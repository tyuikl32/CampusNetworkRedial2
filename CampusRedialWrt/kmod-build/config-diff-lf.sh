#!/bin/bash
# config-diff-lf.sh - redo the config comparison with the CRLF stripped.
#
# The device's /proc/config.gz dump was saved with CRLF line endings. That made
# every "CONFIG_X=value" line end in \r, so the previous diff (and possibly
# kconfig itself) mis-handled it.  Normalise to LF first, then look at what
# kconfig actually does with it.
export LC_ALL=C
set -u
K=/opt/kmod-build/linux-5.4.164
RAW=/opt/kmod-build/config-5.4.164-ax3000
LF=/opt/kmod-build/config-5.4.164-ax3000.lf

tr -d '\r' < "$RAW" > "$LF"
printf 'raw: %s bytes / %s lines\n' "$(stat -c%s "$RAW")" "$(wc -l < "$RAW")"
printf 'lf : %s bytes / %s lines\n' "$(stat -c%s "$LF")" "$(wc -l < "$LF")"
echo

echo "=== does vanilla 5.4.164 even have these symbols? ==="
for s in WIRELESS_EXT CFG80211_WEXT NET_NS SYSFS RPS RFS_ACCEL XPS BQL \
         NET_L3_MASTER_DEV PTP_1588_CLOCK NET_UDP_TUNNEL SWIOTLB \
         NET_POLL_CONTROLLER NET_DEVLINK XFRM_OFFLOAD NET_SCHED NET_CLS_ACT; do
	printf '  %-24s ' "$s"
	if grep -rqE "^(menu)?config ${s}\$" --include=Kconfig . ; then
		grep -rE "^config ${s}\$" --include=Kconfig -l . | head -1 | sed 's/^/defined in /'
	else
		echo "NOT DEFINED in this tree"
	fi
done
echo

echo "=== rebuild .config from the LF version ==="
cp "$LF" "$K/.config"
"$K/scripts/config" --file "$K/.config" --module MACVLAN --module NETFILTER_XT_MATCH_STATISTIC
make -C "$K" ARCH=arm olddefconfig >/tmp/olddef-lf.log 2>&1
echo "olddefconfig rc=$?"
printf 'warnings: %s\n' "$(grep -ci 'warning' /tmp/olddef-lf.log || true)"
grep -iE 'warning' /tmp/olddef-lf.log | head -20

norm() {
	sed -n -E \
		-e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1\tn/p' \
		-e 's/^(CONFIG_[A-Za-z0-9_]+)=(.*)$/\1\t\2/p' \
		"$1" | sort -u
}
norm "$LF"      > /tmp/lf-dev.txt
norm "$K/.config" > /tmp/lf-eff.txt
printf 'normalised device (LF): %s entries\n' "$(wc -l < /tmp/lf-dev.txt)"
printf 'normalised built      : %s entries\n' "$(wc -l < /tmp/lf-eff.txt)"
echo
echo "=== symbols set to y/m on the device that the build does NOT have ==="
join -t$'\t' -v1 /tmp/lf-dev.txt /tmp/lf-eff.txt > /dev/null 2>&1
awk -F'\t' 'NR==FNR {e[$1]=$2; next} {if (!($1 in e)) print $1"\t"$2}' \
	/tmp/lf-eff.txt /tmp/lf-dev.txt > /dev/null 2>&1
join -t$'\t' -j1 <(sort -k1 /tmp/lf-dev.txt) /dev/null > /dev/null 2>&1
echo "  --- value changes ---"
join -t$'\t' /tmp/lf-dev.txt /tmp/lf-eff.txt 2>/dev/null \
	| awk -F'\t' '$2 != $3 {printf "  %-52s device=%-14s built=%s\n", $1, $2, $3}'
echo
echo "  --- enabled on the device, entirely missing from the build ---"
awk -F'\t' '$2 != "n"' /tmp/lf-dev.txt | while IFS=$'\t' read -r k v; do
	grep -q "^$k"$'\t' /tmp/lf-eff.txt || printf '  %-52s %s\n' "$k" "$v"
done
