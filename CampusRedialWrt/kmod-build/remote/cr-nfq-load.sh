#!/bin/sh
# cr-nfq-load.sh -- minimal NFQUEUE validation on the AX3000.
#
# Discipline (same as the macvlan bring-up): insmod from /tmp only, NO flash
# writes, everything reversible by "rmmod xt_NFQUEUE nfnetlink_queue" or a reboot.
#
# Usage on device:  sh /tmp/cr-nfq-load.sh <nfnetlink_queue.ko.sha256> <xt_NFQUEUE.ko.sha256>
#
# Checks, in order:
#   1. uploaded artifacts match their expected sha256
#   2. baseline: no NFQUEUE target, modules not loaded, taint value
#   3. insmod nfnetlink_queue.ko  -> rc / lsmod / dmesg
#   4. insmod xt_NFQUEUE.ko       -> rc / lsmod / /proc/net/ip_tables_targets
#   5. iptables can build a NFQUEUE rule (libxt_NFQUEUE.so via XTABLES_LIBDIR=/tmp/xtlib)
#   6. nfqws binary actually runs on this ARM box
#   7. network sanity: default route, pppoe-wan, ping, uptime unchanged
set -u

EXP_NFQ="${1:-}"
EXP_XT="${2:-}"

MARK() { echo; echo "===== $* ====="; }
RC()   { echo "  rc=$1"; }

MARK "0. artifacts"
for f in /tmp/nfnetlink_queue.ko /tmp/xt_NFQUEUE.ko /tmp/libxt_NFQUEUE.so; do
	if [ -f "$f" ]; then
		printf '  %-30s %s  %s bytes\n' "$f" "$(sha256sum "$f" | cut -c1-16)" "$(wc -c < "$f")"
	else
		echo "  MISSING $f"
	fi
done
[ -n "$EXP_NFQ" ] && { got=$(sha256sum /tmp/nfnetlink_queue.ko | cut -d' ' -f1); [ "$got" = "$EXP_NFQ" ] && echo "  nfnetlink_queue.ko sha256 MATCH" || echo "  !! nfnetlink_queue.ko sha256 MISMATCH ($got)"; }
[ -n "$EXP_XT" ]  && { got=$(sha256sum /tmp/xt_NFQUEUE.ko    | cut -d' ' -f1); [ "$got" = "$EXP_XT" ]  && echo "  xt_NFQUEUE.ko sha256 MATCH"      || echo "  !! xt_NFQUEUE.ko sha256 MISMATCH ($got)"; }

MARK "1. baseline"
echo "  NFQUEUE in /proc/net/ip_tables_targets : $(grep -ci nfqueue /proc/net/ip_tables_targets)"
echo "  lsmod nfnetlink_queue / xt_NFQUEUE     : $(lsmod | grep -c -E '^(nfnetlink_queue|xt_NFQUEUE)')"
echo "  tainted                                : $(cat /proc/sys/kernel/tainted)"
echo "  kernel oops lines in dmesg so far      : $(dmesg | grep -ci -E 'oops|BUG:|Call trace')"
echo "  uptime                                 : $(cut -d' ' -f1 /proc/uptime) s"

MARK "2. insmod nfnetlink_queue.ko"
insmod /tmp/nfnetlink_queue.ko; RC $?
lsmod | grep -E '^(nfnetlink_queue|nfnetlink) ' || echo "  (not in lsmod)"

MARK "3. insmod xt_NFQUEUE.ko"
insmod /tmp/xt_NFQUEUE.ko; RC $?
lsmod | grep -E '^xt_NFQUEUE ' || echo "  (not in lsmod)"
echo "  NFQUEUE in /proc/net/ip_tables_targets : $(grep -ci nfqueue /proc/net/ip_tables_targets)"
grep -i nfqueue /proc/net/ip_tables_targets | sed 's/^/    /'

MARK "4. kernel log tail (look for oops / Unknown symbol)"
dmesg | tail -12 | sed 's/^/  /'
echo "  tainted now : $(cat /proc/sys/kernel/tainted)   (128 = an oops happened at some point)"

MARK "5. iptables NFQUEUE rule (userspace lib via XTABLES_LIBDIR)"
mkdir -p /tmp/xtlib
cp -f /tmp/libxt_NFQUEUE.so /tmp/xtlib/ 2>/dev/null
XTABLES_LIBDIR=/tmp/xtlib iptables -t mangle -N CRNFQT; RC $?
XTABLES_LIBDIR=/tmp/xtlib iptables -t mangle -A CRNFQT -j NFQUEUE --queue-num 200 --queue-bypass; RC $?
XTABLES_LIBDIR=/tmp/xtlib iptables -t mangle -S CRNFQT | sed 's/^/  /'
XTABLES_LIBDIR=/tmp/xtlib iptables -t mangle -F CRNFQT
XTABLES_LIBDIR=/tmp/xtlib iptables -t mangle -X CRNFQT
echo "  cleanup rc=$?  (chain removed)"

MARK "6. nfqws binary runs"
/opt/zapret/nfq/nfqws --help >/tmp/nfqws-help.txt 2>&1; RC $?
head -3 /tmp/nfqws-help.txt | sed 's/^/  /'
echo "  version: $(grep -m1 -i 'version' /tmp/nfqws-help.txt)"

MARK "7. network sanity"
ip route | grep -m3 default | sed 's/^/  /'
ip -4 -o addr show pppoe-wan 2>/dev/null | awk '{print "  pppoe-wan "$4}'
ping -c2 -W3 223.5.5.5 2>&1 | tail -2 | sed 's/^/  /'
echo "  uptime                                 : $(cut -d' ' -f1 /proc/uptime) s"
echo "  zapret service                         : $(/etc/init.d/zapret status 2>&1 | head -1)"

MARK "done (modules are LOADED but nothing uses them yet; nothing was written to flash)"
echo "rollback: rmmod xt_NFQUEUE; rmmod nfnetlink_queue"
