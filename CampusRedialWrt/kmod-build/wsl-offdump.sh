#!/bin/bash
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
run() {
  local K=$1 L=$2 DEF=$3 D=/opt/kmod-build/offdump-$L
  rm -rf "$D"; mkdir -p "$D"
  cp "$SRC/offdump/cr_offdump.c" "$D/"
  printf 'obj-m := cr_offdump.o\nccflags-y := %s\n' "$DEF" > "$D/Makefile"
  if ! make -C "$K" ARCH=arm CROSS_COMPILE="$TC" M="$D" modules >"$D/build.log" 2>&1; then
    echo "### $L: BUILD FAILED"; grep -E "error:" "$D/build.log" | head -6; return
  fi
  echo "### $L"
  readelf -sW "$D/cr_offdump.ko" 2>/dev/null | awk '$4=="OBJECT" && $8 ~ /^cr_/ {printf "  %-30s size=%-7s (%s)\n", $8, $3, $3}'
}
run /opt/kmod-build/linux-ipq-5.4   QSDK     "-DCR_QSDK"
run /opt/kmod-build/linux-5.4.164   UPSTREAM ""
