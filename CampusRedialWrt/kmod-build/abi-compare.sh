#!/bin/bash
# abi-compare.sh - compare struct-offset immediates between a module we built from
# the device's own config and the same module the firmware vendor shipped.
#
# Why: vermagic alone proves nothing (CONFIG_MODVERSIONS is off on this kernel).
# If the vendor's kernel tree defines struct net_device (etc.) differently from
# vanilla 5.4.164, the compiled immediates that encode field offsets will differ.
# Matching immediate sets per function is a compiler-version-robust ABI check.
#
# Usage: abi-compare.sh <ours.ko> <theirs.ko> [label]
set -u

OD=/opt/kmod-build/armv7-eabihf--glibc--stable-2022.08-1/bin/arm-buildroot-linux-gnueabihf-objdump
OURS=$1
THEIRS=$2
LABEL=${3:-$(basename "$OURS")}

imms() {
	"$OD" -d "$1" | awk '
		/^[0-9a-f]+ </ {
			fn = $0
			sub(/^[0-9a-f]+ </, "", fn)
			sub(/>:.*/, "", fn)
			next
		}
		{
			line = $0
			while (match(line, /#[0-9]+|#0x[0-9a-fA-F]+/)) {
				imm = substr(line, RSTART, RLENGTH)
				print fn "\t" imm
				line = substr(line, RSTART + RLENGTH)
			}
		}
	' | sort -u
}

echo "======================================================================"
echo " ABI immediate comparison: $LABEL"
echo "   ours   : $OURS   ($(stat -c%s "$OURS") bytes)"
echo "   vendor : $THEIRS ($(stat -c%s "$THEIRS") bytes)"
echo "======================================================================"

imms "$OURS"   > /tmp/imms-ours.txt
imms "$THEIRS" > /tmp/imms-theirs.txt

echo "distinct function/immediate pairs: ours=$(wc -l < /tmp/imms-ours.txt) vendor=$(wc -l < /tmp/imms-theirs.txt)"
echo

echo "--- functions present with DIFFERENT immediates (offset-level suspects) ---"
join -t$'\t' -j1 <(awk -F'\t' '{print $1}' /tmp/imms-ours.txt | uniq -c | awk '{print $2"\t"$1}' | sort) \
                 <(awk -F'\t' '{print $1}' /tmp/imms-theirs.txt | uniq -c | awk '{print $2"\t"$1}' | sort) 2>/dev/null \
  | awk -F'\t' '$2 != $3 {print "  " $1 "  ours=" $2 " vendor=" $3 " immediates"}'
echo
echo "--- per-function immediate diff (functions existing in both) ---"
only_ours=$(comm -23 <(cut -f1 /tmp/imms-ours.txt | sort -u) <(cut -f1 /tmp/imms-theirs.txt | sort -u) | wc -l)
only_theirs=$(comm -13 <(cut -f1 /tmp/imms-ours.txt | sort -u) <(cut -f1 /tmp/imms-theirs.txt | sort -u) | wc -l)
echo "  functions only in ours: $only_ours, only in vendor: $only_theirs"
echo "  (static/inlined helpers differ between compiler versions; this is expected noise)"
echo
echo "--- immediates in functions common to both that DIFFER ---"
comm -12 <(cut -f1 /tmp/imms-ours.txt | sort -u) <(cut -f1 /tmp/imms-theirs.txt | sort -u) > /tmp/common-fns.txt
awk -F'\t' 'NR==FNR {c[$0]; next} ($1 in c)' /tmp/common-fns.txt /tmp/imms-ours.txt   | sort -u > /tmp/c-ours.txt
awk -F'\t' 'NR==FNR {c[$0]; next} ($1 in c)' /tmp/common-fns.txt /tmp/imms-theirs.txt | sort -u > /tmp/c-theirs.txt
comm -3 /tmp/c-ours.txt /tmp/c-theirs.txt | sed 's/^/  /' | head -60
echo "  total differing lines: $(comm -3 /tmp/c-ours.txt /tmp/c-theirs.txt | wc -l)"
