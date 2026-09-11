#!/bin/bash
# cfgfmt.sh - is the exported device config plain LF, and did olddefconfig really
# keep it intact?  A CRLF .config makes kconfig mis-parse values, which would
# silently reset layout-relevant options and explain the 64-byte net_device gap.
export LC_ALL=C
set -u
F=/opt/kmod-build/config-5.4.164-ax3000
E=/opt/kmod-build/linux-5.4.164/.config

echo "=== byte-level check of the device config ==="
ls -l "$F"
printf 'total lines (\\n count) : %s\n' "$(tr -cd '\n' < "$F" | wc -c)"
printf 'CR characters           : %s\n' "$(tr -cd '\r' < "$F" | wc -c)"
printf 'NUL bytes               : %s\n' "$(tr -cd '\0' < "$F" | wc -c)"
echo "first 3 lines, cat -A (shows \$ at EOL, ^M for CR):"
head -3 "$F" | cat -A
echo

echo "=== line shape census ==="
printf '  CONFIG_X=...            : %s\n' "$(grep -c '^CONFIG_[A-Za-z0-9_]*=' "$F")"
printf '  "# CONFIG_X is not set" : %s\n' "$(grep -c '^# CONFIG_[A-Za-z0-9_]* is not set' "$F")"
printf '  other lines             : %s\n' "$(( $(wc -l < "$F") - $(grep -c '^CONFIG_[A-Za-z0-9_]*=' "$F") - $(grep -c '^# CONFIG_[A-Za-z0-9_]* is not set' "$F") ))"
echo

echo "=== layout-relevant options: device file vs the .config we actually built ==="
for sym in NET_NS WIRELESS_EXT CFG80211_WEXT SYSFS RPS RFS_ACCEL XPS BQL NET_SCHED \
           NET_CLS_ACT DCB NET_DSA XFRM_OFFLOAD NET_L3_MASTER_DEV NET_SWITCHDEV \
           NET_DEVLINK PTP_1588_CLOCK NETWORK_FILESYSTEMS CGROUPS SECURITY \
           BPF_SYSCALL NET_POLL_CONTROLLER TLS TLS_DEVICE SWIOTLB NET_UDP_TUNNEL \
           MACSEC FAILOVER VLAN_8021Q NETFILTER NETFILTER_ADVANCED NF_CONNTRACK \
           XDP_SOCKETS DEBUG_NET LOCKDEP PROVE_LOCKING IPV6 MPLS; do
	d=$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$F" | head -1)
	e=$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$E" | head -1)
	flag="  "
	[ "${d:-x}" = "${e:-x}" ] || flag="**"
	printf '%s %-24s device=%-28s built=%s\n' "$flag" "$sym" "${d:-<absent>}" "${e:-<absent>}"
done
