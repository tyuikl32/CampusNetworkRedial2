#!/bin/sh
# Per-session capacity test for the campus connection pool.
#
# Runs the same download on ALL three pool sessions at the same time and
# reports what each session carried.  The point is to tell apart:
#   * "the campus caps the ACCOUNT"  -> each session carries ~1/3 of one cap
#   * "each session has its own cap" -> each session carries a full cap
# which decides whether multi-dial actually adds bandwidth on this line.
set -u

URL="https://test.xidian.edu.cn/backend/garbage.php?r=1&ckSize=100"
SEC=${1:-5}
STREAMS=${2:-4}

snap() {
	for d in pppoe-wan pppoe-wan2 pppoe-wan3; do
		printf '%s ' "$(cat /sys/class/net/$d/statistics/rx_bytes 2>/dev/null || echo 0)"
	done
}

echo "=== per-session test: $STREAMS streams x ${SEC}s on EACH of 3 sessions at once ==="

before=$(snap)
t0=$(date +%s)
for d in pppoe-wan pppoe-wan2 pppoe-wan3; do
	src=$(ip -4 -o addr show dev "$d" 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')
	[ -n "$src" ] || continue
	n=0
	while [ "$n" -lt "$STREAMS" ]; do
		curl -sS -4 --interface "$src" --max-time "$SEC" -o /dev/null \
			"${URL}&r=${d}-${n}" 2>/dev/null &
		n=$((n + 1))
	done
done
wait
t1=$(date +%s)
after=$(snap)

el=$((t1 - t0)); [ "$el" -gt 0 ] || el=1
set -- $before; b1=$1; b2=$2; b3=$3
set -- $after;  a1=$1; a2=$2; a3=$3
d1=$((a1 - b1)); d2=$((a2 - b2)); d3=$((a3 - b3)); tot=$((d1 + d2 + d3))

echo "  pppoe-wan  : $d1 bytes"
echo "  pppoe-wan2 : $d2 bytes"
echo "  pppoe-wan3 : $d3 bytes"
echo "  TOTAL      : $tot bytes in ${el}s"
awk -v a="$d1" -v b="$d2" -v c="$d3" -v t="$tot" -v e="$el" 'BEGIN {
	printf "  per-session: %.1f / %.1f / %.1f Mbps\n", a*8/e/1e6, b*8/e/1e6, c*8/e/1e6
	printf "  AGGREGATE  : %.1f Mbps\n", t*8/e/1e6
}'

echo
echo "=== reference: ONE session alone, $STREAMS streams x ${SEC}s ==="
b0=$(cat /sys/class/net/pppoe-wan/statistics/rx_bytes)
src=$(ip -4 -o addr show dev pppoe-wan 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')
t0=$(date +%s)
n=0
while [ "$n" -lt "$STREAMS" ]; do
	curl -sS -4 --interface "$src" --max-time "$SEC" -o /dev/null "${URL}&r=solo-${n}" 2>/dev/null &
	n=$((n + 1))
done
wait
t1=$(date +%s)
a0=$(cat /sys/class/net/pppoe-wan/statistics/rx_bytes)
el=$((t1 - t0)); [ "$el" -gt 0 ] || el=1
awk -v d="$((a0 - b0))" -v e="$el" 'BEGIN { printf "  single session: %.1f Mbps\n", d*8/e/1e6 }'
