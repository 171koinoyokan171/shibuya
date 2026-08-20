#!/usr/bin/env bash
# Fetches the chat_id from a freshly created bot and writes everything into move.env.
#
# What to do BEFORE running this:
#   1. Create a bot with @BotFather (/newbot) — it hands you a token like
#      8123456789:AAH...  Copy it.
#   2. Open your bot in Telegram and press START (or send it any message).
#      Without that the bot is not allowed to message you and there is
#      nowhere for the chat_id to come from — the usual sticking point here.
#
# Run on the Pi:
#   ~/shibuya/tools/telegram-setup.sh
#   ~/shibuya/tools/telegram-setup.sh 8123456789:AAH...   # token as an argument

set -Eeuo pipefail

ENVF=/etc/shibuya/move.env
_g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _0=$'\033[0m'

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  # -r so backslashes in the token are not eaten, even though there are none
  read -rp "Bot token from @BotFather: " TOKEN
fi
TOKEN="${TOKEN// /}"

if [[ ! "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  printf '%sThat does not look like a token.%s Expected 8123456789:AAH...\n' "$_r" "$_0" >&2
  exit 1
fi

API="https://api.telegram.org/bot${TOKEN}"

# The token is validated before looking for a chat_id — otherwise it is unclear
# what went wrong: the token or the missing messages.
echo "Checking the token..."
ME="$(curl -fsS --max-time 15 "${API}/getMe" || true)"
if [[ "$(printf '%s' "$ME" | jq -r '.ok // false')" != "true" ]]; then
  printf '%sTelegram rejected the token.%s Check that you copied all of it.\n' "$_r" "$_0" >&2
  exit 1
fi
BOTNAME="$(printf '%s' "$ME" | jq -r '.result.username')"
printf '%s  ok%s bot @%s\n' "$_g" "$_0" "$BOTNAME"

echo "Looking for your chat_id..."
CHAT_ID=""
for attempt in $(seq 1 20); do
  UPD="$(curl -fsS --max-time 15 "${API}/getUpdates" || true)"
  CHAT_ID="$(printf '%s' "$UPD" | jq -r '[.result[]?.message.chat.id] | last // empty')"
  [[ -n "$CHAT_ID" ]] && break
  if [[ $attempt -eq 1 ]]; then
    printf '%s  Send bot @%s any message (or press START).%s\n' "$_y" "$BOTNAME" "$_0"
    echo   "  Waiting up to 60 seconds..."
  fi
  sleep 3
done

if [[ -z "$CHAT_ID" ]]; then
  printf '%sNo message arrived.%s\n' "$_r" "$_0" >&2
  echo "Open @${BOTNAME} in Telegram, press START and run the script again." >&2
  exit 1
fi

NAME="$(curl -fsS --max-time 15 "${API}/getUpdates" \
  | jq -r '[.result[]?.message.chat | select(.id=='"$CHAT_ID"')] | last | (.first_name // "") + " (@" + (.username // "?") + ")"')"
printf '%s  ok%s chat_id %s — %s\n' "$_g" "$_0" "$CHAT_ID" "$NAME"

# Written into move.env by replacing existing values rather than duplicating them.
echo "Writing to ${ENVF}..."
sudo test -f "$ENVF" || { printf '%sNo %s — run this first: sudo ~/shibuya/bootstrap.sh --only 80%s\n' "$_r" "$ENVF" "$_0" >&2; exit 1; }

sudo cp -a "$ENVF" "${ENVF}.bak"
sudo sed -i \
  -e "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=\"${TOKEN}\"|" \
  -e "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=\"${CHAT_ID}\"|" \
  "$ENVF"
sudo chmod 600 "$ENVF"
printf '%s  ok%s written (previous copy: %s.bak)\n' "$_g" "$_0" "$ENVF"

echo "Sending a test message..."
if curl -fsS --max-time 15 \
     -d "chat_id=${CHAT_ID}" \
     --data-urlencode "text=shibuya: bot connected. Reboot notifications, public IP changes and the daily heartbeat will arrive here." \
     "${API}/sendMessage" >/dev/null; then
  printf '%s  ok%s check Telegram\n' "$_g" "$_0"
else
  printf '%sSending failed.%s\n' "$_r" "$_0" >&2
  exit 1
fi

cat <<EOF

Next, enable the notifications themselves:
    sudo ~/shibuya/bootstrap.sh --only 80
EOF
