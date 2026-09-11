#!/bin/bash
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
VM='5.4.164 SMP preempt mod_unload ARMv7 p2v8'
echo "====================== FINAL ABI VERDICT ======================"
printf '%-26s %-9s %-7s %-7s %-7s %s\n' MODULE vermagic 0x2b8 0x2f8 0x580 netdev_ops
for k in "$SRC/vendor/tun.ko" "$SRC/vendor/ip_gre.ko" "$SRC/out-qsdk/tun.ko" "$SRC/out-qsdk/macvlan.ko" "$SRC/out-qsdk/xt_statistic.ko"; do
  [ -f "$k" ] || continue
  asm=$("${TC}objdump" -dr "$k" 2>/dev/null)
  vm=$(strings "$k" | grep -m1 '^vermagic=' | sed 's/^vermagic=//' | sed 's/[[:space:]]*$//')
  [ "$vm" = "$VM" ] && ok="OK " || ok="BAD"
  printf '%-26s %-9s %-7s %-7s %-7s %s\n' "$(basename "$(dirname "$k")")/$(basename "$k")" "$ok" \
    "$(echo "$asm" | grep -c '0x2b8')" "$(echo "$asm" | grep -c '0x2f8')" "$(echo "$asm" | grep -c '0x580')" \
    "$("${TC}readelf" -sW "$k" 2>/dev/null | awk '$4=="OBJECT" && $8=="macvlan_netdev_ops"{print $3}')"
done
echo
echo "layout probe (exact offsetof, from our QSDK build):"
echo "    sizeof(struct net_device)     = 1408   [upstream 1344]"
echo "    sizeof(struct net_device_ops) =  272   [upstream  264]"
echo "    offsetof(pcpu_refcnt)         = 0x2f8  [upstream 0x2b8 <- what panicked]"
echo "    offsetof(dev_addr)            = 0x1fc  [upstream 0x1d0]"
