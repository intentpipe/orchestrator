#!/usr/bin/env python3
"""Collect orchestrator logs that logmine hasn't read yet, then advance a watermark.

Two log sources feed the orchestrator's story:
  1. the daemon itself — journald (systemd user unit `agent-orchestrator`), which
     is `print("[daemon] …")` captured by the journal;
  2. child runs it spawns — RUN_DIR/<name>.<action>.log (plan/loop/unblock/
     relaunch/checkout), which hold the actual `claude -p` / loop.sh output.

"Not read yet" = new since the last committed watermark, tracked in a state file
(JSON): a journald cursor for source 1, and a per-file byte offset for source 2.
Cursors/offsets (not timestamps) so nothing is double-read or skipped across runs.

Usage:
  collect_logs.py            # print unread log text to stdout (does NOT advance)
  collect_logs.py --commit   # same, then advance the watermark past what was read
  collect_logs.py --reset    # forget the watermark (next run reads recent history)

The daemon runs it once to gather text for the analysis prompt, and again with
--commit once proposals were produced, so a crash mid-analysis re-reads the same
window rather than losing it.
"""
import argparse
import json
import os
import subprocess
import sys

ORCH_HOME = os.environ.get("ORCH_HOME", os.path.expanduser("~/.agent-orchestrator"))
RUN_DIR = os.path.join(ORCH_HOME, "run")
STATE_FILE = os.path.join(ORCH_HOME, "logmine.state")
UNIT = os.environ.get("LOGMINE_UNIT", "agent-orchestrator")
# On a first run (no cursor) don't dump the entire journal — cap the backfill.
FIRST_RUN_SINCE = os.environ.get("LOGMINE_FIRST_RUN_SINCE", "-2 days")
# Per-file guard: never emit more than this many bytes from one run log in a
# single pass (a 3 MB loop log would blow the analysis context). Newest wins.
MAX_PER_FILE = int(os.environ.get("LOGMINE_MAX_PER_FILE", str(200_000)))


def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
    except (OSError, ValueError):
        s = {}
    s.setdefault("journal_cursor", None)
    s.setdefault("offsets", {})
    return s


def save_state(state):
    os.makedirs(ORCH_HOME, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_FILE)


def collect_journal(state):
    """Return (text, new_cursor) for daemon journald lines since the last cursor."""
    if state["journal_cursor"]:
        cmd = ["journalctl", "--user", "-u", UNIT, "--no-pager", "-o", "short-iso",
               "--after-cursor", state["journal_cursor"], "--show-cursor"]
    else:
        cmd = ["journalctl", "--user", "-u", UNIT, "--no-pager", "-o", "short-iso",
               "--since", FIRST_RUN_SINCE, "--show-cursor"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"(journal unavailable: {e})\n", state["journal_cursor"]
    lines = out.stdout.splitlines()
    new_cursor = state["journal_cursor"]
    body = []
    for ln in lines:
        # journalctl --show-cursor emits a trailing "-- cursor: s=…" line.
        if ln.startswith("-- cursor:"):
            new_cursor = ln.split("cursor:", 1)[1].strip()
        elif ln.strip() and not ln.startswith("-- "):
            body.append(ln)
    text = "\n".join(body)
    return (text + "\n" if text else ""), new_cursor


def collect_run_logs(state):
    """Return (text, new_offsets) for new bytes in each RUN_DIR/*.log."""
    offsets = dict(state["offsets"])
    chunks = []
    if not os.path.isdir(RUN_DIR):
        return "", offsets
    for name in sorted(os.listdir(RUN_DIR)):
        if not name.endswith(".log"):
            continue
        path = os.path.join(RUN_DIR, name)
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        start = offsets.get(path, 0)
        if start > size:      # log was rotated/truncated → re-read from 0
            start = 0
        if start == size:     # nothing new
            offsets[path] = size
            continue
        # Cap oversized deltas to the newest MAX_PER_FILE bytes.
        read_from = max(start, size - MAX_PER_FILE)
        try:
            with open(path, "rb") as f:
                f.seek(read_from)
                data = f.read(size - read_from).decode("utf-8", "replace")
        except OSError:
            continue
        offsets[path] = size
        trimmed = " (older bytes skipped)" if read_from > start else ""
        chunks.append(f"===== {name} (bytes {read_from}-{size}{trimmed}) =====\n{data.rstrip()}\n")
    return "\n".join(chunks), offsets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true", help="advance the watermark past what was read")
    ap.add_argument("--reset", action="store_true", help="forget the watermark")
    args = ap.parse_args()

    if args.reset:
        try:
            os.remove(STATE_FILE)
        except OSError:
            pass
        print("logmine watermark reset", file=sys.stderr)
        return

    state = load_state()
    jtext, new_cursor = collect_journal(state)
    rtext, new_offsets = collect_run_logs(state)

    out = []
    if jtext.strip():
        out.append("########## DAEMON JOURNAL ##########\n" + jtext)
    if rtext.strip():
        out.append("########## CHILD RUN LOGS ##########\n" + rtext)
    body = "\n".join(out).strip()
    if not body:
        print("(no new orchestrator logs since the last logmine run)")
    else:
        print(body)

    if args.commit:
        state["journal_cursor"] = new_cursor
        state["offsets"] = new_offsets
        save_state(state)


if __name__ == "__main__":
    main()
