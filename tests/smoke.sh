#!/usr/bin/env bash
# Smoke test for the server-orchestrator daemon — the whole per-message contract
# of process_message, plus the status collector. Network, transcription, and the
# status subprocess are stubbed; no Telegram, no git, no ports touched.
set -euo pipefail
ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- daemon.process_message: allowlist gate, topic routing, note into updates/,
# reply into the topic, and the `status` keyword (topic-scoped vs. all-projects).
python3 - "$ORCH" "$TMP" <<'PY' || fail "daemon process_message checks failed"
import os, sys
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, orch)
import daemon
ws = os.path.join(tmp, "dws", "scaffold"); os.makedirs(ws)
cfg = {"chat_id": "-100", "allowlist": {"42"}}
reg = {"5": {"name": "proj", "workspace": ws}}
class FakeAPI:
    def __init__(self): self.sent = []
    def send_message(self, chat, text, thread_id=None): self.sent.append((thread_id, text))
    def download_voice(self, fid, dest): open(dest, "wb").write(b"x")
api = FakeAPI()
mk = lambda **kw: {"from": {"id": 42}, "message_thread_id": 5, **kw}

# allowlist is the whole security model: a stranger is dropped with no reply
assert daemon.process_message({"from": {"id": 9}, "message_thread_id": 5, "text": "hi"}, cfg, reg, api).startswith("drop")
assert not api.sent, "stranger must get no reply"
# a topic with no registered workspace is skipped
assert daemon.process_message(mk(text="x", message_thread_id=77), cfg, reg, api).startswith("skip: no workspace")
# text → note in updates/ + "Noted" reply into the topic
assert daemon.process_message(mk(text="add dark mode"), cfg, reg, api).startswith("routed text")
fs = os.listdir(os.path.join(ws, "updates"))
assert len(fs) == 1 and fs[0].endswith("-text.md"), fs
assert "add dark mode" in open(os.path.join(ws, "updates", fs[0])).read()
assert api.sent[-1][0] == 5 and "Noted" in api.sent[-1][1]
# voice → transcribed (stubbed) → note
daemon.transcribe = lambda p: "hello from voice"
assert daemon.process_message(mk(voice={"file_id": "a"}), cfg, reg, api).startswith("routed voice")
assert any(f.endswith("-voice.md") for f in os.listdir(os.path.join(ws, "updates")))

# `status` keyword: short-circuits routing (writes no note), replies into its
# topic, and is workspace-scoped by topic. Stub status_report to capture its arg.
calls = []
daemon.status_report = lambda workspace=None: calls.append(workspace) or f"REPORT:{workspace}"
before = len(os.listdir(os.path.join(ws, "updates")))
# in the project's own topic → scoped to that workspace
assert daemon.process_message(mk(text="status"), cfg, reg, api) == "status report sent (proj)"
assert calls[-1] == ws, calls
assert api.sent[-1] == (5, f"REPORT:{ws}")
# in a topic with no workspace → all projects (workspace None)
assert daemon.process_message(mk(text="STATUS", message_thread_id=77), cfg, reg, api) == "status report sent (all)"
assert calls[-1] is None, calls
assert len(os.listdir(os.path.join(ws, "updates"))) == before, "status must not write a note"
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
