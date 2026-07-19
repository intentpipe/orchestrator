# Proposal 2026-07-19 · emoji/keyword triggers (🧠 plan · 🚀 build-all), message-lifecycle reactions, inbox contract fix

Touches `daemon.py`, `tests/smoke.sh`, DESIGN.md (new decision, #2/#9 superseded in part).
Companion (plugin side): `machines-at-work/proposals/2026-07-19-headless-plan.md`.
Realizes the deterministic half of Phase 3 — without the `claude -p` judgment router.

## Goal

Exact-match tokens in a project's topic drive the pipeline from the phone:

| token | action |
|---|---|
| 🧠 or `plan` | headless `/machines-at-work:plan` in the workspace |
| 🚀 or `build-all` | detached `loop.sh` in the workspace |

Any other message stays what it is today: an intent note.

## Prerequisite fix: the inbound contract has drifted

`write_note()` writes `<workspace>/updates/<ts>-<kind>.md` with daemon-owned naming and a
daemon-owned header. machines-at-work 0.15.0 moved note-handling into the plugin
(`inbound.sh`, its DESIGN #27): the server drops **raw** messages into
`updates/.inbox/<epoch>-<msgid>.md`; the plugin names and formats notes. Today nothing ever
lands in `.inbox/`, so `inbound.sh` is a live no-op and the daemon owns conventions it
shouldn't. Fix before (or with) the triggers, since 🧠 relies on plan's inbox drain:

- `write_note()` → write the raw transcript/text to `updates/.inbox/<epoch>-<msgid>.md`
  (`epoch` = `msg["date"]`, `msgid` = `msg["message_id"]`; lexical = chronological holds).
  `mkdir -p` the `.inbox`.
- Replies stop citing plugin note names (the daemon no longer knows them). Text notes get
  no reply at all — the reaction lifecycle (§6) is the acknowledgment. Voice notes still
  get the transcript quoted back (`🎙 > <transcript>`): the reaction says "queued", the
  quote is the only way to catch a mis-transcription before it becomes a task.

## Changes

### 1) Trigger match — deterministic, exact, registered topics only

In `process_message`, after the allowlist and the `status` short-circuit, before note
routing: strip the text; case-fold for the keywords. If it equals exactly one of the four
tokens **and** the topic is registered, dispatch; else fall through to the note path.
Exact match only — the word "plan" inside an intent sentence must never fire. Unregistered
topics get no triggers (nothing to run them in).

*Objection: DESIGN Phase 3 routes via a `claude -p` judgment call.* Four fixed tokens are
mechanics, not judgment — the mechanics/judgment split says script. The router stays
unbuilt until a message genuinely needs interpretation.

### 2) 🧠 → headless plan

Spawn detached (`start_new_session=True`, cwd = workspace, output to a log under
`$ORCH_HOME/run/`):

    claude -p "/machines-at-work:plan headless"

Ack immediately in the topic ("🧠 planning…"). Plan itself drains `.inbox/` (step 1 of the
skill) and — per the companion proposal — posts the resulting task list to the topic via
`notify.sh`. The daemon never waits on the child; the long-poll loop stays responsive.

### 3) 🚀 → detached loop.sh

Spawn detached, cwd = workspace, `"$MAW_SCRIPTS/loop.sh"`, log under `$ORCH_HOME/run/`.
Ack "🚀 loop started". Progress/escalations/finish already reach the topic — loop.sh calls
`notify.sh` throughout. `MAW_SCRIPTS` (path to the installed plugin's `scripts/`) is a new
line in `telegram.env`; if unset, 🚀 replies with a config error instead of failing silently.

### 4) 🚀 is the approval — no pending state

Flow: text intent → 🧠 → read the posted task plan → 🚀 (or text corrections and 🧠 again).
Supersedes DESIGN #2's per-topic pending-approval state and #9's `APPROVAL_MODE` knob —
the explicit send of 🚀 *is* `required`-mode approval, and sending it immediately is `auto`.
The daemon stays stateless across messages.

### 5) Concurrency guard

One pidfile per workspace per action (`$ORCH_HOME/run/<name>.{plan,loop}.pid`). A token
arriving while its pid is alive gets "already running" instead of a second process. Stale
pidfile (dead pid) → proceed. Survives daemon restarts; costs no daemon state.

### 6) Message-lifecycle reactions — every allow-listed message answers for itself

Add `set_reaction(chat_id, message_id, emoji)` to `TelegramAPI` (`setMessageReaction`;
calling again replaces the previous reaction). Lifecycle on every allow-listed message:

- **👀 on receipt** — set immediately after the allowlist check, before transcription/
  routing: "the server has it".
- **👌 on success** — note queued to `.inbox/`, trigger dispatched (process spawned — for
  🧠/🚀 the reaction means *started*, not *finished*; completion arrives via `notify.sh`),
  or status report sent.
- **😱 on failure, plus a reply saying what went wrong** — failed transcription,
  unregistered topic, unsupported message type (image/sticker/…), missing `MAW_SCRIPTS`,
  spawn error, missing workspace. This upgrades today's silent swallows: an unregistered
  topic currently logs `skip:` and the phone hears nothing.

*Objection: why not ✅/⚠️/⏳?* Bots may only react with Telegram's fixed reaction set;
none of those three are in it. 👀/👌/😱 are the closest legal trio; the ⚠️-style detail
lives in the failure reply text, which carries the actual reason anyway.

Reaction calls are tolerant like everything else: a failed `setMessageReaction` (message
too old, API hiccup) is logged and never blocks processing. Non-allow-listed senders get
no reaction — a stranger probing the bot learns nothing (Decision #4).

## Verify

Extend `tests/smoke.sh` (stub API, stub spawner, tmp workspace):
1. Text message → file appears at `updates/.inbox/<epoch>-<msgid>.md`, raw content, no note in `updates/`; stub API saw reactions 👀 then 👌 and no reply text.
2. `🧠` / `plan` / `PLAN ` (case/whitespace) → spawner called with the plan command; no inbox file; 👀 → 👌.
3. `let's plan this later` → inbox file, no spawn.
4. Second `🚀` with live pidfile → "already running" reply, no second spawn.
5. Message in an unregistered topic → 👀 then 😱 and a reply naming the problem; no inbox file.
6. Photo message → 😱 + "unsupported" reply.
7. Plugin side already covered: machines-at-work's smoke test drains a faked `.inbox/`.

## Risks

- **Headless plan blocks on interactivity** — the skill asks the user when there are no
  notes and presents the plan for approval. Companion proposal makes the `headless`
  argument branch both into `notify.sh` replies. Trigger work should land after it.
- **Tasks are created before a human approves.** Deliberate: approval shifts from "accept
  tasks interactively" to "read topic, send 🚀". A wrong plan is corrected by texting and
  re-planning — same recovery as today, one message later.
- **Replay on restart** — already covered by the persisted offset; a trigger is processed
  at most once.

## Not in scope

New-project-from-General (Phase 4), the judgment router, inline approve/reject buttons,
non-exact matching of any kind.
