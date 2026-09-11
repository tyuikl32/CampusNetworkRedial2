#!/usr/bin/env python3
"""Build an OpenWrt 21.02-style .ipk (gzip'd tar of debian-binary/control/data).

OpenWrt 21.02 packages are NOT `ar` archives -- they are:

    ipk = gzip(tar(./debian-binary, ./control.tar.gz, ./data.tar.gz))
    control.tar.gz = gzip(tar(./, ./control [, ./postinst ...]))
    data.tar.gz    = gzip(tar(./, ./etc/..., ./lib/...))

(opkg rejects a *plain* tar with "Malformed package file", so the outer gzip
layer is mandatory. The `./` entry prefixes are what the real feed ipks use.)

Usage:
    mkunipk.py --name kmod-ipt-ipopt \
               --version 5.4-qsdk-11.5.0.5-1 \
               --arch arm_cortex-a7_neon-vfpv4 \
               --depends "kernel (= 5.4-...)" \
               --desc "..." \
               --payload payload-dir \
               --out out.ipk
"""
import argparse
import gzip
import io
import os
import sys
import tarfile
import time


def _add_dir(tf, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    tf.addfile(ti)


def _add_file(tf, name, data, mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def make_inner_tar(entries, gz=True):
    """entries: list of (arcname, bytes|None-for-dir). arcname already prefixed with './'."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tf:
        for name, data in entries:
            if data is None:
                _add_dir(tf, name)
            else:
                _add_file(tf, name, data)
    blob = raw.getvalue()
    if not gz:
        return blob
    return gzip.compress(blob, mtime=0)


def build(control_text, payload_dir, out_path, extra_control_files=None):
    # control.tar.gz
    centries = [("./", None), ("./control", control_text.encode("utf-8"))]
    for nm, data in (extra_control_files or []):
        centries.append(("./" + nm, data))
    control_tgz = make_inner_tar(centries)

    # data.tar.gz
    dentries = [("./", None)]
    dirs_seen = {"./"}
    for root, dirs, files in os.walk(payload_dir):
        dirs.sort()
        files.sort()
        rel_root = os.path.relpath(root, payload_dir).replace(os.sep, "/")
        if rel_root == ".":
            rel_root = ""
        for d in dirs:
            rel = (rel_root + "/" + d) if rel_root else d
            arc = "./" + rel + "/"
            if arc not in dirs_seen:
                dirs_seen.add(arc)
                dentries.append((arc, None))
        for f in files:
            rel = (rel_root + "/" + f) if rel_root else f
            with open(os.path.join(root, f), "rb") as fh:
                dentries.append(("./" + rel, fh.read()))
    data_tgz = make_inner_tar(dentries)

    outer = make_inner_tar([
        ("./debian-binary", b"2.0\n"),
        ("./control.tar.gz", control_tgz),
        ("./data.tar.gz", data_tgz),
    ])

    with open(out_path, "wb") as fh:
        fh.write(outer)
    return len(outer)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--arch", required=True)
    ap.add_argument("--depends", default="")
    ap.add_argument("--desc", default="")
    ap.add_argument("--section", default="kernel")
    ap.add_argument("--license", default="GPL-2.0")
    ap.add_argument("--payload", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    lines = [
        "Package: %s" % args.name,
        "Version: %s" % args.version,
        "Depends: %s" % args.depends if args.depends else "Depends:",
        "Section: %s" % args.section,
        "Architecture: %s" % args.arch,
        "License: %s" % args.license,
    ]
    if args.desc:
        lines.append("Description: %s" % args.desc.replace("\n", " "))
    control_text = "\n".join(lines) + "\n"

    n = build(control_text, args.payload, args.out)
    sys.stderr.write("wrote %s (%d bytes)\n" % (args.out, n))
    sys.stderr.write("--- control ---\n" + control_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
