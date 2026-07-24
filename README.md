# Orchestrator layer

Cross-project control plane for the scaffold — **not** plugin code (the plugin is per-project and read-only;
this sits above all projects). Architecture + rationale: `DESIGN.md`.

- `tg.sh` — Telegram helpers: discover a chat id, create a forum topic.

## One-time setup: the community + the `scaffold` topic

A bot can't create a supergroup or enable Topics, so the first steps are manual (Telegram app), then scripted.

Do this **on the server that runs the scaffold** (`~` = the home of the user the scaffold/daemon runs as) — that's
what reads `telegram.env` at runtime. The token/chat/topic values are Telegram-side, not machine-specific, so you
*may* generate them from any machine with internet and copy the three lines over; the file that matters lives on the server.

1. **Create the bot.** Message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. **Store the token.**
   ```
   mkdir -p ~/.agent-orchestrator
   printf 'TELEGRAM_BOT_TOKEN=%s\n' '123456:ABC...' > ~/.agent-orchestrator/telegram.env
   chmod 600 ~/.agent-orchestrator/telegram.env
   ```
3. **Create the community.** New group named `me and my agents` → group settings → enable **Topics**
   (this upgrades it to a supergroup — Telegram's equivalent of a "community"). Add the bot as an **admin**
   with **Manage Topics** permission.
4. **Get the chat id.** Send any message in the group, then:
   ```
   server-orchestrator/tg.sh chat-id            # prints e.g.  -1001234567890  me and my agents
   ```
   Append it: `echo 'TELEGRAM_CHAT_ID=-1001234567890' >> ~/.agent-orchestrator/telegram.env`
5. **Create the `scaffold` topic** (the maintainer inbox retros post into):
   ```
   server-orchestrator/tg.sh new-topic scaffold  # prints a thread id, e.g. 2
   ```
   Append it: `echo 'SCAFFOLD_RETRO_TOPIC_ID=2' >> ~/.agent-orchestrator/telegram.env`

After this, `notify.sh` (in any project) can reach Telegram, and the `scaffold` topic is ready to receive
retros. Per-project topics and the inbound voice daemon are later phases of the proposal.

## Keyword: `status`

Send `status` (text) in **any** topic and the daemon replies with a live cross-project report —
each project's repos and their git branch (`*` = dirty working tree), plus whether the backend and
frontend ports are listening:

```
📊 Project status

• bibbles
   branches: backend main*, frontend main*
   running:  backend: 🟢 :8810 · frontend: 🟢 :3031
• tell-your-friends
   branches: app_mobile dev*, core dev*
   running:  backend: 🟢 :8800 · frontend: 🟢 :3030
```

It short-circuits before topic routing, so it never writes an update note. Implementation lives in
`system-scripts/status.py` (pure stdlib; also runnable from the shell to print the same report) and
reads two things: the daemon **registry** for which projects exist + their workspaces (so a newly
`register`ed project appears automatically), and `system-scripts/ports.json` for the FE/BE ports to
probe. Keep `ports.json` in sync with `projects/PORTS.md` when you add or move a service.

## Keyword: `pull-all`

Send `pull-all` (text) in **any** topic and the daemon fast-forward-pulls the whole
fleet — every registered project's repos **and** the `machines-at-work` scaffold
(resolved from `MAW_SCRIPTS`, since it lives outside every project workspace) — then
replies with a per-repo result:

```
📥 pull-all

• bibbles
   backend main ✅ pulled
   frontend main ✅ up to date
• tell-your-friends
   app-mobile dev ✅ pulled · core dev ⏭ skipped (dirty, 2 files) · scaffold dev ✅ up to date
• machines-at-work main ✅ pulled
```

Guarded on purpose: a repo is pulled only if its tree is **clean** and the pull is a
**fast-forward** — a dirty or diverged repo is reported and skipped, never clobbered
(the same "don't touch dirty" rule `status` marks with `*`). Like `status` it short-
circuits routing and writes no note. Implementation: `system-scripts/pull.py` (imports
`status.py` for the fleet enumeration; pure stdlib; also runnable from the shell).

## Topic triggers: 🧠 plan · 🚀 build-all · 🩹 unblock

In a **registered project topic**, a message that is exactly one of these tokens drives the
pipeline instead of becoming a note (exact match only — "let's plan later" is still a note):

| token | action |
|---|---|
| 🧠 or `plan` | headless `/machines-at-work:plan` in the workspace — drains queued notes, posts the task list back into the topic |
| 🚀 or `build-all` | detached `loop.sh` — set `MAW_SCRIPTS=` in `telegram.env` to the plugin's `scripts/` dir |
| 🩹 or `unblock` | headless `/machines-at-work:unblock` — diagnoses why the build queue is stuck and auto-resolves the safe cases (finished-but-unmerged, clean retry); the rest are escalated with a precise reason |

🚀 is the plan approval: text intent → 🧠 → read the posted plan → 🚀. A second trigger while
one is running replies "already running" (pidfiles + child logs under `~/.agent-orchestrator/run/`).
🩹 when a `loop.sh` run stops on a block: it merges work that only missed its merge step and resets
un-started tasks for a clean retry, then tells you what genuinely needs a human (and what to run next).

When a 🧠/🚀/🩹 run finishes, the daemon posts the outcome back into the topic — **✅** on success,
**😱 + the log tail** if it exited non-zero or a command was rejected — so a run never fails silently
(the earlier gap: a headless plan denied at a permission prompt died leaving only a 👌). The run's own
`notify.sh` still delivers the substance (the task list); this is the completion signal on top.

Every message you send gets a reaction: 👀 processing, then 👌 queued/started, or 😱 plus a reply
saying what went wrong. (Telegram bots can only react from a fixed emoji set — no ✅/⚠️.)

## Keyword: `checkout`

Send `checkout` (text) in a **project topic** and the daemon posts that project's
checkout options — one Telegram message each:

- the **baseline**: every code repo on its `DEFAULT_BRANCH` (the merged mainline);
- one option **per open-PR feature branch**. PRs are grouped across repos by head
  branch, so a feature touching both repos is one option; a repo with no PR on that
  branch stays on the default. That's the frontend/backend-only case — a
  frontend-only PR leaves the backend on `dev`.

**React to one of those messages** and the daemon checks its branches out in each
repo (dirty trees are left untouched, never clobbered) and runs `relaunch`, which
rebuilds the preview stack and posts the fresh **frontend URL** back into the topic.

```
🔀 checkout · tell-your-friends — react to an option to check it out, build it, and get the frontend URL:
[dev (baseline)]
• app_mobile: dev
• core: dev
[feat/onboarding]
• app_mobile: feat/onboarding
• core: dev
    ↳ app_mobile PR #41: Onboarding flow
```

Enumeration is `system-scripts/checkout.py` (reuses `status.py` for the fleet
walk; `gh` lists open PRs — a repo with no `gh`/origin just contributes no PR
options). **Receiving reactions requires the bot to be a chat admin**, and the
daemon requests `message_reaction` in `getUpdates`' `allowed_updates` (both are
already wired). A reaction by a non-allow-listed user, a cleared reaction, or a
reaction on any non-offer message does nothing.

## Keyword: `help`

Send `help` (or `/help`) in **any** topic and the daemon replies with the full
command list — the keywords above, the topic triggers, and the General-topic
behaviour. Short-circuits like `status`; never writes a note.

## General topic: free-form → `claude -p`

Registered topics map to a project; the **General** topic doesn't. A message there that isn't `status`
is treated as a free-form instruction — the daemon's one interpretation path (everything else is
deterministic). It transcribes voice, then runs a **one-shot** `claude -p` in `GENERAL_WORKSPACE` and
posts the output back into General. Good for cross-project asks:

> *"update all the projects to the latest main"* · *"write a script that shows the branches with open PRs"*

```
echo 'GENERAL_WORKSPACE=/home/you/projects' >> ~/.agent-orchestrator/telegram.env
```

If `GENERAL_WORKSPACE` is unset it fails loudly (😱 + a reply) rather than running claude against the
daemon's home. Reaction lifecycle is the same as everywhere: 👀 → 👌, or 😱 + reason.

**Deliberately bounded** (see Decision #11):
- **One-shot, not a session.** The daemon is stateless across messages, so this is *fire a task, get one
  result back* — not a conversation. If you find yourself wanting to iterate on an authored script over
  several messages, that's the signal to SSH in / open Claude Code directly, not to bend this into a REPL.
- **Synchronous.** A long run briefly parks the poll loop (same shape as `status`); fine for a single user.
- **`--dangerously-skip-permissions`**, run in a pinned cwd. The cwd is a sensible default dir, **not** a
  sandbox — the allowlist stays the whole security model, exactly as it is for the 🚀 loop.
- **General only.** Registered project topics still note-drop / trigger; this never fires there.

## `system-scripts/`

Server-wide, cross-project tooling that isn't the Telegram bridge itself: the `status`
collector, the `pull-all` fast-forward puller, and the `checkout` option enumerator/builder
(all reuse `status.py`'s registry + agents.env + git walk). Anything the daemon exposes as a
keyword-driven "act on the whole box" belongs here.

## Keyword: `logmine`

Send `logmine` in any topic and the daemon audits **its own tooling** by reading its logs.
It mirrors the `checkout` offer→react→build flow:

1. `logmine/collect_logs.py` gathers the orchestrator logs not seen since the last run —
   the daemon's journald output (unit `agent-orchestrator`) plus the tails of the child runs
   in `run/*.log` — tracked by a watermark (`~/.agent-orchestrator/logmine.state`: a journald
   cursor + per-file byte offsets, so nothing is double-read or skipped).
2. A synchronous `claude -p` with `logmine/analyze.md` turns that into a JSON array of
   **tooling-improvement proposals**, scoped to the two repos that produced the logs
   (`server-orchestrator`, the `machines-at-work` plugin) — never project app code. The
   watermark advances once analysis returns.
3. Each proposal is posted as its own message, remembered by `message_id` (`run/logmine_offers.json`).
4. **React to a proposal** → the daemon spawns a detached `claude -p` with `logmine/implement.md`
   and `--dangerously-skip-permissions` in the target repo: it commits+pushes the current state
   first, then implements the one change on a fresh branch and opens a PR (the guard forbids
   default-branch pushes). `reap_jobs` posts the result with the PR URL.

Not reacting is an implicit "deny" — the proposal simply expires from the map.

## Plugin freshness (`sync_plugin`)

The `machines-at-work` plugin's **skills** run from a version-pinned install *cache*
(`~/.claude/plugins/cache/…`), while only its `scripts/` run live via `MAW_SCRIPTS`. So a
version bump that isn't reinstalled leaves headless skill runs (plan/build/unblock) executing a
**stale** copy — this is a real trap: the cache once sat at 0.19.0, predating the `unblock`
skill entirely, so the 🩹 trigger invoked a skill that wasn't installed. `sync_plugin()` runs
before every dispatch: if the source `plugin.json` version moved past what's installed, it
`claude plugin marketplace update` + `claude plugin update` to refresh the cache. That is what
keeps the project scaffolds auto-updated to a new machines-at-work version — bump the version,
and the next plan/build/unblock/logmine reinstalls it.
