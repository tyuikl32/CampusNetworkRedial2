#!/bin/sh
# Stage 1: load the self-built macvlan.ko and report state.  No writes outside /tmp.
echo "=== which insmod ==="
which insmod 2>&1 || echo "(busybox insmod not in PATH)"

echo "=== insmod ==="
insmod /tmp/macvlan.ko
echo "INSMOD_RC=$?"

echo "=== lsmod ==="
lsmod 2>/dev/null | grep -i macvlan || echo "(macvlan not in lsmod)"

echo "=== sysfs ==="
ls -d /sys/module/macvlan 2>&1
cat /sys/module/macvlan/refcnt 2>/dev/null

echo "=== dmesg tail ==="
dmesg 2>/dev/null | tail -25

echo "=== uptime ==="
uptime
