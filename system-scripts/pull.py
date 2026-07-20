#!/usr/bin/env python3
"""Fast-forward-pull every repo in the fleet — for the Telegram `pull-all` keyword.

Same layer/enumeration as status.py (which it imports, not duplicates): registry
projects → each workspace's agents.env → its code repos, plus any extra repos
passed on the command line. The daemon passes MAW_SCRIPTS so the machines-at-work
plugin repo — outside any project workspace — is pulled too.

Pulling can silently eat uncommitted work, so each repo is guarded: pulled only
if its working tree is clean, and only as a fast-forward. A dirty or diverged
repo is reported and SKIPPED, never clobbered — the same "don't touch dirty" rule
`status` already surfaces with its `*` marker.

Run:  pull.py [--repo <path-inside-a-git-repo> ...]
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status  # reuse _projects, _parse_agents_env, _git — one source of fleet truth


def _pull_one(path):
    """Pull the git repo containing `path` (a repo root or any subdir of one).
    Returns (repo_root_or_path, result_line). Never modifies a dirty/diverged repo."""
    top = status._git(path, "rev-parse", "--show-toplevel")
    if not top:
        return path, "⚠️ not a git repo"
    dirty = status._git(top, "status", "--porcelain")
    if dirty:
        n = len(dirty.splitlines())
        return top, f"⏭ skipped (dirty, {n} file{'s' if n != 1 else ''})"
    before = status._git(top, "rev-parse", "HEAD")
    out = subprocess.run(["git", "-C", top, "pull", "--ff-only"],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        tail = (out.stderr.strip().splitlines() or ["pull failed"])[-1]
        return top, f"⚠️ {tail}"
    after = status._git(top, "rev-parse", "HEAD")
    branch = status._git(top, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    return top, (f"{branch} ✅ up to date" if before == after else f"{branch} ✅ pulled")


def build_report(extra_repos=()):
    """Pull every registered project's repos, then each extra repo (e.g. the
    machines-at-work scaffold). Text output is the Telegram reply."""
    lines = ["📥 pull-all", ""]
    for p in status._projects():
        lines.append(f"• {p['name']}")
        repos = status._parse_agents_env(os.path.join(p["workspace"], "agents.env"))
        if not repos:
            lines.append(f"   (no agents.env at {p['workspace']})")
            continue
        for name, path in repos:
            _, res = _pull_one(path)
            lines.append(f"   {name} {res}")
    for extra in extra_repos:
        top, res = _pull_one(extra)
        lines.append(f"• {os.path.basename(top)} {res}")
    return "\n".join(lines)


if __name__ == "__main__":
    extras, argv, i = [], sys.argv[1:], 0
    while i < len(argv):
        if argv[i] == "--repo" and i + 1 < len(argv):
            extras.append(argv[i + 1]); i += 2
        else:
            i += 1
    print(build_report(extras))
