# ⏰ timesync — VPS timezone and time synchronization script

[![Shell CI](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml/badge.svg)](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml) [![Release](https://img.shields.io/github/v/release/brucelau1987cn/timesync?color=blue&label=version)](https://github.com/brucelau1987cn/timesync/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A one-shot script for VPS timezone and system time calibration: it auto-detects timezone from public IP, configures the system timezone, and prefers chrony for time synchronization. Supports Debian/Ubuntu, CentOS/RHEL, Alpine, Arch, and other common Linux distributions.

Quickstart

```bash
# One-liner (requires root)
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash

# Or download and inspect before running
curl -fsSL -o timesync.sh https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh
bash timesync.sh
```

Use cases

- Initializing a new VPS: set correct timezone and system clock
- Unattended execution in SSH/automation/CI
- Debian 13: automatically fix chrony runtime-dir and stale PID issues
- Fallback to HTTP Date header when NTP is unavailable

Main features

- Intelligent timezone detection via public IPv4 with multiple fallbacks
- Safe timezone configuration using timedatectl when available, fallback to /etc/localtime with rollback support
- Prefer chrony; supports ntpdate/ntpd as fallbacks; auto-install missing tools
- Handles conflicting services (systemd-timesyncd / ntpd)
- Debian 13 compatibility: ensure /run/chrony, /var/lib/chrony, /var/log/chrony exist and have correct ownership; remove stale PID files
- Non-interactive safe: guards around clear/tput/stty to run in CI/cron/SSH without TTY
- Basic GitHub Actions: run bash -n and ShellCheck on PRs

Non-interactive notes

Script is safe to run in non-interactive environments (CI, cron, SSH, panels). If your runtime requires TERM, set TERM explicitly: `TERM=xterm bash timesync.sh`.

Diagnostics and troubleshooting

If something goes wrong, collect diagnostics (a provided script: scripts/collect-diagnostics.sh) to gather system info, chrony journal, permissions, and package status.

License

MIT
