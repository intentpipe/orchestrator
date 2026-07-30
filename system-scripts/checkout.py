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

`--refresh` is the same realisation without a human picking: it points the preview
at the branch that was just developed (or, with no branch named, at the most
recently updated open PR) and rebuilds it. That is what a project's AFTER_DONE
hook calls when machines-at-work lands a task — otherwise every build leaves the
repos back on DEFAULT_BRANCH and the preview silently reverts to the mainline.

Run:  checkout.py <workspace>            # human-readable option list
      checkout.py --json <workspace>     # options as JSON (the daemon posts these)
      checkout.py --build <offer.json>   # check out an option's branches, then relaunch
      checkout.py --refresh <workspace> [branch]   # follow that branch (default: latest PR)
"""
import json
import os
import subprocess
import sys

ORCH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ORCH_DIR)
import status  # reuse _projects, _parse_agents_env, _git — one source of fleet truth

RELAUNCH = os.path.join(ORCH_DIR, "relaunch")
RUN_DIR = os.path.join(status.ORCH_HOME, "run")
# A refresh takes minutes (docker + a release web build). Rounds bound the
# drain loop below so a marker that keeps reappearing can't spin forever.
REFRESH_MAX_ROUNDS = 5

# Building a preview regenerates lockfiles with different transitive pins (flutter
# pub get rewrites pubspec.lock; uv rewrites uv.lock), which leaves the tree dirty
# — and a dirty repo used to be SKIPPED here while the other one switched, which
# served a new frontend against the previous branch's backend. The committed
# lockfile is the source of truth, so restore exactly those before judging
# dirtiness; any OTHER dirt is a real edit and still blocks the switch.
LOCKFILES = ("pubspec.lock", "uv.lock", "poetry.lock", "package-lock.json")


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
    """Open PRs in `repo` as [{number, title, headRefName, url, updatedAt}] via gh.
    Any failure (no gh, no origin, not authenticated) → [] — never fatal: a repo
    that can't have PRs just contributes no PR options."""
    if not os.path.isdir(os.path.join(repo, ".git")):
        return []
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--state", "open", "--json",
             "number,title,headRefName,url,updatedAt"],
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
                "prs": [{"repo": rname, "number": pr["number"], "title": pr["title"],
                         "url": pr["url"], "updatedAt": pr.get("updatedAt", "")}
                        for rname, _ in repos for pr in prs_by_repo[rname]
                        if pr["headRefName"] == default]}
    options = [baseline]
    for b in branches:
        branch_map, prs = {}, []
        for rname, _ in repos:
            match = next((pr for pr in prs_by_repo[rname] if pr["headRefName"] == b), None)
            if match:
                branch_map[rname] = b
                prs.append({"repo": rname, "number": match["number"], "title": match["title"],
                            "url": match["url"], "updatedAt": match.get("updatedAt", "")})
            else:
                branch_map[rname] = default  # no PR here → stay on default (the FE/BE-only rule)
        options.append({"label": b, "branches": branch_map, "prs": prs})
    # Each option carries its own rendered body, so the CLI and the daemon post
    # the SAME text — the daemon used to rebuild it from the branch map and drifted
    # from this one the moment either grew an annotation.
    for opt in options:
        opt["body"] = render_option(opt, default)
    return {"name": name, "workspace": workspace, "default": default, "options": options}


def render_option(opt, default):
    """One option as a message body (repo→branch, with PR annotations).

    A repo left on the default branch inside a *feature* option is annotated as
    such: that is the one-sided-change case (a frontend-only PR has no backend
    branch to check out), and saying so up front is what separates "this option is
    incomplete" from "this option is correct and only touches one repo"."""
    lines = []
    for r, br in opt["branches"].items():
        one_sided = br == default and opt["label"] != f"{default} (baseline)"
        lines.append(f"• {r}: {br}" + ("   (no PR on this branch — untouched by this change)"
                                       if one_sided else ""))
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
        out.append(opt["body"])
        out.append("")
    return "\n".join(out).rstrip()


def _restore_lockfiles(path):
    """Discard lockfile-only drift (see LOCKFILES) so a preview build's churn
    doesn't read as a real edit."""
    for f in LOCKFILES:
        if os.path.exists(os.path.join(path, f)):
            subprocess.run(["git", "-C", path, "checkout", "--", f],
                           capture_output=True, text=True, timeout=30)


def _post(offer, text):
    """Say something in the project's topic. `checkout.py --build` runs DETACHED
    from the daemon and is not job-tracked, so a failure it doesn't announce is
    invisible — the user just waits for a URL that never arrives. Best-effort:
    never let a comms problem break the build."""
    try:
        import daemon  # noqa: PLC0415 — optional, and importing it must not be fatal
        env = daemon.load_env(daemon.ENV_FILE)
        token, chat = env.get("TELEGRAM_BOT_TOKEN"), env.get("TELEGRAM_CHAT_ID")
        if not token or not chat:
            return
        daemon.TelegramAPI(token).send_message(chat, text, offer.get("topic"))
    except Exception as e:
        print(f"[checkout] telegram post failed (non-fatal): {e}", flush=True)


def build(offer):
    """Realise one option: check out its branches per repo, then relaunch (which
    rebuilds the preview stack and posts the URLs + their branches to the topic).

    `offer` = {name, workspace, topic, branches:{repo:branch}}.

    A repo that can't be switched ABORTS the whole build — nothing is checked out
    and nothing is rebuilt. A half-applied option is precisely the bug this flow
    exists to prevent (frontend on the PR branch, backend still on the default
    one): it is invisible in the served app, so the old state plus a loud message
    beats a silent mixture. A dirty tree is still never clobbered — pull.py's
    rule — beyond the lockfile drift above."""
    repos = dict(status._parse_agents_env(os.path.join(offer["workspace"], "agents.env")))
    notes, failed, todo = [], [], []
    # Pass 1 — decide for EVERY repo before touching any: an option that can't be
    # applied in full shouldn't leave half of it applied.
    for rname, branch in offer["branches"].items():
        path = repos.get(rname)
        if not path or not os.path.isdir(os.path.join(path, ".git")):
            notes.append(f"{rname}: no git repo, skipped")
            continue
        _restore_lockfiles(path)
        on = status._git(path, "rev-parse", "--abbrev-ref", "HEAD")
        if status._git(path, "status", "--porcelain"):
            # Already on the wanted branch: a dirty tree is servable (and someone
            # may be mid-edit), so keep it — only a *switch* is refused.
            if on == branch:
                notes.append(f"{rname}: on {branch} (dirty, left as-is)")
                continue
            notes.append(f"{rname}: DIRTY on {on} — refusing to switch to {branch}")
            failed.append(rname)
            continue
        todo.append((rname, path, branch))
    if failed:
        print("[checkout] " + " · ".join(notes), flush=True)
        _post(offer, "⚠️ checkout of [{}] aborted — {} could not be switched, so nothing "
                     "was checked out and the preview was NOT rebuilt (serving a mixed "
                     "frontend/backend is worse than serving the old state).\n\n{}".format(
                         offer.get("label", "?"), ", ".join(failed), "\n".join(notes)))
        return
    # Pass 2 — apply.
    for rname, path, branch in todo:
        subprocess.run(["git", "-C", path, "fetch", "origin", branch],
                       capture_output=True, text=True, timeout=120)
        co = subprocess.run(["git", "-C", path, "checkout", branch],
                            capture_output=True, text=True, timeout=60)
        if co.returncode != 0:
            why = co.stderr.strip().splitlines()[-1] if co.stderr.strip() else "error"
            notes.append(f"{rname}: checkout {branch} FAILED ({why})")
            failed.append(rname)
            continue
        # fast-forward to the remote tip so a review sees the latest PR commit
        subprocess.run(["git", "-C", path, "merge", "--ff-only", f"origin/{branch}"],
                       capture_output=True, text=True, timeout=60)
        notes.append(f"{rname}: on {branch} @ {status._git(path, 'log', '-1', '--format=%h') or '?'}")
    print("[checkout] " + " · ".join(notes), flush=True)
    if failed:
        _post(offer, "⚠️ checkout of [{}] aborted — {} could not be switched, so the "
                     "preview was NOT rebuilt (serving a mixed frontend/backend is worse "
                     "than serving the old state).\n\n{}".format(
                         offer.get("label", "?"), ", ".join(failed), "\n".join(notes)))
        return
    # Record what this checkout put where: an automatic refresh may move a repo off
    # a branch IT parked there, but never off one a builder is working on
    # (_busy_repo). Best-effort — losing the note only makes the next refresh more
    # cautious, never less.
    try:
        os.makedirs(RUN_DIR, exist_ok=True)
        with open(_state_file(offer["name"]), "w") as f:
            json.dump(offer["branches"], f)
    except OSError as e:
        print(f"[checkout] could not record the checkout state (non-fatal): {e}", flush=True)
    # relaunch rebuilds whatever is now checked out and posts the URLs itself.
    # --reset: the branch may carry different migrations, so the backend's volumes
    # go with it — otherwise the new code serves the old branch's database.
    # When pass 2 moved nothing — the repos already stood on these commits and a
    # relaunch minutes ago already built them — relaunch's watermark check makes
    # this a no-op that just re-posts the URLs: no down -v, no ~4-minute rebuild,
    # and the seeded database survives. `relaunch --force` is the override.
    subprocess.run([RELAUNCH, "--reset", offer["name"]])


def _has_branch(path, branch):
    """True if `branch` exists in this repo — locally, as a remote-tracking ref, or
    on origin. EXISTENCE decides whether a repo takes part, not an open PR: under
    machines-at-work a feature's PR opens only when its last task lands, so the
    branch carries work (and must be served) before any PR exists. Repos without
    it stay on the default branch — the same one-sided FE/BE rule options_for
    applies, just extended to branches GitHub hasn't heard of yet."""
    for ref in (f"refs/heads/{branch}", f"refs/remotes/origin/{branch}"):
        if status._git(path, "rev-parse", "-q", "--verify", ref) is not None:
            return True
    try:  # never fetched here, but pushed from elsewhere
        out = subprocess.run(["git", "-C", path, "ls-remote", "--exit-code", "--heads",
                              "origin", branch], capture_output=True, text=True, timeout=30)
        return out.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def option_for_branch(data, branch):
    """The option that serves `branch`, or None when no repo has it.

    An open PR on that branch already describes the option (with its annotations),
    so reuse it; otherwise synthesise one from where the branch actually exists."""
    if branch == data["default"]:
        return data["options"][0]
    for opt in data["options"]:
        if opt["label"] == branch:
            return opt
    repos = status._parse_agents_env(os.path.join(data["workspace"], "agents.env"))
    branch_map = {rname: (branch if _has_branch(path, branch) else data["default"])
                  for rname, path in repos}
    if branch not in branch_map.values():
        return None
    opt = {"label": branch, "branches": branch_map, "prs": []}
    opt["body"] = render_option(opt, data["default"])
    return opt


def latest_option(data):
    """The option for the most recently updated open PR — "what was developed
    last". Baseline when the project has no open feature PR (nothing to follow)."""
    best, best_at = data["options"][0], ""
    for opt in data["options"][1:]:
        at = max((pr.get("updatedAt") or "") for pr in opt["prs"]) if opt["prs"] else ""
        if at > best_at:   # ISO-8601 UTC from gh — lexical order is chronological
            best, best_at = opt, at
    return best


def _topic(workspace):
    """The forum topic this project reports into (its registry key), or None for
    an unregistered project — build() then only prints."""
    for topic, e in status._load_json(status.REGISTRY).items():
        if os.path.normpath(e.get("workspace", "")) == os.path.normpath(workspace):
            return topic
    return None


def _alive(pidfile):
    """Whether the pid in `pidfile` is a live (non-zombie) process. Mirrors
    daemon.pid_alive deliberately: --refresh runs standalone from a project's
    AFTER_DONE hook, where the daemon may not be importable at all."""
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return False
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split(") ", 1)[1].split(" ", 1)[0] != "Z"
    except OSError:
        return False


def _state_file(name):
    return os.path.join(RUN_DIR, f"{name}.checkout-state.json")


def _busy_repo(data, opt):
    """A repo sitting on a branch this refresh has no business moving, as
    "<repo> on <branch>" — else None.

    A human picking an option in the checkout flow means "switch, whatever is
    there". An automatic refresh must not: a repo on a task branch is a builder
    mid-task, and yanking it out from under a running session strands its work.
    Movable is therefore exactly: the default branch, the branch we are about to
    check out anyway, and the one the last checkout/refresh put there (the preview
    following its own previous state is not work in flight). Anything else is
    someone else's, so the refresh gives way — the next landing fires again."""
    ours = status._load_json(_state_file(data["name"]))
    repos = dict(status._parse_agents_env(os.path.join(data["workspace"], "agents.env")))
    for rname, want in opt["branches"].items():
        path = repos.get(rname)
        if not path or not os.path.isdir(os.path.join(path, ".git")):
            continue
        on = status._git(path, "rev-parse", "--abbrev-ref", "HEAD")
        if on and on not in (want, data["default"], ours.get(rname)):
            return f"{rname} on {on}"
    return None


def refresh_once(workspace, branch=None):
    """Point the preview at `branch` (or the latest open PR) and rebuild it."""
    data = options_for(workspace)
    opt = option_for_branch(data, branch) if branch else None
    if opt is None:
        if branch:
            print(f"[checkout] no repo has '{branch}' — falling back to the latest PR", flush=True)
        opt = latest_option(data)
    busy = _busy_repo(data, opt)
    if busy:
        print(f"[checkout] refresh {data['name']} → {opt['label']} SKIPPED: {busy} "
              f"(work in flight — not switching under it)", flush=True)
        return
    print(f"[checkout] refresh {data['name']} → {opt['label']}", flush=True)
    build({"name": data["name"], "workspace": workspace, "topic": _topic(workspace),
           "label": opt["label"], "branches": opt["branches"]})


def refresh(workspace, branch=None):
    """--refresh: follow the branch that was just developed, serialised per project.

    Shares the daemon's `<name>.checkout.pid` so an automatic refresh and a
    human-chosen checkout can never build the same project at once. A refresh that
    finds one in flight QUEUES itself in a marker file instead of stacking a second
    docker+flutter build: a loop lands several tasks in a row, and what the human
    wants is the LAST branch developed, which the queued round re-picks when it
    runs — not one rebuild per task, three deep."""
    workspace = os.path.normpath(workspace)
    if not os.path.exists(os.path.join(workspace, "agents.env")) \
            and os.path.exists(os.path.join(workspace, "machines-at-work", "agents.env")):
        workspace = os.path.join(workspace, "machines-at-work")   # given the project root
    name = options_for(workspace)["name"]
    os.makedirs(RUN_DIR, exist_ok=True)
    pidfile = os.path.join(RUN_DIR, f"{name}.checkout.pid")
    pending = os.path.join(RUN_DIR, f"{name}.refresh-pending")
    if _alive(pidfile):
        with open(pending, "w") as f:
            f.write((branch or "") + "\n")
        print(f"[checkout] refresh queued behind the build already running for {name}", flush=True)
        return
    # Own the slot. A marker left by a checkout the daemon ran (that path doesn't
    # drain the queue) is stale by now — this run supersedes it.
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    try:
        os.remove(pending)
    except OSError:
        pass
    try:
        for _ in range(REFRESH_MAX_ROUNDS):
            refresh_once(workspace, branch)
            if not os.path.exists(pending):
                return
            branch = open(pending).read().strip() or None
            os.remove(pending)
        print(f"[checkout] refresh hit {REFRESH_MAX_ROUNDS} rounds for {name} — stopping", flush=True)
    finally:
        try:
            os.remove(pidfile)
        except OSError:
            pass


def main(argv):
    if argv and argv[0] == "--refresh":
        if len(argv) < 2:
            sys.exit("usage: checkout.py --refresh <workspace> [branch]")
        refresh(argv[1], argv[2] if len(argv) > 2 else None)
        return
    if argv and argv[0] == "--build":
        build(json.load(open(argv[1])))
        return
    if argv and argv[0] == "--json":
        print(json.dumps(options_for(argv[1])))
        return
    if not argv:
        sys.exit("usage: checkout.py [--json|--build|--refresh] <workspace|offer.json>")
    print(render(argv[0]))


if __name__ == "__main__":
    main(sys.argv[1:])
