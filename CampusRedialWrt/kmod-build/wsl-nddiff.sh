#!/bin/bash
A=/opt/kmod-build/linux-5.4.164/include/linux/netdevice.h
B=/opt/kmod-build/linux-ipq-5.4/include/linux/netdevice.h
extract() { awk '/^struct net_device \{/{p=1} p{print} p&&/^\};/{exit}' "$1"; }
extract "$A" > /tmp/nd.up
extract "$B" > /tmp/nd.qsdk
echo "upstream struct net_device lines: $(wc -l < /tmp/nd.up)   QSDK: $(wc -l < /tmp/nd.qsdk)"
echo
echo "================= unified diff of struct net_device ================="
diff -u /tmp/nd.up /tmp/nd.qsdk
