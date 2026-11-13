# ⏰ timesync — VPS Timezone & Time Sync Script

[![Shell CI](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml/badge.svg)](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml) [![Release](https://img.shields.io/github/v/release/brucelau1987cn/timesync?color=blue&label=version)](https://github.com/brucelau1987cn/timesync/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A one-shot script for VPS timezone and system time calibration: auto-detects timezone from public IP, configures the system timezone, and prefers chrony for time synchronization. Supports Debian/Ubuntu, CentOS/RHEL, Alpine, Arch, and other common Linux distributions.

## Quick Reference

| Scenario | Recommended | Notes |
|---|---|---|
| New VPS initialization | `curl … | bash` | One step for timezone + time sync |
| Review before running | Download first | Better for production |
| SSH / CI / cron | Run directly | Non-interactive / no-TTY safe |
| Debian 13 | Run latest version | Handles chrony runtime-dir / stale PID |
| Re-running on an existing VPS | Run latest version | v1.2.6 fixes chrony daemon failure on re-run |
| Running behind TUN / transparent proxy | `bash timesync.sh --egress eth0` | Timezone follows the physical NIC, not the exit node |
| Troubleshooting sync failures | Run diagnostics script | Auto-collects systemctl / journal / permissions |

## Quickstart

```bash
# One-liner (requires root)
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash

# Or download and inspect before running
curl -fsSL -o timesync.sh https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh
bash timesync.sh
```

## TUN / Transparent Proxy (v1.3.0+)

With sing-box / mihomo / clash TUN mode enabled, the default route points at `tun0`, so the detected public IP is the **exit node** and the timezone gets set to the wrong country.

Since v1.3.0 the script lists every interface with its real egress and lets you choose:

```bash
bash timesync.sh --list          # inspect only, no changes
bash timesync.sh --egress eth0   # physical NIC (recommended)
bash timesync.sh --egress tun0   # follow the exit node (explicit choice)
bash timesync.sh --tz Asia/Shanghai   # no network at all
```

Interactive runs show a menu; non-interactive runs (`curl | bash`, cron, panels) default to the **physical NIC** instead of silently using the exit node.

| Flag | Description |
|---|---|
| `--egress auto` | Auto-select (prefer physical NIC, ignore saved choice) |
| `--egress <iface>` | Use the given interface, e.g. `eth0` |
| `--egress <IP>` | Use the interface owning that local IP |
| `--tz <zone>` | Force a timezone, skip all network probing |
| `--list` | List interfaces and egress only |
| `--dry-run` | Print the config that would be written |
| `--yes` | Non-interactive, accept recommendations |

The choice is stored in `/etc/timesync.conf` and reused on later runs.

### How it bypasses the tunnel

1. **Probing**: `curl --interface eth0` uses `SO_BINDTODEVICE`, so the route lookup is restricted to the physical NIC and skips the TUN policy routes.
2. **DNS**: TUN setups often hijack DNS / use fake-ip (`198.18.x.x`). The script resolves names over **DoH to an IP literal** (`1.1.1.1`, falling back to AliDNS `223.5.5.5`) and connects with `--resolve`, never touching the system resolver.
3. **NTP**: with chrony ≥ 4.0 it writes `bindacqdevice eth0` so NTP client sockets are bound to the physical NIC, and NTP hostnames are pre-resolved via DoH to avoid fake-ip.
4. chrony < 4.0 / ntpdate / ntpd cannot bind to a device; the script warns and suggests `--tz` or upgrading chrony.

## Use Cases

- Auto-configure correct timezone and system clock after new VPS provisioning
- Unattended execution in SSH / cloud panels / automation scripts
- Debian 13 and other new distros: auto-fix chrony runtime directory and stale PID issues
- Fallback to HTTP Date header when NTP is unavailable

## Main Features

- 🌐 **Smart timezone detection**: auto-detect geolocation and timezone from public IPv4, with multiple fallback sources.
- 🕳️ **TUN-aware egress selection**: detects tun/wg/sing-box/mihomo interfaces, lets you probe via the physical NIC so the timezone is not taken from the exit node; NTP queries are pinned to the same interface.
- 🕐 **Safe timezone configuration**: prefer `timedatectl`; fall back to `/etc/localtime` symlink with rollback protection.
- 🔧 **Multi-NTP tool support**: prefer chrony, support ntpdate / ntpd as fallbacks; auto-install if missing.
- 🛡️ **Conflict service handling**: auto-stop systemd-timesyncd / ntpd to avoid conflicts.
- ✅ **Debian 13 compatible**: create `/run/chrony`, `/var/lib/chrony`, `/var/log/chrony` with correct ownership; remove stale PID files before starting.
- 🔄 **Re-run safe**: cleans all stale PID/socket files on every run; stops both `chrony` and `chronyd` units; pkill any residual processes; supports both `_chrony` (RHEL) and `chrony` (Debian) users — prevents daemon startup failure on repeated runs.
- 🤖 **Non-interactive safe**: safe wrappers around `clear` / `tput` / `stty`; runs in `curl | bash`, SSH, CI, cron without a TTY.
- 🧪 **CI-guarded**: GitHub Actions runs `bash -n` and ShellCheck on every PR.

## How It Works

0. Select the probing egress (detect TUN, optionally pin a physical NIC).
1. Fetch public IP and detect timezone.
2. Configure system timezone.
3. Detect or install chrony / ntpdate / ntpd.
4. Write sync config and start the time sync service.
5. Wait for chrony daemon to become responsive, then run `chronyc -a makestep`.
6. Display sync sources, tracking status, and final time.

## Non-Interactive Environments

The script is safe in headless / no-TTY environments: SSH remote commands, CI pipelines, cron jobs, automation panels, etc.

```bash
# Recommended: just run it
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash

# If your runner requires TERM, set it explicitly
TERM=xterm bash timesync.sh
```

Internal safe wrappers prevent `clear`, `tput`, `stty`, and interactive prompts from causing early exit.

## Verification Commands

```bash
# Check timezone and NTP status
timedatectl

# Check chrony sync status
chronyc tracking

# List chrony sources
chronyc sources -v

# Force a one-shot sync step
chronyc -a makestep

# View chrony logs
journalctl -u chrony -n 200 --no-pager
```

## Troubleshooting

### `chronyc` reports `506 Cannot talk to daemon`

This means chronyd is not running. Common causes:

- `/run/chrony` missing or incorrect permissions;
- `/var/lib/chrony`, `/var/log/chrony` ownership mismatch;
- Stale `/run/chrony/chronyd.pid` left from a previous run;
- Residual chronyd process from a previous abnormal exit;
- Daemon not yet fully ready after config write.

The script handles all of these automatically: creates directories, fixes `_chrony`/`chrony` ownership, removes all stale PID/socket files, stops both `chrony` and `chronyd` units, pkills residual processes, restarts chrony, waits for daemon readiness, then runs `makestep`. If it still fails, run:

```bash
systemctl status chrony --no-pager -l
journalctl -u chrony -n 200 --no-pager
```

### No output or early exit in SSH / panels / cron

Make sure you're using the latest version (v1.2.4+). Earlier versions could exit early in environments without `TERM` set.

## Diagnostics Script

A ready-to-run diagnostics script is included: `scripts/collect-diagnostics.sh`

```bash
bash scripts/collect-diagnostics.sh
```

Collects:

- OS and kernel info
- chrony systemctl status and journal
- Key directory permissions and process info
- chronyc tracking / sources / activity
- Network and IP info
- Debian package status

## Changelog (excerpt)

- **v1.2.6**: Fix `506 Cannot talk to daemon` on re-run: clean stale PID/socket files, stop both `chrony`/`chronyd` units, pkill residual processes, detect real unit name via `list-unit-files`, use `restart` instead of `start`, support both `_chrony` (RHEL) and `chrony` (Debian) users.
- **v1.2.5**: Add English README, diagnostics script, and quick-reference table.
- **v1.2.4**: Non-interactive hardening; safe wrappers; README cleanup; GitHub Actions CI.
- **v1.2.3**: Fix Debian 13 chrony runtime-dir / stale PID causing `chronyc makestep` failure.
- **v1.2.0**: Fix chrony/ntp install detection, ipinfo JSON parsing, and HTTP fallback robustness.

Full history: [GitHub Releases](https://github.com/brucelau1987cn/timesync/releases)

## Contributing

- PRs for compatibility fixes, new tests, or docs improvements are welcome.
- All PRs run Shell CI automatically: `bash -n timesync.sh` + ShellCheck.

## Security Notice

Do not expose GitHub tokens, server passwords, or private keys in issues, PRs, chats, or commit messages. If exposed, revoke/rotate immediately.

## License

MIT
