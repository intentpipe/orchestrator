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
cfg = {"chat_id": "-100", "allowlist": {"42"}, "maw_scripts": "/opt/maw/scripts",
       "plan_model": "claude-fable-5"}  # mirrors build_config's default
reg = {"5": {"name": "proj", "workspace": ws}}
class FakeAPI:
    def __init__(self): self.sent = []; self.reactions = []; self._mid = 0
    def send_message(self, chat, text, thread_id=None):
        self.sent.append((thread_id, text)); self._mid += 1
        return {"result": {"message_id": self._mid}}  # offer_checkout keys the map on this
    def set_reaction(self, chat, mid, emoji): self.reactions.append((mid, emoji))
    def download_voice(self, fid, dest): open(dest, "wb").write(b"x")
    def download_file(self, fid, base, ext=None):
        self.downloads = getattr(self, "downloads", []); self.downloads.append((fid, ext))
        p = base + (ext or ".jpg"); open(p, "wb").write(b"img"); return p
api = FakeAPI()
mk = lambda **kw: {"from": {"id": 42}, "chat": {"id": -100}, "message_id": kw.pop("mid", 1),
                   "date": kw.pop("date", 1700000000), "message_thread_id": 5, **kw}
inbox = os.path.join(ws, "updates", ".inbox")
ls = lambda: sorted(os.listdir(inbox)) if os.path.isdir(inbox) else []

# allowlist is the whole security model: a stranger gets no reply AND no reaction
assert daemon.process_message({"from": {"id": 9}, "message_thread_id": 5, "text": "hi"}, cfg, reg, api).startswith("drop")
assert not api.sent and not api.reactions, "stranger must get no reply and no reaction"
# A topic with no registered workspace has nowhere to put a note and nothing to
# run against, so a non-command message is refused — 👀 then 😱 — with the list of
# commands that DO work there. It must never run anything: this daemon has no
# interpretation path (Decision #11, reverted).
assert not hasattr(daemon, "run_general") and not hasattr(daemon, "general"), \
    "the free-form claude -p path must be gone, not merely unreachable"
assert daemon.process_message(mk(text="x", message_thread_id=77), cfg, reg, api) == "skip: no workspace for this topic"
assert api.reactions == [(1, "👀"), (1, "😱")], api.reactions
assert "no project" in api.sent[-1][1] and "status" in api.sent[-1][1], api.sent
assert api.sent[-1][0] == 77, "the refusal replies in the topic it came from"
# Voice there is refused the same way — no transcription, no spawn.
called = []
daemon.transcribe = lambda p: called.append(p) or "should not be reached"
api = FakeAPI()
assert daemon.process_message(mk(voice={"file_id": "v"}, message_thread_id=77, mid=21), cfg, reg, api) \
    == "skip: no workspace for this topic"
assert not called, "an unroutable message must not even be transcribed"
# The box-level commands still work there — removing the workspace path must not
# take `status`/`logmine`/`help` with it, since General is where they're used.
api = FakeAPI()
daemon.status_report = lambda ws=None: f"report(ws={ws})"
assert daemon.process_message(mk(text="status", message_thread_id=77, mid=22), cfg, reg, api) == "status report sent (all)"
assert api.sent[-1] == (77, "report(ws=None)") and api.reactions[-1] == (22, "👌")
api = FakeAPI()
assert daemon.process_message(mk(text="help", message_thread_id=77, mid=23), cfg, reg, api) == "help sent"
assert "logmine" in api.sent[-1][1] and "one-shot claude" not in api.sent[-1][1], "help must not advertise a removed feature"
# …and HELP must describe the acks it actually sends, now that they differ.
assert "✍" in api.sent[-1][1], "help must name the note reaction"
assert "no project" in api.sent[-1][1], "help must say what an unregistered topic does"
# text → RAW drop at updates/.inbox/<epoch>-<msgid>.md, 👀→✍, NO reply text.
# The note ack must be a DIFFERENT emoji from the command ack: the note path
# sends no reply, so while both were 👌 a swallowed message looked like a
# started run. Pinned to the literal — Telegram bots may only react from a
# fixed set, and it carries ✍ bare (U+270D), not ✍️ with the U+FE0F selector.
assert daemon.NOTED == "✍" and daemon.NOTED != "👌", repr(daemon.NOTED)
api = FakeAPI()
assert daemon.process_message(mk(text="add dark mode", date=1700000001, mid=7), cfg, reg, api).startswith("queued text")
assert ls() == ["1700000001-7.md"], ls()
assert open(os.path.join(inbox, "1700000001-7.md")).read() == "add dark mode\n", "must be raw — no header, plugin owns format"
assert api.reactions == [(7, "👀"), (7, daemon.NOTED)] and not api.sent, \
    "text note: reaction only, no reply — and ✍ not 👌, so a note never looks like a started trigger"
# voice → transcribed (stubbed) → raw drop + transcript quoted back
daemon.transcribe = lambda p: "hello from voice"
assert daemon.process_message(mk(voice={"file_id": "a"}, date=1700000002, mid=8), cfg, reg, api).startswith("queued voice")
assert "1700000002-8.md" in ls() and "hello from voice" in open(os.path.join(inbox, "1700000002-8.md")).read()
assert api.sent[-1] == (5, "🎙 > hello from voice")
# photo in a project topic → image + caption note dropped TOGETHER under the same
# <epoch>-<msgid> base, note referencing the image by bare basename — moving it to
# resources/ and rewriting the reference is inbound.sh's job, not the daemon's
api = FakeAPI()
assert daemon.process_message(mk(photo=[{"file_id": "small"}, {"file_id": "LARGE"}],
                                 caption="build this mockup", date=1700000005, mid=9),
                              cfg, reg, api).startswith("queued image")
assert api.downloads[-1][0] == "LARGE", "must fetch the largest photo size"
assert "1700000005-9.jpg" in ls() and "1700000005-9.md" in ls(), ls()
note = open(os.path.join(inbox, "1700000005-9.md")).read()
assert note == "build this mockup\n\n[image: 1700000005-9.jpg]\n", note
assert api.reactions == [(9, "👀"), (9, daemon.NOTED)] and not api.sent, "image note: reaction only, no reply"
# a screenshot sent as a FILE (image/* document) rides the same path, keeping its
# extension; a caption-less image still gets a note (the picture IS the intent)
assert daemon.process_message(mk(document={"file_id": "d", "mime_type": "image/png", "file_name": "shot.png"},
                                 date=1700000006, mid=90), cfg, reg, api).startswith("queued image")
assert "1700000006-90.png" in ls(), ls()
assert open(os.path.join(inbox, "1700000006-90.md")).read() == "[image: 1700000006-90.png]\n"
# unsupported type (non-image document etc.) → 😱 + reply
api = FakeAPI()
assert daemon.process_message(mk(document={"file_id": "z", "mime_type": "application/pdf"}, mid=91),
                              cfg, reg, api).startswith("skip: only voice notes")
assert api.reactions[-1] == (91, "😱") and "voice notes and text" in api.sent[-1][1]

# trigger tokens: exact match only, dispatch instead of note. Stub the spawner.
spawns = []
daemon.spawn_detached = lambda cmd, cwd, base, track=None: spawns.append((cmd, cwd, base)) or 4242
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="🧠", mid=10), cfg, reg, api) == "plan started for proj (pid 4242)"
assert spawns[-1] == (["claude", "-p", "/intentpipe:plan headless",
                       "--model", "claude-fable-5", *daemon.PLAN_CLAUDE_FLAGS], ws, "proj.plan"), \
    "plan runs on PLAN_MODEL (judgment step gets the strongest model); unblock/retro stay on the CLI default"
assert "--permission-mode" in spawns[-1][0] and "Bash" in " ".join(spawns[-1][0]), "headless plan must run non-interactively"
assert api.reactions == [(10, "👀"), (10, "👌")] and api.sent[-1][1] == "🧠 planning…"
assert daemon.process_message(mk(text=" PLAN ", mid=11), cfg, reg, api).startswith("plan started"), "case/whitespace-insensitive"
assert daemon.process_message(mk(text="build-all", mid=12), cfg, reg, api).startswith("loop started")
assert spawns[-1][0] == ["/opt/maw/scripts/loop.sh"] and spawns[-1][2] == "proj.loop"
# 🩹/unblock: headless /intentpipe:unblock, own pidfile, non-interactive flags
assert daemon.process_message(mk(text="🩹", mid=120), cfg, reg, api).startswith("unblock started for proj")
assert spawns[-1][0] == ["claude", "-p", "/intentpipe:unblock headless", *daemon.PLAN_CLAUDE_FLAGS] and spawns[-1][2] == "proj.unblock"
assert api.sent[-1][1] == "🩹 unblocking…"
assert daemon.process_message(mk(text="unblock", mid=121), cfg, reg, api).startswith("unblock started"), "word form triggers too"
# 📋/retro: headless /intentpipe:retro, own pidfile; the track must carry the
# workspace and the PRE-EXISTING retro reports so reap_jobs can post only new ones
tracked = []
daemon.spawn_detached = lambda cmd, cwd, base, track=None: tracked.append((cmd, cwd, base, track)) or 4242
os.makedirs(os.path.join(ws, "retro"), exist_ok=True)
open(os.path.join(ws, "retro", "2026-07-01-old.md"), "w").write("# old\n")
assert daemon.process_message(mk(text="retro", mid=130), cfg, reg, api).startswith("retro started for proj")
cmd, cwd, base, track = tracked[-1]
assert cmd == ["claude", "-p", "/intentpipe:retro headless", *daemon.PLAN_CLAUDE_FLAGS] and base == "proj.retro"
assert track["workspace"] == ws and track["retro_before"] == ["2026-07-01-old.md"], track
assert daemon.process_message(mk(text="📋", mid=131), cfg, reg, api).startswith("retro started"), "emoji form"
# memory: project resolves from cwd — a workspace registered as <root>/intentpipe
# must spawn at <root>, so headless runs share the interactive session's memory store
mawws = os.path.join(tmp, "p2", "intentpipe"); os.makedirs(mawws)
reg["6"] = {"name": "proj2", "workspace": mawws}
assert daemon.process_message(mk(text="🧠", message_thread_id=6, mid=132), cfg, reg, api).startswith("plan started for proj2")
assert tracked[-1][1] == os.path.join(tmp, "p2"), "spawn cwd must be the project ROOT, not the workspace"
assert daemon.process_message(mk(text="🧠", mid=133), cfg, reg, api).startswith("plan started for proj")
assert tracked[-1][1] == ws, "a workspace that IS the project root spawns in place"
daemon.spawn_detached = lambda cmd, cwd, base, track=None: spawns.append((cmd, cwd, base)) or 4242
assert ls() == before, "triggers must not write inbox files"
# a token inside a sentence is a note, not a trigger
n = len(spawns)
assert daemon.process_message(mk(text="let's plan this later", date=1700000003, mid=13), cfg, reg, api).startswith("queued text")
assert len(spawns) == n and "1700000003-13.md" in ls()
# NEAR-MISS on a trigger: a short message carrying a trigger emoji without being
# one (the `I🚀` that fell through to the inbox on 2026-07-30) is REFUSED — it
# neither runs nor becomes a note, and the reply names the trigger it resembles.
api = FakeAPI(); n, before = len(spawns), ls()
assert daemon.process_message(mk(text="I🚀", date=1700000007, mid=140), cfg, reg, api) \
    == "skip: near-miss trigger 'i🚀'"
assert len(spawns) == n, "a near-miss must never auto-fire the trigger it resembles"
assert ls() == before, "a near-miss must never be filed as an intent note"
assert api.reactions[-1] == (140, "😱") and "🚀" in api.sent[-1][1], api.sent
# every command emoji is guarded, including 🔌 (a keyword short-circuit, not a
# TRIGGERS entry) — and the guard sits AFTER the exact-match table, so the clean
# token still dispatches
for txt, mid in (("x🧠", 141), ("🩹?", 142), (".📋", 143), ("a🔌", 144)):
    assert daemon.process_message(mk(text=txt, mid=mid), cfg, reg, api).startswith("skip: near-miss"), txt
assert ls() == before and len(spawns) == n
assert daemon.process_message(mk(text="🚀", mid=145), cfg, reg, api).startswith("loop started"), \
    "the guard must not shadow the exact token"
n = len(spawns)   # that dispatch was deliberate; re-baseline for the checks below
# …but a real note that merely CONTAINS a trigger emoji is still a note: the
# guard is length-bounded, so intent never gets refused for mentioning a rocket
api = FakeAPI()
assert daemon.process_message(mk(text="ship it 🚀 today", date=1700000008, mid=146), cfg, reg, api) \
    .startswith("queued text"), "the guard must not eat real intent notes"
assert "1700000008-146.md" in ls() and api.reactions[-1] == (146, daemon.NOTED)
# live pidfile → "already running", no second spawn
os.makedirs(daemon.RUN_DIR, exist_ok=True)
open(os.path.join(daemon.RUN_DIR, "proj.loop.pid"), "w").write(str(os.getpid()))
api = FakeAPI()
assert daemon.process_message(mk(text="🚀", mid=14), cfg, reg, api).startswith("skip: loop already running")
assert len(spawns) == n and api.reactions[-1] == (14, "😱") and "already running" in api.sent[-1][1]
# INTENTPIPE_SCRIPTS unset → 🚀 fails with a config error, never a silent no-op
assert daemon.process_message(mk(text="🚀", mid=15), {**cfg, "maw_scripts": None}, reg, api).startswith("skip: INTENTPIPE_SCRIPTS")
assert "INTENTPIPE_SCRIPTS" in api.sent[-1][1]
# Release it: that pidfile was this check's fixture, and it now holds the whole
# project (project_busy), which would make every later dispatch here "busy".
os.remove(os.path.join(daemon.RUN_DIR, "proj.loop.pid"))

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
# passes INTENTPIPE_SCRIPTS through so the scaffold repo is pulled too. Stub the runner.
pcalls = []
daemon.pull_report = lambda maw=None: pcalls.append(maw) or "📥 pull-all\n(stub)"
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="pull-all", mid=18), cfg, reg, api) == "pull-all done"
assert pcalls[-1] == "/opt/maw/scripts" and api.sent[-1] == (5, "📥 pull-all\n(stub)")
assert api.reactions == [(18, "👀"), (18, "👌")] and ls() == before, "pull-all must not write a note"
# case/space-insensitive, and fine from a topic with no workspace (fleet-wide)
assert daemon.process_message(mk(text=" PULL ALL ", message_thread_id=77, mid=19), cfg, reg, api) == "pull-all done"

# `plugin` (and 🔌): box-level like pull-all — never topic-scoped (one user-scope
# install serves every project), writes no note, and passes the daemon's own plugin
# dir through so the keyword and sync_plugin can't resolve different sources.
gcalls = []
daemon.plugin_report = lambda plugin_dir=None: gcalls.append(plugin_dir) or "🔌 intentpipe plugin\n(stub)"
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="plugin", mid=25), cfg, reg, api) == "plugin report sent"
assert gcalls[-1] == "/opt/maw", gcalls  # maw_scripts /opt/maw/scripts → the plugin root
assert api.sent[-1] == (5, "🔌 intentpipe plugin\n(stub)")
assert api.reactions == [(25, "👀"), (25, "👌")] and ls() == before, "plugin must not write a note"
# the 🔌 alias, and from a topic with no workspace (it is never project-scoped)
assert daemon.process_message(mk(text="🔌", message_thread_id=77, mid=26), cfg, reg, api) == "plugin report sent"
assert daemon.process_message(mk(text=" PLUGIN ", mid=27), cfg, reg, api) == "plugin report sent"
# a sentence containing the word is still a note, not a command
n = len(gcalls)
assert daemon.process_message(mk(text="the plugin broke again", date=1700000004, mid=28), cfg, reg, api).startswith("queued text")
assert len(gcalls) == n and "1700000004-28.md" in ls()

# `help`: lists every command. Short-circuits like status/pull-all — replies into
# its topic, writes no note, works in a project topic and in General alike.
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="help", mid=22), cfg, reg, api) == "help sent"
assert api.sent[-1][0] == 5 and "status" in api.sent[-1][1] and "pull-all" in api.sent[-1][1]
assert "plugin" in api.sent[-1][1], "help must list every keyword the router accepts"
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
# checkout.py renders each option's body (including the "untouched by this change"
# annotation); the daemon only routes it. Use the real renderer so the two can't drift.
sys.path.insert(0, os.path.join(orch, "system-scripts"))
import checkout as _co
for _o in opts["options"]:
    _o["body"] = _co.render_option(_o, "dev")
daemon.checkout_options = lambda w: opts
api = FakeAPI(); before = ls()
assert daemon.process_message(mk(text="checkout", mid=30), cfg, reg, api) == "checkout offered for proj (2 option(s))"
assert len(api.sent) == 3 and all(s[0] == 5 for s in api.sent), api.sent  # intro + 2 options, all in-topic
assert "feat/x" in api.sent[-1][1] and "app_mobile: feat/x" in api.sent[-1][1] and "PR #7" in api.sent[-1][1]
# the repo with no PR on that branch is annotated, so a one-sided option reads as
# deliberate ("core stays on dev because nothing here changed") rather than broken
assert "core: dev   (no PR on this branch — untouched by this change)" in api.sent[-1][1], api.sent[-1][1]
assert "(no PR on this branch" not in api.sent[-2][1], "the baseline option is not a one-sided change"
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
# `relaunch force` is the phone's escape hatch from the build watermark: same
# keyword, --force through to the script (a plain relaunch must NOT carry it, or
# nothing is ever skipped).
assert daemon.process_message(mk(text="Relaunch Force", mid=42), cfg, reg, api).startswith("relaunch started for proj")
assert spawns[-1][0] == [daemon.RELAUNCH, "--force", "proj"], spawns[-1]
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

# a finished retro run posts each NEW report under <workspace>/retro/ as its own
# react-to-apply offer — pre-existing reports (retro_before) stay silent
daemon.RETRO_OFFERS_FILE = os.path.join(daemon.RUN_DIR, "retro_offers.json")
open(os.path.join(ws, "retro", "2026-07-29-new-pattern.md"), "w").write(
    "# Retro 2026-07-29 · a new pattern\n\nbody\n\n## Confidence\n\n**High.** seen thrice.\n")
api = FakeAPI()
daemon._JOBS[:] = [{"popen": FakePopen(0), "log": _job("retroproj", 0, "wrote 1 report")["log"],
                    "name": "proj", "action": "retro", "topic": 5,
                    "workspace": ws, "retro_before": ["2026-07-01-old.md"]}]
daemon.reap_jobs(cfg, api)
texts = [t for _, t in api.sent]
assert any(t.startswith("✅ retro for proj finished") for t in texts), texts
offer_msgs = [t for t in texts if t.startswith("📋 retro proposal")]
assert len(offer_msgs) == 1, texts  # only the NEW report, not the old one
assert "Retro 2026-07-29 · a new pattern" in offer_msgs[0] and "High." in offer_msgs[0], offer_msgs
assert "React to this message" in offer_msgs[0]
roffers = daemon.load_retro_offers()
assert len(roffers) == 1 and list(roffers.values())[0]["file"].endswith("2026-07-29-new-pattern.md"), roffers

# reacting to the offer applies it: a headless claude run IN THE PLUGIN REPO whose
# prompt carries the implement instructions + the full proposal text
plugdir = os.path.join(tmp, "maw"); os.makedirs(os.path.join(plugdir, "scripts"))
rcfg = {**cfg, "maw_scripts": os.path.join(plugdir, "scripts")}
rmid = int(next(iter(roffers)))
daemon.save_offers({})   # FakeAPI mids restart at 1 — drop the stale checkout offers so the id can't collide
applies = []
daemon.spawn_detached = lambda cmd, cwd, base, track=None: applies.append((cmd, cwd, base, track)) or 777
api = FakeAPI()
assert daemon.process_reaction(mkr(mid=rmid), rcfg, api).startswith("retro apply started")
cmd, cwd, base, track = applies[-1]
assert cwd == plugdir and base.startswith("retro-apply."), (cwd, base)
assert cmd[0] == "claude" and "--dangerously-skip-permissions" in cmd
assert "=== PROPOSAL ===" in cmd[2] and "a new pattern" in cmd[2], "prompt must embed the proposal"
assert "intentpipe plugin repo" in cmd[2], "prompt must be the retro-implement instructions"
assert track["report_tail"] is True, track  # the PR URL surfaces on completion
assert any("applying" in t for _, t in api.sent), api.sent
daemon.spawn_detached = lambda cmd, cwd, base, track=None: spawns.append((cmd, cwd, base)) or 4242
PY
echo "[smoke] daemon process_message ok"

# --- The project mutex: plan/loop/unblock/retro/checkout/relaunch all mutate one
# project's task queue, state repo, or checked-out branches, so any one of them
# running must block the others — the per-(project, action) pidfile alone let a 🚀
# start against a queue the planner was still writing.
python3 - "$ORCH" "$TMP" <<'PY' || fail "project mutex checks failed"
import os, sys
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, orch)
import daemon
daemon.RUN_DIR = os.path.join(tmp, "mutexrun"); os.makedirs(daemon.RUN_DIR)
ws = os.path.join(tmp, "mws", "scaffold"); os.makedirs(ws)
cfg = {"chat_id": "-100", "allowlist": {"42"}, "maw_scripts": "/opt/maw/scripts"}
reg = {"5": {"name": "proj", "workspace": ws}}
class FakeAPI:
    def __init__(self): self.sent = []; self.reactions = []; self._mid = 0
    def send_message(self, chat, text, thread_id=None):
        self.sent.append((thread_id, text)); self._mid += 1
        return {"result": {"message_id": self._mid}}
    def set_reaction(self, chat, mid, emoji): self.reactions.append((mid, emoji))
mk = lambda **kw: {"from": {"id": 42}, "chat": {"id": -100}, "message_id": kw.pop("mid", 1),
                   "date": 1700000000, "message_thread_id": 5, **kw}
spawns = []
daemon.spawn_detached = lambda cmd, cwd, base, track=None: spawns.append(base) or 4242
daemon.sync_plugin = lambda cfg: None

# A live plan pidfile (this very process — guaranteed alive and not a zombie)
# must turn a 🚀 away, naming the run that holds the project.
open(os.path.join(daemon.RUN_DIR, "proj.plan.pid"), "w").write(str(os.getpid()))
api = FakeAPI()
out = daemon.process_message(mk(text="🚀"), cfg, reg, api)
assert out == "skip: plan already running for proj", out
assert not spawns, "🚀 must not spawn while plan holds the project"
assert api.reactions[-1] == (1, "😱") and "plan is still running" in api.sent[-1][1], api.sent
# …and `relaunch`, which would swap branches under that same plan.
api = FakeAPI()
out = daemon.process_message(mk(text="relaunch", mid=2), cfg, reg, api)
assert out == "skip: plan already running for proj", out
assert not spawns, spawns
# A run never blocks itself: with only its OWN pidfile alive, plan proceeds.
os.rename(os.path.join(daemon.RUN_DIR, "proj.plan.pid"),
          os.path.join(daemon.RUN_DIR, "proj.loop.pid"))
assert daemon.project_busy("proj", exclude="proj.loop") is None, "own base must be excluded"
assert daemon.project_busy("proj") == "loop"
# A stale pidfile (dead pid) is not a lock — the fleet must not wedge after a crash.
open(os.path.join(daemon.RUN_DIR, "proj.loop.pid"), "w").write("999999999")
assert daemon.project_busy("proj") is None, "a dead pid must not hold the project"
api = FakeAPI()
assert daemon.process_message(mk(text="🚀", mid=3), cfg, reg, api).startswith("loop started")
assert spawns == ["proj.loop"], spawns
# Another project is unaffected — the mutex is per-project, not global.
open(os.path.join(daemon.RUN_DIR, "other.plan.pid"), "w").write(str(os.getpid()))
assert daemon.project_busy("proj") is None, "another project's run must not block this one"
PY
echo "[smoke] project mutex ok"

# --- Orphan sweep: leaked flutter_tester workers survive daemon restarts and carry
# the box's memory peak. Age is the discriminator (a live suite runs for minutes),
# and the match is on the exact comm name so nothing else is ever a candidate.
python3 - "$ORCH" "$TMP" <<'PY' || fail "orphan sweep checks failed"
import os, subprocess, sys, time
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, orch)
import daemon

# Hermetic fixture: a child that renames its own comm via prctl(PR_SET_NAME) to a
# name only this test uses. The sweep is exercised against a real process in real
# /proc without the suite depending on — or signalling — anything else on the box.
FAKE = ("smoke_tester",)
victim = subprocess.Popen([sys.executable, "-c",
    "import ctypes, time\n"
    "ctypes.CDLL('libc.so.6').prctl(15, b'smoke_tester', 0, 0, 0)\n"
    "time.sleep(300)"])
bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
time.sleep(0.3)   # let both appear in /proc with a readable comm
try:
    # Younger than max_age → spared. This is what protects a LIVE suite: a daemon
    # restart mid-verify must not kill the workers that verify is still using.
    assert daemon.sweep_orphans(max_age=10_000, comms=FAKE) == [], "a young worker must be spared"
    assert victim.poll() is None
    # Older than max_age → reaped, and reported so the journal (and logmine) see it.
    killed = daemon.sweep_orphans(max_age=0, comms=FAKE)
    assert [p for p, _, _ in killed] == [victim.pid], (killed, victim.pid)
    assert killed[0][1] == "smoke_tester" and isinstance(killed[0][2], int), killed
    victim.wait(timeout=10)
    assert victim.poll() is not None, "the orphan must actually be dead"
    # Only a matching comm is ever signalled — everything else on the box is
    # structurally out of scope, not spared by a special case.
    assert bystander.poll() is None, "a non-matching process must never be touched"
    assert "flutter_tester" in daemon.ORPHAN_COMMS and daemon.ORPHAN_MAX_AGE >= 3600
    # A broken /proc must never take the poll loop down with it.
    real = daemon._boot_time
    daemon._boot_time = lambda: (_ for _ in ()).throw(ValueError("boom"))
    assert daemon.sweep_orphans(comms=FAKE) == [], "a sweep failure must degrade to a no-op"
    daemon._boot_time = real
finally:
    for p in (victim, bystander):
        p.kill(); p.wait()

# getUpdates backoff: doubles per failure, capped, and Telegram's own retry_after wins.
import io, json as _json, urllib.error
assert daemon.POLL_BACKOFF_MIN == 5 and daemon.POLL_BACKOFF_MAX == 120
b = daemon.POLL_BACKOFF_MIN
seq = []
for _ in range(6):
    seq.append(b); b = min(b * 2, daemon.POLL_BACKOFF_MAX)
assert seq == [5, 10, 20, 40, 80, 120], seq
assert daemon._retry_after(OSError("read timed out")) is None, "only HTTP errors carry retry_after"
body = _json.dumps({"parameters": {"retry_after": 37}}).encode()
e429 = urllib.error.HTTPError("u", 429, "Too Many Requests", {}, io.BytesIO(body))
assert daemon._retry_after(e429) == 37
# header fallback when the body has none, and a hostile value is capped
e_hdr = urllib.error.HTTPError("u", 429, "x", {"Retry-After": "12"}, io.BytesIO(b"{}"))
assert daemon._retry_after(e_hdr) == 12
e_big = urllib.error.HTTPError("u", 429, "x", {"Retry-After": "99999"}, io.BytesIO(b"{}"))
assert daemon._retry_after(e_big) == daemon.POLL_BACKOFF_MAX

# A failed child's log tail reaches the JOURNAL, not just Telegram — logmine reads
# the journal, so a bare "FAILED (rc=1)" is a defect it can never diagnose.
logp = os.path.join(tmp, "child.log")
open(logp, "w").write("\n".join(f"line {i}" for i in range(60)))
tail, rejected = daemon._log_report(logp, 20)
assert tail.splitlines()[0] == "line 40" and len(tail.splitlines()) == 20, tail
assert daemon._log_report(logp)[0].endswith("line 59")   # byte-budget form unchanged
PY
echo "[smoke] orphan sweep + backoff ok"

# --- status.py builds a report from a stub registry + ports.json, and scopes to
# one workspace when asked. No git repos / no live ports needed to exercise it.
python3 - "$ORCH" "$TMP" <<'PY' || fail "status.py checks failed"
import json, os, sys
orch, tmp = sys.argv[1], sys.argv[2]
home = os.path.join(tmp, "orch"); os.makedirs(home)
a = os.path.join(tmp, "a", "scaffold"); os.makedirs(a)
b = os.path.join(tmp, "b", "scaffold"); os.makedirs(b)
open(os.path.join(a, "agents.env"), "w").write('DEFAULT_BRANCH=dev\nREPOS="be fe"\nREPO_be=../be\nREPO_fe=../fe\n')
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
assert "🟢" in status._svc({"backend": 8810}, "backend", {})[0]
status._probe = lambda port, path="/": ("erroring", 500)
line = status._svc({"frontend": {"port": 3031, "health": "/"}}, "frontend", {})[0]
assert "🟠" in line and "(500)" in line, line
status._probe = lambda port, path="/": ("down", None)
assert "🔴" in status._svc({"backend": 8810}, "backend", {})[0]
assert status._svc({}, "backend", {}) == ["   backend:  n/a"]
# a service that declares its url + repo reports BOTH: the stable public URL and
# the branch behind it — the pairing that makes "what am I looking at?" answerable
status._probe = lambda port, path="/": ("up", 200)
spec = {"frontend": {"port": 3030, "url": "https://fe.example", "repo": "fe"}}
out = status._svc(spec, "frontend", {"fe": "feat/x (abc1234)"})
assert "https://fe.example" in out[0] and out[1].strip() == "↳ fe @ feat/x (abc1234)", out

# Repos on different branches: only SOME splits are the served-mismatch bug.
# Real repos here, because the distinction is "does the other repo have this
# branch at all" — the frontend-only / backend-only case must NOT be shouted at.
import subprocess
def git(d, *args):
    subprocess.run(["git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *args],
                   check=True, capture_output=True)
for r in ("be", "fe"):
    p = os.path.join(tmp, "a", r); os.makedirs(p)
    subprocess.run(["git", "init", "-qb", "dev", p], check=True, capture_output=True)
    git(p, "commit", "-qm", "init", "--allow-empty")
rep = status.build_report(a)
assert "MIXED CHECKOUT" not in rep and "one-sided" not in rep, rep   # both on dev

# one-sided change: fe on a feature branch, be has no such branch → expected
git(os.path.join(tmp, "a", "fe"), "checkout", "-qb", "feat/x")
rep = status.build_report(a)
assert "MIXED CHECKOUT" not in rep, rep
assert "one-sided change: fe on 'feat/x'" in rep and "be has no such branch" in rep, rep

# the real defect: be HAS feat/x but is serving dev → the preview is a mixture
git(os.path.join(tmp, "a", "be"), "branch", "feat/x")
rep = status.build_report(a)
assert "MIXED CHECKOUT: be has 'feat/x' but serves dev" in rep, rep
PY
echo "[smoke] status.py ok"

# --- plugin.py: the install-freshness report behind /plugin. Everything is stubbed
# (fake source tree, fake install record, fake registry) — no `claude plugin update`
# runs, nothing on the real box is touched. What it guards: a stale cache is never
# reported as current, --check never mutates, a failed reinstall is not dressed up as
# a success, and a project that doesn't ENABLE the plugin is called out rather than
# printed with everyone else's version.
python3 - "$ORCH" "$TMP" <<'PY' || fail "plugin.py checks failed"
import json, os, sys
orch, tmp = sys.argv[1], sys.argv[2]
home = os.path.join(tmp, "porch"); os.makedirs(home)
# three projects: one enables the plugin, one turned it off, one never had the entry
for name, settings in (("on", {"intentpipe@intentpipe": True}),
                       ("off", {"intentpipe@intentpipe": False}),
                       ("none", None)):
    root = os.path.join(tmp, "p-" + name); os.makedirs(os.path.join(root, "intentpipe"))
    if settings is not None:
        os.makedirs(os.path.join(root, ".claude"))
        json.dump({"enabledPlugins": settings}, open(os.path.join(root, ".claude", "settings.json"), "w"))
json.dump({str(i): {"name": n, "workspace": os.path.join(tmp, "p-" + n, "intentpipe")}
           for i, n in enumerate(("on", "off", "none"))},
          open(os.path.join(home, "registry.json"), "w"))
os.environ["ORCH_HOME"] = home
sys.path.insert(0, os.path.join(orch, "system-scripts"))
import plugin

src = os.path.join(tmp, "psrc", ".claude-plugin"); os.makedirs(src)
def set_source(v): json.dump({"version": v}, open(os.path.join(src, "plugin.json"), "w"))
cache = os.path.join(tmp, "pcache"); os.makedirs(os.path.join(cache, ".claude-plugin"))
def set_installed(v, path=cache):
    json.dump({"plugins": {plugin.PLUGIN_ID: [{"scope": "user", "version": v, "installPath": path}]}},
              open(plugin.INSTALLED, "w"))
    json.dump({"version": v}, open(os.path.join(cache, ".claude-plugin", "plugin.json"), "w"))
plugin.INSTALLED = os.path.join(tmp, "installed.json")
plugin.MARKETPLACES = os.path.join(tmp, "marketplaces.json")
json.dump({plugin.MARKETPLACE: {"installLocation": os.path.dirname(src)}}, open(plugin.MARKETPLACES, "w"))
run = lambda **kw: plugin.build_report(**kw)

# in sync → "current", and each project's line answers what IT runs
set_source("1.2.0"); set_installed("1.2.0")
rep = run(check=True)
assert "cache   1.2.0 ✅ current" in rep, rep
assert "• on    1.2.0 ✅" in rep, rep
assert "⚠️ disabled" in rep and "off" in rep, rep
assert "not enabled" in rep, rep   # the project with no entry runs NO version, not "1.2.0"

# stale + --check: says so, names the source version, and changes NOTHING
updates = []
plugin._update_cache = lambda: updates.append(1)
set_source("1.3.0")
rep = run(check=True)
assert "⚠️ STALE — source is 1.3.0" in rep, rep
assert not updates, "--check must never reinstall"
assert "1.2.0" in rep and "• on    1.2.0" in rep, "projects still run the installed version, not the source"

# stale + update: the reinstall runs and the transition is reported
def good(): set_installed("1.3.0"); updates.append("ran"); return None
plugin._update_cache = good
rep = run()
assert "cache   1.2.0 → 1.3.0 ✅ reinstalled" in rep, rep
assert "• on    1.3.0 ✅" in rep, rep

# a reinstall that fails must NOT read as success — this is the whole point of the
# report: a silently stale cache is what runs the wrong skills in every project
set_source("1.4.0")
plugin._update_cache = lambda: "npm ERR! marketplace not found"
rep = run()
assert "⚠️ still not current" in rep and "marketplace not found" in rep, rep
assert "✅ reinstalled" not in rep, rep

# the install record and the cache dir disagreeing = the pinned copy isn't what the
# record claims; and a source with no readable manifest is "cannot tell", not "current"
set_installed("1.4.0", path=os.path.join(tmp, "gone")); set_source("1.4.0")
assert "⚠️ cache dir" in run(check=True), run(check=True)
set_installed("1.4.0")
rep = run(check=True, explicit_source="/nonexistent")
assert "cannot tell" in rep and "✅ current" not in rep, rep

# no source at all (no marketplace, no INTENTPIPE_SCRIPTS) → one honest line, no crash
json.dump({}, open(plugin.MARKETPLACES, "w")); os.environ.pop("INTENTPIPE_SCRIPTS", None)
assert "no plugin source found" in run(check=True)
PY
echo "[smoke] plugin.py ok"

# --- checkout.py --build: the branch-switch path the Telegram checkout flow runs.
# Guards the mixed-checkout bug: a repo that can't be switched must ABORT the
# rebuild (never serve a new frontend against the old backend), lockfile churn
# from a preview build must not count as a real edit, and the relaunch it does run
# must reset the backend volumes so the branch's migrations replay from empty.
python3 - "$ORCH" "$TMP" <<'PY' || fail "checkout.py build checks failed"
import os, subprocess, sys
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(orch, "system-scripts"))
import checkout

root = os.path.join(tmp, "co"); ws = os.path.join(root, "scaffold"); os.makedirs(ws)
open(os.path.join(ws, "agents.env"), "w").write('REPOS="fe be"\nREPO_fe=../fe\nREPO_be=../be\n')
def git(d, *a): subprocess.run(["git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *a],
                               check=True, capture_output=True)
for r in ("fe", "be"):
    p = os.path.join(root, r); os.makedirs(p)
    subprocess.run(["git", "init", "-qb", "dev", p], check=True, capture_output=True)
    open(os.path.join(p, "src.txt"), "w").write("v1\n")
    open(os.path.join(p, "pubspec.lock"), "w").write("pinned\n")
    git(p, "add", "."); git(p, "commit", "-qm", "init")
    git(p, "checkout", "-qb", "feat/x"); open(os.path.join(p, "src.txt"), "w").write("v2\n")
    git(p, "commit", "-qam", "feature"); git(p, "checkout", "-q", "dev")
on = lambda r: subprocess.run(["git", "-C", os.path.join(root, r), "rev-parse", "--abbrev-ref", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

calls, posts = [], []
fake = os.path.join(tmp, "fake-relaunch")
open(fake, "w").write('#!/usr/bin/env bash\necho "$@" >> "$0.calls"\n'); os.chmod(fake, 0o755)
checkout.RELAUNCH = fake
checkout._post = lambda offer, text: posts.append(text)
offer = lambda br: {"name": "proj", "workspace": ws, "topic": 5, "label": "feat/x",
                    "branches": {"fe": br, "be": br}}

# happy path: both repos switch, then relaunch runs WITH --reset (the branch may
# carry different migrations, so the dev database goes with it)
checkout.build(offer("feat/x"))
assert on("fe") == "feat/x" and on("be") == "feat/x", (on("fe"), on("be"))
assert open(fake + ".calls").read().strip() == "--reset proj", open(fake + ".calls").read()

# lockfile churn (a preview build regenerating pubspec.lock) is NOT a real edit —
# it used to make the repo "dirty" and get it silently skipped
open(os.path.join(root, "be", "pubspec.lock"), "w").write("regenerated by a build\n")
checkout.build(offer("dev"))
assert on("fe") == "dev" and on("be") == "dev", "lockfile drift must not block a switch"

# a genuinely dirty repo aborts the WHOLE build: no relaunch, and the user is told
open(os.path.join(root, "be", "src.txt"), "a").write("hand edit\n")
n = len(open(fake + ".calls").read().splitlines())
checkout.build(offer("feat/x"))
assert len(open(fake + ".calls").read().splitlines()) == n, "a half-applied option must not be served"
assert posts and "aborted" in posts[-1] and "be" in posts[-1], posts
assert on("be") == "dev" and on("fe") == "dev", "an option that can't apply in full applies to no repo"
PY
echo "[smoke] checkout.py build ok"

# --- checkout.py --refresh: the automatic side of the same flow — a intentpipe
# task lands, `done` puts every repo back on the default branch, and this points the
# preview back at the branch that was just developed. Guards the three things that
# make it usable unattended: a branch only one repo has leaves the other on default
# (the one-sided FE/BE rule, here for a branch with no PR yet), with no branch named
# it follows the most recently updated open PR, and a second refresh while one is
# building QUEUES instead of stacking a rebuild — the last branch developed wins.
python3 - "$ORCH" "$TMP" <<'PY' || fail "checkout.py refresh checks failed"
import json, os, subprocess, sys
orch, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(orch, "system-scripts"))
import checkout, status

root = os.path.join(tmp, "rf"); ws = os.path.join(root, "intentpipe"); os.makedirs(ws)
# the registry is the source of the project's name and topic (as for the daemon):
# `relaunch` is addressed by name, and the refresh reports into that topic
status.REGISTRY = os.path.join(tmp, "rf-registry.json")
json.dump({"5": {"name": "proj", "workspace": ws}}, open(status.REGISTRY, "w"))
open(os.path.join(ws, "agents.env"), "w").write(
    'PROJECT_NAME=proj\nDEFAULT_BRANCH=dev\nREPOS="fe be"\nREPO_fe=../fe\nREPO_be=../be\n')
def git(d, *a): subprocess.run(["git", "-C", d, "-c", "user.email=t@t", "-c", "user.name=t", *a],
                               check=True, capture_output=True)
for r in ("fe", "be"):
    p = os.path.join(root, r); os.makedirs(p)
    subprocess.run(["git", "init", "-qb", "dev", p], check=True, capture_output=True)
    git(p, "commit", "-qm", "init", "--allow-empty")
git(os.path.join(root, "fe"), "branch", "feature/only-fe")   # frontend-only work, no PR yet
on = lambda r: subprocess.run(["git", "-C", os.path.join(root, r), "rev-parse", "--abbrev-ref", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

checkout.RUN_DIR = os.path.join(tmp, "rfrun")
checkout.RELAUNCH = os.path.join(tmp, "fake-relaunch")   # written by the build section above
checkout._post = lambda offer, text: None
prs = {"fe": [], "be": []}
checkout._open_prs = lambda repo: prs["fe" if repo.endswith("fe") else "be"]

# a branch only the frontend has: the backend stays on dev instead of failing
checkout.refresh(ws, "feature/only-fe")
assert on("fe") == "feature/only-fe" and on("be") == "dev", (on("fe"), on("be"))
# ... and the project root is accepted as well as the workspace dir
checkout.refresh(root, "dev")
assert on("fe") == "dev", on("fe")

# a repo on a THIRD branch is a builder mid-task: an unattended refresh gives way
# rather than switching the tree under a running session (a human-picked option
# still switches — that path is checkout.build above)
checkout.refresh(ws, "feature/only-fe")            # park the preview on the branch again
git(os.path.join(root, "be"), "checkout", "-qb", "task/0007-wip")
checkout.refresh(ws, "dev")
assert on("be") == "task/0007-wip" and on("fe") == "feature/only-fe", (on("be"), on("fe"))
# ... but the branch the PREVIOUS refresh parked there is the preview's own state,
# not someone's work — it must still be able to move off it
git(os.path.join(root, "be"), "checkout", "-q", "dev")
checkout.refresh(ws, "dev")
assert on("fe") == "dev", on("fe")

# no branch named → follow the most recently updated open PR (not merely the last
# one gh happened to list)
git(os.path.join(root, "be"), "branch", "feature/older")
git(os.path.join(root, "be"), "branch", "feature/newer")
prs["be"] = [{"number": 1, "title": "older", "url": "u1", "headRefName": "feature/older",
              "updatedAt": "2026-07-01T00:00:00Z"},
             {"number": 2, "title": "newer", "url": "u2", "headRefName": "feature/newer",
              "updatedAt": "2026-07-20T00:00:00Z"}]
checkout.refresh(ws)
assert on("be") == "feature/newer" and on("fe") == "dev", (on("be"), on("fe"))

# a refresh arriving while one is in flight queues rather than stacking a rebuild:
# a loop lands several tasks in a row and only the last branch is worth building
os.makedirs(checkout.RUN_DIR, exist_ok=True)
open(os.path.join(checkout.RUN_DIR, "proj.checkout.pid"), "w").write(str(os.getpid()))
built = []
checkout.refresh_once = lambda w, b=None: built.append(b)
checkout.refresh(ws, "feature/only-fe")
assert not built, "a queued refresh must not build"
assert open(os.path.join(checkout.RUN_DIR, "proj.refresh-pending")).read().strip() == "feature/only-fe"
# the run that owns the slot drains the queue when it finishes, so the branch that
# arrived meanwhile is the one served
os.remove(os.path.join(checkout.RUN_DIR, "proj.checkout.pid"))
real_once = checkout.refresh_once
def once(w, b=None):
    real_once(w, b)
    if len(built) == 1:   # a second task lands while the first refresh builds
        open(os.path.join(checkout.RUN_DIR, "proj.refresh-pending"), "w").write("feature/newer\n")
checkout.refresh_once = once
checkout.refresh(ws, "dev")
assert built == ["dev", "feature/newer"], built
assert not os.path.exists(os.path.join(checkout.RUN_DIR, "proj.checkout.pid")), "pidfile must be released"
PY
echo "[smoke] checkout.py refresh ok"

# --- preview-lib: the two things a preview must never get wrong — what code it is
# serving (cmd_urls names the repo + branch behind every URL, and shouts when the
# two repos disagree) and how the backend comes up on a branch switch (volumes
# reset + force-recreate, so the branch's migrations replay from empty). Docker is
# stubbed by overriding DC after sourcing; nothing is started.
PREV="$TMP/prev"; mkdir -p "$PREV/fe" "$PREV/be"
for r in fe be; do
  git -C "$PREV/$r" init -qb dev
  git -C "$PREV/$r" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
done
prev() { # prev <cmd...> — source the lib against the fake project, stub docker
  ( export PROJECT=p FRONTEND_DIR="$PREV/fe" BACKEND_DIR="$PREV/be" DEFAULT_BRANCH=dev \
           FRONTEND_PORT=1 BACKEND_PORT=2 FRONTEND_URL=https://fe API_URL=https://api \
           STATE_DIR="$PREV/state" FLUTTER_PATH=/nonexistent
    source "$ORCH/preview/preview-lib.sh"
    DC() { echo "docker compose $*"; }
    "$@" )
}
out="$(prev cmd_urls)"
grep -q "↳ fe @ dev (" <<<"$out" || fail "cmd_urls must name the frontend repo + branch: $out"
grep -q "↳ be @ dev (" <<<"$out" || fail "cmd_urls must name the backend repo + branch: $out"
grep -q "MIXED CHECKOUT" <<<"$out" && fail "same branch in both repos is not a mixed checkout" || true
# A one-sided change (the backend has no such branch) is the NORMAL case for a
# frontend-only PR and must be reported as expected, not warned about — crying
# wolf here would train the warning to be ignored where it matters.
git -C "$PREV/fe" checkout -qb feat/x
out="$(prev cmd_urls)"
grep -q "MIXED CHECKOUT" <<<"$out" && fail "a one-sided change must not be flagged as mixed: $out" || true
grep -q "one-sided change: be has no 'feat/x'" <<<"$out" || fail "a one-sided change must be named as such: $out"
# ...but once the branch EXISTS in the backend, serving dev there is the defect.
git -C "$PREV/be" branch feat/x
grep -q "MIXED CHECKOUT" <<<"$(prev cmd_urls)" || fail "a stale repo with the branch available must be shouted"
git -C "$PREV/be" branch -qD feat/x
# two unrelated feature branches: not something the checkout flow produces
git -C "$PREV/be" checkout -qb feat/y
grep -q "MIXED CHECKOUT" <<<"$(prev cmd_urls)" || fail "unrelated branches in both repos must be shouted"
git -C "$PREV/be" checkout -q dev && git -C "$PREV/be" branch -qD feat/y
# checkout falls the OTHER repo back to the default branch instead of leaving it
# on the previous feature branch — "stay put" was how a two-repo feature bled into
# the next, one-sided checkout.
git -C "$PREV/be" checkout -qb feat/old
out="$(prev _checkout_repo backend "$PREV/be" feat/x)"
grep -q "falling back to dev" <<<"$out" || fail "a missing branch must fall back to the default: $out"
[ "$(git -C "$PREV/be" branch --show-current)" = "dev" ] || fail "fallback did not check out the default branch"
git -C "$PREV/be" branch -qD feat/old
echo dirt > "$PREV/fe/dirt.txt"
grep -q "dirty" <<<"$(prev cmd_urls)" || fail "a dirty tree must be marked"
# plain start: no volume reset, no force-recreate (a relaunch must not drop the dev DB)
out="$(prev start_backend)"
grep -q "down -v" <<<"$out" && fail "a plain up must not reset volumes: $out" || true
grep -q -- "--force-recreate" <<<"$out" && fail "a plain up must not force-recreate: $out" || true
# reset: volumes dropped first, and the container recreated even if nothing changed
out="$(BACKEND_RESET_VOLUMES=1 prev start_backend)"
grep -q "docker compose down -v" <<<"$out" || fail "BACKEND_RESET_VOLUMES must drop volumes: $out"
grep -q -- "--force-recreate" <<<"$out" || fail "a volume reset implies --force-recreate: $out"
# The build watermark: a rebuild is skipped ONLY when the running preview already
# serves exactly the checked-out commits. Every ingredient of that sentence is a
# separate way to be wrong, so each gets a case — a false "current" serves stale
# code, which is the failure this whole library exists to prevent.
rm -f "$PREV/fe/dirt.txt"
mkdir -p "$PREV/fe/build/web" "$PREV/state"; touch "$PREV/fe/build/web/index.html"
echo "build/" > "$PREV/fe/.gitignore"          # as every flutter repo does
git -C "$PREV/fe" add .gitignore && git -C "$PREV/fe" -c user.email=t@t -c user.name=t commit -qm ignore
echo $$ > "$PREV/state/web-serve.pid"          # a live server (this test's own pid)
prev preview_current && fail "no watermark yet — nothing can be current" || true
prev write_watermark
prev preview_current || fail "same commits + live server must count as current"
out="$(prev cmd_up)"
grep -q "skipping the rebuild" <<<"$out" || fail "a current preview must not be rebuilt: $out"
grep -q "docker compose up" <<<"$out" && fail "a skipped up must not touch the backend: $out" || true
echo drift > "$PREV/fe/dirt.txt"
prev preview_current && fail "a dirty tree has no stable identity — never current" || true
git -C "$PREV/fe" add -A && git -C "$PREV/fe" -c user.email=t@t -c user.name=t commit -qm drift
prev preview_current && fail "a new commit must invalidate the watermark" || true
prev write_watermark
PREVIEW_FORCE_REBUILD=1 prev preview_current && fail "--force must override the watermark" || true
echo 999999 > "$PREV/state/web-serve.pid"
prev preview_current && fail "a dead server must rebuild however current the code is" || true
echo "[smoke] preview-lib ok"

echo "SMOKE OK"
