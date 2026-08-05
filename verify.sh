#!/usr/bin/env bash
# Приёмочная проверка shibuya. Запускать НА Pi:  ~/shibuya/verify.sh
#
# Проверяет то, что можно проверить автоматически. Три вещи проверить
# скриптом нельзя, и они перечислены в конце — это roaming mosh при смене
# сети, работа с телефона и доступ снаружи после переезда.

set -uo pipefail   # без -e: одна упавшая проверка не должна прерывать отчёт

PASS=0; FAIL=0; WARN=0
_g=$'\033[32m'; _r=$'\033[31m'; _y=$'\033[33m'; _b=$'\033[34m'; _0=$'\033[0m'

chk()  { printf '  %s✔%s %s\n' "$_g" "$_0" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s✘%s %s\n' "$_r" "$_0" "$*"; FAIL=$((FAIL+1)); }
soft() { printf '  %s~%s %s\n' "$_y" "$_0" "$*"; WARN=$((WARN+1)); }
head_() { printf '\n%s── %s%s\n' "$_b" "$*" "$_0"; }

# Проверка "вывод содержит шаблон" без пайплайна: `cmd | grep -q` под
# pipefail врёт при совпадении (SIGPIPE у отправителя).
has() { [[ "$1" =~ $2 ]]; }

head_ "система"
if [[ -e /dev/watchdog0 ]] && has "$(systemctl show -p RuntimeWatchdogUSec --value)" '30s|30000000'; then
  chk "hardware watchdog активен (30s)"
else
  soft "watchdog не подтверждён: systemctl show -p RuntimeWatchdogUSec"
fi

SWAP="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null)"
has "$SWAP" 'zram' && chk "zram-swap: ${SWAP//$'\n'/ }" || bad "zram-swap не активен"

has "$(locale 2>&1)" 'en_US.UTF-8' && chk "локаль en_US.UTF-8" || bad "локаль не en_US.UTF-8"
has "$(locale 2>&1)" 'Cannot set' && bad "локаль всё ещё сыплет ошибками" || chk "локаль без ошибок"

JSIZE="$(journalctl --disk-usage 2>/dev/null)"
chk "журнал: ${JSIZE#*take }"

head_ "доступ и защита"
UFW="$(sudo ufw status verbose 2>/dev/null)"
has "$UFW" 'Status: active'        && chk "ufw активен"           || bad "ufw НЕ активен"
has "$UFW" 'deny \(incoming\)'     && chk "по умолчанию deny in"  || bad "политика по умолчанию не deny"
has "$UFW" '22/tcp'                && chk "ufw: ssh разрешён"     || bad "ufw: нет правила на 22"
has "$UFW" '60000:60010/udp'       && chk "ufw: mosh разрешён"    || bad "ufw: нет правила на mosh"
has "$UFW" 'tailscale0'            && chk "ufw: тайлнет доверен"  || soft "ufw: нет правила на tailscale0"

SSHD="$(sudo sshd -T 2>/dev/null)"
has "$SSHD" 'permitrootlogin no'         && chk "root-логин закрыт"        || bad "root-логин открыт"
has "$SSHD" 'passwordauthentication no'  && chk "пароли запрещены"         || bad "разрешён вход по паролю"
has "$SSHD" 'maxauthtries 3'             && chk "maxauthtries 3"           || soft "maxauthtries не 3"
has "$SSHD" 'x11forwarding no'           && chk "x11forwarding выключен"   || soft "x11forwarding включён"
has "$SSHD" "allowusers $(id -un)"       && chk "AllowUsers = $(id -un)"   || bad "AllowUsers не настроен"

if sudo fail2ban-client status sshd >/dev/null 2>&1; then
  chk "fail2ban: jail sshd активен"
else
  bad "fail2ban: jail sshd не работает"
fi

# Слушающие сокеты: наружу должны торчать только ssh и (при активной сессии) mosh.
head_ "открытые порты"
LISTEN="$(sudo ss -tulnH 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\])/ {print $1, $5}' | sort -u)"
echo "$LISTEN" | sed 's/^/    /'
has "$LISTEN" '(0\.0\.0\.0|\*):22' && chk "ssh слушает" || bad "ssh не слушает"

head_ "tailscale"
TS="$(tailscale status --json 2>/dev/null || echo '{}')"
TSBACK="$(printf '%s' "$TS" | jq -r '.BackendState // "нет"')"
if [[ "$TSBACK" == "Running" ]]; then
  chk "в тайлнете: $(tailscale ip -4 2>/dev/null | head -1) ($(printf '%s' "$TS" | jq -r '.Self.DNSName' | sed 's/\.$//'))"
  EXPIRY="$(printf '%s' "$TS" | jq -r '.Self.KeyExpiry // "none"')"
  if [[ "$EXPIRY" == "none" || "$EXPIRY" == "null" ]]; then
    chk "key expiry отключён — нода не выпадет из тайлнета"
  else
    bad "KEY EXPIRY ВКЛЮЧЁН (до ${EXPIRY}) — отключи в admin-консоли, иначе доступ пропадёт"
  fi
else
  bad "tailscale не авторизован (BackendState=${TSBACK})"
fi

head_ "инструменты"
for t in mosh-server tmux zsh git gh docker kubectl gcloud helm k9s node npm rg fdfind batcat nvim direnv jq; do
  command -v "$t" >/dev/null 2>&1 && chk "$t" || bad "$t отсутствует"
done
for t in claude omc uv pulumi; do
  if command -v "$t" >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/$t" ]] || [[ -x "$HOME/.pulumi/bin/$t" ]]; then
    chk "$t"
  else
    bad "$t отсутствует"
  fi
done

head_ "облако"
GACC="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
if [[ -n "$GACC" ]]; then
  chk "gcloud авторизован: ${GACC}"
  CTXS="$(kubectl config get-contexts -o name 2>/dev/null)"
  for c in lvn-prod-gke-cluster lvn-dev-gke-cluster leaply-prod-gke; do
    has "$CTXS" "$c" && chk "контекст ${c}" || soft "нет контекста ${c}"
  done
  while read -r ctx; do
    [[ -z "$ctx" ]] && continue
    if timeout 25 kubectl --context="$ctx" get nodes >/dev/null 2>&1; then
      chk "кластер отвечает: ${ctx##*_}"
    else
      bad "кластер НЕ отвечает: ${ctx##*_}"
    fi
  done <<< "$CTXS"
else
  soft "gcloud не авторизован — kubectl не проверяю"
fi

head_ "git и ключи"
for k in id_lvn id_gh; do
  [[ -f "$HOME/.ssh/${k}" ]] && chk "ключ ${k} на месте" || bad "нет ключа ${k}"
done
has "$(git config --global --get user.useConfigOnly 2>/dev/null)" 'true' \
  && chk "git fail-closed (useConfigOnly)" || bad "useConfigOnly не включён"
# includeIf gitdir срабатывает только ВНУТРИ репозитория, поэтому проверяем
# на одноразовом репо, а не просто в каталоге ~/lvn.
PROBE="$(mktemp -d "$HOME/lvn/.identity-probe-XXXX")"
git -C "$PROBE" init -q 2>/dev/null
IDENT="$(git -C "$PROBE" config --get user.email 2>/dev/null)"
rm -rf "$PROBE"
if [[ "$IDENT" == *"@skelar.tech" ]]; then
  chk "identity в ~/lvn подставляется: ${IDENT}"
else
  bad "includeIf для ~/lvn не работает (получили: '${IDENT:-пусто}')"
fi

for alias_ in github.com-lvn github.com; do
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -T "git@${alias_}" 2>&1)"
  if has "$out" 'successfully authenticated'; then
    chk "GitHub ${alias_}: $(printf '%s' "$out" | sed -n 's/.*Hi \([^!]*\)!.*/\1/p')"
  else
    soft "GitHub ${alias_}: ключ ещё не добавлен в аккаунт"
  fi
done

head_ "docker"
if docker info >/dev/null 2>&1; then
  chk "docker доступен без sudo"
  if timeout 90 docker run --rm hello-world >/dev/null 2>&1; then
    chk "docker run отработал"
  else
    bad "docker run не отработал"
  fi
else
  soft "docker без sudo недоступен — нужен новый логин (группа docker)"
fi

head_ "claude code"
if [[ -x "$HOME/.local/bin/claude" ]]; then
  chk "claude $("$HOME/.local/bin/claude" --version 2>/dev/null)"
else
  bad "claude не установлен"
fi

head_ "устойчивость к перезагрузке"
for unit in ssh tailscaled docker fail2ban zramswap unattended-upgrades; do
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    chk "${unit} стартует при загрузке"
  else
    bad "${unit} НЕ включён в автозапуск"
  fi
done
[[ -f /var/run/reboot-required ]] && soft "требуется перезагрузка (ждут обновления ядра)" \
                                  || chk "перезагрузка не требуется"

printf '\n%s────────────────────────%s\n' "$_b" "$_0"
printf '  %sпройдено: %d%s   %sзамечаний: %d%s   %sпровалено: %d%s\n' \
  "$_g" "$PASS" "$_0" "$_y" "$WARN" "$_0" "$_r" "$FAIL" "$_0"

cat <<'EOF'

  Скриптом проверить нельзя — это делается руками:

  1. Зайти с iPhone через Blink по mosh и убедиться, что попадаешь
     сразу в tmux-сессию 'main'.
  2. ГЛАВНЫЙ ТЕСТ: посреди сессии переключить телефон с WiFi на LTE.
     Сессия должна молча продолжиться с того же места — ради этого
     всё и затевалось.
  3. Заблокировать телефон на 15+ минут и вернуться — работа на месте.
  4. После переезда: выключить Tailscale на телефоне и подключиться
     по LTE на белый IP родителей. Иначе легко обмануть себя, думая,
     что проброс работает, когда трафик на самом деле идёт по тайлнету.
EOF

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
