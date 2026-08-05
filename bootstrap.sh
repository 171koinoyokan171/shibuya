#!/usr/bin/env bash
# shibuya bootstrap — раскатка Raspberry Pi 5 в рабочий сервер для работы с телефона.
#
# Запускать НА Pi:
#   sudo ~/shibuya/bootstrap.sh                 # все скрипты фазы A по порядку
#   sudo ~/shibuya/bootstrap.sh --only 20       # только 20-hardening.sh
#   sudo ~/shibuya/bootstrap.sh --skip 60,90    # всё, кроме docker и ups
#   sudo ~/shibuya/bootstrap.sh --list          # что вообще есть
#
# Всё идемпотентно: повторный прогон безопасен и почти бесшумен.
# Скрипты 80/90 в дефолтный набор НЕ входят — это фаза B (подготовка к переезду),
# их запускают отдельно и осознанно: sudo ./bootstrap.sh --only 80

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/lib/common.sh"

# Фаза A — то, что делается дома, пока Pi под рукой.
PHASE_A=(00-base 10-mosh-tmux 20-hardening 30-tailscale 40-devtools 50-cloud 60-docker 70-identity)

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_scripts() {
  log "доступные скрипты:"
  local f
  for f in "${ROOT}"/scripts/*.sh; do
    local base; base="$(basename "$f" .sh)"
    local desc; desc="$(sed -n '2s/^# \{0,1\}//p' "$f")"
    local mark="  "
    [[ " ${PHASE_A[*]} " == *" ${base} "* ]] && mark="A "
    printf '  %s %-16s %s\n' "$mark" "$base" "$desc"
  done
  echo
  echo "  A = входит в дефолтный прогон (фаза A). Остальное — вручную через --only."
}

ONLY=""; SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --skip) SKIP="$2"; shift 2 ;;
    --list) list_scripts; exit 0 ;;
    -h|--help) usage 0 ;;
    *) warn "неизвестный аргумент: $1"; usage 1 ;;
  esac
done

require_root
ensure_dirs

# Целевой пользователь должен быть настоящим, не root — иначе конфиги
# уедут в /root и на телефоне ничего не появится.
TU="$(target_user)"
[[ "$TU" != "root" ]] || die "запускай через sudo от обычного пользователя, а не из root-шелла"
log "целевой пользователь: ${TU} ($(target_home))"

# Отбираем скрипты к запуску.
selected=()
if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra want <<< "$ONLY"
  for w in "${want[@]}"; do
    w="${w// /}"
    matches=("${ROOT}"/scripts/"${w}"*.sh)
    [[ -e "${matches[0]}" ]] || die "не нашёл скрипт по префиксу '${w}'"
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

[[ ${#selected[@]} -gt 0 ]] || die "нечего запускать"

log "к запуску: ${selected[*]}"

started_at="$(date -Is)"
failed=()

for name in "${selected[@]}"; do
  script="${ROOT}/scripts/${name}.sh"
  [[ -f "$script" ]] || die "нет файла: $script"
  section "$name"
  # Не роняем весь прогон из-за одного скрипта: остальные шаги независимы,
  # а список упавших печатается в конце.
  if SHIBUYA_ROOT="$ROOT" SHIBUYA_USER="$TU" bash "$script"; then
    ok "$name завершён"
  else
    rc=$?
    warn "$name упал (код $rc) — продолжаю остальные"
    failed+=("$name")
  fi
done

section "итог"
echo "начато:   $started_at"
echo "закончено: $(date -Is)"
if [[ ${#failed[@]} -gt 0 ]]; then
  warn "упали: ${failed[*]}"
  echo
  echo "Разбирай по одному:  sudo ${ROOT}/bootstrap.sh --only ${failed[0]%%-*}"
  exit 1
fi

ok "все шаги прошли"
echo
echo "Дальше:"
echo "  1. Интерактивные логины (их нельзя автоматизировать):"
echo "       sudo tailscale up --hostname=shibuya      # и ОТКЛЮЧИТЬ key expiry в admin-консоли"
echo "       gcloud auth login --no-launch-browser"
echo "       gh auth login"
echo "       claude   # вставить OAuth-URL"
echo "  2. Проверка:  ${ROOT}/verify.sh"
