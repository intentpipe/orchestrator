# logmine — analyze orchestrator logs for improvements

You are auditing the **orchestrator control plane** and the **intentpipe
scaffold** by reading their own logs. Below (after the `=== LOGS ===` marker) is
every log line logmine has not yet read: the daemon's journald output plus the
tails of the child runs it spawned (plan / loop / unblock / relaunch / checkout).

Your job: find **recurring or high-impact flaws** these logs reveal, and for each
propose **one concrete, mechanical improvement** to the tooling that would prevent
or reduce it. Think like an SRE reading an incident feed.

## Scope — hard rule
Only propose changes to these two repos (the tooling that produced the logs):
- `orchestrator` — `/home/agent/intentpipe/orchestrator`
  (daemon.py, relaunch, system-scripts/, tg.sh, logmine/).
- `intentpipe` (the plugin) — `/home/agent/intentpipe/plugin`
  (scripts/, skills/, agents/, hooks/, templates/).

**Never** propose changes to project app code (bibbles, tell-your-friends). If a
log shows an app-code failure, the proposable improvement is to the *tooling's*
handling of it (better diagnosis, retry, escalation), not the app fix.

## What counts as a good proposal
- Backed by evidence in the logs (quote the line(s) that motivate it).
- A repeated pattern (many timeouts, repeated rejections, the same crash) or a
  single clearly-broken behavior — not a one-off transient.
- Mechanical and bounded: a config value, a retry/backoff, a clearer error, a
  guard, a missing reap, a watermark — something a focused change can land.
- Skip anything already handled well, and skip pure noise.

## Output — STRICT
Output **only** a JSON array (no prose before or after), newest/most-important
first, at most 6 items. Each item:

```json
{
  "title": "one-line summary of the fix",
  "repo": "orchestrator" | "intentpipe",
  "evidence": "the log line(s) or pattern that motivate this, quoted briefly",
  "problem": "what is going wrong, in one or two sentences",
  "change": "the specific mechanical change to make (files/functions if known)",
  "severity": "high" | "medium" | "low"
}
```

If the logs reveal nothing worth changing, output exactly `[]`.
