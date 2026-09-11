#!/bin/sh
# ============================================================================
# install-sni-desync.sh — zapret ClientHello desync 安装脚本（OpenWrt 21.02 / fw3 / armv7）
#
# 用途：解除校园网按 SNI（TLS ClientHello 中的域名）做的黑名单式限速。
#       用 nfqws 在出口把命中 hostlist 的 TCP 连接首包做分片/乱序/假包，
#       使 DPI 读不到（或读错）SNI，流量落回默认全速类。客户端零配置、不装证书。
#
# 原理/参数说明见仓库 README 的“解除按 SNI 限速”一节。
#
# 适用：OpenWrt 21.02.x (firewall3/iptables)。fw4/nftables（22+）请用上游
#       install_easy.sh，本脚本只覆盖 21.02 路径。
#
# 依赖（自动 opkg 安装）：curl ipset iptables-mod-extra iptables-mod-nfqueue
#       iptables-mod-filter iptables-mod-ipopt iptables-mod-conntrack-extra
#       iptables-mod-u32（IPv6 时另装 ip6tables-mod-nat ip6tables-extra）
#
# 二进制：zapret v72.13 官方 openwrt-embedded 发行包，全部校验 SHA-256。
#
# 用法：
#   ./install-sni-desync.sh [--offline=<tarball>] [--ip6] [--dry-run] [--mode=nfqws|tpws]
#     --offline=<tarball>  用本地已下载的发行包，跳过联网（推荐，GitHub 直连慢）
#     --ip6                同时处理 IPv6（多拨 PPPoE 通常无 IPv6，默认跳过）
#     --dry-run            只回显将执行的操作，不实际改动
#     --mode=...           强制运行模式；默认自动探测：内核有 NFQUEUE target 用
#                          nfqws（透明队列，性能最好），否则回退 tpws（nat DNAT，
#                          兼容 qsdk 等精简内核，见 docs/reference/SNI-DESYNC.md）
#
# 安全：在线文件先下载到 /tmp 并校验 SHA-256，不匹配立即中止；所有系统改动
#       在执行前回显，可先 --dry-run 预演。退出码非零即中止（set -e）。
# ============================================================================

set -eu
umask 022

# ---- 常量：版本 / URL / SHA-256（来自官方 v72.13 发行包 sha256sum.txt） ----
ZAPRET_VERSION="v72.13"
RELEASE_BASE="https://github.com/bol-van/zapret/releases/download/${ZAPRET_VERSION}"
TARBALL_NAME="zapret-${ZAPRET_VERSION}-openwrt-embedded.tar.gz"
TARBALL_URL="${RELEASE_BASE}/${TARBALL_NAME}"
TARBALL_SHA256="b2a9f454523264899e0e7ba19c662e59e29fb20ebb354aa3631cd76885f4c2e6"
SHA_NFQWS="a6281e65fdd74f1d72be2b6b86c4b8c068c275fd3ae35abe520921fb551d3058"
SHA_TPWS="412032484525f7fef8ea7d69e7eefc2c972098aee8879a5f93c70dcfb75b1438"
SHA_IP2NET="7e417be96586d301c1fd2c6ebf80254c9927155c0d4e63fce72121350bca2575"
SHA_MDIG="d7449846f1dfe63ad2bb9ac2afa0b5a834148a8d4cd45c82c54a0ab65ec315c2"

# ---- 路径常量 ----
ZAPRET_BASE=/opt/zapret
CONFIG_FILE=${ZAPRET_BASE}/config
FIREWALL_INCLUDE=/etc/firewall.zapret
HOTPLUG_DST=/etc/hotplug.d/iface/90-zapret
INIT_DST=/etc/init.d/zapret
INIT_SRC=${ZAPRET_BASE}/init.d/openwrt/zapret

# ---- 参数 ----
DISABLE_IPV6=1
ENABLE_IP6=0
DRY_RUN=0
OFFLINE=0
OFFLINE_TARBALL=""
MODE=""            # 运行时探测：nfqws（首选）或 tpws（内核无 NFQUEUE 时回退）
MODE_EXPLICIT=0    # --mode=tpws 强制指定
for arg in "$@"; do
	case "$arg" in
		--ip6) ENABLE_IP6=1; DISABLE_IPV6=0 ;;
		--dry-run) DRY_RUN=1 ;;
		--offline=*) OFFLINE=1; OFFLINE_TARBALL="${arg#*=}" ;;
		--offline) OFFLINE=1 ;;
		--mode=nfqws) MODE=nfqws; MODE_EXPLICIT=1 ;;
		--mode=tpws) MODE=tpws; MODE_EXPLICIT=1 ;;
		*) die "未知参数: $arg" ;;
	esac
done

log()  { printf '[install-sni-desync] %s\n' "$*"; }
die()  { printf '[install-sni-desync] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[install-sni-desync] WARN: %s\n' "$*" >&2; }

# 执行/回显：DRY_RUN=1 时只打印；否则执行并检查退出码
run() {
	echo "  + $*"
	[ "$DRY_RUN" = 1 ] && return 0
	"$@" || die "命令失败: $*"
}
run_quiet() {
	[ "$DRY_RUN" = 1 ] && { echo "  + $*"; return 0; }
	"$@" >/dev/null 2>&1 || die "命令失败: $*"
}

check_requirements() {
	[ -x /sbin/fw3 ] || die "未找到 /sbin/fw3：本脚本仅支持 OpenWrt 21.02 (firewall3/iptables)"
	[ -x /sbin/uci ] || die "未找到 /sbin/uci"
	[ -x /bin/opkg ] || [ -x /usr/bin/opkg ] || command -v opkg >/dev/null 2>&1 \
		|| die "未找到 opkg"
	[ "$(id -u)" = 0 ] || die "需要 root 权限"
	# 下载器：curl 或 wget 任一可用即可；都没有则 install_deps 会装 curl
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
		command -v uclient-fetch >/dev/null 2>&1 || \
		warn "未发现 curl/wget/uclient-fetch，将由 opkg 安装 curl"
}

install_deps() {
	# NFQUEUE 依赖仅在 nfqws 模式需要；tpws 模式只需 nat REDIRECT（内核内建，无额外包）
	if [ "$MODE" = nfqws ]; then
		log "安装依赖包（nfqws 模式）..."
		local pkgs="ipset iptables-mod-extra iptables-mod-nfqueue iptables-mod-filter iptables-mod-ipopt iptables-mod-conntrack-extra iptables-mod-u32"
		[ "$DISABLE_IPV6" = 1 ] || pkgs="$pkgs ip6tables-mod-nat ip6tables-extra"
		run_quiet opkg update
		run opkg install $pkgs
	else
		log "tpws 模式：无需额外 iptables 模块（内核 nat REDIRECT 已确认可用）"
	fi
}

# 探测内核是否具备 NFQUEUE（nfqws 的前提）：
# 1) /proc/net/ip_tables_targets 含 NFQUEUE（target 已注册）
# 2) iptables -m NFQUEUE 可解析（用户态 .so 存在）
# 两者都满足才用 nfqws；否则回退 tpws（仅用 nat REDIRECT）
detect_mode() {
	[ "$MODE_EXPLICIT" = 1 ] && { log "模式已指定: $MODE"; return 0; }
	local iptables_bin
	iptables_bin=$(command -v iptables 2>/dev/null || echo /usr/sbin/iptables)
	if grep -q NFQUEUE /proc/net/ip_tables_targets 2>/dev/null \
		&& [ -e /usr/lib/iptables/libxt_NFQUEUE.so ] \
		&& "$iptables_bin" -m NFQUEUE -h >/dev/null 2>&1
	then
		MODE=nfqws
	else
		MODE=tpws
	fi
	log "运行模式: $MODE（内核 $(grep -q NFQUEUE /proc/net/ip_tables_targets 2>/dev/null && echo 有 || echo 无) NFQUEUE target）"
}

download_tarball() {
	local dst="$1"
	if [ "$OFFLINE" = 1 ]; then
		[ -n "$OFFLINE_TARBALL" ] || die "--offline 需要提供 tarball 路径：--offline=/path/to/$TARBALL_NAME"
		[ -f "$OFFLINE_TARBALL" ] || die "找不到本地发行包: $OFFLINE_TARBALL"
		log "使用本地发行包: $OFFLINE_TARBALL"
		cp -f "$OFFLINE_TARBALL" "$dst"
		return 0
	fi

	# 直连 GitHub 失败时依次尝试镜像前缀（仅作为传输代理，仍会做 SHA-256 校验）
	local url
	for url in \
		"$TARBALL_URL" \
		"https://gh-proxy.com/$TARBALL_URL" \
		"https://ghfast.top/$TARBALL_URL"
	do
		log "下载 $url"
		rm -f "$dst"
		if command -v curl >/dev/null 2>&1; then
			curl -fL --retry 2 --connect-timeout 20 -o "$dst" "$url" && return 0
		elif command -v wget >/dev/null 2>&1; then
			wget -q -T 20 -O "$dst" "$url" && return 0
		else
			uclient-fetch -q -O "$dst" "$url" && return 0
		fi
		warn "该地址失败，尝试下一个"
	done
	rm -f "$dst"
	die "所有下载地址均失败；可在 PC 下载后加 --offline=/path 部署"
}

verify_sha256() {
	local file="$1" expect="$2" desc="$3" actual
	actual=$(sha256sum "$file" | awk '{print $1}')
	if [ "$actual" != "$expect" ]; then
		die "$desc 校验失败：期望 $expect，实际 $actual（已中止，拒绝使用）"
	fi
	log "$desc 校验通过"
}

extract_tarball() {
	# 只解压运行所需子目录，避免把全部架构二进制拷进闪存
	local tarball="$1" work="$2"
	mkdir -p "$work"
	run_quiet tar -xzf "$tarball" -C "$work" \
		"zapret-${ZAPRET_VERSION}/binaries/linux-arm" \
		"zapret-${ZAPRET_VERSION}/common" \
		"zapret-${ZAPRET_VERSION}/init.d/openwrt" \
		"zapret-${ZAPRET_VERSION}/ipset" \
		"zapret-${ZAPRET_VERSION}/config.default"
}

install_binaries() {
	local srcdir="$1" dst="$ZAPRET_BASE/binaries/linux-arm"
	mkdir -p "$dst"
	for f in nfqws tpws ip2net mdig; do
		run cp -f "$srcdir/$f" "$dst/$f"
	done
	run chmod 755 "$dst"/*
	log "已安装二进制到 $ZAPRET_BASE/binaries/linux-arm"
}

install_common_files() {
	local src="$1"
	mkdir -p "$ZAPRET_BASE/init.d/openwrt/custom.d" "$ZAPRET_BASE/common" "$ZAPRET_BASE/ipset"
	run cp -R "$src/common"/* "$ZAPRET_BASE/common/"
	run cp -R "$src/init.d/openwrt"/* "$ZAPRET_BASE/init.d/openwrt/"
	run cp -R "$src/ipset"/* "$ZAPRET_BASE/ipset/"
	run cp -f "$src/config.default" "$ZAPRET_BASE/config.default"
	# nfq/tpws 可执行链接目录（init 脚本用 $ZAPRET_BASE/nfq/nfqws）
	mkdir -p "$ZAPRET_BASE/nfq" "$ZAPRET_BASE/tpws"
	run ln -sf "../binaries/linux-arm/nfqws" "$ZAPRET_BASE/nfq/nfqws"
	run ln -sf "../binaries/linux-arm/tpws" "$ZAPRET_BASE/tpws/tpws"
	log "已复制运行支持文件到 $ZAPRET_BASE"
}

configure() {
	# hostlist：每行一个域名，支持后缀匹配（如 ".baidu.com"）。MODE_FILTER=hostlist
	# 时只有命中这些域名的连接才会被 desync，其余流量完全不受影响。
	# 多拨：WAN 接口由 zapret 自动发现（所有带默认路由的接口，含各 PPPoE），
	# 如需显式指定可取消下面 OPENWRT_WAN4 注释。
	mkdir -p "$ZAPRET_BASE/ipset"
	[ -f "$ZAPRET_BASE/ipset/zapret-hosts-user.txt" ] || {
		touch "$ZAPRET_BASE/ipset/zapret-hosts-user.txt"
		log "已创建空 hostlist 用户列表：$ZAPRET_BASE/ipset/zapret-hosts-user.txt"
	}

	if [ "$MODE" = nfqws ]; then
	cat > "$CONFIG_FILE" <<EOF
# 由 install-sni-desync.sh 生成（zapret ${ZAPRET_VERSION} / OpenWrt 21.02 / fw3 / nfqws）
# 对抗按 SNI 的黑名单式限速：命中 hostlist 的 TCP 首包做假包+分段乱序。
DISABLE_IPV4=0
DISABLE_IPV6=${DISABLE_IPV6}
NFQWS_ENABLE=1
TPWS_ENABLE=0
TPWS_SOCKS_ENABLE=0
NFQWS_PORTS_TCP=80,443
NFQWS_PORTS_UDP=443
NFQWS_TCP_PKT_OUT=6
NFQWS_TCP_PKT_IN=3
NFQWS_UDP_PKT_OUT=6
NFQWS_UDP_PKT_IN=0
NFQWS_OPT="
--filter-tcp=80 --dpi-desync=fake,multisplit --dpi-desync-split-pos=method+2 --dpi-desync-fooling=md5sig <HOSTLIST> --new
--filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig <HOSTLIST> --new
--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=6 <HOSTLIST_NOAUTO>
"
MODE_FILTER=hostlist
#OPENWRT_WAN4="wan wan2"
FLOWOFFLOAD=donttouch
EOF
	else
	cat > "$CONFIG_FILE" <<EOF
# 由 install-sni-desync.sh 生成（zapret ${ZAPRET_VERSION} / OpenWrt 21.02 / fw3 / tpws 模式）
# 内核无 NFQUEUE target（qsdk 等自编内核常见），改用 tpws 用户态透明代理：
# nat PREROUTING 把 LAN 出站 80/443 DNAT 到本机 tpws，由 tpws 对 ClientHello 分段。
DISABLE_IPV4=0
DISABLE_IPV6=${DISABLE_IPV6}
NFQWS_ENABLE=0
TPWS_ENABLE=1
TPWS_SOCKS_ENABLE=0
TPWS_PORTS=80,443
TPWS_OPT="
--filter-tcp=80 --split-pos=method+2 --new
--filter-tcp=443 --split-pos=1,midsld --disorder <HOSTLIST> --new
"
MODE_FILTER=hostlist
FLOWOFFLOAD=donttouch
EOF
	fi
	# uci 不需要本脚本改动；config 直接由 init.d/zapret 读取
	log "已写入 $CONFIG_FILE（模式: $MODE）"
}

install_init() {
	run ln -sf "$INIT_SRC" "$INIT_DST"
	if [ "$DRY_RUN" = 1 ]; then
		log "（dry-run）/etc/init.d/zapret enable"
	else
		/etc/init.d/zapret enable >/dev/null 2>&1 \
			|| warn "init enable 失败（可稍后手动 /etc/init.d/zapret enable，不影响安装完成）"
	fi
	log "已注册 init 脚本 /etc/init.d/zapret（procd 管理）"
}

install_firewall_include() {
	# 21.02 = fw3：firewall include（reload=1），每次防火墙 reload/restart 都会执行。
	# 这里不直接照抄 zapret 自带的 firewall.zapret，而是包两层守卫（详见生成内容）：
	#   1) 服务未启用或存在停止标记 /var/run/zapret.off 时，不安装 tpws 跳转；
	#   2) 访问路由器自身 IP 的 80/443 永不投入 tpws（面板自救保险）。
	# 起因：跳转一旦存在，LAN 出站 80/443 全被 DNAT 到 127.0.0.127:988；tpws 不在时
	# 客户端一律 connection refused，而 LuCI 面板同样监听 80 端口，于是连管理页都
	# 打不开，现象与“路由器死机”完全一样。
	local lan_ip
	lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
	if [ -z "$lan_ip" ]; then lan_ip=192.168.6.1; fi

	if [ "$DRY_RUN" = 1 ]; then
		echo "  + 写入守卫版 $FIREWALL_INCLUDE (LAN_IP=$lan_ip)"
	else
		cat > "$FIREWALL_INCLUDE" <<EOF
#!/bin/sh
# 由 install-sni-desync.sh 生成；重新安装会覆盖，请不要手工修改。
#
# fw3 include：防火墙 reload/restart 时安装 tpws 的 nat 跳转（LAN 出站 80/443 → tpws）。
#
# 守卫 1（必需）：只有 SNI 分流服务处于“启用”状态、且没有停止标记时才安装跳转。
#   跳转存在时，所有经 LAN 的 80/443 都会被 DNAT 到 127.0.0.127:988。若此刻 tpws
#   没有运行，客户端一律 connection refused；而 LuCI 面板自己也监听 80 端口，于是
#   管理页面一起失联——看起来就像路由器死机。因此：
#     · 停止分流必须摘掉跳转（见 campus_redial rpcd 的 zapret_apply_action）
#     · 之后重载防火墙不得把跳转补回来（本守卫）
ZAPRET_ON=
for f in /etc/rc.d/S*zapret; do
	if [ -e "\$f" ]; then ZAPRET_ON=1; break; fi
done

if [ -n "\$ZAPRET_ON" ] && [ ! -e /var/run/zapret.off ]; then
	SCRIPT=\$(readlink /etc/init.d/zapret)
	if [ -n "\$SCRIPT" ]; then
		EXEDIR=\$(dirname "\$SCRIPT")
		ZAPRET_BASE=\$(readlink -f "\$EXEDIR/../..")
	else
		ZAPRET_BASE=/opt/zapret
	fi
	. "\$ZAPRET_BASE/init.d/openwrt/functions"
	zapret_apply_firewall
fi

# 守卫 2（保险）：访问路由器自身 IP 的 80/443 一律直连，永不投入 tpws。
# 即使 tpws 意外崩溃或被 OOM 杀掉，管理页面仍然可达，可以从面板恢复。
# 幂等：先删同规格旧规则，再插到 PREROUTING 最前。
LAN_IP=$lan_ip
iptables -t nat -D PREROUTING -d "\$LAN_IP" -p tcp -m multiport --dports 80,443 -j RETURN 2>/dev/null
iptables -t nat -I PREROUTING 1 -d "\$LAN_IP" -p tcp -m multiport --dports 80,443 -j RETURN
EOF
		log "已写入守卫版 firewall include: $FIREWALL_INCLUDE（LAN_IP=$lan_ip）"
	fi
	run chmod 755 "$FIREWALL_INCLUDE"

	# 注册 uci include（去重：遍历全部 include 段，避免重复注册导致规则被装两次）
	local have= i p
	i=0
	while [ "$i" -le 15 ]; do
		p=$(uci -q get "firewall.@include[$i].path" 2>/dev/null || true)
		if [ "$p" = "$FIREWALL_INCLUDE" ]; then have=1; break; fi
		i=$((i+1))
	done
	if [ -n "$have" ]; then
		log "firewall include 已注册，跳过 uci 修改"
	else
		run uci add firewall include
		run uci set firewall.@include[-1].path="$FIREWALL_INCLUDE"
		run uci set firewall.@include[-1].reload="1"
		run uci commit firewall
		log "已注册 firewall include（fw3 重启时加载规则）"
	fi
}

install_hotplug() {
	# 90-zapret：WAN 接口 up/down 时自动重载（多拨动态 PPPoE 接口需要）
	run ln -sf "$ZAPRET_BASE/init.d/openwrt/90-zapret" "$HOTPLUG_DST"
	log "已安装 hotplug 钩子 $HOTPLUG_DST"
}

start_service() {
	log "重启 zapret 服务与防火墙..."
	if [ "$DRY_RUN" = 1 ]; then
		echo "  + rm -f /var/run/zapret.off"
		echo "  + $INIT_DST enable"
		echo "  + $INIT_DST restart"
		echo "  + fw3 -q restart"
	else
		# 清掉“已停止”标记：安装/重装即表示要启用分流
		rm -f /var/run/zapret.off
		"$INIT_DST" enable >/dev/null 2>&1 || true
		"$INIT_DST" restart >/dev/null 2>&1 \
			|| warn "zapret 服务启动失败（可检查 /tmp 日志后手动 $INIT_DST start）"
		fw3 -q restart >/dev/null 2>&1 \
			|| warn "fw3 restart 失败（可手动执行）"
	fi
	log "服务与防火墙已重启"
}

cleanup() {
	rm -rf "$tmp"
}

main() {
	log "== 解除按 SNI 限速：zapret ${ZAPRET_VERSION} / OpenWrt 21.02 / fw3 =="
	check_requirements
	detect_mode

	tmp=$(mktemp -d /tmp/zapret-install.XXXXXX)
	trap cleanup EXIT INT TERM
	tarball="$tmp/$TARBALL_NAME"
	work="$tmp/zapret"

	install_deps
	download_tarball "$tarball"
	verify_sha256 "$tarball" "$TARBALL_SHA256" "发行包 $TARBALL_NAME"
	extract_tarball "$tarball" "$work"
	src="$work/zapret-${ZAPRET_VERSION}"

	# 解压后的二进制逐个校验（防镜像/传输篡改）
	verify_sha256 "$src/binaries/linux-arm/nfqws" "$SHA_NFQWS" "nfqws"
	verify_sha256 "$src/binaries/linux-arm/tpws"  "$SHA_TPWS"  "tpws"
	verify_sha256 "$src/binaries/linux-arm/ip2net" "$SHA_IP2NET" "ip2net"
	verify_sha256 "$src/binaries/linux-arm/mdig"   "$SHA_MDIG"  "mdig"

	install_binaries "$src/binaries/linux-arm"
	install_common_files "$src"
	configure
	install_init
	install_firewall_include
	install_hotplug
	start_service

	log "安装完成（模式: $MODE）。"
	log "  1) 编辑 hostlist：$ZAPRET_BASE/ipset/zapret-hosts-user.txt（每行一个域名）"
	log "  2) 重启服务：/etc/init.d/zapret restart"
	if [ "$MODE" = tpws ]; then
		log "  3) tpws 模式验证：/opt/zapret/tpws/tpws --port=19889 --bind-addr=0.0.0.0 \\"
		log "     --split-pos=1,midsld --disorder --hostlist=... --debug=1 前台观察分片日志"
	else
		log "  3) 验证：tcpdump -i pppoe-wan 看 ClientHello 分片 + 测速 A/B（见 README）"
	fi
}

main "$@"
