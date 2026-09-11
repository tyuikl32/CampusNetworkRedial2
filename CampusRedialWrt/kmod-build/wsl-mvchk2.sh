#!/bin/bash
M=/opt/kmod-build/linux-ipq-5.4/drivers/net/macvlan.c
D=/opt/kmod-build/linux-ipq-5.4/net/core/dev.c
echo "=========== netdev_rx_handler_register (5.4) ==========="
awk '/^int netdev_rx_handler_register/{p=1} p{print} p&&/^}/{exit}' "$D"
echo
echo "=========== macvlan_common_newlink: the guard clause ==========="
awk '/^int macvlan_common_newlink/{p=1} p{print} p&&/^}/{exit}' "$M" | sed -n '1,60p'
