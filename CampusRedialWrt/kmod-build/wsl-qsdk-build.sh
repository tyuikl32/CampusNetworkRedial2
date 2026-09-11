#!/bin/bash
# Build ABI-compatible kernel modules for the Redmi AX3000 (ipq50xx) from the
# ACTUAL vendor kernel source used by the running firmware:
#   Qualcomm QSDK  linux-ipq-5.4 @ d5fcb18e5420670c8734c6a659873e73adab6dac
# whose Makefile is VERSION=5 PATCHLEVEL=4 SUBLEVEL=164 EXTRAVERSION=(empty),
# i.e. UTS_RELEASE == "5.4.164" == what the device reports in uname -r.
#
# WHY the vendor tree is mandatory (do not "just use upstream 5.4.164"):
#   QSDK patches struct net_device (+60 bytes) and struct net_device_ops (+2
#   members).  Upstream-built modules still insmod (vermagic matches, and
#   CONFIG_MODVERSIONS is off) and then corrupt memory -> kernel panic.
#   Proof & history: memory/2026-09-10-ax3000-kmod-abi-mismatch.md
set -uo pipefail

SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
SHA=d5fcb18e5420670c8734c6a659873e73adab6dac
Q=/opt/kmod-build/linux-ipq-5.4
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
J=$(nproc)
DST=$SRC/out-qsdk
VM_EXPECT='5.4.164 SMP preempt mod_unload ARMv7 p2v8'
PRIV_EXPECT='0x580'   # ALIGN(sizeof(struct net_device),32) = 1408
mkdir -p "$DST"

echo "############ [1/6] preflight: is this really the vendor tree? ############"
for f in priv_flags_ext local_addr_mask ndo_flow_offload_check; do
  if grep -q "$f" "$Q/include/linux/netdevice.h"; then echo "  OK   netdevice.h has $f"
  else echo "  FATAL netdevice.h MISSING $f -> wrong source tree"; exit 1; fi
done
grep -q 'config SKB_RECYCLER' "$Q/net/Kconfig" && echo "  OK   net/Kconfig declares SKB_RECYCLER" \
  || echo "  WARN SKB_RECYCLER not declared in net/Kconfig"
if grep -q -A2 '^config WIRELESS_EXT$' "$Q/net/wireless/Kconfig" && \
   sed -n '/^config WIRELESS_EXT$/,/^config /p' "$Q/net/wireless/Kconfig" | grep -q 'bool "'; then
  echo "  OK   WIRELESS_EXT is user-selectable here (upstream had no prompt)"
else echo "  WARN WIRELESS_EXT has no prompt -> config value may be dropped"; fi
awk -F'= *' '/^EXTRAVERSION/{gsub(/ /,"",$2); print "  OK   Makefile EXTRAVERSION=\"" $2 "\" (must be empty for UTS 5.4.164)"}' "$Q/Makefile"

echo
echo "############ [2/6] seed the device's own config ############"
CFG=""
for c in "$SRC/config-5.4.164-ax3000.lf" "$SRC/config-5.4.164-ax3000" /opt/kmod-build/config-5.4.164-ax3000.lf; do
  [ -f "$c" ] && CFG="$c" && break
done
[ -n "$CFG" ] || { echo "FATAL: device config not found"; exit 1; }
echo "  source: $CFG"
tr -d '\r' < "$CFG" > "$Q/.config"
"$Q/scripts/config" --file "$Q/.config" \
  --module MACVLAN --module NETFILTER_XT_MATCH_STATISTIC --module TUN
"$Q/scripts/config" --file "$Q/.config" --set-str LOCALVERSION ""

echo "  running olddefconfig + modules_prepare (this is the slow part) ..."
if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" olddefconfig >"$DST/olddefconfig.log" 2>&1; then
  echo "  FATAL olddefconfig failed"; tail -20 "$DST/olddefconfig.log"; exit 1; fi
if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" -j"$J" modules_prepare >"$DST/prepare.log" 2>&1; then
  echo "  FATAL modules_prepare failed"; tail -30 "$DST/prepare.log"; exit 1; fi
echo "  UTS_RELEASE = $(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "$Q/include/generated/utsrelease.h" 2>/dev/null)"

echo
echo "############ [3/6] config fidelity: built .config vs DEVICE .config ############"
sort "$Q/.config"  > "$DST/built.config.sorted"
sort <(tr -d '\r' < "$CFG") > "$DST/device.config.sorted"
echo "  --- lines that differ (expect only the 3 module promotions + defaults) ---"
diff "$DST/device.config.sorted" "$DST/built.config.sorted" | sed 's/^/    /' | head -60
echo "  --- diff line count: $(diff "$DST/device.config.sorted" "$DST/built.config.sorted" | grep -cE '^[<>]') ---"

echo "  --- the symbols that decide struct layout (built vs device) ---"
for s in WIRELESS_EXT WEXT_CORE SKB_RECYCLER NET_CLS_ACT NETFILTER_INGRESS NET_DSA TIPC \
         SYSFS MPLS_ROUTING ETHERNET_PACKET_MANGLE VLAN_8021Q NF_FLOW_TABLE \
         MODVERSIONS MODULE_SIG ARM_MODULE_PLTS PREEMPT SMP LOCALVERSION; do
  b=$(grep -E "^CONFIG_$s=" "$Q/.config" | head -1 | cut -d= -f2-)
  d=$(grep -E "^CONFIG_$s=" "$CFG" | head -1 | cut -d= -f2-)
  bb=$b; dd=$d
  [ -z "$b" ] && { grep -q "^# CONFIG_$s is not set" "$Q/.config" && bb="n(explicit)" || bb="(unset)"; }
  [ -z "$d" ] && { grep -q "^# CONFIG_$s is not set" "$CFG" && dd="n(explicit)" || dd="(unset)"; }
  [ "$bb" = "$dd" ] && m="  OK " || m="  !! "
  printf '%s %-26s built=%-12s device=%s\n' "$m" "$s" "$bb" "$dd"
done

echo
echo "############ [4/6] build modules ############"
build_one() {
  local tgt=$1
  echo "  -> $tgt"
  if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" -j"$J" "$tgt" >"$DST/$(basename "$tgt").log" 2>&1; then
    echo "     BUILD FAILED (tail of log):"; tail -25 "$DST/$(basename "$tgt").log"; return 1; fi
  cp "$Q/$tgt" "$DST/"
}
build_one drivers/net/macvlan.ko
build_one drivers/net/tun.ko
build_one net/netfilter/xt_statistic.ko
for k in "$DST"/*.ko; do "${TC}strip" --strip-debug "$k" 2>/dev/null || true; done

echo
echo "############ [5/6] OFFLINE ABI VERDICT vs the vendor modules on the device ############"
echo "--- vermagic: must be exactly '$VM_EXPECT' ---"
for k in "$DST/macvlan.ko" "$DST/tun.ko" "$DST/xt_statistic.ko" "$SRC/vendor/tun.ko"; do
  [ -f "$k" ] || continue
  vm=$("${TC}strings" "$k" | grep -m1 -E '^5\.4\.[0-9]+ (SMP|UP)')
  if [ "$vm" = "$VM_EXPECT" ]; then printf '  OK   %-22s %s\n' "$(basename "$k")" "$vm"
  else printf '  !!   %-22s %s\n' "$(basename "$k")" "${vm:-<none>}"; fi
done

echo "--- ALIGN(sizeof(struct net_device),32): must be $PRIV_EXPECT (=1408) ---"
disasm() { # $1=ko  $2=tag
  [ -f "$1" ] || { echo "  --   $2: missing"; return; }
  "${TC}objdump" -dr "$1" > "$DST/$2.asm" 2>/dev/null
  hits=$(grep -cE "#1408[[:space:]]*; 0x580" "$DST/$2.asm")
  if [ "$hits" -gt 0 ]; then
    printf '  OK   %-18s %2d site(s) use 0x580\n' "$2" "$hits"
    grep -m2 -E "#1408[[:space:]]*; 0x580" "$DST/$2.asm" | sed 's/^[[:space:]]*/         /'
  else
    printf '  !!   %-18s no 0x580 -> struct net_device size mismatch\n' "$2"
  fi
}
disasm "$SRC/vendor/tun.ko"  tun.vendor
disasm "$DST/tun.ko"         tun.qsdk
disasm "$DST/macvlan.ko"     macvlan.qsdk
disasm "$DST/xt_statistic.ko" xt_statistic.qsdk

echo
echo "############ [6/6] artifacts ############"
( cd "$DST" && sha256sum *.ko > SHA256SUMS 2>/dev/null ) && cat "$DST/SHA256SUMS"
ls -la "$DST"/*.ko
echo
echo "NEXT (run on the HOST, pure offline comparison):"
echo "  python offset-hist.py $DST/tun.vendor.asm $DST/tun.qsdk.asm"
echo "  python offset-hist.py $DST/tun.vendor.asm $DST/macvlan.qsdk.asm"
echo "=== done ==="
