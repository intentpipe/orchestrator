#!/usr/bin/env bash
# Smoke test for the server-orchestrator daemon — the whole per-message contract
# of process_message, plus the status collector. Network, transcription, and the
# status subprocess are stubbed; no Telegram, no git, no ports touched.
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- daemon.process_message: allowlist gate, reaction lifecycle (👀→👌/😱),
# raw drops into updates/.inbox/ (inbound.sh contract), trigger tokens
# (🧠 plan · 🚀 build-all), and the `status` keyword (topic-scoped vs. all).
python3 - "$ORCH" "$TMP" <<'PY' || fail "daemon process_message checks failed"
import os, sys
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, orch)
import daemon
daemon.RUN_DIR = os.path.join(tmp, "run")
ws = os.path.join(tmp, "dws", "scaffold"); os.makedirs(ws)
cfg = {"chat_id": "-100", "allowlist": {"42"}, "maw_scripts": "/opt/maw/scripts"}
reg = {"5": {"name": "proj", "workspace": ws}}
class FakeAPI:
    def __init__(self): self.sent = []; self.reactions = []
    def send_message(self, chat, text, thread_id=None): self.sent.append((thread_id, text))
    def set_reaction(self, chat, mid, emoji): self.reactions.append((mid, emoji))
    def download_voice(self, fid, dest): open(dest, "wb").write(b"x")
api = FakeAPI()
mk = lambda **kw: {"from": {"id": 42}, "chat": {"id": -100}, "message_id": kw.pop("mid", 1),
                   "date": kw.pop("date", 1700000000), "message_thread_id": 5, **kw}
inbox = os.path.join(ws, "updates", ".inbox")
ls = lambda: sorted(os.listdir(inbox)) if os.path.isdir(inbox) else []

# allowlist is the whole security model: a stranger gets no reply AND no reaction
assert daemon.process_message({"from": {"id": 9}, "message_thread_id": 5, "text": "hi"}, cfg, reg, api).startswith("drop")
assert not api.sent and not api.reactions, "stranger must get no reply and no reaction"
# unregistered topic: 👀 then 😱 + a reply naming the problem, no inbox file
assert daemon.process_message(mk(text="x", message_thread_id=77), cfg, reg, api).startswith("skip: no workspace")
assert api.reactions == [(1, "👀"), (1, "😱")] and "registered" in api.sent[-1][1]
# text → RAW drop at updates/.inbox/<epoch>-<msgid>.md, 👀→👌, NO reply text
api = FakeAPI()
assert daemon.process_message(mk(text="add dark mode", date=1700000001, mid=7), cfg, reg, api).startswith("queued text")
assert ls() == ["1700000001-7.md"], ls()
assert open(os.path.join(inbox, "1700000001-7.md")).read() == "add dark mode\n", "must be raw — no header, plugin owns format"
assert api.reactions == [(7, "👀"), (7, "👌")] and not api.sent, "text note: reaction only, no reply"
# voice → transcribed (stubbed) → raw drop + transcript quoted back
daemon.transcribe = lambda p: "hello from voice"
assert daemon.process_message(mk(voice={"file_id": "a"}, date=1700000002, mid=8), cfg, reg, api).startswith("queued voice")
assert "1700000002-8.md" in ls() and "hello from voice" in open(os.path.join(inbox, "1700000002-8.md")).read()
assert api.sent[-1] == (5, "🎙 > hello from voice")
# unsupported type (photo etc.) → 😱 + reply
api = FakeAPI()
assert daemon.process_message(mk(photo=[{"file_id": "p"}], mid=9), cfg, reg, api).startswith("skip: unsupported")
assert api.reactions[-1] == (9, "😱") and "voice notes and text" in api.sent[-1][1]

# trigger tokens: exact match only, dispatch instead of note. Stub the spawner.
spawns = []
daemon.spawn_detached = lambda cmd, cwd, base: spawns.append((cmd, cwd, base)) or 4242
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="🧠", mid=10), cfg, reg, api) == "plan started for proj (pid 4242)"
assert spawns[-1] == (["claude", "-p", "/machines-at-work:plan headless"], ws, "proj.plan")
assert api.reactions == [(10, "👀"), (10, "👌")] and api.sent[-1][1] == "🧠 planning…"
assert daemon.process_message(mk(text=" PLAN ", mid=11), cfg, reg, api).startswith("plan started"), "case/whitespace-insensitive"
assert daemon.process_message(mk(text="build-all", mid=12), cfg, reg, api).startswith("loop started")
assert spawns[-1][0] == ["/opt/maw/scripts/loop.sh"] and spawns[-1][2] == "proj.loop"
assert ls() == before, "triggers must not write inbox files"
# a token inside a sentence is a note, not a trigger
n = len(spawns)
assert daemon.process_message(mk(text="let's plan this later", date=1700000003, mid=13), cfg, reg, api).startswith("queued text")
assert len(spawns) == n and "1700000003-13.md" in ls()
# live pidfile → "already running", no second spawn
os.makedirs(daemon.RUN_DIR, exist_ok=True)
open(os.path.join(daemon.RUN_DIR, "proj.loop.pid"), "w").write(str(os.getpid()))
api = FakeAPI()
assert daemon.process_message(mk(text="🚀", mid=14), cfg, reg, api).startswith("skip: loop already running")
assert len(spawns) == n and api.reactions[-1] == (14, "😱") and "already running" in api.sent[-1][1]
# MAW_SCRIPTS unset → 🚀 fails with a config error, never a silent no-op
assert daemon.process_message(mk(text="🚀", mid=15), {**cfg, "maw_scripts": None}, reg, api).startswith("skip: MAW_SCRIPTS")
assert "MAW_SCRIPTS" in api.sent[-1][1]

# `status` keyword: short-circuits routing (writes no note), replies into its
# topic, and is workspace-scoped by topic. Stub status_report to capture its arg.
calls = []
daemon.status_report = lambda workspace=None: calls.append(workspace) or f"REPORT:{workspace}"
api = FakeAPI(); before = ls()
# in the project's own topic → scoped to that workspace
assert daemon.process_message(mk(text="status", mid=16), cfg, reg, api) == "status report sent (proj)"
assert calls[-1] == ws, calls
assert api.sent[-1] == (5, f"REPORT:{ws}") and api.reactions == [(16, "👀"), (16, "👌")]
# in a topic with no workspace → all projects (workspace None)
assert daemon.process_message(mk(text="STATUS", message_thread_id=77, mid=17), cfg, reg, api) == "status report sent (all)"
assert calls[-1] is None, calls
assert ls() == before, "status must not write a note"
PY
echo "[smoke] daemon process_message ok"

# --- status.py builds a report from a stub registry + ports.json, and scopes to
# one workspace when asked. No git repos / no live ports needed to exercise it.
python3 - "$ORCH" "$TMP" <<'PY' || fail "status.py checks failed"
import json, os, sys
orch, tmp = sys.argv[1], sys.argv[2]
home = os.path.join(tmp, "orch"); os.makedirs(home)
a = os.path.join(tmp, "a", "scaffold"); os.makedirs(a)
b = os.path.join(tmp, "b", "scaffold"); os.makedirs(b)
open(os.path.join(a, "agents.env"), "w").write('REPOS="be"\nREPO_be=../be\n')
open(os.path.join(b, "agents.env"), "w").write('REPOS="be"\nREPO_be=../be\n')
json.dump({"1": {"name": "alpha", "workspace": a}, "2": {"name": "beta", "workspace": b}},
          open(os.path.join(home, "registry.json"), "w"))
os.environ["ORCH_HOME"] = home
sys.path.insert(0, os.path.join(orch, "system-scripts"))
import status
full = status.build_report()
assert "alpha" in full and "beta" in full, full
one = status.build_report(a)
assert "alpha" in one and "beta" not in one, one
assert "No project registered" in status.build_report("/nope")

# _svc maps probe state -> icon. The regression this guards: a bound-but-500
# service must NOT read as up (that false 🟢 is what hid a broken frontend).
status._probe = lambda port, path="/": ("up", 200)
assert "🟢" in status._svc({"backend": 8810}, "backend")
status._probe = lambda port, path="/": ("erroring", 500)
line = status._svc({"frontend": {"port": 3031, "health": "/"}}, "frontend")
assert "🟠" in line and "(500)" in line, line
status._probe = lambda port, path="/": ("down", None)
assert "🔴" in status._svc({"backend": 8810}, "backend")
assert status._svc({}, "backend") == "backend: n/a"
PY
echo "[smoke] status.py ok"

echo "SMOKE OK"
