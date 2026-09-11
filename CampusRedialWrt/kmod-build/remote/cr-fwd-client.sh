#!/bin/sh
# cr-fwd-client.sh -- generate genuine FORWARDED traffic on the router itself.
#
# Why this exists: tpws's nat jump matches "-i br-lan" and nfqws's rules match the
# WAN devices, so router-local traffic only exercises the OUTPUT/POSTROUTING
# half of the picture.  This harness builds a real client that the router
# FORWARDS for, so the mangle FORWARD chain (inbound NFQUEUE rules) is hit too.
#
# Topology (all created on the fly, nothing written to flash):
#
#   netns "crns"                         root namespace
#   crns0 10.9.9.2/24  --L2-->  crgw0 10.9.9.1/24
#        (macvlan on br-lan)      (macvlan on br-lan, default gw for the client)
#                                        |
#                                   routed -> FORWARD -> POSTROUTING -> pppoe-wanN
#
# Two macvlan children of br-lan CAN talk to each other (macvlan bridge mode
# hashes between siblings).  A child can NOT talk to its parent br-lan itself,
# which is why the gateway is a second child on a SEPARATE subnet (10.9.9.0/24)
# instead of br-lan's own 192.168.6.1 -- a /24 route on crgw0 would otherwise
# fight with br-lan's route for 192.168.6.0/24 on the return path.
#
# Usage:  sh /tmp/cr-fwd-client.sh up | check | down
set -u

NS=crns
CDEV=crns0
GDEV=crgw0
CIP=10.9.9.2
GIP=10.9.9.1
PFX=24
TESTIP=202.117.124.253          # test.xidian.edu.cn (campus HTTP bulk server)
URLPATH="/backend/garbage.php"

ns() { ip netns exec "$NS" "$@"; }

up() {
	down >/dev/null 2>&1
	ip link add link br-lan name "$GDEV" type macvlan mode bridge || return 1
	ip addr add "$GIP/$PFX" dev "$GDEV"
	ip link set "$GDEV" up
	ip netns add "$NS" || return 1
	ip link add link br-lan name "$CDEV" type macvlan mode bridge || return 1
	ip link set "$CDEV" netns "$NS" || return 1
	ns ip link set lo up
	ns ip link set "$CDEV" up
	ns ip addr add "$CIP/$PFX" dev "$CDEV"
	ns ip route add default via "$GIP"
	mkdir -p "/etc/netns/$NS"
	printf 'nameserver 223.5.5.5\n' > "/etc/netns/$NS/resolv.conf"
	# unzoned interface -> fw3's FORWARD policy would drop it; masquerade for a
	# source outside the lan zone.  Both are temporary and removed by "down".
	iptables -I FORWARD 1 -i "$GDEV" -j ACCEPT
	iptables -I FORWARD 1 -o "$GDEV" -j ACCEPT
	iptables -t nat -I POSTROUTING 1 -s "10.9.9.0/24" -j MASQUERADE
	echo "  client $CIP/$PFX via $GIP (root-ns $GDEV on br-lan)"
	ns ip -4 -o addr show dev "$CDEV" | awk '{print "  "$2" "$4}'
	ns ip route | sed 's/^/  /'
	ip -4 -o addr show dev "$GDEV" | awk '{print "  gw: "$2" "$4}'
}

down() {
	iptables -D FORWARD -i "$GDEV" -j ACCEPT 2>/dev/null
	iptables -D FORWARD -o "$GDEV" -j ACCEPT 2>/dev/null
	iptables -t nat -D POSTROUTING -s "10.9.9.0/24" -j MASQUERADE 2>/dev/null
	ip netns del "$NS" 2>/dev/null
	ip link del "$CDEV" 2>/dev/null
	ip link del "$GDEV" 2>/dev/null
	rm -rf "/etc/netns/$NS"
	echo "  harness removed (macvlans, netns, 3 temp iptables rules)"
}

counters() {
	local f i o
	f=$(iptables -t mangle -L FORWARD -v -n 2>/dev/null | awk '/NFQUEUE/{s+=$1} END{print s+0}')
	i=$(iptables -t mangle -L INPUT -v -n 2>/dev/null | awk '/NFQUEUE/{s+=$1} END{print s+0}')
	o=$(iptables -t mangle -L POSTROUTING -v -n 2>/dev/null | awk '/NFQUEUE/{s+=$1} END{print s+0}')
	echo "$f $i $o"
}

sum_rx() {
	local t=0 v
	for w in pppoe-wan pppoe-wan2 pppoe-wan3 pppoe-wan4 pppoe-wan5; do
		[ -e "/sys/class/net/$w/statistics/rx_bytes" ] || continue
		v=$(cat "/sys/class/net/$w/statistics/rx_bytes"); t=$((t + v))
	done
	echo "$t"
}

test_run() {
	SEC=${1:-8}
	STREAMS=${2:-16}
	echo "  mode: $(grep -E '^(NFQWS_ENABLE|TPWS_ENABLE)=' /opt/zapret/config | tr '\n' ' ')"
	set -- $(counters); f0=$1; i0=$2; o0=$3
	# baseline rx per session so the per-session split can be shown
	set -- $(for w in pppoe-wan pppoe-wan2 pppoe-wan3 pppoe-wan4 pppoe-wan5; do
		[ -e "/sys/class/net/$w/statistics/rx_bytes" ] && cat "/sys/class/net/$w/statistics/rx_bytes" || echo 0; done)
	b1=$1; b2=$2; b3=$3; b4=$4; b5=$5
	b=$(sum_rx); t0=$(date +%s)
	i=0
	while [ "$i" -lt "$STREAMS" ]; do
		ns curl -sS -4 --max-time "$SEC" -o /dev/null "http://$TESTIP$URLPATH?ckSize=100&r=fwd${i}" 2>/dev/null &
		i=$((i + 1))
	done
	wait
	t1=$(date +%s); a=$(sum_rx); e=$((t1 - t0)); [ "$e" -gt 0 ] || e=1
	set -- $(for w in pppoe-wan pppoe-wan2 pppoe-wan3 pppoe-wan4 pppoe-wan5; do
		[ -e "/sys/class/net/$w/statistics/rx_bytes" ] && cat "/sys/class/net/$w/statistics/rx_bytes" || echo 0; done)
	a1=$1; a2=$2; a3=$3; a4=$4; a5=$5
	echo "  loadavg: $(cat /proc/loadavg)"
	for pair in "$b1:$a1:wan" "$b2:$a2:wan2" "$b3:$a3:wan3" "$b4:$a4:wan4" "$b5:$a5:wan5"; do
		bb=${pair%%:*}; rest=${pair#*:}; aa=${rest%%:*}; nm=${rest#*:}
		d=$((aa - bb)); [ "$d" -lt 0 ] && d=0
		printf '    %-5s %8.2f Mbps\n' "$nm" "$(awk -v x="$d" -v t="$e" 'BEGIN{printf "%.2f", x*8/t/1000000}')"
	done
	printf '  AGGREGATE (forwarded): %.2f Mbps in %ss\n' \
		"$(awk -v x="$((a - b))" -v t="$e" 'BEGIN{printf "%.2f", x*8/t/1000000}')" "$e"
	set -- $(counters); f1=$1; i1=$2; o1=$3
	echo "  NFQUEUE deltas: FORWARD=$((f1-f0)) POSTROUTING=$((o1-o0))"
	echo "  nat 988 hits in PREROUTING: $(iptables -t nat -L PREROUTING -v -n 2>/dev/null | awk '/988/{s+=$1} END{print s+0}')"
}


check() {
	echo "=== L3 from the client (gw, internet) ==="
	ns ping -c2 -W3 "$GIP" 2>&1 | tail -2 | sed 's/^/  gw: /'
	ns ping -c2 -W3 223.5.5.5 2>&1 | tail -2 | sed 's/^/  inet: /'
	echo "=== forwarded HTTP download (no TLS: the router only forwards) ==="
	set -- $(counters); f0=$1; i0=$2; o0=$3
	ns curl -sS -4 --max-time 15 -o /dev/null \
		-w "  http=%{http_code} avg=%{speed_download}B/s ip=%{remote_ip}\n" \
		"http://$TESTIP$URLPATH?ckSize=50&r=fwdcheck" 2>&1
	set -- $(counters); f1=$1; i1=$2; o1=$3
	echo "  NFQUEUE deltas: FORWARD=$((f1-f0)) (inbound replies) INPUT=$((i1-i0)) POSTROUTING=$((o1-o0)) (outbound)"
	echo "=== conntrack for the client (mark shows the desync bit 0x40000000) ==="
	grep -E "src=10\.9\.9\.2 " /proc/net/nf_conntrack 2>/dev/null | tail -4 | sed 's/^/  /'
	echo "=== wan egress balance: mwan3 status for this source ==="
	grep -c . /proc/net/nf_conntrack >/dev/null
	ip neigh show dev "$GDEV" | sed 's/^/  neigh: /'
}

case "${1:-status}" in
	up)     up ;;
	down)   down ;;
	check)  check ;;
	test)   shift; test_run "$@" ;;
	status) ip netns list 2>/dev/null; ip -4 -o addr show "$GDEV" 2>/dev/null; ns ip -4 -o addr show 2>/dev/null ;;
	*)      echo "usage: $0 {up|check|test <sec> <streams>|down|status}"; exit 2 ;;
esac
