# server-orchestrator · design & rationale

> This project began life as a scaffold proposal (2026-07-09) and was later
> extracted into its own repo: it is a **standalone server-side control plane**,
> above all projects, that the agentic-engineering-scaffold plugin knows nothing
> about. The dependency runs one way — the orchestrator reads the scaffold's
> workspaces (registry → `updates/`), never the reverse. The original proposal
> text follows; where it says "apply by hand in the scaffold repo," that framing
> predates the extraction.

## Origin — Telegram voice-note orchestrator (the inbound control plane)

Realizes the scaffold's "Deliberately not built (yet): Telegram/WhatsApp bridge — notify.sh is the seam;
wire it when needed." The loop is now validated; async mobile control was the next seam.

## Goal
Drive the scaffold from a phone by voice. A Telegram supergroup ("me and my agents") with **Topics**
enabled is the control plane: one **forum topic per project**, created programmatically. A voice note in a
project's topic → transcribed on the server → routed into that project's existing inbound door
(`scaffold/updates/`) → planned → built by `loop.sh`, with escalations and results reported **back into
the same topic**. A note in the "General" topic can spawn a new project (new topic + `init-project`).

Everything runs on a **Hetzner Linux box** (always-on, the proper home for a long-poll daemon and for the
`claude -p` loop itself).

## Why Telegram, not WhatsApp
WhatsApp's only official API (Business Cloud) cannot create Communities or Channels — they are in-app-only —
and is built for business→customer template messaging. Unofficial libs (Baileys/whatsapp-web.js) violate ToS
and risk a number ban: an unsound base for an always-on orchestrator. Telegram's **Bot API** is official and
free; **forum topics** (`createForumTopic`) are exactly the "community + one channel per project" model,
created programmatically; voice download is first-class (`getFile`). It maps 1:1 to the request.

## Architecture
```
Telegram supergroup "me and my agents"  (Topics on · bot = admin w/ manage_topics)
  ├─ "General"      → orchestrator: "new project foo" → createForumTopic + init-project + register
  ├─ "foo"  ⇄  ~/projects/foo/scaffold        (message_thread_id ↔ workspace)
  └─ "bar"  ⇄  ~/projects/bar/scaffold

inbound daemon  (systemd service — DETERMINISTIC, a script):
  getUpdates long-poll (offset-tracked; no port/TLS needed)
    → drop any message whose from.id ∉ ALLOWLIST          ← the only door; enforce first
    → voice? getFile → download .oga → ffmpeg 16k mono wav → whisper.cpp → transcript
      text?  transcript = message text
    → resolve message_thread_id → workspace via registry
    → hand {transcript, workspace|General} to `claude -p` orchestrator prompt   ← the one JUDGMENT call
         feature  → write scaffold/updates/<ts>.md → /scaffold:plan → (approve via reply) → launch loop.sh detached
         new proj → createForumTopic → init-project in ~/projects/<name> → register mapping → greet in new topic
         status   → task.sh status → summarize → reply
         control  → approve pending plan · task.sh reopen <id> · stop loop
  loop.sh's notify.sh  → sendMessage(chat_id, message_thread_id=topic)   ← escalations/results into the project's topic
```
Mechanics (poll, download, transcribe, route, launch) are the script; *what a note means* is the single
`claude -p` call — the repo's mechanics/judgment split holds.

## Where each piece lives
- **Outbound leg → in the plugin.** A small `notify.sh` extension: when Telegram creds are set, POST
  `sendMessage` with `message_thread_id`. Belongs in the plugin because it runs *inside* a project.
- **Inbound daemon + orchestrator prompt + registry → a new top-level `orchestrator/` dir** (shipped in this
  repo, run standalone on the server; sibling to `DESIGN.md`/`proposals/`/`tests/`, **not** part of the
  read-only plugin). It is inherently cross-project — above any single workspace — so it cannot live in the
  per-project plugin. Ships a `systemd/agent-orchestrator.service` template and a README.
- **Registry & secrets → server-local, uncommitted.** `~/.agent-orchestrator/`: `registry.json`
  (`chat_id`, `{thread_id → workspace path}`), `telegram.env` (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`,
  `ALLOWLIST` of user ids), `chmod 600`. Per-project, `init-project`/the orchestrator writes
  `TELEGRAM_TOPIC_ID` into `scaffold/agents.env`; `notify.sh` sources the global creds + this topic id.

## Decisions (with the objection that shaped each)
1. **Voice → `updates/`, not a new inbound path.** *Objection:* doesn't a chat need its own command
   grammar? No — the scaffold already accepts human notes of any shape in `scaffold/updates/` and `/plan`
   turns them into tasks (DESIGN #13/#26). A transcript is just such a note. Reusing it means voice control inherits the
   existing plan-approval gate and `Intent:`-note rework tracking for free; no parallel intake to drift.
2. **The plan-approval gate becomes a reply, not a bypass.** *(Superseded by #10: the 🚀 trigger is the
   approval; no pending state.)* *Objection:* async voice tempts auto-plan-and-
   build. But the approved plan is the human's contract with the pipeline (DESIGN #13/#26) — so the orchestrator replies
   with the planned task list and waits for an "approve"/"go" message before launching `loop.sh`.
   Per-topic pending-approval state in the daemon; cheap, and keeps the one human gate that matters.
3. **`loop.sh` runs detached; the topic is the progress feed.** *Objection:* a build outlives a chat turn.
   The daemon fires `loop.sh` for the target workspace in the background; the outbound leg (Phase 1) is what
   makes an async build legible — every escalation/result lands in the project's topic via `notify.sh`.
4. **The allowlist is the whole security model — enforce it before anything else.** A voice note spawns
   projects and runs autonomous loops on your server; a stranger who finds the bot must hit a wall. The daemon
   drops any update whose `from.id` isn't allow-listed **before** transcription or routing. Bot token lives in
   a `chmod 600` env file, never committed. The group is private; only you add the bot.
5. **Transcription is local (whisper.cpp), not hosted.** The box is always-on and flat-cost; short notes
   transcribe in seconds on CPU (base/small model). No API key, no third-party audio, no per-minute bill.
   Cost: a one-time `whisper.cpp` build + `ffmpeg` (opus `.oga` → 16 kHz mono wav). A `transcribe.sh` wrapper
   isolates the dependency behind one interface.
6. **`createForumTopic` needs a human-seeded group.** *Objection:* can the bot bootstrap the whole thing? No —
   a bot cannot create a supergroup or enable Topics. One-time manual setup (create group, enable Topics, add
   bot as admin with `manage_topics`, capture `chat_id`); *thereafter* the bot creates a topic per project
   with no manual step. Documented in `orchestrator/README`.
7. **Long-poll, not webhook.** A public IP allows webhooks, but long-poll (`getUpdates` with offset) needs no
   inbound port, no TLS cert, no reverse proxy — simpler and sufficient for a single-user orchestrator. Revisit
   only if latency or multi-instance delivery ever matters.
8. **The daemon is one self-contained script, outside the plugin's bash-only rule.** It does HTTP + JSON +
   persistent offset/registry state; `jq`-in-bash or a single Python file both fit. It is mechanics
   (deterministic), so it stays a script — but as orchestrator-layer code it isn't bound by the plugin's
   bash convention. Pick whichever keeps it one readable file (leaning Python for the JSON/state handling).
9. **Approval is one knob, defaulting on: `APPROVAL_MODE=required|auto` (per-project, in agents.env).**
   *(Superseded by #10: sending 🚀 after reading the plan is `required`; sending it immediately is `auto` — no knob.)*
   *Objection:* async voice control eventually wants zero-friction "just build it" for trusted projects — will
   that be a rewrite? No. `required` (default) parks in per-topic pending-state and waits for an "approve"
   reply before launching `loop.sh`; `auto` launches immediately. Both **still post the transcript + plan to
   the topic** and both leave `verify.sh` as the merge gate — `auto` drops the human plan gate, never the
   legibility or the deterministic gate. It's one branch in the daemon, so a mature project can run `auto`
   while a new/risky one stays `required`. Setting it per-project (not global) is what makes the mix cheap.
10. **Deterministic tokens realize Phase 3's control; 🚀 is the approval (proposal 2026-07-19).** Exact-match
   tokens in a registered topic — 🧠/`plan` → detached headless `/machines-at-work:plan`, 🚀/`build-all` →
   detached `loop.sh` (located via `MAW_SCRIPTS` in telegram.env) — instead of the planned `claude -p` router:
   four fixed tokens are mechanics, not judgment, so the router stays unbuilt until a message genuinely needs
   interpretation. Sending 🚀 after reading the posted plan *is* the approval, which supersedes #2's
   pending-approval state and #9's `APPROVAL_MODE` knob; the daemon stays stateless across messages (pidfiles
   under `$ORCH_HOME/run/` guard double-launch and survive restarts). Every allow-listed message gets a
   reaction lifecycle — 👀 received → 👌 queued/started, or 😱 + a reply naming the failure (bots may only
   use Telegram's fixed reaction set, hence not ✅/⚠️; strangers get no reaction at all, per #4). Same
   change: raw messages now land in `updates/.inbox/<epoch>-<msgid>.md` per machines-at-work 0.15.0's
   `inbound.sh` contract — the daemon no longer names or formats notes, ending the drift where it did.

## Phased build (each phase independently verifiable)
- **Phase 1 — outbound leg (in-plugin, smallest, low-risk).** Extend `notify.sh`: creds set → `sendMessage`
  into `TELEGRAM_TOPIC_ID`. *Verify:* `notify.sh "hi"` from a project lands in its topic. Independently useful
  (escalations to your phone) before any inbound code exists. Bump plugin version; add to `tests/smoke.sh`.
- **Phase 2 — inbound, one hand-registered project.** Daemon: long-poll → allowlist → `transcribe.sh` →
  route one manually-registered topic → write `updates/<ts>.md` → reply. *Verify:* a voice note in the
  topic produces the update file with the right transcript and a reply.
- **Phase 3 — orchestrator judgment + control.** The `claude -p` router: feature (plan → reply diff → approve
  → detached `loop.sh`), status, control. *Verify:* voice "add feature X" → planned → approved → built →
  result posts back to the topic.
- **Phase 4 — new-project from General.** `createForumTopic` → `init-project` → register → greet.
  *Verify:* "new project foo" → topic appears, workspace scaffolded, mapping stored.

## Risks
- **Compromised bot token = code execution on the box.** Mitigated by the allowlist (identity, not just token)
  + `chmod 600` secrets + private group. This is the highest-severity surface; call it out in the README.
- **Transcription errors silently mis-spec.** Mitigated by Decision #2 — the plan/spec-diff is echoed back for
  approval before any build, so a mis-heard note is caught at the gate, not after code lands.
- **whisper.cpp build/RAM on a tiny box.** base/small models need ~2–4 GB; if the box is 1 vCPU/<2 GB, fall
  back to a hosted Whisper API behind the same `transcribe.sh` interface (no other code changes).
- **Registry ↔ filesystem drift** (a project dir deleted, topic orphaned). Keep the registry the single map;
  the daemon skips + logs a route to a missing workspace rather than crashing.

## Not in scope (yet)
- Multi-user (several people in the group driving projects) — allowlist already gates it; per-user workspace
  ownership would build on DESIGN's "multi-user scaffold state" note.
- Webhook delivery, media other than voice/text, inline buttons for approve/reject (a reply word is enough
  to start).
