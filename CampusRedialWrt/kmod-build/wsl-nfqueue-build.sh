#!/bin/bash
# Build NFQUEUE kernel modules for the Redmi AX3000 (ipq50xx) from the SAME
# vendor tree that produced the running kernel:
#   Qualcomm QSDK  linux-ipq-5.4 @ d5fcb18e5420670c8734c6a659873e73adab6dac
#
# Why: the device kernel has
#   # CONFIG_NETFILTER_NETLINK_QUEUE is not set
#   # CONFIG_NETFILTER_XT_TARGET_NFQUEUE is not set
# so zapret nfqws cannot be used and the project fell back to tpws (a single
# threaded userspace proxy that caps download at ~270 mbit).  These two modules
# restore the kernel fast path: only the first few packets of a connection go
# to userspace, the bulk data never leaves the kernel.
#
# Same ABI discipline as wsl-qsdk-build.sh (vendor tree is MANDATORY, upstream
# 5.4.164 would panic - see memory/2026-09-10-ax3000-kmod-abi-mismatch.md).
set -uo pipefail

SRC=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
Q=/opt/kmod-build/linux-ipq-5.4
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
J=$(nproc)
DST=$SRC/out-nfq
VM_EXPECT='5.4.164 SMP preempt mod_unload ARMv7 p2v8'
PRIV_EXPECT='0x580'   # ALIGN(sizeof(struct net_device),32) = 1408 (regression guard)
mkdir -p "$DST"

echo "############ [1/7] preflight: is this really the vendor tree? ############"
for f in priv_flags_ext local_addr_mask ndo_flow_offload_check; do
  if grep -q "$f" "$Q/include/linux/netdevice.h"; then echo "  OK   netdevice.h has $f"
  else echo "  FATAL netdevice.h MISSING $f -> wrong source tree"; exit 1; fi
done
grep -q 'config SKB_RECYCLER' "$Q/net/Kconfig" && echo "  OK   net/Kconfig declares SKB_RECYCLER" \
  || echo "  WARN SKB_RECYCLER not declared in net/Kconfig"
awk -F'= *' '/^EXTRAVERSION/{gsub(/ /,"",$2); print "  OK   Makefile EXTRAVERSION=\"" $2 "\" (must be empty for UTS 5.4.164)"}' "$Q/Makefile"
for f in net/netfilter/nfnetlink_queue.c net/netfilter/xt_NFQUEUE.c net/netfilter/nf_queue.c; do
  [ -f "$Q/$f" ] && echo "  OK   $f" || { echo "  FATAL missing $f"; exit 1; }
done

echo
echo "############ [2/7] seed the device's own config + the two NFQUEUE symbols ############"
CFG=""
for c in "$SRC/config-5.4.164-ax3000.lf" "$SRC/config-5.4.164-ax3000"; do
  [ -f "$c" ] && CFG="$c" && break
done
[ -n "$CFG" ] || { echo "FATAL: device config not found"; exit 1; }
echo "  source: $CFG"
tr -d '\r' < "$CFG" > "$Q/.config"
# keep the previously validated promotions (MACVLAN/STATISTIC/TUN) so the
# regression module below is built under identical conditions
"$Q/scripts/config" --file "$Q/.config" \
  --module MACVLAN --module NETFILTER_XT_MATCH_STATISTIC --module TUN \
  --module NETFILTER_NETLINK_QUEUE --module NETFILTER_XT_TARGET_NFQUEUE
"$Q/scripts/config" --file "$Q/.config" --set-str LOCALVERSION ""

echo "  running olddefconfig + modules_prepare ..."
if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" olddefconfig >"$DST/olddefconfig.log" 2>&1; then
  echo "  FATAL olddefconfig failed"; tail -20 "$DST/olddefconfig.log"; exit 1; fi
if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" -j"$J" modules_prepare >"$DST/prepare.log" 2>&1; then
  echo "  FATAL modules_prepare failed"; tail -30 "$DST/prepare.log"; exit 1; fi
echo "  UTS_RELEASE = $(sed -n 's/^#define UTS_RELEASE "\(.*\)"/\1/p' "$Q/include/generated/utsrelease.h" 2>/dev/null)"

echo
echo "############ [3/7] config fidelity: built .config vs DEVICE .config ############"
sort "$Q/.config" > "$DST/built.config.sorted"
sort <(tr -d '\r' < "$CFG") > "$DST/device.config.sorted"
echo "  --- diffs (expect ONLY the module promotions) ---"
diff "$DST/device.config.sorted" "$DST/built.config.sorted" | sed 's/^/    /' | head -40
echo "  --- diff line count: $(diff "$DST/device.config.sorted" "$DST/built.config.sorted" | grep -cE '^[<>]') ---"

echo "  --- the symbols that decide struct layout (built vs device) ---"
for s in WIRELESS_EXT WEXT_CORE SKB_RECYCLER NET_CLS_ACT NETFILTER_INGRESS NET_DSA TIPC \
         SYSFS MPLS_ROUTING ETHERNET_PACKET_MANGLE VLAN_8021Q NF_FLOW_TABLE \
         MODVERSIONS MODULE_SIG ARM_MODULE_PLTS PREEMPT SMP LOCALVERSION \
         NETFILTER_ADVANCED NETFILTER_NETLINK NF_CONNTRACK; do
  b=$(grep -E "^CONFIG_$s=" "$Q/.config" | head -1 | cut -d= -f2-)
  d=$(grep -E "^CONFIG_$s=" "$CFG" | head -1 | cut -d= -f2-)
  bb=$b; dd=$d
  [ -z "$b" ] && { grep -q "^# CONFIG_$s is not set" "$Q/.config" && bb="n(explicit)" || bb="(unset)"; }
  [ -z "$d" ] && { grep -q "^# CONFIG_$s is not set" "$CFG" && dd="n(explicit)" || dd="(unset)"; }
  [ "$bb" = "$dd" ] && m="  OK " || m="  !! "
  printf '%s %-26s built=%-12s device=%s\n' "$m" "$s" "$bb" "$dd"
done

echo "  --- the new symbols actually took ---"
for s in NETFILTER_NETLINK_QUEUE NETFILTER_XT_TARGET_NFQUEUE; do
  printf '     %-32s %s\n' "$s" "$(grep -E "^CONFIG_$s=" "$Q/.config" || echo 'MISSING!')"
done

echo
echo "############ [4/7] build modules ############"
build_one() {
  local tgt=$1
  echo "  -> $tgt"
  if ! make -C "$Q" ARCH=arm CROSS_COMPILE="$TC" -j"$J" "$tgt" >"$DST/$(basename "$tgt").log" 2>&1; then
    echo "     BUILD FAILED (tail of log):"; tail -25 "$DST/$(basename "$tgt").log"; return 1; fi
  cp "$Q/$tgt" "$DST/"
}
build_one net/netfilter/nfnetlink_queue.ko
build_one net/netfilter/xt_NFQUEUE.ko
build_one drivers/net/tun.ko          # regression guard (ABI reference module)

# collect undefined symbols BEFORE stripping debug (symtab is kept either way,
# but do it now so this always reflects the shipped binary)
for k in nfnetlink_queue xt_NFQUEUE tun; do
  "${TC}nm" -u "$DST/$k.ko" 2>/dev/null | awk '{print $NF}' | sort -u > "$DST/$k.undef"
  printf '  undef symbols: %-16s %s\n' "$k" "$(wc -l < "$DST/$k.undef")"
done
for k in "$DST"/*.ko; do "${TC}strip" --strip-debug "$k" 2>/dev/null || true; done

echo
echo "############ [5/7] OFFLINE ABI VERDICT ############"
echo "--- vermagic: must be exactly '$VM_EXPECT' ---"
for k in "$DST/nfnetlink_queue.ko" "$DST/xt_NFQUEUE.ko" "$DST/tun.ko" "$SRC/vendor/tun.ko"; do
  [ -f "$k" ] || continue
  vm=$("${TC}strings" "$k" | grep -m1 -E '^5\.4\.[0-9]+ (SMP|UP)')
  if [ "$vm" = "$VM_EXPECT" ]; then printf '  OK   %-22s %s\n' "$(basename "$k")" "$vm"
  else printf '  !!   %-22s %s\n' "$(basename "$k")" "${vm:-<none>}"; fi
done

echo "--- regression: netdev_priv must still be $PRIV_EXPECT (=1408) ---"
disasm() { # $1=ko $2=tag
  [ -f "$1" ] || { echo "  --   $2: missing"; return; }
  "${TC}objdump" -dr "$1" > "$DST/$2.asm" 2>/dev/null
  hits=$(grep -cE "#1408[[:space:]]*; 0x580" "$DST/$2.asm")
  if [ "$hits" -gt 0 ]; then printf '  OK   %-18s %2d site(s) use 0x580\n' "$2" "$hits"
  else printf '  !!   %-18s no 0x580\n' "$2"; fi
}
disasm "$SRC/vendor/tun.ko" tun.vendor
disasm "$DST/tun.ko"        tun.qsdk
"${TC}objdump" -dr "$DST/nfnetlink_queue.ko" > "$DST/nfnetlink_queue.qsdk.asm" 2>/dev/null
"${TC}objdump" -dr "$DST/xt_NFQUEUE.ko"      > "$DST/xt_NFQUEUE.qsdk.asm"      2>/dev/null

echo "--- declared module metadata ---"
for k in nfnetlink_queue xt_NFQUEUE; do
  printf '  %-18s license=%s\n' "$k" "$("${TC}strings" "$DST/$k.ko" | grep -m1 -E '^GPL')"
done

echo
echo "############ [6/7] undefined symbols (cross-check vs device kallsyms on the HOST) ############"
for k in nfnetlink_queue xt_NFQUEUE; do
  echo "  --- $k ---"
  sed 's/^/     /' "$DST/$k.undef"
done

echo
echo "############ [7/7] artifacts ############"
( cd "$DST" && sha256sum *.ko > SHA256SUMS 2>/dev/null ) && cat "$DST/SHA256SUMS"
ls -la "$DST"/*.ko
echo
echo "NEXT (host side, pure offline):"
echo "  python sshvm.py download /proc/kallsyms > /tmp/kallsyms.txt"
echo "  cross-check every name in out-nfq/{nfnetlink_queue,xt_NFQUEUE}.undef"
echo "=== done ==="
