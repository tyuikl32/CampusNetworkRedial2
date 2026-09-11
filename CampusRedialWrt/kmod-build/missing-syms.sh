#!/bin/bash
# missing-syms.sh - the full list of symbols that are enabled in the device's
# kernel config but absent from the .config we built from vanilla 5.4.164, plus
# a correct "is this symbol known to vanilla at all" check.
export LC_ALL=C
set -u
K=/opt/kmod-build/linux-5.4.164
LF=/opt/kmod-build/config-5.4.164-ax3000.lf

norm() {
	sed -n -E \
		-e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set$/\1\tn/p' \
		-e 's/^(CONFIG_[A-Za-z0-9_]+)=(.*)$/\1\t\2/p' \
		"$1" | sort -u
}
norm "$LF"       > /tmp/d.txt
norm "$K/.config" > /tmp/e.txt

echo "=== ENABLED on the device but NOT PRESENT AT ALL in our .config ==="
awk -F'\t' '$2 != "n" {print $1}' /tmp/d.txt | while read -r k; do
	grep -q "^$k	" /tmp/e.txt || echo "$k"
done | tee /tmp/missing.txt
echo "count: $(wc -l < /tmp/missing.txt)"
echo

echo "=== for each of those: is the Kconfig symbol known to vanilla 5.4.164? ==="
while read -r k; do
	s=${k#CONFIG_}
	if grep -rqE "^config ${s}$" "$K" --include=Kconfig; then
		loc=$(grep -rE "^config ${s}$" "$K" --include=Kconfig -l | head -1)
		printf '  %-46s KNOWN in %s\n' "$k" "${loc#$K/}"
	else
		printf '  %-46s vendor-only (no Kconfig entry)\n' "$k"
	fi
done < /tmp/missing.txt
echo

echo "=== the net_device layout gates, checked directly in vanilla 5.4.164 ==="
for s in WIRELESS_EXT CFG80211_WEXT NET_NS SYSFS RPS RFS_ACCEL XPS BQL NET_SCHED \
         NET_CLS_ACT DCB NET_L3_MASTER_DEV PTP_1588_CLOCK NET_POLL_CONTROLLER \
         XFRM_OFFLOAD NET_DSA NET_SWITCHDEV NET_DEVLINK WLAN; do
	if grep -rqE "^config ${s}$" "$K" --include=Kconfig; then
		loc=$(grep -rE "^config ${s}$" "$K" --include=Kconfig -l | head -1)
		printf '  %-24s defined (%-28s) device=%s built=%s\n' "$s" "${loc#$K/}" \
			"$(grep -E "^(CONFIG_$s=|# CONFIG_$s is not set)" /tmp/d.txt | head -1 | cut -f2 || echo -)" \
			"$(grep -E "^(CONFIG_$s=|# CONFIG_$s is not set)" /tmp/e.txt | head -1 | cut -f2 || echo -)"
	else
		printf '  %-24s NOT in vanilla Kconfig     device=%s built=%s\n' "$s" \
			"$(grep -E "^CONFIG_$s	" /tmp/d.txt | cut -f2)" \
			"$(grep -E "^CONFIG_$s	" /tmp/e.txt | cut -f2)"
	fi
done
