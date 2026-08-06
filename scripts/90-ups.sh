#!/usr/bin/env bash
# ФАЗА B (опционально): ИБП через NUT — корректное выключение при разряде батареи.
#
# Имеет смысл только если у ИБП есть USB-порт ДАННЫХ (не только зарядка).
# Запускать когда ИБП уже подключён к Pi по USB:
#   sudo ~/shibuya/bootstrap.sh --only 90
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

section "поиск ИБП на USB"
apt_install nut-client nut-server usbutils

# nut-scanner опрашивает USB и находит поддерживаемый драйвер сам.
SCAN="$(nut-scanner -U -q 2>/dev/null || true)"
if [[ -z "$SCAN" ]] || ! contains "$SCAN" 'driver'; then
  warn "ИБП по USB не найден."
  echo
  echo "  Возможные причины:"
  echo "    - ИБП подключён только по питанию, дата-кабель не воткнут"
  echo "    - у модели нет USB-порта данных ('тупой' ИБП)"
  echo
  warn "Без связи с ИБП Pi при разряде батареи выключится жёстко."
  warn "Для SD-карты это главный способ получить повреждение файловой системы —"
  warn "ещё один довод за скорый переезд на SSD."
  echo
  echo "  Подключено по USB сейчас:"
  lsusb | sed 's/^/    /'
  exit 0
fi

ok "ИБП найден:"
printf '%s\n' "$SCAN" | sed 's/^/    /'

section "конфигурация NUT"
# Standalone: ИБП обслуживает только эту машину, сеть не задействована.
write_file /etc/nut/ups.conf 0640 "root:nut" <<EOF
# shibuya: сгенерировано nut-scanner
maxretry = 3

$(printf '%s\n' "$SCAN")
EOF
if changed; then ok "ups.conf записан"; fi

write_file /etc/nut/nut.conf 0640 "root:nut" <<'EOF'
MODE=standalone
EOF

write_file /etc/nut/upsd.users 0640 "root:nut" <<'EOF'
[upsmon]
    password = shibuya-local
    upsmon primary
EOF

UPSNAME="$(printf '%s' "$SCAN" | grep -oE '^\[[^]]+\]' | head -1 | tr -d '[]')"
UPSNAME="${UPSNAME:-ups}"

write_file /etc/nut/upsmon.conf 0640 "root:nut" <<EOF
# shibuya: выключаться заранее, а не в момент полного разряда — при жёстком
# обрыве питания на SD-карте легко получить битую файловую систему.
MONITOR ${UPSNAME}@localhost 1 upsmon shibuya-local primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RUN_AS_USER root

# Пропало электричество / вернулось / батарея на исходе — сообщить в Telegram.
NOTIFYCMD /usr/local/bin/shibuya-ups-notify
NOTIFYFLAG ONBATT  SYSLOG+EXEC
NOTIFYFLAG ONLINE  SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
EOF

write_file /usr/local/bin/shibuya-ups-notify 0755 <<'EOF'
#!/usr/bin/env bash
# upsmon зовёт этот скрипт при смене состояния питания.
set -uo pipefail
[[ -f /etc/shibuya/move.env ]] && source /etc/shibuya/move.env
[[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && exit 0

CHARGE="$(upsc "$(upsc -l 2>/dev/null | head -1)" battery.charge 2>/dev/null || echo '?')"
RUNTIME="$(upsc "$(upsc -l 2>/dev/null | head -1)" battery.runtime 2>/dev/null || echo '?')"
[[ "$RUNTIME" =~ ^[0-9]+$ ]] && RUNTIME="$((RUNTIME / 60)) мин"

curl -fsS --max-time 15 \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=shibuya ИБП: ${1:-событие}
Заряд: ${CHARGE}%  Хватит на: ${RUNTIME}" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
EOF

chown root:nut /etc/nut/*.conf 2>/dev/null || true
systemctl restart nut-server nut-monitor 2>/dev/null || true
enable_now nut-server.service
enable_now nut-monitor.service

sleep 3
if upsc "${UPSNAME}" >/dev/null 2>&1; then
  ok "ИБП опрашивается:"
  upsc "${UPSNAME}" 2>/dev/null | grep -E 'battery.charge|battery.runtime|ups.status|ups.model' | sed 's/^/    /'
else
  warn "upsc не отвечает — проверь: journalctl -u nut-server -n 30"
fi

ok "90-ups готов"
