#!/usr/bin/env python3
"""Build the two self-compiled NFQUEUE kmod .ipk packages for the Redmi AX3000.

Why two packages: upstream `iptables-mod-nfqueue` (userspace, taken from the
ipq40xx/generic 21.02.7 core feed) declares

    Depends: libc, iptables, kmod-nfnetlink-queue, kmod-ipt-nfqueue

so the kernel side must be split into exactly those two names, otherwise opkg
leaves the dependency unresolved and reports the bogus
"incompatible with the architectures configured" error (see
memory/2026-09-11-ax3000-mwan3-install.md section 4.1).

  kmod-nfnetlink-queue : /lib/modules/5.4.164/nfnetlink_queue.ko   (queue handler)
  kmod-ipt-nfqueue     : /lib/modules/5.4.164/xt_NFQUEUE.ko        (iptables target)

/etc/modules.d ordering (kmodloader sorts file names, digits < letters):
  ... 55-xt-statistic, ipt-nfqueue, nfnetlink-queue
Both new files sort AFTER nfnetlink / nf-conntrack / nf-ipt, which is what the
modules need (nfnetlink_queue.ko references nfnetlink_* and nf_ct_hook).

Usage:  python mk-nfqueue-pkgs.py
"""
import hashlib
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mkunipk  # noqa: E402

KDIR = os.path.normpath(os.path.join(HERE, ".."))          # kmod-build/
SRC = os.path.join(KDIR, "out-nfq")                        # built .ko
VERSION = "5.4-qsdk-11.5.0.5-1"
ARCH = "arm_cortex-a7_neon-vfpv4"
KDEP = "kernel (= 5.4-qsdk-11.5.0.5-1-1d36e0bafcfe3798b2e9608e79ec8215)"
MODDIR = "lib/modules/5.4.164"

PKGS = [
    {
        "name": "kmod-nfnetlink-queue",
        "ko": "nfnetlink_queue.ko",
        "modfile": "nfnetlink-queue",
        "modline": "nfnetlink_queue\n",
        "depends": "%s, kmod-nfnetlink" % KDEP,
        "desc": "Netfilter NFQUEUE over NFNETLINK interface (self-built from QSDK linux-ipq-5.4)",
    },
    {
        "name": "kmod-ipt-nfqueue",
        "ko": "xt_NFQUEUE.ko",
        "modfile": "ipt-nfqueue",
        "modline": "xt_NFQUEUE\n",
        "depends": "%s, kmod-ipt-core, kmod-nfnetlink-queue" % KDEP,
        "desc": "\"NFQUEUE\" iptables target (self-built from QSDK linux-ipq-5.4)",
    },
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    out = []
    for p in PKGS:
        payload = os.path.join(HERE, p["name"])
        if os.path.isdir(payload):
            shutil.rmtree(payload)
        os.makedirs(os.path.join(payload, MODDIR))
        os.makedirs(os.path.join(payload, "etc/modules.d"))
        src_ko = os.path.join(SRC, p["ko"])
        if not os.path.isfile(src_ko):
            raise SystemExit("missing %s -- run wsl-nfqueue-build.sh first" % src_ko)
        shutil.copy2(src_ko, os.path.join(payload, MODDIR, p["ko"]))
        with open(os.path.join(payload, "etc/modules.d", p["modfile"]), "w") as fh:
            fh.write(p["modline"])
        ipk = os.path.join(HERE, "%s_%s_%s.ipk" % (p["name"], VERSION, ARCH))
        mkunipk.build(
            "Package: %s\nVersion: %s\nDepends: %s\nSection: kernel\n"
            "Architecture: %s\nLicense: GPL-2.0\nDescription: %s\n"
            % (p["name"], VERSION, p["depends"], ARCH, p["desc"]),
            payload, ipk,
        )
        out.append((p["name"], ipk, os.path.getsize(ipk), sha256(ipk),
                    sha256(os.path.join(payload, MODDIR, p["ko"]))))
    print("\n=== built packages ===")
    for name, ipk, size, ih, kh in out:
        print("%-22s %7d B  ipk-sha256=%s  ko-sha256=%s" % (name, size, ih[:16], kh[:16]))
    print("\ninstall order on device: kmod-nfnetlink-queue -> kmod-ipt-nfqueue -> iptables-mod-nfqueue")
    return 0


if __name__ == "__main__":
    sys.exit(main())
