#!/bin/sh
# Snapshot the router's network-related config before any connection-pool work.
# Read-only w.r.t. behaviour: only creates a backup directory on the overlay.
# Prints the directory name so the caller can download it.

set -u

STAMP=$(date '+%Y%m%d-%H%M%S')
B="/etc/config/.campus-redial-backup-$STAMP"
mkdir -p "$B" || { echo "BACKUP_FAILED mkdir"; exit 1; }
chmod 700 "$B"

for f in network mwan3 firewall campus-redial dhcp; do
	[ -f "/etc/config/$f" ] && cp -p "/etc/config/$f" "$B/$f"
done

# Also keep a plain uci export, which is immune to "which file owns section X".
uci export network  > "$B/network.uci"  2>/dev/null || true
uci export mwan3    > "$B/mwan3.uci"    2>/dev/null || true
uci export firewall > "$B/firewall.uci" 2>/dev/null || true

echo "BACKUP_DIR=$B"
ls -l "$B"
echo "--- sha256 ---"
sha256sum "$B"/* 2>/dev/null
