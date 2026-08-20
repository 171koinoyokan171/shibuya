#!/usr/bin/env bash
# shibuya acceptance check. Run this ON THE Pi:  ~/shibuya/verify.sh
#
# Checks everything that can be checked automatically. Three things cannot be
# checked by a script and are listed at the end — mosh roaming across a network
# change, working from the phone, and outside access after the move.

set -uo pipefail   # no -e: one failed check must not cut the report short

PASS=0; FAIL=0; WARN=0
_g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _b=$'\033[34m'; _0=$'\033[0m'

chk()  { printf '  %s✔%s %s\n' "$_g" "$_0" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘%s %s\n' "$_r" "$_0" "$*"; FAIL=$((FAIL+1)); }
soft() { printf '  %s~%s %s\n' "$_y" "$_0" "$*"; WARN=$((WARN+1)); }
head_() { printf '\n%s── %s%s\n' "$_b" "$*" "$_0"; }

# "output contains pattern" without a pipeline: `cmd | grep -q` under
# pipefail lies on a match (SIGPIPE on the producer side).
has() { [[ "$1" =~ $2 ]]; }

head_ "system"
if [[ -e /dev/watchdog0 ]] && has "$(systemctl show -p RuntimeWatchdogUSec --value)" '30s|30000000'; then
  chk "hardware watchdog active (30s)"
else
  soft "watchdog not confirmed: systemctl show -p RuntimeWatchdogUSec"
fi

SWAP="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null)"
has "$SWAP" 'zram' && chk "zram-swap: ${SWAP//$'\n'/ }" || bad "zram-swap not active"

has "$(locale 2>&1)" 'en_US.UTF-8' && chk "locale en_US.UTF-8" || bad "locale is not en_US.UTF-8"
has "$(locale 2>&1)" 'Cannot set' && bad "locale still throws errors" || chk "locale is clean"

JSIZE="$(journalctl --disk-usage 2>/dev/null)"
chk "journal: ${JSIZE#*take }"

head_ "access and hardening"
UFW="$(sudo ufw status verbose 2>/dev/null)"
has "$UFW" 'Status: active'        && chk "ufw active"           || bad "ufw NOT active"
has "$UFW" 'deny \(incoming\)'     && chk "default deny incoming"  || bad "default policy is not deny"
has "$UFW" '22/tcp'                && chk "ufw: ssh allowed"     || bad "ufw: no rule for 22"
has "$UFW" '60000:60010/udp'       && chk "ufw: mosh allowed"    || bad "ufw: no rule for mosh"
has "$UFW" 'tailscale0'            && chk "ufw: tailnet trusted"  || soft "ufw: no rule for tailscale0"

SSHD="$(sudo sshd -T 2>/dev/null)"
has "$SSHD" 'permitrootlogin no'         && chk "root login disabled"        || bad "root login enabled"
has "$SSHD" 'passwordauthentication no'  && chk "password auth disabled"         || bad "password auth is allowed"
has "$SSHD" 'maxauthtries 3'             && chk "maxauthtries 3"           || soft "maxauthtries is not 3"
has "$SSHD" 'x11forwarding no'           && chk "x11forwarding off"   || soft "x11forwarding is on"
has "$SSHD" "allowusers $(id -un)"       && chk "AllowUsers = $(id -un)"   || bad "AllowUsers not configured"

if sudo fail2ban-client status sshd >/dev/null 2>&1; then
  chk "fail2ban: sshd jail active"
else
  bad "fail2ban: sshd jail not running"
fi

# Listening sockets: only ssh and (during an active session) mosh should face outward.
head_ "open ports"
LISTEN="$(sudo ss -tulnH 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\])/ {print $1, $5}' | sort -u)"
echo "$LISTEN" | sed 's/^/    /'
has "$LISTEN" '(0\.0\.0\.0|\*):22' && chk "ssh listening" || bad "ssh not listening"

head_ "tailscale"
TS="$(tailscale status --json 2>/dev/null || echo '{}')"
TSBACK="$(printf '%s' "$TS" | jq -r '.BackendState // "none"')"
if [[ "$TSBACK" == "Running" ]]; then
  chk "on the tailnet: $(tailscale ip -4 2>/dev/null | head -1) ($(printf '%s' "$TS" | jq -r '.Self.DNSName' | sed 's/\.$//'))"
  EXPIRY="$(printf '%s' "$TS" | jq -r '.Self.KeyExpiry // "none"')"
  if [[ "$EXPIRY" == "none" || "$EXPIRY" == "null" ]]; then
    chk "key expiry disabled — the node will not drop off the tailnet"
  else
    bad "KEY EXPIRY IS ON (until ${EXPIRY}) — disable it in the admin console or access will disappear"
  fi
else
  bad "tailscale not authenticated (BackendState=${TSBACK})"
fi

head_ "tools"
for t in mosh-server tmux zsh git gh docker kubectl gcloud helm k9s node npm rg fdfind batcat nvim direnv jq; do
  command -v "$t" >/dev/null 2>&1 && chk "$t" || bad "$t is missing"
done
for t in claude omc uv pulumi; do
  if command -v "$t" >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/$t" ]] || [[ -x "$HOME/.pulumi/bin/$t" ]]; then
    chk "$t"
  else
    bad "$t is missing"
  fi
done

head_ "cloud"
GACC="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
if [[ -n "$GACC" ]]; then
  chk "gcloud authenticated: ${GACC}"
  CTXS="$(kubectl config get-contexts -o name 2>/dev/null)"
  for c in lvn-prod-gke-cluster lvn-dev-gke-cluster leaply-prod-gke; do
    has "$CTXS" "$c" && chk "context ${c}" || soft "context ${c} missing"
  done
  while read -r ctx; do
    [[ -z "$ctx" ]] && continue
    if timeout 25 kubectl --context="$ctx" get nodes >/dev/null 2>&1; then
      chk "cluster responds: ${ctx##*_}"
    else
      bad "cluster does NOT respond: ${ctx##*_}"
    fi
  done <<< "$CTXS"
else
  soft "gcloud not authenticated — skipping kubectl checks"
fi

head_ "git and keys"
for k in id_lvn id_gh; do
  [[ -f "$HOME/.ssh/${k}" ]] && chk "key ${k} present" || bad "key ${k} missing"
done
has "$(git config --global --get user.useConfigOnly 2>/dev/null)" 'true' \
  && chk "git fail-closed (useConfigOnly)" || bad "useConfigOnly not enabled"
# includeIf gitdir only fires INSIDE a repository, so the check runs in a
# throwaway repo rather than just in the ~/lvn directory.
PROBE="$(mktemp -d "$HOME/lvn/.identity-probe-XXXX")"
git -C "$PROBE" init -q 2>/dev/null
IDENT="$(git -C "$PROBE" config --get user.email 2>/dev/null)"
rm -rf "$PROBE"
if [[ "$IDENT" == *"@skelar.tech" ]]; then
  chk "identity applied in ~/lvn: ${IDENT}"
else
  bad "includeIf for ~/lvn does not work (got: '${IDENT:-empty}')"
fi

for alias_ in github.com-lvn github.com; do
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -T "git@${alias_}" 2>&1)"
  if has "$out" 'successfully authenticated'; then
    chk "GitHub ${alias_}: $(printf '%s' "$out" | sed -n 's/.*Hi \([^!]*\)!.*/\1/p')"
  else
    soft "GitHub ${alias_}: key not added to the account yet"
  fi
done

head_ "docker"
if docker info >/dev/null 2>&1; then
  chk "docker works without sudo"
  if timeout 90 docker run --rm hello-world >/dev/null 2>&1; then
    chk "docker run succeeded"
  else
    bad "docker run failed"
  fi
else
  soft "docker needs sudo — log in again to pick up the docker group"
fi

head_ "claude code"
if [[ -x "$HOME/.local/bin/claude" ]]; then
  chk "claude $("$HOME/.local/bin/claude" --version 2>/dev/null)"
else
  bad "claude is not installed"
fi

head_ "survives a reboot"
for unit in ssh tailscaled docker fail2ban zramswap unattended-upgrades; do
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    chk "${unit} starts at boot"
  else
    bad "${unit} is NOT enabled at boot"
  fi
done
[[ -f /var/run/reboot-required ]] && soft "reboot required (kernel updates pending)" \
                                  || chk "no reboot required"

printf '\n%s────────────────────────%s\n' "$_b" "$_0"
printf '  %spassed: %d%s   %swarnings: %d%s   %sfailed: %d%s\n' \
  "$_g" "$PASS" "$_0" "$_y" "$WARN" "$_0" "$_r" "$FAIL" "$_0"

cat <<'EOF'

  Cannot be checked by a script — do these by hand:

  1. Connect from the iPhone through Blink over mosh and confirm you land
     straight in the tmux session 'main'.
  2. THE REAL TEST: switch the phone from WiFi to LTE mid-session.
     The session should silently carry on from the same place — that is what
     the whole thing was built for.
  3. Lock the phone for 15+ minutes and come back — the work is still there.
  4. After the move: turn Tailscale off on the phone and connect over LTE to
     the public IP at my parents' place. Otherwise it is easy to fool yourself
     into thinking the port forward works while traffic actually goes over the tailnet.
EOF

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
