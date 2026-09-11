# luci-app-campus-redial

This package provides a LuCI page and a procd-managed worker for testing a
campus PPPoE connection and redialing it until the selected exit criteria pass.

The worker only operates on the configured WAN interface. It never calls a
whole-device network restart and never changes LAN, bridge, wireless, LuCI or
uhttpd settings.

## Development install

Build the package from an OpenWrt SDK or source tree:

```sh
make package/luci-app-campus-redial/compile V=s
```

仓库根目录附带的 OpenWrt 25.12.5 `.apk` 是历史构建产物；当前 21.02.7 验收不使用它。
21.02.7 应使用对应 SDK 生成 `.ipk`。历史构建说明如下：
`make package/luci-app-campus-redial/compile V=s` 流程生成并验证的
`luci-app-campus-redial-1.0.0-r1.apk`（`arch:x86_64`，25,970 bytes，SHA-256
`794CE600949362769063CBA5AD1C25E96E5B6D619D5E654C9E8990E1633209BD`）。精简 OpenWrt VM
通过临时 glibc 构建根目录完成了 SDK 构建；这段 APK/ucode 构建记录仅供历史追溯，
当前 21.02.7 不使用 `tools/build-dev-apk.sh`，正式发布应使用对应 SDK 的标准 `make` 流程。

For a quick development install, copy the package files to the router and
restart rpcd/uhttpd. The normal package flow is preferred because it installs
the service and permissions consistently.

```sh
opkg install /tmp/luci-app-campus-redial_*.ipk
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/campus-redial enable
/etc/init.d/campus-redial start
```

Configure the PPPoE account, the existing `wan` interface and its physical
device in LuCI before starting the worker. A missing or LAN bridge device is
rejected by the worker; an interface whose current protocol is not `pppoe` is
also rejected before any network mutation.

When `pool_size` is greater than one, the worker creates only its own
`campus_wanN_device` sections with short `crwanN` macvlan devices and gives each secondary PPPoE session a
distinct MAC/`pppname`. It never creates VLAN tags or changes the physical WAN
MAC. If the target kernel/netifd cannot create macvlan devices, the worker
leaves the pool session down and reports the device error; `pool_size=1`
remains the safe compatibility mode.

Normal probes and speed downloads are launched with the session's PPPoE device
and negotiated IPv4 source address. The bundled `campus-redial-bind.so` helper
uses `SO_BINDTODEVICE` where supported and falls back to source-address binding
for PPP netdevices that reject that socket option.

The package removal hook only cleans sections marked by this package (`wan2`..
`wan6`, its macvlan devices and its mwan3 sections) and restores temporary IPv6
delegation changes. LAN, Wi-Fi and unmarked WAN configuration are left intact.

## Historical validated behavior (OpenWrt 25.12.5 x86/64, VMware)

- Cold start dials once, redials only the WAN interface on probe failure, and
  parks in `failed`/`idle` after the configured attempt limit.
- Stop cancels dialing, probing and speed tests mid-flight; the state settles
  to `stopped`/`idle` without extra dials.
- The test layer (6-stream download measurement, three-round probes, parallel
  dual-mode execution with sibling cancellation) passes in a sandbox harness.
- LuCI page renders status, buttons, three statistic groups and logs; Save &
  Apply persists credentials to UCI (0600); the password never appears in the
  `status`/`logs` RPC output.
- Repeated redial cycles leave LAN up, uhttpd listening and wireless config
  untouched.
- The current VMware test environment has the matching `kmod-macvlan`
  installed. A `pool_size=2` run confirmed both `wan` and `wan2` online via
  independent `crwanN` devices and MAC addresses. A clean `pool_size=5` run
  with the recommended 60-second authentication interval brought all five
  sessions online and passed speed checks; the earlier 5-second run reached
  only 2/5, so the conservative interval is intentional.
- The historical APK installs with the normal `apk add` path, creates the
  procd enable links and runs its post-install permission hook. An upgrade
  preserves UCI/network backup files. Removing it deletes only sections marked
  by this package; the `lan` and primary `wan` UCI hashes were identical before
  and after removal, and the final VM kept both interfaces up.

## Local service commands

```sh
/etc/init.d/campus-redial status
/etc/init.d/campus-redial start
/etc/init.d/campus-redial stop
/usr/sbin/campus-redialctl test
/usr/sbin/campus-redialctl redial_once
ubus -S call campus_redial status
```

The current state is in `/var/run/campus-redial/status.json`; the latest task
and cumulative counters are stored below `/etc/campus-redial/`. PPPoE secrets
are stored in the UCI file with mode `0600` and are never returned by the RPC
status or log methods. Pool status includes `pool_success_count` and
`pool_size`, plus one redacted row per session.
