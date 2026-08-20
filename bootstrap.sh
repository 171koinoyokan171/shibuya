#!/usr/bin/env bash
# shibuya bootstrap — turns a Raspberry Pi 5 into a server I can work from on my phone.
#
# Run this ON THE Pi:
#   sudo ~/shibuya/bootstrap.sh                 # every phase A script, in order
#   sudo ~/shibuya/bootstrap.sh --only 20       # only 20-hardening.sh
#   sudo ~/shibuya/bootstrap.sh --skip 60,90    # everything except docker and ups
#   sudo ~/shibuya/bootstrap.sh --list          # see what exists
#
# Everything is idempotent: re-running is safe and almost silent.
# Scripts 80/90 are NOT part of the default set — they are phase B (preparing for the move),
# run them separately and deliberately: sudo ./bootstrap.sh --only 80

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/lib/common.sh"

# Phase A — what gets done at home, while the Pi is within reach.
PHASE_A=(00-base 10-mosh-tmux 20-hardening 30-tailscale 40-devtools 45-claude-sync 50-cloud 60-docker 70-identity)

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_scripts() {
  log "available scripts:"
  local f
  for f in "${ROOT}"/scripts/*.sh; do
    local base; base="$(basename "$f" .sh)"
    local desc; desc="$(sed -n '2s/^# \{0,1\}//p' "$f")"
    local mark="  "
    [[ " ${PHASE_A[*]} " == *" ${base} "* ]] && mark="A "
    printf '  %s %-16s %s\n' "$mark" "$base" "$desc"
  done
  echo
  echo "  A = part of the default run (phase A). The rest is manual, via --only."
}

ONLY=""; SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --list) list_scripts; exit 0 ;;
    -h|--help) usage 0 ;;
    *) warn "unknown argument: $1"; usage 1 ;;
  esac
done

require_root
ensure_dirs

# The target user must be a real one, not root — otherwise the configs
# land in /root and nothing shows up on the phone.
TU="$(target_user)"
[[ "$TU" != "root" ]] || die "run this with sudo as a normal user, not from a root shell"
log "target user: ${TU} ($(target_home))"

# Pick the scripts to run.
selected=()
if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra want <<< "$ONLY"
  for w in "${want[@]}"; do
    w="${w// /}"
    matches=("${ROOT}"/scripts/"${w}"*.sh)
    [[ -e "${matches[0]}" ]] || die "no script matches prefix '${w}'"
    for m in "${matches[@]}"; do selected+=("$(basename "$m" .sh)"); done
  done
else
  selected=("${PHASE_A[@]}")
fi

if [[ -n "$SKIP" ]]; then
  IFS=',' read -ra drop <<< "$SKIP"
  filtered=()
  for s in "${selected[@]}"; do
    keep=1
    for d in "${drop[@]}"; do
      d="${d// /}"
      [[ "$s" == "$d"* ]] && keep=0
    done
    [[ $keep -eq 1 ]] && filtered+=("$s")
  done
  selected=("${filtered[@]}")
fi

[[ ${#selected[@]} -gt 0 ]] || die "nothing to run"

log "to run: ${selected[*]}"

started_at="$(date -Is)"
failed=()

for name in "${selected[@]}"; do
  script="${ROOT}/scripts/${name}.sh"
  [[ -f "$script" ]] || die "no such file: $script"
  section "$name"
  # One failing script does not abort the run: the other steps are independent,
  # and the failures are printed at the end.
  if SHIBUYA_ROOT="$ROOT" SHIBUYA_USER="$TU" bash "$script"; then
    ok "$name finished"
  else
    rc=$?
    warn "$name failed (code $rc) — continuing with the rest"
    failed+=("$name")
  fi
done

section "summary"
echo "started:  $started_at"
echo "finished: $(date -Is)"
if [[ ${#failed[@]} -gt 0 ]]; then
  warn "failed: ${failed[*]}"
  echo
  echo "Work through them one at a time:  sudo ${ROOT}/bootstrap.sh --only ${failed[0]%%-*}"
  exit 1
fi

ok "all steps passed"
echo
echo "Next:"
echo "  1. Interactive logins (these cannot be automated):"
echo "       sudo tailscale up --hostname=shibuya      # then DISABLE key expiry in the admin console"
echo "       gcloud auth login --no-launch-browser"
echo "       gh auth login"
echo "       claude   # paste the OAuth URL"
echo "  2. Verify:  ${ROOT}/verify.sh"
