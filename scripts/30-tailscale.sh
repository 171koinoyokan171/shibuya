#!/usr/bin/env bash
# The primary access channel: Tailscale (works through NAT, my parents' router stays untouched).
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

HOSTNAME_TS="${SHIBUYA_TS_HOSTNAME:-shibuya}"

# --------------------------------------------------------- repository ------
# Tailscale serves the key already in binary form (noarmor), so it is NOT run
# through gpg --dearmor — it does not parse a second time.
section "tailscale repository"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list

if [[ -s "$KEYRING" ]]; then
  skip "tailscale key already in place"
else
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" -o "$KEYRING"
  chmod 0644 "$KEYRING"
  ok "tailscale key installed"
  _apt_updated=0
fi

REPO_LINE="deb [signed-by=${KEYRING}] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main"
if [[ -f "$LIST" ]] && grep -qF "$REPO_LINE" "$LIST"; then
  skip "tailscale repository already configured"
else
  printf '%s\n' "$REPO_LINE" > "$LIST"
  ok "tailscale repository added"
  _apt_updated=0
fi

apt_install tailscale
enable_now tailscaled.service

# ------------------------------------------------------------ ufw ---------
# The tailscale0 rule may have been skipped in 20-hardening if the interface
# did not exist yet. Add it now that it does.
if have ufw && contains "$(ufw status 2>/dev/null || true)" 'Status: active'; then
  if contains "$(ufw status)" 'tailscale0'; then
    skip "ufw rule for tailscale0 already present"
  else
    ufw allow in on tailscale0 >/dev/null
    ok "ufw: all inbound tailnet traffic allowed"
  fi
fi

# ----------------------------------------------------------- login --------
section "authentication"
TS_STATUS="$(tailscale status --json 2>/dev/null || echo '{}')"
BACKEND="$(printf '%s' "$TS_STATUS" | jq -r '.BackendState // "Unknown"')"

if [[ "$BACKEND" == "Running" ]]; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  TS_NAME="$(printf '%s' "$TS_STATUS" | jq -r '.Self.DNSName // ""' | sed 's/\.$//')"
  ok "already on the tailnet: ${TS_IP} (${TS_NAME})"
else
  log "node not authenticated — starting login"
  # tailscale up blocks until confirmed in a browser. Run it in the background,
  # catch the URL and print it — otherwise bootstrap hangs forever.
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
    warn "MANUAL STEP REQUIRED — open this URL in a browser:"
    echo
    echo "    $URL"
    echo
    warn "once confirmed the node shows up on the tailnet as '${HOSTNAME_TS}'"
  else
    warn "could not catch the URL; run it by hand:"
    warn "    sudo tailscale up --hostname=${HOSTNAME_TS}"
  fi
fi

# A node key expires after 180 days by default, after which the machine silently
# drops off the tailnet — for a server you cannot reach that is the most
# annoying way to lose access. The warning fires ONLY when expiry is actually
# enabled: a warning that always prints stops being read.
EXPIRY="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "none"')"
echo
case "$EXPIRY" in
  none|null|"")
    ok "key expiry disabled — the node will not drop off the tailnet"
    ;;
  *)
    warn "KEY EXPIRY IS ON — until ${EXPIRY}"
    warn "After that date the node silently leaves the tailnet and access is gone."
    warn "Disable it once: https://login.tailscale.com/admin/machines"
    warn "  -> node '${HOSTNAME_TS}' -> ... -> Disable key expiry"
    ;;
esac

ok "30-tailscale done"
