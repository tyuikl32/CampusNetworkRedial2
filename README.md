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
| SNI 分流（nfqws） | 实机运行中 | 转发路径 16 路明文 HTTP 实测 312~315 Mbps（tpws 为 173~180，完全不经手 355） |
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

见仓库许可证文件（如无，请以原始项目 [Introduce183/campus-network-redial](https://github.com/Introduce183/campus-network-redial) 的许可为准）。
