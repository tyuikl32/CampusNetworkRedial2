#!/bin/sh
# Persist the self-built modules.  THIS WRITES TO FLASH (overlay).
# Rollback: rm /lib/modules/5.4.164/macvlan.ko /lib/modules/5.4.164/xt_statistic.ko
#           rm /etc/modules.d/30-macvlan /etc/modules.d/55-xt-statistic
#           rmmod macvlan xt_statistic

echo "=== 1) install .ko into /lib/modules/5.4.164 ==="
cp /tmp/macvlan.ko    /lib/modules/5.4.164/macvlan.ko
echo "cp macvlan    RC=$?"
cp /tmp/xt_statistic.ko /lib/modules/5.4.164/xt_statistic.ko
echo "cp xt_statistic RC=$?"
ls -la /lib/modules/5.4.164/macvlan.ko /lib/modules/5.4.164/xt_statistic.ko
sha256sum /lib/modules/5.4.164/macvlan.ko /lib/modules/5.4.164/xt_statistic.ko

echo
echo "=== 2) autoload entries (/etc/modules.d) ==="
printf 'macvlan\n'     > /etc/modules.d/30-macvlan
printf 'xt_statistic\n' > /etc/modules.d/55-xt-statistic
ls -la /etc/modules.d/30-macvlan /etc/modules.d/55-xt-statistic
cat /etc/modules.d/30-macvlan /etc/modules.d/55-xt-statistic

echo
echo "=== 3) load by NAME, exactly like boot does (kmodloader) ==="
modprobe macvlan;       echo "modprobe macvlan       RC=$?"
modprobe xt_statistic;  echo "modprobe xt_statistic  RC=$?"
lsmod 2>/dev/null | grep -E 'macvlan|xt_statistic'

echo
echo "=== 4) corrected ip argument order test (address BEFORE type) ==="
ip link add link br-lan name crtest address 02:aa:bb:cc:dd:01 type macvlan mode bridge
echo "RC_ADD=$?"
ip -d link show crtest 2>&1 | head -3
ip link set crtest up 2>&1; echo "RC_UP=$?"
ip -br link show crtest 2>&1
ip link del crtest 2>&1; echo "RC_DEL=$?"

echo
echo "=== 5) dmesg ==="
dmesg 2>/dev/null | tail -8

echo
echo "=== 6) sanity ==="
ip -4 addr show pppoe-wan 2>/dev/null | grep -m1 inet
ip route 2>/dev/null | grep -m1 default
ip -4 addr show br-lan 2>/dev/null | grep -m1 inet
df -h /overlay 2>/dev/null | tail -1
uptime
