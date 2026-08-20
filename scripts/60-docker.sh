#!/usr/bin/env bash
# Docker Engine + compose + buildx. Careful with writes: we still live on an SD card.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"

section "docker engine"
if have docker; then
  skip "docker already installed: $(docker --version)"
else
  add_apt_repo docker \
    "https://download.docker.com/linux/ubuntu/gpg" \
    "https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Unbounded container logs are a direct way to kill the SD card and fill the disk.
# The default json-file driver grows forever.
section "daemon configuration"
write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
if changed; then
  systemctl restart docker 2>/dev/null || true
  ok "daemon restarted with log limits"
fi

enable_now docker.service

# The docker group is equivalent to root — on a single-user machine that is a
# deliberate trade for convenience: otherwise every docker call needs sudo.
section "user access"
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  skip "${USER_NAME} is already in the docker group"
else
  usermod -aG docker "$USER_NAME"
  ok "${USER_NAME} added to the docker group (applies after a new login)"
fi

echo
warn "While the system lives on an SD card, avoid heavy builds:"
warn "the card is slow and wears out from writes. After moving to an SSD,"
warn "move data-root: /etc/docker/daemon.json -> \"data-root\": \"/mnt/ssd/docker\""

ok "60-docker done"
