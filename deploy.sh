#!/usr/bin/env bash
# Раскатка: синхронизирует ~/shibuya на Pi и (опционально) запускает bootstrap.
#
# Запускать НА МАКЕ:
#   ./deploy.sh                    # только синхронизировать файлы
#   ./deploy.sh --run              # синхронизировать и прогнать фазу A
#   ./deploy.sh --run --only 20    # синхронизировать и прогнать один скрипт
#   SHIBUYA_HOST=shibuya ./deploy.sh --run   # через другой хост/алиас
#
# Хост по умолчанию — shibuya.local (mDNS, работает пока Pi дома).
# После переезда: SHIBUYA_HOST=shibuya (Tailscale MagicDNS) или shibuya-wan.

set -Eeuo pipefail

HOST="${SHIBUYA_HOST:-koinoyokan171@shibuya.local}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/"
DST="shibuya/"

RUN=0; PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN=1; shift ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

echo "==> sync ${SRC} -> ${HOST}:~/${DST}"
# -a сохраняет права как есть, включая исполняемый бит на скриптах.
# --chmod намеренно не используем: rsync в macOS его не поддерживает.
rsync -az --delete \
  --exclude '.git/' \
  --exclude '*.swp' \
  --exclude 'secrets/' \
  "$SRC" "${HOST}:${DST}"

# Подстраховка на случай, если файл создали без +x.
ssh "$HOST" 'chmod +x ~/shibuya/*.sh ~/shibuya/scripts/*.sh ~/shibuya/tools/*.sh 2>/dev/null || true'
echo "  ok синхронизировано"

if [[ $RUN -eq 1 ]]; then
  echo "==> запуск bootstrap на ${HOST}"
  # -t нужен, чтобы sudo и интерактивные подтверждения работали.
  ssh -t "$HOST" "sudo ~/shibuya/bootstrap.sh ${PASSTHRU[*]:-}"
fi
