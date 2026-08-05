#!/usr/bin/env bash
# ФАЗА B — подготовка к переезду: WiFi родителей, самолечение сети, уведомления.
#
# В дефолтный прогон НЕ входит: запускать осознанно, когда есть данные.
# Настройки берутся из /etc/shibuya/move.env (создаётся из шаблона при
# первом запуске) — чтобы пароли не лежали в git.
#
#   sudo ~/shibuya/bootstrap.sh --only 80
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

ENVF="${SHIBUYA_ETC}/move.env"

if [[ ! -f "$ENVF" ]]; then
  write_file "$ENVF" 0600 <<'EOF'
# shibuya: параметры переезда. Файл НЕ в git — пароли остаются на машине.
# Заполни и запусти:  sudo ~/shibuya/bootstrap.sh --only 80

# WiFi родителей. Критично: сейчас в netplan прописан только домашний SSID,
# и без этих данных машина поднимется у родителей БЕЗ СЕТИ ВООБЩЕ.
PARENTS_WIFI_SSID=""
PARENTS_WIFI_PSK=""

# Домашний WiFi — оставляем, чтобы Pi работал в обеих точках.
HOME_WIFI_SSID="autostrada"
HOME_WIFI_PSK=""

# Telegram-уведомления: загрузка, смена публичного IP, суточный heartbeat.
# Бот создаётся у @BotFather, chat_id — у @userinfobot.
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EOF
  warn "создан шаблон ${ENVF} — заполни его и запусти скрипт снова"
  exit 0
fi

# shellcheck disable=SC1090
source "$ENVF"

# ------------------------------------------------------------ netplan -----
# Самая опасная точка всего переезда: если у родителей не окажется known
# сети, машина поднимется без связи и чинится только физически.
section "сеть: два SSID + ethernet"
if [[ -z "${PARENTS_WIFI_SSID:-}" || -z "${PARENTS_WIFI_PSK:-}" ]]; then
  warn "PARENTS_WIFI_SSID/PSK не заполнены в ${ENVF} — netplan НЕ трогаю"
  warn "ОТВОЗИТЬ МАШИНУ В ТАКОМ ВИДЕ НЕЛЬЗЯ: у родителей она останется без сети"
else
  # Проводное соединение приоритетнее (metric ниже): стабильный линк и
  # предсказуемый NAT для проброса портов. WiFi — автоматический резерв.
  NP=/etc/netplan/60-shibuya.yaml
  if write_file "$NP" 0600 <<EOF
# shibuya: сеть для двух локаций. Ethernet приоритетнее WiFi.
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
      optional: true
      dhcp4-overrides:
        route-metric: 100
  wifis:
    wlan0:
      dhcp4: true
      dhcp6: false
      optional: true
      regulatory-domain: "UA"
      dhcp4-overrides:
        route-metric: 600
      access-points:
        "${HOME_WIFI_SSID}":
          auth:
            key-management: "psk"
            password: "${HOME_WIFI_PSK}"
        "${PARENTS_WIFI_SSID}":
          auth:
            key-management: "psk"
            password: "${PARENTS_WIFI_PSK}"
EOF
  then
    # netplan try сам откатится через 120 секунд, если конфиг разорвал связь.
    # netplan apply такой страховки не даёт — на удалённой машине это разница
    # между "подождать две минуты" и "ехать к родителям".
    if timeout 150 netplan try --timeout 120 </dev/null >/dev/null 2>&1; then
      ok "netplan принят (оба SSID + ethernet)"
    else
      warn "netplan try не подтвердился — конфиг откачен, проверь вручную"
    fi
  fi
fi

echo
log "MAC-адреса для DHCP-резервации на роутере родителей:"
for i in eth0 wlan0; do
  m="$(cat "/sys/class/net/${i}/address" 2>/dev/null || echo '—')"
  printf '    %-6s %s\n' "$i" "$m"
done

# -------------------------------------------------------- уведомления -----
# Смысл: узнать о перезагрузке или смене публичного IP ДО того, как
# понадобится доступ. Иначе первый признак проблемы — это "не могу зайти
# именно сейчас, когда очень нужно".
section "Telegram-уведомления"
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  warn "TELEGRAM_BOT_TOKEN/CHAT_ID не заполнены — уведомления не настраиваю"
else
  write_file /usr/local/bin/shibuya-notify 0755 <<'EOF'
#!/usr/bin/env bash
# Шлёт в Telegram состояние машины. Вызывается при загрузке и раз в сутки.
set -uo pipefail
source /etc/shibuya/move.env

REASON="${1:-manual}"
PUB_IP="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || echo '?')"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || echo '—')"
LAN_IP="$(hostname -I | awk '{print $1}')"
IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
UP="$(uptime -p)"
TEMP="$(awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
DISK="$(df -h / | awk 'NR==2{print $4" свободно ("$5" занято)"}')"

# Публичный IP запоминаем: его смена у родителей означает, что проброс
# портов больше не ведёт на нашу машину.
PREV_FILE=/etc/shibuya/state/last-public-ip
PREV="$(cat "$PREV_FILE" 2>/dev/null || echo '')"
CHANGED=""
[[ -n "$PREV" && "$PREV" != "$PUB_IP" ]] && CHANGED="

*ПУБЛИЧНЫЙ IP СМЕНИЛСЯ:* \`${PREV}\` -> \`${PUB_IP}\`
Проброс портов на роутере теперь может вести не туда."
printf '%s' "$PUB_IP" > "$PREV_FILE"

TEXT="*shibuya* (${REASON})
Публичный IP: \`${PUB_IP}\`
Tailscale: \`${TS_IP}\`
LAN: \`${LAN_IP}\` через ${IFACE}
Аптайм: ${UP}
Температура: ${TEMP}
Диск: ${DISK}${CHANGED}"

curl -fsS --max-time 15 \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=Markdown" \
  --data-urlencode "text=${TEXT}" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null
EOF

  write_file /etc/systemd/system/shibuya-notify.service 0644 <<'EOF'
[Unit]
Description=Сообщить в Telegram, что shibuya загрузилась
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
# Даём сети и tailscale устояться, иначе в сообщении будут пустые адреса.
ExecStartPre=/bin/sleep 20
ExecStart=/usr/local/bin/shibuya-notify boot

[Install]
WantedBy=multi-user.target
EOF

  write_file /etc/systemd/system/shibuya-heartbeat.service 0644 <<'EOF'
[Unit]
Description=Суточный heartbeat shibuya

[Service]
Type=oneshot
ExecStart=/usr/local/bin/shibuya-notify heartbeat
EOF

  write_file /etc/systemd/system/shibuya-heartbeat.timer 0644 <<'EOF'
[Unit]
Description=Раз в сутки сообщать, что машина жива

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  enable_now shibuya-notify.service
  enable_now shibuya-heartbeat.timer

  if /usr/local/bin/shibuya-notify test; then
    ok "тестовое сообщение отправлено — проверь Telegram"
  else
    warn "отправить не удалось: проверь токен и chat_id в ${ENVF}"
  fi
fi

# ------------------------------------------------------- самолечение -----
# Последняя линия обороны перед поездкой к родителям: если сеть пропала и
# сама не вернулась — перезапустить networkd, а если и это не помогло —
# перезагрузиться. Cooldown обязателен, иначе получим цикл перезагрузок.
section "самолечение сети"
write_file /usr/local/bin/shibuya-netcheck 0755 <<'EOF'
#!/usr/bin/env bash
# Проверяет связь. Три провала подряд -> рестарт сети. Шесть -> ребут.
set -uo pipefail

STATE=/etc/shibuya/state
FAILS="${STATE}/netcheck-fails"
LAST_REBOOT="${STATE}/netcheck-last-reboot"
mkdir -p "$STATE"

alive() {
  ping -c1 -W5 1.1.1.1  >/dev/null 2>&1 && return 0
  ping -c1 -W5 8.8.8.8  >/dev/null 2>&1 && return 0
  # DNS отдельно: бывает, что пакеты ходят, а резолв сломан.
  getent hosts one.one.one.one >/dev/null 2>&1 && return 0
  return 1
}

if alive; then
  echo 0 > "$FAILS"
  exit 0
fi

n=$(( $(cat "$FAILS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAILS"
logger -t shibuya-netcheck "нет связи, провал №${n}"

if [[ $n -eq 3 ]]; then
  logger -t shibuya-netcheck "перезапускаю systemd-networkd"
  systemctl restart systemd-networkd
  systemctl restart tailscaled 2>/dev/null || true
fi

if [[ $n -ge 6 ]]; then
  # Не чаще раза в час — иначе машина уйдёт в цикл перезагрузок и станет
  # недоступной надёжнее, чем от самой поломки сети.
  now=$(date +%s)
  last=$(cat "$LAST_REBOOT" 2>/dev/null || echo 0)
  if (( now - last > 3600 )); then
    echo "$now" > "$LAST_REBOOT"
    echo 0 > "$FAILS"
    logger -t shibuya-netcheck "связи нет после рестарта сети — перезагружаюсь"
    systemctl reboot
  else
    logger -t shibuya-netcheck "ребут пропущен: был меньше часа назад"
  fi
fi
EOF

write_file /etc/systemd/system/shibuya-netcheck.service 0644 <<'EOF'
[Unit]
Description=Проверка связи с самовосстановлением

[Service]
Type=oneshot
ExecStart=/usr/local/bin/shibuya-netcheck
EOF

write_file /etc/systemd/system/shibuya-netcheck.timer 0644 <<'EOF'
[Unit]
Description=Проверять связь каждые 5 минут

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
enable_now shibuya-netcheck.timer

ok "80-resilience готов"
echo
echo "  Осталось перед переездом:"
echo "    1. Снять образ SD-карты на Мак (точка отката)"
echo "    2. Залогаутиться на tty1:  sudo pkill -t tty1"
echo "    3. Распечатать памятку родителям из ~/shibuya/RUNBOOK.md"
