#!/usr/bin/env bash
# Два профиля Claude Code (личный + рабочий) и синхронизация сессий через claude-sync.
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

USER_NAME="$(target_user)"
USER_HOME="$(target_home)"

# Claude Code сам ставится в 40-devtools. Здесь — только то, что сверху:
# второй профиль и синхронизация с Маком.

# --------------------------------------------------------- claude-sync ----
# Синхронизирует ~/.claude между Маком и Pi через Cloudflare R2 с age-шифрованием.
section "claude-sync"
if as_user test -x "${USER_HOME}/.local/bin/claude-sync"; then
  skip "claude-sync уже стоит: $(as_user "${USER_HOME}/.local/bin/claude-sync" --version 2>/dev/null || echo '?')"
else
  as_user npm install -g @tawandotorg/claude-sync >/dev/null 2>&1 \
    && ok "claude-sync установлен: $(as_user "${USER_HOME}/.local/bin/claude-sync" --version 2>/dev/null || echo '?')" \
    || warn "claude-sync не установился — поставь вручную: npm i -g @tawandotorg/claude-sync"
fi

# ------------------------------------------------------------ профили -----
# Личный аккаунт живёт в дефолтном ~/.claude, рабочий — в отдельном
# ~/.claude-work через CLAUDE_CONFIG_DIR. Каждый профиль держит свои
# .credentials.json и .claude.json, поэтому логины не выбивают друг друга.
section "профили Claude Code"
for d in "${USER_HOME}/.claude-work" "${USER_HOME}/.claude-sync-work"; do
  if [[ -d "$d" ]]; then
    skip "уже есть: ${d#$USER_HOME/}"
  else
    install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$d"
    ok "создан: ${d#$USER_HOME/}"
  fi
done

# claude-sync читает ТОЛЬКО $HOME/.claude — про CLAUDE_CONFIG_DIR он не знает
# (config.ClaudeDirE() смотрит лишь os.UserHomeDir()). Поэтому рабочий профиль
# синхронизируем через подменённый HOME, где .claude — симлинк на ~/.claude-work.
# Заодно туда же уезжает и собственный конфиг claude-sync, что и нужно:
# у каждого профиля свой бакет и своё состояние.
SHIM="${USER_HOME}/.claude-sync-work/.claude"
if [[ "$(readlink -f "$SHIM" 2>/dev/null)" == "${USER_HOME}/.claude-work" ]]; then
  skip "shim уже указывает на ~/.claude-work"
else
  ln -sfn "${USER_HOME}/.claude-work" "$SHIM"
  chown -h "${USER_NAME}:${USER_NAME}" "$SHIM"
  ok "shim: ~/.claude-sync-work/.claude -> ~/.claude-work"
fi

install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "${USER_HOME}/.claude-sync"

# ------------------------------------------------------------ алиасы ------
# Блок кладём в конец rc-файла, в отличие от direnv-хука из 40-devtools.
# Здесь это безопасно: tmux запускается БЕЗ exec, поэтому внутренний шелл
# (тот, в котором реально работают) перечитывает .zshrc уже с выставленным
# $TMUX, пропускает авто-attach и доходит до конца файла.
section "алиасы профилей"

# Одноразовая уборка: раньше блок добавлялся руками под другим маркером.
for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  [[ -f "$f" ]] || continue
  if grep -q '# >>> claude-code:multi-account >>>' "$f"; then
    tmp="$(mktemp)"
    awk '/# >>> claude-code:multi-account >>>/{f=1} !f{print} /# <<< claude-code:multi-account <<</{f=0}' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    chown "${USER_NAME}:${USER_NAME}" "$f"
    ok "убран старый ручной блок из ${rc}"
  fi
done

for rc in .bashrc .zshrc; do
  f="${USER_HOME}/${rc}"
  [[ -f "$f" ]] || continue
  ensure_block "$f" claude-profiles <<'EOF'
# Личный аккаунт — дефолтный профиль (~/.claude + ~/.claude.json).
# Важно: именно unset переменной, а не CLAUDE_CONFIG_DIR=$HOME/.claude —
# это два РАЗНЫХ профиля (дефолт держит .claude.json в корне $HOME).
alias cc-personal='env -u CLAUDE_CONFIG_DIR claude'
alias cc-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'
alias cc-which='echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude (default/personal)}"'

# claude-sync: личный профиль — как есть, рабочий — через подменённый HOME.
alias cs-personal='claude-sync'
alias cs-work='HOME="$HOME/.claude-sync-work" claude-sync'
alias cs-pull-all='claude-sync pull && HOME="$HOME/.claude-sync-work" claude-sync pull'
alias cs-push-all='claude-sync push && HOME="$HOME/.claude-sync-work" claude-sync push'
EOF
  chown "${USER_NAME}:${USER_NAME}" "$f"
done

# ------------------------------------------------------------- конфиг -----
# Креды R2 и age-ключ намеренно НЕ лежат в репозитории и не едут через
# deploy.sh (в .gitignore и в --exclude). Их переносят с Мака руками, один раз.
#
# encryption_key_path в config.yaml хранится АБСОЛЮТНЫМ, поэтому скопированный
# с Мака конфиг ищет ключ по macOS-пути и падает на расшифровке. Чиним здесь,
# чтобы это не всплывало каждый раз после переноса.
section "конфиг claude-sync"

fix_key_path() {
  local dir="$1" label="$2"
  local cfg="${dir}/config.yaml" key="${dir}/age-key.txt"
  if [[ ! -f "$cfg" ]]; then
    warn "${label}: нет config.yaml — перенеси с Мака (см. итог ниже)"
    return 0
  fi
  local want="encryption_key_path: ${key}"
  if grep -qF "$want" "$cfg"; then
    skip "${label}: путь к ключу корректный"
  else
    backup_file "$cfg"
    sed -i "s|^encryption_key_path: .*|${want}|" "$cfg"
    ok "${label}: путь к ключу исправлен на локальный"
  fi
  [[ -f "$key" ]] || warn "${label}: нет age-key.txt — перенеси с Мака"
  chmod 600 "$cfg" "$key" 2>/dev/null || true
  chown "${USER_NAME}:${USER_NAME}" "$cfg" "$key" 2>/dev/null || true
}

fix_key_path "${USER_HOME}/.claude-sync"                    "личный"
fix_key_path "${USER_HOME}/.claude-sync-work/.claude-sync"  "рабочий"

# -------------------------------------------------------- авто-синк -------
# Хуки Claude Code: pull на старте сессии, push на завершении. Живут в
# settings.json каждого профиля — а он исключён из синхронизации, поэтому
# ставятся локально на каждой машине и друг другу не мешают.
#
# Рабочему профилю нужен префикс HOME=. Хук запускается подпроцессом Claude
# Code и наследует обычный $HOME, а cc-work меняет только CLAUDE_CONFIG_DIR —
# без префикса хук синхронизировал бы ЛИЧНЫЙ бакет во время работы в
# корпоративном профиле.
section "авто-синхронизация"
CS="${USER_HOME}/.local/bin/claude-sync"

if [[ -x "$CS" ]]; then
  as_user "$CS" auto enable 2>&1 | sed 's/^/  /' || warn "личный: auto enable не прошёл"

  # Для рабочего профиля `auto enable` НЕ используем: он ищет точную строку
  # "claude-sync pull -q", нашу версию с HOME-префиксом не узнаёт и на каждом
  # прогоне дописывает ещё одну пару хуков. Выставляем состояние сами —
  # выкидываем все claude-sync-хуки и кладём ровно одну правильную пару.
  WORK_SETTINGS="${USER_HOME}/.claude-work/settings.json"
  if [[ -L "${USER_HOME}/.claude-sync-work/.claude" && -f "$WORK_SETTINGS" ]]; then
    as_user node -e '
      const fs=require("fs"), p=process.argv[1];
      const j=JSON.parse(fs.readFileSync(p,"utf8"));
      const want={ SessionStart: `HOME="$HOME/.claude-sync-work" claude-sync pull -q`,
                   Stop:         `HOME="$HOME/.claude-sync-work" claude-sync push -q` };
      j.hooks = j.hooks || {};
      let changed=false;
      for (const ev of Object.keys(want)) {
        // Снимок ДО любых мутаций — иначе сравнение всегда даёт "изменилось"
        // и скрипт врёт про идемпотентность на каждом прогоне.
        const before = JSON.stringify(j.hooks[ev] || []);
        const groups = JSON.parse(before);
        // убираем ВСЕ существующие claude-sync хуки этого события
        for (const g of groups) g.hooks = (g.hooks||[]).filter(h => !String(h.command||"").includes("claude-sync"));
        const kept = groups.filter(g => (g.hooks||[]).length > 0);
        kept.push({ matcher:"", hooks:[{ type:"command", command: want[ev] }] });
        if (JSON.stringify(kept) !== before) { j.hooks[ev] = kept; changed = true; }
      }
      if (changed) { fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n"); console.log("хуки рабочего профиля выставлены"); }
      else console.log("хуки рабочего профиля уже верные");
    ' "$WORK_SETTINGS" | sed 's/^/  ok /'
  fi
else
  warn "claude-sync не найден — авто-синк пропущен"
fi

# Учти: `claude-sync auto status` для РАБОЧЕГО профиля всегда пишет
# "not installed" — он ищет точную строку "claude-sync pull -q", а у нас
# она с префиксом. Хук при этом рабочий; проверять надо в settings.json.

ok "45-claude-sync готов"
echo
echo "  Ручные шаги (автоматизировать нельзя):"
echo "    1. Креды claude-sync — с Мака, по одному разу на профиль:"
echo "         scp ~/.claude-sync/config.yaml ~/.claude-sync/age-key.txt \\"
echo "             shibuya:~/.claude-sync/"
echo "         scp ~/.claude-sync-work/.claude-sync/{config.yaml,age-key.txt} \\"
echo "             shibuya:~/.claude-sync-work/.claude-sync/"
echo "       затем ещё раз: sudo ~/shibuya/bootstrap.sh --only 45  (починит путь к ключу)"
echo "    2. Логины (нужен браузер):"
echo "         cc-personal   # /login под личным аккаунтом"
echo "         cc-work       # /login под рабочим"
echo "    3. Первая синхронизация:  cs-pull-all"
