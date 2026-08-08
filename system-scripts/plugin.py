#!/usr/bin/env python3
"""Update the intentpipe plugin install and report the version each project runs.

The trap this closes: the plugin's **skills** run from a version-pinned install
cache (`~/.claude/plugins/cache/...`), while only its `scripts/` run live via
INTENTPIPE_SCRIPTS. A version bump in the source tree that is never reinstalled leaves
every project's headless skill run (plan/build/unblock) executing a STALE copy —
the cache once sat at 0.19.0, predating the `unblock` skill entirely, so 🩹
invoked a skill that wasn't installed. `daemon.sync_plugin` does this reinstall
before a dispatch; this script is the same operation on demand, plus the report
that says what every project is actually on.

One install serves the whole box (user scope), so "the version this project is
on" is the cache version — what genuinely varies per project is whether the
project **enables** the plugin at all (`<root>/.claude/settings.json` →
`enabledPlugins`). A project that doesn't runs no version of it, which is why
that is the per-project line rather than a version repeated N times.

Same layer and enumeration as status.py (which it imports, not duplicates):
registry projects → workspace → project root. Pure stdlib.

Run:  plugin.py                 # reinstall the cache if the source moved, then report
      plugin.py --check         # report only, change nothing
      plugin.py --pull          # fast-forward the source repo first, then update
      plugin.py --post          # also post the report into Telegram
      plugin.py --source <dir>  # plugin source tree (default: the marketplace's)
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status  # reuse _projects and _git — one source of fleet truth
import pull    # reuse _pull_one — one source of the "never clobber a dirty tree" rule

PLUGIN_ID = "intentpipe@intentpipe"
MARKETPLACE = "intentpipe"
CLAUDE_HOME = os.path.expanduser("~/.claude")
INSTALLED = os.path.join(CLAUDE_HOME, "plugins", "installed_plugins.json")
MARKETPLACES = os.path.join(CLAUDE_HOME, "plugins", "known_marketplaces.json")
ORCH_HOME = os.environ.get("ORCH_HOME", os.path.expanduser("~/.agent-orchestrator"))
TELEGRAM_ENV = os.environ.get("TELEGRAM_ENV", os.path.join(ORCH_HOME, "telegram.env"))


def _load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def source_dir(explicit=None):
    """Where the plugin is authored. The marketplace is registered as a directory,
    so its installLocation IS the source tree; INTENTPIPE_SCRIPTS (the daemon's handle on
    the same repo) is the fallback for a box that registered it differently."""
    if explicit:
        return explicit
    loc = _load_json(MARKETPLACES).get(MARKETPLACE, {}).get("installLocation")
    if loc and os.path.isdir(loc):
        return loc
    scripts = os.environ.get("INTENTPIPE_SCRIPTS")
    return os.path.dirname(scripts.rstrip("/")) if scripts else None


def _manifest_version(root):
    """Version from a plugin tree's manifest — works on the source tree and on an
    install cache dir alike (both carry .claude-plugin/plugin.json)."""
    if not root:
        return None
    return _load_json(os.path.join(root, ".claude-plugin", "plugin.json")).get("version")


def installed_entry():
    """The install record the projects resolve to: {version, installPath, scope}.
    Prefer the user-scope entry — that is the one install serving every project."""
    entries = _load_json(INSTALLED).get("plugins", {}).get(PLUGIN_ID) or []
    if not entries:
        return {}
    return next((e for e in entries if e.get("scope") == "user"), entries[0])


def project_pin(root):
    """A project-scoped install record for this root. It SHADOWS the user-scope
    cache for every session started in the project — a reinstall bumps user
    scope only, so the pin silently keeps that one project on the old version
    (quorum sat on 0.41.0 this way while the report said 0.41.1 fleet-wide)."""
    real = os.path.realpath(root)
    for e in _load_json(INSTALLED).get("plugins", {}).get(PLUGIN_ID) or []:
        if e.get("scope") == "project" and os.path.realpath(e.get("projectPath", "?")) == real:
            return e
    return None


def _update_cache():
    """Refresh the marketplace, then reinstall the plugin — daemon.sync_plugin's two
    steps. Returns an error string, or None on success."""
    for cmd in (["claude", "plugin", "marketplace", "update", MARKETPLACE],
                ["claude", "plugin", "update", PLUGIN_ID]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        except Exception as e:  # missing binary, timeout — report, never raise
            return f"{' '.join(cmd[:3])}: {e}"
        if r.returncode != 0:
            return (r.stderr.strip() or r.stdout.strip() or "failed").splitlines()[-1][:200]
    return None


def _enabled_in(root):
    """Does this project switch the plugin on? Both settings files count — a repo
    commits settings.json, a box-local override lands in settings.local.json."""
    for name in ("settings.json", "settings.local.json"):
        val = _load_json(os.path.join(root, ".claude", name)).get("enabledPlugins", {}).get(PLUGIN_ID)
        if val is not None:
            return bool(val), name
    return None, None


def build_report(check=False, do_pull=False, explicit_source=None):
    """Update (unless --check) and render the report. Text output is the Telegram post."""
    lines = ["🔌 intentpipe plugin", ""]
    src = source_dir(explicit_source)
    if not src:
        return "\n".join(lines + ["⚠️ no plugin source found — register the marketplace or set INTENTPIPE_SCRIPTS"])

    if do_pull:
        _, res = pull._pull_one(src)  # dirty/diverged is skipped and said, never clobbered
        lines.append(f"source repo {res}")

    src_version = _manifest_version(src)
    branch = status._git(src, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    sha = status._git(src, "rev-parse", "--short", "HEAD") or "?"
    dirty = "*" if status._git(src, "status", "--porcelain") else ""
    lines.append(f"source  {src_version or '?'}  ({branch} {sha}{dirty})")

    before = installed_entry().get("version")
    if not src_version:
        # No manifest to compare against — say so rather than call the cache
        # "current" against a version we never read.
        state = f"{before or '(none)'} ⚠️ cannot tell — no readable manifest at {src}"
    elif before != src_version and not check:
        err = _update_cache()
        after = installed_entry().get("version")
        state = f"{before or '(none)'} → {after or '?'} " + (
            "✅ reinstalled" if after == src_version else f"⚠️ still not current — {err or 'update ran but the version did not move'}")
    elif before != src_version:
        state = f"{before or '(none)'} ⚠️ STALE — source is {src_version} (run without --check to reinstall)"
    else:
        state = f"{before} ✅ current"
    lines.append(f"cache   {state}")

    # A cache dir whose manifest disagrees with the record (or is gone) means the
    # pinned copy the skills load is not what the record claims it is.
    entry = installed_entry()
    path, recorded = entry.get("installPath"), entry.get("version")
    on_disk = _manifest_version(path) if path and os.path.isdir(path) else None
    if recorded and on_disk != recorded:
        lines.append(f"⚠️ cache dir {path or '(missing)'} holds {on_disk or 'nothing'}, not {recorded}")

    lines.append("")
    running = installed_entry().get("version") or "?"
    projects = status._projects()
    if not projects:
        lines.append("(no registered projects)")
    width = max((len(p["name"]) for p in projects), default=0)
    for p in projects:
        root = os.path.dirname(p["workspace"].rstrip("/"))  # workspace = <root>/intentpipe
        enabled, where = _enabled_in(root)
        pin = project_pin(root) if enabled else None
        if pin and pin.get("version") != running:
            note = (f"{pin.get('version') or '?'} ⚠️ project-scope pin shadows the {running} user install "
                    f"— fix: cd {root} && claude plugin uninstall -s project --keep-data {PLUGIN_ID}, "
                    f"then restore enabledPlugins in .claude/settings.json (uninstall clears it)")
        elif pin:
            note = (f"{running} ✅ but project-scope pinned — the NEXT reinstall will strand it; "
                    f"remove the pin (claude plugin uninstall -s project --keep-data, then restore enabledPlugins)")
        elif enabled:
            note = f"{running} ✅" + ("" if where == "settings.json" else f" (via {where})")
        elif enabled is False:
            note = "— ⚠️ disabled in .claude/" + where
        else:
            note = '— ⚠️ not enabled (add "%s": true under enabledPlugins in .claude/settings.json)' % PLUGIN_ID
        lines.append(f"• {p['name'].ljust(width)}  {note}")
    return "\n".join(lines)


def post(text):
    """Post the report into the scaffold topic — the maintainer inbox (README).
    No topic id set → the group's General topic. Never fails its caller."""
    env = {}
    try:
        with open(TELEGRAM_ENV) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    except OSError:
        pass
    token, chat = env.get("TELEGRAM_BOT_TOKEN"), env.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        print("[plugin] no telegram creds — printed only", file=sys.stderr)
        return False
    data = {"chat_id": chat, "text": text}
    topic = env.get("SCAFFOLD_RETRO_TOPIC_ID")
    if topic:
        data["message_thread_id"] = topic
    try:
        req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
                                     data=urllib.parse.urlencode(data).encode())
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r).get("ok", False)
    except Exception as e:
        print(f"[plugin] telegram send failed: {e}", file=sys.stderr)
        return False


if __name__ == "__main__":
    argv = sys.argv[1:]
    explicit = argv[argv.index("--source") + 1] if "--source" in argv and len(argv) > argv.index("--source") + 1 else None
    report = build_report(check="--check" in argv, do_pull="--pull" in argv, explicit_source=explicit)
    print(report)
    if "--post" in argv:
        post(report)
