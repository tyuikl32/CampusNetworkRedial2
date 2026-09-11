#!/bin/sh
# ============================================================================
# uninstall-sni-desync.sh — 卸载 install-sni-desync.sh 安装的全部内容
#
# 还原项（与安装一一对应）：
#   1. 停止并禁用 /etc/init.d/zapret，删除符号链接
#   2. 从 uci firewall 删除 include 段，删除 /etc/firewall.zapret
#   3. 删除 hotplug 钩子 /etc/hotplug.d/iface/90-zapret
#   4. 删除 /opt/zapret（含 hostlist；如有自定义域名请先备份）
#   5. 清理 iptables 中残留的 zapret NFQUEUE 规则（init stop 应已清理，此处兜底）
#
# 保留项：opkg 安装的依赖包（kmod/iptables 模块是共享组件，不自动卸载；
# 如确需释放空间可手动：opkg remove iptables-mod-nfqueue iptables-mod-u32 ...）
#
# 用法：./uninstall-sni-desync.sh [--dry-run]
# ============================================================================

set -u
umask 022

ZAPRET_BASE=/opt/zapret
CONFIG_FILE=${ZAPRET_BASE}/config
FIREWALL_INCLUDE=/etc/firewall.zapret
HOTPLUG_DST=/etc/hotplug.d/iface/90-zapret
INIT_DST=/etc/init.d/zapret

DRY_RUN=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		*) echo "未知参数: $arg" >&2; exit 1 ;;
	esac
done

log()  { printf '[uninstall-sni-desync] %s\n' "$*"; }
die()  { printf '[uninstall-sni-desync] ERROR: %s\n' "$*" >&2; exit 1; }
run() {
	echo "  + $*"
	[ "$DRY_RUN" = 1 ] && return 0
	"$@" || log "（忽略失败：$*）"
}

[ "$(id -u)" = 0 ] || die "需要 root 权限"
[ -x /sbin/fw3 ] || die "未找到 /sbin/fw3：本脚本仅支持 OpenWrt 21.02 (fw3)"

log "== 卸载 zapret SNI desync =="

# 0. 如有自定义 hostlist，先备份到 /tmp 供用户带走
if [ -s "$ZAPRET_BASE/ipset/zapret-hosts-user.txt" ] && [ "$DRY_RUN" != 1 ]; then
	cp -f "$ZAPRET_BASE/ipset/zapret-hosts-user.txt" /tmp/zapret-hosts-user.txt.bak \
		&& log "已备份 hostlist 到 /tmp/zapret-hosts-user.txt.bak"
fi

# 1. 停止服务、清防火墙规则（init stop 在 iptables/fw3 下会撤销 NFQUEUE 规则并停 nfqws）
#    stop/disable 失败不阻断卸载（服务可能本来就没起来）；</dev/null 防御异常环境下读 stdin
if [ -x "$INIT_DST" ] || [ -L "$INIT_DST" ]; then
	if [ "$DRY_RUN" = 1 ]; then
		echo "  + $INIT_DST stop && disable"
	else
		"$INIT_DST" stop </dev/null >/dev/null 2>&1 || log "（init stop 非零，继续）"
		"$INIT_DST" disable </dev/null >/dev/null 2>&1 || log "（init disable 非零，继续）"
	fi
fi

# 2. 删除 uci firewall include（按 path 匹配，幂等）
if [ "$DRY_RUN" = 1 ]; then
	echo "  + uci 删除 firewall include（path=$FIREWALL_INCLUDE）"
else
	found=""
	i=0
	while uci -q get firewall.@include[$i].path >/dev/null 2>&1; do
		p=$(uci -q get firewall.@include[$i].path)
		if [ "$p" = "$FIREWALL_INCLUDE" ]; then
			uci delete firewall.@include[$i] || die "uci delete include 失败"
			found=1
			break
		fi
		i=$((i+1))
	done
	[ -n "$found" ] && uci commit firewall
	if [ -n "$found" ]; then
		log "firewall include 已移除（原第 $i 项）"
	else
		log "未发现 firewall include，跳过 uci 修改"
	fi
fi
run rm -f "$FIREWALL_INCLUDE"

# 3. hotplug 钩子（上游按链接名匹配 ??-zapret，我们固定为 90-zapret）
run rm -f "$HOTPLUG_DST"

# 4. 安装目录（含 config、binaries、hostlist）
run rm -rf "$ZAPRET_BASE"

# 5. 兜底：清理残留 NFQUEUE 规则（正常情况下 init stop 已清）
if [ "$DRY_RUN" != 1 ] && command -v iptables >/dev/null 2>&1; then
	while r=$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -E "NFQUEUE --queue-num 200" | sed -E 's/^-A POSTROUTING //' | head -1); do
		[ -n "$r" ] || break
		echo "  + iptables -t mangle -D POSTROUTING $r"
		iptables -t mangle -D POSTROUTING $r || break
	done
fi

run fw3 -q restart
log "卸载完成。路由器网络已恢复原状。"
[ "$DRY_RUN" = 1 ] || log "如 hostlist 有自定义内容，备份在 /tmp/zapret-hosts-user.txt.bak（重启后丢失，请及时取走）"
