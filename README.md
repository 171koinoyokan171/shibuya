# shibuya

Provisioning scripts for **shibuya** — a Raspberry Pi 5 set up as an always-on
personal server: SSH/mosh access from a phone over Tailscale (or a port
forward), with tmux keeping work alive across network changes and app
restarts.

Everything is idempotent shell — re-running `bootstrap.sh` is safe and mostly
silent. The system is never edited by hand; a change means editing a script
in `scripts/` and re-deploying.

## Hardware

- Raspberry Pi 5 (8 GB), Ubuntu 24.04 arm64
- [Argon ONE V3 M.2 NVMe](https://argon40.com/products/argon-one-v3-m-2-nvme-case) case — active cooling, safe-shutdown power button
- SanDisk IX SN530 512 GB (Industrial NVMe) as the boot disk, migrated from the original SD card via `rpi-clone`

## Layout

| Path | What |
|---|---|
| `bootstrap.sh` | Entry point — runs the scripts in `scripts/` on the Pi, in order |
| `deploy.sh` | Run from the Mac: rsyncs this repo to the Pi and optionally triggers `bootstrap.sh` |
| `scripts/` | One idempotent script per concern (base packages, hardening, Tailscale, Docker, cloud CLIs, UPS, the Argon case daemon, ...) |
| `lib/common.sh` | Shared helpers: logging, `apt_install`, `write_file`/`ensure_line` with automatic backups, systemd helpers |
| `verify.sh` | Acceptance checks — run after provisioning to confirm the box actually works |
| `STATUS.md` | Current state, hardware notes, and gotchas — written for picking the project back up in a new session |
| `RUNBOOK.md` | Operational playbook: how to connect, what to do if access is lost, incident response |

## Quick start

```bash
git clone <this repo> ~/shibuya
cd ~/shibuya
sudo ./bootstrap.sh --list       # see what's available
sudo ./bootstrap.sh              # run the default phase
./verify.sh                      # confirm it worked
```

From another machine, `deploy.sh` syncs and (optionally) triggers a remote run:

```bash
./deploy.sh --run                # sync + run the default phase over SSH
./deploy.sh --run --only 20      # sync + run a single script
```

Machine-specific secrets (Wi-Fi passwords, bot tokens, hardware identifiers)
are never committed — they live outside this repo or under the gitignored
`secrets/` directory, generated or filled in per-machine.

## Docs

`STATUS.md` carries the project state and the reasoning behind the hardware
choices; `RUNBOOK.md` is the operational playbook — how to connect, what to do
when access is lost, and the procedure if the machine is ever compromised.
