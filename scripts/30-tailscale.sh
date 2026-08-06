#!/usr/bin/env bash
# Основной канал доступа: Tailscale (работает через NAT, роутер родителей не трогаем).
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

HOSTNAME_TS="${SHIBUYA_TS_HOSTNAME:-shibuya}"

# --------------------------------------------------------- репозиторий -----
# Tailscale отдаёт ключ уже в бинарном виде (noarmor), поэтому НЕ прогоняем
# его через gpg --dearmor — второй раз он не разбирается.
section "репозиторий tailscale"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list

if [[ -s "$KEYRING" ]]; then
  skip "ключ tailscale уже на месте"
else
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" -o "$KEYRING"
  chmod 0644 "$KEYRING"
  ok "ключ tailscale установлен"
  _apt_updated=0
fi

REPO_LINE="deb [signed-by=${KEYRING}] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main"
if [[ -f "$LIST" ]] && grep -qF "$REPO_LINE" "$LIST"; then
  skip "репозиторий tailscale уже настроен"
else
  printf '%s\n' "$REPO_LINE" > "$LIST"
  ok "репозиторий tailscale добавлен"
  _apt_updated=0
fi

apt_install tailscale
enable_now tailscaled.service

# ------------------------------------------------------------ ufw ---------
# Правило на tailscale0 могло не примениться в 20-hardening, если интерфейса
# тогда ещё не существовало. Добавляем сейчас, когда он появился.
if have ufw && contains "$(ufw status 2>/dev/null || true)" 'Status: active'; then
  if contains "$(ufw status)" 'tailscale0'; then
    skip "правило ufw для tailscale0 уже есть"
  else
    ufw allow in on tailscale0 >/dev/null
    ok "ufw: разрешён весь входящий трафик из тайлнета"
  fi
fi

# ----------------------------------------------------------- логин --------
section "авторизация"
TS_STATUS="$(tailscale status --json 2>/dev/null || echo '{}')"
BACKEND="$(printf '%s' "$TS_STATUS" | jq -r '.BackendState // "Unknown"')"

if [[ "$BACKEND" == "Running" ]]; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  TS_NAME="$(printf '%s' "$TS_STATUS" | jq -r '.Self.DNSName // ""' | sed 's/\.$//')"
  ok "уже в тайлнете: ${TS_IP} (${TS_NAME})"
else
  log "нода не авторизована — запускаю логин"
  # tailscale up блокируется до подтверждения в браузере. Запускаем в фоне,
  # вылавливаем ссылку и показываем её — иначе bootstrap встанет намертво.
  LOGFILE=/tmp/tailscale-up.log
  rm -f "$LOGFILE"
  setsid nohup tailscale up --hostname="${HOSTNAME_TS}" --accept-dns=true \
    > "$LOGFILE" 2>&1 &
  for _ in $(seq 1 15); do
    grep -qE 'https://login\.tailscale\.com' "$LOGFILE" 2>/dev/null && break
    sleep 1
  done
  URL="$(grep -oE 'https://login\.tailscale\.com[^ ]*' "$LOGFILE" 2>/dev/null | head -1 || true)"
  if [[ -n "$URL" ]]; then
    warn "ТРЕБУЕТСЯ РУЧНОЙ ШАГ — открой ссылку в браузере:"
    echo
    echo "    $URL"
    echo
    warn "после подтверждения нода появится в тайлнете как '${HOSTNAME_TS}'"
  else
    warn "не удалось выловить ссылку; запусти вручную:"
    warn "    sudo tailscale up --hostname=${HOSTNAME_TS}"
  fi
fi

# Ключ ноды по умолчанию протухает через 180 дней, после чего машина молча
# выпадает из тайлнета — для сервера, к которому нельзя подъехать, это самый
# обидный способ потерять доступ. Предупреждаем ТОЛЬКО если expiry реально
# включён: предупреждение, которое печатается всегда, перестают читать.
EXPIRY="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "none"')"
echo
case "$EXPIRY" in
  none|null|"")
    ok "key expiry отключён — нода не выпадет из тайлнета"
    ;;
  *)
    warn "KEY EXPIRY ВКЛЮЧЁН — до ${EXPIRY}"
    warn "После этой даты нода молча выпадет из тайлнета и доступ пропадёт."
    warn "Отключить один раз: https://login.tailscale.com/admin/machines"
    warn "  -> нода '${HOSTNAME_TS}' -> ... -> Disable key expiry"
    ;;
esac

ok "30-tailscale готов"
