#!/usr/bin/env bash
# Hardening: sshd drop-in, ufw with auto-rollback, fail2ban.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
MOSH_PORTS="$(cat "${SHIBUYA_ETC}/mosh-ports" 2>/dev/null || echo '60000:60010')"
MOSH_UFW="${MOSH_PORTS/:/\:}"   # ufw wants 60000:60010 — same format

# ------------------------------------------------------------- sshd --------
# The port is NOT changed: a non-standard external port is done by forwarding on the
# router (high external -> internal 22). Changing it on the server means losing
# access the moment you forget about it on the next connection.
section "sshd"
write_file /etc/ssh/sshd_config.d/99-shibuya.conf 0644 <<EOF
# shibuya: SSH hardening. This machine will face the internet through a port forward.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 10
AllowUsers ${USER_NAME}

# Drop sessions whose client disappeared instead of piling up stuck processes.
ClientAliveInterval 30
ClientAliveCountMax 4

# Not needed, and extra attack surface.
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
PermitTunnel no
EOF
if changed; then
  # Validate BEFORE reloading: a broken sshd_config on a remote machine means
  # a trip to it. reload, not restart — existing sessions stay alive.
  if ! sshd -t; then
    warn "sshd -t rejected the config — rolling the drop-in back"
    rm -f /etc/ssh/sshd_config.d/99-shibuya.conf
    die "sshd_config failed validation, changes rolled back"
  fi
  systemctl reload ssh
  ok "sshd reloaded its config"
fi

SSHD_EFF="$(sshd -T)"
contains "$SSHD_EFF" 'permitrootlogin no' \
  && ok "root login disabled" || warn "PermitRootLogin did not take effect"
contains "$SSHD_EFF" "allowusers ${USER_NAME}" \
  && ok "AllowUsers = ${USER_NAME}" || warn "AllowUsers did not take effect"
contains "$SSHD_EFF" 'passwordauthentication no' \
  && ok "password login disabled" || warn "PasswordAuthentication did not take effect"

# -------------------------------------------------------------- ufw --------
# Order matters: rules first, then enable. The other way round cuts you off from
# the machine. Plus a safety net: a timer that turns ufw off after 10 minutes
# unless we cancel it after confirming connectivity.
section "ufw"
apt_install ufw

ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ok "default policy: deny incoming / allow outgoing"

add_rule() {
  local rule="$1" comment="$2"
  if ufw status | grep -qF "$comment"; then
    skip "rule already present: $comment"
  else
    # shellcheck disable=SC2086
    ufw allow $rule comment "$comment" >/dev/null
    ok "rule: $comment"
  fi
}

add_rule "22/tcp"            "ssh"
add_rule "${MOSH_UFW}/udp"   "mosh"
# All tailnet traffic is trusted: getting in requires a key from my own
# Tailscale account.
if ufw status | grep -q 'tailscale0'; then
  skip "tailscale0 rule already present"
else
  ufw allow in on tailscale0 >/dev/null 2>&1 || warn "no tailscale0 yet — the rule will be added after 30-tailscale"
fi

if ufw status | grep -q '^Status: active'; then
  skip "ufw already active"
else
  # Safety net: if connectivity dies after enabling ufw, the firewall turns
  # itself off after 10 minutes and the machine is reachable again.
  systemctl stop shibuya-ufw-rollback.timer 2>/dev/null || true
  systemd-run --quiet --on-active=600 --unit=shibuya-ufw-rollback \
    --description="ufw auto-rollback in case connectivity was lost after enabling" \
    /usr/sbin/ufw --force disable >/dev/null 2>&1 || warn "could not arm the auto-rollback timer"

  ufw --force enable >/dev/null
  ok "ufw enabled"
  warn "AUTO-ROLLBACK ARMED: ufw turns itself off in 10 minutes."
  warn "Test a NEW connection, then cancel the rollback:"
  warn "    sudo systemctl stop shibuya-ufw-rollback.timer"
fi

ufw status verbose | sed 's/^/    /'

# ---------------------------------------------------------- fail2ban -------
# With key-only auth this is mostly log hygiene: with port 22 exposed to the
# internet the log swells with brute-force attempts within a day.
section "fail2ban"
apt_install fail2ban

write_file /etc/fail2ban/jail.d/shibuya.local 0644 <<EOF
[DEFAULT]
# ufw enforces the bans — otherwise fail2ban would reach into iptables behind ufw's back.
banaction = ufw
bantime  = 1h
findtime = 10m
maxretry = 5
# Never ban myself or the tailnet: those are the only ways in.
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10 192.168.0.0/16 10.0.0.0/8

[sshd]
enabled = true
port    = ssh
backend = systemd
EOF
if changed; then
  systemctl restart fail2ban
fi
enable_now fail2ban.service

sleep 2
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "sshd jail active"
else
  warn "sshd jail did not come up: fail2ban-client status sshd"
fi

ok "20-hardening done"
