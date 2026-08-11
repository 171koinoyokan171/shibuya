#!/usr/bin/env bash
# ФАЗА B (опционально): Argon ONE V3 M.2 NVMe — кнопка питания и вентилятор.
#
# Ставит официальный вендорский скрипт argon1.sh: демон argononed опрашивает
# RP2040 на плате корпуса по I2C, управляет вентилятором по температуре и
# обрабатывает короткое/долгое нажатие кнопки питания (safe shutdown).
# Имеет смысл только с корпусом Argon ONE V3 (M.2 NVMe вариант для Pi 5).
#   sudo ~/shibuya/bootstrap.sh --only 95
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

CONFIG=/boot/firmware/config.txt

section "Argon ONE V3: установка вендорского скрипта"
# argon1.sh сам идемпотентен (Setup/Update режимы), но правит config.txt
# напрямую через tee -a, в обход наших write_file/backup_file — бэкапим сами.
backup_file "$CONFIG"

TMP="$(mktemp)"
curl -fsSL https://download.argon40.com/argon1.sh -o "$TMP"
bash "$TMP"
rm -f "$TMP"

section "Argon ONE V3: PSU_MAX_CURRENT в EEPROM"
# argon1.sh применяет этот шаг только когда CHECKPLATFORM=Raspbian и на Ubuntu
# молча пропускает его ("EEPROM not updated. Please run under Raspberry Pi
# OS"). Сам python-скрипт дистрибутив не проверяет (смотрит только is_pifive),
# так что запускаем его отдельно, чтобы EEPROM всё же обновился.
EEPROMCFG=/etc/argon/argonone-eepromconfig.py
if [[ -f "$EEPROMCFG" ]]; then
  python3 "$EEPROMCFG"
else
  warn "не нашёл $EEPROMCFG — argon1.sh прошёл не так, как ожидалось, проверь вывод выше"
fi

section "проверка"
if systemctl is-active --quiet argononed.service; then
  ok "argononed активен"
else
  warn "argononed не активен — проверь: journalctl -u argononed -n 30"
fi

echo
warn "argon1.sh включил dtparam=pciex1_gen 3 и dtparam=nvme в ${CONFIG} —"
warn "нужен ребут, чтобы проверить, что NVMe после этого всё ещё грузится."
warn "Если после ребута диск/загрузка пропали — вернуть Gen2: убрать строку"
warn "pciex1_gen из ${CONFIG} (оригинал до правки лежит в ${SHIBUYA_BACKUPS}/)."
echo
echo "Конфигурация вентилятора/кнопки: sudo argonone-config"
