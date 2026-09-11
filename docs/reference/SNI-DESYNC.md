# 解除按 SNI 限速（zapret）— 多版本 OpenWrt 安装指南

> 适用场景：校园网按 SNI（TLS ClientHello 中的域名）做**黑名单式限速**。
> 原理：让 DPI 读不到（或读错）SNI，使流量落回默认不限速类。
> 工具：[zapret](https://github.com/bol-van/zapret) v72.13（nfqws / tpws）。
>
> 本文按 OpenWrt 版本和防火墙后端分路径。先确认你的环境：
>
> ```sh
> cat /etc/openwrt_release | grep -E 'RELEASE|TARGET'   # 版本与 target
> uname -m                                              # 架构（决定二进制目录）
> [ -x /sbin/fw3 ] && echo fw3 || true; [ -x /sbin/fw4 ] && echo fw4 || true
> grep NFQUEUE /proc/net/ip_tables_targets              # 有输出 = 内核支持 NFQUEUE
> ```

## 本机现状（2026-09-11 更新）：AX3000 已切到 **nfqws**

> 这台 Redmi AX3000 原本因为「内核无 NFQUEUE」只能跑 tpws（下行被砍到 ~177 Mbps）。
> 现在**内核侧 NFQUEUE 已经由本项目自编补上**（厂商 QSDK 树构建的 `nfnetlink_queue.ko` + `xt_NFQUEUE.ko`，
> 见 `memory/2026-09-11-ax3000-nfqueue-nfqws-live.md`），设备**当前就运行在 nfqws 模式**：
>
> ```sh
> grep -E '^(NFQWS_ENABLE|TPWS_ENABLE|MODE_FILTER)=' /opt/zapret/config
> # NFQWS_ENABLE=1 / TPWS_ENABLE=0 / MODE_FILTER=hostlist
> ```
>
> 实测（同一转发路径、16 路明文 HTTP、校园测速靶站）：
>
> | 路径 | 聚合下行 |
> | --- | --- |
> | tpws | 173.1 / 180.4 Mbps |
> | **nfqws** | **312.5 / 314.7 Mbps** |
> | 完全不经手（`nozapret` 排除对照） | 355.1 Mbps |
>
> 代价：每连接只有**前 3 个包**进用户态（16 连接一次测速共 48 包），daemon CPU 0.03~0.15 s。
>
> 切换/回滚脚本（仓库内，需上传到设备 `/tmp` 执行）：
>
> ```sh
> sh /tmp/cr-nfq-switch.sh status     # 看当前模式、跳转、NFQUEUE 规则、连通性
> sh /tmp/cr-nfq-switch.sh off        # nfqws -> tpws（配置备份 /opt/zapret/config.tpws.bak）
> sh /tmp/cr-nfq-switch.sh on         # tpws -> nfqws
> ```
>
> **hostlist 语义（实测 v72.13，很反直觉，务必记住）**：`zapret-hosts-user.txt`
> **存在但为空 = 匹配所有主机**（日志里 profile 标 `(empty)`，没有任何 hostlist check 就直接命中）。
> 所以"名单是空的"不等于"没生效"，而是"对全部域名 desync"——本机就是**故意留空**的。
>
> **更正一条流传过的错说法**：「上行是内核直通、只有首包走 tpws」是错的。tpws 是代理，
> 两个方向都要过用户态；上行看着无损，只是因为上行线速率低于 tpws 的天花板。

## 两种模式怎么选

| 模式 | 内核要求 | 适用 | 性能 |
|---|---|---|---|
| **nfqws**（首选） | iptables 有 NFQUEUE target + `iptables-mod-nfqueue` | 官方 OpenWrt（19.07~21.02 iptables / 22+ nftables） | 只处理每连接前几个包，转发零损耗 |
| **tpws**（回退） | nat 表 REDIRECT target（所有固件都有） | 内核精简/厂商自编固件无 NFQUEUE（如 qsdk、部分运营商定制固件） | 全部 hostlist 流量过用户态代理，CPU 稍高 |

安装脚本 `install-sni-desync.sh` 会自动探测并选择模式；也可 `--mode=tpws` 强制。

---

## 一、OpenWrt 21.02.x（fw3/iptables）—— 主路径

适用于本仓库目标设备以外的所有标准 21.02 固件（armv7/mipsel/x86 等）。

```sh
# 1. 传文件到路由器（SSH 无 sftp 时用管道）
ssh root@<ip> 'cat > /tmp/zapret-embedded.tar.gz' < tools/zapret-embedded.tar.gz
ssh root@<ip> 'cat > /tmp/install-sni-desync.sh' < tools/install-sni-desync.sh

# 2. 安装（自动探测模式、装依赖、写 config、注册 fw3 include 和 hotplug）
ssh root@<ip> 'sh /tmp/install-sni-desync.sh --offline=/tmp/zapret-embedded.tar.gz'

# 3. 填 hostlist（被限速的域名，每行一个）
echo 'pan.baidu.com' >> /opt/zapret/ipset/zapret-hosts-user.txt
/etc/init.d/zapret restart
```

安装脚本做的事（`--dry-run` 可预演）：

1. `opkg` 安装依赖：`ipset iptables-mod-extra iptables-mod-nfqueue iptables-mod-filter
   iptables-mod-ipopt iptables-mod-conntrack-extra iptables-mod-u32`（nfqws 模式）。
   **注意**：这些包在官方 feed 的 `targets/<target>/packages`（core）里；社区/自编固件若
   core feed 404（见下文 qsdk 特例），nfqws 装不上，自动回退 tpws。
2. 校验并解压 v72.13 openwrt-embedded 包的 `linux-arm` 二进制 + common + init.d + ipset 到
   `/opt/zapret`（约 500 KB）。
3. 生成 `/opt/zapret/config`：
   - nfqws 模式：443 用 `fake,multidisorder`（拆 1 字节 + midsld、badseq/md5sig 伪装），
     80 用 `fake,multisplit`；
   - tpws 模式：443 用 `split-pos=1,midsld --disorder`，80 用 `split-pos=method+2`。
   - 两者都 `MODE_FILTER=hostlist`——只处理名单内域名，其他流量零影响。
4. 注册 `/etc/init.d/zapret`（procd，开机自启）+ `/etc/firewall.zapret`（fw3 include，
   reload=1）+ `/etc/hotplug.d/iface/90-zapret`（WAN ifup 自动重载，多拨 PPPoE 需要）。

### 验收

```sh
# 规则计数增长（LAN 客户端访问 hostlist 域名后）
iptables -t nat -L PREROUTING -v -n | grep 988        # tpws：DNAT 计数应增长
iptables -t mangle -S POSTROUTING | grep NFQUEUE      # nfqws：应有 connbytes+NFQUEUE 规则

# tpws 确认分片生效（前台 debug 跑一个临时实例）
/opt/zapret/tpws/tpws --port=19889 --bind-addr=0.0.0.0 --user=daemon \
  --split-pos=1,midsld --disorder --hostlist=/opt/zapret/ipset/zapret-hosts-user.txt \
  --debug=1    # 客户端访问名单域名时打印 "Sending multisplit part ..." 即生效
```

### 已实测环境

- **Redmi AX3000（ipq50xx，qsdk 11.5.0.5 内核 5.4.164，21.02.7）**：出厂内核无 NFQUEUE target、
  无 xt_NFQUEUE.ko，core feed 404（官方 downloads.openwrt.org 无 ipq50xx target）。
  - 2026-09-10：以 **tpws 模式**部署验收（tpws v72.13 监听 988，fw3 DNAT 生效，
    debug 日志确认对 `www.speedtest.net` 的 ClientHello 完成 multisplit 分段）。
  - **2026-09-11：改为自编内核模块 + nfqws**（见本页顶部「本机现状」）。
    `--mode=tpws` 仍然是这台设备的**回退路径**：`sh install-sni-desync.sh --mode=tpws` 依旧可用。
- 192.168.6.1 的部署即用此路径；`/opt/zapret/config.working` 是 09-10 的 tpws 生效配置备份，
  `2026-09-11` 起的 tpws 配置备份在 `/opt/zapret/config.tpws.bak`。

## 二、OpenWrt 22.03+ / 23.05 / 24.10（fw4/nftables）

nfqws 模式依赖变化：`kmod-nft-queue` 替代 iptables 系模块，防火墙规则走 nftables。

```sh
opkg update
opkg install kmod-nft-nat kmod-nft-offload kmod-nft-queue curl ca-bundle
# 用上游完整安装器（fw4 路径上游支持更完整，含 nftables include 和 ifset 自动重载）：
cd /tmp && tar xzf zapret-embedded.tar.gz && cd zapret-v72.13
sh install_easy.sh        # 交互式：选 nfqws 模式、hostlist 过滤；按提示填名单
```

或继续用本仓库脚本（已适配 fw3；对 fw4 设备脚本会在 `check_requirements` 处拒绝，
提示走上游 `install_easy.sh`——fw4 的 nftables include 机制不同，不硬造）。

24.10+ 注意：内核 ≥6.17 可能去掉 iptables-legacy，本脚本/fw3 路径均不适用，走本节。

## 三、19.07 及更早（fw2/iptables-1.8 以下）

`iptables-mod-nfqueue`、`xt_NFQUEUE` 均存在，但 zapret 上游不再测试老版本。
建议：`--mode=tpws`（tpws 只依赖 nat REDIRECT，兼容性最好）+ 手工确认：

```sh
opkg install iptables-mod-extra ipset curl
sh install-sni-desync.sh --mode=tpws --offline=/tmp/zapret-embedded.tar.gz
```

## 四、非 armv7 架构（mipsel/mips/x86_64/aarch64）

发行包内含 `binaries/linux-{mipsel,mips,mips64,arm64,x86,x86_64,ppc,lexra}`。
脚本默认只拷 `linux-arm`；其他架构改 `install-sni-desync.sh` 顶部：

```sh
# 把脚本里 binaries/linux-arm 全部替换为对应目录，如：
sed -i 's#linux-arm#linux-mipsel#g' install-sni-desync.sh   # mipsel 设备
# 并把 SHA_* 四个哈希换成官方 sha256sum.txt 对应条目
```

（arm64 设备同时把脚本里 `linux-arm` 换成 `linux-arm64`，哈希对应替换。）

## 五、厂商/自编固件（qsdk、ImmortalWrt、padavan 转生等）排障

这类固件常见三个坑，脚本已处理前两个：

1. **core feed 404**：`targets/<target>` 在官方 CDN 不存在（自编 target 名）。
   → 脚本回退 tpws 模式，不依赖任何 target 包。
2. **内核无 NFQUEUE**：`grep NFQUEUE /proc/net/ip_tables_targets` 为空。
   → tpws 模式（nat REDIRECT 全固件都有）。若连 nat 表都被裁剪，只能自编固件。
3. **kmod 版本必须匹配内核**：如需补装 kmod（如 `kmod-ipt-nfqueue`），必须用与
   `uname -r` 完全一致的构建（本机 qsdk 内核是 `5.4-qsdk-11.5.0.5`，官方 kmod 不兼容，
   强装会报 `kernel version mismatch`）。这就是本机不装 kmod、用 tpws 的原因。

### 本机（Redmi AX3000）快速操作备忘

```sh
ssh root@192.168.6.1
/etc/init.d/zapret status|start|restart            # 服务状态/启动/重启
vi /opt/zapret/ipset/zapret-hosts-user.txt        # 维护域名名单
/etc/init.d/zapret restart                        # 改完名单重启生效
iptables -t nat -L PREROUTING -v -n | grep 988    # 看 DNAT 计数
logread -f | grep zapret                          # 服务日志
```

> ⚠️ **不要把 `/etc/init.d/zapret stop` 当作“关闭分流”。**
> tpws 模式下 iptables 会把 LAN 的**全部** 80/443 DNAT 到 `127.0.0.127:988`
> （名单筛选是 tpws 自己做的，不是 iptables 做的）。`stop` 只停守护进程、
> 不摘跳转（`INIT_APPLY_FW` 未设置），于是所有网页 connection refused ——
> **LuCI 面板也在 80 端口，连管理页都会打不开，看起来像路由器死机。**
>
> 正确的关闭/开启姿势（也是面板上“停止/启动”按钮做的事）：
>
> ```sh
> # 关闭分流：先摘跳转，再停进程；标记文件阻止防火墙重载把跳转补回来
> touch /var/run/zapret.off
> /etc/init.d/zapret stop_fw
> /etc/init.d/zapret stop
> /etc/init.d/zapret disable        # 可选：让“已停止”跨重启保持
>
> # 开启分流
> rm -f /var/run/zapret.off
> /etc/init.d/zapret enable
> /etc/init.d/zapret start
> /etc/init.d/zapret start_fw
> ```
>
> 判断是否处于故障态：`running` 与 `redirect` 不一致。
> `!running && redirect`（进程没了但跳转还在）就是上面那个黑洞。
> 详见 `memory/2026-09-10-sni-stop-blackhole.md`。
>
> 另外安装脚本会生成带守卫的 `/etc/firewall.zapret`，其中一条 RETURN 保证
> 访问路由器自身 IP 的 80/443 永不投入 tpws —— 即使 tpws 崩溃，管理面板仍可达。
>
> ⚠️ **还有一类"看不见的"残留（2026-09-11 实测踩到）**：zapret 摘规则时只枚举**当前存在**的 WAN 设备。
> 多拨场景下如果某个会话在切换那一刻是 **down** 的，它那条 `nat OUTPUT -o pppoe-wanN … DNAT --to
> 127.0.0.127:988` 就摘不掉，等会话重新上线就会把**路由器本机**经该会话的 80/443 投进死端口。
> 所以停用/切换后要**无条件补扫**，别按设备名逐条摘：
>
> ```sh
> iptables -t nat -S | grep -F -- '--to-destination 127.0.0.127:988'   # 必须为空
> ```
>
> `kmod-build/remote/cr-nfq-switch.sh` 已内置这个补扫（`sweep_tpws_rules()`）。

## 六、卸载

```sh
ssh root@<ip> 'sh /tmp/uninstall-sni-desync.sh'   # 幂等，hostlist 自动备份 /tmp
```

## 七、验收与迭代（两把尺子）

> **测速方法论（2026-09-11 踩坑总结，做 A/B 前必读）**
>
> 1. **测什么路径**：tpws 的跳转匹配 `-i br-lan`（以及 `nat OUTPUT -o pppoe-wanN`，所以路由器本机流量
>    也会进 tpws）；nfqws 的规则匹配 WAN 设备（出向 POSTROUTING + 入向 FORWARD/INPUT）。
>    要复现"用户从 LAN 下载"的场景，就得有**真正的转发流量**。
> 2. **别用 HTTPS 从路由器本机测**：本机跑 TLS 会先把自己 CPU 吃满（12 路 HTTPS 只有 ~79 Mbps），
>    **永远看不到 tpws 的天花板**。用**明文 HTTP 大文件**（校园测速站）测，本机 TLS 成本归零。
> 3. **转发路径的真客户端装置**：`kmod-build/remote/cr-fwd-client.sh`——`ip netns` + **两个** br-lan 上的
>    macvlan（一个留根命名空间当网关、一个进 netns），且**用独立子网**（桥设备上的 macvlan 子接口
>    与父接口 br-lan 不互通，网关只能写另一个子接口）；从别的接口进来的测试流量还要
>    `sysctl -w net.ipv4.conf.<dev>.route_localnet=1`，否则包在被 DNAT 到 127.0.0.127 后会被当 martian 丢掉
>    （症状：DNAT 计数在涨、吞吐恒 0）。
> 4. **绕过 tpws 的实时对照**：`ipset add nozapret <ip>`（DNAT 规则本来就带 `! --match-set nozapret dst`），
>    `ipset del` 即恢复；不用改配置、不用重启。
> 5. 本机路径 A/B + daemon CPU 采样脚本：`kmod-build/remote/cr-nfq-ab.sh`。

1. **分片证据**：临时 debug 实例（见第一节）或 `tcpdump -i br-lan -w /tmp/t.pcap tcp port 443`
   拷回 PC 用 Wireshark 看 ClientHello 是否拆成多段。
2. **测速 A/B**：对名单域名开/关服务各测一次。**关闭务必用 `stop_fw`（或面板上的
   “停止”按钮），不要只跑 `/etc/init.d/zapret stop`** —— 后者会留下指向死端口的
   nat 跳转，整网 http/https 全部 connection refused（详见“本机快速操作备忘”的警告）。
   开启：`/etc/init.d/zapret start` + `/etc/init.d/zapret start_fw`。
   tpws 模式下还可用 PC 直接 curl：`curl -4 -so /dev/null -w '%{speed_download}\n' https://<域名>/`。
