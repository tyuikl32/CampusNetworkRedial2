#!/bin/bash
# flag-values.sh - exact IFF_* / NETIF_F_* constants for this kernel, so the
# lo device dump can be searched for them.
set -u
export LC_ALL=C
cd /opt/kmod-build/linux-5.4.164
echo "=== IFF_* (net_device::flags / ::priv_flags) ==="
grep -nE '^#define IFF_(LOOPBACK|UP|NO_QUEUE|LIVE_ADDR_CHANGE|NO_ARP|NOARP)\b' include/uapi/linux/if.h include/linux/netdevice.h 2>/dev/null
echo
echo "=== the private flag block in netdevice.h ==="
sed -n '/\* Private \(from 16 bits\)/,/^#define IFF_ECHO/p' include/linux/netdevice.h | grep -nE '#define IFF_' | head -40
echo
echo "=== NETIF_F_GSO_SOFTWARE / used by lo hw_features ==="
grep -nE '^#define NETIF_F_GSO_SOFTWARE' include/linux/netdev_features.h
echo
echo "=== net_device field order, offsets we care about (source of truth) ==="
awk '/^struct net_device \{/,/^\};/' include/linux/netdevice.h | grep -nE 'dev_addr|dev_addrs|perm_addr|broadcast|unsigned int\s+mtu|min_mtu|max_mtu|tx_queue_len|unsigned short\s+type|addr_len|unsigned int\s+flags|priv_flags|ifindex|netdev_ops|pcpu_refcnt|needed_headroom|hard_header_len' | head -40
