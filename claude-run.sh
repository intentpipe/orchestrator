#!/usr/bin/env bash
# Box-wide rate-limit safety net (box_spec.md §12). The plugin's loop.sh already
# parks WIP and retries a usage-limit exit for ONE build run (scripts/lib.sh:
# limit_wait, is_out_of_credits — same message format, same regexes, reused
# here rather than reinvented). What's missing is coordination ACROSS the
# several `claude -p` sessions this box can have running at once (a build, the
# moderator's classification pings, council runners, the meta-agent pass, the
# cycle timer) — one limit on a shared subscription should pause all of them,
# not have each burn its own retry budget in ignorance of the others.
#
# This is that coordination point: the only way any NEW spawner (moderator,
# council runner, meta-agent pass, cycle timer — box_spec.md §4) starts a
# session. loop.sh itself is untouched (a live, shared script three other
# projects depend on today; not edited by this box-wide net) and keeps calling
# `claude` directly with its own per-run retry, unaffected in production.
#
# Usage: claude-run.sh [claude args...]   (forwarded to $CLAUDE_BIN, default
# `claude`; stdin forwarded too, so `-p` prompts on stdin work same as always)
#
# Exit codes:
#   0        success — stdout is $CLAUDE_BIN's own stdout, unchanged
#   1        refused: a limit stamp already stands (see below) — did not start
#   4        gave up: out of credits (no retry — doesn't clear on a timer)
#   5        gave up: usage limit did not clear after MAX_LIMIT_RETRIES waits
#   6        refused: the box is PAUSED (see $ORCH_HOME/PAUSED)
#   8        refused: no free session slot (MAX_SESSIONS all busy)
#   other    $CLAUDE_BIN's own exit code, forwarded as-is (a genuine failure,
#            not a limit/credits/pause condition)
#
# Config (env): ORCH_HOME (default ~/.agent-orchestrator), CLAUDE_BIN (default
# `claude`), MAX_SESSIONS (default 3), MAX_LIMIT_RETRIES (default 6, mirrors
# loop.sh's default), LIMIT_BACKOFF (default 1800s, mirrors loop.sh's default
# fallback when the limit message carries no reset timestamp).
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORCH_HOME="${ORCH_HOME:-$HOME/.agent-orchestrator}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MAX_SESSIONS="${MAX_SESSIONS:-3}"
MAX_LIMIT_RETRIES="${MAX_LIMIT_RETRIES:-6}"
LIMIT_BACKOFF="${LIMIT_BACKOFF:-1800}"
RUN_DIR="$ORCH_HOME/run"
PAUSED_FILE="$ORCH_HOME/PAUSED"
STAMP_FILE="$ORCH_HOME/limit.until"
mkdir -p "$RUN_DIR"

notify() { # notify <msg> -- best-effort, never fails the caller (same contract as
  # notify.sh). stderr, not stdout: stdout is reserved for the wrapped claude
  # call's own output (a caller parsing --output-format json on a call that
  # eventually succeeds after a retry must see ONLY that JSON, nothing this
  # wrapper printed along the way). ALSO appended to a durable log
  # ($ORCH_HOME/notify.log): a caller that captures this process's own stderr
  # per-call (loop.sh's `claude ... 2>errf`, reused/discarded every call) would
  # otherwise lose a notification that fired mid-retry on a call that went on
  # to succeed — the log is the one place it's guaranteed to still be found.
  printf '%s [notify] %s\n' "$(date -u +%FT%TZ)" "$1" >> "$ORCH_HOME/notify.log" 2>/dev/null || true
  "$HOME/intentpipe/plugin/scripts/notify.sh" "$1" 1>&2 || echo "[notify] $1" >&2
}

# --- same parsing loop.sh's lib.sh uses (scripts/lib.sh: is_out_of_credits,
# limit_wait) — duplicated, not sourced: lib.sh's own top level resolves a
# WORKSPACE (find_workspace) via agents.env, which this box-wide wrapper has
# none of (it runs from cwd-less contexts: the daemon, a systemd timer). Same
# regexes, so the same message from the same CLI is read identically wherever
# it's parsed.
is_out_of_credits() {
  echo "$1" | grep -qiE 'credit balance (is )?too low|purchase credits|insufficient (credit|funds)|out of (usage )?credits?'
}
limit_wait() { # -> seconds to wait on stdout, rc 1 if <output> isn't a usage/rate limit
  echo "$1" | grep -qiE 'usage limit|rate.?limit|(hour|weekly|session) limit' || return 1
  local reset now
  reset=$(echo "$1" | grep -oE '\|[0-9]{10}' | head -1 | tr -d '|' || true)
  now=$(date +%s)
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ] && [ $((reset - now)) -lt $((8 * 86400)) ]; then
    echo $((reset - now + 60))
  else
    echo "$LIMIT_BACKOFF"
  fi
}

pause_box() { # pause_box <reason>: hard pause, nothing spawns until a human (or
  # a documented manual step — box_spec.md §12's Telegram `resume` wiring is out
  # of scope for this run) removes $PAUSED_FILE.
  echo "$1 (pid $$, $(date -u +%FT%TZ))" > "$PAUSED_FILE"
  notify "claude-run.sh: box PAUSED — $1. Resume: rm $PAUSED_FILE"
}

# --- 1. hard pause: nothing spawns while PAUSED exists.
if [ -f "$PAUSED_FILE" ]; then
  echo "REFUSED: box is PAUSED — $(cat "$PAUSED_FILE")" >&2
  exit 6
fi

# --- 2. limit stamp pre-check: a future stamp means refuse, don't even try.
# Non-blocking by design (box_spec.md §12: "the daemon and the moderator sleep
# until it passes; the cycle timer exits and lets its next tick try again" —
# that's the CALLER's decision, not this wrapper's). The refusal message is
# shaped exactly like a real usage-limit message from claude itself (same
# `...limit...|<epoch>` grammar limit_wait parses), so a caller that already
# knows how to read a limit message off `claude` (loop.sh, via its own
# unmodified limit_wait) treats "someone else's limit still standing" exactly
# like "I just hit it myself" — no separate code path needed there.
now=$(date +%s)
stamp=0
[ -f "$STAMP_FILE" ] && stamp=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
if [ "$stamp" -gt "$now" ]; then
  echo "Claude AI usage limit reached|$stamp"
  echo "REFUSED: box-wide limit stamp stands until $(date -d "@$stamp" -u +%FT%TZ 2>/dev/null || echo "$stamp")" >&2
  exit 1
fi

# --- 3. concurrency cap: one pidfile slot from a fixed pool. Non-blocking, same
# rationale as the stamp pre-check. flock on a per-slot lockfile makes
# check-then-claim atomic across concurrent claude-run.sh processes — a bare
# "read pidfile, then write" has a TOCTOU race two processes starting in the
# same instant can both win.
slot=""
for n in $(seq 1 "$MAX_SESSIONS"); do
  pf="$RUN_DIR/claude-run-$n.pid"
  lockf="$RUN_DIR/claude-run-$n.lock"
  exec {fd}>"$lockf"
  flock -n "$fd" || { exec {fd}>&-; continue; }
  if [ -f "$pf" ] && pid=$(cat "$pf" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exec {fd}>&-   # slot busy, held by a live process
    continue
  fi
  echo "$$" > "$pf"
  slot="$pf"
  exec {fd}>&-   # claimed: the pidfile itself is the durable marker from here
  break
done
if [ -z "$slot" ]; then
  echo "REFUSED: no free session slot (MAX_SESSIONS=$MAX_SESSIONS all busy)" >&2
  exit 8
fi
# --- 4. run, with a bounded internal retry on a usage limit (mirrors loop.sh's
# MAX_LIMIT_RETRIES/LIMIT_BACKOFF exactly, so the two give-up points agree).
# Out of credits never retries: it doesn't clear on a timer.
attempt=0
errf=$(mktemp)
cleanup() { rm -f "$slot" "$errf"; }
trap cleanup EXIT
while :; do
  rc=0
  out=$("$CLAUDE_BIN" "$@" 2>"$errf") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$out"
    exit 0
  fi
  combined="$out"$'\n'"$(cat "$errf")"
  if is_out_of_credits "$combined"; then
    pause_box "out of credits (claude-run.sh, args: $*)"
    printf '%s\n' "$out" >&2
    exit 4
  fi
  if wait=$(limit_wait "$combined"); then
    echo "$((now + wait))" > "$STAMP_FILE"
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$MAX_LIMIT_RETRIES" ]; then
      pause_box "usage limit persisted through $MAX_LIMIT_RETRIES retries (claude-run.sh, args: $*)"
      printf '%s\n' "$out" >&2
      exit 5
    fi
    [ "$attempt" -eq 1 ] && notify "claude-run.sh: usage limit — retrying in $((wait / 60))m (up to $MAX_LIMIT_RETRIES tries)"
    sleep "$wait"
    now=$(date +%s)
    continue
  fi
  # genuine failure, not a limit/credits condition: forward as-is.
  printf '%s\n' "$out"
  printf '%s\n' "$(cat "$errf")" >&2
  exit "$rc"
done
