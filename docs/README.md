# 文档导航

本目录是本项目的正式文档。根目录的 [README.md](../README.md) 是项目总入口（功能概览、目录结构、快速开始）。

## 建议阅读顺序

| 你是 | 读这些 |
| --- | --- |
| **刚接触这个项目** | [01-项目原理.md](01-项目原理.md) → [README.md](../README.md) |
| **要把它部署到自己的路由器** | [02-部署-通用.md](02-部署-通用.md) → [04-使用方法.md](04-使用方法.md) |
| **用的是这台 Redmi AX3000（或同款 QSDK 内核机型）** | [03-部署-AX3000-自编内核模块.md](03-部署-AX3000-自编内核模块.md)（先读 02） |
| **已经装好，出问题了** | [05-故障排查.md](05-故障排查.md) |
| **要改内核模块 / 深入 ABI 细节** | [reference/AX3000-KMOD-BUILD.md](reference/AX3000-KMOD-BUILD.md) |
| **要改 SNI 分流的策略或换机型** | [reference/SNI-DESYNC.md](reference/SNI-DESYNC.md) |

## 文档清单

| 文档 | 行数量级 | 内容 |
| --- | --- | --- |
| [01-项目原理.md](01-项目原理.md) | 中 | 术语表、问题背景、检测原理、重拨状态机、多拨为何可行（BRAS 行为实测）、mwan3 分流、SNI 限速与对抗手法、nfqws vs tpws 的实测差别、hostlist 语义、组件与数据流、设计边界 |
| [02-部署-通用.md](02-部署-通用.md) | 长 | **通用 OpenWrt 部署**：支持范围、依赖、21.02.7 SDK 构建 `.ipk`、安装与验证、初始配置（LuCI 逐项）、多拨连接池、SNI 分流的两条部署路径、升级卸载、部署后自检清单 |
| [03-部署-AX3000-自编内核模块.md](03-部署-AX3000-自编内核模块.md) | 长 | **本机特殊改动**：设备事实、为什么 opkg 装不上 kmod、`vermagic` 相同 ≠ ABI 相同、自编流水线与 `CR_KMOD_CACHE` 约定、四个自编模块、按上游包名打包、ABI 三判据、SNI 分流的 nfqws 落地、验收记录、回滚 |
| [04-使用方法.md](04-使用方法.md) | 长 | Windows 侧（C# 参数/PowerShell/开机自启/判定逻辑）与路由器侧（LuCI 面板逐项、SNI 面板、命令行、状态文件、典型操作剧本） |
| [05-故障排查.md](05-故障排查.md) | 很长 | 按现象组织：拨号与认证、多拨连接池、SNI 分流（含 `stop` 黑洞与遗留死规则）、内核模块与 ABI、**测量方法学陷阱** |
| [reference/AX3000-KMOD-BUILD.md](reference/AX3000-KMOD-BUILD.md) | 很长 | 自编内核模块的完整技术记录：`struct net_device` +64 字节的逐项来源、ABI 判据的取舍、上机实测全过程、附录（已排除的预编译来源、诊断脚本清单、踩过的脚本坑） |
| [reference/SNI-DESYNC.md](reference/SNI-DESYNC.md) | 长 | SNI 分流部署指南：nfqws/tpws 两种模式怎么选、21.02(fw3) / 22+(fw4) / 19.07 / 非 arm 架构各自的路径、厂商自编固件排障、本机现状与备忘、验收与迭代 |

## 工作日志索引（`memory/`）

`memory/` 下是逐次调试的**原始工作日志**，包含实测数据、失败尝试与踩坑记录。文档里的很多结论就来自这里；
排查陌生问题时也值得翻。日志按日期命名，**早于 2026-09-11 目录重组的日志使用旧路径**（换算见
[README 的"目录重组说明"](../README.md#目录重组说明2026-09-11)）。

| 日志 | 内容 |
| --- | --- |
| `memory/2026-09-07-bandwidth-property-error.md` | Windows 侧：PowerShell 测速函数把 `EnsureSuccessStatusCode()` 的返回值混进管道，导致"Mbps 属性找不到"的排查 |
| `memory/2026-09-10-openwrt-frontend-vmnet8.md` | LuCI 前端"页面显示旧版"的误判定位（实为浏览器缓存）+ VMware VMnet8 管理链路不通的排查 |
| `memory/2026-09-10-sni-desync-zapret-scripts.md` | zapret v72.13 安装/卸载脚本的编写与沙盒验证（依赖清单、防火墙挂接、包内容核对） |
| `memory/2026-09-10-sni-stop-blackhole.md` | **`/etc/init.d/zapret stop` 造成全网 connection refused 的黑洞**：现象、判据（`running` 与 `redirect` 不一致）与正确姿势 |
| `memory/2026-09-10-ax3000-kmod-abi-mismatch.md` | 第一次内核 panic 的定位：`vermagic` 一致却崩、探针反推结构体错位 |
| `memory/2026-09-11-ax3000-kmod-abi-aligned.md` | ABI 对齐的判定方法与结论（厂商树 + 原装配置；三条编译器无关判据） |
| `memory/2026-09-11-ax3000-mwan3-install.md` | 内核模块持久化 + 装 mwan3；opkg"架构不兼容"其实是依赖残缺假象 |
| `memory/2026-09-11-ax3000-multidial-live.md` | 多拨上机：BRAS 允许同账号多会话（需独立 MAC）；两个把连接池卡死的缺陷；早期带宽实测 |
| `memory/2026-09-11-official-openwrt-nfqws-feasibility.md` | "换官方固件是否可行"的核实（含**已被推翻**的旧结论与更正标注） |
| `memory/2026-09-11-ax3000-nfqueue-nfqws-live.md` | 自编 NFQUEUE 两件套 → 切到 nfqws；带宽 A/B（转发路径 177 → 314 Mbps）；测量方法学与遗留死规则 |

## 文档维护约定

新增或修改文档时请遵守：

1. **路径**：仓库内文件用相对路径；设备上的文件用绝对路径（`/opt/zapret/config`）。
2. **凭据**：**任何**密码、账号、内网会话 cookie 都不写进文档，示例统一用 `<账号>`、`<密码>`、`<路由器IP>`。
3. **实测与推断要分开写**：实测结论注明测量条件（路径、流数、窗口、机型）；推断标注为推断；
   素材之间冲突时取更晚/更具体的那条并注明差异。
4. **命令块标注在哪台机器上执行**（Windows / 路由器 / WSL / Linux 构建机）。
5. **危险操作要写清回滚**：尤其是内核模块、防火墙跳转、`/etc/config/network` 的改动。
