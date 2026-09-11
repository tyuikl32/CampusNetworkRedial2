#!/bin/bash
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
echo "### struct net_device_ops instances (expect 272 = QSDK layout, 264 = upstream) ###"
for k in "$SRC/vendor/tun.ko" "$SRC/vendor/pppox.ko" "$SRC/vendor/ip_gre.ko" "$SRC/out-qsdk/tun.ko" "$SRC/out-qsdk/macvlan.ko"; do
  [ -f "$k" ] || continue
  echo "-- $(basename "$(dirname "$k")")/$(basename "$k")"
  "${TC}readelf" -sW "$k" 2>/dev/null | awk '$4=="OBJECT" && $8 ~ /(netdev_ops|ethtool_ops|header_ops)$/ {printf "     %-28s size=%s\n", $8, $3}'
done
echo
echo "### any 0x2b8 / 0x2f8 immediates in the vendor modules? ###"
for k in vendor/tun.ko vendor/pppox.ko vendor/ip_gre.ko; do
  printf '  %-16s 2b8=%s  2f8=%s\n' "$(basename "$k")" \
    "$("${TC}objdump" -dr "$SRC/$k" 2>/dev/null | grep -c '0x2b8')" \
    "$("${TC}objdump" -dr "$SRC/$k" 2>/dev/null | grep -c '0x2f8')"
done
