#!/usr/bin/env python3
"""Inbound Telegram daemon — the scaffold's voice/text control plane (Phase 2).

Standalone server-side control plane, above any single workspace/project — a
separate project from the scaffold it feeds, not part of it. Architecture +
rationale: DESIGN.md (alongside this file).

Long-poll getUpdates → enforce the allowlist (the only door, Decision #4) →
resolve the message's forum topic to a workspace via the registry → transcribe
voice (or take text) → drop the note into <workspace>/updates/<ts>.md → reply
into the topic. That is the whole job: it feeds the existing inbound door and
confirms. Planning / approval-reply / detached loop.sh are Phase 3.

Keyword `status` short-circuits routing and replies with a live report
(branches + FE/BE up/down) from system-scripts/status.py: scoped to the one
project when sent in its topic, all projects when sent anywhere else.

Config (all under $ORCH_HOME, default ~/.agent-orchestrator):
  telegram.env   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ALLOWLIST (space/comma ids)
  registry.json  {"<thread_id>": {"name": ..., "workspace": "/abs/scaffold-dir"}}
  offset         last processed update_id (persisted, so restarts don't replay)

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
TRANSCRIBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcribe.sh")
STATUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-scripts", "status.py")


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
        r = self._call("getUpdates", {"offset": offset, "timeout": timeout}, timeout=timeout + 15)
        return r.get("result", [])

    def send_message(self, chat_id, text, thread_id=None):
        p = {"chat_id": chat_id, "text": text}
        if thread_id is not None:
            p["message_thread_id"] = thread_id
        return self._call("sendMessage", p)

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


def ts_utc():
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def write_note(workspace, text, kind, when):
    updates = os.path.join(workspace, "updates")
    os.makedirs(updates, exist_ok=True)
    name = f"{when}-{kind}.md"
    header = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    with open(os.path.join(updates, name), "w") as f:
        f.write(f"# Telegram {kind} note · {header}\n\n{text}\n")
    return name


def process_message(msg, cfg, registry, api):
    """Handle one Telegram message; return a one-line status for the log.

    Allowlist is checked FIRST — before any download, transcription, or routing
    (Decision #4: the allowlist is the whole security model)."""
    sender = str(msg.get("from", {}).get("id", ""))
    if sender not in cfg["allowlist"]:
        return f"drop: sender {sender or '?'} not allow-listed"

    thread_id = msg.get("message_thread_id")
    entry = registry.get(str(thread_id))

    # `status` keyword: reply into the topic it came from. In a project topic it
    # reports just that project; anywhere else (General, unregistered) it reports
    # all of them. Runs before the note-routing path — it never writes a note.
    if msg.get("text", "").strip().lower() == "status":
        api.send_message(cfg["chat_id"], status_report(entry["workspace"] if entry else None), thread_id)
        return f"status report sent ({entry['name'] if entry else 'all'})"

    if not entry:
        return f"skip: no workspace registered for topic {thread_id}"
    workspace = entry["workspace"]
    if not os.path.isdir(workspace):
        return f"skip: workspace {workspace} missing (registry drift)"

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
            api.send_message(cfg["chat_id"], "⚠️ Could not transcribe that voice note.", thread_id)
            return "voice: empty transcript"
    elif "text" in msg:
        kind, text = "text", msg["text"]
    else:
        api.send_message(cfg["chat_id"], "Only voice notes and text are supported.", thread_id)
        return "skip: unsupported message type"

    name = write_note(workspace, text, kind, when=ts_utc())
    api.send_message(cfg["chat_id"], f"📝 Noted → updates/{name}\n\n> {text}", thread_id)
    return f"routed {kind} → {entry['name']}/updates/{name}"


def build_config(env):
    token = env.get("TELEGRAM_BOT_TOKEN")
    if not token:
        sys.exit(f"no TELEGRAM_BOT_TOKEN in {ENV_FILE}")
    allowlist = {x for x in env.get("ALLOWLIST", "").replace(",", " ").split()}
    if not allowlist:
        sys.exit("ALLOWLIST empty — refusing to start. The allowlist is the whole "
                 "security model (Decision #4); add ALLOWLIST=<your telegram user id> "
                 f"to {ENV_FILE}.")
    return {"token": token, "chat_id": env.get("TELEGRAM_CHAT_ID"), "allowlist": allowlist}


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
