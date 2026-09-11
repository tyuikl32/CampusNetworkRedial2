# CampusRedialWrt —— OpenWrt 侧全部脚本与代码

本目录包含项目在路由器上运行的一切。**部署与使用请以仓库根 `docs/` 为准**：

| 文档 | 内容 |
| --- | --- |
| [../docs/02-部署-通用.md](../docs/02-部署-通用.md) | 通用 OpenWrt 部署（构建 `.ipk`、安装、配置） |
| [../docs/03-部署-AX3000-自编内核模块.md](../docs/03-部署-AX3000-自编内核模块.md) | 本机（Redmi AX3000）的特殊改动与自编内核模块 |
| [../docs/04-使用方法.md](../docs/04-使用方法.md) | 面板、命令行、状态文件的使用 |
| [../docs/05-故障排查.md](../docs/05-故障排查.md) | 按现象排查 |
| [../docs/reference/SNI-DESYNC.md](../docs/reference/SNI-DESYNC.md) | SNI 分流的部署与验收指南 |
| [../docs/reference/AX3000-KMOD-BUILD.md](../docs/reference/AX3000-KMOD-BUILD.md) | 自编内核模块的深度技术记录 |

---

## 目录

```
CampusRedialWrt/
├── luci-app-campus-redial/          LuCI 应用（可单独打包安装）
│   ├── Makefile                     包定义（依赖、安装规则、prerm 卸载钩子）
│   ├── htdocs/luci-static/resources/view/campus-redial/overview.js
│   │                                前端页面：状态、配置、按钮、日志、SNI 分流面板
│   ├── root/etc/init.d/campus-redial  procd 服务（START=95）
│   ├── root/etc/config/campus-redial  UCI 配置模板（凭据写这里，0600）
│   ├── root/etc/uci-defaults/         首次安装钩子（权限收紧 + 启用自启）
│   ├── root/lib/upgrade/keep.d/       升级保留清单
│   ├── root/usr/sbin/campus-rediald   守护进程（POSIX shell：拨号/探测/测速/连接池/mwan3）
│   ├── root/usr/sbin/campus-redialctl 控制工具（start/stop/test/redial_once/clear_stats）
│   ├── root/usr/sbin/campus-redial-mwan3       mwan3 策略生成
│   ├── root/usr/sbin/campus-redial-mwan3route  每会话路由表注入
│   ├── root/usr/libexec/rpcd/campus_redial     rpcd 插件（状态/日志/控制 + SNI 分流控制）
│   ├── root/usr/share/luci/menu.d/            菜单项
│   ├── root/usr/share/rpcd/acl.d/             ACL
│   └── src/campus-redial-bind.c      会话绑定 helper（SO_BINDTODEVICE / 源地址绑定）
│
├── tools/                           安装、卸载与构建辅助脚本
│   ├── install-sni-desync.sh        SNI 分流安装（自动探测 nfqws/tpws，支持 --offline=、--mode=、--dry-run）
│   ├── install-flow-offload.sh      转发快路径（flow offload）+ 首包保护：聚合下行 350 → ~690 Mbps
│   ├── uninstall-sni-desync.sh      幂等卸载（hostlist 自动备份）
│   ├── build-macvlan-kmod.sh        内核模块构建入口（转发到 kmod-build/ 的流程）
│   ├── build-dev-apk.sh             历史 25.12 APK 应急构建（当前 21.02.7 不使用）
│   ├── dev-prerm.sh                 与 Makefile prerm 逻辑对应的开发用脚本
│   ├── deploy-current.tar.gz        一份可直接解包的部署文件树快照
│   └── zapret-embedded.tar.gz       zapret v72.13 官方发行包（离线安装用，GPL）
│
├── kmod-build/                      自编内核模块（本机机型专用，详见 docs/03）
│   ├── wsl-setup.sh / wsl-extract-qsdk.sh     准备源码树与工具链（WSL 内）
│   ├── wsl-qsdk-build.sh                      主构建：macvlan / tun / xt_statistic
│   ├── wsl-nfqueue-build.sh                   构建 NFQUEUE 两件套
│   ├── wsl-nfq-verify.sh                      离线 ABI 闸门（vermagic / 配置保真 / 结构体门 / 符号对照）
│   ├── wsl-offdump.sh + offdump/cr_offdump.c  只编译不加载的 offsetof 探针
│   ├── pkg/mkunipk.py                         生成 OpenWrt 21.02 格式 .ipk
│   ├── pkg/mk-nfqueue-pkgs.py                 打 NFQUEUE 两个自编包
│   ├── remote/cr-*.sh                         上机脚本（加载验证、持久化、池探针、带宽诊断、模式切换、转发路径测试客户端）
│   ├── config-5.4.164-ax3000                  设备原装内核配置（ABI 保真的基准）
│   ├── kallsyms-ax3000.txt                    设备符号表快照（符号对照用）
│   ├── vendor/                                从设备取回的厂商模块（二进制不入库）
│   ├── out-qsdk/ out-nfq/                     构建产物（.ko + SHA256SUMS + 未定义符号表）
│   └── abicheck/ ipk-check/                   探针源码与 ipk 结构取证
│
└── dist/                            历史构建产物
    ├── luci-app-campus-redial-1.0.0-r1.apk    OpenWrt 25.12 历史包（不适用于 21.02.7）
    └── std-package-source.tar                 包源码归档（放进 SDK 构建用）
```

## 两条容易踩的约定

1. **shell 脚本必须是 LF**：Windows 编辑器默认 CRLF 会让设备上的 `/bin/sh` 直接报语法错误。
   推送到设备前统一 `tr -d '\r'`，或给仓库加 `.gitattributes`（`*.sh text eol=lf`）。
2. **第三方二进制不入库**：`kmod-build/vendor/*.ko` 需要时从设备自行取回
   （命令写在 `CampusRedialWrt/kmod-build/.gitignore` 里）；
   约 1.9 GB 的构建输入（内核源码、工具链）放在仓库外的缓存目录，见 `docs/03`。
