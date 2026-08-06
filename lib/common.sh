#!/usr/bin/env bash
# Общие хелперы для всех скриптов shibuya.
# Подключается через: source "$(dirname "$0")/../lib/common.sh"
#
# Главный принцип: каждая функция идемпотентна и ничего не делает, если
# нужное состояние уже достигнуто. Прогон bootstrap.sh второй раз должен
# быть безопасным и почти бесшумным.

set -Eeuo pipefail

SHIBUYA_ETC="/etc/shibuya"
SHIBUYA_BACKUPS="${SHIBUYA_ETC}/backups"
SHIBUYA_STATE="${SHIBUYA_ETC}/state"

# ---------------------------------------------------------------- вывод ----

_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_green=$'\033[32m'
_c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_dim=$'\033[2m'

log()   { printf '%s==>%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
skip()  { printf '%s  --%s %s\n' "$_c_dim"    "$_c_reset" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()   { printf '%sFAIL%s %s\n' "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

# Печатает заголовок секции — чтобы в длинном выводе bootstrap было видно,
# какой скрипт сейчас работает.
section() {
  printf '\n%s%s%s\n' "$_c_blue" "────── $* ──────" "$_c_reset"
}

on_error() {
  local rc=$? line=${1:-?}
  printf '%sFAIL%s строка %s, код %s\n' "$_c_red" "$_c_reset" "$line" "$rc" >&2
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------- guards ---

require_root() {
  [[ $EUID -eq 0 ]] || die "нужен root: запускай через sudo"
}

require_not_root() {
  [[ $EUID -ne 0 ]] || die "этот скрипт должен работать от обычного пользователя, не от root"
}

# Пользователь, для которого настраиваем окружение. Скрипты запускаются
# через sudo, поэтому $USER там root — берём реального через SUDO_USER.
target_user() {
  echo "${SUDO_USER:-${SHIBUYA_USER:-$(id -un)}}"
}

target_home() {
  getent passwd "$(target_user)" | cut -d: -f6
}

# Выполнить команду от имени целевого пользователя (а не от root).
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

# Ставит пакеты, которых ещё нет. Возвращает 0 всегда, если всё встало.
apt_install() {
  local missing=()
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' \
      || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    skip "пакеты уже стоят: $*"
    return 0
  fi
  apt_update_once
  log "apt install: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
  ok "установлено: ${missing[*]}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Проверка "вывод содержит шаблон" БЕЗ пайплайна.
#
# Так делать нельзя:  cmd | grep -q pat
# Потому что grep выходит по первому совпадению, cmd ловит SIGPIPE и с
# `set -o pipefail` весь пайплайн становится неуспешным — то есть проверка
# врёт ровно тогда, когда совпадение НАЙДЕНО. Ловится тяжело: скрипт ругается
# на корректно применённые настройки.
contains() {
  local haystack="$1" pattern="$2"
  [[ "$haystack" =~ $pattern ]]
}

# ---------------------------------------------------------------- файлы ----

# Копия системного файла перед первой правкой. Копия делается ОДИН раз —
# чтобы повторный прогон не затёр оригинал уже изменённой версией.
backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  ensure_dirs
  local dst="${SHIBUYA_BACKUPS}/${src//\//_}.orig"
  if [[ ! -f "$dst" ]]; then
    cp -a "$src" "$dst"
    ok "бэкап оригинала: $dst"
  fi
}

# Признак "последняя write_file/ensure_line/ensure_block что-то изменила".
#
# Раньше эти функции сообщали об этом кодом возврата 1 = "без изменений".
# Под `set -e` это оказалось миной: любой вызов, не обёрнутый в `if` или
# `|| true`, ронял скрипт на ВТОРОМ прогоне — то есть ровно тогда, когда
# идемпотентность должна была работать. Забыть обёртку слишком легко
# (забыл в 12 местах из 14). Теперь функции всегда возвращают 0, а признак
# изменения читается через changed().
SHIBUYA_CHANGED=0

# Изменил ли последний вызов write_file/ensure_line/ensure_block файл?
#   write_file /etc/foo.conf <<EOF ... EOF
#   if changed; then systemctl restart foo; fi
changed() { [[ "${SHIBUYA_CHANGED:-0}" == "1" ]]; }

# Записать файл с нужным содержимым и правами. Если содержимое уже такое —
# ничего не делает (чтобы не дёргать лишние рестарты). Всегда возвращает 0;
# факт изменения — через changed().
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root:root}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    chmod "$mode" "$path"; chown "$owner" "$path"
    skip "без изменений: $path"
    SHIBUYA_CHANGED=0
    return 0
  fi
  backup_file "$path"
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
  rm -f "$tmp"
  ok "записан: $path"
  SHIBUYA_CHANGED=1
  return 0
}

# Файл в домашнем каталоге целевого пользователя.
write_user_file() {
  local rel="$1" mode="${2:-0644}"
  local home; home="$(target_home)"
  local u; u="$(target_user)"
  write_file "${home}/${rel}" "$mode" "${u}:${u}"
}

# Гарантирует наличие строки в файле (по якорю для поиска дубля).
# Всегда возвращает 0; факт добавления — через changed().
ensure_line() {
  local file="$1" line="$2" match="${3:-$2}"
  touch "$file"
  if grep -qF -- "$match" "$file" 2>/dev/null; then
    skip "строка уже есть в $file"
    SHIBUYA_CHANGED=0
    return 0
  fi
  backup_file "$file"
  printf '%s\n' "$line" >> "$file"
  ok "добавлено в $file: $line"
  SHIBUYA_CHANGED=1
  return 0
}

# Управляемый блок в чужом конфиге — по образцу вашей work-isolation схемы
# в ~/.ssh/config. Позволяет переписывать свой кусок, не трогая остальное.
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
      skip "блок ${tag} без изменений: $file"
      SHIBUYA_CHANGED=0
      return 0
    fi
    backup_file "$file"
    local tmp; tmp="$(mktemp)"
    awk -v s="$start" -v e="$end" '$0==s{f=1;next} $0==e{f=0;next} !f{print}' "$file" > "$tmp"
    printf '%s\n' "$new" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    ok "блок ${tag} обновлён: $file"
  else
    backup_file "$file"
    printf '\n%s\n' "$new" >> "$file"
    ok "блок ${tag} добавлен: $file"
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
    skip "$unit уже enabled+active"
    return 0
  fi
  systemctl enable --now "$unit"
  ok "$unit enabled+active"
}

# ------------------------------------------------------------ apt repos ----

# Добавляет сторонний apt-репозиторий с ключом в правильном (не deprecated)
# формате: ключ в /etc/apt/keyrings, signed-by в .list.
add_apt_repo() {
  local name="$1" key_url="$2" repo_line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"

  install -d -m 0755 /etc/apt/keyrings

  if [[ ! -s "$keyring" ]]; then
    log "ключ репозитория ${name}"
    curl -fsSL "$key_url" | gpg --dearmor -o "$keyring"
    chmod 0644 "$keyring"
    _apt_updated=0
  fi

  local line="deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] ${repo_line}"
  if [[ -f "$list" ]] && grep -qF "$line" "$list"; then
    skip "репозиторий ${name} уже настроен"
  else
    printf '%s\n' "$line" > "$list"
    ok "репозиторий ${name} добавлен"
    _apt_updated=0
  fi
}

# ------------------------------------------------------------ маркеры ------

# Для шагов, которые нельзя проверить дешёвой командой (например, разовые
# миграции) — файл-маркер в /etc/shibuya/state.
step_done() { ensure_dirs; [[ -f "${SHIBUYA_STATE}/$1" ]]; }
mark_done() { ensure_dirs; touch "${SHIBUYA_STATE}/$1"; }
