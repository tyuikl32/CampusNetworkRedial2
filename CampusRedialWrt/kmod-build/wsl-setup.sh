#!/bin/bash
# Prepare the AX3000 kernel-module build tree inside WSL (ext4 native).
# Idempotent-ish: skips steps whose outputs already exist.
set -eu

SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
# 大件构建输入（QSDK 源码归档 / 内核源码树 / 交叉工具链）不入库，放在仓库外的缓存目录。
# 可用环境变量 CR_KMOD_CACHE 覆盖。
CACHE=${CR_KMOD_CACHE:-/mnt/d/CampusNetworkRedial/kmod-build-cache}
DST=/opt/kmod-build
mkdir -p "$DST"
cd "$DST"

say() { printf '\n==> %s\n' "$*"; }

say "disk space"
df -h "$DST" | tail -1

# --- kernel source (re-extract natively so symlinks are real) --------------
if [ ! -f "$DST/linux-5.4.164/Makefile" ]; then
    say "extracting linux-5.4.164.tar.xz"
    time tar -xf "$CACHE/linux-5.4.164.tar.xz" -C "$DST"
else
    say "kernel source already extracted"
fi
ls -ld "$DST/linux-5.4.164" && ls "$DST/linux-5.4.164/Makefile"

# --- toolchain ------------------------------------------------------------
TCNAME=armv7-eabihf--glibc--stable-2022.08-1
if [ ! -x "$DST/$TCNAME/bin/arm-buildroot-linux-gnueabihf-gcc" ]; then
    say "extracting toolchain"
    time tar -xf "$CACHE/armv7-toolchain.tar.bz2" -C "$DST"
else
    say "toolchain already extracted"
fi
ls -d "$DST"/armv7-eabihf--glibc--stable-* 2>/dev/null || true
"$DST/$TCNAME/bin/arm-buildroot-linux-gnueabihf-gcc" --version | head -1

# --- device kernel config -------------------------------------------------
say "installing device kernel config"
cp "$SRC/config-5.4.164-ax3000" "$DST/config-5.4.164-ax3000"
wc -l "$DST/config-5.4.164-ax3000"

say "setup done"
