#!/usr/bin/env python3
"""Unpack an OpenWrt .ipk (an `ar` archive of debian-binary + control.tar.gz + data.tar.gz)."""
import io
import os
import sys
import tarfile


def members(buf):
    if buf[:8] != b"!<arch>\n":
        raise SystemExit("not an ar archive")
    off = 8
    while off + 60 <= len(buf):
        hdr = buf[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        size = int(hdr[48:58].decode("ascii", "replace").strip() or "0")
        data = buf[off + 60:off + 60 + size]
        yield name, data
        off += 60 + size + (size & 1)


def main():
    path = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else None
    buf = open(path, "rb").read()
    for name, data in members(buf):
        clean = name.rstrip("/")
        print("== member: %s (%d bytes)" % (clean, len(data)))
        if clean.endswith(".tar.gz") or clean.endswith(".tar"):
            mode = "r:gz" if clean.endswith(".gz") else "r:"
            with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tf:
                for m in sorted(tf.getmembers(), key=lambda x: x.name):
                    print("   %8d  %s" % (m.size, m.name))
                    if outdir and (m.isfile() or m.issym()):
                        tf.extract(m, outdir)
    if outdir:
        print("extracted to", outdir)


if __name__ == "__main__":
    main()
