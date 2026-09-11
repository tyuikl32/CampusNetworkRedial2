#!/bin/bash
M=/opt/kmod-build/linux-ipq-5.4/drivers/net/macvlan.c
echo "=========== macvlan_port_create ==========="
awk '/^static int macvlan_port_create/{p=1} p{print} p&&/^}/{exit}' "$M"
echo
echo "=========== any bridge master check anywhere in macvlan.c ==========="
grep -n "bridge_master\|netif_is_bridge\|br_port" "$M" || echo "  (none)"
echo
echo "=========== netdev_is_rx_handler_busy ==========="
grep -n -A5 "netdev_is_rx_handler_busy" /opt/kmod-build/linux-ipq-5.4/include/linux/netdevice.h | head -12
