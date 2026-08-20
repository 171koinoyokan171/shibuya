#!/usr/bin/env bash
# Deploy: syncs ~/shibuya to the Pi and (optionally) runs bootstrap.
#
# Run this ON THE MAC:
#   ./deploy.sh                    # sync files only
#   ./deploy.sh --run              # sync and run phase A
#   ./deploy.sh --run --only 20    # sync and run a single script
#   SHIBUYA_HOST=shibuya ./deploy.sh --run   # via a different host/alias
#
# The default host is shibuya.local (mDNS, works while the Pi is at home).
# Once it moves: SHIBUYA_HOST=shibuya (Tailscale MagicDNS) or shibuya-wan.

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
# -a preserves permissions as they are, including the executable bit on scripts.
# --chmod is deliberately not used: rsync on macOS does not support it.
rsync -az --delete \
  --exclude '.git/' \
  --exclude '*.swp' \
  --exclude 'secrets/' \
  "$SRC" "${HOST}:${DST}"

# Safety net in case a file was created without +x.
ssh "$HOST" 'chmod +x ~/shibuya/*.sh ~/shibuya/scripts/*.sh ~/shibuya/tools/*.sh 2>/dev/null || true'
echo "  ok synced"

if [[ $RUN -eq 1 ]]; then
  echo "==> running bootstrap on ${HOST}"
  # -t is needed so sudo and interactive prompts work.
  ssh -t "$HOST" "sudo ~/shibuya/bootstrap.sh ${PASSTHRU[*]:-}"
fi
