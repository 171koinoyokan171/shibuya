#!/usr/bin/env bash
# Shared helpers for every shibuya script.
# Sourced via: source "$(dirname "$0")/../lib/common.sh"
#
# Core principle: every function is idempotent and does nothing when the
# desired state is already in place. Running bootstrap.sh a second time must
# be safe and almost silent.

set -Eeuo pipefail

SHIBUYA_ETC="/etc/shibuya"
SHIBUYA_BACKUPS="${SHIBUYA_ETC}/backups"
SHIBUYA_STATE="${SHIBUYA_ETC}/state"

# --------------------------------------------------------------- output ----

_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_dim=$'\033[2m'

log()   { printf '%s==>%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
skip()  { printf '%s  --%s %s\n' "$_c_dim"    "$_c_reset" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()   { printf '%sFAIL%s %s\n' "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

# Prints a section header so that in bootstrap's long output it is clear
# which script is currently running.
section() {
  printf '\n%s%s%s\n' "$_c_blue" "────── $* ──────" "$_c_reset"
}

on_error() {
  local rc=$? line=${1:-?}
  printf '%sFAIL%s line %s, code %s\n' "$_c_red" "$_c_reset" "$line" "$rc" >&2
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------- guards ---

require_root() {
  [[ $EUID -eq 0 ]] || die "root required: run this with sudo"
}

require_not_root() {
  [[ $EUID -ne 0 ]] || die "this script must run as a normal user, not as root"
}

# The user whose environment we are setting up. Scripts run under sudo, so
# $USER is root there — take the real one from SUDO_USER.
target_user() {
  echo "${SUDO_USER:-${SHIBUYA_USER:-$(id -un)}}"
}

target_home() {
  getent passwd "$(target_user)" | cut -d: -f6
}

# Run a command as the target user (not as root).
as_user() {
  local u; u="$(target_user)"
  if [[ "$(id -un)" == "$u" ]]; then
    "$@"
  else
    sudo -u "$u" -H "$@"
  fi
}

ensure_dirs() {
  install -d -m 0755 "$SHIBUYA_ETC" "$SHIBUYA_BACKUPS" "$SHIBUYA_STATE"
}

# ------------------------------------------------------------------ apt ----

_apt_updated=0

apt_update_once() {
  if [[ $_apt_updated -eq 0 ]]; then
    log "apt update"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    _apt_updated=1
  fi
}

# Installs packages that are not present yet. Always returns 0 when they are in place.
apt_install() {
  local missing=()
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' \
      || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    skip "packages already installed: $*"
    return 0
  fi
  apt_update_once
  log "apt install: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
  ok "installed: ${missing[*]}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# "output contains pattern" WITHOUT a pipeline.
#
# Do not do this:  cmd | grep -q pat
# grep exits on the first match, cmd catches SIGPIPE and with
# `set -o pipefail` the whole pipeline fails — meaning the check lies exactly
# when a match IS found. Painful to debug: the script complains about settings
# that were applied correctly.
contains() {
  local haystack="$1" pattern="$2"
  [[ "$haystack" =~ $pattern ]]
}

# ---------------------------------------------------------------- files ----

# A copy of a system file before the first edit. Taken ONCE, so that a repeat
# run does not overwrite the original with an already-modified version.
backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  ensure_dirs
  local dst="${SHIBUYA_BACKUPS}/${src//\//_}.orig"
  if [[ ! -f "$dst" ]]; then
    cp -a "$src" "$dst"
    ok "original backed up: $dst"
  fi
}

# Flag: "the last write_file/ensure_line/ensure_block changed something".
#
# These functions used to signal that with exit code 1 = "no changes".
# Under `set -e` that was a landmine: any call not wrapped in `if` or
# `|| true` killed the script on the SECOND run — exactly when idempotency
# was supposed to pay off. Forgetting the wrapper is far too easy
# (I forgot it in 12 places out of 14). Now they always return 0 and the change
# flag is read through changed().
SHIBUYA_CHANGED=0

# Did the last write_file/ensure_line/ensure_block actually change the file?
#   write_file /etc/foo.conf <<EOF ... EOF
#   if changed; then systemctl restart foo; fi
changed() { [[ "${SHIBUYA_CHANGED:-0}" == "1" ]]; }

# Write a file with the given content and mode. If the content already matches,
# it does nothing (to avoid pointless restarts). Always returns 0;
# use changed() to detect a change.
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root:root}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    chmod "$mode" "$path"; chown "$owner" "$path"
    skip "unchanged: $path"
    SHIBUYA_CHANGED=0
    return 0
  fi
  backup_file "$path"
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  ok "written: $path"
  SHIBUYA_CHANGED=1
  return 0
}

# A file in the target user's home directory.
write_user_file() {
  local rel="$1" mode="${2:-0644}"
  local home; home="$(target_home)"
  local u; u="$(target_user)"
  write_file "${home}/${rel}" "$mode" "${u}:${u}"
}

# Ensures a line exists in a file (an anchor is used to detect duplicates).
# Always returns 0; use changed() to detect an addition.
ensure_line() {
  local file="$1" line="$2" match="${3:-$2}"
  touch "$file"
  if grep -qF -- "$match" "$file" 2>/dev/null; then
    skip "line already in $file"
    SHIBUYA_CHANGED=0
    return 0
  fi
  backup_file "$file"
  printf '%s\n' "$line" >> "$file"
  ok "added to $file: $line"
  SHIBUYA_CHANGED=1
  return 0
}

# A managed block inside someone else's config — modelled on the work-isolation
# setup in ~/.ssh/config. Lets us rewrite our own chunk without touching the rest.
ensure_block() {
  local file="$1" tag="$2"
  local body; body="$(cat)"
  local start="# >>> shibuya:${tag} >>>"
  local end="# <<< shibuya:${tag} <<<"
  touch "$file"
  local new; new="$(printf '%s\n%s\n%s\n' "$start" "$body" "$end")"

  if grep -qF "$start" "$file"; then
    local current
    current="$(awk -v s="$start" -v e="$end" '$0==s{f=1} f{print} $0==e{f=0}' "$file")"
    if [[ "$current" == "$new" ]]; then
      skip "block ${tag} unchanged: $file"
      SHIBUYA_CHANGED=0
      return 0
    fi
    backup_file "$file"
    local tmp; tmp="$(mktemp)"
    awk -v s="$start" -v e="$end" '$0==s{f=1;next} $0==e{f=0;next} !f{print}' "$file" > "$tmp"
    printf '%s\n' "$new" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    ok "block ${tag} updated: $file"
  else
    backup_file "$file"
    printf '\n%s\n' "$new" >> "$file"
    ok "block ${tag} added: $file"
  fi
  SHIBUYA_CHANGED=1
  return 0
}

# ------------------------------------------------------------- systemd -----

systemd_reload_if_needed() {
  systemctl daemon-reload
}

enable_now() {
  local unit="$1"
  if systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl is-active --quiet "$unit" 2>/dev/null; then
    skip "$unit already enabled+active"
    return 0
  fi
  systemctl enable --now "$unit"
  ok "$unit enabled+active"
}

# ------------------------------------------------------------ apt repos ----

# Adds a third-party apt repository with the key in the correct (non-deprecated)
# format: key in /etc/apt/keyrings, signed-by in the .list file.
add_apt_repo() {
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"

  install -d -m 0755 /etc/apt/keyrings

  if [[ ! -s "$keyring" ]]; then
    log "repository key ${name}"
    curl -fsSL "$key_url" | gpg --dearmor -o "$keyring"
    chmod 0644 "$keyring"
    _apt_updated=0
  fi

  local line="deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] ${repo_line}"
  if [[ -f "$list" ]] && grep -qF "$line" "$list"; then
    skip "repository ${name} already configured"
  else
    printf '%s\n' "$line" > "$list"
    ok "repository ${name} added"
    _apt_updated=0
  fi
}

# ------------------------------------------------------------- markers ------

# For steps that cannot be checked with a cheap command (one-off migrations,
# for example) — a marker file in /etc/shibuya/state.
step_done() { ensure_dirs; [[ -f "${SHIBUYA_STATE}/$1" ]]; }
mark_done() { ensure_dirs; touch "${SHIBUYA_STATE}/$1"; }
