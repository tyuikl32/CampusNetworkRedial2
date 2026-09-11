#!/bin/sh
# Read-only probe for the three fixes: mwan3 route persistence, daemon config
# sanity, and the LuCI wide-layout rendering question.  Touches nothing.
echo '=== A. routing tables ==='
echo -n 'main default count: '; ip route show table main | grep -c '^default'
echo '--- main defaults ---'; ip route show table main | grep '^default'
for t in 1 5 6; do echo "--- table $t ---"; ip route show table $t 2>/dev/null || echo '(empty)'; done
echo
echo '=== B. mwan3 uci (owned sections) ==='
uci show mwan3 2>/dev/null | grep -E '^mwan3\.(globals|wan|wan2|wan3|cr_)' | head -60
echo
echo '=== C. network session options ==='
for s in wan wan2 wan3; do echo "--- network.$s ---"; uci show network.$s 2>/dev/null; done
echo '--- device sections ---'
uci show network 2>/dev/null | grep -E 'campus_.*_device|\.type=|\.ip4table' | head -20
echo
echo '=== D. ppp proto: does it add a default route / honour ip4table? ==='
grep -n 'proto_add_ipv4_route\|defaultroute\|ip4table\|ip6table' /lib/netifd/proto/ppp.sh 2>/dev/null || echo '(no matches)'
echo
echo '=== E. netifd route table handling ==='
grep -rn 'ip4table' /lib/netifd/*.sh /sbin/ifup 2>/dev/null | head || echo '(none)'
echo
echo '=== F. campus-redial config ==='
uci show campus-redial 2>/dev/null | grep -vE 'password|username' | head -40
echo '--- passwords set? (presence only) ---'
for s in $(uci show campus-redial 2>/dev/null | sed -n "s/^campus-redial\.\([^.]*\)=account$/\1/p"); do
  u=$(uci -q get campus-redial.$s.username)
  p=$(uci -q get campus-redial.$s.password)
  echo "  $s: user=$u pass_len=${#p} enabled=$(uci -q get campus-redial.$s.enabled) max=$(uci -q get campus-redial.$s.max_connections)"
done
echo
echo '=== G. runtime status files ==='
ls -l /var/run/campus-redial/ 2>/dev/null | head -30
echo '--- speed values ---'
for f in /var/run/campus-redial/speed.*.value; do [ -f "$f" ] && echo "  $f = $(cat $f)"; done
echo '--- status.json head ---'
head -c 800 /var/run/campus-redial/status.json 2>/dev/null; echo
echo
echo '=== H. luci themes installed ==='
opkg list-installed 2>/dev/null | grep -i 'luci-theme\|^luci ' | head
echo '--- /etc/config/luci ---'
cat /etc/config/luci 2>/dev/null | grep -vE '^\s*$' | head -20
echo
echo '=== I. theme css files ==='
for d in /www/luci-static/*/; do echo "  $d"; ls "$d" 2>/dev/null | head -10; done
echo
echo '=== J. cbi-section-table CSS rules (with context) ==='
for f in /www/luci-static/bootstrap/cascade.css /www/luci-static/*/cascade.css; do
  [ -f "$f" ] || continue
  echo "--- $f ($(wc -c < $f) bytes, $(grep -c cbi-section-table $f) hits) ---"
done
echo
echo '=== K. media queries in theme css ==='
grep -o '@media[^{]*{[^}]*' /www/luci-static/bootstrap/cascade.css 2>/dev/null | head -5
grep -oh '@media screen and (max-width[^)]*)' /www/luci-static/*/*.css 2>/dev/null | sort -u
