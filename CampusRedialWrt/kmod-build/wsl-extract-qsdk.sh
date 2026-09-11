#!/bin/bash
set -euo pipefail
SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
# 大件构建输入（QSDK 源码归档 / 内核源码树 / 交叉工具链）不入库，放在仓库外的缓存目录。
# 可用环境变量 CR_KMOD_CACHE 覆盖。
CACHE=${CR_KMOD_CACHE:-/mnt/d/CampusNetworkRedial/kmod-build-cache}
SHA=d5fcb18e5420670c8734c6a659873e73adab6dac
Q=/opt/kmod-build/linux-ipq-5.4
TB=$CACHE/qsdk/linux-ipq-5.4-$SHA.tar.gz
echo "=== tarball ==="; ls -la "$TB"; gzip -t "$TB" && echo "gzip OK"
if [ -d "$Q" ]; then echo "(already extracted)"; else
  echo "=== extracting (this takes a couple of minutes) ==="
  time tar -xzf "$TB" -C /opt/kmod-build
  mv "/opt/kmod-build/linux-ipq-5.4-$SHA" "$Q"
fi
echo "=== source identity ==="
sed -n '1,6p' "$Q/Makefile"
echo "=== vendor struct fields present? (must be non-empty) ==="
grep -n "priv_flags_ext" "$Q/include/linux/netdevice.h" | head -3
grep -n "local_addr_mask" "$Q/include/linux/netdevice.h" | head -3
grep -n "ndo_flow_offload" "$Q/include/linux/netdevice.h" | head -3
grep -n "SKB_RECYCLER" "$Q/include/linux/netdevice.h" | head -3
grep -rn "config SKB_RECYCLER" "$Q"/net "$Q"/drivers "$Q"/include 2>/dev/null | head -3
echo "=== WIRELESS_EXT Kconfig here ==="
grep -n -A6 "config WIRELESS_EXT" "$Q/net/wireless/Kconfig" | head -14
