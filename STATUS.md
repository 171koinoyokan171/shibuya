# shibuya — project status

> A context-handover file for a fresh chat. Current as of **2026-08-06**.
> Operational instructions live next door in `RUNBOOK.md`.

## What this is

A Raspberry Pi 5 (Ubuntu 24.04 arm64, hostname `shibuya`) as an always-reachable
working server: connect from an iPhone through Blink Shell over mosh and do real work
when there is no laptop around — put out production fires, review PRs, run Claude Code.

The machine sits at home for now, but is being prepared to move to my parents' place,
where it will run on a UPS and be reachable through a port forward on their static
public IP.

**The core idea:** two independent access channels (Tailscale + port forwarding), mosh
to survive network changes, tmux to survive everything else.

## Status: phases A and B are closed

`~/shibuya/verify.sh` → **64 passed / 0 warnings / 0 failures**

Verified by actually using it, not by "the package installed fine":

| What | How it was verified |
|---|---|
| mosh from the phone | Blink → mosh → tmux; **switching WiFi→LTE mid-session does not break the session** |
| mosh over Tailscale | connected by the MagicDNS name `shibuya`, proof file written |
| git | cloned `liven-dev/gh-slack-bot` through `github.com-lvn`, identity applied automatically |
| kubectl | 3 GKE clusters respond, including both production ones |
| claude / k9s / docker | `claude -p` answers, k9s starts, `docker run hello-world` passes |
| reboot | ~20 seconds of downtime, everything came back on its own |
| network self-healing | exercised in a sandbox: network restart on the 3rd failure, reboot on the 6th, cooldown holds |
| Telegram | boot notification, 09:00 heartbeat, netcheck every 5 minutes |
| netplan | both SSIDs in wpa_supplicant, eth0 metric 100 / wlan0 600 |

## How to connect

| From | Command |
|---|---|
| Mac, at home | `mosh -p 60000:60010 shibuya-local` |
| Mac, Tailscale | `mosh -p 60000:60010 shibuya` |
| iPhone | Blink → profile `shibuya` (mosh, ports `60000:60010`) |

Logging in lands straight in the tmux session `main`. **To leave: `Ctrl-a` then `d`.**
Typing `exit` in the last window also detaches instead of killing the session (the
interception lives in `/etc/shibuya/shell-tmux.sh`). A real exit is `builtin exit`.

## How to make changes

The system is never touched by hand — edit a script and deploy. Otherwise
reproducibility is lost, and the future SSD migration depends on it.

```bash
cd ~/shibuya
./deploy.sh --run              # sync and run phase A
./deploy.sh --run --only 20    # a single script
./bootstrap.sh --list          # see what exists
ssh shibuya '~/shibuya/verify.sh'
```

Everything is idempotent, re-running is safe. Originals of every system file touched
live in `/etc/shibuya/backups/`. The repository is `~/shibuya` — deliberately outside
`~/lvn` so it does not fall under the Skelar git context.

## What is left

### Before moving the box

- [x] Close the session on tty1
- [ ] **SD card image** — a rollback point. `sudo poweroff`, card into a reader:
      `sudo dd if=/dev/rdiskN bs=4m | gzip > ~/shibuya-$(date +%F).img.gz`
- [ ] **UPS**: if it has a **data** USB port — connect it and run
      `sudo ~/shibuya/bootstrap.sh --only 90` (clean shutdown on low battery plus a
      power-loss alert). If there is no data port, skip it — but an abrupt shutdown
      damages the filesystem on the SD card.
- [ ] Print the note for my parents from `RUNBOOK.md` and fill in the phone number

### On site at my parents' (phase C)

1. Power through the UPS, **Ethernet cable** into the router
2. Check access over Tailscale (there is no port forward yet — this is where it pays off)
3. On the router: a **DHCP reservation** for the eth0 MAC (wlan0 has its own)
4. Port forwarding:
   - **TCP** `<high external port>` → `22`
   - **UDP** `60000-60010` → `60000-60010` — **strictly one-to-one**: mosh-server tells
     the client which port it took, so remapping numbers breaks everything
5. **Acceptance: turn Tailscale off on the phone** and connect over LTE to the public IP.
   Otherwise it is easy to conclude the forward works while traffic goes over the tailnet.
6. Uncomment `Host shibuya-wan` in `~/.ssh/config` on the Mac and create the matching
   profile in Blink

### Phase D — SSD migration: closed 2026-08-11

Done **not** the way originally planned (a clean install) but with `rpi-clone` — a
deliberate choice in favour of speed, and a documented compromise: cloning does not
prove that `bootstrap.sh`/`deploy.sh` can reproduce the system from scratch, so that
remains unconfirmed. Disk: `nvme0n1`, SanDisk IX SN530 512GB — new,
`percentage_used=0%`, `power_on_hours=0` (checked with `nvme smart-log` before cloning).

Sequence: `rpi-clone nvme0n1 -U` → root grew to 476G → `BOOT_ORDER=0xf416`
(NVMe → SD → eMMC) via `rpi-eeprom-config --apply` → reboot → confirmed `findmnt /` =
`/dev/nvme0n1p2`, up in ~12s. The SD card (`mmcblk0`) stayed in the slot untouched as a
fallback — the firmware falls back to it on its own if the NVMe will not boot. Docker's
`data-root` did not need moving separately: the whole root was cloned, so docker landed
on the NVMe along with everything else.

Not done: a clean reinstall was never exercised, so the reproducibility of
`bootstrap.sh` from scratch on this machine is unverified. If a from-zero recovery is
ever needed (SD dead, NVMe dead), it will show up as an unknown rather than a proven path.

### Argon ONE V3: power button and fan — closed 2026-08-11

`scripts/95-argon-case.sh` (optional, not in `PHASE_A`, run with `--only 95`) installs
the official `argon1.sh`. Two traps worth remembering:

- **On Ubuntu (not Raspbian) the vendor script silently skips the EEPROM step**
  (`PSU_MAX_CURRENT=5000`) — it prints "Please run this under Raspberry Pi OS" and
  moves on. `argonone-eepromconfig.py` itself does not check the distribution (only
  `is_pifive`), so our script calls it separately after `argon1.sh` — that is what
  actually gets the EEPROM updated on Ubuntu.
- **`argon1.sh` forces `dtparam=pciex1_gen=3`** in `config.txt` on any Pi 5, without
  asking — exactly what the SSD section below suggests avoiding "if the disk is not
  detected". Verified by rebooting: the NVMe boots fine on Gen3, `argononed` is
  `enabled`+`active`. If the disk ever stops being detected after an update, the first
  thing to check is `pciex1_gen` in `config.txt` (the original backup is in
  `${SHIBUYA_BACKUPS}/_boot_firmware_config.txt.orig`).

Fan/button configuration: `sudo argonone-config`.

## Which SSD to buy

At the time of writing the system was on the SD card (`mmcblk0`, 29 GB, 7.3 GB used =
27%). The card is a consumable: it degrades with writes and goes read-only within a year
or two. Mitigated (logs capped at 200 MB, swap in zram, `noatime`) but not solved.

**Capacity: 512 GB.** Checked against prices (August 2026): 256 GB costs the same as
512 — the cheap Kioxia BG4/BG6 256 GB models are listed as out of stock, and what is
actually available runs 3,850–4,823 UAH against 4,085 UAH for 512. There is nothing to
save by going smaller.

**TLC, not QLC — mandatory.** TLC is 3 bits per cell, roughly 1000–3000 write cycles;
QLC is 4 bits and roughly 300–1000. With logs being written around the clock that is the
difference between "works for five years" and "started acting strange after eighteen
months".

### Shopping list — two items, ~4,400 UAH

**Important about the existing hardware:** the Pi sits in the official Pi 5 case, whose
**fan is built into the lid** (not the Active Cooler — there is no heatsink on the SoC).
The system confirms it: `cooling_fan` spins at 3059 rpm, temperature 56.8 °C. That rules
out the M.2 HAT+ option: the HAT takes the lid's place, and removing the lid means no
cooling at all.

| Item | Model | Price |
|---|---|---|
| Case + cooling + NVMe | **Argon ONE V3 M.2 NVMe** | ~1,900 UAH (used marketplace, seller rated 5.0/5) |
| Disk | **SanDisk IX SN530 512 GB** (`SDBPTPZ-512G-XI`, **2230**) | ~2,500 UAH (used marketplace, different seller, 5.0/5) |

**Pay through the marketplace's escrow, not by card transfer.** The seller offers
2,350 UAH by card instead of 2,500 — but a direct transfer removes the "goods first,
money after" protection, and that protection is exactly what allows returning the disk if
smart-log shows mileage. 150 UAH for the right to return an item of unclear provenance is
cheap.

The disk comes in the **2230** form factor — the Argon ONE V3 board supports
2230/2242/2260/2280, the standoff just has to move to the 2230 position.

**Why Argon ONE V3 and not the NEO 5 (1,500 UAH).** The extra 400 UAH buys a **power
button with a clean shutdown**: my parents can be told "press and hold the button for
three seconds" instead of "pull the cord". An abrupt power cut is the main way to corrupt
the filesystem, and that risk was budgeted for separately. Also: a heatsink on the NVMe
itself, a PWM fan, ports routed to the back, and the disk on a ribbon **inside** the case
(no external cable to knock loose). The button works through Argon's open script —
installed via `scripts/95-argon-case.sh` on 2026-08-11, see above.

**Why this disk.** "IX" marks the **Industrial line**: a −40…+85 °C operating range,
vibration tolerance, and a series designed for around-the-clock duty in embedded systems.
Directly relevant: the box will spend years in a corner with unclear ventilation, and the
Pi already sits at 57 °C. 3D TLC, with endurance far above consumer drives (the 256 GB
version is rated 400 TBW).

PCIe Gen 3 is not a concern — the Pi 5 has a single x1 lane and tops out at ~450–900 MB/s
with any disk.

**Decoding SanDisk SN530 part numbers:** `SDBPTPZ` = 2230, `SDBPNPZ` = 2280. Useful when
buying a different unit — listings often omit the form factor.

**The disk is OEM / pulled stock** (listed as "used" while described as new — normal for
OEM batches without retail packaging; manufacturing dates are recent, January–March 2026).
Two consequences: there may be no retail warranty (ask the seller), and **the mileage must
be checked immediately after installation** — procedure below.

**Nothing else needs buying:** the 27 W power supply (5.1V/5A) is on hand, and the SD card
stays in the slot as emergency media. The current lid-fan case goes into the spares box.

#### How to pick a disk if this one falls through

The frame: **256–500 GB, M.2 2280, NVMe, TLC mandatory.** Check the memory type on the
product page rather than inferring it from the price — the Goodram PX600 500 GB costs
3,966 UAH and is **QLC**, while the Kioxia Exceria G2 500 GB was 1,832 UAH and TLC (out of
stock). **Avoid Kingston NV2/NV3** — they change internals without changing the part
number. No-name brands: the memory type cannot be verified and there is no warranty path.

On TBW, without panic: the journal is capped at 200 MB and docker has limits, so the
machine writes ~1–5 GB a day, i.e. ~2 TB a year. Even 160 TBW is decades. Endurance is not
the binding constraint here; brand predictability and warranty matter more.

If an OEM pull from a laptop turns up (WD SN740 and similar), buy only from a seller who
accepts returns and check the mileage immediately:

```bash
sudo apt install -y nvme-cli
sudo nvme smart-log /dev/nvme0n1 | grep -E 'percentage_used|power_on_hours'
```

On a new drive `percentage_used` = 0% and `power_on_hours` is in single digits. Hundreds
of hours means a pull.

Rejected options: **M.2 HAT+ + Active Cooler** (~5,550 UAH, a board without a case,
incompatible with the existing lid fan); **USB enclosure + SATA SSD** (~3,000–5,300 UAH,
cheaper, but an external cable is a failure point on a machine you cannot reach); and the
**Argon NEO 5 + no-name 512 GB bundle at 6,670 UAH** (the disk works out to ~5,170 UAH,
no-name, unrated seller, listed as "used" under a "NEW" headline).

### Do not overpay for speed

The Pi 5 has a single-lane PCIe x1: Gen2 gives ~450 MB/s, Gen3 (not officially supported,
usually works) ~900 MB/s. The bus is the limit, not the disk — a Gen4 drive adds nothing
over Gen3. Even the lower ~450 MB/s is roughly twenty times faster than the SD card.

If the disk is not detected, leave Gen2 as the default and do not set
`dtparam=pciex1_gen=3` in `/boot/firmware/config.txt`.

### Power — already covered

The official **Raspberry Pi 27 W USB-C (5.1V ⎓ 5.0A, P1724)** is on hand and suitable.
Nothing to buy. An ordinary 5V/3A charger would cause random reboots under load — the
worst class of problem for an unreachable machine.

### After installing the disk

```bash
sudo rpi-eeprom-config --edit    # BOOT_ORDER=0xf416 — NVMe first, then SD
```

**Leave the SD card in the slot** as emergency media: if the NVMe has trouble, the machine
falls back to booting from it.

## Things found along the way (do not repeat)

These cost time and may resurface:

- **The `noble-updates` pocket was missing from apt** — only `noble` and
  `noble-security` were present. apt sat in an unsolvable conflict (`bzip2` vs
  `libbz2-1.0`) and **could install nothing at all**. Fixed by
  `/etc/apt/sources.list.d/shibuya-updates.sources`.
- **mosh and locales.** `update-locale LC_ALL=` writes an *empty* `LC_ALL`, and
  mosh-server refuses to start on it. On top of that macOS sends a non-existent
  `LC_CTYPE=UTF-8`; `AcceptEnv` is an additive directive that a drop-in does not
  override, so the stock line in `sshd_config` had to be commented out.
- **mosh 1.4.0 aborts (SIGABRT) on a zero-size terminal.** This only shows up in headless
  testing via `script -q /dev/null` on macOS. With a real terminal everything works — do
  not waste time chasing the "bug".
- **`cmd | grep -q` under `set -o pipefail` lies on a match**: grep exits first and the
  producer catches SIGPIPE. `lib/common.sh` has `contains()` for this.
- **`write_file` always returns 0**; use `changed()` to detect a change. Returning 1 for
  "no changes" used to kill scripts on the second run.
- The official helm apt repository (`baltocdn.com`) serves an incomplete certificate
  chain — helm is installed as a binary from `get.helm.sh`.
- **`billw2/rpi-clone` (unmaintained since 2020, predating the Pi 5 and NVMe) cannot
  clone to NVMe** — it decides the disk "might be a partition rather than a disk" because
  of the trailing digit in `nvme0n1`, and addresses partitions without the `p` separator
  (`nvme0n11` instead of `nvme0n1p1`). The `framps/rpi-clone` fork (actively maintained)
  fixes exactly this: `dst_part_base` handles `*nvme*` alongside `*mmcblk*`. Use only that one.
- **`rpi-clone` does not rename partition labels on the clone** — after cloning, the SD
  and the NVMe end up with identical `LABEL=writable`/`LABEL=system-boot` (UUIDs do
  differ; mkfs generates them anew). Since `cmdline.txt`/`fstab` resolve root through
  `LABEL=` rather than `PARTUUID=`, having both cards in the system makes the result
  non-deterministic (confirmed: a known issue on the Raspberry Pi forums). Rename them
  before adding the second disk to `BOOT_ORDER`: `fatlabel /dev/nvme0n1p1 nvme-boot`,
  `e2label /dev/nvme0n1p2 nvme-root`, then fix `root=LABEL=` in `cmdline.txt` and both
  lines in `fstab` on the new card.

## Security

The machine holds credentials for three GKE clusters (two of them production) and GitHub
keys, and it will be exposed to the internet through a port forward.

- The Pi's keys (`id_lvn`, `id_gh`) are **separate from the Mac's keys** — they can be
  revoked independently.
- The `pt` client-context key is deliberately **not present**. If it is ever needed:
  `sudo SHIBUYA_WITH_PT=1 ~/shibuya/bootstrap.sh --only 70`
- `gcloud auth application-default login` was **never run** — an ADC token is the most
  valuable thing that could sit on this machine, and a plain `gcloud auth login` is enough.
- The compromise procedure is in `RUNBOOK.md`, section "If the machine is compromised".
  It was written up front, deliberately.

## Where things live

| Path | What |
|---|---|
| `~/shibuya/` (Mac) | git repository with the scripts, `RUNBOOK.md` and this file |
| `~/shibuya/` (Pi) | the same copy, synced by `deploy.sh` |
| `/etc/shibuya/move.env` | parents' WiFi + Telegram token, root:600, **not in git** |
| `/etc/shibuya/backups/` | originals of every system file touched |
| `/etc/shibuya/shell-tmux.sh` | auto-attach and the `exit` interception, sourced from both rc files |
| `~/.ssh/config` (Mac) | the `shibuya:hosts` block with the aliases |
