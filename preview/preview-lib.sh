#!/usr/bin/env bash
# preview-lib.sh — shared dev-preview control logic for every project.
#
# The public HTTPS previews are served by the always-on `cloudflared-previews`
# systemd user service (persistent named tunnel), NOT per-run quick-tunnels. This
# library manages only the two LOCAL processes behind that tunnel for one project:
#   * a dockerized backend (docker compose) on $BACKEND_PORT
#   * a STATIC RELEASE build of the Flutter web app, served on $FRONTEND_PORT
#     (release build, not `flutter run` — it can't silently die or wedge the port)
#
# Why a shared lib: the two staleness traps a Flutter web preview hits are
# generic, so their fixes belong in one place instead of drifting per project:
#   1. Edge cache — Flutter's entry files (main.dart.js, flutter_bootstrap.js)
#      have FIXED names, so the URL never changes across builds and Cloudflare
#      keeps serving an edge-cached old copy for hours. We serve via
#      serve-nocache.py (Cache-Control: no-store) so CF never caches them.
#   2. Service worker — a SW caches the app in the browser independently of HTTP
#      headers, so a rebuild wouldn't reach an already-loaded client. We build
#      with --pwa-strategy=none (no new SW) and ship a self-destroying SW at the
#      URL a stale SW polls, so previously-loaded clients heal themselves.
# And: every relaunch (up/restart/rebuild) ALWAYS recompiles first, so a preview
# can never serve a stale build.
#
# A project's <name>-dev.sh sources this after setting the config vars below, then
# calls `preview_main "$@"`. See bibbles-dev.sh / tyf-dev.sh for the two shapes
# (compile-time API define vs runtime .env).
#
# ── Config the caller MUST set before sourcing ──────────────────────────────
#   PROJECT        display name (e.g. bibbles)
#   FRONTEND_DIR   flutter app dir (has pubspec.yaml; build output at build/web)
#   BACKEND_DIR    dir with the docker compose file
#   FRONTEND_PORT  local port for the static web server
#   BACKEND_PORT   local port the backend listens on
#   FRONTEND_URL   public preview URL (shown by `urls`)
#   API_URL        public API URL (shown by `urls`; bibbles also bakes it in)
#   STATE_DIR      dir for pid/log state (e.g. $ROOT/.dev)
#   FLUTTER_PATH   bin dir prepended to PATH (project-pinned Flutter SDK)
# ── Optional ────────────────────────────────────────────────────────────────
#   BUILD_EXTRA    array of extra `flutter build web` args (e.g. --dart-define=…)
#   TMPDIR         override (Flutter's web compiler overflows the small /tmp tmpfs)
#   pre_build      shell function; if defined, run before each build (validation)
#   BACKEND_WAIT   1 = `docker compose up --wait` (needs healthchecks); default 0
# ── Env knobs a CALLER sets (not project config) ────────────────────────────
#   BACKEND_FORCE_RECREATE=1  recreate containers even when image+config match
#   BACKEND_RESET_VOLUMES=1   `down -v` first: the branch's migrations replay
#                             against an empty DB (implies --force-recreate).
#                             Set by `checkout` and by `relaunch --reset`.
#   FRONTEND_REPO_DIR / BACKEND_REPO_DIR
#                  git repos `checkout` switches; default to FRONTEND_DIR /
#                  BACKEND_DIR, which is right when the build dir IS the repo
#                  (both projects today). Set them when a repo root differs from
#                  the dir compose/flutter is invoked in.
set -euo pipefail

: "${PROJECT:?preview-lib: PROJECT unset}"
: "${FRONTEND_DIR:?preview-lib: FRONTEND_DIR unset}"
: "${BACKEND_DIR:?preview-lib: BACKEND_DIR unset}"
: "${FRONTEND_PORT:?preview-lib: FRONTEND_PORT unset}"
: "${BACKEND_PORT:?preview-lib: BACKEND_PORT unset}"
: "${FRONTEND_URL:?preview-lib: FRONTEND_URL unset}"
: "${API_URL:?preview-lib: API_URL unset}"
: "${STATE_DIR:?preview-lib: STATE_DIR unset}"
: "${FLUTTER_PATH:?preview-lib: FLUTTER_PATH unset}"

# Default to an empty array (not ("") — that injects a stray empty build arg).
declare -p BUILD_EXTRA >/dev/null 2>&1 || BUILD_EXTRA=()
# The build dir is the repo root in both projects today; keep them overridable.
FRONTEND_REPO_DIR="${FRONTEND_REPO_DIR:-$FRONTEND_DIR}"
BACKEND_REPO_DIR="${BACKEND_REPO_DIR:-$BACKEND_DIR}"
WEB_DIR="$FRONTEND_DIR/build/web"
export PATH="$FLUTTER_PATH:$PATH"
export TMPDIR="${TMPDIR:-$STATE_DIR/tmp}"
mkdir -p "$STATE_DIR" "$TMPDIR"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_NOCACHE="$_LIB_DIR/serve-nocache.py"

DC() { docker compose "$@"; }   # docker group on the box → no sudo
is_up()     { local pid; pid=$(cat "$1" 2>/dev/null || true); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
port_busy() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

start_backend() {
  # --build: rebuild the backend image from current source every relaunch, so a
  # preview reflects the latest merged BACKEND code — not just the frontend. Plain
  # `up -d` reuses a stale image, which silently served 46h-old code (no shop /
  # inventory / arrange endpoints) behind a fresh frontend. Docker's layer cache
  # keeps this near-instant when nothing changed; recreating the container also
  # re-runs any start-time migrations (e.g. bibbles' `alembic upgrade head`).
  # --force-recreate (set by cmd_checkout via BACKEND_FORCE_RECREATE) additionally
  # restarts containers whose image and config are unchanged. That matters after a
  # branch switch: the backend source is bind-mounted, so `--build` alone can find
  # nothing to do and leave the OLD container running against the NEW branch's
  # migrations. Recreating re-runs the start-time DB work — for tyf that is
  # DB_RESET_ON_START, which drops the schema and replays the new branch's
  # migration chain from empty, so switching branches needs no volume surgery.
  # BACKEND_RESET_VOLUMES=1 (set by cmd_checkout and by `relaunch --reset`) tears
  # the stack down WITH ITS VOLUMES first, so the branch's migration chain replays
  # against an empty database. --force-recreate alone only re-runs a start-time
  # rebuild for a project that has one (tyf's DB_RESET_ON_START); a project
  # without that flag would keep the previous branch's schema and rows sitting in
  # a named volume, which is exactly how a "fresh" preview served stale data.
  # Only ever used on an explicit branch switch/reset — a plain up/restart must
  # not throw away the dev database.
  if [ "${BACKEND_RESET_VOLUMES:-0}" = 1 ]; then
    echo "[backend] docker compose down -v (resetting volumes for a clean branch state)"
    (cd "$BACKEND_DIR" && DC down -v --remove-orphans) || echo "[backend] down -v reported errors (continuing)"
  fi
  local extra=()
  { [ "${BACKEND_FORCE_RECREATE:-0}" = 1 ] || [ "${BACKEND_RESET_VOLUMES:-0}" = 1 ]; } && extra+=(--force-recreate)
  # --wait blocks until healthchecks pass, so `checkout` returns only once the API
  # is really serving (and its DB rebuild has finished). Opt-in: a compose file
  # without healthchecks gains nothing and only risks a spurious timeout.
  [ "${BACKEND_WAIT:-0}" = 1 ] && extra+=(--wait)
  echo "[backend] docker compose up -d --build ${extra[*]} ($PROJECT)"
  (cd "$BACKEND_DIR" && DC up -d --build "${extra[@]}")
}

build_frontend() {
  declare -F pre_build >/dev/null && pre_build
  # Regenerate code-gen outputs (freezed / json_serializable) before building.
  # *.freezed.dart and *.g.dart are gitignored, so a fresh or branch-switched
  # checkout carries stale/missing generated code; `flutter build web` then
  # compiles against it and dies at dart2js (e.g. "No named parameter with the
  # name 'currentUserThankedRecently'"). The dev loop's VERIFY already runs this,
  # so mirror it here — previews must build the exact code the loop verified.
  if grep -qE '^[[:space:]]*build_runner:' "$FRONTEND_DIR/pubspec.yaml" 2>/dev/null; then
    echo "[frontend] dart run build_runner build --delete-conflicting-outputs"
    (cd "$FRONTEND_DIR" && flutter pub get && dart run build_runner build --delete-conflicting-outputs)
  fi
  echo "[frontend] flutter build web --release --pwa-strategy=none ${BUILD_EXTRA[*]}"
  # --pwa-strategy=none: don't generate/register the Flutter service worker, so
  # serve-nocache.py's no-store fully controls freshness (see header, trap #2).
  (cd "$FRONTEND_DIR" && flutter build web --release --pwa-strategy=none "${BUILD_EXTRA[@]}")
  install_sw_killswitch
}

# A device that loaded an OLDER build still has that build's caching SW installed
# and keeps serving the stale app from Cache Storage. Ship a self-destroying SW at
# the URL that stale SW polls (flutter_service_worker.js): on its next update check
# the browser fetches this, which clears caches, unregisters, and reloads — leaving
# the device SW-free (new --pwa-strategy=none loads don't re-register).
install_sw_killswitch() {
  cat > "$WEB_DIR/flutter_service_worker.js" <<'SW'
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    try { const k = await caches.keys(); await Promise.all(k.map((c) => caches.delete(c))); } catch (_) {}
    try { await self.registration.unregister(); } catch (_) {}
    const cs = await self.clients.matchAll({ type: 'window' });
    for (const c of cs) { try { c.navigate(c.url); } catch (_) {} }
  })());
});
SW
  echo "[frontend] installed self-destroying service worker (heals stale clients)"
}

serve_frontend() {
  if is_up "$STATE_DIR/web-serve.pid"; then
    echo "[frontend] static server already up (pid $(cat "$STATE_DIR/web-serve.pid"))"; return
  fi
  if port_busy "$FRONTEND_PORT"; then
    echo "[frontend] :$FRONTEND_PORT already in use by an untracked process — leaving it."
    echo "[frontend] run '$0 restart' to hand port management to this script."; return
  fi
  [ -f "$WEB_DIR/index.html" ] || build_frontend
  # setsid + </dev/null fully detaches the server into its own session, so it never
  # holds this script's stdio open (which would hang the caller) and survives the
  # shell. serve-nocache.py (not `python3 -m http.server`) sends no-store so
  # Cloudflare never edge-caches a stale main.dart.js after a rebuild.
  setsid python3 "$SERVE_NOCACHE" "$FRONTEND_PORT" "$WEB_DIR" \
      </dev/null > "$STATE_DIR/web-serve.log" 2>&1 &
  sleep 1
  local real; real=$(ss -ltnp 2>/dev/null | grep ":$FRONTEND_PORT " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  [ -n "$real" ] && echo "$real" > "$STATE_DIR/web-serve.pid"
  echo "[frontend] serving $WEB_DIR on :$FRONTEND_PORT (pid ${real:-?})"
}

stop_frontend() {
  local pid; pid=$(cat "$STATE_DIR/web-serve.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill "$pid" && echo "[frontend] stopped (pid $pid)"; fi
  rm -f "$STATE_DIR/web-serve.pid"
  # Also reap an untracked server (a leftover `flutter run` or a hand-started one).
  if port_busy "$FRONTEND_PORT"; then
    pkill -f "run -d web-server --web-port $FRONTEND_PORT" 2>/dev/null || true
    local held; held=$(ss -ltnp 2>/dev/null | grep ":$FRONTEND_PORT " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    [ -n "$held" ] && { kill "$held" 2>/dev/null && echo "[frontend] reaped untracked pid $held on :$FRONTEND_PORT"; }
  fi
}

# Every relaunch (up/restart/rebuild) recompiles first so the preview can never
# serve a stale build. The static server itself never dies; the ~80s
# `flutter build web --release` is the cost of guaranteed-current previews.
cmd_up()      { start_backend; stop_frontend; sleep 1; build_frontend; serve_frontend; echo; cmd_urls; }
cmd_down()    { stop_frontend; (cd "$BACKEND_DIR" && DC stop); }
cmd_restart() { stop_frontend; sleep 1; build_frontend; serve_frontend; cmd_urls; }
cmd_rebuild() { cmd_restart; }   # kept for muscle memory; identical to restart

# True when $2 names a branch in repo $1, locally or on origin. A bare
# `git checkout <branch>` DWIMs a remote-only name into a tracking branch, so
# both cases are checkout-able; only a name in neither is not.
_branch_exists() {
  git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 ||
    git -C "$1" rev-parse --verify --quiet "refs/remotes/origin/$2" >/dev/null 2>&1
}

# Check out $3 in the single repo $2 ($1 = label for logging).
#
# `flutter pub get`/build regenerate pubspec.lock with different transitive pins,
# leaving the tree dirty; that drift then BLOCKS `git checkout`. The committed
# lockfile is the source of truth, so restore ONLY pubspec.lock — never a blind
# `checkout -f`, which would nuke real source edits. Any OTHER dirt is a real
# edit, so we let git refuse the checkout rather than discard someone's work.
#
# A missing branch is a warning, not an error: most task branches touch one repo
# only, so "no such branch in core" is the normal case for a frontend-only task
# and must still leave the other repo switched and the preview redeployed.
# The branch a repo falls back to when a feature doesn't exist in it: DEFAULT_BRANCH
# if the project declares one, else whatever origin/HEAD points at, else main.
_default_branch() {
  local dir="$1" ref
  [ -z "${DEFAULT_BRANCH:-}" ] || { echo "$DEFAULT_BRANCH"; return; }
  if ref=$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${ref#origin/}"; return
  fi
  echo main
}

_checkout_repo() {
  local label="$1" dir="$2" branch="$3" fallback
  if [ ! -d "$dir/.git" ]; then
    echo "[git/$label] $dir is not a git repo — skipping"; return 0
  fi
  git -C "$dir" checkout -- pubspec.lock 2>/dev/null || true
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  # A branch that doesn't exist here means the change touches only the OTHER repo
  # — the normal frontend-only / backend-only case. The right state for this repo
  # is then the default branch, NOT wherever it happens to be standing: "stay put"
  # left the previous checkout's feature branch in place, so switching from a
  # two-repo feature to a frontend-only one silently kept the old backend. Falling
  # back makes every checkout a complete, reproducible state.
  if ! _branch_exists "$dir" "$branch"; then
    fallback=$(_default_branch "$dir")
    if [ "$fallback" = "$branch" ] || ! _branch_exists "$dir" "$fallback"; then
      echo "[git/$label] WARNING: neither '$branch' nor a default branch here — staying on $(git -C "$dir" branch --show-current)"
      return 0
    fi
    echo "[git/$label] no '$branch' here (change doesn't touch this repo) — falling back to $fallback"
    branch="$fallback"
  fi
  echo "[git/$label] checkout $branch"
  git -C "$dir" checkout "$branch"
  git -C "$dir" pull --ff-only --quiet 2>/dev/null || true
  echo "[git/$label] now on $(git -C "$dir" branch --show-current) @ $(git -C "$dir" log -1 --format=%h)"
}

# Switch BOTH repos to a branch and redeploy in one step.
#
# Frontend-only checkout was the old behaviour and it silently served a mixed
# build: the new UI against the previous branch's backend and database. A feature
# lands across both repos under one branch name, so both must move together, and
# the backend container must be recreated so the branch's migrations/seed define
# the DB (see start_backend's --force-recreate note).
cmd_checkout() {
  local branch="${1:?usage: $0 checkout <branch>}"
  _checkout_repo frontend "$FRONTEND_REPO_DIR" "$branch"
  _checkout_repo backend  "$BACKEND_REPO_DIR"  "$branch"
  # Plain assignment, not a `VAR=1 cmd_up` prefix: bash keeps assignment prefixes
  # on *function* calls in the shell after the call, so the prefix form reads as
  # scoped while behaving globally. Set it outright and let the script exit.
  BACKEND_FORCE_RECREATE=1
  # A branch switch also resets the volumes: the previous branch's schema/rows
  # live in a named volume that --force-recreate does not touch.
  BACKEND_RESET_VOLUMES=1
  cmd_up
}

# "<branch> (<sha>[, dirty])" for a repo dir — what a URL is actually serving.
_repo_state() {
  local dir="$1" br sha
  [ -d "$dir/.git" ] || { echo "not-a-git-repo"; return; }
  br=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || br="?"
  sha=$(git -C "$dir" log -1 --format=%h 2>/dev/null) || sha="?"
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "$br ($sha, dirty)"
  else
    echo "$br ($sha)"
  fi
}

# Classify a frontend/backend branch split. NOT every split is wrong: most changes
# touch one repo only, so "frontend on feature/x, backend on dev" is the intended,
# complete state for a frontend-only PR — warning about it would cry wolf on the
# common case. What is wrong is a repo standing on the WRONG branch while the
# right one exists for it. So:
#   aligned  — same branch in both.
#   split    — the other repo has no such branch and is on its default branch:
#              a one-sided change, correctly served.
#   mixed    — the branch DOES exist in the other repo but isn't checked out (the
#              real defect), or both sit on unrelated non-default branches.
# Echoes the kind; the caller words the message.
_split_kind() {
  local feb="$1" beb="$2" fed bed
  [ "$feb" != "$beb" ] || { echo aligned; return; }
  fed=$(_default_branch "$FRONTEND_REPO_DIR"); bed=$(_default_branch "$BACKEND_REPO_DIR")
  # Both on their own default branch — the baseline. (Two repos may name their
  # default differently, so different strings here are still "aligned".)
  if [ "$feb" = "$fed" ] && [ "$beb" = "$bed" ]; then echo aligned; return; fi
  # Both off-default, on unrelated branches: never a state the checkout flow
  # produces, so somebody's tree is stale.
  if [ "$feb" != "$fed" ] && [ "$beb" != "$bed" ]; then echo mixed; return; fi
  # Exactly one repo carries a feature branch. Expected only if the other genuinely
  # doesn't have that branch; if it does, it should be on it.
  if [ "$feb" != "$fed" ]; then
    _branch_exists "$BACKEND_REPO_DIR" "$feb" && { echo mixed; return; }
  else
    _branch_exists "$FRONTEND_REPO_DIR" "$beb" && { echo mixed; return; }
  fi
  echo split
}

# A URL is only meaningful together with the code behind it: a frontend served
# from a PR branch against a backend still on the default branch looks fine and
# behaves wrongly. So every place that prints a URL prints its repo + branch, and
# a split between the two is classified rather than left for the user to notice.
cmd_urls() {
  local fe be feb beb fen ben
  fe=$(_repo_state "$FRONTEND_REPO_DIR"); be=$(_repo_state "$BACKEND_REPO_DIR")
  feb="${fe%% *}"; beb="${be%% *}"
  fen=$(basename "$FRONTEND_REPO_DIR"); ben=$(basename "$BACKEND_REPO_DIR")
  echo "=== Preview URLs (persistent Cloudflare tunnel) ==="
  echo "  Frontend : $FRONTEND_URL   (static release, local :$FRONTEND_PORT)"
  echo "             ↳ $fen @ $fe"
  echo "  API      : $API_URL   (local :$BACKEND_PORT, + /docs for Swagger)"
  echo "             ↳ $ben @ $be"
  case "$(_split_kind "$feb" "$beb")" in
    split)
      if [ "$feb" != "$(_default_branch "$FRONTEND_REPO_DIR")" ]; then
        echo "  ℹ️ one-sided change: $ben has no '$feb', so it serves $beb — expected"
      else
        echo "  ℹ️ one-sided change: $fen has no '$beb', so it serves $feb — expected"
      fi ;;
    mixed)
      echo "  ⚠️ MIXED CHECKOUT: $fen serves $feb but $ben serves $beb — not a one-sided change, so one of them is stale" ;;
  esac
}

# Machine-readable "<repo-dir-name>\t<branch>\t<sha>" per served repo, for callers
# that want the state without parsing the URL block (e.g. a status collector).
cmd_branches() {
  local dir st
  for dir in "$FRONTEND_REPO_DIR" "$BACKEND_REPO_DIR"; do
    st=$(_repo_state "$dir")
    printf '%s\t%s\t%s\n' "$(basename "$dir")" "${st%% *}" "$(echo "$st" | sed -E 's/^[^ ]+ \((.*)\)$/\1/')"
  done
}

cmd_status() {
  echo "=== docker ==="; (cd "$BACKEND_DIR" && DC ps) || true
  echo; echo "=== frontend ==="
  if is_up "$STATE_DIR/web-serve.pid"; then echo "  static server: up (pid $(cat "$STATE_DIR/web-serve.pid"))"
  elif port_busy "$FRONTEND_PORT"; then echo "  static server: up (untracked — run 'restart' to adopt)"
  else echo "  static server: down"; fi
  echo; echo "=== tunnel ==="
  echo "  cloudflared-previews: $(systemctl --user is-active cloudflared-previews 2>/dev/null || echo unknown)"
  echo; cmd_urls
}

cmd_logs() { tail -n "${2:-40}" "$STATE_DIR/${1:-web-serve}.log"; }

preview_main() {
  case "${1:-}" in
    up|start)                             cmd_up ;;
    down|stop)                            cmd_down ;;
    restart)                              cmd_restart ;;
    rebuild|rebuild-frontend|restart-app) cmd_rebuild ;;
    checkout|switch)                      cmd_checkout "${2:-}" ;;
    status)                               cmd_status ;;
    urls)                                 cmd_urls ;;
    branches)                             cmd_branches ;;
    logs)                                 cmd_logs "${2:-web-serve}" "${3:-40}" ;;
    *)
      echo "usage: $0 {up|down|restart|rebuild|checkout <branch>|status|urls|branches|logs [name] [n]}"
      echo "  up        start backend (docker) + recompile & serve the frontend on :$FRONTEND_PORT"
      echo "  down      stop the frontend server and 'docker compose stop' the backend"
      echo "  restart   recompile the frontend and re-serve (always picks up code/.env changes)"
      echo "  rebuild   recompile the frontend and re-serve (same as restart)"
      echo "  checkout <branch>  switch BOTH repos to <branch>, reset the backend"
      echo "                     volumes + recreate it, then recompile & serve"
      echo "  status    docker ps + frontend + tunnel state + URLs"
      echo "  urls      show the persistent preview URLs + the branch behind each"
      echo "  branches  repo/branch/sha per served repo, tab-separated"
      echo "  logs [name] [n]   tail a state log (default web-serve, 40 lines)"
      exit 1 ;;
  esac
}
