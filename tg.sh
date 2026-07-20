#!/usr/bin/env bash
# Telegram orchestrator helpers — the cross-project control plane (NOT plugin code).
# Reads TELEGRAM_BOT_TOKEN from the env or ~/.agent-orchestrator/telegram.env.
#   tg.sh chat-id                     # discover the id of the group the bot can see
#   tg.sh new-topic <name> [chat_id]  # create a forum topic, print its thread id
#   tg.sh rename-topic <thread_id> <new-name> [chat_id]  # rename an existing topic
#   tg.sh register <name> <scaffold-dir>  # new-topic + map it to a workspace (inbound)
#                                           and point that workspace's notify.sh at it
set -euo pipefail
env_file="${TELEGRAM_ENV:-$HOME/.agent-orchestrator/telegram.env}"
# shellcheck disable=SC1090
[ -f "$env_file" ] && . "$env_file"
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN (in the env or $env_file)}"
api="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN"

case "${1:-}" in
  chat-id)
    # Add the bot to your group as admin, send one message in the group, run this.
    curl -fsS "$api/getUpdates" | python3 -c 'import json,sys
seen={}
for u in json.load(sys.stdin).get("result",[]):
    for k in ("message","channel_post","my_chat_member"):
        c=u.get(k,{}).get("chat")
        if c: seen[c["id"]]=c.get("title") or c.get("username") or c.get("type")
for i,t in seen.items(): print(f"{i}\t{t}")
if not seen: sys.exit("no chats seen — add the bot to the group as admin, send a message there, and retry")'
    ;;
  new-topic)
    name="${2:?usage: tg.sh new-topic <name> [chat_id]}"
    chat="${3:-${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID (env/file) or pass chat_id}}"
    curl -fsS "$api/createForumTopic" \
      --data-urlencode "chat_id=$chat" \
      --data-urlencode "name=$name" | python3 -c 'import json,sys
r=json.load(sys.stdin)
if not r.get("ok"): sys.exit("createForumTopic failed: "+json.dumps(r))
print(r["result"]["message_thread_id"])'
    ;;
  rename-topic)
    # Rename an existing forum topic (e.g. after a project is renamed). The
    # thread id doesn't change, so the registry mapping still holds — only the
    # Telegram-side title moves. Idempotent: renaming to the same name is a no-op.
    tid="${2:?usage: tg.sh rename-topic <thread_id> <new-name> [chat_id]}"
    name="${3:?usage: tg.sh rename-topic <thread_id> <new-name> [chat_id]}"
    chat="${4:-${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID (env/file) or pass chat_id}}"
    curl -fsS "$api/editForumTopic" \
      --data-urlencode "chat_id=$chat" \
      --data-urlencode "message_thread_id=$tid" \
      --data-urlencode "name=$name" | python3 -c 'import json,sys
r=json.load(sys.stdin)
if not r.get("ok"): sys.exit("editForumTopic failed: "+json.dumps(r))
print("renamed")'
    ;;
  register)
    # Hand-register one project (proposal Phase 2): create its topic, map the
    # topic → workspace in the registry (inbound daemon reads this), and wire the
    # workspace's outbound notify.sh to the same topic. Idempotent per name.
    name="${2:?usage: tg.sh register <name> <scaffold-dir>}"
    ws="$(cd "${3:?usage: tg.sh register <name> <scaffold-dir>}" && pwd)"
    tid="$("$0" new-topic "$name")"
    ORCH_HOME="${ORCH_HOME:-$HOME/.agent-orchestrator}" python3 - "$tid" "$name" "$ws" <<'PY'
import json, os, sys
tid, name, ws = sys.argv[1:4]
home = os.environ["ORCH_HOME"]; os.makedirs(home, exist_ok=True)
reg = os.path.join(home, "registry.json")
d = json.load(open(reg)) if os.path.exists(reg) else {}
d[tid] = {"name": name, "workspace": ws}
json.dump(d, open(reg, "w"), indent=2)
PY
    # Outbound leg: this workspace's notify.sh now targets its own topic.
    ae="$ws/agents.env"
    if [ -f "$ae" ]; then
      if grep -q '^TELEGRAM_TOPIC_ID=' "$ae"; then
        sed -i "s/^TELEGRAM_TOPIC_ID=.*/TELEGRAM_TOPIC_ID=$tid/" "$ae"
      else
        printf 'TELEGRAM_TOPIC_ID=%s\n' "$tid" >> "$ae"
      fi
    fi
    echo "registered '$name' → topic $tid → $ws"
    ;;
  *)
    echo "usage: tg.sh {chat-id | new-topic <name> [chat_id] | rename-topic <thread_id> <new-name> [chat_id] | register <name> <scaffold-dir>}" >&2; exit 2 ;;
esac
