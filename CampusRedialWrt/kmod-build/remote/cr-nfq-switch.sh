#!/bin/sh
# cr-nfq-switch.sh -- switch zapret between tpws (userspace proxy) and nfqws
# (kernel fast path, only the first packets per connection go to userspace).
#
# Usage on device:
#   sh /tmp/cr-nfq-switch.sh status
#   sh /tmp/cr-nfq-switch.sh on       # tpws -> nfqws  (needs the two modules loaded)
#   sh /tmp/cr-nfq-switch.sh off      # nfqws -> tpws  (rollback)
#
# Order matters -- the documented black hole (memory/2026-09-10-sni-stop-blackhole.md):
# the tpws nat jump grabs ALL LAN 80/443 and must be removed BEFORE tpws dies,
# and /var/run/zapret.off must exist meanwhile so an fw3 reload cannot put it back.
set -u

CONF=/opt/zapret/config
BAK=/opt/zapret/config.tpws.bak
OFFFLAG=/var/run/zapret.off
LIST=/opt/zapret/ipset/zapret-hosts-user.txt

MARK() { echo; echo "===== $* ====="; }

detect_wans() {
	local i out=
	for i in $(ubus list 'network.interface.*' 2>/dev/null | sed 's/^network\.interface\.//'); do
		case "$i" in wan|wan[0-9]|wan[0-9][0-9]) out="$out $i" ;; esac
	done
	echo "$out" | sed 's/^ //'
}

write_nfqws_conf() {
	local wans="$1"
	cat > "$CONF" <<EOF
# nfqws mode (kernel NFQUEUE, self-built modules) -- written by cr-nfq-switch.sh
# Only the first NFQWS_TCP_PKT_OUT/IN packets of a connection enter userspace;
# bulk payload (both directions) stays in the kernel fast path.
DISABLE_IPV4=0
DISABLE_IPV6=1
NFQWS_ENABLE=1
TPWS_ENABLE=0
TPWS_SOCKS_ENABLE=0
NFQWS_PORTS_TCP=80,443
NFQWS_PORTS_UDP=443
NFQWS_TCP_PKT_OUT=6
NFQWS_TCP_PKT_IN=3
NFQWS_UDP_PKT_OUT=6
NFQWS_UDP_PKT_IN=0
NFQWS_OPT="
--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig <HOSTLIST> --new
--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig <HOSTLIST> --new
--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO>
"
MODE_FILTER=hostlist
# all pool sessions, explicit: netifd only installs a default route for the
# primary PPPoE, so automatic WAN discovery is not trusted here
OPENWRT_WAN4="$wans"
FLOWOFFLOAD=donttouch
EOF
	echo "  wrote $CONF with OPENWRT_WAN4=\"$wans\""
}

report() {
	MARK "state"
	echo "  zapret service   : $(/etc/init.d/zapret status 2>&1 | head -1)"
	echo "  mode in config   : $(grep -E '^(NFQWS_ENABLE|TPWS_ENABLE)=' "$CONF" | tr '\n' ' ')"
	echo "  mode filter      : $(grep -E '^MODE_FILTER=' "$CONF")"
	echo "  hostlist entries : $(grep -c . "$LIST" 2>/dev/null)  (0 = every host is desynced)"
	echo "  daemons          : $(ps w | grep -E '[t]pws|[n]fqws' | sed 's/^ *//' | cut -c1-110)"
	echo "  off-flag         : $([ -e "$OFFFLAG" ] && echo PRESENT || echo absent)"
	MARK "tpws nat jump (must be 0 when nfqws is on)"
	iptables -t nat -S PREROUTING | grep -c 988 | sed 's/^/  DNAT-to-988 rules: /'
	MARK "nfqws NFQUEUE rules in mangle POSTROUTING"
	iptables -t mangle -S POSTROUTING | grep NFQUEUE | sed 's/^/  /'
	echo "  rule count: $(iptables -t mangle -S POSTROUTING | grep -c NFQUEUE)"
	MARK "network"
	ip route | grep -m3 default | sed 's/^/  /'
	ping -c2 -W3 223.5.5.5 2>&1 | tail -2 | sed 's/^/  /'
	echo "  uptime: $(cut -d' ' -f1 /proc/uptime) s   tainted: $(cat /proc/sys/kernel/tainted)"
}

stop_everything_safely() {
	touch "$OFFFLAG"
	/etc/init.d/zapret stop_fw >/dev/null 2>&1
	echo "  stop_fw rc=$?  (nat 988 rules left: $(iptables -t nat -S | grep -cF -- '--to-destination 127.0.0.127:988'))"
	sweep_tpws_rules
	/etc/init.d/zapret stop >/dev/null 2>&1
	echo "  stop rc=$?"
	sleep 1
}

sweep_tpws_rules() {
	# zapret enumerates only the WAN devices that exist RIGHT NOW, so a rule for a
	# pool session that is DOWN at switch time survives stop_fw.  With tpws gone
	# that leftover turns into a black hole the moment the session comes back
	# (measured for real on 2026-09-11: a stale "-A OUTPUT -o pppoe-wan5 ... DNAT
	# --to-destination 127.0.0.127:988" was left behind while wan5 was down).
	local chain spec n=0
	for chain in PREROUTING OUTPUT; do
		iptables -t nat -S "$chain" 2>/dev/null | grep -F -- '--to-destination 127.0.0.127:988' | \
		while read -r spec; do
			spec=${spec#-A "$chain" }
			iptables -t nat -D "$chain" $spec && echo "  swept stale rule: $chain $spec"
		done
	done
	echo "  sweep done, 988 rules now: $(iptables -t nat -S | grep -cF -- '--to-destination 127.0.0.127:988')"
}

start_everything() {
	rm -f "$OFFFLAG"
	/etc/init.d/zapret start >/dev/null 2>&1
	echo "  start rc=$?"
	sleep 1
	/etc/init.d/zapret start_fw >/dev/null 2>&1
	echo "  start_fw rc=$?"
	sleep 1
}

case "${1:-status}" in
	on)
		MARK "preflight"
		[ -f /tmp/nfnetlink_queue.ko ] || { echo "FATAL /tmp/nfnetlink_queue.ko missing"; exit 1; }
		lsmod | grep -q '^nfnetlink_queue ' || { echo "FATAL nfnetlink_queue not loaded"; exit 1; }
		lsmod | grep -q '^xt_NFQUEUE '      || { echo "FATAL xt_NFQUEUE not loaded"; exit 1; }
		grep -qi nfqueue /proc/net/ip_tables_targets || { echo "FATAL no NFQUEUE target"; exit 1; }
		[ -x /opt/zapret/nfq/nfqws ] || { echo "FATAL nfqws binary missing"; exit 1; }
		echo "  modules + nfqws binary present"
		cp -f "$CONF" "$BAK"; echo "  backup: $BAK ($(wc -c < "$BAK") bytes)"
		wans=$(detect_wans); echo "  detected WAN sessions: $wans"
		MARK "switch tpws -> nfqws"
		stop_everything_safely
		write_nfqws_conf "$wans"
		start_everything
		report
		;;
	off)
		MARK "rollback nfqws -> tpws"
		[ -f "$BAK" ] || { echo "FATAL backup $BAK missing"; exit 1; }
		stop_everything_safely
		cp -f "$BAK" "$CONF"; echo "  restored $CONF from $BAK"
		start_everything
		report
		;;
	status)
		report
		;;
	*)
		echo "usage: $0 {status|on|off}"; exit 2 ;;
esac
echo
echo "===== done ====="
