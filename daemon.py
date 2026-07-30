#!/usr/bin/env python3
"""Inbound Telegram daemon — the scaffold's voice/text control plane.

Standalone server-side control plane, above any single workspace/project — a
separate project from the scaffold it feeds, not part of it. Architecture +
rationale: DESIGN.md (alongside this file).

Long-poll getUpdates → enforce the allowlist (the only door, Decision #4) →
resolve the message's forum topic to a workspace via the registry → then either
dispatch a trigger token (Decision #10: 🧠/`plan` → headless /machines-at-work:plan,
🚀/`build-all` → detached loop.sh, 🩹/`unblock` → headless /machines-at-work:unblock,
📋/`retro` → headless /machines-at-work:retro, whose new reports post back
react-to-apply; exact match only) or transcribe voice / take
text and drop the RAW message into <workspace>/updates/.inbox/<epoch>-<msgid>.md
— machines-at-work's inbound.sh contract; the plugin names and formats notes,
never the daemon. An image (photo, or an image/* document) is intent too: it is
downloaded next to its caption note under the same <epoch>-<msgid> base and
referenced by bare basename ([image: <name>]); inbound.sh turns it into a
permanent resources/ file the plan reads (plugin DESIGN #37). Every allow-listed message gets a reaction lifecycle:
👀 received → 👌 queued/started, or 😱 + a reply saying what went wrong.

Keyword `status` short-circuits routing and replies with a live report
(branches + FE/BE up/down) from system-scripts/status.py: scoped to the one
project when sent in its topic, all projects when sent anywhere else. Keyword
`pull-all` likewise short-circuits: system-scripts/pull.py fast-forward-pulls the
whole fleet (every project's repos + the machines-at-work scaffold via
MAW_SCRIPTS), skipping any dirty tree, and replies with a per-repo result.
Keyword `plugin` (or 🔌) short-circuits too: system-scripts/plugin.py reinstalls
the machines-at-work plugin when its source version moved — the same reinstall
sync_plugin does silently before a dispatch — and replies with the source and
cache versions plus what each project actually runs.
Keyword `help` short-circuits the same way, replying with the full command list.

Keyword `checkout` (in a project topic) posts that project's checkout options —
the default-branch baseline plus one per open-PR feature branch (repos without a
PR on that branch stay on the default; that's the frontend/backend-only case) —
one Telegram message each, remembered by message_id. A message_reaction on one of
those messages (allow-listed user) checks its branches out — all repos or none —
and relaunches the preview stack with the backend volumes reset (the branch may
carry different migrations), which posts the fresh URLs and the branch serving each. Receiving reactions needs the
bot to be a chat admin and `message_reaction` in getUpdates' allowed_updates.

Keyword `relaunch` (in a project topic) rebuilds just that project's preview stack
(down → fresh up) via its <name>-dev.sh and posts the new frontend URL — the same
relaunch the checkout flow runs, but on the current checkout rather than a chosen one.

In the General topic (no registered workspace) a message that isn't `status` is
treated as a free-form instruction (Decision #11): transcribe if voice, then run
a one-shot `claude -p` in GENERAL_WORKSPACE and post its output back. This is the
one interpretation path — everything else in this daemon stays deterministic.

Config (all under $ORCH_HOME, default ~/.agent-orchestrator):
  telegram.env   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ALLOWLIST (space/comma ids),
                 MAW_SCRIPTS (path to the machines-at-work plugin's scripts/, for 🚀),
                 GENERAL_WORKSPACE (cwd for a General-topic `claude -p`),
                 PLAN_MODEL (model for the headless 🧠 plan run; default
                 claude-fable-5 — planning is the pipeline's highest-judgment,
                 lowest-token step, so it gets the strongest model; 🚀 build
                 cost lives in loop.sh's own MODEL knob, default opus)
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
PULL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-scripts", "pull.py")
CHECKOUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-scripts", "checkout.py")
PLUGIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system-scripts", "plugin.py")
RELAUNCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relaunch")
# `relaunch` skips the rebuild when the preview already serves the checked-out
# commits; `relaunch force` is the same keyword with that check turned off.
RELAUNCH_WORDS = ("relaunch", "relaunch force")
# message_id → offer map for `checkout`: reacting to an offer message triggers its
# build. Persisted so an offer survives the restart between posting and reacting.
OFFERS_FILE = os.path.join(RUN_DIR, "checkout_offers.json")
OFFERS_KEEP = 60  # cap the map so it can't grow without bound

# logmine: read new orchestrator logs → propose tooling improvements → a reaction
# on a proposal implements it (branch + PR). Mirrors the checkout offer→react→build
# flow; its message_id → proposal map is persisted the same way.
ORCH_DIR = os.path.dirname(os.path.abspath(__file__))
LOGMINE_COLLECT = os.path.join(ORCH_DIR, "logmine", "collect_logs.py")
LOGMINE_ANALYZE = os.path.join(ORCH_DIR, "logmine", "analyze.md")
LOGMINE_IMPLEMENT = os.path.join(ORCH_DIR, "logmine", "implement.md")
LOGMINE_OFFERS_FILE = os.path.join(RUN_DIR, "logmine_offers.json")

# retro: a project-topic `retro` keyword runs the plugin's /machines-at-work:retro
# headless; when the run finishes, reap_jobs posts each NEW file the skill wrote
# into <workspace>/retro/ as its own message, and a reaction on one applies it —
# a headless run in the machines-at-work repo (branch + PR), mirroring the
# logmine offer→react→implement flow. The human gate the retro skill promises
# survives as the reaction plus the PR merge.
RETRO_IMPLEMENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "retro-implement.md")
RETRO_OFFERS_FILE = os.path.join(RUN_DIR, "retro_offers.json")

# decision gate: a build task can carry a `Decision:` the builder can't invent.
# loop.sh (via the plugin's ask.sh) posts the question into the topic with
# "Reply to this message to decide" and remembers it here — message_id →
# {task, workspace}. A reply to that message routes to task.sh resolve, which
# folds the answer into the task and reopens it. Written by ask.sh, read here.
DECISION_OFFERS_FILE = os.path.join(RUN_DIR, "decision_offers.json")

# machines-at-work plugin: its SKILLS run from a version-pinned install CACHE
# (only its scripts/ run live, via MAW_SCRIPTS), so a version bump that isn't
# reinstalled leaves headless skill runs (plan/build/unblock) executing a STALE
# copy. sync_plugin() reinstalls when the source version moved, before a dispatch.
MAW_PLUGIN_ID = "machines-at-work@machines-at-work"
MAW_MARKETPLACE = "machines-at-work"
INSTALLED_PLUGINS = os.path.expanduser("~/.claude/plugins/installed_plugins.json")

# Ceiling for a General `claude -p` run. It parks the poll loop meanwhile (same
# synchronous-subprocess shape as status_report), so keep it bounded.
CLAUDE_TIMEOUT = 300

# Exact-match trigger tokens (Decision #10). Matching is on the stripped,
# case-folded message text — "plan" inside a sentence never fires.
TRIGGERS = {"🧠": "plan", "plan": "plan", "🚀": "loop", "build-all": "loop",
            "🩹": "unblock", "unblock": "unblock", "📋": "retro", "retro": "retro"}

# Headless plan needs a non-interactive permission model or every plugin script
# (inbound/freshen/task/linear/notify) hits an approval prompt with nobody to
# answer it and is denied — and the run can't reach the sibling code repos. This
# is loop.sh's proven contract: acceptEdits + an explicit tool allowlist (Bash
# included). The allowlist (Decision #4) stays the whole security boundary.
PLAN_CLAUDE_FLAGS = ["--permission-mode", "acceptEdits",
                     "--allowedTools", "Bash,Read,Edit,Write,Glob,Grep,Agent,Skill,TodoWrite"]

# Human-facing command list for the `help` keyword. Hand-synced with the keyword
# short-circuits in _route and the TRIGGERS table above — the daemon's whole
# command surface is small and deterministic, so one readable block covers it.
HELP = (
    "🤖 Orchestrator commands\n"
    "\n"
    "Any topic:\n"
    "• status — live fleet report: git branch + FE/BE up/down. In a project "
    "topic it scopes to that project; elsewhere it covers every project.\n"
    "• pull-all — fast-forward-pull every repo in the fleet (and the "
    "machines-at-work plugin); dirty trees are skipped, never clobbered.\n"
    "• 🔌 or plugin — update the machines-at-work plugin install from source and "
    "report the version each project runs (a stale cache means stale skills).\n"
    "• logmine — read the orchestrator's own logs since last time and post "
    "tooling-improvement proposals; react to one to implement it (branch + PR).\n"
    "• help — this message.\n"
    "\n"
    "In a project topic:\n"
    "• 🧠 or plan — plan the queued notes (headless /machines-at-work:plan).\n"
    "• 🚀 or build-all — run the build loop (loop.sh, detached).\n"
    "• 🩹 or unblock — diagnose why the build queue is stuck and auto-resolve the "
    "safe cases (finished-but-unmerged, clean retry); the rest are escalated with a reason.\n"
    "• 📋 or retro — mine this project's finished tasks for pipeline weaknesses "
    "(headless /machines-at-work:retro); each proposal posts back — react to one "
    "to apply it as a machines-at-work PR.\n"
    "• checkout — post the checkout options (default branch + each open-PR "
    "state); react to one to check ALL repos out, rebuild with the backend "
    "volumes reset, and get the URLs with the branch behind each.\n"
    "• relaunch — rebuild this project's preview stack from the CURRENT checkout "
    "(no branch switch, dev database kept) and post its URLs + branches. Already "
    "serving these commits? it just re-posts the URLs — `relaunch force` rebuilds "
    "anyway.\n"
    "• anything else (text, voice, or an image with optional caption) — dropped "
    "as an intent note for the next plan; an image becomes a permanent resource "
    "the plan looks at (mockup, bug screenshot, sketch).\n"
    "\n"
    "In the General topic:\n"
    "• anything (text or voice) — answered by a one-shot claude run."
)


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
        # allowed_updates must be explicit: `message_reaction` is OFF by default, and
        # naming it drops the default set — so `message` has to be listed too. (The
        # bot must also be a chat admin for Telegram to deliver reaction updates.)
        r = self._call("getUpdates", {
            "offset": offset, "timeout": timeout,
            "allowed_updates": json.dumps(["message", "message_reaction"]),
        }, timeout=timeout + 30)
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

    def download_file(self, file_id, dest_base, ext=None):
        """Download any Telegram file to dest_base + extension — taken from
        Telegram's file_path unless the caller already knows better (a document
        keeps its own name's extension). Returns the final path."""
        path = self._call("getFile", {"file_id": file_id})["result"]["file_path"]
        ext = ext or os.path.splitext(path)[1] or ".jpg"
        url = f"{self.base.replace('/bot', '/file/bot')}/{path}"
        urllib.request.urlretrieve(url, dest_base + ext)
        return dest_base + ext


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


def instruction_text(msg, api, cfg, thread_id):
    """(kind, text) for a message: transcribe voice — quoting the transcript back
    into the topic so a mis-hear is visible before it's acted on — or take raw
    text. Raises ValueError on an empty transcript or an unsupported type. Shared
    by the note-drop path (registered topic) and the `claude -p` path (General)."""
    if "voice" in msg:
        fd, dest = tempfile.mkstemp(suffix=".oga")
        os.close(fd)
        try:
            api.download_voice(msg["voice"]["file_id"], dest)
            text = transcribe(dest)
        finally:
            if os.path.exists(dest):
                os.remove(dest)
        if not text:
            raise ValueError("could not transcribe that voice note")
        api.send_message(cfg["chat_id"], f"🎙 > {text}", thread_id)
        return "voice", text
    if "text" in msg:
        return "text", msg["text"]
    raise ValueError("only voice notes and text are supported")


def run_general(prompt, cwd):
    """One-shot `claude -p` in cwd; its stdout becomes the Telegram reply, trimmed
    to Telegram's ~4096-char message ceiling. --dangerously-skip-permissions: no
    TTY exists to answer permission prompts, and the allowlist (Decision #4) is
    already the whole boundary for the loop.sh the daemon spawns on 🚀."""
    out = subprocess.run(["claude", "-p", prompt, "--dangerously-skip-permissions"],
                         cwd=cwd, capture_output=True, text=True, timeout=CLAUDE_TIMEOUT)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"claude exited {out.returncode}")
    reply = out.stdout.strip() or "(claude returned no output)"
    return reply if len(reply) <= 3900 else reply[:3900] + "\n…(truncated)"


def general(msg, cfg, api, thread_id, react, fail):
    """A General-topic message that isn't `status`: treat it as a free-form
    instruction and answer it with a one-shot `claude -p` in GENERAL_WORKSPACE.
    This is the daemon's only interpretation path — the deferred Phase-3 router
    (Decision #10), scoped to General so registered topics stay note-drop.

    Synchronous like status_report: a slow run briefly parks the poll loop —
    acceptable for one user. The upgrade path (spawn detached, post back via the
    bot API like a project's notify.sh) needs no new door. cwd is pinned to the
    projects dir, not the daemon's home — a sensible default, not a sandbox."""
    cwd = cfg.get("general_workspace")
    if not cwd:
        return fail("skip: GENERAL_WORKSPACE unset",
                    "GENERAL_WORKSPACE isn't set in telegram.env — nothing to run claude against")
    if not os.path.isdir(cwd):
        return fail(f"skip: GENERAL_WORKSPACE {cwd} missing", f"GENERAL_WORKSPACE is missing: {cwd}")
    try:
        kind, text = instruction_text(msg, api, cfg, thread_id)
    except ValueError as e:
        return fail(f"skip: {e}", str(e))
    try:
        reply = run_general(text, cwd)
    except subprocess.TimeoutExpired:
        return fail(f"claude -p timed out after {CLAUDE_TIMEOUT}s", "that took too long and was stopped")
    except Exception as e:
        return fail(f"error: claude -p failed: {e}", f"claude failed: {e}")
    api.send_message(cfg["chat_id"], reply, thread_id)
    react("👌")
    return f"general {kind} → claude -p ({len(text)} chars in, {len(reply)} out)"


def pull_report(maw_scripts=None):
    """Fast-forward-pull the whole fleet (registry repos + the machines-at-work
    scaffold when MAW_SCRIPTS is set); pull.py's stdout is the Telegram reply.
    Synchronous like status_report — parks the poll loop while pulling, bounded by
    the timeout. --repo takes any path inside the scaffold repo; pull.py resolves
    it to the repo root, so passing MAW_SCRIPTS (its scripts/ dir) is enough."""
    cmd = [sys.executable, PULL] + (["--repo", maw_scripts] if maw_scripts else [])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if out.returncode != 0:
        return f"⚠️ pull-all failed: {out.stderr.strip() or 'unknown error'}"
    return out.stdout.strip() or "(no repos)"


def plugin_report(plugin_dir=None):
    """Reinstall the machines-at-work plugin if its source moved, then report the
    version every project runs; plugin.py's stdout is the Telegram reply. The
    daemon posts it into the topic the keyword came from, so plugin.py is run
    WITHOUT --post (which would also send it to the scaffold topic).

    Same synchronous shape as status_report/pull_report — it parks the poll loop,
    bounded by the timeout. sync_plugin does this reinstall silently before a
    dispatch; the keyword is the on-demand version that also says what it found."""
    cmd = [sys.executable, PLUGIN] + (["--source", plugin_dir] if plugin_dir else [])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
    if out.returncode != 0:
        return f"⚠️ plugin failed: {out.stderr.strip() or 'unknown error'}"
    return out.stdout.strip() or "(no plugin report)"


def load_offers():
    try:
        return json.load(open(OFFERS_FILE))
    except (OSError, ValueError):
        return {}


def save_offers(offers):
    """Persist the message_id→offer map, newest-capped so it can't grow forever."""
    if len(offers) > OFFERS_KEEP:  # dict preserves insertion order → drop the oldest
        offers = dict(list(offers.items())[-OFFERS_KEEP:])
    os.makedirs(RUN_DIR, exist_ok=True)
    tmp = OFFERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(offers, f)
    os.replace(tmp, OFFERS_FILE)


def checkout_options(workspace):
    """checkout.py --json for one project → its options dict. Raises on failure."""
    out = subprocess.run([sys.executable, CHECKOUT, "--json", workspace],
                         capture_output=True, text=True, timeout=90)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "checkout enumeration failed")
    return json.loads(out.stdout)


def offer_checkout(entry, cfg, api, thread_id, react, fail):
    """`checkout` in a project topic: post one message per checkout option and
    remember each message_id → option, so reacting to one triggers its build.

    An option is a branch-per-repo state: the baseline (all repos on the default
    branch) plus one per open-PR feature branch, with repos that have no PR on
    that branch left on the default (the frontend/backend-only rule)."""
    try:
        data = checkout_options(entry["workspace"])
    except Exception as e:
        return fail(f"error: checkout enumeration failed: {e}", f"couldn't list checkout options: {e}")

    options = data["options"]
    api.send_message(cfg["chat_id"],
                     f"🔀 checkout · {data['name']} — react to an option to check it "
                     f"out, build it, and get the frontend URL:", thread_id)
    offers = load_offers()
    for opt in options:
        # checkout.py renders the body (it knows which repos a one-sided change
        # leaves on the default branch); the daemon only routes it.
        resp = api.send_message(cfg["chat_id"], f"[{opt['label']}]\n{opt['body']}", thread_id)
        mid = (resp or {}).get("result", {}).get("message_id")
        if mid is not None:
            offers[str(mid)] = {"name": data["name"], "workspace": entry["workspace"],
                                "topic": thread_id, "label": opt["label"],
                                "branches": opt["branches"]}
    save_offers(offers)
    react("👌")
    return f"checkout offered for {entry['name']} ({len(options)} option(s))"


def build_checkout(offer):
    """Detached: check out an offer's branches per repo, then relaunch (which posts
    the frontend URL to the project's topic). Runs via `checkout.py --build`."""
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(offer, f)
    return spawn_detached([sys.executable, CHECKOUT, "--build", path], os.path.dirname(CHECKOUT),
                          f"{offer['name']}.checkout")


def _maw_plugin_dir(cfg):
    s = cfg.get("maw_scripts")
    return os.path.dirname(s.rstrip("/")) if s else None


def _installed_plugin_version():
    try:
        return json.load(open(INSTALLED_PLUGINS))["plugins"][MAW_PLUGIN_ID][0]["version"]
    except Exception:
        return None


def _source_plugin_version(cfg):
    pd = _maw_plugin_dir(cfg)
    if not pd:
        return None
    try:
        return json.load(open(os.path.join(pd, ".claude-plugin", "plugin.json")))["version"]
    except Exception:
        return None


def sync_plugin(cfg):
    """Reinstall the machines-at-work plugin when its source version moved past
    what's installed, so headless skill runs (plan/build/unblock) never execute a
    STALE cached copy — the plugin's skills run from a version-pinned install
    cache, only its scripts/ run live via MAW_SCRIPTS. No-op when already current;
    best-effort, never blocks a trigger. This is what keeps the project scaffolds
    auto-updated to a new machines-at-work version."""
    src = _source_plugin_version(cfg)
    inst = _installed_plugin_version()
    if not src or src == inst:
        return
    log(f"plugin update: installed {inst} → source {src}; reinstalling cache")
    for cmd in (["claude", "plugin", "marketplace", "update", MAW_MARKETPLACE],
                ["claude", "plugin", "update", MAW_PLUGIN_ID]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            if r.returncode != 0:
                log(f"plugin update step failed (non-fatal): {r.stderr.strip()[:200]}")
        except Exception as e:
            log(f"plugin update step errored (non-fatal): {e}")


def load_logmine_offers():
    try:
        return json.load(open(LOGMINE_OFFERS_FILE))
    except (OSError, ValueError):
        return {}


def save_logmine_offers(offers):
    if len(offers) > OFFERS_KEEP:  # dict preserves insertion order → drop the oldest
        offers = dict(list(offers.items())[-OFFERS_KEEP:])
    os.makedirs(RUN_DIR, exist_ok=True)
    tmp = LOGMINE_OFFERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(offers, f)
    os.replace(tmp, LOGMINE_OFFERS_FILE)


def load_decision_offers():
    try:
        return json.load(open(DECISION_OFFERS_FILE))
    except (OSError, ValueError):
        return {}


def save_decision_offers(offers):
    os.makedirs(RUN_DIR, exist_ok=True)
    tmp = DECISION_OFFERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(offers, f)
    os.replace(tmp, DECISION_OFFERS_FILE)


def resolve_decision(mid, offer, reply_text, cfg, api, thread_id, react, fail):
    """A reply to a remembered decision question: fold the human's answer into the
    gated task (task.sh resolve, in the task's workspace) and drop the offer so it
    can't be answered twice. task.sh resolve reopens the task; the next build
    implements it."""
    text = (reply_text or "").strip()
    if not text:
        return fail("skip: empty decision reply", "reply with the decision text.")
    scripts = cfg.get("maw_scripts")
    if not scripts:
        return fail("skip: MAW_SCRIPTS unset", "MAW_SCRIPTS is not set — can't record the decision.")
    task, workspace = offer["task"], offer["workspace"]
    try:
        out = subprocess.run([os.path.join(scripts, "task.sh"), "resolve", task, text],
                             cwd=workspace, capture_output=True, text=True, timeout=60)
    except OSError as e:
        return fail(f"error: resolve spawn failed: {e}", f"couldn't record the decision: {e}")
    if out.returncode != 0:
        return fail(f"error: task.sh resolve rc={out.returncode}",
                    f"couldn't record the decision: {out.stderr.strip()[:300]}")
    offers = load_decision_offers()
    offers.pop(str(mid), None)
    save_decision_offers(offers)
    api.send_message(cfg["chat_id"],
                     f"✅ decision recorded for task {task} — back in the queue; the next build implements it.",
                     thread_id)
    react("👌")
    return f"decision resolved for task {task}"


def _json_array(text):
    """First top-level JSON array in claude's stdout (it may wrap it in prose or a
    ```json fence). [] on anything unparseable."""
    i, j = text.find("["), text.rfind("]")
    if i == -1 or j == -1 or j < i:
        return []
    try:
        v = json.loads(text[i:j + 1])
        return v if isinstance(v, list) else []
    except ValueError:
        return []


def _slug(s):
    out = "".join(c if c.isalnum() else "-" for c in s.lower()).strip("-")
    while "--" in out:
        out = out.replace("--", "-")
    return (out or "change")[:40]


def run_logmine(cfg, api, thread_id, react, fail):
    """`logmine`: read the orchestrator logs not seen since the last run, ask claude
    for tooling improvements, and post each as its own message the user can
    react-to-implement. Synchronous like a General claude run — it parks the poll
    loop, bounded by CLAUDE_TIMEOUT; acceptable for one user."""
    try:
        logs = subprocess.run([sys.executable, LOGMINE_COLLECT],
                              capture_output=True, text=True, timeout=90).stdout
    except Exception as e:
        return fail(f"error: logmine collect failed: {e}", f"couldn't read the logs: {e}")
    if logs.lstrip().startswith("(no new orchestrator logs"):
        api.send_message(cfg["chat_id"], "🔍 logmine: no new logs since the last run.", thread_id)
        react("👌")
        return "logmine: no new logs"
    api.send_message(cfg["chat_id"], "🔍 logmine: reading new logs…", thread_id)
    prompt = open(LOGMINE_ANALYZE).read() + "\n\n=== LOGS ===\n" + logs
    # Feed the prompt on stdin, not as an argv string: the collected logs run to
    # hundreds of KB and a single argument is capped at MAX_ARG_STRLEN (128 KiB),
    # so `claude -p <prompt>` dies with OSError "argument list too long". stdin
    # has no such cap.
    try:
        out = subprocess.run(["claude", "-p", "--dangerously-skip-permissions"],
                             input=prompt, cwd=ORCH_DIR, capture_output=True, text=True,
                             timeout=CLAUDE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return fail("logmine analyze timed out", "the log analysis took too long and was stopped")
    except OSError as e:
        return fail(f"error: logmine analyze spawn failed: {e}", f"couldn't start the analysis: {e}")
    if out.returncode != 0:
        return fail(f"error: logmine analyze rc={out.returncode}",
                    f"analysis failed: {out.stderr.strip()[:300]}")
    proposals = _json_array(out.stdout)
    # Watermark advances now: these logs have been analyzed (whether or not they
    # produced proposals); re-reading them would just resurface the same findings.
    try:
        subprocess.run([sys.executable, LOGMINE_COLLECT, "--commit"],
                       capture_output=True, text=True, timeout=90)
    except Exception:
        pass
    if not proposals:
        api.send_message(cfg["chat_id"], "🔍 logmine: nothing worth changing in the new logs.", thread_id)
        react("👌")
        return "logmine: no proposals"
    offers = load_logmine_offers()
    sev = {"high": "🔴", "medium": "🟠", "low": "🟡"}
    for p in proposals[:6]:
        body = (f"{sev.get(p.get('severity', ''), '•')} logmine · {p.get('repo', '?')}\n"
                f"{p.get('title', '(untitled)')}\n\n"
                f"problem: {p.get('problem', '')}\n"
                f"change: {p.get('change', '')}\n"
                f"evidence: {p.get('evidence', '')}\n\n"
                "React to this message to implement it (branch + PR).")
        resp = api.send_message(cfg["chat_id"], body, thread_id)
        mid = (resp or {}).get("result", {}).get("message_id")
        if mid is not None:
            offers[str(mid)] = {"proposal": p, "topic": thread_id}
    save_logmine_offers(offers)
    react("👌")
    return f"logmine: {len(proposals)} proposal(s) posted"


def start_logmine_implement(lm, cfg, api):
    """A reaction on a logmine proposal message: implement it headless (branch +
    PR) in its target repo with --dangerously-skip-permissions. Scope is enforced
    by the implement prompt (orchestrator or plugin only); reap_jobs posts the
    result including the PR URL (report_tail)."""
    p = lm.get("proposal", {})
    topic = lm.get("topic")
    repo = p.get("repo")
    cwd = ORCH_DIR if repo == "server-orchestrator" else _maw_plugin_dir(cfg)
    if not cwd or not os.path.isdir(cwd):
        api.send_message(cfg["chat_id"], f"⚠️ logmine: unknown target repo '{repo}' — can't implement.", topic)
        return f"logmine implement: bad repo {repo}"
    slug = _slug(p.get("title", "change"))
    base = f"logmine.{slug}"
    if pid_alive(os.path.join(RUN_DIR, base + ".pid")):
        api.send_message(cfg["chat_id"], f"⏳ already implementing “{p.get('title')}”.", topic)
        return f"skip: logmine implement already running for {slug}"
    prompt = open(LOGMINE_IMPLEMENT).read() + "\n\n=== PROPOSAL ===\n" + json.dumps(p, indent=2)
    try:
        pid = spawn_detached(["claude", "-p", prompt, "--dangerously-skip-permissions"], cwd, base,
                             track={"name": slug, "action": "logmine", "topic": topic, "report_tail": True})
    except OSError as e:
        api.send_message(cfg["chat_id"], f"⚠️ couldn't start implement: {e}", topic)
        return f"error: logmine implement spawn failed: {e}"
    api.send_message(cfg["chat_id"], f"🛠 implementing “{p.get('title')}” in {repo} — a PR will follow.", topic)
    return f"logmine implement started for {slug} (pid {pid})"


def load_retro_offers():
    try:
        return json.load(open(RETRO_OFFERS_FILE))
    except (OSError, ValueError):
        return {}


def save_retro_offers(offers):
    if len(offers) > OFFERS_KEEP:  # dict preserves insertion order → drop the oldest
        offers = dict(list(offers.items())[-OFFERS_KEEP:])
    os.makedirs(RUN_DIR, exist_ok=True)
    tmp = RETRO_OFFERS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(offers, f)
    os.replace(tmp, RETRO_OFFERS_FILE)


def _retro_files(workspace):
    d = os.path.join(workspace, "retro")
    return sorted(f for f in os.listdir(d) if f.endswith(".md")) if os.path.isdir(d) else []


def _proposal_summary(path):
    """(title, confidence) parsed leniently from a retro report — the first
    heading and the first line under '## Confidence'. Missing pieces degrade to
    the filename / empty, never an error: the daemon routes reports, it doesn't
    understand them."""
    title, conf = os.path.basename(path), ""
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return title, conf
    for i, ln in enumerate(lines):
        if ln.startswith("# ") and title == os.path.basename(path):
            title = ln.lstrip("# ").strip()
        if ln.lower().startswith("## confidence"):
            conf = next((n.strip().strip("*") for n in lines[i + 1:] if n.strip()), "")
            break
    return title, conf


def offer_retro_proposals(job, cfg, api):
    """A finished `retro` run: post each NEW file under <workspace>/retro/ into
    the topic and remember message_id → file, so a reaction applies it (a
    headless branch-plus-PR run in the machines-at-work repo). Mirrors the
    logmine offer→react→implement flow; what a report says is the skill's
    business — the daemon only routes the file."""
    new = [f for f in _retro_files(job["workspace"]) if f not in set(job.get("retro_before", []))]
    if not new:
        api.send_message(cfg["chat_id"], "📋 retro: no new proposals this run.", job.get("topic"))
        return "retro: no new proposals"
    offers = load_retro_offers()
    for fname in new[:6]:
        path = os.path.join(job["workspace"], "retro", fname)
        title, conf = _proposal_summary(path)
        body = (f"📋 retro proposal · {job['name']}\n{title}\n"
                + (f"confidence: {conf}\n" if conf else "")
                + f"\n{fname}\n\nReact to this message to apply it (branch + PR in the machines-at-work repo).")
        resp = api.send_message(cfg["chat_id"], body, job.get("topic"))
        mid = (resp or {}).get("result", {}).get("message_id")
        if mid is not None:
            offers[str(mid)] = {"file": path, "name": job["name"], "topic": job.get("topic")}
    save_retro_offers(offers)
    return f"retro: {len(new[:6])} proposal(s) offered for {job['name']}"


def start_retro_apply(ro, cfg, api):
    """A reaction on a retro proposal message: apply it headless in the
    machines-at-work repo (branch + PR) — the same shape as logmine's implement.
    The retro skill's human gate survives as the reaction plus the PR merge;
    nothing lands on a default branch."""
    topic = ro.get("topic")
    path = ro.get("file", "")
    cwd = _maw_plugin_dir(cfg)
    if not cwd or not os.path.isdir(cwd):
        api.send_message(cfg["chat_id"], "⚠️ retro: MAW_SCRIPTS unset or missing — can't apply.", topic)
        return "retro apply: no plugin dir"
    if not os.path.isfile(path):
        api.send_message(cfg["chat_id"], f"⚠️ retro: proposal file is gone: {path}", topic)
        return f"retro apply: missing {path}"
    slug = _slug(os.path.splitext(os.path.basename(path))[0])
    base = f"retro-apply.{slug}"
    if pid_alive(os.path.join(RUN_DIR, base + ".pid")):
        api.send_message(cfg["chat_id"], f"⏳ already applying {os.path.basename(path)}.", topic)
        return f"skip: retro apply already running for {slug}"
    prompt = open(RETRO_IMPLEMENT).read() + "\n\n=== PROPOSAL ===\n" + open(path).read()
    try:
        pid = spawn_detached(["claude", "-p", prompt, "--dangerously-skip-permissions"], cwd, base,
                             track={"name": slug, "action": "retro-apply", "topic": topic, "report_tail": True})
    except OSError as e:
        api.send_message(cfg["chat_id"], f"⚠️ couldn't start the apply: {e}", topic)
        return f"error: retro apply spawn failed: {e}"
    api.send_message(cfg["chat_id"], f"🛠 applying {os.path.basename(path)} — a PR will follow.", topic)
    return f"retro apply started for {slug} (pid {pid})"


def process_reaction(r, cfg, api):
    """Handle a message_reaction update. Only an allow-listed user's *added*
    reaction on a remembered checkout-offer or logmine-proposal message does
    anything — it builds that checkout, or implements that proposal. Every other
    reaction is ignored (same silence a non-allow-listed message gets: probing the
    bot must teach nothing)."""
    user = str(r.get("user", {}).get("id", ""))
    if user not in cfg["allowlist"]:
        return f"drop reaction: user {user or '?'} not allow-listed"
    if not r.get("new_reaction"):
        return "reaction removed, ignored"
    mid = str(r.get("message_id"))
    offer = load_offers().get(mid)
    if not offer:
        lm = load_logmine_offers().get(mid)
        if lm:
            return start_logmine_implement(lm, cfg, api)
        ro = load_retro_offers().get(mid)
        if ro:
            return start_retro_apply(ro, cfg, api)
        return f"reaction on non-offer message {mid}, ignored"
    base = os.path.join(RUN_DIR, f"{offer['name']}.checkout.pid")
    if pid_alive(base):
        api.send_message(cfg["chat_id"], f"⏳ {offer['name']} is already building — hang on.", offer["topic"])
        return f"skip: checkout build already running for {offer['name']}"
    pid = build_checkout(offer)
    api.send_message(cfg["chat_id"],
                     f"👌 checking out [{offer['label']}] and rebuilding {offer['name']} "
                     f"(backend volumes reset) — the URLs and the branches behind them "
                     f"will follow.", offer["topic"])
    return f"checkout+build started for {offer['name']} [{offer['label']}] (pid {pid})"


def image_payload(msg):
    """(file_id, ext_hint) when the message carries an image — a compressed photo
    (largest size Telegram offers) or an image/* document (a screenshot sent as a
    file, full quality). None otherwise."""
    if "photo" in msg:
        return msg["photo"][-1]["file_id"], None
    doc = msg.get("document")
    if doc and doc.get("mime_type", "").startswith("image/"):
        return doc["file_id"], os.path.splitext(doc.get("file_name", ""))[1] or None
    return None


def write_image_inbox(workspace, msg, api, file_id, ext_hint):
    """An image texted into a project topic: download it NEXT TO its caption note
    in updates/.inbox/ under the same <epoch>-<msgid> base, the note referencing
    it by bare basename ([image: <name>]). Still a raw drop: the plugin's
    inbound.sh moves the image to resources/ and rewrites the reference (its
    DESIGN #37) — the daemon never learns the workspace's conventions."""
    inbox = os.path.join(workspace, "updates", ".inbox")
    os.makedirs(inbox, exist_ok=True)
    base = f"{msg['date']}-{msg['message_id']}"
    img = api.download_file(file_id, os.path.join(inbox, base), ext_hint)
    caption = (msg.get("caption") or "").strip()
    with open(os.path.join(inbox, base + ".md"), "w") as f:
        f.write((caption + "\n\n" if caption else "") + f"[image: {os.path.basename(img)}]\n")
    return base + ".md"


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
    # /proc, not kill(pid, 0): the daemon doesn't reap its detached children, so a
    # finished plan/loop lingers as a ZOMBIE — still a live pid to kill(0), which
    # would wedge every future trigger at "already running". State 'Z' = not running.
    try:
        with open(f"/proc/{pid}/stat") as f:
            state = f.read().split(") ", 1)[1].split(" ", 1)[0]
        return state != "Z"
    except OSError:
        return False  # no such process: stale pidfile, proceed


# In-flight detached runs the daemon reaps + reports on: [{popen, name, action,
# topic, log}]. Fire-and-forget with only a 👌 hid failures — a run rejected or
# crashed before it could notify.sh left the user staring at "planning…" forever.
_JOBS = []
# A run can exit 0 yet have been blocked (a denied tool call reads as "success"
# once claude explains and stops). These markers in the log betray that.
# Keep them SPECIFIC to the harness's own denial text: a generic "permission
# denied" also matches infra noise (e.g. an early docker-socket blip during a
# verify that then passes), which fired a false 😱 on a clean 5-task loop — so
# it is intentionally NOT a marker.
REJECT_MARKERS = ("requires approval", "may only access")


def spawn_detached(cmd, cwd, base, track=None):
    """Start cmd detached (survives the daemon), log + pidfile under RUN_DIR.
    With `track` ({name, action, topic}) the run is registered for reap_jobs to
    watch and report on when it finishes."""
    os.makedirs(RUN_DIR, exist_ok=True)
    logpath = os.path.join(RUN_DIR, base + ".log")
    logf = open(logpath, "ab")
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL,
                         stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
    with open(os.path.join(RUN_DIR, base + ".pid"), "w") as f:
        f.write(str(p.pid))
    if track is not None:
        _JOBS.append({"popen": p, "log": logpath, **track})
    return p.pid


def _log_report(path):
    """(tail, rejected) for a finished run's log — tail for the reply, rejected
    True if a permission denial appears anywhere in it."""
    try:
        with open(path) as f:
            data = f.read()
    except OSError:
        return "(log unavailable)", False
    rejected = any(m in data.lower() for m in REJECT_MARKERS)
    tail = data[-1500:].strip() or "(no output)"
    return tail, rejected


def reap_jobs(cfg, api):
    """Poll tracked detached runs; when one finishes, reap it (no zombies) and post
    the outcome into its topic — a concise ✅ on success, a 😱 with the log tail on
    failure or rejection. (The run's own notify.sh still delivers the substance,
    e.g. the task list; this is the completion signal.) Called once per poll cycle."""
    still = []
    for j in _JOBS:
        rc = j["popen"].poll()
        if rc is None:
            still.append(j)
            continue
        tail, rejected = _log_report(j["log"])
        if rc != 0 or rejected:
            why = f"exited with code {rc}" if rc != 0 else "was blocked — a tool or command was rejected"
            api.send_message(cfg["chat_id"],
                             f"😱 {j['action']} for {j['name']} {why}:\n\n{tail}", j.get("topic"))
            log(f"{j['action']} for {j['name']} FAILED (rc={rc}, rejected={rejected})")
        else:
            done = f"✅ {j['action']} for {j['name']} finished."
            if j.get("report_tail"):   # e.g. logmine implement — surface the PR URL
                done += f"\n\n{tail}"
            api.send_message(cfg["chat_id"], done, j.get("topic"))
            log(f"{j['action']} for {j['name']} finished ok")
            if j.get("action") == "retro":   # post the run's new reports, react-to-apply
                try:
                    log(offer_retro_proposals(j, cfg, api))
                except Exception as e:
                    log(f"retro offer error (non-fatal): {e}")
    _JOBS[:] = still


def dispatch(action, entry, cfg, api, thread_id, react, fail):
    """Launch a trigger's process. 👌 means STARTED; the run's own notify.sh
    delivers the substance, and reap_jobs posts the completion signal — ✅ on
    success, 😱 + log tail if it fails or is rejected."""
    sync_plugin(cfg)   # a headless skill run must never execute a stale plugin cache
    name, workspace = entry["name"], entry["workspace"]
    if action == "loop":
        scripts = cfg.get("maw_scripts")
        if not scripts:
            return fail("skip: MAW_SCRIPTS unset",
                        "MAW_SCRIPTS is not set in telegram.env — can't launch loop.sh")
        cmd, ack = [os.path.join(scripts, "loop.sh")], "🚀 loop started"
    elif action == "unblock":
        cmd, ack = ["claude", "-p", "/machines-at-work:unblock headless", *PLAN_CLAUDE_FLAGS], "🩹 unblocking…"
    elif action == "retro":
        cmd, ack = ["claude", "-p", "/machines-at-work:retro headless", *PLAN_CLAUDE_FLAGS], \
                   "📋 retro — mining finished tasks; proposals will post back…"
    else:
        # Plan is the one dispatch that gets an explicit model: it is judgment
        # over intent (decompose, feature boundaries, Decision: gates) and its
        # short sessions make the strongest model cheap relative to the build
        # iterations a bad decomposition costs. unblock/retro stay on the CLI
        # default; loop.sh pins its own (MODEL=opus|sonnet|fable).
        cmd, ack = ["claude", "-p", "/machines-at-work:plan headless",
                    "--model", cfg["plan_model"], *PLAN_CLAUDE_FLAGS], "🧠 planning…"
    base = f"{name}.{action}"
    if pid_alive(os.path.join(RUN_DIR, base + ".pid")):
        return fail(f"skip: {action} already running for {name}", f"{action} is already running")
    # The agents declare `memory: project`, which claude resolves from cwd. The
    # registry's workspace is <root>/machines-at-work, so spawning there gave
    # every headless run a different memory store than an interactive session at
    # the project root — the stores forked and lessons stopped being delivered
    # (plugin proposals/2026-07-29-agent-memory-forks-by-cwd.md). Only the spawn
    # cwd moves; inbox writes, task.sh resolve etc. keep using `workspace`.
    root = os.path.dirname(workspace) \
        if os.path.basename(workspace.rstrip("/")) == "machines-at-work" else workspace
    track = {"name": name, "action": action, "topic": thread_id}
    if action == "retro":   # reap_jobs posts the files the run adds under retro/
        track.update(workspace=workspace, retro_before=_retro_files(workspace))
    try:
        pid = spawn_detached(cmd, root, base, track=track)
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

    # A reply to a remembered decision question folds the answer into its task and
    # reopens it. Checked first, before any keyword/note routing: the reply is free
    # text (the actual decision), not a command, and must not be misread as one.
    reply = msg.get("reply_to_message")
    if reply:
        mid = str(reply.get("message_id"))
        offer = load_decision_offers().get(mid)
        if offer:
            return resolve_decision(mid, offer, msg.get("text", ""), cfg, api, thread_id, react, fail)

    # `status` keyword: reply into the topic it came from. In a project topic it
    # reports just that project; anywhere else (General, unregistered) it reports
    # all of them. Runs before the note-routing path — it never writes a note.
    if stripped == "status":
        api.send_message(cfg["chat_id"], status_report(entry["workspace"] if entry else None), thread_id)
        react("👌")
        return f"status report sent ({entry['name'] if entry else 'all'})"

    # `pull-all`: fleet-wide, so it short-circuits routing like `status` and works
    # in any topic. Includes the machines-at-work scaffold (MAW_SCRIPTS), which
    # lives outside every project workspace. Never writes a note.
    if stripped in ("pull-all", "pull all"):
        api.send_message(cfg["chat_id"], pull_report(cfg.get("maw_scripts")), thread_id)
        react("👌")
        return "pull-all done"

    # `plugin` (or 🔌): box-level like status/pull-all — the plugin install is
    # user-scope, one copy serving every project, so this is never topic-scoped.
    # It reinstalls a moved version and reports what each project actually runs;
    # the reply goes to the topic it was asked from. Never writes a note.
    if stripped in ("plugin", "🔌"):
        api.send_message(cfg["chat_id"], plugin_report(_maw_plugin_dir(cfg)), thread_id)
        react("👌")
        return "plugin report sent"

    # `logmine`: box-level like status/pull-all — read the orchestrator's own logs
    # since the last run and post tooling-improvement proposals to react-to-implement.
    if stripped == "logmine":
        return run_logmine(cfg, api, thread_id, react, fail)

    # `help`: list every command. Short-circuits routing like `status` — works in
    # any topic and never writes a note.
    if stripped in ("help", "/help"):
        api.send_message(cfg["chat_id"], HELP, thread_id)
        react("👌")
        return "help sent"

    # relaunch is project-scoped — it rebuilds ONE project's preview. In a topic
    # with no workspace, say so rather than firing a free-form `claude -p`.
    if stripped in RELAUNCH_WORDS and not entry:
        return fail("skip: relaunch needs a project topic",
                    "run `relaunch` inside a project topic — it rebuilds that project's preview.")

    if not entry:
        # General (or any unregistered topic): not a command, so treat the
        # message as a free-form instruction and answer it with `claude -p`.
        return general(msg, cfg, api, thread_id, react, fail)
    workspace = entry["workspace"]
    if not os.path.isdir(workspace):
        return fail(f"skip: workspace {workspace} missing (registry drift)",
                    f"registered workspace is missing: {workspace}")

    # `checkout`: post the project's checkout options (branch-per-repo states) so
    # reacting to one builds it. Project-scoped — it needs this topic's repos.
    if stripped == "checkout":
        return offer_checkout(entry, cfg, api, thread_id, react, fail)

    # `relaunch`: rebuild just this project's preview stack (down → fresh up) and
    # post the new frontend URL. Detached — the rebuild takes minutes; relaunch
    # posts the URL (or a failure) into the topic itself when it's done.
    if stripped in RELAUNCH_WORDS:
        name = entry["name"]
        base = f"{name}.relaunch"
        if pid_alive(os.path.join(RUN_DIR, base + ".pid")):
            return fail(f"skip: relaunch already running for {name}", "a relaunch is already running")
        # A plain `relaunch` no-ops when the preview already serves the checked-out
        # commits (relaunch's build watermark). `relaunch force` is the way to say
        # "I don't care what the watermark thinks, build it again" from the phone —
        # the only escape hatch a Telegram user has when a preview looks wrong in a
        # way the watermark can't see.
        argv = [RELAUNCH, name] if stripped == "relaunch" else [RELAUNCH, "--force", name]
        try:
            pid = spawn_detached(argv, os.path.dirname(RELAUNCH), base)
        except OSError as e:
            return fail(f"error: spawn relaunch failed: {e}", f"couldn't start relaunch: {e}")
        api.send_message(cfg["chat_id"], f"🚀 relaunching {name} — the fresh frontend URL will follow.", thread_id)
        react("👌")
        return f"relaunch started for {name} (pid {pid})"

    action = TRIGGERS.get(stripped)
    if action:
        return dispatch(action, entry, cfg, api, thread_id, react, fail)

    # An image (photo, or a screenshot sent as a file) is intent like text: it
    # drops into the inbox next to its caption note, and the next plan reads the
    # picture itself — a mockup, a bug screenshot, a sketch.
    img = image_payload(msg)
    if img:
        try:
            name = write_image_inbox(workspace, msg, api, *img)
        except Exception as e:
            return fail(f"error: image download failed: {e}", f"couldn't fetch that image: {e}")
        react("👌")
        return f"queued image → {entry['name']}/updates/.inbox/{name}"

    try:
        kind, text = instruction_text(msg, api, cfg, thread_id)
    except ValueError as e:
        return fail(f"skip: {e}", str(e))

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
            "allowlist": allowlist, "maw_scripts": env.get("MAW_SCRIPTS"),
            "general_workspace": env.get("GENERAL_WORKSPACE"),
            "plan_model": env.get("PLAN_MODEL", "claude-fable-5")}


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
            reaction = u.get("message_reaction")
            if msg:
                try:
                    # reload registry per message: a newly-registered topic works without a restart
                    log(process_message(msg, cfg, load_registry(), api))
                except Exception as e:
                    log(f"error on update {u['update_id']}: {e}")
            elif reaction:
                try:
                    log(process_reaction(reaction, cfg, api))
                except Exception as e:
                    log(f"error on reaction update {u['update_id']}: {e}")
            write_offset(offset)
        try:  # report + reap any finished plan/loop runs (every cycle, even with no updates)
            reap_jobs(cfg, api)
        except Exception as e:
            log(f"reap_jobs error: {e}")
        if once:
            return


if __name__ == "__main__":
    run(once="--once" in sys.argv[1:])
