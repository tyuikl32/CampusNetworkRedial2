#!/bin/bash
Q=/opt/kmod-build/linux-ipq-5.4
echo "=== whole-tree search: SKB_RECYCLER (file list) ==="
grep -rl "SKB_RECYCLER" "$Q" 2>/dev/null | sed "s|$Q/||" | head -30
echo "--- count: $(grep -rl "SKB_RECYCLER" "$Q" 2>/dev/null | wc -l) files"
echo
echo "=== declare it? (Kconfig) ==="
grep -rn "config SKB_RECYCLER" "$Q" 2>/dev/null | head -5 || true
echo
echo "=== netdevice.h: struct net_device conditional region around our added fields ==="
grep -nE "^#(if|ifdef|ifndef|elif|endif)|priv_flags_ext|local_addr_mask|struct work_struct\s+work;|WIRELESS_EXT" "$Q/include/linux/netdevice.h" | awk -F: '$1>1930 && $1<2030' 
echo
echo "=== skbuff.h: recycler refs ==="
grep -n "recycl\|RECYCL" "$Q/include/linux/skbuff.h" | head -20
echo
echo "=== net/wireless/Kconfig WIRELESS_EXT ==="
sed -n '/^config WIRELESS_EXT/,/^config /p' "$Q/net/wireless/Kconfig" | head -12
