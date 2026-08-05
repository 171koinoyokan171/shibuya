#!/usr/bin/env bash
# Docker Engine + compose + buildx. Осторожно с записью: пока живём на SD-карте.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"

section "docker engine"
if have docker; then
  skip "docker уже стоит: $(docker --version)"
else
  add_apt_repo docker \
    "https://download.docker.com/linux/ubuntu/gpg" \
    "https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Логи контейнеров без лимита — прямой путь убить SD-карту и забить диск.
# json-file по умолчанию растёт бесконечно.
section "конфигурация демона"
if write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
then
  systemctl restart docker 2>/dev/null || true
  ok "демон перезапущен с лимитами логов"
fi

enable_now docker.service

# Группа docker эквивалентна root — на однопользовательской машине это
# осознанный размен на удобство: иначе каждый docker-вызов через sudo.
section "доступ пользователя"
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
  skip "${USER_NAME} уже в группе docker"
else
  usermod -aG docker "$USER_NAME"
  ok "${USER_NAME} добавлен в группу docker (применится после нового логина)"
fi

echo
warn "Пока система живёт на SD-карте, тяжёлые сборки лучше не гонять:"
warn "карта медленная и изнашивается от записи. После переезда на SSD"
warn "перенести data-root: /etc/docker/daemon.json -> \"data-root\": \"/mnt/ssd/docker\""

ok "60-docker готов"
