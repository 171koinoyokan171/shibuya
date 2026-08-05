#!/usr/bin/env bash
# Защита: sshd drop-in, ufw с автооткатом, fail2ban.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
MOSH_PORTS="$(cat "${SHIBUYA_ETC}/mosh-ports" 2>/dev/null || echo '60000:60010')"
MOSH_UFW="${MOSH_PORTS/:/\:}"   # ufw хочет 60000:60010 — формат совпадает

# ------------------------------------------------------------- sshd --------
# Порт НЕ меняем: нестандартный внешний порт делается пробросом на роутере
# (внешний высокий -> внутренний 22). Менять порт на сервере значит потерять
# доступ, если забудешь про это при следующем подключении.
section "sshd"
if write_file /etc/ssh/sshd_config.d/99-shibuya.conf 0644 <<EOF
# shibuya: ужесточение SSH. Машина будет торчать в интернет через проброс.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 10
AllowUsers ${USER_NAME}

# Рвать сессии, у которых пропал клиент, а не копить зависшие процессы.
ClientAliveInterval 30
ClientAliveCountMax 4

# Не нужно и лишняя поверхность атаки.
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
PermitTunnel no
EOF
then
  # Валидация ДО перезагрузки: сломанный sshd_config на удалённой машине
  # означает поездку к ней. reload, а не restart — существующие сессии живут.
  if ! sshd -t; then
    warn "sshd -t не принял конфиг — откатываю drop-in"
    rm -f /etc/ssh/sshd_config.d/99-shibuya.conf
    die "sshd_config не прошёл валидацию, изменения откачены"
  fi
  systemctl reload ssh
  ok "sshd перечитал конфиг"
fi

SSHD_EFF="$(sshd -T)"
contains "$SSHD_EFF" 'permitrootlogin no' \
  && ok "root-логин закрыт" || warn "PermitRootLogin не применился"
contains "$SSHD_EFF" "allowusers ${USER_NAME}" \
  && ok "AllowUsers = ${USER_NAME}" || warn "AllowUsers не применился"
contains "$SSHD_EFF" 'passwordauthentication no' \
  && ok "вход по паролю запрещён" || warn "PasswordAuthentication не применился"

# -------------------------------------------------------------- ufw --------
# Порядок критичен: сначала правила, потом enable. Наоборот — это отрезать
# себя от машины. Плюс подстраховка: таймер, который через 10 минут сам
# выключит ufw, если мы его не отменим после проверки связи.
section "ufw"
apt_install ufw

ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ok "политика по умолчанию: deny incoming / allow outgoing"

add_rule() {
  local rule="$1" comment="$2"
  if ufw status | grep -qF "$comment"; then
    skip "правило уже есть: $comment"
  else
    # shellcheck disable=SC2086
    ufw allow $rule comment "$comment" >/dev/null
    ok "правило: $comment"
  fi
}

add_rule "22/tcp"            "ssh"
add_rule "${MOSH_UFW}/udp"   "mosh"
# Весь трафик из тайлнета доверяем: попасть в него можно только с ключом
# от вашего Tailscale-аккаунта.
if ufw status | grep -q 'tailscale0'; then
  skip "правило tailscale0 уже есть"
else
  ufw allow in on tailscale0 >/dev/null 2>&1 || warn "tailscale0 ещё нет — правило добавится после 30-tailscale"
fi

if ufw status | grep -q '^Status: active'; then
  skip "ufw уже активен"
else
  # Страховка: если после включения ufw связь пропадёт, через 10 минут
  # firewall выключится сам и машина снова станет доступной.
  systemctl stop shibuya-ufw-rollback.timer 2>/dev/null || true
  systemd-run --quiet --on-active=600 --unit=shibuya-ufw-rollback \
    --description="Автооткат ufw, если после включения потеряна связь" \
    /usr/sbin/ufw --force disable >/dev/null 2>&1 || warn "не удалось поставить таймер автоотката"

  ufw --force enable >/dev/null
  ok "ufw включён"
  warn "ВЗВЕДЁН АВТООТКАТ: через 10 минут ufw выключится сам."
  warn "Проверь НОВОЕ подключение и отмени откат:"
  warn "    sudo systemctl stop shibuya-ufw-rollback.timer"
fi

ufw status verbose | sed 's/^/    /'

# ---------------------------------------------------------- fail2ban -------
# При key-only аутентификации это в основном гигиена логов: с открытым в
# интернет 22-м портом лог за сутки распухает от переборов.
section "fail2ban"
apt_install fail2ban

if write_file /etc/fail2ban/jail.d/shibuya.local 0644 <<EOF
[DEFAULT]
# ufw как исполнитель банов — иначе fail2ban полезет в iptables мимо ufw.
banaction = ufw
bantime  = 1h
findtime = 10m
maxretry = 5
# Себя и тайлнет не банить никогда: это единственные каналы доступа.
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10 192.168.0.0/16 10.0.0.0/8

[sshd]
enabled = true
port    = ssh
backend = systemd
EOF
then
  systemctl restart fail2ban
fi
enable_now fail2ban.service

sleep 2
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "jail sshd активен"
else
  warn "jail sshd не поднялся: fail2ban-client status sshd"
fi

ok "20-hardening готов"
