#!/usr/bin/env bash
# Рабочий инструментарий: node, Claude Code, OMC, gh, direnv и CLI-комфорт.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# --------------------------------------------------------- CLI-комфорт ----
# Всё есть в apt под arm64. Названия бинарей в Debian/Ubuntu отличаются
# (batcat, fdfind) — алиасы уже прописаны в .zshrc из 10-mosh-tmux.
section "CLI-инструменты"
apt_install ripgrep fd-find bat fzf neovim direnv tree

# direnv нужен, чтобы .envrc в ~/lvn работал так же, как на Маке.
for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  hook='eval "$(direnv hook '"${rc#.}"')"'
  [[ "$rc" == ".bashrc" ]] && hook='eval "$(direnv hook bash)"'
  [[ "$rc" == ".zshrc"  ]] && hook='eval "$(direnv hook zsh)"'
  if grep -q 'direnv hook' "$f" 2>/dev/null; then
    skip "direnv hook уже в ${rc}"
  else
    # Важно: хук должен идти ДО авто-attach в tmux, иначе он окажется
    # недостижимым — tmux перехватывает управление и до конца файла
    # выполнение не доходит.
    tmp="$(mktemp)"
    awk -v hook="$hook" '
      /# >>> shibuya:tmux-autoattach >>>/ && !done { print hook; print ""; done=1 }
      { print }
      END { if (!done) print hook }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    chown "${USER_NAME}:${USER_NAME}" "$f"
    ok "direnv hook добавлен в ${rc}"
  fi
done

# ------------------------------------------------------------- node -------
# NodeSource 22.x LTS: на сервере важнее стабильность, чем свежесть.
section "node"
if have node && contains "$(node -v)" '^v2[2-9]'; then
  skip "node уже стоит: $(node -v)"
else
  add_apt_repo nodesource \
    "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    "https://deb.nodesource.com/node_22.x nodistro main"
  apt_install nodejs
  ok "node $(node -v), npm $(npm -v)"
fi

# npm ставим глобальные пакеты в ~/.local — тогда не нужен sudo npm,
# который на серверах регулярно приводит к каше из root-owned файлов в $HOME.
section "npm prefix"
NPMRC="${USER_HOME}/.npmrc"
if grep -q "prefix=${USER_HOME}/.local" "$NPMRC" 2>/dev/null; then
  skip "npm prefix уже настроен"
else
  install -d -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/.local/bin" "${USER_HOME}/.local/lib"
  printf 'prefix=%s/.local\n' "$USER_HOME" >> "$NPMRC"
  chown "${USER_NAME}:${USER_NAME}" "$NPMRC"
  ok "npm prefix = ~/.local"
fi

for rc in .bashrc .zshrc; do
  ensure_line "${USER_HOME}/${rc}" 'export PATH="$HOME/.local/bin:$PATH"' '.local/bin:$PATH' || true
  chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/${rc}"
done

# ------------------------------------------------------- Claude Code ------
# Ставим нативным установщиком — тем же способом, что на Маке
# (~/.local/share/claude/versions/...), а не через npm.
section "Claude Code"
if as_user test -x "${USER_HOME}/.local/bin/claude"; then
  skip "claude уже стоит: $(as_user "${USER_HOME}/.local/bin/claude" --version 2>/dev/null || echo '?')"
else
  as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    && ok "claude установлен" \
    || warn "установка claude не удалась — поставь вручную: curl -fsSL https://claude.ai/install.sh | bash"
fi

# ------------------------------------------------------------- OMC --------
section "oh-my-claudecode"
if as_user test -x "${USER_HOME}/.local/bin/omc"; then
  skip "omc уже стоит: $(as_user "${USER_HOME}/.local/bin/omc" --version 2>/dev/null || echo '?')"
else
  as_user npm install -g oh-my-claude-sisyphus >/dev/null 2>&1 \
    && ok "omc установлен: $(as_user "${USER_HOME}/.local/bin/omc" --version 2>/dev/null || echo '?')" \
    || warn "omc не установился — поставь вручную: npm i -g oh-my-claude-sisyphus"
fi

# --------------------------------------------------------------- gh -------
# GitHub отдаёт ключ уже дearmored — через gpg --dearmor его гонять нельзя.
section "gh cli"
if have gh; then
  skip "gh уже стоит: $(gh --version | head -1)"
else
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
  _apt_updated=0
  apt_install gh
fi

# --------------------------------------------------------------- uv -------
section "uv"
if as_user test -x "${USER_HOME}/.local/bin/uv"; then
  skip "uv уже стоит"
else
  as_user bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1 \
    && ok "uv установлен" \
    || warn "uv не установился"
fi

ok "40-devtools готов"
echo
echo "  Ручные логины (нужен браузер):"
echo "    gh auth login"
echo "    claude          # вставить OAuth-URL"
