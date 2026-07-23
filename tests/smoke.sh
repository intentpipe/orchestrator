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
    def __init__(self): self.sent = []; self.reactions = []; self._mid = 0
    def send_message(self, chat, text, thread_id=None):
        self.sent.append((thread_id, text)); self._mid += 1
        return {"result": {"message_id": self._mid}}  # offer_checkout keys the map on this
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
# General / unregistered topic: a non-command message is a free-form instruction
# answered by `claude -p`. With GENERAL_WORKSPACE unset it must fail loudly (config
# error) — 👀 then 😱 + a reply naming the missing key — like MAW_SCRIPTS for 🚀.
assert daemon.process_message(mk(text="x", message_thread_id=77), cfg, reg, api).startswith("skip: GENERAL_WORKSPACE unset")
assert api.reactions == [(1, "👀"), (1, "😱")] and "GENERAL_WORKSPACE" in api.sent[-1][1]
# GENERAL_WORKSPACE set: stub the one-shot run; the message text is piped to
# claude -p in that cwd, its output posts back into General (thread 77), 👀→👌.
gws = os.path.join(tmp, "gws"); os.makedirs(gws)
gcfg = {**cfg, "general_workspace": gws}
runs = []
daemon.run_general = lambda prompt, cwd: runs.append((prompt, cwd)) or f"ran:{prompt}"
api = FakeAPI()
assert daemon.process_message(mk(text="show branches with open PRs", message_thread_id=77, mid=20), gcfg, reg, api).startswith("general text → claude -p")
assert runs[-1] == ("show branches with open PRs", gws), runs
assert api.sent[-1] == (77, "ran:show branches with open PRs") and api.reactions == [(20, "👀"), (20, "👌")]
# voice in General: transcribe (stubbed) → quote it back → claude -p on the transcript
daemon.transcribe = lambda p: "update all projects"
api = FakeAPI()
assert daemon.process_message(mk(voice={"file_id": "v"}, message_thread_id=77, mid=21), gcfg, reg, api).startswith("general voice → claude -p")
assert api.sent[0] == (77, "🎙 > update all projects") and runs[-1][0] == "update all projects"
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
assert daemon.process_message(mk(photo=[{"file_id": "p"}], mid=9), cfg, reg, api).startswith("skip: only voice notes")
assert api.reactions[-1] == (9, "😱") and "voice notes and text" in api.sent[-1][1]

# trigger tokens: exact match only, dispatch instead of note. Stub the spawner.
spawns = []
daemon.spawn_detached = lambda cmd, cwd, base, track=None: spawns.append((cmd, cwd, base)) or 4242
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="🧠", mid=10), cfg, reg, api) == "plan started for proj (pid 4242)"
assert spawns[-1] == (["claude", "-p", "/machines-at-work:plan headless", *daemon.PLAN_CLAUDE_FLAGS], ws, "proj.plan")
assert "--permission-mode" in spawns[-1][0] and "Bash" in " ".join(spawns[-1][0]), "headless plan must run non-interactively"
assert api.reactions == [(10, "👀"), (10, "👌")] and api.sent[-1][1] == "🧠 planning…"
assert daemon.process_message(mk(text=" PLAN ", mid=11), cfg, reg, api).startswith("plan started"), "case/whitespace-insensitive"
assert daemon.process_message(mk(text="build-all", mid=12), cfg, reg, api).startswith("loop started")
assert spawns[-1][0] == ["/opt/maw/scripts/loop.sh"] and spawns[-1][2] == "proj.loop"
# 🩹/unblock: headless /machines-at-work:unblock, own pidfile, non-interactive flags
assert daemon.process_message(mk(text="🩹", mid=120), cfg, reg, api).startswith("unblock started for proj")
assert spawns[-1][0] == ["claude", "-p", "/machines-at-work:unblock headless", *daemon.PLAN_CLAUDE_FLAGS] and spawns[-1][2] == "proj.unblock"
assert api.sent[-1][1] == "🩹 unblocking…"
assert daemon.process_message(mk(text="unblock", mid=121), cfg, reg, api).startswith("unblock started"), "word form triggers too"
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

# `pull-all`: short-circuits like status (writes no note), works in any topic,
# passes MAW_SCRIPTS through so the scaffold repo is pulled too. Stub the runner.
pcalls = []
daemon.pull_report = lambda maw=None: pcalls.append(maw) or "📥 pull-all\n(stub)"
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="pull-all", mid=18), cfg, reg, api) == "pull-all done"
assert pcalls[-1] == "/opt/maw/scripts" and api.sent[-1] == (5, "📥 pull-all\n(stub)")
assert api.reactions == [(18, "👀"), (18, "👌")] and ls() == before, "pull-all must not write a note"
# case/space-insensitive, and fine from a topic with no workspace (fleet-wide)
assert daemon.process_message(mk(text=" PULL ALL ", message_thread_id=77, mid=19), cfg, reg, api) == "pull-all done"

# `help`: lists every command. Short-circuits like status/pull-all — replies into
# its topic, writes no note, works in a project topic and in General alike.
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="help", mid=22), cfg, reg, api) == "help sent"
assert api.sent[-1][0] == 5 and "status" in api.sent[-1][1] and "pull-all" in api.sent[-1][1]
assert "plan" in api.sent[-1][1] and "build-all" in api.sent[-1][1] and "unblock" in api.sent[-1][1], "help must list the triggers"
assert api.reactions == [(22, "👀"), (22, "👌")] and ls() == before, "help must not write a note"
# case-insensitive, accepts /help, and works from a workspace-less topic
assert daemon.process_message(mk(text=" HELP ", message_thread_id=77, mid=23), cfg, reg, api) == "help sent"
assert daemon.process_message(mk(text="/help", message_thread_id=77, mid=24), cfg, reg, api) == "help sent"

# `checkout`: post one message per option, remember message_id→offer, react 👌,
# write no note. Stub the enumerator (no gh/git) and point OFFERS_FILE at the tmp
# RUN_DIR (it's derived from RUN_DIR at import, before the test repointed RUN_DIR).
daemon.OFFERS_FILE = os.path.join(daemon.RUN_DIR, "checkout_offers.json")
opts = {"name": "proj", "workspace": ws, "default": "dev", "options": [
    {"label": "dev (baseline)", "branches": {"app_mobile": "dev", "core": "dev"}, "prs": []},
    {"label": "feat/x", "branches": {"app_mobile": "feat/x", "core": "dev"},
     "prs": [{"repo": "app_mobile", "number": 7, "title": "Add X", "url": "u"}]},
]}
daemon.checkout_options = lambda w: opts
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="checkout", mid=30), cfg, reg, api) == "checkout offered for proj (2 option(s))"
assert len(api.sent) == 3 and all(s[0] == 5 for s in api.sent), api.sent  # intro + 2 options, all in-topic
assert "feat/x" in api.sent[-1][1] and "app_mobile: feat/x" in api.sent[-1][1] and "PR #7" in api.sent[-1][1]
assert api.reactions == [(30, "👀"), (30, "👌")] and ls() == before, "checkout writes no note"
offers = daemon.load_offers()
assert len(offers) == 2 and all(o["topic"] == 5 for o in offers.values()), offers
opt_mid = int(next(m for m, o in offers.items() if o["label"] == "feat/x"))

# reaction on an offer message → check out + build (stub the detached spawner)
builds = []
daemon.build_checkout = lambda offer: builds.append(offer) or 555
mkr = lambda **kw: {"user": {"id": kw.pop("uid", 42)}, "message_id": kw.pop("mid", 1),
                    "new_reaction": kw.pop("new", [{"type": "emoji", "emoji": "👍"}]), **kw}
api = FakeAPI()
assert daemon.process_reaction(mkr(mid=opt_mid), cfg, api).startswith("checkout+build started for proj [feat/x]")
assert builds and builds[-1]["branches"] == {"app_mobile": "feat/x", "core": "dev"}, builds
assert api.sent[-1][0] == 5 and "checking out [feat/x]" in api.sent[-1][1]
# stranger's reaction, a cleared reaction, and a reaction on an unknown message all do nothing
api = FakeAPI(); builds.clear()
assert daemon.process_reaction(mkr(mid=opt_mid, uid=9), cfg, api).startswith("drop reaction")
assert daemon.process_reaction(mkr(mid=opt_mid, new=[]), cfg, api) == "reaction removed, ignored"
assert daemon.process_reaction(mkr(mid=999999), cfg, api).startswith("reaction on non-offer message")
assert not builds and not api.sent, "dropped/ignored reactions: no build, no post"

# `relaunch`: project-scoped, spawns the relaunch script detached, 👀→👌, no note.
# In a topic with no workspace it refuses with guidance rather than a claude run.
api = FakeAPI(); before = ls(); spawns.clear()
assert daemon.process_message(mk(text="relaunch", mid=40), cfg, reg, api).startswith("relaunch started for proj")
assert spawns[-1] == ([daemon.RELAUNCH, "proj"], os.path.dirname(daemon.RELAUNCH), "proj.relaunch")
assert api.reactions == [(40, "👀"), (40, "👌")] and ls() == before, "relaunch writes no note"
assert "relaunching proj" in api.sent[-1][1]
# in General (no workspace) → refused, no spawn
n = len(spawns)
assert daemon.process_message(mk(text="relaunch", message_thread_id=77, mid=41), cfg, reg, api).startswith("skip: relaunch needs a project topic")
assert len(spawns) == n and "project topic" in api.sent[-1][1]

# reap_jobs: post ✅ on success, 😱 + log tail on non-zero exit OR a rejection in
# the log (even if it exited 0), and leave still-running jobs untouched.
class FakePopen:
    def __init__(self, rc): self._rc = rc
    def poll(self): return self._rc
def _job(pname, rc, logtext):
    lp = os.path.join(tmp, pname + ".joblog"); open(lp, "w").write(logtext)
    return {"popen": FakePopen(rc), "log": lp, "name": pname, "action": "plan", "topic": 5}
api = FakeAPI()
daemon._JOBS[:] = [
    _job("okproj", 0, "planned 3 tasks\nall good"),
    _job("failproj", 1, "boom\nTraceback (most recent call last)"),
    _job("blockedproj", 0, "step 2\nThis command requires approval\n(denied)"),
    {"popen": FakePopen(None), "log": "/nope", "name": "running", "action": "loop", "topic": 9},
]
daemon.reap_jobs(cfg, api)
assert len(daemon._JOBS) == 1 and daemon._JOBS[0]["name"] == "running", daemon._JOBS  # unfinished stays
texts = [t for _, t in api.sent]
assert any(t.startswith("✅ plan for okproj finished") for t in texts), texts       # success
assert any(t.startswith("😱 plan for failproj") and "boom" in t for t in texts), texts  # crash
assert any(t.startswith("😱 plan for blockedproj") and "blocked" in t for t in texts), texts  # exit 0 but rejected
assert len(texts) == 3, texts  # the running job posted nothing
daemon._JOBS[:] = []
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
