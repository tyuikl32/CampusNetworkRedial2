#!/bin/sh
# Kill all leftover campus-rediald wrappers and restart via procd.
for p in $(ps w 2>/dev/null | grep campus-rediald | grep -v grep | awk '{print $1}'); do
    kill -9 $p 2>/dev/null
done
sleep 1
rm -f /var/run/campus-redial/daemon.pid /var/run/campus-redial/control
echo remaining-after-kill:
ps w | grep campus-rediald | grep -v grep