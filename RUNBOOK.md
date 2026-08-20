# shibuya — runbook

Raspberry Pi 5, Ubuntu 24.04 arm64. A working server I reach from my phone over mosh.

## How to connect

| From | Command |
|---|---|
| Mac, at home | `mosh -p 60000:60010 koinoyokan171@shibuya.local` |
| Mac, over Tailscale | `mosh -p 60000:60010 koinoyokan171@shibuya` |
| iPhone (Blink) | profile `shibuya` — Tailscale name, mosh, ports `60000:60010` |
| iPhone, fallback | profile `shibuya-wan` — public IP at my parents' place, forwarded TCP port |

Logging in drops you straight into the tmux session `main`, so work survives a dropped
connection, a phone reboot and a dead battery. The tmux prefix is `C-a`, mouse mode is on
(tap switches pane, swipe scrolls back through history).

## Deploying and making changes

Everything is configured by idempotent scripts. There is no need to touch the system by
hand — edit a script and deploy, and the configuration stays reproducible (moving to an
SSD then comes down to a single run).

```bash
# from the Mac
cd ~/shibuya
./deploy.sh                      # sync only
./deploy.sh --run                # sync and run phase A
./deploy.sh --run --only 20      # a single script
./bootstrap.sh --list            # see what exists

# on the Pi
~/shibuya/verify.sh              # acceptance check
```

Re-running is safe: a script does nothing if the state is already in place. Originals of
every system file touched are kept in `/etc/shibuya/backups/`.

## If access is lost

Cheapest first.

1. **Check which channel is alive.** Tailscale and port forwarding are independent:
   ```bash
   tailscale status              # from the Mac
   nc -vz <public IP> <port>     # port forward
   ```
2. **Did the public IP change?** A Telegram notification is sent when it does. After that
   the forward on my parents' router points nowhere — it needs the new IP, or DDNS.
3. **Tailscale dropped.** Usually an expired node key. Check the
   [admin console](https://login.tailscale.com/admin/machines); key expiry for `shibuya`
   should be **disabled**.
4. **The machine does not answer at all.** Self-healing (`shibuya-netcheck.timer`) restarts
   networking after 15 minutes without connectivity and reboots the machine after 30. The
   watchdog reboots on a kernel hang. So waiting ~30 minutes is a deliberate strategy, not
   doing nothing.
5. **Nothing helped** — call my parents: "pull the power out of the little box, wait ten
   seconds, plug it back in."

### Locked myself out with the firewall

When ufw is enabled the script arms a 10-minute auto-rollback timer. If the connection
drops right after enabling it, just wait — ufw turns itself off. Cancel it by hand once
you have confirmed connectivity:

```bash
sudo systemctl stop shibuya-ufw-rollback.timer
```

### Broke sshd

`20-hardening.sh` validates the config with `sshd -t` before reloading and rolls the
drop-in back if validation fails. It does a `reload`, not a `restart` — existing sessions
survive. If it is broken anyway: get in over Tailscale (a separate channel) and restore
the file from `/etc/shibuya/backups/`.

## If the machine is compromised

Written up front so there is nothing to figure out in the moment. The order matters — cut
access first, investigate afterwards.

```bash
# 1. Remove the machine from the tailnet (from any other device)
#    admin console -> Machines -> shibuya -> Remove

# 2. Revoke cloud credentials
gcloud auth revoke --all
#    + GCP Console -> IAM -> service accounts / user sessions

# 3. Delete the Pi's SSH keys from GitHub
gh ssh-key list        # find 'shibuya-pi (skelar)' and 'shibuya-pi (personal)'
gh ssh-key delete <id>

# 4. Revoke the Claude Code token
#    claude.ai -> Settings -> rotate

# 5. Remove the port forward on my parents' router
```

The keys on the Pi are deliberately **separate** from the Mac's keys — the work laptop is
untouched and rotation stays scoped to one machine.

## Things to know about this machine

- **It boots from an SD card.** A consumable: it degrades with writes and goes read-only
  after a year or two. Logs are capped at 200 MB, swap lives in zram (in RAM) and `noatime`
  is on — but moving to a USB SSD is still a matter of time.
- **Automatic reboot at 04:00** if kernel security updates have landed. tmux sessions die
  with it. That is a deliberate trade: an unpatched kernel on a machine exposed to the
  internet is worse than a lost session, and a regular reboot also proves the machine can
  still boot — while that is still fixable by hand.
- **The `docker` group is equivalent to root.** On a single-user machine that is a
  conscious trade for convenience.
- **The client-context key `pt` is deliberately not on this machine.** If it is ever
  needed: `sudo SHIBUYA_WITH_PT=1 ~/shibuya/bootstrap.sh --only 70`.

## Note for my parents (print this)

> **The "shibuya" box**
>
> A small computer about the size of a cigarette pack. It runs around the clock, it should
> not make noise, and getting warm to the touch is normal.
>
> **Nothing needs to be done.** It runs by itself.
>
> **If Dmytro calls and asks for a reboot:**
> 1. Pull the power cable out of the box
> 2. Count to ten
> 3. Plug it back in
> 4. It comes back online on its own within 2 minutes
>
> **Do not:** switch off the power strip or UPS it is plugged into; unplug the network
> cable; move it somewhere else.
>
> Dmytro's phone: ______________________
