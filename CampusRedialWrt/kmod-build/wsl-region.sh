#!/bin/bash
A=/opt/kmod-build/linux-5.4.164/include/linux/netdevice.h
B=/opt/kmod-build/linux-ipq-5.4/include/linux/netdevice.h
show() { echo "########## $2 : ingress_queue -> pcpu_refcnt ##########"; awk '/ingress_queue;/{p=1} p{print} /pcpu_refcnt;/{if(p)exit}' "$1" | sed 's/^/  /'; echo; }
show "$A" UPSTREAM
show "$B" QSDK
