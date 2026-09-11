#!/bin/sh
# Campus-redial pool probe.
#
# Question: does the campus BRAS (Huawei ME60-X8A) accept a SECOND concurrent
# PPPoE session for the same account when it arrives from a DIFFERENT source
# MAC?  That single fact decides whether the whole connection-pool feature is
# viable on this line.
#
# Method: one throwaway macvlan on the WAN device carrying eth0's MAC with the
# last byte +1, then one manual pppd dialled exactly the way netifd does it
# (plugin rp-pppoe.so nic-<dev>).  nodefaultroute + no usepeerdns, so routing
# and resolver state are never touched.
#
# Writes NOTHING to flash.  Creates nothing in UCI.  Removes the macvlan and
# kills pppd on exit, whatever happens.  The primary pppoe-wan is only ever
# read, never reconfigured.

set -u

WANDEV=eth0
NEWMAC=a4:39:b3:56:36:8c          # eth0 (a4:39:b3:56:36:8b) last byte +1
MVDEV=crtest0
PPPNIC=crtest-ppp
USERID=<校园网账号-不入库>
PASSWD='<PPPoE密码-不入库>'
LOG=/tmp/cr-pool-probe.log
IPPDIR=/tmp/cr-pool-probe.d

cleanup() {
	pkill -f "nic-$MVDEV" 2>/dev/null || true
	sleep 1
	ip link del "$MVDEV" 2>/dev/null || true
	rm -rf "$IPPDIR" "$LOG"
}

trap 'cleanup' EXIT INT TERM

echo "=== 0. baseline ==="
echo "eth0 mac        : $(cat /sys/class/net/$WANDEV/address)"
echo "eth0 promisc    : $(cat /sys/class/net/$WANDEV/promiscuity)"
ip -4 addr show pppoe-wan 2>/dev/null | grep inet || echo "primary wan     : DOWN"
echo "default routes  :"; ip route | grep '^default'
echo "uptime          : $(cat /proc/uptime | awk '{print $1"s"}')"

echo
echo "=== 1. remove any leftovers ==="
pkill -f "nic-$MVDEV" 2>/dev/null || true
sleep 1
ip link del "$MVDEV" 2>/dev/null || true

echo
echo "=== 2. create macvlan $MVDEV on $WANDEV ($NEWMAC) ==="
if ! ip link add link "$WANDEV" name "$MVDEV" address "$NEWMAC" type macvlan mode bridge 2>/tmp/cr-probe-err; then
	echo "MACVLAN_CREATE_FAILED: $(cat /tmp/cr-probe-err)"
	rm -f /tmp/cr-probe-err
	exit 1
fi
rm -f /tmp/cr-probe-err
ip link set "$MVDEV" up || { echo "MACVLAN_UP_FAILED"; exit 1; }
echo "created mac     : $(cat /sys/class/net/$MVDEV/address)"
echo "parent promisc  : $(cat /sys/class/net/$WANDEV/promiscuity)"
ip -d link show "$MVDEV" | sed -n '2p'

echo
echo "=== 3. dial a second PPPoE session on $MVDEV ==="
rm -rf "$IPPDIR"; mkdir -p "$IPPDIR"
# No-op hooks: this manual pppd is not a netifd interface, so it must never
# call /lib/netifd/ppp-up (that would confuse netifd about its own sessions).
printf '#!/bin/sh\nexit 0\n' > "$IPPDIR/ip-up";   chmod +x "$IPPDIR/ip-up"
printf '#!/bin/sh\nexit 0\n' > "$IPPDIR/ip-down"; chmod +x "$IPPDIR/ip-down"

/usr/sbin/pppd nodetach nodefaultroute noauth maxfail 1 \
	ifname "$PPPNIC" \
	user "$USERID" password "$PASSWD" \
	mtu 1492 mru 1492 \
	ip-up-script "$IPPDIR/ip-up" ip-down-script "$IPPDIR/ip-down" \
	plugin rp-pppoe.so "nic-$MVDEV" \
	>"$LOG" 2>&1 &
PPPD=$!
echo "pppd pid        : $PPPD"

echo
echo "=== 4. wait for negotiation (max 30s) ==="
i=0
while [ "$i" -lt 30 ]; do
	if ip -4 addr show "$PPPNIC" 2>/dev/null | grep -q 'inet '; then
		echo "SECOND SESSION UP after ${i}s"
		break
	fi
	if ! kill -0 "$PPPD" 2>/dev/null; then
		echo "pppd exited after ${i}s"
		break
	fi
	i=$((i + 1))
	sleep 1
done

echo
echo "=== 5. result ==="
ip -4 addr show "$PPPNIC" 2>/dev/null | sed -n '1,4p' || echo "(no $PPPNIC interface)"
echo "--- primary wan (must still be there) ---"
ip -4 addr show pppoe-wan 2>/dev/null | grep inet || echo "PRIMARY WAN GONE"
echo "--- default routes ---"; ip route | grep '^default'
echo "--- interfaces ---"; ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' '; echo
echo "--- pppd log (tail) ---"; tail -25 "$LOG" 2>/dev/null
echo "--- kernel msgs (tail) ---"; dmesg | tail -8

echo
echo "=== 6. teardown ==="
cleanup
trap - EXIT INT TERM
sleep 1
echo "macvlan gone?   : $(ls /sys/class/net/$MVDEV 2>&1 | head -1)"
echo "parent promisc  : $(cat /sys/class/net/$WANDEV/promiscuity)"
ip -4 addr show pppoe-wan 2>/dev/null | grep inet || echo "PRIMARY WAN GONE"
ip route | grep '^default'
echo "interfaces      : $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
echo "uptime          : $(cat /proc/uptime | awk '{print $1"s"}')"
echo "=== DONE ==="
