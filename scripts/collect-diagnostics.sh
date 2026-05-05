#!/usr/bin/env bash
set -euo pipefail
out_dir="/tmp/timesync-diagnostics-$(date +%s)"
mkdir -p "$out_dir"
echo "Collecting diagnostics to $out_dir"
# Basic system
uname -a > "$out_dir/uname.txt" 2>&1 || true
cat /etc/os-release > "$out_dir/os-release.txt" 2>&1 || true
# Disk/mount
df -h > "$out_dir/df.txt" 2>&1 || true
mount > "$out_dir/mounts.txt" 2>&1 || true
# Chrony status and journal
systemctl status chrony --no-pager -l > "$out_dir/chrony-systemctl.txt" 2>&1 || true
journalctl -u chrony -n 500 --no-pager > "$out_dir/chrony-journal.txt" 2>&1 || true
# Directories and permissions
ls -ld /run /run/chrony /var/run/chrony /var/lib/chrony /var/log/chrony /etc/chrony > "$out_dir/chrony-dirs.txt" 2>&1 || true
stat -c '%n %U %G %a' /var/lib/chrony /var/log/chrony /run/chrony 2>/dev/null > "$out_dir/chrony-stats.txt" || true
# Processes and sockets
ps -ef | grep [c]hronyd > "$out_dir/chronyd-procs.txt" 2>&1 || true
ss -ltnp | grep chronyd > "$out_dir/chronyd-sockets.txt" 2>/dev/null || true
# chronyc outputs
chronyc tracking > "$out_dir/chronyc-tracking.txt" 2>&1 || true
chronyc sources -v > "$out_dir/chronyc-sources.txt" 2>&1 || true
chronyc activity > "$out_dir/chronyc-activity.txt" 2>&1 || true
# Network
ip -4 addr show > "$out_dir/ip-addr.txt" 2>&1 || true
ip route > "$out_dir/ip-route.txt" 2>&1 || true
# Package status (Debian/Ubuntu)
if command -v dpkg-query &>/dev/null; then dpkg-query -l chrony 2>/dev/null > "$out_dir/dpkg-chrony.txt" || true; fi
# Tar gzip
tar -C /tmp -czf "$out_dir.tar.gz" "$(basename "$out_dir")" || true
echo "Diagnostics archived to /tmp/$(basename "$out_dir").tar.gz"
echo "Upload or share that archive when filing an issue." 
exit 0
