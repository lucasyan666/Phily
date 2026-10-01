#!/usr/bin/env bash
# Finds your chat with the feedback bot, stores it as TELEGRAM_CHAT_ID and
# sends a test message. Run it after setting TELEGRAM_BOT_TOKEN and pressing
# Start in your bot. Never prints the token.
#
#   cd firebase && ./tools/telegram-chat-id.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! TOKEN=$(firebase functions:secrets:access TELEGRAM_BOT_TOKEN 2>/dev/null); then
  echo "✗ No TELEGRAM_BOT_TOKEN yet. Run: firebase functions:secrets:set TELEGRAM_BOT_TOKEN" >&2
  exit 1
fi

# The bot only learns your chat id once you've messaged it (Start counts).
ID=$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ids = [u["message"]["chat"]["id"] for u in d.get("result", [])
       if "message" in u and u["message"]["chat"].get("type") == "private"]
print(ids[-1] if ids else "")')

if [[ -z $ID ]]; then
  echo "✗ The bot hasn't heard from you. Open it in Telegram, press Start" >&2
  echo "  (or send it 'hi'), then run this again." >&2
  exit 1
fi

printf %s "$ID" | firebase functions:secrets:set TELEGRAM_CHAT_ID --data-file=- >/dev/null
curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="$ID" \
  --data-urlencode text="✅ Phily feedback is connected. New messages will arrive here." >/dev/null
echo "✓ TELEGRAM_CHAT_ID set, and a test message sent to your Telegram."
