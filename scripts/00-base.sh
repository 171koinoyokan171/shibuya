#!/usr/bin/env bash
# Foundation: locale, zram-swap, journald limits, noatime, hardware watchdog, auto-reboot for updates.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

# ------------------------------------------------------ apt: noble-updates -
# This image ships only 'noble' and 'noble-security' in its sources, without
# 'noble-updates'. The consequences are worse than they look: the security update
# for libbz2-1.0 has landed while its matching bzip2 lives in updates and never arrives,
# so apt hits an unsolvable conflict and can install NOTHING at all.
# On top of that the machine misses the whole class of non-security fixes.
section "apt: noble-updates pocket"
write_file /etc/apt/sources.list.d/shibuya-updates.sources 0644 <<'EOF'
# shibuya: the stock ubuntu.sources on this image has no noble-updates.
# Without it apt conflicts with itself (bzip2 vs libbz2-1.0) and installs nothing.
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
if changed; then
  _apt_updated=0
  apt_update_once
  log "pulling the held-back updates (this fixes the bzip2 conflict)"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  ok "noble-updates enabled, system caught up"
fi

# ---------------------------------------------------------- packages -------
# The base set that makes everything else bearable. mtr/ethtool/ncdu exist
# specifically to debug a machine you cannot walk up to.
apt_install \
  build-essential git-lfs curl wget rsync ca-certificates gnupg \
  ethtool mtr-tiny ncdu unzip sqlite3 jq less man-db bash-completion

# ------------------------------------------------------------ locale -------
# The machine only has C.utf8, while macOS sends LC_CTYPE=UTF-8 over SSH,
# which does not exist on Linux — hence "cannot set LC_CTYPE" on every
# login and broken non-ASCII rendering in tmux/nvim.
section "locale"
apt_install locales
if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
  skip "en_US.UTF-8 already generated"
else
  log "generating en_US.UTF-8"
  sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen en_US.UTF-8 >/dev/null
  ok "en_US.UTF-8 generated"
fi
# The file is written whole rather than via update-locale: `update-locale LC_ALL=`
# leaves an EMPTY assignment `LC_ALL=` in the file, and mosh-server treats an
# empty LC_ALL as a request for a non-existent locale and refuses to start
# ("The locale requested by LC_ALL= isn't available here").
write_file /etc/default/locale 0644 <<'EOF' || true
# shibuya: LANG only. No empty LC_* — mosh dies on those.
LANG=en_US.UTF-8
EOF

# The other half of the problem: the junk LC_CTYPE=UTF-8 that macOS sends.
# Note: AcceptEnv is ADDITIVE — a drop-in does not override it, it appends.
# So the stock `AcceptEnv LANG LC_*` line in sshd_config has to be commented
# out, otherwise LC_* keeps coming through.
section "sshd: stop accepting the broken LC_CTYPE"
sshd_changed=0
if grep -qE '^AcceptEnv LANG LC_\*' /etc/ssh/sshd_config; then
  backup_file /etc/ssh/sshd_config
  sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*  # shibuya: replaced by drop-in 10-shibuya-env.conf/' \
    /etc/ssh/sshd_config
  ok "stock AcceptEnv LANG LC_* commented out"
  sshd_changed=1
else
  skip "stock AcceptEnv already commented out"
fi

write_file /etc/ssh/sshd_config.d/10-shibuya-env.conf 0644 <<'EOF'
# macOS sends LC_CTYPE=UTF-8 — no such locale on Linux; it breaks the session
# and stops mosh-server from starting. Only a safe set is accepted.
AcceptEnv LANG LC_COLLATE LC_TIME LC_MESSAGES
EOF
if changed; then
  sshd_changed=1
fi

if [[ $sshd_changed -eq 1 ]]; then
  sshd -t || die "sshd_config is broken — NOT reloading ssh, fix it by hand"
  systemctl reload ssh
  ok "sshd reloaded its config"
  if contains "$(sshd -T)" 'acceptenv lc_\*'; then
    warn "LC_* is still accepted — check sshd_config by hand"
  else
    ok "client LC_CTYPE is no longer accepted"
  fi
fi

# ------------------------------------------------------------- zram --------
# There is no swap at all on 8 GB of RAM — Docker builds and node would hit
# OOM. zram lives in RAM (zstd compression) and does not wear the SD card at all.
section "zram-swap"
apt_install zram-tools
write_file /etc/default/zramswap 0644 <<'EOF'
# shibuya: compressed swap in RAM. The disk stays untouched — the SD card is a consumable already.
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
  ok "zram active: ${SWAP_NOW//$'\n'/ }"
else
  warn "zram did not come up — check: systemctl status zramswap"
fi

# ---------------------------------------------------------- journald -------
# The journal stays PERSISTENT: for a machine you cannot walk up to, logs that
# survive a reboot matter more than saving writes. But the size is capped,
# otherwise it will happily eat gigabytes on the SD card.
section "journald"
write_file /etc/systemd/journald.conf.d/99-shibuya.conf 0644 <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
SystemMaxFileSize=50M
SystemMaxFiles=8
RuntimeMaxUse=64M
# Protection against a chatty service writing the card to death overnight.
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF
if changed; then
  systemctl restart systemd-journald
  ok "journald restarted"
fi
journalctl --vacuum-size=200M --quiet 2>/dev/null || true

# ------------------------------------------------------------ noatime ------
# Fewer writes to the SD card. ONLY the root line is edited, and it is validated:
# a broken fstab means the machine does not boot, and it is a long drive away.
section "fstab noatime"
if grep -qE '^[^#].*\s/\s.*noatime' /etc/fstab; then
  skip "noatime already set for /"
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
    ok "noatime added for / (applies after a reboot)"
  else
    mv /etc/fstab.shibuya-prev /etc/fstab
    warn "findmnt --verify rejected the new fstab — rolled back, / stays on relatime"
  fi
fi

# ----------------------------------------------------------- watchdog ------
# The Pi 5 has /dev/watchdog0. If the kernel hangs, the hardware reboots the board
# on its own — the only way to recover a machine you cannot physically reach.
section "hardware watchdog"
if [[ -e /dev/watchdog0 ]]; then
  write_file /etc/systemd/system.conf.d/99-shibuya-watchdog.conf 0644 <<'EOF'
[Manager]
# Kernel alive -> systemd pets the watchdog every 30s. Hung -> hardware reboot.
RuntimeWatchdogSec=30
# If the reboot itself hangs for 5 minutes — let the hardware finish it.
RebootWatchdogSec=5min
EOF
  if changed; then
    systemctl daemon-reexec
    ok "watchdog configured (applied via daemon-reexec)"
  fi
else
  warn "/dev/watchdog0 not found — skipping"
fi

# -------------------------------------------------- unattended-upgrades ----
# Security updates are downloaded and installed, but the kernel does not take
# effect without a reboot. For a machine out of reach, an unpatched kernel is
# worse than a nightly reboot. Side benefit: a regular reboot proves the machine
# can still boot — while that is still fixable by hand.
section "unattended-upgrades"
apt_install unattended-upgrades
write_file /etc/apt/apt.conf.d/52shibuya-upgrades 0644 <<'EOF' || true
// shibuya: apply security updates and reboot at night.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
enable_now unattended-upgrades.service

# ------------------------------------------------------- physical access ---
# My parents have physical access to the box. An open console session on tty1
# is a passwordless sudo shell for anyone who presses a key.
section "console"
if ls /etc/systemd/system/getty@tty1.service.d/*.conf >/dev/null 2>&1 \
   && grep -rq -- '--autologin' /etc/systemd/system/getty@tty1.service.d/ 2>/dev/null; then
  warn "AUTOLOGIN is enabled on tty1 — worth turning off before the move"
else
  ok "no autologin configured on tty1"
fi
if who | grep -q 'tty1'; then
  warn "an open session is sitting on tty1 since $(who | awk '/tty1/{print $3, $4}')"
  warn "log out physically before the move, or: sudo pkill -t tty1"
fi

ok "00-base done"
