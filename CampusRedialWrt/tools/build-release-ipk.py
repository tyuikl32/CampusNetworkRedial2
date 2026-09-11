#!/usr/bin/env python3
"""Build a **generic** (Architecture: all) .ipk for luci-app-campus-redial.

Why hand-rolled instead of `make package/luci-app-campus-redial/compile`:
  * the LuCI app is shell + JS + JSON + a Lua rpcd plugin, i.e. **architecture
    independent**, so ONE package installs on every OpenWrt 21.02.x device;
  * the only arch-specific piece in the upstream Makefile is the optional
    LD_PRELOAD helper `src/campus-redial-bind.c`.  The daemon only uses it when
    the file exists (`[ -r "$BIND_LIBRARY" ]`), and it falls back to the
    uclient-fetch / `curl --interface <session>` path otherwise, so the generic
    package omits the .so **and depends on curl** instead (without either one,
    the probe/speed-test session binding has no working path).
  * the upstream Makefile's install rules **forget /usr/sbin/campus-redial-mwan3route**,
    which the daemon calls (guarded by `-x`) to inject the per-session default
    route -- that is the fix for mwan3 reporting "error (16)".  This builder
    ships it and fails loudly if the manifest drifts from the package tree.

Format (OpenWrt 21.02, opkg) -- exactly what the firmware's own feed packages use:

    ipk = gzip(tar(./debian-binary, ./control.tar.gz, ./data.tar.gz))
    control.tar.gz = gzip(tar(./, ./control, ./conffiles, ./postinst, ./prerm))
    data.tar.gz    = gzip(tar(./, ./etc/..., ./usr/..., ./www/...))

Usage:
    python build-release-ipk.py --out-dir /path/to/release-assets
    python build-release-ipk.py --out-dir . --version 1.0.0 --release 3
    python build-release-ipk.py --check-only          # manifest drift + CRLF only
"""
import argparse
import gzip
import io
import os
import re
import stat
import sys
import tarfile
import time

try:                                    # keep Chinese output readable on Windows consoles
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))          # repo root
PKG = os.path.join(REPO, "CampusRedialWrt", "luci-app-campus-redial")

# ---------------------------------------------------------------- manifest
# (source relative to the package dir, destination inside the package, mode)
INSTALL = [
    ("root/etc/config/campus-redial", "/etc/config/campus-redial", 0o600),
    ("root/etc/init.d/campus-redial", "/etc/init.d/campus-redial", 0o755),
    ("root/etc/uci-defaults/99-campus-redial-permissions", "/etc/uci-defaults/99-campus-redial-permissions", 0o755),
    ("root/usr/sbin/campus-rediald", "/usr/sbin/campus-rediald", 0o755),
    ("root/usr/sbin/campus-redialctl", "/usr/sbin/campus-redialctl", 0o755),
    ("root/usr/sbin/campus-redial-mwan3", "/usr/sbin/campus-redial-mwan3", 0o755),
    ("root/usr/sbin/campus-redial-mwan3route", "/usr/sbin/campus-redial-mwan3route", 0o755),
    ("root/usr/libexec/rpcd/campus_redial", "/usr/libexec/rpcd/campus_redial", 0o755),
    ("root/usr/share/luci/menu.d/luci-app-campus-redial.json", "/usr/share/luci/menu.d/luci-app-campus-redial.json", 0o644),
    ("root/usr/share/rpcd/acl.d/luci-app-campus-redial.json", "/usr/share/rpcd/acl.d/luci-app-campus-redial.json", 0o644),
    ("root/lib/upgrade/keep.d/luci-app-campus-redial", "/lib/upgrade/keep.d/luci-app-campus-redial", 0o644),
    ("htdocs/luci-static/resources/view/campus-redial/overview.js",
     "/www/luci-static/resources/view/campus-redial/overview.js", 0o644),
]
EXTRA_DIRS = ["/etc/campus-redial", "/usr/share/luci/menu.d", "/usr/share/rpcd/acl.d",
              "/usr/libexec/rpcd", "/lib/upgrade/keep.d",
              "/www/luci-static/resources/view/campus-redial"]

# the daemon needs jsonfilter + a session-bound fetcher (bind.so or curl);
# kmod-macvlan / mwan3 are only needed for pool_size > 1 -> documented, not hard deps
DEPS_DEFAULT = ("libc, luci-base, rpcd, rpcd-mod-luci, uclient-fetch, curl, "
                # 依赖虚拟包 `ip`（ip-tiny / ip-full 都满足）。写死 ip-tiny 会在装了
                # ip-full 的设备上被 opkg 报成误导性的“架构不兼容”，实测踩过。
                "ca-bundle, ppp, ppp-mod-pppoe, ip, jsonfilter")
CONFFILES = [
    "/etc/config/campus-redial",
    "/etc/campus-redial/stats.json",
    "/etc/campus-redial/last-run.json",
    "/etc/campus-redial/firewall-managed-networks",
]


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def make_tar(entries, gz=True):
    """entries: list of (arcname, bytes|None for dir, mode)."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            ti.mode = mode
            if data is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    blob = raw.getvalue()
    return gzip.compress(blob, mtime=0) if gz else blob


def makefile_script(name):
    """Pull define Package/$(PKG_NAME)/<name> ... endef out of the Makefile and
    undo Make's escaping ($$ -> $).  Keeps postinst/prerm in sync with the source."""
    text = open(os.path.join(PKG, "Makefile"), encoding="utf-8").read()
    m = re.search(r"define Package/\$\(PKG_NAME\)/%s\n(.*?)\nendef" % re.escape(name),
                  text, re.S)
    if not m:
        raise SystemExit("FATAL: cannot find '%s' script in the Makefile" % name)
    return m.group(1).replace("$$", "$").replace("$${", "${")


def check_tree():
    """Fail on manifest drift and on CRLF in shipped files."""
    problems = []
    shipped = {src for src, _, _ in INSTALL}
    for root, _dirs, files in os.walk(PKG):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), PKG).replace(os.sep, "/")
            if rel in shipped or rel == "Makefile" or rel == "README.md" or rel.startswith("src/"):
                continue
            problems.append("  未被 manifest 收录（会被漏装）: %s" % rel)
    for src, _dst, _mode in INSTALL:
        path = os.path.join(PKG, src)
        if not os.path.isfile(path):
            problems.append("  manifest 声明的源文件不存在: %s" % src)
            continue
        data = read(path)
        if data.startswith(b"\x7fELF"):
            problems.append("  含 ELF 二进制（通用包不能带）: %s" % src)
        if b"\r\n" in data:
            problems.append("  含 CRLF（设备上 /bin/sh 会报语法错）: %s" % src)
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=os.path.join(REPO, "dist"))
    ap.add_argument("--version", default="1.0.0")
    ap.add_argument("--release", default="2")
    ap.add_argument("--depends", default=DEPS_DEFAULT)
    ap.add_argument("--arch", default="all")
    ap.add_argument("--with-bind", default="",
                    help="可选：把编译好的 campus-redial-bind.so 一起打包（那时 arch 应写成目标架构）")
    ap.add_argument("--epoch", type=int, default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")),
                    help="写进 control 的 SourceDateEpoch；默认 0 以保证可重复构建")
    ap.add_argument("--check-only", action="store_true")
    args = ap.parse_args()

    print("### 1) manifest 与文件自检")
    problems = check_tree()
    if problems:
        print("\n".join(problems))
        if args.check_only:
            return 1
        raise SystemExit("FATAL: 上述问题必须先解决（或用 --check-only 只看报告）")
    print("  OK  manifest 与包树一致；无 ELF、无 CRLF")
    if args.check_only:
        print("--check-only：自检通过，未打包")
        return 0

    print("### 2) 组装 data 树")
    entries = [("./", None, 0o755)]
    for d in sorted(set(os.path.dirname(p) for p in EXTRA_DIRS)):
        entries.append(("./" + d.lstrip("/") + "/", None, 0o755))
    total = 0
    listing = []
    for src, dst, mode in INSTALL:
        data = read(os.path.join(PKG, src))
        total += len(data)
        entries.append(("./" + dst.lstrip("/"), data, mode))
        listing.append("  %-58s %7d B  mode %o" % (dst, len(data), mode))
    if args.with_bind:
        bind = read(args.with_bind)
        entries.append(("./usr/lib/campus-redial-bind.so", bind, 0o644))
        listing.append("  %-58s %7d B  (LD_PRELOAD helper)" % ("/usr/lib/campus-redial-bind.so", len(bind)))
        total += len(bind)
    data_tgz = make_tar(entries)
    print("\n".join(listing))
    print("  载荷合计 %d 字节" % total)

    print("### 3) 组装 control")
    control = "\n".join([
        "Package: luci-app-campus-redial",
        "Version: %s-%s" % (args.version, args.release),
        "Depends: %s" % args.depends,
        "Source: CampusRedialWrt/luci-app-campus-redial",
        "SourceName: luci-app-campus-redial",
        "Section: luci",
        "Priority: optional",
        "License: GPL-2.0",
        "SourceDateEpoch: %d" % args.epoch,
        "Architecture: %s" % args.arch,
        "Installed-Size: %d" % ((total + 1023) // 1024),
        "Description:  LuCI interface and procd service for PPPoE campus network redial",
        " testing: probes the current exit, redials until it passes, optional multi-session",
        " connection pool with mwan3, optional SNI desync panel.",
    ]) + "\n"
    centries = [
        ("./", None, 0o755),
        ("./control", control.encode(), 0o644),
        ("./conffiles", ("\n".join(CONFFILES) + "\n").encode(), 0o644),
        ("./postinst", makefile_script("postinst").encode(), 0o755),
        ("./prerm", makefile_script("prerm").encode(), 0o755),
    ]
    control_tgz = make_tar(centries)
    print(control)

    print("### 4) 打包")
    outer = make_tar([
        ("./debian-binary", b"2.0\n", 0o644),
        ("./control.tar.gz", control_tgz, 0o644),
        ("./data.tar.gz", data_tgz, 0o644),
    ])
    os.makedirs(args.out_dir, exist_ok=True)
    name = "luci-app-campus-redial_%s-%s_%s.ipk" % (args.version, args.release, args.arch)
    out = os.path.join(args.out_dir, name)
    with open(out, "wb") as fh:
        fh.write(outer)
    import hashlib
    print("  %s" % out)
    print("  %d 字节  sha256=%s" % (len(outer), hashlib.sha256(outer).hexdigest()))
    if args.check_only:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
