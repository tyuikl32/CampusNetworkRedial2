#!/bin/bash
M=/opt/kmod-build/linux-ipq-5.4/drivers/net/macvlan.c
echo "=== bridge-port / upper-dev restrictions in macvlan_common_newlink ==="
grep -n "bridge_port\|IFF_UP\|upper_dev\|NETIF_F\|return -EINVAL\|EBUSY\|lowerdev->flags" "$M" | head -30
echo
echo "=== macvlan_setup (what gets initialised) ==="
awk '/^static void macvlan_setup/{p=1} p{print} p&&/^}/{exit}' "$M"
