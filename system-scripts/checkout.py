#!/usr/bin/env python3
"""Enumerate — and, on demand, realise — the checkout options for a project.

For the Telegram `checkout` keyword. Cross-project, above any single workspace
(same layer as status.py / pull.py, NOT plugin code); it reuses status.py's
registry + agents.env + git helpers so there is one source of fleet truth.

An *option* is one coherent working-tree state for the whole project: a branch
per code repo. The options are:

  • baseline    — every repo on its DEFAULT_BRANCH (the mainline / merged state).
  • per feature — one option per open-PR head branch. PRs are grouped across
                  repos by head branch, so a feature that touches both repos
                  (same branch name in each — machines-at-work's task branches
                  are named identically per repo) becomes a single option with
                  both repos on it. A repo with no open PR on that branch stays
                  on DEFAULT_BRANCH — e.g. a frontend-only PR leaves the backend
                  on `dev`. That "the other repo stays on default" rule is the
                  whole reason a feature is an option and not a per-repo branch.

`gh` is used to list open PRs; a repo with no `gh`/origin (e.g. a solo
DONE=local project) simply contributes no PR options — never an error.

Run:  checkout.py <workspace>            # human-readable option list
      checkout.py --json <workspace>     # options as JSON (the daemon posts these)
      checkout.py --build <offer.json>   # check out an option's branches, then relaunch
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import status  # reuse _projects, _parse_agents_env, _git — one source of fleet truth

RELAUNCH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "relaunch")


def _default_branch(workspace):
    """DEFAULT_BRANCH from the workspace's agents.env (one value per project);
    falls back to `main` when unset."""
    path = os.path.join(workspace, "agents.env")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("DEFAULT_BRANCH="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'") or "main"
    except OSError:
        pass
    return "main"


def _open_prs(repo):
    """Open PRs in `repo` as [{number, title, headRefName, url}] via gh.
    Any failure (no gh, no origin, not authenticated) → [] — never fatal: a repo
    that can't have PRs just contributes no PR options."""
    if not os.path.isdir(os.path.join(repo, ".git")):
        return []
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--state", "open", "--json", "number,title,headRefName,url"],
            cwd=repo, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return []
    if out.returncode != 0:
        return []
    try:
        return json.loads(out.stdout or "[]")
    except ValueError:
        return []


def options_for(workspace):
    """Every checkout option for the project at `workspace`.

    Returns {name, workspace, default, options:[{label, branches:{repo:branch},
    prs:[{repo,number,title,url}]}]}. options[0] is always the baseline."""
    name = "?"
    for p in status._projects():
        if os.path.normpath(p["workspace"]) == os.path.normpath(workspace):
            name = p["name"]
            break
    repos = status._parse_agents_env(os.path.join(workspace, "agents.env"))
    default = _default_branch(workspace)

    prs_by_repo = {rname: _open_prs(path) for rname, path in repos}
    # distinct FEATURE branches (a PR whose head IS the default branch — e.g. a
    # dev→main release PR — is not a distinct checkout state, so it annotates the
    # baseline instead of spawning a duplicate option).
    branches = sorted({pr["headRefName"] for prs in prs_by_repo.values()
                       for pr in prs if pr["headRefName"] != default})

    baseline = {"label": f"{default} (baseline)",
                "branches": {rname: default for rname, _ in repos},
                "prs": [{"repo": rname, "number": pr["number"], "title": pr["title"], "url": pr["url"]}
                        for rname, _ in repos for pr in prs_by_repo[rname]
                        if pr["headRefName"] == default]}
    options = [baseline]
    for b in branches:
        branch_map, prs = {}, []
        for rname, _ in repos:
            match = next((pr for pr in prs_by_repo[rname] if pr["headRefName"] == b), None)
            if match:
                branch_map[rname] = b
                prs.append({"repo": rname, "number": match["number"],
                            "title": match["title"], "url": match["url"]})
            else:
                branch_map[rname] = default  # no PR here → stay on default (the FE/BE-only rule)
        options.append({"label": b, "branches": branch_map, "prs": prs})
    return {"name": name, "workspace": workspace, "default": default, "options": options}


def render_option(opt):
    """One option as a Telegram message body (repo→branch, with PR annotations)."""
    lines = [f"• {r}: {br}" for r, br in opt["branches"].items()]
    for pr in opt["prs"]:
        lines.append(f"    ↳ {pr['repo']} PR #{pr['number']}: {pr['title']}")
    return "\n".join(lines)


def render(workspace):
    """Full human-readable option list for one project (CLI / debugging)."""
    data = options_for(workspace)
    if not any(data["options"][0]["branches"]):
        return f"{data['name']}: no code repos in agents.env — nothing to check out."
    out = [f"🔀 checkout · {data['name']}", ""]
    for i, opt in enumerate(data["options"]):
        out.append(f"[{i}] {opt['label']}")
        out.append(render_option(opt))
        out.append("")
    return "\n".join(out).rstrip()


def build(offer):
    """Realise one option: check out its branches per repo, then relaunch (which
    rebuilds the preview stack and posts the frontend URL to the project's topic).

    `offer` = {name, workspace, branches:{repo:branch}}. A dirty repo is left
    untouched and reported — never clobbered — mirroring pull.py's rule."""
    repos = dict(status._parse_agents_env(os.path.join(offer["workspace"], "agents.env")))
    notes = []
    for rname, branch in offer["branches"].items():
        path = repos.get(rname)
        if not path or not os.path.isdir(os.path.join(path, ".git")):
            notes.append(f"{rname}: no git repo, skipped")
            continue
        if status._git(path, "status", "--porcelain"):
            notes.append(f"{rname}: dirty, left as-is")
            continue
        subprocess.run(["git", "-C", path, "fetch", "origin", branch],
                       capture_output=True, text=True, timeout=120)
        co = subprocess.run(["git", "-C", path, "checkout", branch],
                            capture_output=True, text=True, timeout=60)
        if co.returncode != 0:
            notes.append(f"{rname}: checkout {branch} failed ({co.stderr.strip().splitlines()[-1] if co.stderr.strip() else 'error'})")
            continue
        # fast-forward to the remote tip so a review sees the latest PR commit
        subprocess.run(["git", "-C", path, "merge", "--ff-only", f"origin/{branch}"],
                       capture_output=True, text=True, timeout=60)
        notes.append(f"{rname}: on {branch}")
    print("[checkout] " + " · ".join(notes), flush=True)
    # relaunch rebuilds whatever is now checked out and posts the URL itself.
    subprocess.run([RELAUNCH, offer["name"]])


def main(argv):
    if argv and argv[0] == "--build":
        build(json.load(open(argv[1])))
        return
    if argv and argv[0] == "--json":
        print(json.dumps(options_for(argv[1])))
        return
    if not argv:
        sys.exit("usage: checkout.py [--json|--build] <workspace|offer.json>")
    print(render(argv[0]))


if __name__ == "__main__":
    main(sys.argv[1:])
