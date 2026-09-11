# Redmi AX3000 / ipq50xx（QSDK 11.5.0.5，内核 5.4.164）kmod-macvlan 部署与自编指南

对象设备：Redmi AX3000，管理地址 `192.168.6.1`，社区 21.02.7 固件 + Qualcomm QSDK 供应商内核。
本文回答三个问题：

1. **为什么 `opkg` 装不上 `kmod-macvlan`**（以及 `kmod-ipt-ipopt` 等 target 级 kmod）；
2. **为什么“用设备自己的 config 编上游源码”也不行**（2026-09-10 实测 panic 的根因）；
3. **怎样才能得到与这块设备内核 ABI 真正匹配的 `macvlan.ko`。**

> 2026-09-11 补充：同一条流水线后来又编了 **NFQUEUE** 两个模块
> （`net/netfilter/nfnetlink_queue.ko` + `net/netfilter/xt_NFQUEUE.ko`），
> 用来把 zapret 从 tpws 用户态代理切到内核 nfqws（下行 177 → 314 Mbps）。
> 命令：`wsl-nfqueue-build.sh`（构建）+ `wsl-nfq-verify.sh`（闸门）+ `pkg/mk-nfqueue-pkgs.py`（打两个 ipk）。
> 全过程的坑（含 `pipefail`+SIGPIPE 的假闸门、kallsyms 没有数据符号、`/proc/PID/stat` 字段错位）
> 见 `memory/2026-09-11-ax3000-nfqueue-nfqws-live.md`。

> 变更纪律：对本路由器的任何“严肃更改”（装/删内核模块、改 `/etc/config/network`、跑会打断 WAN 的拨号实验、重启）**必须先向机主说明并得到确认**再执行。刷固件不在此文档范围内，也不由助手执行。

---

## 1. 设备事实（全部实测）

| 项目 | 值 |
| --- | --- |
| 型号 / target | Redmi AX3000（`redmi,ax3000`）/ `ipq50xx/arm` |
| 固件 | OpenWrt 21.02.7 `r16847-f8282da11e`（社区构建，hostname/SSID 为 `Bwrt`） |
| 内核 | `5.4.164`，QSDK `11.5.0.5`，ARMv7，`SMP preempt mod_unload ARMv7 p2v8` |
| opkg 架构 | `arm_cortex-a7_neon-vfpv4` |
| 内核包版本 | `5.4-qsdk-11.5.0.5-1-1d36e0bafcfe3798b2e9608e79ec8215` |
| 有线口 | `eth0` = WAN 口（`nss-dp` 驱动）；`eth1` = LAN 交换 CPU 口（挂在 `br-lan`） |
| BRAS | Huawei **ME60-X8A**（AC-name） |

设备上已安装的 **39 个 kmod 全部**声明同一个内核依赖：

```
Depends: kernel (= 5.4-qsdk-11.5.0.5-1-1d36e0bafcfe3798b2e9608e79ec8215)
```

这是内核的**配置 / ABI 指纹**（OpenWrt 由内核 `.config` 派生的 MD5）。

---

## 2. 固件的内核源码出处（2026-09-10 已定位）

社区同源项目 `hzyitc/openwrt-redmi-ax3000` 的分支
`ipq50xx-qsdk-kernel-5.4-openwrt-21.02-qsdk-11.5.05.841.1029`，
其 `target/linux/ipq50xx/Makefile` 明确写着：

```make
KERNEL_PATCHVER:=5.4
LINUX_VERSION-5.4:=-qsdk-11.5.0.5
CONFIG_KERNEL_GIT_CLONE_URI:=https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-5.4
CONFIG_KERNEL_GIT_REF:=d5fcb18e5420670c8734c6a659873e73adab6dac
```

- `LINUX_VERSION-5.4:=-qsdk-11.5.0.5` 与设备 `DISTRIB`/内核包版本**完全一致**；
- 该 target 的 `patches/` 只有 5 个小补丁（合计约 6.5 KB），**没有一条动 `netdevice.h`**；
- ⇒ 设备内核 = **Qualcomm QSDK 供应商内核树** `linux-ipq-5.4`（CodeLinaro，commit `d5fcb18e`），
  **不是**上游 `linux-5.4.164`。

这一点是理解下面所有问题的钥匙。

---

## 3. 为什么 opkg 装不上（已验证的技术结论）

1. 官方 OpenWrt 21.02.7 **没有 ipq50xx target**（ipq50xx 到 23.05 才进入官方）。
   固件里 `/etc/opkg/distfeeds.conf` 指向官方 CDN，其中
   `targets/ipq50xx/arm/packages/` 是 404，`opkg update` 拿不到 core 列表。
2. `base` / `packages` / `luci` feed 可以 update，但**不含**任何 kmod
   （kmod 包只随 target 一起编译发布）。
3. 借用其它 target 的 kmod 全部失败：`armvirt/32`（`5.4.238`）、`ipq40xx/generic`（`5.4.238`）
   等模块 `insmod` 报 `module PLT section(s) missing` 或 vermagic 不匹配 ——
   本机 `CONFIG_ARM_MODULE_PLTS=y`，而官方 21.02.7 的 armv7 内核没开，编出的 `.ko` 无 `.plt` 段。
4. 社区同源项目 `hzyitc` 的 kmod feed 里 `kmod-macvlan` 声明
   `kernel (= 5.4-qsdk-11.5.0.5-1-6be5791bae9794f7d4dc8a02dd8d6a55)`，
   **与本机指纹 `1d36e0ba…` 不同**（因为它的构建配置与本机固件不同）。

---

## 4. 核心根因：vermagic 相同 ≠ ABI 相同（会直接 panic）

这是本项目踩过的最深的一个坑，**不要再走一遍**。

### 4.1 现象

早期做法：用设备的 `/proc/config.gz` 作为 `.config`，在上游 `linux-5.4.164` 源码上编译
`macvlan.ko`。结果：

- `vermagic` **完全一致**：`5.4.164 SMP preempt mod_unload ARMv7 p2v8`；
- `.plt` 段存在；`CONFIG_MODVERSIONS` 未启用、`CONFIG_MODULE_SIG` 未启用；
- ⇒ `insmod` **成功**，`lsmod` 能看到模块；
- ⇒ 一旦 `ip link add ... type macvlan` 建接口，**立即内核 panic**。

### 4.2 探针（canary）实测：`struct net_device` 布局不同

为了在不崩内核的前提下先判定 ABI，曾写过一个只读探针 `cr_abicheck.ko`
（读 `lo` 设备的各标量字段 + 打印 `lo` 结构体原始字节）。
**下面 `sizeof/offsetof` 那几行是探针自己（用上游头文件）编出来的编译期常量**，
后半段才是它在设备上实际读到的值：

```
sizeof(net_device)=1344 NETDEV_ALIGN=32 IFNAMSIZ=16 FIB=15
offsetof name=0 ifindex=168 mtu=324 min_mtu=328 max_mtu=332
offsetof type=336 hard_header_len=338 min_header_len=340 addr_len=379
offsetof flags=308 priv_flags=312 features=112 hw_features=120
offsetof tx_queue_len=656 state=44 perm_addr=346 dev_addr=464
offsetof netdev_ops=288 dev_addrs=420 broadcast=504 dev_list=48
  ok   name == 'lo' (got 'lo')
  ok   ifindex == 1 (got 1)
  FAIL lo mtu == 65536 (got 0)          ← 布局已错位
  FAIL lo addr_len == 6 (got 0)
  FAIL dev_addr == dev_addrs.list.next + 8
```

判词明确是 `RESULT=ABI_MISMATCH`。**而且探针本身也把内核打崩了**：探针退出路径上的
`dev_put()`（`net_device.h` 内联）按**上游偏移**去读 `dev->pcpu_refcnt`：

```
PC is at cr_abicheck_init+0x49c
r4 = dev = 8f831800   r3 = *(dev+0x2b8) = 0e13a000   ← 垃圾指针
Code: ... ldr r3,[r4,#0x2b8]; ... ldr r2,[r3,r1]     ← this_cpu_dec(*dev->pcpu_refcnt)
```

⇒ 设备上 `0x2b8` 处并不是 `pcpu_refcnt`。**只要模块用上游头文件里的偏移去碰结构体，就必炸。**

### 4.3 量化差异：设备的结构体大 64 字节

从设备上取回厂商自己编的 `tun.ko`（与设备内核同源），反汇编其 `tun_free_netdev`，
`netdev_priv(dev)` 被内联为一条 `add`：

| 模块 | 内联的 `ALIGN(sizeof(struct net_device), 32)` |
| --- | --- |
| 厂商 `tun.ko`（设备实际内核） | `add r4, r0, #1408 ; 0x580` |
| 本机上游 `tun.ko` | `add r6, r0, #1344 ; 0x540` |

**差 64 字节。** 同一函数里其它字段偏移也整体平移（例如末段字段 `+0x40`：
`0x240→0x280`、`0x2b8→0x2f8`、`0x2d8→0x318`）。

### 4.4 差异来自哪里（2026-09-11 已完全定位：+64 字节逐项对齐）

改变 `struct net_device` 的只有 **QSDK 对 `netdevice.h` 的文本级改动** 与 **配置开关**，四项相加正好 64：

| # | 来源 | 性质 | 字节 | 位置 |
| --- | --- | --- | --- | --- |
| 1 | `CONFIG_WIRELESS_EXT=y`（QSDK 里该符号**有 prompt**，设备 `=y`） | 配置开关 | **+8** | `wireless_handlers` + `wireless_data` 两指针，插在 `netdev_ops` **之前** |
| 2 | `unsigned int priv_flags_ext;`（QSDK 新增字段） | 源码 | **+4** | `priv_flags` 之后 |
| 3 | `unsigned char local_addr_mask[MAX_ADDR_LEN];`（QSDK 新增，32 字节） | 源码 | **+32** | `dev_addrs` 之后 |
| 4 | `_tx` 的对齐填充（`____cacheline_aligned_in_smp`，64 字节边界） | 对齐副作用 | **+20** | `_tx` 之前 |
| | **合计** | | **+64** | |

第 4 项最容易被忽略：前 3 项把 `_tx` 之前的偏移推了 +44，而 `_tx` 必须落在 64 字节边界，
于是它前面的填充从 20 涨到 40 字节，**净增 20**。（上游 `_tx`=576，QSDK `_tx`=640。）

**必须纠正的旧说法：`CONFIG_SKB_RECYCLER` 并不向 `struct net_device` 追加字段。**
QSDK 的 `netdevice.h` 里**没有任何** recycler 相关字段（全树 0 命中）；它的实现完全在
`net/core/skbuff_recycle.c` / `skbuff_recycle.h`，`sizeof(struct sk_buff)` 也**不变**（新增的只是位域）。
它会让“上游源码 + 原装 config”这条路丢符号，但**不是**布局差异的来源。

同理，`CONFIG_ETHERNET_PACKET_MANGLE` 那两块（`eth_mangle_rx/tx` 两指针 + `phy_ptr`，共 12 字节）
**在设备上是关闭的**（config 里连符号都不存在），对设备布局贡献 **0**。

⇒ 结论不变，但理由要写对：**即使用“设备原装 config + `olddefconfig`”，上游源码也补不回第 1–3 项**
—— 因为上游树里根本没有这些字段（第 2、3 项），且该符号无 prompt 会被直接丢掉（第 1 项）。
这才是“配置完全一致却依然 ABI 不匹配”的根因。

> 顺带说明 `CONFIG_WIRELESS=y`（上游根本没有这个符号）说明 QSDK 保留了**旧版无线 Kconfig**
> （`WEXT_CORE/SPY/PRIV` 一堆可见开关，且 `# CONFIG_CFG80211 is not set`）——这正是第 1 项能成立的前提。

> **结论（推翻旧文档的说法）：**
> 能得到可用 `macvlan.ko` 的**必要但不充分**条件是“设备原装内核配置”；
> 还必须加上**厂商 QSDK 内核源码**。只用上游源码 + 原装配置 ⇒ 必 panic。

---

## 5. 已验证不可行的替代方案（都别再用）

| 方案 | 实测结果 |
| --- | --- |
| **同 MAC 多 PPPoE**（`network.wan2` 或裸 `pppd` 跑在 `eth0`） | BRAS 主动发 **PADT** 踢掉会话：第二条会话出现时，原主会话立刻被断（`logread` 可见 `Recv PADT session 0x…`）。**同 MAC 多会话被接入侧禁止** |
| **VLAN 多拨**（`wan.3` 等） | 带标签 PADI 到不了 BRAS，PADO 永远超时 |
| **VLAN id 0**（想借“优先级标签”拿独立 MAC） | 内核在 `vlan_dev_hard_start_xmit()` 里**照旧插入 4 字节 802.1Q 头（TCI=0）**；实测 PADI 有发出（源 MAC 已改成新 MAC）但**无 PADO**，OLT/BRAS 丢弃带标签帧 |
| **内核内建虚拟网卡** | `/proc/config.gz`：`# CONFIG_MACVLAN is not set`、`# CONFIG_IPVLAN is not set`、`# CONFIG_VETH is not set`、`# CONFIG_DUMMY is not set`、`# CONFIG_NET_TEAM is not set`、`# CONFIG_BONDING is not set`；只有 `VLAN_8021Q=y`、`BRIDGE=y`、`TUN=m` |
| **换物理口** | 只有 `eth0` 是 WAN 口，`eth1` 是 LAN 交换口，拿不到第二个上行网卡 |
| **bridge** | 一台物理口只能属于一个 bridge，最多多出 1 个 MAC，数量不够 |

需要保留的唯一硬件事实：**每条 PPPoE 会话必须有独立源 MAC，且必须是“不带 VLAN 标签”的以太帧。**

---

## 6. 正确做法：用 QSDK 厂商内核源码自编 `macvlan.ko`

### 6.1 需要的材料

| 材料 | 位置 |
| --- | --- |
| **QSDK 内核源码** `linux-ipq-5.4` @ `d5fcb18e5420670c8734c6a659873e73adab6dac` | `kmod-build/qsdk/linux-ipq-5.4-<sha>.tar.gz`（取自主源 `https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-5.4`，实测 **166.7 MB**，国内约 176 KB/s、历时 16 分钟） |
| 同上，**更快的镜像**（备用） | GitHub `CodeLinaro-mirror/qsdk_oss_kernel_linux-ipq-5.4`（CodeLinaro 官方镜像，`clo/main`），commit 已验证存在：`https://codeload.github.com/CodeLinaro-mirror/qsdk_oss_kernel_linux-ipq-5.4/tar.gz/<sha>`；国内可用 `https://ghfast.top/` 前缀加速 |
| 设备内核配置（`/proc/config.gz` 导出） | `kmod-build/config-5.4.164-ax3000`（4633 行，注意原始文件是 **CRLF**，用前 `tr -d '\r'`） |
| ARMv7 交叉工具链（Bootlin glibc，gcc 11.3） | `kmod-build/armv7-eabihf--glibc--stable-2022.08-1/` |
| 厂商参考模块（ABI 比对用） | `kmod-build/vendor/tun.ko`、`ip_gre.ko`、`pppox.ko`（从设备取回） |
| 构建脚本 | `kmod-build/wsl-qsdk-build.sh` |
| 布局探针（只编译、永不加载） | `kmod-build/offdump/cr_offdump.c` + `wsl-offdump.sh` |
| WSL 环境 | Debian 13（trixie），构建树在 `/opt/kmod-build/linux-ipq-5.4` |

**源码身份校验**（解包后应立即确认，三条都必须命中）：

```sh
sed -n '1,6p' /opt/kmod-build/linux-ipq-5.4/Makefile      # EXTRAVERSION 必须为空 → UTS 5.4.164
grep -c priv_flags_ext    /opt/kmod-build/linux-ipq-5.4/include/linux/netdevice.h
grep -c local_addr_mask   /opt/kmod-build/linux-ipq-5.4/include/linux/netdevice.h
grep -A3 'config WIRELESS_EXT' /opt/kmod-build/linux-ipq-5.4/net/wireless/Kconfig | grep 'bool "'   # 必须有 prompt
```

目标 vermagic：`5.4.164 SMP preempt mod_unload ARMv7 p2v8`
（**注意：**`CONFIG_LOCALVERSION` 必须为空 —— 设备的 vermagic 里没有 `-qsdk-11.5.0.5` 后缀）。

### 6.2 构建

```sh
# 宿主机（Windows Git Bash）→ WSL
wsl.exe -d Debian -- bash /mnt/d/CampusNetworkRedial/kmod-build/wsl-qsdk-build.sh
```

脚本做四件事：

1. 解包 QSDK 源码到 `/opt/kmod-build/linux-ipq-5.4`；
2. 用设备 config 播种，`scripts/config --module MACVLAN / NETFILTER_XT_MATCH_STATISTIC / TUN`，
   然后 `olddefconfig` + `modules_prepare`；
3. **配置保真闸门**：逐个核对 `WIRELESS_EXT / SKB_RECYCLER / NET_L3_MASTER_DEV /
   MODVERSIONS / MODULE_SIG / ARM_MODULE_PLTS` 是否与设备一致，不一致就大声报错；
4. 编 `drivers/net/macvlan.ko`、`drivers/net/tun.ko`、`net/netfilter/xt_statistic.ko`，
   并打印 vermagic + `netdev_priv` 常量。

> ⚠️ 路径坑：5.4 的 macvlan 是**单文件** `drivers/net/macvlan.c`，
> 产物是 `drivers/net/macvlan.ko`，**没有** `drivers/net/macvlan/` 这个目录。
> 老文档里的 `M=drivers/net/macvlan` 是错的。

### 6.3 上机**之前**必须做的离线 ABI 自检（2026-09-11 已全部通过）

设备被崩过一次，所以“能编出来”不等于“能装到设备上”。
判据必须选**与编译器无关**的量：设备固件用的是 OpenWrt GCC **8.4.0**，本机是 Buildroot GCC **11.3.0**，
两者内联与寻址方式差异很大，逐函数反汇编比对（`offset-hist.py`）噪音很高，
**不能**把它当成通过/不通过的唯一判据（它的正则原先还把 `[sp, #N]` 栈帧偏移混进来，已修）。

三条可靠判据，全部与编译器无关：

**① `netdev_priv` 常量 = `0x580`**

```sh
<tc>/bin/arm-buildroot-linux-gnueabihf-objdump -dr out-qsdk/tun.ko | grep -E '#1408\s*; 0x580'
```
厂商 `tun.ko`、本机 `tun.ko`、本机 `macvlan.ko` **都命中 `#1408 ; 0x580`**；上游版是 `#1344 ; 0x540`。

**② 编译期 `offsetof` 表**（`kmod-build/offdump/cr_offdump.c`，**只编译、永不加载**）

把每个字段写成 `char cr_<f>[offsetof(struct net_device, <f>)];`，
数组**长度**即偏移量，用 `readelf -sW` 直接读出——全程不执行任何代码：

```sh
wsl.exe -d Debian -- bash /mnt/d/CampusNetworkRedial/kmod-build/wsl-offdump.sh
```

| 量 | 上游 5.4.164 | QSDK（设备同源） |
| --- | --- | --- |
| `sizeof(struct net_device)` | 1344 | **1408** |
| `sizeof(struct net_device_ops)` | 264 | **272** |
| `offsetof(pcpu_refcnt)` | `0x2b8` (696) | **`0x2f8` (760)** |
| `offsetof(dev_addr)` | `0x1d0` (464) | **`0x1fc` (508)** |
| `offsetof(netdev_ops)` | 288 | **296** |
| `offsetof(mtu)` | 324 | **336** |

**③ 设备侧真值签名（最终判据）**

设备上厂商自编的模块里，**`0x2f8` 出现 13 次（`tun.ko`）、1 次（`ip_gre.ko`）；`0x2b8` 出现 0 次**：

```sh
<tc>/bin/arm-buildroot-linux-gnueabihf-objdump -dr vendor/tun.ko | grep -c '0x2f8'   # 13
<tc>/bin/arm-buildroot-linux-gnueabihf-objdump -dr vendor/tun.ko | grep -c '0x2b8'   # 0
```

设备内核的 `pcpu_refcnt` 就在 **`0x2f8`**，与我们 QSDK 构建**完全一致**，与上游 `0x2b8` 明确不同。
**这正是上次 panic 的偏移**：canary 用上游头文件按 `0x2b8` 去读 `dev_put()`，读到垃圾指针。
（我们自编模块里出现的 `0x2b8` 全部只是 `bne/beq` 的**分支目标**，没有一处是 `pcpu_refcnt` 访问。）

本机实测汇总（2026-09-11）：

```
MODULE                     vermagic  0x2b8   0x2f8   0x580   netdev_ops
vendor/tun.ko              OK        0       13      10
vendor/ip_gre.ko           OK        0       1       14
out-qsdk/tun.ko            OK        2*      17      10
out-qsdk/macvlan.ko        OK        1*      3       10      272
out-qsdk/xt_statistic.ko   OK        0       0       0
* 仅为分支跳转目标，非 pcpu_refcnt 访问
```

> 结论口径：**①②③ 全过 = ABI 对齐**。`offset-hist.py` 只作辅助参考。
> **2026-09-11 实测：①②③ 全过，且上机后 `insmod` + 建/删 macvlan 接口全部通过（见 6.5）。**

### 6.4 部署到设备

```sh
python sshvm.py upload out-qsdk/macvlan.ko /tmp/macvlan.ko
python sshvm.py run '
  cp /tmp/macvlan.ko /lib/modules/5.4.164/macvlan.ko
  printf "%s\n" macvlan > /etc/modules.d/30-macvlan
  modprobe macvlan && ls -d /sys/module/macvlan
'
```

`opkg install` 依然会被内核依赖指纹拦住；自编模块直接放 `*.ko` 即可。
（也可以自己打一个 `.ipk`，`Depends` 写
`kernel (=5.4-qsdk-11.5.0.5-1-1d36e0bafcfe3798b2e9608e79ec8215)`。）

### 6.5 上机实测验收（**2026-09-11 已通过**）

实测步骤与结果：

```sh
insmod /tmp/macvlan.ko                 # RC=0
lsmod | grep macvlan                   # macvlan 24576 0
ls -d /sys/module/macvlan              # 存在
```

```sh
# 阴性对照：macvlan 建在桥端口上必然失败（桥端口已被 br_handle_frame 占用 rx_handler）
ip link add link eth1 name crtest0 type macvlan mode bridge
#   -> RTNETLINK answers: Resource busy        (RC=2，干净失败，不崩)

# 正例：建在 br-lan 上（ARPHRD_ETHER / UP / 自身无 rx_handler）
ip link add link br-lan name crtest type macvlan mode bridge     # RC=0
#   13: crtest@br-lan: <BROADCAST,MULTICAST> mtu 1500 ... macvlan mode bridge
ip link set crtest address 02:aa:bb:cc:dd:01                     # RC=0
ip link set crtest up                                            # RC=0
#   crtest@br-lan  UP  02:aa:bb:cc:dd:01 <BROADCAST,MULTICAST,UP,LOWER_UP>
#   /sys: mtu 1500, addr_len 6, type 1, flags 0x1003, operstate up
#   ip -s link: TX 110 bytes / 1 packet          <- 数据路径真的走通了
ip link del crtest                                               # RC=0
```

- 整个过程中 `dmesg` **没有任何新的 oops**；内核日志里只有
  `device br-lan entered/left promiscuous mode`（macvlan 对下层设备的标准动作）。
- `pppoe-wan` 地址、默认路由、`br-lan` 全部正常，`uptime` **未归零**。
- 结束后按“最小验证”约定 `rmmod macvlan` 还原：`lsmod` 无 macvlan、`/sys/module/macvlan` 消失、
  `/lib/modules/5.4.164/macvlan.ko` 与 `/etc/modules.d/30-macvlan` **均未创建**（只在内存里，没写 flash）。
  > 这一步是**只读内存**的最小验证。**持久化**是随后单独做的一步，见 §6.6。

**两个上机才会遇到的坑：**

1. ~~Busybox 的 `ip` 不支持 `ip link add ... address <mac>`~~ —— **此说法已作废（2026-09-11 更正）**。
   设备上装的是 **`ip-full`（iproute2 5.11.0）**，不是 busybox 的 `ip`，
   它在设备上 `ip -V` 明确输出 `ip utility, iproute2-5.11.0`。
   当时的 `unknown option "address"` 是 **iproute2 的参数顺序问题**：`address` 必须写在
   `type macvlan` **之前**。两种写法都可用：

   ```sh
   # 写法 A（一步到位，address 在 type 之前）
   ip link add link br-lan name crtest address 02:aa:bb:cc:dd:01 type macvlan mode bridge

   # 写法 B（两步，本次实测用的就是这种）
   ip link add link br-lan name crtest type macvlan mode bridge
   ip link set crtest address 02:aa:bb:cc:dd:01
   ```

   写成 `... type macvlan mode bridge address <mac>`（address 在 type 之后）才会报
   `unknown option "address"`。**这与内核无关，纯粹是用户态解析顺序。**
2. **不能把 macvlan 建在桥端口上**（如 `eth1`）：
   `macvlan_port_create()` 要求 `dev->type == ARPHRD_ETHER`（`br-lan` 满足）且
   `!netdev_is_rx_handler_busy(dev)`；桥端口的 rx_handler 已被 `br_handle_frame` 占用 ⇒ `-EBUSY`。
   测试时请建在**桥设备本身**（`br-lan`）上，不要建在它的端口上。

抓 panic 日志仍按第 8 节的 `kmsg-capture.py` 双通道方式（本次三条日志：
`kmod-build/capture-macvlan-{1,2,3}.log`）。
**如果哪天又要重启，说明 ABI 仍未对齐，立即按第 8 节回滚。**

### 6.6 持久化 + 装 mwan3（**2026-09-11 已完成**）

机主确认后执行。**会写 flash/overlay**，但完全可回滚。

**① 持久化内核模块**

```sh
cp macvlan.ko     /lib/modules/5.4.164/        # sha256 abb1fda3…6786
cp xt_statistic.ko /lib/modules/5.4.164/       # sha256 6bb95872…a4bd7
printf 'macvlan\n'      > /etc/modules.d/30-macvlan
printf 'xt_statistic\n' > /etc/modules.d/55-xt-statistic
modprobe macvlan ; modprobe xt_statistic       # 两个 RC=0
```

实测 `lsmod` 两个模块都在，`uptime` 未归零，无 oops。回滚：删这两个 `.ko` 与
`/etc/modules.d/{30-macvlan,55-xt-statistic}`，再 `rmmod`。

**② mwan3 依赖的真实分布（关键）**

`mwan3` 的 `Depends: libc, ip, ipset, iptables, iptables-mod-conntrack-extra, iptables-mod-ipopt, jshn`
里，设备唯一缺的是 **`iptables-mod-ipopt`**，而它**不在 `packages/base` feed**——
`iptables-mod-ipopt` 与 `kmod-ipt-ipopt` **只存在于 target 的 core feed**（本机 `ipq50xx` 的
core feed 是 404，因为官方 21.02.7 没有这个 target）。
解决办法：从 **`ipq40xx/generic` 的 core feed** 取**同架构**（`arm_cortex-a7_neon-vfpv4`）的
`iptables-mod-ipopt_1.8.7-1_arm_cortex-a7_neon-vfpv4.ipk`，它只提供**用户态**
`/usr/lib/iptables/libxt_statistic.so`（以及 dscp/ecn/length/tcpmss 等 .so）。
**内核侧的 `kmod-ipt-ipopt` 绝对不能用借来的** `.ko`（那是为 ipq40xx 内核编的，ABI 不符），
必须用我们自己按 QSDK 源码编的 `xt_statistic.ko`。

**③ 自打一个 `kmod-ipt-ipopt` 包**

用 `kmod-build/pkg/mkunipk.py`（本次新写）生成
`kmod-ipt-ipopt_5.4-qsdk-11.5.0.5-1_arm_cortex-a7_neon-vfpv4.ipk`（2452 B），内容：

| 项 | 值 |
| --- | --- |
| payload | `/lib/modules/5.4.164/xt_statistic.ko`、`/etc/modules.d/55-xt-statistic` |
| Depends | `kernel (= 5.4-qsdk-11.5.0.5-1-1d36e0bafcfe3798b2e9608e79ec8215), kmod-ipt-core` |
| Architecture | `arm_cortex-a7_neon-vfpv4` |

安装顺序必须是 **先 `kmod-ipt-ipopt`，再 `iptables-mod-ipopt`，最后 `mwan3`**。

**④ 三个必须记住的坑**

1. **opkg 的“架构不兼容”是假象。** 在 `kmod-ipt-ipopt` 缺失时，
   `opkg install iptables-mod-ipopt` 会报：

   ```
   pkg_hash_fetch_best_installation_candidate: Packages for iptables-mod-ipopt
       found, but incompatible with the architectures configured
   ```

   但 `-V3` 显示它的 `arch=arm_cortex-a7_neon-vfpv4 arch_priority=10` —— **架构完全匹配**。
   `--force-depends` 也**不能**绕过。真正原因是**未解析的 kmod 依赖把候选标记成了
   incomplete**，opkg 用一句误导性的架构错误盖住了它。**装好 `kmod-ipt-ipopt` 后立刻恢复正常**
   —— 不要再顺着“架构”这条线索查下去。
2. **21.02 的 `.ipk` 不是 `ar` 归档**，而是
   `gzip(tar(./debian-binary, ./control.tar.gz, ./data.tar.gz))`。
   外层 gzip 是**必需**的：给它一个未压缩的 tar 会得到
   `pkg_init_from_file: Malformed package file`。feed 上的 `.ipk` 本身就是 gzip 的
   （设备自己 `wget` 下来的字节与本地 curl 下载完全一致，都是 `1f 8b`）。
3. **QSDK 改了符号名**：`xt_mark.o` 由 `CONFIG_NETFILTER_XT_MARK` 控制，
   而不是上游的 `CONFIG_NETFILTER_XT_MATCH_MARK`。
   所以“设备 config 写着 `MATCH_MARK is not set`，但 `/lib/modules/5.4.164/xt_mark.ko` 确实存在”
   **不是矛盾**，也不是 config 抓错了。

**⑤ 验收**

```sh
iptables -t mangle -N CRSTATEST
iptables -t mangle -A CRSTATEST -m statistic --mode random --probability 0.25 -j RETURN   # RC=0
iptables -t mangle -S CRSTATEST     # -A CRSTATEST -m statistic --mode random --probability 0.25000000000 -j RETURN
iptables -t mangle -F CRSTATEST ; iptables -t mangle -X CRSTATEST                          # 干净退出
```

最终状态：`mwan3 2.10.13-1` + `luci-app-mwan3` + `iptables-mod-ipopt 1.8.7-1` +
`kmod-ipt-ipopt 5.4-qsdk-11.5.0.5-1` 均 `install user installed`。
mwan3 安装后**会自动 enable 并启动**（`/etc/rc.d/S19mwan3`）；实测
`mwan3 status` → `interface wan is online`，`pppoe-wan`（10.194.238.20）/默认路由/`br-lan`/
uhttpd:80 全部正常，`uptime` 未归零，`logread` 无新增 oops。

> **注意**：本包只提供 `statistic` 这一个 ipopt 内核 match（mwan3 加权分流只用它）。
> `iptables-mod-ipopt` 用户态还带 `libxt_dscp/ecn/length/tcpmss/…`，但**这些在本固件上没有对应内核模块**，
> 写 `-m dscp` 之类会报 `No such file or directory`。需要的话得按同样流程各自编译。

---

## 7. 兜底方案：用户态 TAP 中继（不需要内核模块）

当自编 `.ko` 这条路彻底走不通时的替代：

- 内核有 `TUN=m`（`kmod-tun` 已安装），可创建带独立 MAC 的 TAP 设备；
- 缺点：TAP 的收发都要经过用户态进程，需要一个把 TAP ↔ `eth0` 互转、并改写源 MAC 的 L2 中继；
- 需要一个能跑在设备上的静态 ARM 二进制（Zig `zig cc -target arm-linux-musleabihf -static`
  可在 Windows 上交叉编译），并评估吞吐（5 条会话的数据面都会过这个进程）。

优先度低于自编 `macvlan.ko`。

---

## 8. 安全与回滚

- **危险模块绝不要留在设备上**。2026-09-10 已确认设备上没有残留：
  `/lib/modules/5.4.164/macvlan.ko` 与 `/etc/modules.d/30-macvlan` 均不存在，
  `modprobe macvlan` 直接失败（rc=255）⇒ `campus-rediald` 会走“内核未提供 macvlan”的明确报错分支，
  而不是先以为“模块可用”再去创建接口把内核打崩。
- 回滚：确认 `lsmod | grep macvlan` 为空、`/lib/modules/5.4.164/macvlan.ko` 不存在、
  `/etc/modules.d/` 里没有 `30-macvlan`。`/etc/config/network` 的原始备份在设备
  `/etc/config/network.campus-redial.bak`。
- **抓 panic 日志的正确姿势**：`kernel.panic=3` 会 3 秒后重启，来不及看。
  抓取前先 `sysctl -w kernel.panic_on_oops=0`，用 `kmsg-capture.py`
  （一条 SSH 通道持续读 `/dev/kmsg` 并 `fsync` 落盘，另一条通道触发 `insmod`）。
- 任何会打断 WAN 的实验（同 MAC 多拨、VLAN 拨号）结束后都要 `ifup wan` 并确认
  `ip -4 addr show pppoe-wan` 与 `ip route | grep default` 恢复正常。
- **未刷固件、未改动固件分区。** `/etc/config/network` 仅在测试需要时增删过临时 section。

---

## 附录 A：已排查并排除的预编译来源

| 来源 | 结论 |
| --- | --- |
| 官方 `downloads.openwrt.org` `targets/ipq50xx/arm/packages` | 404，官方从未发布该 target |
| `hzyitc.github.io/openwrt-redmi-ax3000`（保留 10 个构建） | 指纹全为 `6be5791b…`，与本机不符 |
| `hzyitc` gh-pages 历史（41 个 commit，最早 2023-05-22） | 2023 年构建目录从未进入历史 |
| `armvirt/32`、`ipq40xx/generic` 等其它 target | vermagic 与 PLT 均不匹配 |
| `openwrt.hurl.live` 社区镜像 | 目标路径 404 |
| 各 fork 的 gh-pages | 见 `memory/` 当日记录 |

## 附录 B：诊断脚本清单（`kmod-build/`）

| 脚本 | 用途 |
| --- | --- |
| `wsl-setup.sh` | WSL 内解包上游内核源码 + 工具链到 ext4 |
| `wsl-qsdk-build.sh` | **当前正确路线**：QSDK 源码 → 三个 `.ko` + 配置闸门 + ABI 自查 |
| `wsl-extract-qsdk.sh` | 解包 QSDK 源码到 `/opt/kmod-build/linux-ipq-5.4` 并校验源码身份 |
| `offdump/cr_offdump.c` + `wsl-offdump.sh` | **只编译不加载**的 `offsetof` 表，量出两套树的真实布局 |
| `wsl-final.sh` | 输出最终 ABI 判定表（vermagic / `0x2b8` / `0x2f8` / `0x580`） |
| `offset-hist.py` | 辅助：比对两个 `.ko` 各函数用到的结构体偏移集合（**已修掉把 `[sp,#N]` 栈帧偏移当结构体偏移的 bug**；跨编译器时噪音大，不作唯一判据） |
| `analyze-dump.py` | 解析探针打印的 `lo` 结构体原始字节，反推真实字段偏移 |
| `kmsg-capture.py` | 抓 panic/oops 日志（双 SSH 通道 + 落盘 `fsync`） |
| `static-check.sh` / `config-drift.sh` / `config-diff-lf.sh` / `missing-syms.sh` | 配置差异与缺失符号核查 |
| `remote/cr-load.sh` | 上机第 1 步：`insmod` + `lsmod`/sysfs/`dmesg` 自检 |
| `remote/cr-iface.sh` | 上机第 2 步：建/验/删测试 macvlan（含 `eth1` 阴性对照） |
| `remote/cr-persist.sh` | 上机第 3 步：持久化到 `/lib/modules/5.4.164/` + `/etc/modules.d/`（**写 flash**） |
| `pkg/unipk.py` | 读 `.ipk`（列成员 / 解包） |
| `pkg/mkunipk.py` | **写 `.ipk`**（生成 OpenWrt 21.02 的 gzip-tar 格式包） |
| `speedtest-mirrors.sh` | QSDK 源码镜像测速（CodeLinaro 主源 vs GitHub 镜像） |

### 踩过的脚本坑（别再犯）

- **设备 config 是 CRLF**：任何 `grep '^CONFIG_X='` 都会带回 `\r`，比对时全变“不一致”。
  用前一律 `tr -d '\r'`。
- **Windows Git Bash 里的 curl 不认 `/dev/null`**（`-o /dev/null` 报 `client returned ERROR on write`），
  测速/探测要用真实临时文件。
- **WSL 的 `/tmp` 是 tmpfs**，WSL 实例空闲退出后内容会丢；跨 `wsl.exe` 调用别依赖 `/tmp` 传文件。
- `awk` 的 `strtonum()` 只有 gawk 有；Debian 默认 mawk 会报 `function strtonum never defined`。
- 输出 `vermagic` 的字符串**带尾空格**，字符串比较前先 `sed 's/[[:space:]]*$//'`。
- **Windows 路径传参**：`sshvm.py` 这种从 Git Bash 调用时，
  `/c/Users/...` 会被改写成 `d:\c\Users\...`；用 `C:/Users/...` 正斜杠形式的绝对路径。
- 设备 busybox 缺 `od`，看原始字节用 `hexdump -C`。
- 设备 busybox 的 `tar -xzOf` 对嵌套 gzip 不稳；用 `gzip -dc | tar -xO` 逐层展开。
