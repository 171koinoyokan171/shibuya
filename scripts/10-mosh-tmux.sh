#!/usr/bin/env bash
# Транспорт и UX под телефон: mosh, tmux с авто-attach, zsh, комфортный шелл.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# ------------------------------------------------------------- mosh --------
# mosh отказывается стартовать без UTF-8 локали — поэтому 00-base должен
# отработать раньше. ncurses-term нужен ради терминфо tmux-256color.
section "mosh"
apt_install mosh ncurses-term
ok "$(mosh-server --version 2>&1 | head -1)"

# Диапазон UDP-портов фиксируем на 60000-60010 вместо дефолтных 60000-61000:
# на роутере родителей придётся пробрасывать ровно эти порты один-в-один,
# и пробрасывать тысячу вместо десяти — незачем.
# Это флаг КЛИЕНТА (mosh -p 60000:60010), на сервере ничего не настраивается,
# но записываем в state, чтобы ufw и документация брали число из одного места.
write_file "${SHIBUYA_ETC}/mosh-ports" 0644 <<'EOF' || true
60000:60010
EOF

# ------------------------------------------------------------- tmux --------
# tmux — второй слой живучести. mosh держит СВЯЗЬ, tmux держит РАБОТУ:
# переживает и смерть mosh-server, и ребут телефона, и разрядку батареи.
section "tmux"
apt_install tmux

install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "${USER_HOME}/.config"

write_user_file .tmux.conf 0644 <<'EOF' || true
# shibuya: tmux под экран телефона и клавиатуру Blink Shell.

# C-a вместо C-b: на key bar в Blink Ctrl достаётся одним нажатием,
# а 'a' ближе к левому краю, чем 'b'.
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# Главный выигрыш на телефоне: тап переключает панель, скролл пальцем
# листает историю, границы панелей тянутся пальцем.
set -g mouse on

# True color в Blink.
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:Tc"

set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g focus-events on
set -g display-time 2000

# Если к одной сессии подключены телефон и ноут — не ужимать всё до размера
# самого маленького экрана, а подгонять под активного клиента.
setw -g aggressive-resize on

# Копирование в vi-стиле: на телефоне без мышки это единственный вменяемый путь.
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-selection-and-cancel

# Сплиты в текущем каталоге, мнемоника | и -
bind '|' split-window -h -c "#{pane_current_path}"
bind '-' split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# Перезагрузить конфиг, не выходя из сессии.
bind r source-file ~/.tmux.conf \; display "tmux.conf перечитан"

# Статус-бар компактный: на 390 пикселях ширины лишнему места нет.
# Температура и нагрузка — потому что это Pi под нагрузкой на SD-карте,
# и знать, что он троттлит, полезно до того, как всё встанет.
set -g status-interval 10
set -g status-style "bg=colour236,fg=colour250"
set -g status-left "#[bg=colour24,fg=colour255,bold] #S #[default] "
set -g status-left-length 20
set -g status-right "#[fg=colour244]#(cut -d' ' -f1 /proc/loadavg) #(awk '{printf \"%.0f°\", $1/1000}' /sys/class/thermal/thermal_zone0/temp) #[fg=colour250]%H:%M "
set -g status-right-length 40
setw -g window-status-current-style "bg=colour24,fg=colour255"
setw -g window-status-format " #I:#W "
setw -g window-status-current-format " #I:#W "
EOF

# ------------------------------------------------------- авто-attach -------
# При интерактивном входе по SSH/mosh сразу попадаем в постоянную сессию
# 'main'. `new -A` = attach, если есть, иначе создать.
#
# Осознанно НЕ используем exec: если tmux по какой-то причине не стартует,
# exec уронил бы соединение и мы бы потеряли доступ к машине. Так же
# осознанно проверяем $TMUX (не вложиться в самих себя) и интерактивность
# (иначе сломается scp/rsync/git-over-ssh).
section "авто-attach в tmux"
ATTACH_SNIPPET='
# >>> shibuya:tmux-autoattach >>>
# Вход по SSH/mosh -> сразу в постоянную сессию. Работа переживает разрыв связи.
if [ -z "${TMUX:-}" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && command -v tmux >/dev/null 2>&1; then
    tmux new-session -A -s main
fi
# <<< shibuya:tmux-autoattach <<<'

for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  touch "$f"; chown "${USER_NAME}:${USER_NAME}" "$f"
  if grep -q 'shibuya:tmux-autoattach' "$f"; then
    skip "авто-attach уже в ${rc}"
  else
    backup_file "$f"
    printf '%s\n' "$ATTACH_SNIPPET" >> "$f"
    ok "авто-attach добавлен в ${rc}"
  fi
done

# ------------------------------------------------------------- zsh ---------
# Паритет с Маком: там zsh, мышечная память должна работать одинаково.
# Без oh-my-zsh — на слабой машине через мобильный канал каждый лишний
# фреймворк в старте шелла ощущается.
section "zsh"
apt_install zsh zsh-autosuggestions zsh-syntax-highlighting fzf

write_user_file .zshrc 0644 <<'EOF' || true
# shibuya: минимальный быстрый zsh. Тяжёлых фреймворков намеренно нет —
# шелл стартует через мобильный канал, каждые лишние 300мс заметны.

HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS
setopt AUTO_CD INTERACTIVE_COMMENTS

autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

# Промпт: хост + каталог + ветка. Хост важен — легко забыть, что ты на Pi
# и, например, снести что-то не на той машине.
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

# Стрелки листают историю по уже набранному префиксу — экономит нажатия,
# а на телефоне каждое нажатие дорогое.
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

# >>> shibuya:tmux-autoattach >>>
if [ -z "${TMUX:-}" ] && [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ] && command -v tmux >/dev/null 2>&1; then
    tmux new-session -A -s main
fi
# <<< shibuya:tmux-autoattach <<<
EOF

if [[ "$(getent passwd "$USER_NAME" | cut -d: -f7)" == "/usr/bin/zsh" ]]; then
  skip "zsh уже логин-шелл"
else
  chsh -s /usr/bin/zsh "$USER_NAME"
  ok "логин-шелл переключён на zsh"
fi

ok "10-mosh-tmux готов"
echo
echo "  Подключение с Мака:  mosh -p 60000:60010 ${USER_NAME}@shibuya.local"
