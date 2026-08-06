#!/usr/bin/env python3
"""What the pipeline actually spends — for the Telegram `tokens` keyword.

Cross-project, above any single workspace (same layer as the daemon, NOT plugin
code). The source is the Claude Code transcripts the CLI already writes:

  ~/.claude/projects/<project>/<session>.jsonl              main-loop turns
  ~/.claude/projects/<project>/<session>/subagents/*.jsonl  subagent turns

Both are needed and the second is easy to miss: a subagent's usage is NOT in its
parent's transcript, so a reader that globs only `<project>/*.jsonl` undercounts
by roughly half on a build-heavy day.

Three things this gets right that a naive sum does not:

  requestId dedupe   A resumed session (loop.sh --resume, DESIGN #38) copies its
                     predecessor's history into the new file, and a subagent
                     transcript can repeat rows outright — one worst-case run
                     held 336 rows for 192 real requests. Dedupe globally on
                     requestId, else you roughly double the bill.
  cache tiers        A cache WRITE is 1.25x base input at the 5m TTL and 2x at
                     1h; a cache READ is 0.10x. Since ~95% of a build session is
                     cached prefix, treating those as plain input tokens is not
                     a rounding error, it is the whole answer.
  main vs subagent   isSidechain splits the implementer/reviewer/Explore spend
                     from the orchestrating session's own. That split is the
                     point: on a build day the subagents are 70-80% of it.

Dollars are API-equivalent, not a bill: on a Claude subscription there is no
per-token charge (DESIGN #12). They are here because one number that weights a
cache read against an output token is the only way to compare two runs.

Pure stdlib, no deps — matches daemon.py so the daemon can shell out to it the
same way it does status.py.

Run:  system-scripts/tokens.py                  # last 7 days, every project
      system-scripts/tokens.py --days 30
      system-scripts/tokens.py --project quorum # substring match on the cwd
      system-scripts/tokens.py --runs           # + the priciest single runs
      system-scripts/tokens.py --json
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys
from collections import defaultdict

ROOT = os.path.expanduser("~/.claude/projects")

# $ per 1M tokens (base input, output), from the published model pricing.
# Unknown ids fall back to opus-class rather than silently costing zero — a new
# model showing up must not make the report quietly cheaper.
PRICES = {
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-4-8": (5.0, 25.0),
    "claude-opus-4-7": (5.0, 25.0),
    "claude-opus-4-6": (5.0, 25.0),
    "claude-fable-5": (10.0, 50.0),
    "claude-sonnet-5": (3.0, 15.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5": (1.0, 5.0),
}
FALLBACK = (5.0, 25.0)
CACHE_READ = 0.10
CACHE_WRITE_5M = 1.25
CACHE_WRITE_1H = 2.00


def split_cost(model, u):
    """-> (read$, write$, output$). Split, not summed, because which one is big
    decides what to do about it: reads mean context x turns, output means
    thinking. In practice it is always reads."""
    inp, out = PRICES.get(model, FALLBACK)
    cc = u.get("cache_creation") or {}
    w1h = cc.get("ephemeral_1h_input_tokens", 0)
    w5m = cc.get("ephemeral_5m_input_tokens", 0)
    if not (w1h or w5m):  # older rows carry only the total
        w5m = u.get("cache_creation_input_tokens", 0)
    read = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) * CACHE_READ) * inp
    write = (w5m * CACHE_WRITE_5M + w1h * CACHE_WRITE_1H) * inp
    return read / 1e6, write / 1e6, u.get("output_tokens", 0) * out / 1e6


class Bucket:
    __slots__ = ("read", "write", "out", "reqs", "runs", "otok", "rtok")

    def __init__(self):
        self.read = self.write = self.out = 0.0
        self.reqs = self.otok = self.rtok = 0
        self.runs = set()

    def add(self, c, u, run=None):
        self.read += c[0]
        self.write += c[1]
        self.out += c[2]
        self.reqs += 1
        self.otok += u.get("output_tokens", 0)
        self.rtok += u.get("cache_read_input_tokens", 0)
        if run:
            self.runs.add(run)

    @property
    def total(self):
        return self.read + self.write + self.out


def collect(since, project=None):
    """Walk every transcript once. Returns (buckets, runs, skipped)."""
    files = [(f, False) for f in glob.glob(os.path.join(ROOT, "*", "*.jsonl"))]
    files += [(f, True) for f in glob.glob(os.path.join(ROOT, "*", "*", "subagents", "*.jsonl"))]

    by_day, by_kind_day, by_agent, by_project = (defaultdict(Bucket) for _ in range(4))
    overall = Bucket()
    runs = {}
    seen, dupes = set(), 0

    for path, is_sub in files:
        # <project>/<session>.jsonl vs <project>/<session>/subagents/<agent>.jsonl
        proj = path.split(os.sep)[-4] if is_sub else os.path.basename(os.path.dirname(path))
        # One subagent transcript == one run, which is the unit worth pricing:
        # "what did that implementer cost" is a question about a whole run.
        run_key = path if is_sub else None
        for line in open(path, errors="replace"):
            # Cheap prefilter: only assistant rows carry usage, and they are a
            # small minority of a transcript's lines. json.loads on all of them
            # turns a 2s report into a 60s one.
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "assistant":
                continue
            msg = d.get("message") or {}
            u = msg.get("usage")
            if not u:
                continue
            model = msg.get("model") or "unknown"
            if model == "<synthetic>":  # no request was made, no tokens were spent
                continue
            ts = d.get("timestamp") or ""
            if ts[:10] < since:
                continue
            if project and project not in (d.get("cwd") or ""):
                continue
            rid = d.get("requestId") or msg.get("id")
            if rid in seen:
                dupes += 1
                continue
            seen.add(rid)

            c = split_cost(model, u)
            kind = "sub" if d.get("isSidechain") else "main"
            agent = d.get("attributionAgent") or ("(main loop)" if kind == "main" else "(subagent)")
            skill = d.get("attributionSkill") or "—"

            overall.add(c, u)
            by_day[ts[:10]].add(c, u)
            by_kind_day[(ts[:10], kind)].add(c, u)
            by_agent[agent].add(c, u, run=run_key)
            by_project[proj].add(c, u)

            if run_key:
                r = runs.setdefault(run_key, {"cost": 0.0, "reqs": 0, "agent": agent,
                                              "skill": skill, "day": ts[:10]})
                r["cost"] += sum(c)
                r["reqs"] += 1

    return {"day": by_day, "kind_day": by_kind_day, "agent": by_agent,
            "project": by_project, "all": overall}, runs, dupes


def fmt_tok(n):
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if n >= div:
            return f"{n / div:.1f}{unit}"
    return str(int(n))


def report(b, runs, days, project, show_runs):
    o = b["all"]
    if not o.reqs:
        return "no Claude Code usage recorded in that window"

    L = [f"💰 spend, last {days}d{' · ' + project if project else ''} "
         f"(API-equivalent — a subscription is not billed per token)", ""]

    L.append(f"{'day':<7}{'total':>8}{'main':>8}{'sub':>8}{'sub%':>6}")
    for day in sorted(b["day"])[-days:]:
        tot = b["day"][day].total
        mn = b["kind_day"].get((day, "main"), Bucket()).total
        sb = b["kind_day"].get((day, "sub"), Bucket()).total
        pct = f"{100 * sb / tot:.0f}%" if tot else "—"
        L.append(f"{day[5:]:<7}{tot:>8.2f}{mn:>8.2f}{sb:>8.2f}{pct:>6}")

    sub = sum(v.total for (_, k), v in b["kind_day"].items() if k == "sub")
    L += ["", f"total ${o.total:.2f} · subagents ${sub:.2f} "
              f"({100 * sub / o.total:.0f}%) · {o.reqs} requests"]

    # The decomposition that decides what is worth fixing.
    L.append(f"goes to: cache read {100 * o.read / o.total:.0f}% · "
             f"write {100 * o.write / o.total:.0f}% · output {100 * o.out / o.total:.0f}%")
    if o.read / o.total > 0.5:
        L.append("→ context x turns, not thinking: shrink what enters context, "
                 "and prefer smaller tasks")

    L += ["", f"{'agent':<30}{'$':>8}{'runs':>6}{'$/run':>8}"]
    for name, bk in sorted(b["agent"].items(), key=lambda x: -x[1].total)[:8]:
        n = len(bk.runs)
        per = f"{bk.total / n:.2f}" if n else "—"
        L.append(f"{name[:29]:<30}{bk.total:>8.2f}{(n or '—'):>6}{per:>8}")

    if len(b["project"]) > 1:
        L += ["", f"{'project':<34}{'$':>8}"]
        for name, bk in sorted(b["project"].items(), key=lambda x: -x[1].total)[:6]:
            L.append(f"{name[:33]:<34}{bk.total:>8.2f}")

    if show_runs and runs:
        L += ["", "priciest single runs"]
        for r in sorted(runs.values(), key=lambda x: -x["cost"])[:8]:
            L.append(f"  ${r['cost']:>6.2f}  {r['reqs']:>4} turns  "
                     f"{r['agent'][:26]} ({r['skill'][:22]})")
        top = sorted((r["cost"] for r in runs.values()), reverse=True)
        cut = max(1, len(top) // 10)
        L.append(f"  top 10% of runs = {100 * sum(top[:cut]) / sum(top):.0f}% of subagent spend")

    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=7, help="window in days (default 7)")
    ap.add_argument("--project", help="substring match against a session's cwd")
    ap.add_argument("--runs", action="store_true", help="also list the priciest runs")
    ap.add_argument("--json", action="store_true", dest="as_json")
    a = ap.parse_args()

    since = (dt.date.today() - dt.timedelta(days=a.days - 1)).isoformat()
    if not os.path.isdir(ROOT):
        print(f"no transcripts at {ROOT}", file=sys.stderr)
        return 1
    b, runs, dupes = collect(since, a.project)

    if a.as_json:
        print(json.dumps({
            "window_days": a.days, "since": since, "project": a.project,
            "deduped_requests": dupes,
            "total": round(b["all"].total, 2),
            "read": round(b["all"].read, 2), "write": round(b["all"].write, 2),
            "output": round(b["all"].out, 2), "requests": b["all"].reqs,
            "by_day": {d: round(v.total, 2) for d, v in sorted(b["day"].items())},
            "by_agent": {k: {"cost": round(v.total, 2), "runs": len(v.runs), "requests": v.reqs}
                         for k, v in b["agent"].items()},
            "by_project": {k: round(v.total, 2) for k, v in b["project"].items()},
        }, indent=2))
        return 0

    print(report(b, runs, a.days, a.project, a.runs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
