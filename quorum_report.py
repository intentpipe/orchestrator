"""Best-effort fan-out of the daemon-side outbound reports into Quorum's chat.

Every report `daemon.py` (`reap_jobs`, retro offers), `relaunch`,
`system-scripts/checkout.py` and `system-scripts/plugin.py` post into
Telegram today, this module also posts into Quorum: the project's chat by
default, or — when the text names one that actually resolves — its feature
channel. The mapping is read straight off files already on disk (the
registry's `workspace`, that workspace's `tasks/<id>-*/task.md` `Feature:`
line, `tasks/_features/<slug>.md`), the same way `Chat.Inbox` reads the
registry on the chat service's side — never a new registry, never a second
source of truth.

Config lives beside the Telegram block, in the same box-wide file:
`QUORUM_CHAT_URL` + `QUORUM_PIPE_TOKEN` (a dedicated minted account, `mix
accounts.mint "Pipe" "pipe"` — never the shared token, so the chat service
attributes every post here to that account and not to whatever a body might
claim). Quorum being unreachable, unconfigured, or refusing the post must
never raise: every caller has already delivered its Telegram copy (or decided
not to) before reaching this module, and that copy must not depend on Quorum
being up.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

ORCH_HOME = os.environ.get("ORCH_HOME", os.path.expanduser("~/.agent-orchestrator"))
ENV_FILE = os.environ.get("TELEGRAM_ENV", os.path.join(ORCH_HOME, "telegram.env"))
REGISTRY = os.environ.get("QUORUM_REGISTRY", os.path.join(ORCH_HOME, "registry.json"))

# A message names a feature either directly ("Feature amend-flow blocked: …")
# or through a task ("Task 1234 blocked: …"), which is resolved to that
# task's own `Feature:` line. Either way the slug still has to exist as a
# real `_features/<slug>.md` before it is trusted — see `known_feature`.
_TASK_RE = re.compile(r"\btask (\d+)", re.IGNORECASE)
_FEATURE_RE = re.compile(r"\bfeature ([a-z][a-z0-9-]*)", re.IGNORECASE)

# The chat service's own topic key (`chat/lib/chat/channel_key.ex`:
# `project:<project>` / `feature:<project>:<slug>`) — what a job ticket's
# `reply_to.channel` (quorum_core/jobs.py) carries verbatim. Trusted structured
# data, never re-derived by regex over a message that might carry a log tail.
_CHANNEL_RE = re.compile(r"^(project|feature):[^:]+(?::([a-z][a-z0-9-]*))?$")


def load_env(path=None):
    env = {}
    path = ENV_FILE if path is None else path
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def load_registry(path=None):
    path = REGISTRY if path is None else path
    return json.load(open(path)) if os.path.exists(path) else {}


def workspace_for(project, registry=None):
    """The registered workspace for `project`'s name, or None — the reverse of
    the topic-id-keyed lookup `Chat.Inbox.workspace/1` does on the chat side."""
    registry = load_registry() if registry is None else registry
    for entry in registry.values():
        if entry.get("name") == project:
            return entry.get("workspace")
    return None


def known_feature(workspace, slug):
    return bool(workspace and slug) and os.path.exists(
        os.path.join(workspace, "tasks", "_features", f"{slug}.md")
    )


def feature_for_task(workspace, task_id):
    """The `Feature:` slug task `task_id`'s task.md names, or None."""
    if not workspace:
        return None
    base = os.path.join(workspace, "tasks")
    try:
        names = os.listdir(base)
    except OSError:
        return None
    prefix = f"{task_id}-"
    for name in names:
        if name.startswith(prefix):
            try:
                with open(os.path.join(base, name, "task.md")) as f:
                    for line in f:
                        if line.startswith("Feature:"):
                            slug = line.split(":", 1)[1].strip()
                            return slug or None
            except OSError:
                return None
    return None


def resolve_feature(project, text, workspace=None):
    """The feature slug `text` names and that resolves for `project`, or None
    for the project chat — including when nothing in `text` names one at all,
    or the thing it names does not exist."""
    workspace = workspace_for(project) if workspace is None else workspace
    m = _FEATURE_RE.search(text)
    if m and known_feature(workspace, m.group(1)):
        return m.group(1)
    m = _TASK_RE.search(text)
    if m:
        slug = feature_for_task(workspace, m.group(1))
        if known_feature(workspace, slug):
            return slug
    return None


def feature_from_channel(channel):
    """The feature slug a job ticket's own `reply_to.channel` names, or None
    for project chat. `channel` is the chat service's topic key verbatim
    (`project:<project>` / `feature:<project>:<slug>`) — trusted as written,
    not re-derived from any message text."""
    if not channel:
        return None
    m = _CHANNEL_RE.match(channel)
    return m.group(2) if m else None


def report(project, text, feature=None, workspace=None, env=None, channel=None, route_text=None):
    """Fan `text` into Quorum's chat for `project`. Best-effort: returns True
    once the post is accepted, False for missing config or any failure — never
    raises, so a caller's Telegram leg is never affected by this one.

    Destination priority: an explicit `feature` wins outright; failing that, a
    job ticket's `channel` (its `reply_to.channel`, task 0069) is trusted as
    written; only with neither does the message get classified by regex — and
    that classification reads `route_text` (the message proper) rather than
    `text` itself, so a completion report's attached log tail — which quotes
    task/feature names from unrelated work almost every time — can never steer
    the destination.
    """
    env = load_env() if env is None else env
    base, token = env.get("QUORUM_CHAT_URL"), env.get("QUORUM_PIPE_TOKEN")
    if not base or not token or not project:
        return False
    if feature is None:
        if channel is not None:
            feature = feature_from_channel(channel)
        else:
            feature = resolve_feature(project, route_text if route_text is not None else text,
                                       workspace=workspace)
    base = base.rstrip("/")
    url = (
        f"{base}/v1/chat/projects/{project}/messages"
        if feature is None
        else f"{base}/v1/chat/features/{project}/{feature}/messages"
    )
    body = json.dumps({"kind": "text", "text": text}).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10):
            return True
    except (OSError, urllib.error.URLError) as error:
        print(f"[quorum_report] post to {project} failed (non-fatal): {error}", file=sys.stderr)
        return False


def main(argv):
    if len(argv) < 2:
        print("usage: quorum_report.py <project> <text> [feature]", file=sys.stderr)
        return 2
    project, text = argv[0], argv[1]
    feature = argv[2] if len(argv) > 2 else None
    report(project, text, feature=feature)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
