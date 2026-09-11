#!/bin/bash
# nd-cond.sh - every conditionally-compiled field of struct net_device in this
# tree, with the surrounding #ifdef, so we can match the sizes/places of the
# vendor's extra 64 bytes against the symbols our .config lost.
export LC_ALL=C
set -u
cd /opt/kmod-build/linux-5.4.164
awk '/^struct net_device \{/,/^\};/' include/linux/netdevice.h \
  | awk '
    /^#if/ || /^#ifdef/ || /^#ifndef/ || /^#else/ || /^#elif/ || /^#endif/ { printf "%4d | %s\n", NR, $0; next }
    /^[[:space:]]*[A-Za-z_].*;[[:space:]]*$/ { printf "%4d |      %s\n", NR, $0 }
  ' | sed -n '1,240p'
