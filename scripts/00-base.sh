#!/usr/bin/env bash
# Фундамент: locale, zram-swap, лимиты journald, noatime, hardware watchdog, авто-ребут обновлений.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

# ------------------------------------------------------ apt: noble-updates -
# На этом образе в источниках оказались только 'noble' и 'noble-security',
# без 'noble-updates'. Последствия хуже, чем кажется: security-обновление
# libbz2-1.0 уже приехало, а парный ему bzip2 живёт в updates и не приезжает —
# apt встаёт в неразрешимый конфликт и НИЧЕГО не может доставить.
# Плюс машина не получает весь класс не-security исправлений.
section "apt: пул noble-updates"
write_file /etc/apt/sources.list.d/shibuya-updates.sources 0644 <<'EOF'
# shibuya: в стоковом ubuntu.sources этого образа нет noble-updates.
# Без него apt конфликтует сам с собой (bzip2 vs libbz2-1.0) и не ставит пакеты.
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
if changed; then
  _apt_updated=0
  apt_update_once
  log "подтягиваю отложенные обновления (это чинит конфликт bzip2)"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  ok "noble-updates подключён, система догнана"
fi

# ------------------------------------------------------------ пакеты -------
# Базовый набор, без которого дальше неудобно жить. mtr/ethtool/ncdu нужны
# именно для удалённой диагностики машины, к которой нельзя подъехать.
apt_install \
  build-essential git-lfs curl wget rsync ca-certificates gnupg \
  ethtool mtr-tiny ncdu unzip sqlite3 jq less man-db bash-completion

# ------------------------------------------------------------ locale -------
# Сейчас на машине есть только C.utf8, а macOS при SSH шлёт LC_CTYPE=UTF-8,
# которого в Linux не существует — отсюда "cannot set LC_CTYPE" в каждом
# логине и поломанная отрисовка кириллицы в tmux/nvim.
section "locale"
apt_install locales
if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
  skip "en_US.UTF-8 уже сгенерирован"
else
  log "генерирую en_US.UTF-8"
  sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null
  ok "en_US.UTF-8 сгенерирован"
fi
# Пишем файл целиком, а не через update-locale: `update-locale LC_ALL=`
# оставляет в файле ПУСТОЕ присваивание `LC_ALL=`, а mosh-server расценивает
# пустой LC_ALL как запрос несуществующей локали и отказывается стартовать
# ("The locale requested by LC_ALL= isn't available here").
write_file /etc/default/locale 0644 <<'EOF' || true
# shibuya: только LANG. Никаких пустых LC_* — mosh на них падает.
LANG=en_US.UTF-8
EOF

# Вторая половина проблемы: мусорный LC_CTYPE=UTF-8, который шлёт macOS.
# Важно: AcceptEnv — АДДИТИВНАЯ директива, drop-in её не переопределяет,
# а дополняет. Поэтому стоковую строку `AcceptEnv LANG LC_*` в sshd_config
# приходится именно закомментировать, иначе LC_* продолжает проходить.
section "sshd: не принимать битый LC_CTYPE"
sshd_changed=0
if grep -qE '^AcceptEnv LANG LC_\*' /etc/ssh/sshd_config; then
  backup_file /etc/ssh/sshd_config
  sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*  # shibuya: заменено drop-in-ом 10-shibuya-env.conf/' \
    /etc/ssh/sshd_config
  ok "стоковый AcceptEnv LANG LC_* закомментирован"
  sshd_changed=1
else
  skip "стоковый AcceptEnv уже закомментирован"
fi

write_file /etc/ssh/sshd_config.d/10-shibuya-env.conf 0644 <<'EOF'
# macOS шлёт LC_CTYPE=UTF-8 — в Linux такой локали нет, она ломает сессию
# и не даёт стартовать mosh-server. Принимаем только безопасный набор.
AcceptEnv LANG LC_COLLATE LC_TIME LC_MESSAGES
EOF
if changed; then
  sshd_changed=1
fi

if [[ $sshd_changed -eq 1 ]]; then
  sshd -t || die "sshd_config сломан — НЕ перезагружаю ssh, чини вручную"
  systemctl reload ssh
  ok "sshd перечитал конфиг"
  if contains "$(sshd -T)" 'acceptenv lc_\*'; then
    warn "LC_* всё ещё принимается — проверь sshd_config вручную"
  else
    ok "LC_CTYPE от клиента больше не принимается"
  fi
fi

# ------------------------------------------------------------- zram --------
# Swap на машине нет вообще при 8 ГБ RAM — Docker-сборки и node будут ловить
# OOM. zram живёт в оперативке (сжатие zstd), SD-карту не изнашивает совсем.
section "zram-swap"
apt_install zram-tools
write_file /etc/default/zramswap 0644 <<'EOF'
# shibuya: сжатый swap в RAM. Диск не трогаем — SD-карта и так расходник.
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
if changed; then
  systemctl restart zramswap.service
fi
enable_now zramswap.service
SWAP_NOW="$(swapon --show=NAME,SIZE --noheadings || true)"
if contains "$SWAP_NOW" 'zram'; then
  ok "zram активен: ${SWAP_NOW//$'\n'/ }"
else
  warn "zram не поднялся — проверь: systemctl status zramswap"
fi

# ---------------------------------------------------------- journald -------
# Журнал оставляем ПЕРСИСТЕНТНЫМ: для машины, к которой нельзя подъехать,
# логи, пережившие ребут, важнее экономии записи. Но ограничиваем размер,
# иначе он спокойно съест гигабайты на SD.
section "journald"
write_file /etc/systemd/journald.conf.d/99-shibuya.conf 0644 <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
SystemMaxFileSize=50M
SystemMaxFiles=8
RuntimeMaxUse=64M
# Защита от болтливого сервиса, который за ночь запишет карту досмерти.
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF
if changed; then
  systemctl restart systemd-journald
  ok "journald перезапущен"
fi
journalctl --vacuum-size=200M --quiet 2>/dev/null || true

# ------------------------------------------------------------ noatime ------
# Меньше записей на SD. Правим ТОЛЬКО строку корня и обязательно валидируем:
# сломанный fstab = машина не грузится, а ехать к ней далеко.
section "fstab noatime"
if grep -qE '^[^#].*\s/\s.*noatime' /etc/fstab; then
  skip "noatime для / уже стоит"
else
  backup_file /etc/fstab
  cp /etc/fstab /etc/fstab.shibuya-prev
  awk '
    /^[[:space:]]*#/ { print; next }
    NF >= 4 && $2 == "/" && $4 !~ /(^|,)noatime(,|$)/ { $4 = $4 ",noatime" }
    { print }
  ' OFS='\t' /etc/fstab.shibuya-prev > /etc/fstab
  if findmnt --verify --fstab >/dev/null 2>&1; then
    rm -f /etc/fstab.shibuya-prev
    ok "noatime добавлен для / (применится после ребута)"
  else
    mv /etc/fstab.shibuya-prev /etc/fstab
    warn "findmnt --verify не принял новый fstab — откатил, / остаётся с relatime"
  fi
fi

# ----------------------------------------------------------- watchdog ------
# На Pi 5 есть /dev/watchdog0. Если ядро зависнет, железо перезагрузит плату
# само — единственный способ поднять машину, к которой нет физического доступа.
section "hardware watchdog"
if [[ -e /dev/watchdog0 ]]; then
  write_file /etc/systemd/system.conf.d/99-shibuya-watchdog.conf 0644 <<'EOF'
[Manager]
# Ядро живо -> systemd гладит watchdog каждые 30с. Зависло -> железный ребут.
RuntimeWatchdogSec=30
# Если сам ребут завис на 5 минут — добить железом.
RebootWatchdogSec=5min
EOF
  if changed; then
    systemctl daemon-reexec
    ok "watchdog настроен (применён через daemon-reexec)"
  fi
else
  warn "/dev/watchdog0 не найден — пропускаю"
fi

# -------------------------------------------------- unattended-upgrades ----
# Security-обновления сейчас скачиваются и ставятся, но ядро без ребута не
# применяется. Для машины, к которой не подъехать, непропатченное ядро хуже
# ночного ребута. Побочная польза: регулярный ребут проверяет, что машина
# вообще умеет загружаться — пока это ещё можно починить руками.
section "unattended-upgrades"
apt_install unattended-upgrades
write_file /etc/apt/apt.conf.d/52shibuya-upgrades 0644 <<'EOF' || true
// shibuya: применять security-обновления и перезагружаться ночью.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
enable_now unattended-upgrades.service

# ------------------------------------------------------- физический доступ -
# У родителей к коробке есть физический доступ. Открытая консольная сессия
# на tty1 — это шелл с sudo без пароля для любого, кто нажмёт клавишу.
section "консоль"
if ls /etc/systemd/system/getty@tty1.service.d/*.conf >/dev/null 2>&1 \
   && grep -rq -- '--autologin' /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null; then
  warn "на tty1 включён АВТОЛОГИН — до переезда это стоит выключить"
else
  ok "автологин на tty1 не настроен"
fi
if who | grep -q 'tty1'; then
  warn "на tty1 висит открытая сессия с $(who | awk '/tty1/{print $3, $4}')"
  warn "перед переездом залогаутиться физически или: sudo pkill -t tty1"
fi

ok "00-base готов"
