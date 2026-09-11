#!/bin/sh
# Probe 2: mwan3 internals + table-id derivation, daemon pool sizing, and the
# Argon theme CSS that decides wide vs narrow rendering.  Read-only.
echo '=== A. mwan3 status ==='
mwan3 status 2>/dev/null | head -40
echo
echo '=== B. ip rule ==='
ip rule show
echo
echo '=== C. mwan3 uci: pool sections ==='
for s in wan2 wan3 cr_wan_member cr_wan2_member cr_wan3_member cr_balanced; do
  echo "--- mwan3.$s ---"; uci show mwan3.$s 2>/dev/null || echo '(absent)'
done
echo
echo '=== D. mwan3.sh: table id / iface route ==='
grep -n 'ip4table\|_id)\|rt_table\|table \$' /lib/mwan3/mwan3.sh 2>/dev/null | head -30
echo '--- mwan3_get_routes ---'
sed -n '/^mwan3_get_routes()/,/^}/p' /lib/mwan3/mwan3.sh 2>/dev/null
echo '--- mwan3_create_iface_route ---'
sed -n '/^mwan3_create_iface_route()/,/^}/p' /lib/mwan3/mwan3.sh 2>/dev/null
echo
echo '=== E. mwan3 hotplug ==='
ls -l /etc/hotplug.d/iface/ 2>/dev/null
echo '--- mwan3 CLI commands ---'
grep -n '^[a-z_]*)\|^case\|^\s*help' /usr/sbin/mwan3 2>/dev/null | head -20
echo
echo '=== F. daemon: pool sizing ==='
grep -n 'MAX_POOL_SESSIONS\|POOL_SIZE=' /usr/sbin/campus-rediald 2>/dev/null | head -20
echo
echo '=== G. daemon: where speed test is called ==='
grep -n 'run_speed_test_session\|mbps200_enabled\|MBPS200_ENABLED\|SPEED_ENABLED' /usr/sbin/campus-rediald 2>/dev/null | head -20
echo
echo '=== H. session runtime file ==='
cat /var/run/campus-redial/session.wan2 2>/dev/null
echo '--- account-map ---'
cat /var/run/campus-redial/account-map 2>/dev/null
echo '--- accounts dir ---'
ls -l /var/run/campus-redial/accounts/ 2>/dev/null
echo
echo '=== I. argon css files ==='
ls -l /www/luci-static/argon/css/ 2>/dev/null
echo
echo '=== J. argon: cbi-section-table rules ==='
for f in /www/luci-static/argon/css/*.css; do
  [ -f "$f" ] || continue
  n=$(grep -c 'cbi-section-table' "$f" 2>/dev/null)
  echo "### $f ($(wc -c <$f) bytes, $n hits)"
  [ "$n" -gt 0 ] && grep -o '\.cbi-section-table[^{]*{[^}]*}' "$f" 2>/dev/null | head -10
done
echo
echo '=== K. argon: media queries ==='
grep -oh '@media[^{]*' /www/luci-static/argon/css/*.css 2>/dev/null | sort -u | head -20
echo
echo '=== L. argon: cbi-value / cbi-value-field rules ==='
grep -o '\.cbi-value[a-z-]*[^{]*{[^}]*}' /www/luci-static/argon/css/*.css 2>/dev/null | head -25
echo
echo '=== M. form.js TableSection render (what DOM is produced) ==='
sed -n '/TableSection = Class.extend/,/^\});/p' /www/luci-static/resources/form.js 2>/dev/null | grep -n 'E(\|class\|cbi-section-table\|render' | head -40
