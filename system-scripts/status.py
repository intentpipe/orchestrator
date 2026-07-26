#!/usr/bin/env python3
"""Collect the live state of every registered project — for the Telegram `status` keyword.

Cross-project, above any single workspace (same layer as the daemon, NOT plugin
code). Joins two sources:

  $ORCH_HOME/registry.json          which projects exist + their workspace dirs
                                    (the daemon's topic→workspace map, reused)
  system-scripts/ports.json         per-project FE/BE host ports to probe

For each project it reports each served service — port state, its public preview
URL, and the repo + branch + sha behind that URL (+ `*` if the working tree is
dirty). When the repos are on different branches it says which kind of split that
is: expected (a one-sided change — the other repo simply has no such branch) or a
MIXED CHECKOUT, where a repo has the feature branch but isn't on it — what "the
frontend is showing the PR but the backend isn't" looks like from here.
Pure stdlib, no deps — matches daemon.py so the daemon can shell out to it the
same way it does transcribe.sh.

Run:  system-scripts/status.py                 # report on every project
      system-scripts/status.py <workspace>     # report on just that one project
"""
import http.client
import json
import os
import re
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
    """"<branch>[*] (<sha>)" — `*` = dirty tree. The sha matters as much as the
    name: a branch that moved (a PR updated with new commits) is the same name
    with a different tip, and a preview built before that push is stale."""
    if not os.path.isdir(os.path.join(repo, ".git")):
        return "no-git"
    br = _git(repo, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    dirty = _git(repo, "status", "--porcelain")
    return f"{br}{'*' if dirty else ''} ({_git(repo, 'log', '-1', '--format=%h') or '?'})"


def _probe(port, path="/"):
    """HTTP GET 127.0.0.1:<port><path>. Returns (state, http_code):
      'up'       — got an HTTP response < 500 (serving; 404/401 still count)
      'erroring' — got an HTTP response >= 500, or a bound port that isn't HTTP
                   (a hung dev server that 500s reads as erroring, not up)
      'down'     — nothing accepting the connection
    A plain TCP check can't tell 'up' from 'erroring' — that gap is why a broken
    service showed a false 🟢."""
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            conn.request("GET", path)
            code = conn.getresponse().status
        finally:
            conn.close()
        return ("erroring", code) if code >= 500 else ("up", code)
    except OSError:
        return ("down", None)
    except Exception:  # connected, but not speaking HTTP
        return ("erroring", None)


_ICON = {"up": "🟢", "erroring": "🟠", "down": "🔴"}


def _svc(ports, key, branches):
    """Lines for one service. `ports[key]` is a bare port int, or
    {"port", "health", "url", "repo"} — with `url`/`repo` the report names the
    public URL and, under it, the repo + branch + sha it is currently serving.
    That pairing is the point: a preview URL is stable, so the only thing that
    tells you WHAT it is serving is the branch behind it."""
    spec = ports.get(key)
    port = spec.get("port") if isinstance(spec, dict) else spec
    if not port:
        return [f"   {key + ':':<9} n/a"]
    path = spec.get("health", "/") if isinstance(spec, dict) else "/"
    state, code = _probe(port, path)
    tail = f":{port} ({code})" if state == "erroring" and code else f":{port}"
    url = spec.get("url") if isinstance(spec, dict) else None
    lines = [f"   {key + ':':<9} {_ICON[state]} {tail}" + (f"  {url}" if url else "")]
    repo = spec.get("repo") if isinstance(spec, dict) else None
    if repo:
        lines.append(f"      ↳ {repo} @ {branches.get(repo, '(not in agents.env)')}")
    return lines


def _default_branch(workspace):
    """DEFAULT_BRANCH from the workspace's agents.env; `main` when unset. The
    branch a repo sits on when a change doesn't touch it."""
    try:
        with open(os.path.join(workspace, "agents.env")) as f:
            for line in f:
                if line.strip().startswith("DEFAULT_BRANCH="):
                    return line.strip().split("=", 1)[1].strip().strip('"').strip("'") or "main"
    except OSError:
        pass
    return "main"


def _split_note(repo_paths, branches, default):
    """The one line to say about repos being on different branches — or None.

    Not every split is wrong. Most changes touch one repo only, so a
    frontend-only PR *correctly* leaves the backend on the default branch;
    flagging that would cry wolf on the common case. What is wrong is a repo
    sitting on the default branch when the feature branch exists for it too —
    that is the frontend-showing-the-PR-but-not-the-backend defect.
    """
    names = {n: b.split()[0].rstrip("*") for n, b in branches.items()}
    if len(set(names.values())) <= 1:
        return None
    feature = {n: b for n, b in names.items() if b != default}
    baseline = [n for n, b in names.items() if b == default]
    if len(set(feature.values())) > 1:
        return ("⚠️ MIXED CHECKOUT: " + ", ".join(f"{n} on {b}" for n, b in sorted(names.items()))
                + " — unrelated branches, so at least one is stale")
    branch = next(iter(feature.values()))
    # A repo on the default branch that HAS the feature branch should be on it.
    stale = [n for n in baseline
             if _git(repo_paths[n], "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}") is not None
             or _git(repo_paths[n], "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}") is not None]
    if stale:
        return (f"⚠️ MIXED CHECKOUT: {', '.join(stale)} has '{branch}' but serves {default} "
                "— the preview is a mixture")
    return (f"ℹ️ one-sided change: {', '.join(sorted(feature))} on '{branch}'; "
            f"{', '.join(sorted(baseline))} has no such branch and serves {default} — expected")


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
        branches = {n: _branch(path) for n, path in repos}
        ports = ports_map.get(p["name"], {})
        for key in ("frontend", "backend"):
            lines += _svc(ports, key, branches)
        # Repos not bound to a served port still belong in the report — they are
        # part of the checkout state even when nothing serves them directly.
        rest = [n for n in branches
                if n not in {s.get("repo") for s in ports.values() if isinstance(s, dict)}]
        if rest:
            lines.append("   other repos: " + ", ".join(f"{n} @ {branches[n]}" for n in rest))
        elif not repos:
            lines.append(f"   repos: (no agents.env at {ws})")
        note = _split_note(dict(repos), branches, _default_branch(ws))
        if note:
            lines.append("   " + note)
    return "\n".join(lines)


if __name__ == "__main__":
    import sys
    print(build_report(sys.argv[1] if len(sys.argv) > 1 else None))
