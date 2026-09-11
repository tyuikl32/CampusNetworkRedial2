#!/bin/bash
set -u
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
OUT=$SRC/disasm
mkdir -p "$OUT"
ls -d /opt/kmod-build/* 2>/dev/null | head -20
echo "--- toolchain objdump ---"
"${TC}objdump" --version 2>&1 | head -2
for spec in "vendor/tun.ko:tun.vendor" "out/tun.ko:tun.ours" "vendor/pppox.ko:pppox.vendor" "vendor/ip_gre.ko:ip_gre.vendor" "out/macvlan.ko:macvlan.ours"; do
  f="${spec%%:*}"; n="${spec##*:}"
  if [ -f "$SRC/$f" ]; then
    "${TC}objdump" -dr "$SRC/$f" > "$OUT/$n.asm" 2>&1
    echo "disasm $f -> $n.asm ($(wc -l < "$OUT/$n.asm") lines)"
  else
    echo "MISSING $f"
  fi
done
echo "--- .rel sections sizes (vendor vs ours tun) ---"
for f in vendor/tun.ko out/tun.ko; do
  echo "== $f"; "${TC}readelf" -S "$SRC/$f" 2>/dev/null | grep -E "\.text|\.data|\.rodata|\.rel" | head -12
done
