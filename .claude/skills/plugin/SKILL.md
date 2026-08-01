---
name: plugin
description: Update the intentpipe plugin install from its source tree and post the version every project is running. Use for "update the plugin", "what plugin version are the projects on", "is the plugin cache stale".
argument-hint: "[check] [pull]"
---

Mode: $ARGUMENTS (empty → update, then post). You run one script and read its output; you never hand-edit an install cache, a project's settings, or a version number.

Script: `$(git rev-parse --show-toplevel)/system-scripts/plugin.py` — the mechanics (resolve source, compare, reinstall, enumerate projects, post) live there, not in this skill.

1. Run it, mapping the argument: `check` → `--check` (report only, changes nothing), `pull` → `--pull` (fast-forward the plugin source repo first, skipping it if the tree is dirty), no argument → plain (reinstall the cache when the source moved). Add `--post` unless the human asked for a local look only — posting the report into the scaffold topic is the point of the run.
2. Relay the report as-is. It has three parts: the **source** version + the branch/sha it came from, the **cache** transition (`0.24.0 → 0.26.0 ✅ reinstalled`, `✅ current`, or a `⚠️` that names why it isn't), and one line **per registered project**. One user-scope install serves every project, so a project's line is the cache version it resolves to — what actually differs per project is whether it enables the plugin at all.
3. Act on the warnings rather than restating them:
   - **`⚠️ not enabled` / `⚠️ disabled`** — that project runs *no* version of the plugin: its `/intentpipe:*` skills and the 🧠/🚀/🩹 triggers in its topic do nothing. Quote the one-line fix from the report and let the human apply it; do not edit another project's `.claude/settings.json` from here.
   - **`⚠️ still not current`** — the reinstall ran and the version didn't move. Read the error the report names; the usual cause is `claude plugin update` failing on a marketplace that no longer resolves. Do not fake it by copying files into the cache.
   - **`⚠️ cache dir … holds …`** — the pinned copy the skills load isn't what the install record claims. Say so plainly; this is the stale-skill trap the whole script exists to catch.
   - **source on a feature branch or dirty (`*`)** — not an error, but say which branch the installed version came from: a cache built from an unmerged branch is what every project is now running.
4. If the source version and the cache already match, say so in one line and stop. There is nothing to do and no reason to reinstall.

The same op is a Telegram keyword — `plugin` or 🔌, in any topic — running the same script. That surface always updates-then-reports; the modes above are what a terminal wants and a phone doesn't.

Why this exists: the plugin's **skills** run from a version-pinned install cache, only its `scripts/` run live via `INTENTPIPE_SCRIPTS`. A version bump that is never reinstalled leaves every project's headless plan/build/unblock executing a stale copy — the cache once sat at 0.19.0, predating the `unblock` skill entirely, so 🩹 invoked a skill that wasn't installed. `daemon.sync_plugin` closes that before a dispatch; this is the same operation on demand, plus the per-project answer to "what are we actually running".
