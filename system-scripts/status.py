#!/usr/bin/env python3
"""Collect the live state of every registered project — for the Telegram `status` keyword.

Cross-project, above any single workspace (same layer as the daemon, NOT plugin
code). Joins two sources:

  $ORCH_HOME/registry.json          which projects exist + their workspace dirs
                                    (the daemon's topic→workspace map, reused)
  system-scripts/ports.json         per-project FE/BE host ports to probe

For each project it reports, per code repo, the current git branch (+ `*` if the
working tree is dirty), and whether the backend/frontend ports are listening.
Pure stdlib, no deps — matches daemon.py so the daemon can shell out to it the
same way it does transcribe.sh.

Run:  system-scripts/status.py                 # report on every project
      system-scripts/status.py <workspace>     # report on just that one project
"""
import json
import os
import re
import socket
import subprocess

ORCH_HOME = os.environ.get("ORCH_HOME", os.path.expanduser("~/.agent-orchestrator"))
REGISTRY = os.path.join(ORCH_HOME, "registry.json")
PORTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ports.json")


def _load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _projects():
    """Distinct {name, workspace} from the registry (a project may own several topics)."""
    seen, out = set(), []
    for entry in _load_json(REGISTRY).values():
        ws = entry.get("workspace")
        if ws and ws not in seen:
            seen.add(ws)
            out.append({"name": entry.get("name", "?"), "workspace": ws})
    return sorted(out, key=lambda p: p["name"])


def _parse_agents_env(path):
    """Return [(repo_name, abs_repo_path)] from a workspace's agents.env.

    agents.env is shell: REPOS="a b", REPO_a=../a. We only need those two keys,
    so a light line parse beats sourcing a shell."""
    vals = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                m = re.match(r'^(REPOS|REPO_[A-Za-z0-9_]+)=(.*)$', line)
                if m:
                    vals[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    except OSError:
        return []
    base = os.path.dirname(path)
    repos = []
    for name in vals.get("REPOS", "").split():
        rel = vals.get(f"REPO_{name}")
        if rel:
            repos.append((name, os.path.normpath(os.path.join(base, rel))))
    return repos


def _git(repo, *args):
    try:
        out = subprocess.run(["git", "-C", repo, *args],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _branch(repo):
    if not os.path.isdir(os.path.join(repo, ".git")):
        return "no-git"
    br = _git(repo, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    dirty = _git(repo, "status", "--porcelain")
    return f"{br}{'*' if dirty else ''}"


def _listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.4):
            return True
    except OSError:
        return False


def _svc(ports, key):
    port = ports.get(key)
    if not port:
        return f"{key}: n/a"
    return f"{key}: {'🟢' if _listening(port) else '🔴'} :{port}"


def build_report(only_workspace=None):
    """Report on every registered project, or just the one at `only_workspace`."""
    projects = _projects()
    if only_workspace:
        want = os.path.normpath(only_workspace)
        projects = [p for p in projects if os.path.normpath(p["workspace"]) == want]
        if not projects:
            return f"No project registered for workspace {only_workspace}."
    if not projects:
        return "No projects registered (empty registry.json)."
    ports_map = _load_json(PORTS)
    lines = ["📊 Project status", ""]
    for p in projects:
        lines.append(f"• {p['name']}")
        ws = p["workspace"]
        repos = _parse_agents_env(os.path.join(ws, "agents.env"))
        if repos:
            lines.append("   branches: " + ", ".join(f"{n} {_branch(path)}" for n, path in repos))
        else:
            lines.append(f"   branches: (no agents.env at {ws})")
        ports = ports_map.get(p["name"], {})
        lines.append("   running:  " + " · ".join([_svc(ports, "backend"), _svc(ports, "frontend")]))
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    print(build_report(sys.argv[1] if len(sys.argv) > 1 else None))
