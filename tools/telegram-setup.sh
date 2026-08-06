#!/usr/bin/env bash
# Достаёт chat_id у свежесозданного бота и прописывает всё в move.env.
#
# Что нужно сделать ДО запуска:
#   1. У @BotFather создать бота (/newbot) — он выдаст токен вида
#      8123456789:AAH...  Скопировать его.
#   2. Открыть своего бота в Telegram и нажать START (или написать ему
#      любое сообщение). Без этого бот не имеет права вам писать, и
#      chat_id взяться неоткуда — это самый частый ступор на этом шаге.
#
# Запуск на Pi:
#   ~/shibuya/tools/telegram-setup.sh
#   ~/shibuya/tools/telegram-setup.sh 8123456789:AAH...   # токен аргументом

set -Eeuo pipefail

ENVF=/etc/shibuya/move.env
_g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _0=$'\033[0m'

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  # -r чтобы бэкслеши в токене не съедались, хотя их там и не бывает
  read -rp "Токен бота от @BotFather: " TOKEN
fi
TOKEN="${TOKEN// /}"

if [[ ! "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  printf '%sНе похоже на токен.%s Ожидается вид 8123456789:AAH...\n' "$_r" "$_0" >&2
  exit 1
fi

API="https://api.telegram.org/bot${TOKEN}"

# Проверяем сам токен раньше, чем ищем chat_id — иначе непонятно, что именно
# не так: токен или отсутствие сообщений.
echo "Проверяю токен..."
ME="$(curl -fsS --max-time 15 "${API}/getMe" || true)"
if [[ "$(printf '%s' "$ME" | jq -r '.ok // false')" != "true" ]]; then
  printf '%sТокен не принят Telegram.%s Проверь, что скопирован целиком.\n' "$_r" "$_0" >&2
  exit 1
fi
BOTNAME="$(printf '%s' "$ME" | jq -r '.result.username')"
printf '%s  ok%s бот @%s\n' "$_g" "$_0" "$BOTNAME"

echo "Ищу твой chat_id..."
CHAT_ID=""
for attempt in $(seq 1 20); do
  UPD="$(curl -fsS --max-time 15 "${API}/getUpdates" || true)"
  CHAT_ID="$(printf '%s' "$UPD" | jq -r '[.result[]?.message.chat.id] | last // empty')"
  [[ -n "$CHAT_ID" ]] && break
  if [[ $attempt -eq 1 ]]; then
    printf '%s  Напиши боту @%s любое сообщение (или нажми START).%s\n' "$_y" "$BOTNAME" "$_0"
    echo   "  Жду до 60 секунд..."
  fi
  sleep 3
done

if [[ -z "$CHAT_ID" ]]; then
  printf '%sНе дождался сообщения.%s\n' "$_r" "$_0" >&2
  echo "Открой в Telegram @${BOTNAME}, нажми START и запусти скрипт снова." >&2
  exit 1
fi

NAME="$(curl -fsS --max-time 15 "${API}/getUpdates" \
  | jq -r '[.result[]?.message.chat | select(.id=='"$CHAT_ID"')] | last | (.first_name // "") + " (@" + (.username // "?") + ")"')"
printf '%s  ok%s chat_id %s — %s\n' "$_g" "$_0" "$CHAT_ID" "$NAME"

# Пишем в move.env, заменяя существующие значения, а не плодя дубли.
echo "Прописываю в ${ENVF}..."
sudo test -f "$ENVF" || { printf '%sНет %s — сначала: sudo ~/shibuya/bootstrap.sh --only 80%s\n' "$_r" "$ENVF" "$_0" >&2; exit 1; }

sudo cp -a "$ENVF" "${ENVF}.bak"
sudo sed -i \
  -e "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=\"${TOKEN}\"|" \
  -e "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=\"${CHAT_ID}\"|" \
  "$ENVF"
sudo chmod 600 "$ENVF"
printf '%s  ok%s записано (старая копия: %s.bak)\n' "$_g" "$_0" "$ENVF"

echo "Отправляю тестовое сообщение..."
if curl -fsS --max-time 15 \
     -d "chat_id=${CHAT_ID}" \
     --data-urlencode "text=shibuya: бот подключён. Сюда будут приходить уведомления о перезагрузке, смене публичного IP и суточный heartbeat." \
     "${API}/sendMessage" >/dev/null; then
  printf '%s  ok%s проверь Telegram\n' "$_g" "$_0"
else
  printf '%sОтправить не удалось.%s\n' "$_r" "$_0" >&2
  exit 1
fi

cat <<EOF

Дальше включить сами уведомления:
    sudo ~/shibuya/bootstrap.sh --only 80
EOF
