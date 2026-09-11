#!/bin/bash
# static-check.sh - ABI fingerprints that can be read off the ELF files alone.
#
# The most important one: the size of section .gnu.linkonce.this_module IS
# sizeof(struct module) of whoever compiled the file. If our build and the
# vendor's build disagree there, the kernel writes/reads fields of the module's
# own __this_module at the wrong offsets while loading it - which turns into a
# jump through a garbage mod->init pointer, i.e. an instant panic at insmod time,
# with no chance for our code to print anything.

set -u
TC=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1
OUT=/opt/kmod-build/out
VEN=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build/vendor
OWNOUT=/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build/out

sec_size() { # file section
	readelf -S -W "$1" 2>/dev/null | awk -v s="$2" '$2 == s { print $6; exit }'
}

fmt() { printf '0x%08x' "$1"; }

echo "=============================================================="
echo " struct module size  (section .gnu.linkonce.this_module)"
echo "=============================================================="
report() {
	local f=$1 lbl=$2 v
	v=$(sec_size "$f" "gnu.linkonce.this_module")
	if [ -n "$v" ]; then
		printf '  %-28s %-34s %s\n' "$lbl" "$(basename "$f")" "$((16#$v)) bytes"
	else
		printf '  %-28s %-34s (section missing)\n' "$lbl" "$(basename "$f")"
	fi
}
report "$VEN/tun.ko"            "VENDOR (device kernel)"
report "$VEN/pppox.ko"          "VENDOR (device kernel)"
report "$VEN/ip_gre.ko"         "VENDOR (device kernel)"
report "$OUT/tun.ko"            "OURS   (vanilla 5.4.164)"
report "$OUT/macvlan.ko"        "OURS   (vanilla 5.4.164)"
report "$OUT/xt_statistic.ko"   "OURS   (vanilla 5.4.164)"
echo

echo "=============================================================="
echo " other structural fingerprints"
echo "=============================================================="
for f in "$VEN/tun.ko" "$OUT/tun.ko"; do
	printf '\n  --- %s ---\n' "$f"
	for s in .text .data .rodata .plt .init.text .exit.text .gnu.linkonce.this_module .modinfo .devinit.text; do
		v=$(sec_size "$f" "$s")
		[ -n "$v" ] && printf '      %-30s %8d bytes\n' "$s" "$((16#$v))"
	done
	printf '      %-30s %s\n' "ARM attributes/EABI" "$(readelf -A "$f" 2>/dev/null | grep -m1 'Tag_ABI_VFP_args' | sed 's/^ *//')"
	printf '      %-30s %s\n' "flags(e_flags)" "$(readelf -h "$f" | awk '/Flags:/{print}')"
done
echo

echo "=============================================================="
echo " undefined symbols that our modules need (must all be exported)"
echo "=============================================================="
for f in "$OUT/macvlan.ko" "$OUT/xt_statistic.ko" "$OUT/cr_abicheck.ko"; do
	echo "  --- $(basename "$f") ---"
	readelf -s -W "$f" | awk '$7=="UND" && $8!="" {print "      "$8}' | sort -u | tr '\n' ' ' | fold -s -w 150 | sed 's/^/  /'
	echo
done
