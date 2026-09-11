#!/bin/sh
# Stage 2b: exercise macvlan's netdev_ops / netdev_priv on a throwaway device.
# busybox `ip` has no `address` keyword on `ip link add`, so set the MAC after.
# eth1 is expected to fail with EBUSY because it is a bridge port.

echo "=== baseline links ==="
ip -br link | grep -E 'br-lan|eth1|pppoe-wan'

echo
echo "=== A) negative control: macvlan over eth1 (bridge port -> expect EBUSY) ==="
ip link add link eth1 name crtest0 type macvlan mode bridge 2>&1
echo "RC_A=$?"

echo
echo "=== B) macvlan over br-lan (no 'address' keyword - busybox ip lacks it) ==="
ip link add link br-lan name crtest type macvlan mode bridge 2>&1
echo "RC_B=$?"

echo
echo "=== B.1) created? ==="
ip -d link show crtest 2>&1 | head -5

echo
echo "=== B.2) set MAC then bring UP (exercises macvlan_setup + macvlan_open) ==="
ip link set crtest address 02:aa:bb:cc:dd:01 2>&1
echo "RC_MAC=$?"
ip link set crtest up 2>&1
echo "RC_UP=$?"
ip -br link show crtest 2>&1
echo "--- counters read via /sys (proves net_device fields are sane) ---"
for f in mtu addr_len type flags operstate; do printf '  %-10s ' "$f"; cat /sys/class/net/crtest/$f 2>&1 | head -1; done

echo
echo "=== B.3) stats / counters (proves the net_device is fully wired up) ==="
ip -s link show crtest 2>&1 | tail -6
cat /proc/net/dev 2>/dev/null | grep crtest

echo
echo "=== B.4) cleanup ==="
ip link del crtest 2>&1
echo "RC_DEL=$?"
ip -br link show crtest 2>&1 || echo "(crtest gone - good)"
ip link del crtest0 2>&1 || true

echo
echo "=== dmesg (new lines only) ==="
dmesg 2>/dev/null | grep -iE "macvlan|oops|panic|BUG|unable to handle|call trace" | tail -10
echo "(no macvlan/oops line above = clean)"

echo
echo "=== WAN / LAN sanity ==="
ip -4 addr show pppoe-wan 2>/dev/null | grep -m1 inet
ip route | grep -m1 default
ip -4 addr show br-lan 2>/dev/null | grep -m1 inet
ip -br link | grep -E 'br-lan|eth1'
uptime
