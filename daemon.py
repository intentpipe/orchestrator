#!/usr/bin/env python3
"""Inbound Telegram daemon — the scaffold's voice/text control plane.

Standalone server-side control plane, above any single workspace/project — a
separate project from the scaffold it feeds, not part of it. Architecture +
rationale: DESIGN.md (alongside this file).

Long-poll getUpdates → enforce the allowlist (the only door, Decision #4) →
resolve the message's forum topic to a workspace via the registry → then either
dispatch a trigger token (Decision #10: 🧠/`plan` → headless /machines-at-work:plan,
🚀/`build-all` → detached loop.sh; exact match only) or transcribe voice / take
text and drop the RAW message into <workspace>/updates/.inbox/<epoch>-<msgid>.md
— machines-at-work's inbound.sh contract; the plugin names and formats notes,
never the daemon. Every allow-listed message gets a reaction lifecycle:
👀 received → 👌 queued/started, or 😱 + a reply saying what went wrong.

Keyword `status` short-circuits routing and replies with a live report
(branches + FE/BE up/down) from system-scripts/status.py: scoped to the one
project when sent in its topic, all projects when sent anywhere else.

Config (all under $ORCH_HOME, default ~/.agent-orchestrator):
  telegram.env   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ALLOWLIST (space/comma ids),
                 MAW_SCRIPTS (path to the machines-at-work plugin's scripts/, for 🚀)
  registry.json  {"<thread_id>": {"name": ..., "workspace": "/abs/scaffold-dir"}}
  offset         last processed update_id (persisted, so restarts don't replay)
  run/           <name>.{plan,loop}.{pid,log} — double-launch guard + child logs

Run:  server-orchestrator/daemon.py            # long-poll forever (systemd unit ships alongside)
      server-orchestrator/daemon.py --once     # drain pending updates and exit (for verifying)
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ORCH_HOME = os.environ.get("ORCH_HOME", os.path.expanduser("~/.agent-orchestrator"))
ENV_FILE = os.environ.get("TELEGRAM_ENV", os.path.join(ORCH_HOME, "telegram.env"))
REGISTRY = os.path.join(ORCH_HOME, "registry.json")
OFFSET_FILE = os.path.join(ORCH_HOME, "offset")
RUN_DIR = os.path.join(ORCH_HOME, "run")
TRANSCRIBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcribe.sh")
STATUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-scripts", "status.py")

# Exact-match trigger tokens (Decision #10). Matching is on the stripped,
# case-folded message text — "plan" inside a sentence never fires.
TRIGGERS = {"🧠": "plan", "plan": "plan", "🚀": "loop", "build-all": "loop"}


def log(msg):
    print(f"[daemon] {msg}", flush=True)


def load_env(path):
    env = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def load_registry():
    return json.load(open(REGISTRY)) if os.path.exists(REGISTRY) else {}


def read_offset():
    try:
        return int(open(OFFSET_FILE).read().strip())
    except (OSError, ValueError):
        return 0


def write_offset(n):
    tmp = OFFSET_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(n))
    os.replace(tmp, OFFSET_FILE)  # atomic: a crash never leaves a torn offset


class TelegramAPI:
    def __init__(self, token):
        self.base = f"https://api.telegram.org/bot{token}"

    def _call(self, method, params=None, timeout=60):
        data = urllib.parse.urlencode(params).encode() if params else None
        with urllib.request.urlopen(f"{self.base}/{method}", data=data, timeout=timeout) as r:
            return json.load(r)

    def get_updates(self, offset, timeout=30):
        # read timeout must clear the long-poll window with margin for network latency
        # spikes; a tight +15 buffer logged ~1 spurious "read timed out" per hour.
        r = self._call("getUpdates", {"offset": offset, "timeout": timeout}, timeout=timeout + 30)
        return r.get("result", [])

    def send_message(self, chat_id, text, thread_id=None):
        p = {"chat_id": chat_id, "text": text}
        if thread_id is not None:
            p["message_thread_id"] = thread_id
        return self._call("sendMessage", p)

    def set_reaction(self, chat_id, message_id, emoji):
        # Bots may only react with Telegram's fixed emoji set (no ✅/⚠️/⏳ —
        # hence 👀/👌/😱). Calling again replaces the previous reaction.
        return self._call("setMessageReaction", {
            "chat_id": chat_id, "message_id": message_id,
            "reaction": json.dumps([{"type": "emoji", "emoji": emoji}]),
        })

    def download_voice(self, file_id, dest):
        path = self._call("getFile", {"file_id": file_id})["result"]["file_path"]
        url = f"{self.base.replace('/bot', '/file/bot')}/{path}"
        urllib.request.urlretrieve(url, dest)
        return dest


def transcribe(path):
    out = subprocess.run([TRANSCRIBE, path], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "transcribe failed")
    return out.stdout.strip()


def status_report(workspace=None):
    """Run the status collector; its stdout is the Telegram reply. A workspace
    scopes the report to that one project (used when `status` lands in a project
    topic); None reports on all of them."""
    cmd = [sys.executable, STATUS] + ([workspace] if workspace else [])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return f"⚠️ status failed: {out.stderr.strip() or 'unknown error'}"
    return out.stdout.strip() or "(no status)"


def write_inbox(workspace, text, msg):
    """Raw drop per machines-at-work's inbound.sh contract (its DESIGN #27):
    updates/.inbox/<epoch>-<msgid>.md, lexical = chronological. Naming and
    formatting the note it becomes is the plugin's business, not ours."""
    inbox = os.path.join(workspace, "updates", ".inbox")
    os.makedirs(inbox, exist_ok=True)
    name = f"{msg['date']}-{msg['message_id']}.md"
    with open(os.path.join(inbox, name), "w") as f:
        f.write(text.rstrip("\n") + "\n")
    return name


def pid_alive(pidfile):
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False  # stale pidfile: the process is gone, proceed


def spawn_detached(cmd, cwd, base):
    """Start cmd detached (survives the daemon), log + pidfile under RUN_DIR."""
    os.makedirs(RUN_DIR, exist_ok=True)
    logf = open(os.path.join(RUN_DIR, base + ".log"), "ab")
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
    with open(os.path.join(RUN_DIR, base + ".pid"), "w") as f:
        f.write(str(p.pid))
    return p.pid


def dispatch(action, entry, cfg, api, thread_id, react, fail):
    """Launch a trigger's process. 👌 means STARTED — completion reaches the
    topic via the workspace's own notify.sh, not the daemon."""
    name, workspace = entry["name"], entry["workspace"]
    if action == "loop":
        scripts = cfg.get("maw_scripts")
        if not scripts:
            return fail("skip: MAW_SCRIPTS unset",
                        "MAW_SCRIPTS is not set in telegram.env — can't launch loop.sh")
        cmd, ack = [os.path.join(scripts, "loop.sh")], "🚀 loop started"
    else:
        cmd, ack = ["claude", "-p", "/machines-at-work:plan headless"], "🧠 planning…"
    base = f"{name}.{action}"
    if pid_alive(os.path.join(RUN_DIR, base + ".pid")):
        return fail(f"skip: {action} already running for {name}", f"{action} is already running")
    try:
        pid = spawn_detached(cmd, workspace, base)
    except OSError as e:
        return fail(f"error: spawn {action} failed: {e}", f"couldn't start {action}: {e}")
    api.send_message(cfg["chat_id"], ack, thread_id)
    react("👌")
    return f"{action} started for {name} (pid {pid})"


def process_message(msg, cfg, registry, api):
    """Handle one Telegram message; return a one-line status for the log.

    Allowlist is checked FIRST — before any reaction, download, transcription,
    or routing (Decision #4: the allowlist is the whole security model). A
    stranger gets no reaction: probing the bot must teach nothing."""
    sender = str(msg.get("from", {}).get("id", ""))
    if sender not in cfg["allowlist"]:
        return f"drop: sender {sender or '?'} not allow-listed"

    thread_id = msg.get("message_thread_id")

    def react(emoji):
        try:
            api.set_reaction(msg["chat"]["id"], msg["message_id"], emoji)
        except Exception as e:  # a failed reaction never blocks processing
            log(f"reaction failed (non-fatal): {e}")

    def fail(reason, reply):
        react("😱")
        api.send_message(cfg["chat_id"], f"⚠️ {reply}", thread_id)
        return reason

    react("👀")
    try:
        return _route(msg, cfg, registry, api, thread_id, react, fail)
    except Exception as e:  # whatever broke, the message must not stay at 👀
        return fail(f"error: {e}", str(e))


def _route(msg, cfg, registry, api, thread_id, react, fail):
    entry = registry.get(str(thread_id))
    stripped = msg.get("text", "").strip().lower()

    # `status` keyword: reply into the topic it came from. In a project topic it
    # reports just that project; anywhere else (General, unregistered) it reports
    # all of them. Runs before the note-routing path — it never writes a note.
    if stripped == "status":
        api.send_message(cfg["chat_id"], status_report(entry["workspace"] if entry else None), thread_id)
        react("👌")
        return f"status report sent ({entry['name'] if entry else 'all'})"

    if not entry:
        return fail(f"skip: no workspace registered for topic {thread_id}",
                    "this topic isn't registered to a project")
    workspace = entry["workspace"]
    if not os.path.isdir(workspace):
        return fail(f"skip: workspace {workspace} missing (registry drift)",
                    f"registered workspace is missing: {workspace}")

    action = TRIGGERS.get(stripped)
    if action:
        return dispatch(action, entry, cfg, api, thread_id, react, fail)

    if "voice" in msg:
        kind = "voice"
        fd, dest = tempfile.mkstemp(suffix=".oga")
        os.close(fd)
        try:
            api.download_voice(msg["voice"]["file_id"], dest)
            text = transcribe(dest)
        finally:
            if os.path.exists(dest):
                os.remove(dest)
        if not text:
            return fail("voice: empty transcript", "could not transcribe that voice note")
        # quote the transcript back: the reaction says "queued", the quote is
        # the only way to catch a mis-transcription before it becomes a task
        api.send_message(cfg["chat_id"], f"🎙 > {text}", thread_id)
    elif "text" in msg:
        kind, text = "text", msg["text"]
    else:
        return fail("skip: unsupported message type", "only voice notes and text are supported")

    name = write_inbox(workspace, text, msg)
    react("👌")
    return f"queued {kind} → {entry['name']}/updates/.inbox/{name}"


def build_config(env):
    token = env.get("TELEGRAM_BOT_TOKEN")
    if not token:
        sys.exit(f"no TELEGRAM_BOT_TOKEN in {ENV_FILE}")
    allowlist = {x for x in env.get("ALLOWLIST", "").replace(",", " ").split()}
    if not allowlist:
        sys.exit("ALLOWLIST empty — refusing to start. The allowlist is the whole "
                 "security model (Decision #4); add ALLOWLIST=<your telegram user id> "
                 f"to {ENV_FILE}.")
    return {"token": token, "chat_id": env.get("TELEGRAM_CHAT_ID"),
            "allowlist": allowlist, "maw_scripts": env.get("MAW_SCRIPTS")}


def run(once=False):
    cfg = build_config(load_env(ENV_FILE))
    api = TelegramAPI(cfg["token"])
    log(f"up · {len(load_registry())} topic(s) registered · allowlist {sorted(cfg['allowlist'])}")
    offset = read_offset()
    while True:
        try:
            updates = api.get_updates(offset)
        except Exception as e:  # tolerant like notify.sh — a dead network never kills the daemon
            log(f"getUpdates error: {e}; retrying in 5s")
            time.sleep(5)
            continue
        for u in updates:
            offset = u["update_id"] + 1
            msg = u.get("message")
            if msg:
                try:
                    # reload registry per message: a newly-registered topic works without a restart
                    log(process_message(msg, cfg, load_registry(), api))
                except Exception as e:
                    log(f"error on update {u['update_id']}: {e}")
            write_offset(offset)
        if once:
            return


if __name__ == "__main__":
    run(once="--once" in sys.argv[1:])
