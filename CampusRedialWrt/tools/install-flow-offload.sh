#!/bin/sh
# install-flow-offload.sh — 打开软件 flow offload（转发快路径），并装上 zapret/nfqws 需要的
# “前几个包必须走慢路径”保护规则，让 SNI 混淆与满速转发同时成立。
#
# 背景（2026-09-11 在本项目 AX3000 上实测）：
#   不开 offload：5 条 PPPoE 并发下载只有 ~350 Mbps，期间 cpu1 全程 100%、softirq ~92%。
#                 瓶颈是“每个包都走 netfilter 慢路径”的 CPU，而不是校园网或测速服务器
#                 （同一服务器单流直连可达 244 Mbps，实测 RTT 1.5 ms）。
#   开 offload 后：同样 20/40 条流达到 ~700 Mbps（PC 网卡计数 722~734 Mbps），
#                 CPU 峰值从 99.5% 降到 ~70%。
#
# 为什么不能只插一条 `-j FLOWOFFLOAD`：
#   裸规则会让 TCP 连接在三次握手完成时就进入快路径，此后 nfqws 再也看不到 ClientHello
#   （实测 NFQUEUE 命中数在整个测试期间为 0），SNI 混淆静默失效。
#   所以这里插三条，把 80/443 的前 N 个原始方向包留在慢路径：
#     1) TCP 80/443：连接已发出 >= N 个原始方向包（握手 + ClientHello 之后）才注册快路径
#     2) 其它 TCP  ：直接注册
#     3) 非 TCP    ：直接注册
#   实测：20 条流下载期间 NFQUEUE 仍命中 ~4.5 包/连接，混淆链路完好。
#
# 用法（路由器上执行）：
#   sh install-flow-offload.sh                 # 安装并立即生效（默认 N=8）
#   sh install-flow-offload.sh --packets=12    # 加大保护窗口（更保守）
#   sh install-flow-offload.sh --dry-run       # 只打印将要执行的动作
#   sh install-flow-offload.sh --uninstall     # 摘掉规则与 include 注册
set -u

INCLUDE=/etc/firewall.campus-offload
PACKETS=8
DRY_RUN=0
UNINSTALL=0

for arg in "$@"; do
	case "$arg" in
		--packets=*) PACKETS="${arg#--packets=}" ;;
		--dry-run)   DRY_RUN=1 ;;
		--uninstall|--remove) UNINSTALL=1 ;;
		-h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "未知参数: $arg（--help 查看用法）" >&2; exit 1 ;;
	esac
done

case "$PACKETS" in
	''|*[!0-9]*) echo "FATAL: --packets 必须是数字" >&2; exit 1 ;;
esac

log() { echo "[flow-offload] $*"; }
run() {
	if [ "$DRY_RUN" = 1 ]; then echo "  + $*"; else "$@"; fi
}

write_include() {
	# 规则逻辑写成 include 本体：既保证防火墙 reload 后自动补回，也避免两处维护。
	cat > "$INCLUDE" <<EOF
#!/bin/sh
# 由 install-flow-offload.sh 生成；重新安装会覆盖，请不要手工修改。
#
# fw3 include：防火墙 reload/restart 时重装 flow offload 规则（幂等）。
# 用法：sh $INCLUDE [remove]
PACKETS=$PACKETS

cr_offload_del() {
	iptables -t filter -S FORWARD 2>/dev/null | grep -F -- '-j FLOWOFFLOAD' | \\
		sed 's/^-A /iptables -t filter -D /' | sh 2>/dev/null
}

cr_offload_add() {
	modprobe xt_FLOWOFFLOAD 2>/dev/null
	modprobe nf_flow_table 2>/dev/null
	modprobe nf_flow_table_hw 2>/dev/null

	cr_offload_del

	# 探测内核是否支持 FLOWOFFLOAD：插得进去就说明支持。
	if ! iptables -t filter -I FORWARD 1 -j FLOWOFFLOAD 2>/dev/null; then
		echo "flow offload: 内核不支持 FLOWOFFLOAD target，跳过" >&2
		return 1
	fi
	cr_offload_del

	# 1) 80/443 的前 PACKETS 个原始方向包不进快路径 —— nfqws 必须看到 ClientHello
	iptables -t filter -I FORWARD 1 -p tcp -m multiport --dports 80,443 \\
		-m connbytes ! --connbytes 1:\$PACKETS --connbytes-mode packets --connbytes-dir original \\
		-j FLOWOFFLOAD
	# 2) 其它 TCP 立即进快路径
	iptables -t filter -I FORWARD 2 -p tcp -m multiport ! --dports 80,443 -j FLOWOFFLOAD
	# 3) 非 TCP（UDP/QUIC 等）立即进快路径；首包仍会走慢路径，nfqws 的 UDP 混淆不受影响
	iptables -t filter -I FORWARD 3 ! -p tcp -j FLOWOFFLOAD
}

case "\$1" in
	remove|stop) cr_offload_del ;;
	*) cr_offload_add ;;
esac
EOF
	run chmod 755 "$INCLUDE"
}

register_include() {
	local have= i=0 p=
	while [ "$i" -le 15 ]; do
		p=$(uci -q get "firewall.@include[$i].path" 2>/dev/null || true)
		if [ "$p" = "$INCLUDE" ]; then have=1; break; fi
		i=$((i + 1))
	done
	if [ -n "$have" ]; then
		log "firewall include 已注册，跳过 uci 修改"
	else
		run uci add firewall include
		run uci set "firewall.@include[-1].path=$INCLUDE"
		run uci set firewall.@include[-1].reload=1
		run uci commit firewall
		log "已注册 firewall include（fw3 reload/重启时自动补回规则）"
	fi
}

unregister_include() {
	local i=0 p=
	while [ "$i" -le 15 ]; do
		p=$(uci -q get "firewall.@include[$i].path" 2>/dev/null || true)
		if [ "$p" = "$INCLUDE" ]; then
			run uci delete "firewall.@include[$i]"
			run uci commit firewall
			log "已注销 firewall include"
			return 0
		fi
		i=$((i + 1))
	done
}

apply_now() {
	if [ "$DRY_RUN" = 1 ]; then
		echo "  + sh $INCLUDE"
	else
		sh "$INCLUDE" || return 1
	fi
}

if [ "$UNINSTALL" = 1 ]; then
	log "== 卸载 flow offload 规则 =="
	if [ -f "$INCLUDE" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			echo "  + sh $INCLUDE remove"
		else
			sh "$INCLUDE" remove
		fi
	fi
	unregister_include
	run rm -f "$INCLUDE"
	log "完成：转发回到纯慢路径（SNI 混淆不受影响，带宽回到 CPU 上限 ~350 Mbps）"
	exit 0
fi

log "== 安装 flow offload（保护窗口 N=$PACKETS 个原始方向包）=="
write_include
register_include
if apply_now; then
	log "已生效。当前 FORWARD 链头部："
	if [ "$DRY_RUN" = 1 ]; then
		echo "  (dry-run) iptables -t filter -S FORWARD | head -5"
	else
		iptables -t filter -S FORWARD | head -5 | sed 's/^/  /'
	fi
	log "验证建议："
	log "  1) 带宽：PC 端并发多流下载应在 ~700 Mbps 量级（此前 ~350）"
	log "  2) 混淆未失效：下载期间 NFQUEUE 命中数应持续增长，例如"
	log "     iptables -t mangle -L POSTROUTING -v -n | grep NFQUEUE | awk '{s+=\$1} END {print s}'"
	log "  3) 逐步回退：sh $0 --uninstall"
else
	log "警告：内核不支持 FLOWOFFLOAD，转发保持原状"
fi
