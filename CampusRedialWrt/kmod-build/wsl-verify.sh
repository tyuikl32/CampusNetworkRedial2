#!/bin/bash
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
DST=$SRC/out-qsdk
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
echo "=== vermagic (fixed: no ^5.4 anchor) ==="
for k in "$DST/macvlan.ko" "$DST/tun.ko" "$DST/xt_statistic.ko" "$SRC/vendor/tun.ko"; do
  [ -f "$k" ] || continue
  vm=$(strings "$k" | grep -m1 '^vermagic=')
  printf '  %-24s %s\n' "$(basename "$k")" "$vm"
done
echo
echo "=== .modinfo of our macvlan.ko ==="
"${TC}readelf" -p .modinfo "$DST/macvlan.ko" 2>/dev/null | grep -E "vermagic|name=|depends=" | sed 's/^/  /'
echo
echo "=== layout-symbol fidelity (CR-safe) ==="
tr -d '\r' < "$SRC/config-5.4.164-ax3000" > /tmp/dev.cfg
for s in WIRELESS_EXT WEXT_CORE SKB_RECYCLER NET_CLS_ACT NETFILTER_INGRESS NET_DSA TIPC SYSFS \
         MPLS_ROUTING ETHERNET_PACKET_MANGLE VLAN_8021Q NF_FLOW_TABLE MODVERSIONS MODULE_SIG \
         ARM_MODULE_PLTS PREEMPT SMP LOCALVERSION; do
  b=$(grep -E "^CONFIG_$s=" /opt/kmod-build/linux-ipq-5.4/.config | head -1 | cut -d= -f2-)
  d=$(grep -E "^CONFIG_$s=" /tmp/dev.cfg | head -1 | cut -d= -f2-)
  bb=$b; dd=$d
  [ -z "$b" ] && { grep -q "^# CONFIG_$s is not set" /opt/kmod-build/linux-ipq-5.4/.config && bb="n(explicit)" || bb="(unset)"; }
  [ -z "$d" ] && { grep -q "^# CONFIG_$s is not set" /tmp/dev.cfg && dd="n(explicit)" || dd="(unset)"; }
  [ "$bb" = "$dd" ] && m="OK " || m="!! "
  printf '  %s %-26s built=%-12s device=%s\n' "$m" "$s" "$bb" "$dd"
done
echo
echo "=== does xt_statistic touch net_device at all? (explains its 'no 0x580') ==="
echo -n "  netdev_priv refs in xt_statistic.qsdk.asm: "
grep -c "netdev_priv" "$DST/xt_statistic.qsdk.asm" 2>/dev/null || echo 0
echo -n "  struct net refs: "
grep -cE "net_device|dev_get|netdev_" "$DST/xt_statistic.qsdk.asm" 2>/dev/null || echo 0
