#!/usr/bin/env bash
# Transport and phone-friendly UX: mosh, tmux with auto-attach, zsh, a comfortable shell.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# ------------------------------------------------------------- mosh --------
# mosh refuses to start without a UTF-8 locale, so 00-base has to run first.
# ncurses-term is there for the tmux-256color terminfo.
section "mosh"
apt_install mosh ncurses-term
ok "$(mosh-server --version 2>&1 | head -1)"

# The UDP port range is pinned to 60000-60010 instead of the default 60000-61000:
# these exact ports have to be forwarded one-to-one on my parents' router,
# and forwarding a thousand instead of ten makes no sense.
# This is a CLIENT flag (mosh -p 60000:60010); nothing is configured server-side,
# but it is recorded in state so ufw and the docs read the number from one place.
write_file "${SHIBUYA_ETC}/mosh-ports" 0644 <<'EOF' || true
60000:60010
EOF

# ------------------------------------------------------------- tmux --------
# tmux is the second layer of survivability. mosh keeps the CONNECTION, tmux keeps the WORK:
# it survives mosh-server dying, a phone reboot and a dead battery.
section "tmux"
apt_install tmux

install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "${USER_HOME}/.config"

write_user_file .tmux.conf 0644 <<'EOF' || true
# shibuya: tmux tuned for a phone screen and the Blink Shell keyboard.

# C-a instead of C-b: on Blink's key bar Ctrl is one tap away,
# and 'a' sits closer to the left edge than 'b'.
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# The big win on a phone: tap switches pane, a finger swipe scrolls
# through history, and pane borders can be dragged.
set -g mouse on

# True color in Blink.
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g focus-events on
set -g display-time 2000

# When a phone and a laptop are attached to the same session, do not shrink
# everything to the smallest screen — follow the active client instead.
setw -g aggressive-resize on

# vi-style copy mode: on a phone without a mouse it is the only sane option.
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-selection-and-cancel

# Splits open in the current directory; | and - as mnemonics
bind '|' split-window -h -c "#{pane_current_path}"
bind '-' split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# Reload the config without leaving the session.
bind r source-file ~/.tmux.conf \; display "tmux.conf reloaded"

# A compact status bar: there is no room to waste at 390 pixels wide.
# Temperature and load are shown because this is a Pi under load on an SD card,
# and knowing it is throttling is useful before everything grinds to a halt.
# The "^a d" hint on the left saves you from recalling from memory how to leave
# without killing the session.
set -g status-interval 10
set -g status-style "bg=colour236,fg=colour250"
set -g status-left "#[bg=colour24,fg=colour255,bold] #S #[default] #[fg=colour244]^a d = detach#[default] "
set -g status-left-length 40
set -g status-right "#[fg=colour244]#(cut -d' ' -f1 /proc/loadavg) #(awk '{printf \"%.0f°\", $1/1000}' /sys/class/thermal/thermal_zone0/temp) #[fg=colour250]%H:%M "
set -g status-right-length 40
setw -g window-status-current-style "bg=colour24,fg=colour255"
setw -g window-status-format " #I:#W "
setw -g window-status-current-format " #I:#W "
EOF

# ------------------------------------------------------- auto-attach -------
# An interactive SSH/mosh login lands straight in the persistent session
# 'main'. `new -A` = attach if it exists, otherwise create it.
#
# exec is deliberately NOT used: if tmux fails to start for any reason,
# exec would drop the connection and we would lose access to the machine.
# $TMUX is checked just as deliberately (so we do not nest into ourselves),
# along with interactivity (otherwise scp/rsync/git-over-ssh break).
section "tmux auto-attach"

# The logic lives in ONE file sourced by both shells. The snippet used to be
# copied into .bashrc and .zshrc, and an edit stopped reaching whichever rc
# already had the block — so the correct version lived in only one of them.
write_file /etc/shibuya/shell-tmux.sh 0644 <<'EOF' || true
# shibuya: tmux behaviour on SSH/mosh login. Sourced from ~/.bashrc and ~/.zshrc.

# SSH/mosh login -> straight into the persistent session. Work survives a dropped link,
# a phone reboot and a dead battery.
# Deliberately without exec: if tmux fails to start, exec would drop the connection
# and we would lose access to the machine.
if [ -z "${TMUX:-}" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && command -v tmux >/dev/null 2>&1; then
    tmux new-session -A -s main
fi

# Guard against the classic phone mistake: typing exit and destroying the
# session along with all the work. In the last window exit detaches
# (like ^a d); everywhere else it behaves as usual.
if [ -n "${TMUX:-}" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then setopt IGNORE_EOF; else set -o ignoreeof; fi
    exit() {
        if [ "$(tmux list-windows | wc -l)" -eq 1 ] && [ "$(tmux list-panes | wc -l)" -eq 1 ]; then
            echo "This is the last window — detaching; the session keeps running on the Pi."
            echo "To really close it: builtin exit  (or tmux kill-session)"
            tmux detach-client
        else
            builtin exit "$@"
        fi
    }
fi
EOF

SOURCE_LINE='[ -f /etc/shibuya/shell-tmux.sh ] && . /etc/shibuya/shell-tmux.sh'

for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  touch "$f"; chown "${USER_NAME}:${USER_NAME}" "$f"
  # Clean out old inline blocks left over from earlier versions.
  if grep -q 'shibuya:tmux-autoattach' "$f"; then
    backup_file "$f"
    tmp="$(mktemp)"
    awk '/# >>> shibuya:tmux-autoattach >>>/{f=1} !f{print} /# <<< shibuya:tmux-autoattach <<</{f=0}' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    chown "${USER_NAME}:${USER_NAME}" "$f"
    ok "old inline block removed from ${rc}"
  fi
  ensure_line "$f" "$SOURCE_LINE" 'shell-tmux.sh' \
    && ok "shell-tmux.sh sourced from ${rc}" || skip "shell-tmux.sh already sourced in ${rc}"
  chown "${USER_NAME}:${USER_NAME}" "$f"
done

# ------------------------------------------------------------- zsh ---------
# Parity with the Mac: zsh there too, so muscle memory carries over.
# No oh-my-zsh — on a weak machine over a mobile link every extra framework
# in shell startup is noticeable.
section "zsh"
apt_install zsh zsh-autosuggestions zsh-syntax-highlighting fzf

write_user_file .zshrc 0644 <<'EOF' || true
# shibuya: a minimal, fast zsh. Heavy frameworks are deliberately absent —
# the shell starts over a mobile link, and every extra 300ms shows.

HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS
setopt AUTO_CD INTERACTIVE_COMMENTS

autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

# Prompt: host + directory + branch. The host matters — it is easy to forget
# you are on the Pi and delete something on the wrong machine.
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats ' %F{yellow}%b%f'
setopt PROMPT_SUBST
PROMPT='%F{cyan}%m%f %F{blue}%~%f${vcs_info_msg_0_} %(?.%F{green}.%F{red})❯%f '

[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ] && \
  source /usr/share/doc/fzf/examples/completion.zsh

# Arrows search history by the prefix already typed — it saves keystrokes,
# and on a phone every keystroke is expensive.
autoload -U up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search

alias ll='ls -alh --color=auto'
alias ls='ls --color=auto'
alias k='kubectl'
alias tf='terraform'
alias g='git'
alias gs='git status -sb'
command -v batcat >/dev/null && alias bat='batcat'
command -v fdfind >/dev/null && alias fd='fdfind'

export EDITOR=vim
export PATH="$HOME/.local/bin:$PATH"

# tmux behaviour (auto-attach + exit guard) lives in the shared file so the
# same logic cannot drift apart between .bashrc and .zshrc.
[ -f /etc/shibuya/shell-tmux.sh ] && . /etc/shibuya/shell-tmux.sh
EOF

if [[ "$(getent passwd "$USER_NAME" | cut -d: -f7)" == "/usr/bin/zsh" ]]; then
  skip "zsh is already the login shell"
else
  chsh -s /usr/bin/zsh "$USER_NAME"
  ok "login shell switched to zsh"
fi

ok "10-mosh-tmux done"
echo
echo "  Connect from the Mac:  mosh -p 60000:60010 ${USER_NAME}@shibuya.local"
