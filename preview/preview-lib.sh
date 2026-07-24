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
  echo "[backend] docker compose up -d ($PROJECT)"
  (cd "$BACKEND_DIR" && DC up -d)
}

build_frontend() {
  declare -F pre_build >/dev/null && pre_build
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

# Switch the frontend repo to a branch and redeploy in one step. `flutter pub
# get`/build regenerate pubspec.lock with different transitive pins, leaving the
# tree dirty; that drift then BLOCKS `git checkout`. The committed lockfile is the
# source of truth, so restore ONLY pubspec.lock (never a blind `checkout -f`,
# which would nuke real source edits), then check out and rebuild.
cmd_checkout() {
  local branch="${1:?usage: $0 checkout <branch>}"
  echo "[git] discarding disposable pubspec.lock drift (regenerated by builds)"
  git -C "$FRONTEND_DIR" checkout -- pubspec.lock 2>/dev/null || true
  git -C "$FRONTEND_DIR" fetch origin --quiet 2>/dev/null || true
  echo "[git] checkout $branch"
  git -C "$FRONTEND_DIR" checkout "$branch"
  git -C "$FRONTEND_DIR" pull --ff-only --quiet 2>/dev/null || true
  echo "[git] now on $(git -C "$FRONTEND_DIR" branch --show-current)"
  cmd_restart
}

cmd_urls() {
  echo "=== Preview URLs (persistent Cloudflare tunnel) ==="
  echo "  Frontend : $FRONTEND_URL   (static release, local :$FRONTEND_PORT)"
  echo "  API      : $API_URL   (local :$BACKEND_PORT, + /docs for Swagger)"
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
    logs)                                 cmd_logs "${2:-web-serve}" "${3:-40}" ;;
    *)
      echo "usage: $0 {up|down|restart|rebuild|checkout <branch>|status|urls|logs [name] [n]}"
      echo "  up        start backend (docker) + recompile & serve the frontend on :$FRONTEND_PORT"
      echo "  down      stop the frontend server and 'docker compose stop' the backend"
      echo "  restart   recompile the frontend and re-serve (always picks up code/.env changes)"
      echo "  rebuild   recompile the frontend and re-serve (same as restart)"
      echo "  checkout <branch>  discard pubspec.lock drift, switch branch, rebuild & serve"
      echo "  status    docker ps + frontend + tunnel state + URLs"
      echo "  urls      show the persistent preview URLs"
      echo "  logs [name] [n]   tail a state log (default web-serve, 40 lines)"
      exit 1 ;;
  esac
}
