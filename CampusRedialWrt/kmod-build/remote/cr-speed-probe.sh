#!/bin/sh
# cr-speed-probe.sh -- validate the new per-session speed measurement logic
# (same algorithm as run_speed_test_session in campus-rediald, 2026-09-11 rework):
#   * derive the session's mwan3 fwmark from `ip rule ... iif <dev> lookup N`  (mark = N << 8)
#   * APPEND a mangle OUTPUT mark rule (must come after mwan3_hook, which clears marks)
#   * 6 parallel workers, 2 s warm-up, then measure iface rx_bytes over SPEED_SECONDS
#   * two rounds, take the smaller value (token-bucket channels burst)
# Usage: sh cr-speed-probe.sh [seconds] [url-http] [url-https]
set -u
SEC=${1:-6}
URL_HTTP=${2:-http://test.xidian.edu.cn/backend/garbage.php}
URL_HTTPS=${3:-https://test.xidian.edu.cn/backend/garbage.php}
WANS="wan wan2 wan3 wan4 wan5"

session_mark() { # $1 = iface
	local t
	t=$(ip rule 2>/dev/null | awk -v dev="$1" '
		$0 ~ ("iif " dev " ") { for (i = 1; i <= NF; i++) if ($i == "lookup") { print $(i + 1); exit } }')
	case "$t" in ''|*[!0-9]*) echo "" ;; *) printf '0x%x' $((t * 256)) ;; esac
}
mark_add() { # $1 = mark  $2 = port
	iptables -t mangle -A OUTPUT -p tcp --dport "$2" -m owner --uid-owner 0 \
		-j MARK --set-xmark "$1/0x3f00" 2>/dev/null || true
}
mark_del() { # $1 = mark  $2 = port
	while iptables -t mangle -D OUTPUT -p tcp --dport "$2" -m owner --uid-owner 0 \
		-j MARK --set-xmark "$1/0x3f00" 2>/dev/null; do :; done
}
round() { # $1=iface $2=src $3=url $4=mark $5=port -> prints "Mbps detail"
	local base nowb t0 t1 win bytes_if i
	mark_add "$4" "$5"
	i=1
	while [ "$i" -le 6 ]; do
		curl -sS -4 --interface "$2" --max-time $((SEC + 2)) -o /dev/null \
			"$3?ckSize=100&r=probe$i" 2>/dev/null &
		i=$((i + 1))
	done
	sleep 2
	base=$(cat "/sys/class/net/$1/statistics/rx_bytes")
	t0=$(date +%s)
	sleep "$SEC"
	nowb=$(cat "/sys/class/net/$1/statistics/rx_bytes")
	t1=$(date +%s)
	wait 2>/dev/null
	mark_del "$4" "$5"
	win=$((t1 - t0)); [ "$win" -gt 0 ] || win=1
	bytes_if=$((nowb - base)); [ "$bytes_if" -gt 0 ] || bytes_if=0
	printf '%s|%s MB/%ss' "$(awk -v b="$bytes_if" -v w="$win" 'BEGIN { printf "%.1f", b * 8 / w / 1000000 }')" "$((bytes_if / 1048576))" "$win"
}

test_url() { # $1 = label  $2 = url
	printf '\n== %s ==\n' "$1"
	printf '%-6s %-8s %-16s %8s %8s %8s\n' 会话 mark 源地址 第1轮 第2轮 取小值
	for dev in $WANS; do
		full="pppoe-$dev"
		src=$(ip -4 -o addr show dev "$full" 2>/dev/null | awk 'NR == 1 { split($4, a, "/"); print a[1]; exit }')
		[ -n "$src" ] || { printf '%-6s (无 IP)\n' "$dev"; continue; }
		m=$(session_mark "$full")
		r1=$(round "$full" "$src" "$2" "$m" "$3"); v1=${r1%%|*}; d1=${r1#*|}
		r2=$(round "$full" "$src" "$2" "$m" "$3"); v2=${r2%%|*}
		printf '%-6s %-8s %-16s %8s %8s %8s\n' "$dev" "${m:-无}" "$src" "$v1" "$v2" \
			"$(awk -v a="$v1" -v b="$v2" 'BEGIN { printf "%.1f", (a < b) ? a : b }')"
	done
}

echo "池任务: $(head -c 70 /var/run/campus-redial/status.json)"
test_url "明文 HTTP（推荐口径）" "$URL_HTTP" 80
test_url "HTTPS（对比：路由器自己跑 TLS 的代价）" "$URL_HTTPS" 443
echo
echo "残留测试 mark 规则: $(iptables -t mangle -S OUTPUT | grep -c 'set-xmark 0x[0-9a-f]00') （应为 0）"
