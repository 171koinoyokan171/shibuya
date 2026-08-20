#!/usr/bin/env bash
# Working toolchain: node, Claude Code, OMC, gh, direnv and CLI comfort.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# --------------------------------------------------------- CLI comfort ----
# Everything is in apt for arm64. Binary names differ on Debian/Ubuntu
# (batcat, fdfind) — the aliases are already in .zshrc from 10-mosh-tmux.
section "CLI tools"
apt_install ripgrep fd-find bat fzf neovim direnv tree

# direnv is here so that .envrc in ~/lvn behaves the same as on the Mac.
for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  hook='eval "$(direnv hook '"${rc#.}"')"'
  [[ "$rc" == ".bashrc" ]] && hook='eval "$(direnv hook bash)"'
  [[ "$rc" == ".zshrc"  ]] && hook='eval "$(direnv hook zsh)"'
  if grep -q 'direnv hook' "$f" 2>/dev/null; then
    skip "direnv hook already in ${rc}"
  else
    # Important: the hook must come BEFORE the tmux auto-attach, otherwise it
    # is unreachable — tmux takes over and execution never reaches the end
    # of the file.
    tmp="$(mktemp)"
    awk -v hook="$hook" '
      /# >>> shibuya:tmux-autoattach >>>/ && !done { print hook; print ""; done=1 }
      { print }
      END { if (!done) print hook }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    chown "${USER_NAME}:${USER_NAME}" "$f"
    ok "direnv hook added to ${rc}"
  fi
done

# ------------------------------------------------------------- node -------
# NodeSource 22.x LTS: on a server stability beats being current.
section "node"
if have node && contains "$(node -v)" '^v2[2-9]'; then
  skip "node already installed: $(node -v)"
else
  add_apt_repo nodesource \
    "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    "https://deb.nodesource.com/node_22.x nodistro main"
  apt_install nodejs
  ok "node $(node -v), npm $(npm -v)"
fi

# npm installs global packages into ~/.local, which avoids sudo npm —
# a reliable way to end up with root-owned files scattered around $HOME.
section "npm prefix"
NPMRC="${USER_HOME}/.npmrc"
if grep -q "prefix=${USER_HOME}/.local" "$NPMRC" 2>/dev/null; then
  skip "npm prefix already configured"
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
# Installed with the native installer, the same way as on the Mac
# (~/.local/share/claude/versions/...), rather than through npm.
section "Claude Code"
if as_user test -x "${USER_HOME}/.local/bin/claude"; then
  skip "claude already installed: $(as_user "${USER_HOME}/.local/bin/claude" --version 2>/dev/null || echo '?')"
else
  as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    && ok "claude installed" \
    || warn "claude install failed — do it by hand: curl -fsSL https://claude.ai/install.sh | bash"
fi

# ------------------------------------------------------------- OMC --------
section "oh-my-claudecode"
if as_user test -x "${USER_HOME}/.local/bin/omc"; then
  skip "omc already installed: $(as_user "${USER_HOME}/.local/bin/omc" --version 2>/dev/null || echo '?')"
else
  as_user npm install -g oh-my-claude-sisyphus >/dev/null 2>&1 \
    && ok "omc installed: $(as_user "${USER_HOME}/.local/bin/omc" --version 2>/dev/null || echo '?')" \
    || warn "omc install failed — do it by hand: npm i -g oh-my-claude-sisyphus"
fi

# --------------------------------------------------------------- gh -------
# GitHub serves the key already dearmored — do not run it through gpg --dearmor.
section "gh cli"
if have gh; then
  skip "gh already installed: $(gh --version | head -1)"
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
  skip "uv already installed"
else
  as_user bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1 \
    && ok "uv installed" \
    || warn "uv install failed"
fi

ok "40-devtools done"
echo
echo "  Manual logins (a browser is required):"
echo "    gh auth login"
echo "    claude          # paste the OAuth URL"
