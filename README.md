# 校园网出口检测 + 自动重拨

<a href="https://github.com/Introduce183/campus-network-redial"><img src="https://img.shields.io/badge/o(%3E%E2%96%BD%3C)o%20%E7%BB%99%E6%88%91%E7%82%B9%E4%B8%AAstar%E5%96%B5-e0a587?style=flat-square" alt="o(&gt;▽&lt;)o 给我点个star喵" width="300"></a>

拨号上网时，每次拨号可能分配到不同的出口。好出口一切正常；坏出口会对部分服务限速，导致某些应用加载不出来。

本项目做三件事：

| 能力 | 说明 | 实现位置 |
| --- | --- | --- |
| **出口检测 + 自动重拨** | 用真实业务做探针判断当前出口好坏，不好就断开重拨，直到拿到好出口；也可用"下载测速超阈值"作为判定 | Windows（C# / PowerShell）+ OpenWrt（LuCI 应用） |
| **多拨连接池** | 同一账号建立多条 PPPoE 会话（各自独立 MAC），用 mwan3 按连接分流，聚合带宽 | OpenWrt |
| **SNI 分流** | 扰乱 TLS ClientHello，使链路中间的 DPI 读不到 SNI，从而绕开按域名的黑名单限速 | OpenWrt（zapret：nfqws / tpws） |

> **本仓库不实现**绕过认证、伪造凭据、修改白名单或探寻未授权带宽通道的功能。
> 它只恢复/维护**你自己已有**的拨号连接，只操作配置中指定的 WAN 接口。

---

## 目录结构

```
campus-network-redial/
├── README.md                  # 本文件：项目总入口
├── docs/                      # 项目文档（见下方索引）
│   └── reference/             # 深度技术参考（自编内核模块 / SNI 分流）
├── CampusRedialWrt/           # ★ OpenWrt 侧全部脚本与代码
│   ├── luci-app-campus-redial/   # LuCI 应用（守护进程、rpcd 插件、前端、Makefile）
│   ├── tools/                    # 安装/卸载/构建脚本 + 内嵌 zapret 发行包
│   ├── kmod-build/               # 自编内核模块的构建脚本与上机脚本（本机机型专用）
│   └── dist/                     # 历史构建产物（25.12 apk、包源码归档）
├── memory/                    # 逐次调试的工作日志（含实测数据与踩坑记录）
├── plan.md                    # OpenWrt 侧的原始设计与验收标准
├── HANDOFF-POOL.md            # 多拨连接池的移交现场记录
├── INSTALL.md                 # 安装入口（指向 docs/）
└── （Windows 侧）              # C# 控制台程序 + PowerShell 脚本 + 托盘通知
    Program.cs  RedialCoordinator.cs  ProbeClient.cs  RasdialClient.cs
    DialNameResolver.cs  AppOptions.cs  TrayNotifier.cs
    Redial-UntilCampusReady.ps1/.bat  Test-CampusExit.ps1  Set-AutoStart.ps1/.bat
```

---

## 快速开始

### A. Windows 单机（零依赖，只要已保存拨号连接的账号密码）
（PS：PS脚本详细用法见底部） 

```powershell
# 只检测当前出口，不拨号
powershell -ExecutionPolicy Bypass -File .\Test-CampusExit.ps1

# 自动重拨直到拿到好出口（也可直接双击 Redial-UntilCampusReady.bat）
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -DialName "校园网"

# 要求下行超过 150 Mbps 才算好出口
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -DialName "校园网" -200MbpsMode
```

C# 版本（需要 .NET 8 SDK）：

```powershell
dotnet run --project .\CampusNetworkRedial.csproj -- --help
dotnet run --project .\CampusNetworkRedial.csproj -- --test-only --normal-mode
dotnet run --project .\CampusNetworkRedial.csproj -- -200MbpsMode --dial-name "校园网" --max-attempts 5
```

### B. OpenWrt 路由器接管（全局生效，含多拨与 SNI 分流）

1. **部署**：见 [docs/02-部署-通用.md](docs/02-部署-通用.md)（构建 `.ipk` → 安装 → 填账号）；
   本机 Redmi AX3000 因为内核特殊，还要走
   [docs/03-部署-AX3000-自编内核模块.md](docs/03-部署-AX3000-自编内核模块.md)。
2. **使用**：LuCI「服务 → 校园网自动重拨和集流」+ 同页「SNI 分流」，或命令行
   `/usr/sbin/campus-redialctl start`。详见 [docs/04-使用方法.md](docs/04-使用方法.md)。
3. **出问题**：见 [docs/05-故障排查.md](docs/05-故障排查.md)。

---

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/01-项目原理.md](docs/01-项目原理.md) | 为什么这么做：出口质量、检测原理、重拨状态机、多拨为何可行、mwan3 分流、SNI 限速与对抗、nfqws vs tpws |
| [docs/02-部署-通用.md](docs/02-部署-通用.md) | **通用 OpenWrt 部署**：构建、安装、初始配置、多拨与 SNI 分流的可选步骤、升级卸载 |
| [docs/03-部署-AX3000-自编内核模块.md](docs/03-部署-AX3000-自编内核模块.md) | **本机特殊改动**：为什么 opkg 装不上 kmod、如何用厂商源码树自编并通过 ABI 闸门、打包安装、验收与回滚 |
| [docs/04-使用方法.md](docs/04-使用方法.md) | 装好之后怎么用：Windows 参数、LuCI 面板逐项、命令行、状态文件、典型操作剧本 |
| [docs/05-故障排查.md](docs/05-故障排查.md) | 按现象查原因：拨号/认证、连接池、SNI 分流、内核模块 ABI、以及测量方法学陷阱 |
| [docs/reference/AX3000-KMOD-BUILD.md](docs/reference/AX3000-KMOD-BUILD.md) | 自编内核模块的完整技术记录（ABI 差异逐项来源、判据、上机实测） |
| [docs/reference/SNI-DESYNC.md](docs/reference/SNI-DESYNC.md) | SNI 分流的部署与验收指南（多版本 OpenWrt、多种排障场景） |
| [docs/README.md](docs/README.md) | 文档导航 + `memory/` 工作日志索引 |

---

## 实测状态与边界

诚实说明各部分的验证程度，避免误用：

| 部分 | 状态 | 说明 |
| --- | --- | --- |
| Windows 检测/重拨 | 可用 | C# 与 PowerShell 两套实现；探针地址请换成自己可达的 |
| LuCI 应用（单会话） | 21.02.7 实机运行中 | 仓库**未附**已验收的 21.02.7 成品包，需按文档自行构建 |
| 多拨连接池 | 实机运行中（4~5 路） | 依赖 `kmod-macvlan`；认证间隔需 60 秒；BRAS 侧对同一账号的并发会话数有限制 |
| mwan3 按连接分流 | 实机运行中 | 每接口路由表需要默认路由来源，否则接口被判 `error (16)` 而完全不分流（见故障排查） |
| SNI 分流（nfqws） | 实机运行中 | 转发路径 16 路明文 HTTP 实测 312~315 Mbps（tpws 为 173~180，完全不经手 355；**均为未开转发快路径时**） |
| 转发快路径（flow offload） | 实机运行中 | **决定聚合上限的关键**：开启后 10/20/40 流 = 621~696 / 688~707 / 717 Mbps，CPU 峰值 99.5% → ~70%，且 SNI 混淆照常生效；未开则被 CPU 卡在 ~350 Mbps（见 `docs/01` §5、`docs/05` §3.7） |
| SNI 分流（tpws） | 可用（回退） | 只需 `nat` 表，几乎所有固件都能跑；代价是下行吞吐被用户态代理削半 |
| 自编内核模块 | 实机运行中 | macvlan / xt_statistic / nfnetlink_queue / xt_NFQUEUE；详见 03 与 reference |

---

## 重要提示

1. **探针与测速地址必须换成自己学校/运营商可达且授权的地址。** 仓库默认值
   （斗鱼 CDN 接口、西电 `test.xidian.edu.cn`）只是实测环境的示例。
2. **凭据不入库。** 部署时账号密码只写入设备的 `/etc/config/campus-redial`（权限 `0600`），
   不会出现在状态 RPC、日志或前端返回值里；本仓库文档中的凭据位置一律为占位符。
3. **变更纪律**：装/删内核模块、改 `/etc/config/network`、跑会打断 WAN 的实验、重启设备，
   都应当先说明并获得机主同意。
4. **SNI 分流用错姿势会断网**：停用前必须"先摘跳转、再停进程"，否则 LAN 的 80/443 会被
   指向死端口（连管理面板都打不开）。用 `cr-nfq-switch.sh` 或面板按钮，别直接 `stop`。

---

## 目录重组说明（2026-09-11）

OpenWrt 侧代码从仓库根迁到 `CampusRedialWrt/`，文档统一到 `docs/`。
`memory/`、`HANDOFF-POOL.md`、`plan.md` 里早于本次重组的日志**仍使用旧路径**，
对照关系如下（读旧日志时按此换算）：

| 旧路径 | 新路径 |
| --- | --- |
| `luci-app-campus-redial/` | `CampusRedialWrt/luci-app-campus-redial/` |
| `tools/` | `CampusRedialWrt/tools/` |
| `docs/reference/SNI-DESYNC.md` | `docs/reference/SNI-DESYNC.md` |
| `docs/reference/AX3000-KMOD-BUILD.md` | `docs/reference/AX3000-KMOD-BUILD.md` |
| `kmod-build/`（原在仓库外） | `CampusRedialWrt/kmod-build/`（大件构建输入仍在仓库外，见该目录 `.gitignore`） |
| `luci-app-campus-redial-1.0.0-r1.apk`、`std-package-source.tar` | `CampusRedialWrt/dist/` |

---

## 来源与致谢

- 原始项目：[Introduce183/campus-network-redial](https://github.com/Introduce183/campus-network-redial)
  （README 顶部的 star 徽章指向它）。本仓库是在其基础上的扩展：增加了 OpenWrt 侧实现、
  多拨连接池、SNI 分流，以及针对特定机型的内核模块自编流程。
- SNI 分流使用上游工具 [zapret](https://github.com/bol-van/zapret)（`nfqws` / `tpws`），
  仓库内 `CampusRedialWrt/tools/zapret-embedded.tar.gz` 是其官方发行包（GPL）。
- 内核模块的全部构建材料来自设备固件自身的厂商源码树（Qualcomm QSDK），
  版本与 commit 记录在 [docs/03-部署-AX3000-自编内核模块.md](docs/03-部署-AX3000-自编内核模块.md)。

## 许可

本项目以 **GNU General Public License v2.0** 发布，全文见仓库根目录的 [LICENSE](LICENSE)。

第三方组件与它们的许可：

| 组件 | 位置 | 许可 |
| --- | --- | --- |
| LuCI 应用与脚本（本项目主要代码） | `CampusRedialWrt/` | GPL-2.0（本仓库） |
| **zapret**（`nfqws` / `tpws`，SNI 分流引擎） | `CampusRedialWrt/tools/zapret-embedded.tar.gz` | 上游 GPL-2.0 发行包，未做修改 |
| 自编内核模块（macvlan / xt_statistic / NFQUEUE） | `CampusRedialWrt/kmod-build/out-*/` | 由设备固件自身的厂商内核源码（Qualcomm QSDK，GPL-2.0）构建 |

Windows 侧的 C# / PowerShell 代码与 OpenWrt 侧同属本仓库，采用同一许可。

> 注：历史的构建产物目录 `CampusRedialWrt/dist/`（25.12 的历史 `.apk`、早期源码归档）**不入库**，
> 现由 release 附件提供；其中那份 `std-package-source.tar` 是**旧的 25.12/ucode 版本**，不要再用它构建。
`Switch-NetworkPath.ps1` 则在同一套探针之上做**常驻主备管理**：拨号作主用、Wi-Fi 作保底，两者自动切换，保证任何时候都至少有一条可用出口。**找出口的整个过程你都在 Wi-Fi 上，只有确认可用的出口才会被提为主用。**





# PS脚本用法


## 检测原理

用一个在线服务作为探针：好出口能快速连通它的接口，坏出口则会被限速到请求超时。当前探针使用斗鱼直播的接口。

## 环境要求

- Windows，已保存拨号连接的账号密码
- PowerShell 5.1+
- **网络管理器需要管理员权限**（要改电话簿里的拨号条目开关、加删路由）；`Test-CampusExit.ps1` 和 `Redial-UntilCampusReady.ps1` 不需要

## 用法

### 常驻网络管理器：Wi-Fi 保底 + 拨号主用（推荐）

> ### ⚠️ 启用前必读
>
> **1. 开启这个脚本之前，必须先连上热点（Wi-Fi）。**
> 脚本的原理是"把拨号停放到 Wi-Fi 旁边、流量跑在 Wi-Fi 上、拨号只做后台候选"，所以 Wi-Fi 是它的硬前提。
> 热点没连上时它会**拒绝启动并退出，不做任何改动** —— 因为那种情况下停放等于把流量丢进黑洞
> （拨号让出默认路由，而 Wi-Fi 给不出路由），会变成彻底没有网络出口。
>
> **2. 此脚本只保证一直都有可用网络，可能会在校园网与热点之间切换，不保证游戏时的稳定性。**

双击 `Switch-NetworkPath.bat`（会弹一次 UAC）。它会常驻运行：

1. **首次运行会装一个开关**：把拨号条目在电话簿里的 `IpPrioritizeRemote` 改成 `0`，也就是关掉拨号的"在远程网络上使用默认网关"。拨号仍然正常连接（拿到 IP、链路可用），但不再抢默认路由 —— 于是**每次拨上都是"停放态"，流量留在 Wi-Fi 上**。
2. 在 Wi-Fi 承载的前提下验证这个新出口（三轮确认，见下）。
3. 只有全部通过、并且确认探针确实是从拨号出口发出去的，才**加一条指向拨号的默认路由**把它提为主用。
4. 成为主用后每隔一段时间做健康检查，连续两次失败就**删掉那条默认路由**（流量立刻回到 Wi-Fi，拨号 IP 都不变），再换一个出口重拨。
5. 退出时会把电话簿里的开关还原成 `1` 并重连，让机器回到"拨号当默认网关"的常态。

一句话：**你几乎不会察觉到它在换出口。**

查看当前走哪条出口（只读，不拨号、不断线、不需要提权）：

```powershell
powershell -ExecutionPolicy Bypass -File .\Switch-NetworkPath.ps1 -Status
```

运行日志在 `logs\network-path.log`（超过 1 MB 自动滚成 `.1`）。按 `Ctrl+C` 停止。

同一时刻只允许一个实例在跑，重复启动会被互斥体挡掉。

> ⚠️ **如果管理器被硬杀（直接关窗口 / 结束进程），电话簿里的开关会留在 `0`**，此时拨号连上也不会当默认网关 —— 也就是你会一直在 Wi-Fi 上。想恢复：重跑一次管理器，或者跑
> `powershell -ExecutionPolicy Bypass -File .\Switch-NetworkPath.ps1 -Status` 看状态。管理器正常 `Ctrl+C` 退出时会自动还原。
> 不想还原（例如你想让它一直待在 Wi-Fi 上）可以用 `-KeepParkedOnExit`。

### 只检测当前出口（不拨号）

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-CampusExit.ps1
```

### 自动重拨直到好出口

最简单的方式：直接双击 `Redial-UntilCampusReady.bat`。它会先自动检测拨号上网电话簿里的宽带名称，再用检测到的名称运行主脚本。

也可以手动在 PowerShell 里运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1
```

脚本会自动识别拨号连接名；识别不到时默认使用“宽带连接”。也可以手动指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -DialName "校园网"
```

按 `Ctrl+C` 可随时停止。

### 高速模式：重拨直到带宽达标

如果只关心出口带宽，可以用 `-HighBandwidthMode`：脚本会重拨并测速，直到西电 LibreSpeed 下载测速超过 150 Mbps 才停下。

```powershell
powershell -ExecutionPolicy Bypass -File .\Redial-UntilCampusReady.ps1 -HighBandwidthMode
```

该模式与 `-TestOnly` 互斥，不能同时使用。

### 设置开机自启

双击 `Set-AutoStart.bat`（会弹一次 UAC）。菜单里两个自启条目互相独立，可以分别开关：

- 自动重拨脚本（前台窗口，拿到好出口后停下）—— 走 HKCU Run 键
- 网络管理器（登录后后台常驻，无窗口）—— 走**最高权限计划任务**

两者不要同时开，它们会互相抢 `rasdial`。建议只开网络管理器。

管理器之所以用计划任务而不是 Run 键：它必须提权才能改电话簿和路由，而 Run 键没法让进程提权，用 Run 键启会每次登录弹一次 UAC。

## 判定逻辑

- 每轮探测多次，全部通过才算一轮通过。
- 三轮探测（两段间隔确认）都通过，才判定为“好出口”；第三轮之前等待更久，避免前两轮通过后出口仍不稳定。
- 判定为好出口后，脚本提示“好了喵”（署名 introduce），并询问是否继续测速或者重新拨号：输入 `Y` 继续重新探测，探测失败会自动重新拨号，成功则继续提示不退出；输入其它任意键退出。

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DialName` | 自动识别 | 拨号连接名（`rasdial` 可查看）|
| `-TestOnly` | 关 | 只测当前网络，不拨号 |
| `-HighBandwidthMode` | 关 | 高速模式：重拨直到测速超过 150 Mbps（不能与 `-TestOnly` 同时使用）|
| `-TimeoutSeconds` | 4 | 每次探测超时秒数 |
| `-ProbeCount` | 3 | 每轮探测次数 |
| `-SettleSeconds` | 3 | 拨号后等待多少秒再探测 |
| `-ConfirmIntervalSeconds` | 12 | 第 1、2 轮确认之间的间隔秒数 |
| `-ThirdIntervalSeconds` | 30 | 第 2、3 轮确认之间的间隔秒数 |
| `-PauseSeconds` | 2 | 重拨之间的等待秒数 |
| `-MaxAttempts` | 0 | 最大重拨次数，0 表示一直重拨直到成功 |

## 网络管理器（`Switch-NetworkPath.ps1`）

### 主备怎么切

靠一个电话簿开关 + 运行时加删一条路由。三段都经过实机验证。

**1. 停放（一次性安装，需提权）** —— 把拨号条目的 `IpPrioritizeRemote` 从 `1` 改成 `0`：

```
[校园网-1]
IpPrioritizeRemote=0     ← "在远程网络上使用默认网关" 关掉
```

拨号照常连接，但**不安装默认路由**。RAS 只在连接时读这个值，所以改完要重连一次；但那是一次性的，不在循环里。由此得到"停放态"：**拨号连着，流量走 Wi-Fi。**

**2. 晋升 / 降级（运行时，需提权，不重连）**

| 动作 | 操作 | 效果 |
| --- | --- | --- |
| 晋升 | `New-NetRoute` 加一条指向拨号的默认路由 | 流量回到拨号，**拨号 IP 不变** |
| 降级 | `Remove-NetRoute` 删掉那条 | 流量回到 Wi-Fi，**拨号 IP 不变** |

路由的 `RouteMetric` 取到让拨号的有效跃点（`RouteMetric + 接口跃点`）小于 Wi-Fi 的即可。

**3. 探测停放中的拨号出口（运行时，需提权）** —— 拨号没有默认路由时探针会跟着走 Wi-Fi，所以探测前给 canary 的 IPv4 装 `/32` 主机路由指向拨号接口，探完删掉。`/32` 是最具体前缀，必然胜过默认路由。

### 为什么不用"改跃点"来切

实测过，都不可靠：

| 手段 | 实测结果 |
| --- | --- |
| `Set-NetIPInterface` 改拨号跃点 | 表上有效跃点确实变了（WLAN 5 vs 拨号 6001），**实际流量仍在拨号** |
| 电话簿里 `IpInterfaceMetric=6000` | 重连后接口跃点确实是 6000、表上 WLAN 赢，**实际流量仍在拨号** |
| 事后 `Remove-NetRoute` 删拨号默认路由 | 对外访问直接不通，连绑 Wi-Fi 源也救不回来 |
| `SkipAsSource=true` 于拨号地址 | 连拨号自己当主用都不通 |

原因：`IpPrioritizeRemote=1` 时，RAS 那条默认路由**不受跃点影响**。所以要走另一个开关。

**顺带一个坑**：`Find-NetRoute` **不能**用来判断"当前走哪条出口" —— 实测它对跃点变化不敏感，会一直返回原来那条。管理器只把它当预选，最终结论一律用 `curl -w '%{local_ip}'` 读实际出口源地址来确认。

### 验证与降级

- **验证三轮 + 一道闸**：快判 → 隔 12 秒 → 确认 1/2 → 隔 30 秒 → 确认 2/2 → 出口源地址确认（`curl` 读到的源地址必须等于拨号接口地址），全部通过才晋升。判据沿用 `Test-CampusExit.ps1`，脚本本身未做任何改动。
- **健康检查**：主用状态下**每 5 秒**探测一次，连续 2 次失败判定故障并降级（所以最坏约 12 秒就切回 Wi-Fi）。
  主用态下拨号自己握着默认路由，canary 天然走拨号，所以这一轮**不做 `/32` 引导、也不做出口源地址确认** —— 省掉每轮 18 次路由表增删。改用一次廉价的断言代替：确认最优默认路由确实在拨号上，否则本轮判不通过。停放态（验证出口时）才用 `/32` 引导。
- **健康检查怎么记日志**：健康时**不写日志文件**，只在控制台原地刷一行（不滚动）：

  ```text
  [23:01:48] 健康 · 已持续 12分34秒
  ```

  真的坏了才写正式日志，并带上**此前已健康多久**；恢复时也会记一条并重新计时：

  ```text
  健康检查：未通过 —— Campus exit probe passed 0 of 3（直连探测）。此前已健康 12分34秒。
  健康检查：已恢复 —— Campus exit probe passed 3 of 3（直连探测）。本段从 23:02:05 重新计时。
  ```

  所以 `logs\network-path.log` 里只剩真正有意义的事件，5 秒一轮也不会把它刷爆。
- **降级不需要断开拨号** —— 只删掉那条默认路由，流量立刻回 Wi-Fi，你的 IP 都不变。只有确实要换出口时才断开重拨，而那时流量已经在 Wi-Fi 上了。
- **保底检查**：降级前会确认 Wi-Fi 活着（网卡 Up + 有默认路由 + 网关 ping 通）。Wi-Fi 不可用时会记一条 ERROR 并立刻重拨，把无网窗口压到最短。
- **退避只针对"拨号失败"**：`rasdial` 返回非 0 时退避 2→4→8…→60 秒封顶。"出口不好"不算失败，固定停顿后重拨继续换出口。

### 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-DialName` | 自动识别 | 拨号连接名 |
| `-WifiName` | 自动识别 | 无线网卡名（按 802.11 介质自动找）|
| `-TimeoutSeconds` | 4 | 单次探测超时秒数 |
| `-ProbeCount` | 3 | 每轮探测次数 |
| `-SettleSeconds` | 3 | 拨上后等待几秒再验证 |
| `-ConfirmIntervalSeconds` | 12 | 快判与第 2 轮之间的间隔秒数 |
| `-ThirdIntervalSeconds` | 30 | 第 2、3 轮之间的间隔秒数 |
| `-HealthIntervalSeconds` | 5 | 主用状态下的健康检查周期（最坏 `FailThreshold × 该值` 后降级）|
| `-FailThreshold` | 2 | 连续失败几次判定故障并降级 |
| `-PauseSeconds` | 2 | 坏出口后重新拨号前的停顿 |
| `-MaxDialBackoffSeconds` | 60 | 拨号失败时的退避上限 |
| `-KeepParkedOnExit` | 关 | 退出时不还原电话簿开关（保持停放）|
| `-LogPath` | `logs\network-path.log` | 日志路径 |
| `-Status` | — | 只打印当前状态，不进循环（免提权可跑）|

### 首次运行会改什么

- `C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk`：把 `[校园网-1]` 段的 `IpPrioritizeRemote` 改成 `0`。
  改之前会**自动备份**到 `logs\rasphone.pbk.bak`，写完会做完整性自检（段落头 / 关键行 / 换行符），
  自检不过立刻回滚 —— 因为把这个文件写坏会让 RAS 报 623「找不到电话簿项目」。
- 退出时会改回 `1` 并重连（除非加 `-KeepParkedOnExit`）。

## 实测记录（2026-09-11）

留档备查，都是在本机实测得到的：

- **Wi-Fi 保底确实可用**：断开拨号后 `taobao`/`bilibili` 均 200、`generate_204` 返回 204，源地址都是 Wi-Fi 的 `172.29.81.43`。
- **停放 + 加/删默认路由的切换已验证**（全部用"改动后才解析的新域名"+ `curl` 源地址判定）：

  ```text
  停放态   拨号连着(10.194.175.183)、无默认路由
    ubuntu.com   code=301  src=172.29.81.43   Wi-Fi
    centos.org   code=200  src=172.29.81.43   Wi-Fi
  晋升：加默认路由 Route=4 → 有效 29 < Wi-Fi 30
    nodejs.org   code=307  src=10.194.175.183  拨号
    gitlab.com   code=308  src=10.194.175.183  拨号
    拨号 IP 仍是 10.194.175.183（没重连）
  降级：删掉那条路由
    atlassian.com code=200 src=172.29.81.43   Wi-Fi
    salesforce.com code=302 src=172.29.81.43  Wi-Fi
  ```

  两个方向都反复验证过一遍，拨号 IP 始终不变。
- **出口好坏是按协议族分的**：某次观测到拨号出口 IPv4 被限速（canary 两个主机都 4 秒超时），但 IPv6 是好的（`apiv2` 走 CERNET 0.14 秒返回 200）。所以探针钉死在 IPv4 是有意义的 —— 混着测会把坏的 v4 出口误判成好出口。
