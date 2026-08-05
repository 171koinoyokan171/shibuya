#!/usr/bin/env bash
# Доступы и изоляция контекстов: SSH-ключи Pi, ~/.ssh/config, git fail-closed, direnv.
#
# Ключ клиентского контекста pt по умолчанию НЕ создаётся. Включить осознанно:
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

# ------------------------------------------------------------- ключи ------
# Приватные ключи с Мака НЕ копируем. Отдельные ключи для Pi можно отозвать
# независимо: если машину у родителей скомпрометируют, рабочий ноут не задет.
section "SSH-ключи"
gen_key() {
  local name="$1" comment="$2"
  local path="${SSH_DIR}/${name}"
  if [[ -f "$path" ]]; then
    skip "ключ ${name} уже есть"
  else
    as_user ssh-keygen -t ed25519 -N '' -f "$path" -C "$comment" >/dev/null
    ok "создан ключ ${name}"
  fi
}

gen_key id_lvn "shibuya-pi:skelar"
gen_key id_gh  "shibuya-pi:personal"
if [[ "$WITH_PT" == "1" ]]; then
  gen_key id_pt "shibuya-pi:pt"
else
  skip "ключ pt не создаётся (SHIBUYA_WITH_PT=1, если нужен)"
fi

# --------------------------------------------------------- ssh config -----
# Повторяет схему изоляции с Мака. UseKeychain намеренно нет — это
# macOS-специфичная директива, на Linux от неё sshd/ssh ругается.
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
# Fail-closed как на Маке: useconfigonly=true означает, что коммит без явно
# заданной identity просто не пройдёт. Это защита от коммита в рабочий репо
# от чужого имени — особенно ценно на машине, где смешаны контексты.
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
	# Без явной identity коммит не пройдёт — вместо тихого коммита не от того
	# лица git выдаст ошибку. Identity подставляется includeIf-ом ниже.
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

# ------------------------------------------------------- рабочий каталог --
# Паритет с Маком: ~/lvn с тем же .envrc, чтобы includeIf и WORK_CONTEXT
# срабатывали одинаково. Репозитории клонируем по мере надобности — все 40
# на SD-карту тащить незачем.
section "~/lvn"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/lvn"
write_file "${USER_HOME}/lvn/.envrc" 0644 "${USER_NAME}:${USER_NAME}" <<'EOF' || true
export WORK_CONTEXT="skelar"
EOF
as_user direnv allow "${USER_HOME}/lvn" 2>/dev/null \
  && ok "direnv allow для ~/lvn" \
  || warn "direnv allow не отработал — выполни вручную в ~/lvn"

# ------------------------------------------------------------ вывод -------
section "публичные ключи — добавить в GitHub"
echo
for k in id_lvn id_gh id_pt; do
  [[ -f "${SSH_DIR}/${k}.pub" ]] || continue
  echo "  ${k}:"
  echo "    $(cat "${SSH_DIR}/${k}.pub")"
done
echo
echo "  После 'gh auth login' можно добавить одной командой:"
echo "    gh ssh-key add ~/.ssh/id_lvn.pub --title 'shibuya-pi (skelar)'"
echo "    gh ssh-key add ~/.ssh/id_gh.pub  --title 'shibuya-pi (personal)'"

ok "70-identity готов"
