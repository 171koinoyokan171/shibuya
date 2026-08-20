#!/usr/bin/env bash
# PHASE B (optional): Argon ONE V3 M.2 NVMe — power button and fan.
#
# Installs the vendor's official argon1.sh: the argononed daemon talks to the
# RP2040 on the case board over I2C, drives the fan by temperature and handles
# short/long presses of the power button (safe shutdown).
# Only makes sense with the Argon ONE V3 case (the M.2 NVMe variant for the Pi 5).
#   sudo ~/shibuya/bootstrap.sh --only 95
set -Eeuo pipefail
source "${SHIBUYA_ROOT:?}/lib/common.sh"
require_root
ensure_dirs

CONFIG=/boot/firmware/config.txt

section "Argon ONE V3: installing the vendor script"
# argon1.sh is idempotent itself (Setup/Update modes), but it edits config.txt
# directly with tee -a, bypassing our write_file/backup_file — so back it up here.
backup_file "$CONFIG"

TMP="$(mktemp)"
curl -fsSL https://download.argon40.com/argon1.sh -o "$TMP"
bash "$TMP"
rm -f "$TMP"

section "Argon ONE V3: PSU_MAX_CURRENT in EEPROM"
# argon1.sh only applies this step when CHECKPLATFORM=Raspbian and silently skips
# it on Ubuntu ("EEPROM not updated. Please run under Raspberry Pi
# OS"). The python script itself does not check the distro (only is_pifive),
# so it is run separately to get the EEPROM updated after all.
EEPROMCFG=/etc/argon/argonone-eepromconfig.py
if [[ -f "$EEPROMCFG" ]]; then
  python3 "$EEPROMCFG"
else
  warn "$EEPROMCFG not found — argon1.sh did not run as expected, check the output above"
fi

section "verification"
if systemctl is-active --quiet argononed.service; then
  ok "argononed is active"
else
  warn "argononed is not active — check: journalctl -u argononed -n 30"
fi

echo
warn "argon1.sh enabled dtparam=pciex1_gen 3 and dtparam=nvme in ${CONFIG} —"
warn "a reboot is needed to confirm the NVMe still boots afterwards."
warn "If the disk or boot disappears after the reboot, go back to Gen2: remove the"
warn "pciex1_gen line from ${CONFIG} (the pre-edit original is in ${SHIBUYA_BACKUPS}/)."
echo
echo "Fan/button configuration: sudo argonone-config"
