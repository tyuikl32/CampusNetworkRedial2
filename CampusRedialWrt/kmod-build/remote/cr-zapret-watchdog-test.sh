#!/bin/sh
# wd-test.sh -- 单测 ensure_zapret_rules：从已安装的 campus-rediald 抽出守护函数，直接调用。
# 目的：把"逻辑对不对"与"巡检何时轮到它"分开验证。
set -u
DAEMON=/usr/sbin/campus-rediald
W=/tmp/wd-fn.sh
: > "$W"
awk '/^online_wan_count\(\)/,/^}/' "$DAEMON" >> "$W"
awk '/^zapret_rule_count\(\)/,/^}/' "$DAEMON" >> "$W"
awk '/^ensure_zapret_rules\(\)/,/^}/' "$DAEMON" >> "$W"
echo "抽出函数行数: $(wc -l < "$W")"
grep -c 'ensure_zapret_rules()' "$W" >/dev/null || { echo "FATAL: 抽不到函数"; exit 1; }

cat >> "$W" <<'DRIVER'
uci_get() { uci -q get "campus-redial.main.$1" 2>/dev/null; }
log_msg() { echo "[watchdog] $*"; }
echo "online_wan_count=$(online_wan_count)  zapret_watchdog=$(uci_get zapret_watchdog)"
echo "--- 调用前规则数: $(zapret_rule_count)"
ensure_zapret_rules
echo "--- 调用后规则数: $(zapret_rule_count)"
echo "--- 停止标记在场时应保持不动 ---"
touch /var/run/zapret.off
iptables -t mangle -S | grep NFQUEUE | sed 's/^-A /iptables -t mangle -D /' | sh 2>/dev/null
echo "   摘除后: $(zapret_rule_count)"
ensure_zapret_rules
echo "   守护在停止标记下运行后: $(zapret_rule_count)（期望仍为 0）"
rm -f /var/run/zapret.off
ensure_zapret_rules
echo "   清掉标记后再跑: $(zapret_rule_count)（期望补回 会话数×4）"
DRIVER

echo
echo "== 运行 =="
sh "$W" 2>&1
rm -f "$W"
