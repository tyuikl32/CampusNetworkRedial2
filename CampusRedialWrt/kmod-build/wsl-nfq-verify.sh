#!/bin/bash
# Offline ABI verification for the self-built NFQUEUE modules (see wsl-nfqueue-build.sh).
# Run:  wsl.exe -d Debian -- bash /mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build/wsl-nfq-verify.sh
#
# NOTE ON PIPE SAFETY: this script must never use `producer | grep -q` inside an
# `&&`-condition while `set -o pipefail` is active -- grep -q exits on first hit,
# the producer dies of SIGPIPE (141), pipefail propagates that as failure and the
# gate silently reports "(unset)".  That bug produced five bogus "mismatches" on
# 2026-09-11.  Use plain `grep -q pat file` or `grep -m1 pat file | cut`.
set -uo pipefail

TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-
Q=/opt/kmod-build/linux-ipq-5.4
D=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build
CFG_RAW=$D/config-5.4.164-ax3000
KS=$D/kallsyms-ax3000.txt
VM_EXPECT='5.4.164 SMP preempt mod_unload ARMv7 p2v8'
OUT=$D/out-nfq

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CFG=$TMP/device.config.lf
tr -d '\r' < "$CFG_RAW" > "$CFG"
BUILT=$TMP/built.config
cp "$Q/.config" "$BUILT"

cfgval() { # $1=config file  $2=symbol (CONFIG_ prefix optional) -> y|m|"str"|n(explicit)|(unset)
  local v s=${2#CONFIG_}
  v=$(grep -m1 -E "^CONFIG_$s=" "$1" | cut -d= -f2-)
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  if grep -q "^# CONFIG_$s is not set" "$1"; then printf 'n(explicit)'; else printf '(unset)'; fi
}
kconfig_default() { # $1=symbol -> "default ..." lines from the tree Kconfig
  grep -rh -A12 "^config $1$" "$Q" --include=Kconfig 2>/dev/null | grep -m1 -E '^\s+default ' | sed 's/^\s*//'
}

echo "############ [1] vermagic / license (.modinfo) ############"
for k in "$OUT/nfnetlink_queue.ko" "$OUT/xt_NFQUEUE.ko" "$OUT/tun.ko" "$D/vendor/tun.ko"; do
  [ -f "$k" ] || { printf '  --   %s: missing\n' "$(basename "$k")"; continue; }
  # NB: modinfo strings carry a trailing space -- strip it before comparing
  vm=$("${TC}strings" "$k" | grep -m1 -E '^vermagic=' | sed 's/[[:space:]]*$//')
  lic=$("${TC}strings" "$k" | grep -m1 -E '^license=' | sed 's/[[:space:]]*$//')
  [ "$vm" = "vermagic=$VM_EXPECT" ] && m="  OK " || m="  !! "
  printf '%s %-24s %-52s %s\n' "$m" "$(basename "$k")" "${vm:-<none>}" "${lic:-<none>}"
done

echo
echo "############ [2] whole-config diff (built vs device) ############"
sort "$BUILT" > "$TMP/b.sorted"; sort "$CFG" > "$TMP/d.sorted"
diff "$TMP/d.sorted" "$TMP/b.sorted" | grep -cE '^[<>]' | sed 's/^/  differing lines: /'
diff "$TMP/d.sorted" "$TMP/b.sorted" | sed 's/^/    /'

echo
echo "############ [3] layout gate: CONFIG gates INSIDE the structs our modules touch ############"
echo "  (structs: sk_buff, skb_shared_info, nf_hook_ops, nf_hook_state,"
echo "            xt_action_param, xt_tgchk_param, xt_target, nfqnl_instance, nfnl_callback)"
gate_struct() { # $1=header  $2=struct-name
  local hdr=$1 sname=$2 body syms
  body=$(awk "/^struct $sname \{/,/^\};/" "$Q/$hdr")
  [ -n "$body" ] || { printf '  --   struct %-18s not found in %s\n' "$sname" "$hdr"; return; }
  syms=$(printf '%s\n' "$body" | grep -oE 'CONFIG_[A-Z0-9_]+' | sort -u)
  if [ -z "$syms" ]; then printf '  --   struct %-18s has no CONFIG-gated fields\n' "$sname"; return; fi
  for s in $syms; do
    b=$(cfgval "$BUILT" "$s"); d=$(cfgval "$CFG" "$s")
    if [ "$b" = "$d" ]; then m="  OK "; else m="  !! "; fi
    printf '%s %-18s %-30s built=%-12s device=%-12s' "$m" "$sname" "$s" "$b" "$d"
    [ "$b" != "$d" ] && printf ' kconfig-default: %s' "$(kconfig_default "${s#CONFIG_}")"
    printf '\n'
  done
}
HDR=include/linux/skbuff.h
gate_struct $HDR sk_buff
gate_struct $HDR skb_shared_info
gate_struct include/linux/netfilter.h nf_hook_ops
gate_struct include/linux/netfilter.h nf_hook_state
gate_struct include/linux/netfilter/x_tables.h xt_action_param
gate_struct include/linux/netfilter/x_tables.h xt_tgchk_param
gate_struct include/linux/netfilter/x_tables.h xt_target
gate_struct include/linux/netfilter/nfnetlink.h nfnl_callback

echo
echo "############ [4] module-relevant CONFIG values (built vs device) ############"
for s in NETFILTER NETFILTER_ADVANCED NETFILTER_NETLINK NETFILTER_NETLINK_QUEUE \
         NETFILTER_XT_TARGET_NFQUEUE NETFILTER_XT_MATCH_CONNBYTES NETFILTER_XT_MATCH_STATISTIC \
         NF_CONNTRACK NF_CONNTRACK_NETLINK NF_CONNTRACK_EVENTS NF_CT_NETLINK_TIMEOUT \
         NETFILTER_NETLINK_GLUE_CT NET_CLS_ACT NET_SCHED NET_DSA TIPC MODVERSIONS MODULE_SIG \
         STACKPROTECTOR USER_NS SLUB PROC_FS NO_HZ ARM_MODULE_PLTS SMP PREEMPT \
         MACVLAN VLAN_8021Q WIRELESS_EXT SKB_RECYCLER LOCALVERSION; do
  b=$(cfgval "$BUILT" "$s"); d=$(cfgval "$CFG" "$s")
  if [ "$b" = "$d" ]; then m="  OK "; else m="  !! "; fi
  printf '%s %-30s built=%-14s device=%-14s' "$m" "$s" "$b" "$d"
  [ "$b" != "$d" ] && printf ' kconfig-default: %s' "$(kconfig_default "$s")"
  printf '\n'
done

echo
echo "############ [5] undefined-symbol cross-check vs device kallsyms ############"
echo "  kallsyms on this device has no KALLSYMS_ALL -> DATA symbols are absent by design;"
echo "  [6] proves those are exported by the vendor tree instead."
if [ -f "$KS" ]; then
  for m in nfnetlink_queue xt_NFQUEUE; do
    f=$OUT/$m.undef; [ -f "$f" ] || continue
    ok=0; miss=""
    while read -r s; do
      [ -n "$s" ] || continue
      if grep -qE "(^|[[:space:]])$s([[:space:]]|\$)" "$KS"; then ok=$((ok+1)); else miss="$miss $s"; fi
    done < "$f"
    total=$(grep -c . "$f")
    printf '  %-18s functions present: %s/%s\n' "$m" "$ok" "$total"
    [ -n "$miss" ] && printf '        needs data-symbol proof from [6]:%s\n' "$miss"
  done
else
  echo "  -- $KS missing"
fi

echo
echo "############ [6] data symbols: exported by the vendor tree + provider built on device ############"
check_export() { # $1=symbol  $2=providing CONFIG
  local sym=$1 cfg=$2 files val
  files=$(grep -rlE "EXPORT_SYMBOL(_GPL)?\($sym\)" "$Q" --include='*.c' 2>/dev/null | sed "s#$Q/##" | tr '\n' ' ')
  val=$(cfgval "$CFG" "$cfg")
  if [ -n "$files" ]; then
    printf '  OK   %-20s provider=%-14s device CONFIG_%s=%s\n' "$sym" "$files" "$cfg" "$val"
  else
    printf '  !!   %-20s no EXPORT_SYMBOL in vendor tree\n' "$sym"
  fi
}
check_export init_user_ns      USER_NS
check_export kmalloc_caches    SLUB
check_export __stack_chk_guard STACKPROTECTOR
check_export nf_ct_hook        NF_CONNTRACK
check_export nfnl_ct_hook      NF_CONNTRACK
check_export nfnl_lock         NETFILTER_NETLINK
check_export nfnetlink_subsys_register NETFILTER_NETLINK
check_export nfnetlink_unicast NETFILTER_NETLINK
check_export nf_queue_entry_get_refs NETFILTER
check_export nf_register_queue_handler NETFILTER
check_export nf_reinject       NETFILTER
check_export xt_register_targets NETFILTER_XTABLES
check_export proc_create_net_data PROC_FS
check_export skb_zerocopy      NETFILTER

echo
echo "############ [7] verdict ############"
echo "  PASS requires: [1] all vermagic/license OK, [2] every diff line explainable,"
echo "                 [3] no '!!' rows, [5] all absences covered by [6]."
echo "=== verify done ==="
