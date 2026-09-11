#!/bin/bash
# config-drift.sh - what did olddefconfig change when we fed the device's own
# /proc/config.gz dump to vanilla 5.4.164?
#
# Any symbol Kconfig silently dropped (the vendor/QSDK tree adds Kconfig entries
# vanilla has not got) or flipped is a candidate for the struct net_device size
# difference measured on the wire: ours is 1344 bytes, the device's is bigger
# (its mtu sits 12 bytes later than ours does).
export LC_ALL=C
set -u

K=/opt/kmod-build/linux-5.4.164
DEV=/opt/kmod-build/config-5.4.164-ax3000
EFF=$K/.config

echo "=== inputs ==="
ls -l "$DEV" "$EFF"
printf 'device config: %s lines\n' "$(wc -l < "$DEV")"
printf 'effective .config: %s lines\n' "$(wc -l < "$EFF")"
echo

# -> "CONFIG_FOO<TAB>y" / "CONFIG_FOO<TAB>n" / "CONFIG_FOO<TAB>\"str\""
norm() {
	sed -n -E \
		-e 's/^# (CONFIG_[A-Za-z0-9_]+) is not set[[:space:]]*$/\1\tn/p' \
		-e 's/^(CONFIG_[A-Za-z0-9_]+)=(.*[^[:space:]])$/\1\t\2/p' \
		"$1" | LC_ALL=C sort -u
}

norm "$DEV" > /tmp/cfg-dev.txt
norm "$EFF" > /tmp/cfg-eff.txt
printf 'normalised device : %s entries\n' "$(wc -l < /tmp/cfg-dev.txt)"
printf 'normalised ours   : %s entries\n' "$(wc -l < /tmp/cfg-eff.txt)"
echo

cut -f1 /tmp/cfg-dev.txt | LC_ALL=C sort -u > /tmp/keys-dev.txt
cut -f1 /tmp/cfg-eff.txt | LC_ALL=C sort -u > /tmp/keys-eff.txt

echo "=== symbols on the device that vanilla 5.4.164 does not know ==="
comm -23 /tmp/keys-dev.txt /tmp/keys-eff.txt > /tmp/keys-dropped.txt
printf 'count: %s\n' "$(wc -l < /tmp/keys-dropped.txt)"
echo
echo "--- of those, the ones set to y/m (i.e. actually enabled on the device) ---"
awk -F'\t' 'NR==FNR {d[$1]; next} ($1 in d) && $2 != "n" {printf "  %-52s %s\n", $1, $2}' \
	/tmp/keys-dropped.txt /tmp/cfg-dev.txt
echo

echo "=== symbols in both, value changed by olddefconfig ==="
join -t$'\t' /tmp/cfg-dev.txt /tmp/cfg-eff.txt 2>/dev/null \
	| awk -F'\t' '$2 != $3 {printf "  %-52s device=%-14s ours=%s\n", $1, $2, $3}'
