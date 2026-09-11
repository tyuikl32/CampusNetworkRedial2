#!/bin/sh
# cr-nfq-ab.sh <seconds> <streams> [url]
#
# Aggregate download A/B for the SNI-desync path, measured on the box itself.
#
# Which path is being measured?  Both desync implementations DO see this traffic:
#   * tpws  : zapret installs nat OUTPUT DNAT rules per WAN device
#             (-o pppoe-wanN -m owner ! --uid-owner 1 ... -j DNAT --to 127.0.0.127:988),
#             so router-local 80/443 goes through the userspace proxy too.
#   * nfqws : mangle POSTROUTING rules match -o pppoe-wanN, which local output
#             traverses as well.
# So the same client and the same target give a fair tpws-vs-nfqws comparison.
# (A LAN client hits tpws via PREROUTING instead of OUTPUT -- both end up as
#  local delivery to tpws's socket, i.e. identical proxy work.)
#
# Aggregate is the sum of rx_bytes over ALL pppoe-wan* devices, so mwan3's
# balancing across the pool is included.  CPU of tpws/nfqws is sampled
# before/after: utime+stime in clock ticks (100/s) => "ticks/s" shows how much
# of a core the desync path burns.
set -u

SEC=${1:-8}
STREAMS=${2:-12}
URL=${3:-"https://test.xidian.edu.cn/backend/garbage.php"}
WANS="pppoe-wan pppoe-wan2 pppoe-wan3 pppoe-wan4 pppoe-wan5"

sum_rx() {
	local t=0 v
	for w in $WANS; do
		[ -e "/sys/class/net/$w/statistics/rx_bytes" ] || continue
		v=$(cat "/sys/class/net/$w/statistics/rx_bytes")
		t=$((t + v))
	done
	echo "$t"
}
per_rx() {
	local out=""
	for w in $WANS; do
		[ -e "/sys/class/net/$w/statistics/rx_bytes" ] || continue
		out="$out ${w#pppoe-}:$(cat /sys/class/net/$w/statistics/rx_bytes)"
	done
	echo "$out"
}
desync_cpu() { # prints "name pid ticks" for tpws and nfqws
	for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
		cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
		case "$cmd" in
			*tpws*|*nfqws*)
				set -- $(cut -d')' -f2- "/proc/$p/stat" 2>/dev/null | awk '{print $12, $13}')
				[ -n "${1:-}" ] && echo "$(basename "${cmd%% *}") $p $(( $1 + $2 ))"
				;;
		esac
	done
}

echo "### mode: $(grep -E '^(NFQWS_ENABLE|TPWS_ENABLE|MODE_FILTER)=' /opt/zapret/config | tr '\n' ' ')"
echo "### hostlist entries: $(grep -c . /opt/zapret/ipset/zapret-hosts-user.txt 2>/dev/null) (0 = every host desynced)"
echo "### desync daemons (name pid ticks): $(desync_cpu | tr '\n' ' ')"
echo "### sanity: one stream, 5 s"
curl -sS -4 --noproxy '*' --max-time 12 -o /dev/null \
	-w '  http=%{http_code} avg=%{speed_download}B/s\n' "${URL}?ckSize=20&r=sanity" 2>&1
echo
echo "### A/B run: $STREAMS streams, ${SEC}s"
c0=$(desync_cpu)
b=$(sum_rx); bp=$(per_rx)
t0=$(date +%s)
i=0
while [ "$i" -lt "$STREAMS" ]; do
	curl -sS -4 --noproxy '*' --max-time "$SEC" -o /dev/null "${URL}?ckSize=100&r=ab${i}" 2>/dev/null &
	i=$((i + 1))
done
wait
t1=$(date +%s)
a=$(sum_rx); ap=$(per_rx)
e=$((t1 - t0)); [ "$e" -gt 0 ] || e=1
d=$((a - b))
echo "  loadavg: $(cat /proc/loadavg)"
echo "  delta:   $d bytes in ${e}s"
echo "  per-wan rx:"
for w in $WANS; do
	n=${w#pppoe-}
	bb=$(echo "$bp" | tr ' ' '\n' | grep "^$n:" | cut -d: -f2)
	aa=$(echo "$ap" | tr ' ' '\n' | grep "^$n:" | cut -d: -f2)
	[ -n "$bb" ] || continue
	[ -n "$aa" ] || aa=0
	pd=$((aa - bb)); [ "$pd" -lt 0 ] && pd=0
	printf '    %-6s %8.2f Mbps\n' "$n" "$(awk -v x="$pd" -v t="$e" 'BEGIN{printf "%.2f", x*8/t/1000000}')"
done
printf '  AGGREGATE: %.2f Mbps\n' "$(awk -v x="$d" -v t="$e" 'BEGIN{printf "%.2f", x*8/t/1000000}')"
echo "  iptables counters:"
echo "    nat PREROUTING 988 hits : $(iptables -t nat -L PREROUTING -v -n 2>/dev/null | awk '/988/{s+=$1} END{print s+0}')"
echo "    nat OUTPUT     988 hits : $(iptables -t nat -L OUTPUT -v -n 2>/dev/null | awk '/988/{s+=$1} END{print s+0}')"
echo "    mangle POSTROUTING NFQUEUE pkts: $(iptables -t mangle -L POSTROUTING -v -n 2>/dev/null | awk '/NFQUEUE/{s+=$1} END{print s+0}')"
c1=$(desync_cpu)
echo "  daemon CPU over the run (ticks = 1/100 s):"
echo "    before: $c0"
echo "    after : $c1"
echo "  (delta per daemon, ticks/s of wall clock => fraction of one core)"
awk -v b="$c0" -v a="$c1" -v e="$e" 'BEGIN{
	n=split(b,B," "); m=split(a,A," ");
	for(i=1;i<=n;i+=3){ name=B[i]; pid=B[i+1]; bt=B[i+2];
		for(j=1;j<=m;j+=3) if(A[j]==name && A[j+1]==pid) {
			d=A[j+2]-bt;
			printf "    %-8s pid=%-6s %6d ticks / %ss = %5.2f ticks/s (%.0f%% of one core)\n", name, pid, d, e, d/e, d/e;
		}
	}'
echo "  tainted: $(cat /proc/sys/kernel/tainted)   uptime: $(cut -d' ' -f1 /proc/uptime)s"
