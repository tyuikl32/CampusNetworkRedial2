#!/bin/bash
Q=/opt/kmod-build/linux-ipq-5.4
echo "=== skbuff_recycle.h: does it inject fields into sk_buff? ==="
grep -nE "struct |#define|extern|SKB_RECYCLER" "$Q/net/core/skbuff_recycle.h" 2>/dev/null | head -25
echo
echo "=== netdevice.h lines 1955-1975 (priv_flags_ext / local_addr_mask / work) ==="
sed -n '1955,1976p' "$Q/include/linux/netdevice.h"
echo
echo "=== netdevice.h lines 2000-2032 (mangle / cls_act / nf_ingress) ==="
sed -n '2000,2032p' "$Q/include/linux/netdevice.h"
echo
echo "=== net/Kconfig SKB_RECYCLER block ==="
sed -n '340,362p' "$Q/net/Kconfig"
