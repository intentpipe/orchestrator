#!/usr/bin/env bash
# Tier 1 smoke test for the whole Dialectica/Quorum loop (box_spec.md §11).
# Sealed: no real model, no Telegram, no network. Fake `claude` on PATH,
# TELEGRAM_ENV pointed at /nonexistent, everything under one temp dir.
#
# What's REAL: the plugin's task.sh/preflight.sh/loop.sh (unmodified — a live,
# shared script three other projects depend on today), and claude-run.sh (this
# run's own deliverable, ../claude-run.sh) — the limit-catching chain in point
# 5 below is exercised through the real thing, not a simulation of it.
#
# What's STUBBED, because none of it exists yet (box_spec.md §13 steps 9-12):
# the moderator (here: a few lines that call claude-run.sh and log one wake
# line — no real classifier), "headless plan" (here: task.sh new, called
# directly — no real /intentpipe:plan run against a fake model), cycle.py
# (here: a three-line feature count, not a systemd timer), and the retro
# skill's `autonomous` mode (here: the "meta-agent pass" writes one retro file
# and one intent note by fiat, then runs the SAME real plan-stub/loop.sh/
# squash-merge chain as point 2, against the fake quorum workspace).
#
# Extends, never replaces, the plugin's own tests (box_spec.md §11, closing
# paragraph) — run first, as a hard prerequisite.
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$HOME/intentpipe/plugin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "LOOP-SMOKE FAIL: $*" >&2; exit 1; }
pass() { echo "-- $* --"; }

# Seal from any real creds — the plugin's own notify.sh / ask.sh read this.
export TELEGRAM_ENV=/nonexistent

echo "== prerequisite: plugin's own tests (never replaced, always run first) =="
bash "$PLUGIN/tests/smoke.sh" >/dev/null || fail "plugin tests/smoke.sh failed"
pass "plugin smoke.sh OK"
bash "$PLUGIN/tests/limit-retry.sh" >/dev/null || fail "plugin tests/limit-retry.sh failed"
pass "plugin limit-retry.sh OK"

# --------------------------------------------------------------------------
# Fixtures: a fake dialectica and a fake quorum workspace, single "app" repo
# each (the coordination chain under test doesn't need core/app/engine's real
# shape — see plugin/tests/smoke.sh and limit-retry.sh for the same minimal
# single-repo pattern this mirrors).
# --------------------------------------------------------------------------
mk_ws() { # mk_ws <dir> <default-branch>
  local ws="$1" branch="$2"
  mkdir -p "$ws/app" "$ws/intentpipe/tasks" "$ws/intentpipe/updates" "$ws/intentpipe/retro"
  git -C "$ws" init -qb "$branch" && git -C "$ws" config user.email t@t && git -C "$ws" config user.name t
  git -C "$ws/app" init -qb "$branch"
  git -C "$ws/app" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
  cat > "$ws/intentpipe/agents.env" <<EOF
PROJECT_NAME=$(basename "$ws")
DEFAULT_BRANCH=$branch
DONE=local
REPOS="app"
REPO_app=../app
VERIFY_app="test -f ok.txt"
AFTER_DONE='touch "\$INTENTPIPE_WORKSPACE/../afterdone.marker"'
EOF
  echo ok > "$ws/app/ok.txt"
  git -C "$ws/app" add . && git -C "$ws/app" -c user.email=t@t -c user.name=t commit -qm "add ok"
}
DIALECTICA="$TMP/dialectica"; mk_ws "$DIALECTICA" main
QUORUM="$TMP/quorum"; mk_ws "$QUORUM" dev

tree_hash() { # byte-identity check (§11 point 4) — file contents only, git
  # internals (reflogs etc.) can churn harmlessly without the working tree
  # actually changing.
  find "$1" -type f -not -path '*/.git/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

ORCH_HOME="$TMP/orch-home"; mkdir -p "$ORCH_HOME/run"
export ORCH_HOME

# --------------------------------------------------------------------------
# Fake `claude`: a per-task counter file (like limit-retry.sh's) selects
# canned behaviour. build-claude.sh drives task 0001 through one usage-limit
# hit then a recovery (the injection under test, point 5); any other task
# just lands clean on the first call.
# --------------------------------------------------------------------------
mkdir -p "$TMP/fake"
cat > "$TMP/fake/build-claude.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$DIALECTICA"
id=\$(cat intentpipe/tasks/.current-id 2>/dev/null || echo 0001)
n_file="$TMP/fake/build-count-\$id"
n=\$(cat "\$n_file" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$n_file"
limit_file="$TMP/fake/build-limit-\$id"
if [ -f "\$limit_file" ] && [ "\$n" -eq 1 ]; then
  "$PLUGIN/scripts/task.sh" start "\$id" >/dev/null
  echo "wip" >> app/wip.txt
  echo "Claude AI usage limit reached|9999999999"
  exit 1
fi
git -C app diff --quiet || { echo "RETRY SAW DIRTY TREE" >&2; exit 3; }
"$PLUGIN/scripts/task.sh" start "\$id" >/dev/null
git -C app add -A
git -C app -c user.email=t@t -c user.name=t commit -qm "finish \$id" 2>/dev/null || true
"$PLUGIN/scripts/task.sh" done "\$id" >/dev/null
echo '{"session_id": "build-'"\$id"'", "total_cost_usd": 0.01}'
EOF
chmod +x "$TMP/fake/build-claude.sh"

cat > "$TMP/fake/wake-claude.sh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$TMP/fake/wake-count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$TMP/fake/wake-count"
echo '{"session_id": "wake", "role": "ceo"}'
EOF
chmod +x "$TMP/fake/wake-claude.sh"

cat > "$TMP/fake/meta-claude.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$QUORUM"
id=\$(cat intentpipe/tasks/.current-id)
"$PLUGIN/scripts/task.sh" start "\$id" >/dev/null
echo "\$id" >> app/ok.txt   # a real diff -- an empty commit squash-merges as "no changes"
git -C app add -A
git -C app -c user.email=t@t -c user.name=t commit -qm "finish \$id" >/dev/null
"$PLUGIN/scripts/task.sh" done "\$id" >/dev/null
echo '{"session_id": "meta-'"\$id"'"}'
EOF
chmod +x "$TMP/fake/meta-claude.sh"

# PATH shim: loop.sh (real, unmodified) calls literal `claude`. This makes
# that resolve through claude-run.sh — the box-wide net — instead of straight
# to the fake body, so a build loop.sh drives gets the SAME box-wide
# coordination a moderator/cycle-timer call gets, without editing loop.sh's
# source (a live script three other projects depend on; not touched by this
# run — see SETUP_REPORT.md). $CLAUDE_BIN (read fresh by claude-run.sh from
# the environment on each call) selects which fake body answers.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
exec "$ORCH/claude-run.sh" "\$@"
EOF
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

WAKE_LOG="$TMP/wake.log"
moderator_wake() { # moderator_wake <channel-msg> -> logs one line + prints "woken"
  # on success, on stdout; refused (box paused/limited/no slot) -> prints
  # nothing, returns the refusing exit code. This IS the real claude-run.sh,
  # called directly (no PATH shim needed here: nothing else stands between a
  # real moderator and the wrapper it's specified to call).
  local msg="$1" out rc=0
  out=$(CLAUDE_BIN="$TMP/fake/wake-claude.sh" "$ORCH/claude-run.sh" -p "classify: $msg" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  echo "$(date -u +%FT%TZ) role=ceo msg=\"$msg\"" >> "$WAKE_LOG"
  echo woken
}

# --------------------------------------------------------------------------
# §11 point 1 — a message wakes exactly one role, wake log has one line.
# --------------------------------------------------------------------------
echo "== point 1: moderator wakes exactly one role =="
[ "$(moderator_wake "new feature idea")" = "woken" ] || fail "moderator_wake did not report woken"
[ "$(wc -l < "$WAKE_LOG")" -eq 1 ] || fail "wake log should have exactly 1 line, got $(cat "$WAKE_LOG")"
pass "point 1 OK: one wake, one log line"

# --------------------------------------------------------------------------
# §11 points 2 + 5 — the woken CEO drops an intent note (stub: task.sh new
# stands in for headless plan, box_spec.md §13 step 1's absence noted above)
# -> loop.sh -> the task lands DONE=local, AFTER_DONE fires -- with a usage
# limit injected mid-build (point 5), which must NOT block the task.
# --------------------------------------------------------------------------
echo "== points 2 + 5: intent note -> plan(stub) -> loop.sh -> lands; limit injected mid-build =="
quorum_hash_before_point2=$(tree_hash "$QUORUM")

cd "$DIALECTICA"
echo "v1 walking skeleton" > intentpipe/updates/note.md
git add intentpipe/updates/note.md && git -c user.email=t@t -c user.name=t commit -qm "intent: v1 walking skeleton" >/dev/null
id=$("$PLUGIN/scripts/task.sh" new "V1 walking skeleton")
echo "$id" > intentpipe/tasks/.current-id
touch "$TMP/fake/build-limit-$id"   # this task's first build call hits a limit

# Run loop.sh in the background so we can probe "another spawner" mid-wait.
CLAUDE_BIN="$TMP/fake/build-claude.sh" LIMIT_BACKOFF=3 MAX_TASKS=1 \
  bash "$PLUGIN/scripts/loop.sh" > "$TMP/loop.out" 2>&1 &
loop_pid=$!

# Wait for the box-wide stamp to appear (claude-run.sh writes it the moment
# the fake claude's limit message comes back) -- bounded, not a fixed sleep.
stamp_seen=0
for _ in $(seq 1 100); do
  if [ -s "$ORCH_HOME/limit.until" ] && [ "$(cat "$ORCH_HOME/limit.until")" -gt "$(date +%s)" ]; then
    stamp_seen=1; break
  fi
  sleep 0.1
done
[ "$stamp_seen" -eq 1 ] || fail "box-wide limit stamp never appeared while the build was mid-limit"
pass "limit stamp is up while the build waits"

# §11 point 5: "every other spawner refuses to start while the limit stands."
# A second, unrelated wake attempt during the window must be refused, and must
# never even invoke its own fake claude (wake-count must not tick past the 1
# it already reached in point 1's legitimate call, above).
wake_count_before=$(cat "$TMP/fake/wake-count" 2>/dev/null || echo 0)
rc=0
moderator_wake "another feature, during the pause" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a second spawner should have been refused while the limit stamp stands"
[ "$(wc -l < "$WAKE_LOG")" -eq 1 ] || fail "refused spawner must not add a wake-log line"
wake_count_after=$(cat "$TMP/fake/wake-count" 2>/dev/null || echo 0)
[ "$wake_count_after" = "$wake_count_before" ] || fail "refused spawner must never invoke its own claude call (wake-count $wake_count_before -> $wake_count_after)"
pass "a second spawner was refused while the stamp stood, and never ran"

wait "$loop_pid" || fail "loop.sh (via claude-run.sh) exited nonzero: $(cat "$TMP/loop.out")"
grep -q "Status: done" "intentpipe/tasks/$id"-*/task.md || fail "task $id not done after the limit cleared"
pass "the build resumed the same task after the stamp passed, and it landed done"

# Exactly one notification for this whole limit episode (claude-run.sh's first
# retry; no re-notify on give-up since it never gave up, no notify from the
# refused second spawner since a pre-start refusal is silent by design).
# claude-run.sh's own durable log ($ORCH_HOME/notify.log), not loop.sh's
# captured output: loop.sh's per-call stderr capture is a temp file it only
# ever prints on a FAILURE path, and this call's overall rc is 0 (claude-run.sh
# resolved the retry internally before returning) — the notification that
# fired mid-retry would otherwise be invisible to anything watching loop.sh.
notify_lines=$(grep -c "usage limit" "$ORCH_HOME/notify.log" 2>/dev/null || true)
[ "$notify_lines" -eq 1 ] || fail "expected exactly 1 usage-limit notification, got $notify_lines: $(cat "$ORCH_HOME/notify.log" 2>/dev/null)"
pass "exactly one usage-limit notification for the whole episode"

# AFTER_DONE fires (deferred to end-of-run under loop.sh, per lib.sh's
# after_done — that's WHY loop.sh, not a bare task.sh done, is in this test).
for _ in $(seq 1 50); do [ -f "$DIALECTICA/afterdone.marker" ] && break; sleep 0.1; done
[ -f "$DIALECTICA/afterdone.marker" ] || fail "AFTER_DONE hook never fired"
pass "AFTER_DONE fired"

quorum_hash_after_point2=$(tree_hash "$QUORUM")
[ "$quorum_hash_before_point2" = "$quorum_hash_after_point2" ] \
  || fail "the fake quorum's tree changed during the dialectica council's turn (guardrail violated)"
pass "quorum untouched by the dialectica-side turn (§9/§6 guardrail)"

# --------------------------------------------------------------------------
# §11 point 3 (stubbed cycle.py + retro autonomous mode) — three features
# reach previewable (here: Status: done) -> a 3-line "cycle" check fires ->
# meta-agent pass writes a retro file + intent note into the fake quorum ->
# plan(stub) -> build (real loop.sh again) -> squash-merge onto quorum's dev.
# --------------------------------------------------------------------------
echo "== point 3 (stubbed): 3 features previewable -> meta-agent pass -> quorum lands on dev =="
for title in "Feature two" "Feature three"; do
  id2=$("$PLUGIN/scripts/task.sh" new "$title")
  "$PLUGIN/scripts/task.sh" start "$id2" >/dev/null
  echo "$id2" >> app/ok.txt   # a real diff — an empty commit squash-merges as "no changes" (task.sh done skips it)
  git -C app add -A
  git -C app -c user.email=t@t -c user.name=t commit -qm "finish $id2" >/dev/null
  "$PLUGIN/scripts/task.sh" done "$id2" >/dev/null
done

# cycle.py stub: count Status: done tasks; box_spec.md §7 point 2's threshold.
done_count=$(grep -l "^Status: done" intentpipe/tasks/*/task.md 2>/dev/null | wc -l)
[ "$done_count" -ge 3 ] || fail "expected >= 3 done features to trip the cycle threshold, got $done_count"
pass "cycle threshold reached ($done_count features previewable)"

dialectica_hash_before_point3=$(tree_hash "$DIALECTICA")

cd "$QUORUM"
echo "- $(date -u +%FT%TZ): 3 features previewable, meta-agent pass fired (stub)" >> intentpipe/retro/cycle-0.md
echo "process: simplify the wake classifier (stub complaint)" > intentpipe/updates/note.md
git add intentpipe/retro/cycle-0.md intentpipe/updates/note.md
git -c user.email=t@t -c user.name=t commit -qm "meta-agent pass: retro + intent note (stub)" >/dev/null
mid=$("$PLUGIN/scripts/task.sh" new "Simplify wake classifier")
echo "$mid" > intentpipe/tasks/.current-id

CLAUDE_BIN="$TMP/fake/meta-claude.sh" MAX_TASKS=1 \
  bash "$PLUGIN/scripts/loop.sh" > "$TMP/meta.out" 2>&1 \
  || fail "meta-agent pass loop.sh failed: $(cat "$TMP/meta.out")"
grep -q "Status: done" "intentpipe/tasks/$mid"-*/task.md || fail "meta-agent task not done"
git -C app log -1 dev --format=%B | grep -q "Task-Id: $mid" || fail "no squash commit on quorum's dev"
pass "meta-agent pass landed on quorum's dev via the real plan-stub/loop.sh/squash-merge chain"

dialectica_hash_after_point3=$(tree_hash "$DIALECTICA")
[ "$dialectica_hash_before_point3" = "$dialectica_hash_after_point3" ] \
  || fail "the fake dialectica's tree changed during the meta-agent pass (guardrail violated)"
pass "dialectica untouched by the meta-agent pass (§9/§6 guardrail)"

echo "LOOP-SMOKE OK"
