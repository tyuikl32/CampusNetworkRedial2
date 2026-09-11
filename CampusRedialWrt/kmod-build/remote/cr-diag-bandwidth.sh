#!/bin/sh
# A/B bandwidth test: does the connection pool actually add throughput?
#
# A) 4 streams on ONE session
# B) 4 streams on EACH of the three sessions, simultaneously
# Same target, same stream count per session, so the two runs are comparable.
# /proc/loadavg is printed before and after so a CPU-bound result is visible
# (this SoC does TLS in software; 12 parallel TLS streams can saturate it and
# would masquerade as a campus-side cap).
set -u

URL="https://test.xidian.edu.cn/backend/garbage.php"
SEC=${1:-6}
STREAMS=${2:-4}

rx() { cat /sys/class/net/"$1"/statistics/rx_bytes 2>/dev/null || echo 0; }

spawn() { # device, streams, tag
	local d="$1" n="$2" tag="$3" src i=0
	src=$(ip -4 -o addr show dev "$d" 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')
	[ -n "$src" ] || return 0
	while [ "$i" -lt "$n" ]; do
		curl -sS -4 --interface "$src" --max-time "$SEC" -o /dev/null \
			"${URL}?ckSize=100&r=${tag}-${i}" 2>/dev/null &
		i=$((i + 1))
	done
}

mbps() { awk -v b="$1" -v e="$2" 'BEGIN { printf "%.1f", b * 8 / e / 1000000 }'; }

echo "### loadavg before: $(cat /proc/loadavg)"
echo
echo "=== A) ONE session (pppoe-wan), $STREAMS streams, ${SEC}s ==="
b=$(rx pppoe-wan); t0=$(date +%s)
spawn pppoe-wan "$STREAMS" solo
wait
t1=$(date +%s); a=$(rx pppoe-wan)
e=$((t1 - t0)); [ "$e" -gt 0 ] || e=1
echo "  single session: $(mbps $((a - b)) "$e") Mbps  (bytes=$((a - b)))"
echo "  loadavg: $(cat /proc/loadavg)"
echo
echo "=== B) ALL THREE sessions, $STREAMS streams each, ${SEC}s, simultaneous ==="
set -- "$(rx pppoe-wan)" "$(rx pppoe-wan2)" "$(rx pppoe-wan3)"; b1=$1; b2=$2; b3=$3
t0=$(date +%s)
spawn pppoe-wan "$STREAMS" all
spawn pppoe-wan2 "$STREAMS" all
spawn pppoe-wan3 "$STREAMS" all
wait
t1=$(date +%s)
set -- "$(rx pppoe-wan)" "$(rx pppoe-wan2)" "$(rx pppoe-wan3)"; a1=$1; a2=$2; a3=$3
e=$((t1 - t0)); [ "$e" -gt 0 ] || e=1
d1=$((a1 - b1)); d2=$((a2 - b2)); d3=$((a3 - b3)); tot=$((d1 + d2 + d3))
echo "  wan=$(mbps "$d1" "$e")  wan2=$(mbps "$d2" "$e")  wan3=$(mbps "$d3" "$e")  Mbps"
echo "  AGGREGATE: $(mbps "$tot" "$e") Mbps  (bytes=$tot in ${e}s)"
echo "  loadavg: $(cat /proc/loadavg)"
echo
echo "### note: if B << 3 x A with loadavg >> 1, the limit is the router CPU, not the campus."
