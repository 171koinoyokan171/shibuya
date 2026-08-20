#!/usr/bin/env bash
# Access and context isolation: the Pi's SSH keys, ~/.ssh/config, git fail-closed, direnv.
#
# The pt client-context key is NOT created by default. Enable it deliberately:
#   sudo SHIBUYA_WITH_PT=1 ~/shibuya/bootstrap.sh --only 70
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"
SSH_DIR="${USER_HOME}/.ssh"
WITH_PT="${SHIBUYA_WITH_PT:-0}"

GIT_NAME="${SHIBUYA_GIT_NAME:-Dmitriy Kaluzhniy}"
GIT_EMAIL="${SHIBUYA_GIT_EMAIL:-dmitriy.kaluzhniy@skelar.tech}"

install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$SSH_DIR"

# -------------------------------------------------------------- keys ------
# Private keys are NOT copied from the Mac. Separate keys for the Pi can be
# revoked independently: if the box at my parents' is compromised, the work laptop is untouched.
section "SSH keys"
gen_key() {
  local name="$1" comment="$2"
  local path="${SSH_DIR}/${name}"
  if [[ -f "$path" ]]; then
    skip "key ${name} already exists"
  else
    as_user ssh-keygen -t ed25519 -N '' -f "$path" -C "$comment" >/dev/null
    ok "key ${name} created"
  fi
}

gen_key id_lvn "shibuya-pi:skelar"
gen_key id_gh  "shibuya-pi:personal"
if [[ "$WITH_PT" == "1" ]]; then
  gen_key id_pt "shibuya-pi:pt"
else
  skip "pt key not created (set SHIBUYA_WITH_PT=1 if you need it)"
fi

# --------------------------------------------------------- ssh config -----
# Mirrors the isolation scheme from the Mac. UseKeychain is deliberately absent —
# it is a macOS-specific directive and ssh complains about it on Linux.
section "~/.ssh/config"
PT_BLOCK=""
if [[ "$WITH_PT" == "1" ]]; then
  PT_BLOCK="
Host github.com-pt
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_pt
    IdentitiesOnly yes
"
fi

CFG="${SSH_DIR}/config"
touch "$CFG"; chown "${USER_NAME}:${USER_NAME}" "$CFG"; chmod 0600 "$CFG"

ensure_block "$CFG" "identities" <<EOF || true
Host github.com-lvn
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_lvn
    IdentitiesOnly yes
${PT_BLOCK}
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_gh
    IdentitiesOnly yes

Host *
    AddKeysToAgent yes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%n-%r-%p
    ControlPersist 10m
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chown "${USER_NAME}:${USER_NAME}" "$CFG"; chmod 0600 "$CFG"

# ---------------------------------------------------------- gitconfig -----
# Fail-closed as on the Mac: useconfigonly=true means a commit without an
# explicitly set identity simply will not go through. It guards against committing
# to a work repo under the wrong name — especially valuable where contexts mix.
section "git identity"
write_file "${USER_HOME}/.gitconfig-skelar" 0644 "${USER_NAME}:${USER_NAME}" <<EOF || true
[user]
	email = ${GIT_EMAIL}
	name = ${GIT_NAME}
[core]
	sshCommand = ssh -i ${SSH_DIR}/id_lvn -o IdentitiesOnly=yes
EOF

write_file "${USER_HOME}/.gitconfig" 0644 "${USER_NAME}:${USER_NAME}" <<EOF || true
[core]
	excludesfile = ${USER_HOME}/.gitignore_global
[user]
	# Without an explicit identity a commit fails — instead of quietly committing
	# as the wrong person, git errors out. The identity is supplied by includeIf below.
	useConfigOnly = true
[init]
	defaultBranch = main
[pull]
	rebase = true
[includeIf "gitdir:${USER_HOME}/lvn/"]
	path = ${USER_HOME}/.gitconfig-skelar
EOF

write_file "${USER_HOME}/.gitignore_global" 0644 "${USER_NAME}:${USER_NAME}" <<'EOF' || true
.DS_Store
*.swp
.direnv/
.envrc.local
EOF

# ------------------------------------------------------- work directory ---
# Parity with the Mac: ~/lvn with the same .envrc so includeIf and WORK_CONTEXT
# behave identically. Repositories are cloned on demand — dragging all 40 onto
# an SD card makes no sense.
section "~/lvn"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/lvn"
write_file "${USER_HOME}/lvn/.envrc" 0644 "${USER_NAME}:${USER_NAME}" <<'EOF' || true
export WORK_CONTEXT="skelar"
EOF
as_user direnv allow "${USER_HOME}/lvn" 2>/dev/null \
  && ok "direnv allow for ~/lvn" \
  || warn "direnv allow failed — run it by hand in ~/lvn"

# ---------------------------------------------------------- output --------
section "public keys — add these to GitHub"
echo
for k in id_lvn id_gh id_pt; do
  [[ -f "${SSH_DIR}/${k}.pub" ]] || continue
  echo "  ${k}:"
  echo "    $(cat "${SSH_DIR}/${k}.pub")"
done
echo
echo "  After 'gh auth login' they can be added with a single command:"
echo "    gh ssh-key add ~/.ssh/id_lvn.pub --title 'shibuya-pi (skelar)'"
echo "    gh ssh-key add ~/.ssh/id_gh.pub  --title 'shibuya-pi (personal)'"

ok "70-identity done"
