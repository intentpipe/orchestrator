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

• careybo
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

## `system-scripts/`

Server-wide, cross-project tooling that isn't the Telegram bridge itself. Today: the `status`
collector. Anything the daemon exposes as a keyword-driven "report on the whole box" belongs here.
