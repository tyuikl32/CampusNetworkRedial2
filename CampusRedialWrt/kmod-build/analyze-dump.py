#!/usr/bin/env python3
"""Locate the device kernel's real struct net_device field offsets from the raw
dump cr_abicheck.ko printed for the lo device.

We know what lo's fields must contain, so every distinctive value in the dump
acts as a landmark.  Comparing the landmark offsets with the offsets our own
build believes in tells us exactly how the vendor's struct differs.
"""
import re
import sys

LOG = r"D:\CampusNetworkRedial\kmod-build\capture-canary-1.log"

# offsets as measured by our own build (printed by cr_abicheck.ko)
OURS = {
    "name": 0, "state": 44, "features": 112, "hw_features": 120,
    "ifindex": 168, "netdev_ops": 288, "flags": 308, "priv_flags": 312,
    "mtu": 324, "min_mtu": 328, "max_mtu": 332, "type": 336,
    "hard_header_len": 338, "min_header_len": 340, "perm_addr": 346,
    "addr_len": 379, "dev_addrs": 420, "dev_addr": 464, "broadcast": 504,
    "tx_queue_len": 656, "pcpu_refcnt": 696, "sizeof": 1344,
}


def load_dump(path):
    buf = {}
    rx = re.compile(r"cr_abicheck: ([0-9a-f]{8}): ((?:[0-9a-f]{8} ?)+)")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = rx.search(line)
            if not m:
                continue
            off = int(m.group(1), 16)
            words = m.group(2).split()
            for i, w in enumerate(words):
                # hexdump groups are printed little-endian: the group value IS
                # the u32 that lives at that address
                v = int(w, 16)
                for b in range(4):
                    buf[off + i * 4 + b] = (v >> (8 * b)) & 0xFF
    return buf


def u32(buf, off):
    return (buf.get(off, 0) | (buf.get(off + 1, 0) << 8)
            | (buf.get(off + 2, 0) << 16) | (buf.get(off + 3, 0) << 24))


def u16(buf, off):
    return buf.get(off, 0) | (buf.get(off + 1, 0) << 8)


def find_all(buf, value, size=4, lo=0, hi=0x540):
    hits = []
    for off in range(lo, min(hi, max(buf) + 1) - size + 1, 1):
        if size == 4:
            v = u32(buf, off)
        elif size == 2:
            v = u16(buf, off)
        else:
            v = buf.get(off, 0)
        if v == value:
            hits.append(off)
    return hits


def main():
    buf = load_dump(LOG)
    if not buf:
        print("no dump found in %s" % LOG)
        return 1
    print("dump bytes recovered: %d (offsets %#x..%#x)" % (
        len(buf), min(buf), max(buf)))
    print()

    print("=== landmark search in the DEVICE's lo struct ===")
    marks = [
        ("mtu / 65536",              0x10000, 4),
        ("type ARPHRD_LOOPBACK 772", 772, 2),
        ("hard_header_len 14",       14, 2),
        ("tx_queue_len 1000",        1000, 4),
        ("flags IFF_LOOPBACK|IFF_UP", 9, 4),
        ("flags IFF_LOOPBACK",       8, 4),
        ("features lo",         0x00000288, 4),   # high half of the u64
        ("hw_features lo",      0x401d4800, 4),
        ("addr_len 6",               6, 1),
    ]
    for name, val, size in marks:
        hits = find_all(buf, val, size)
        print("  %-30s value=%-12s at %s" % (
            name, hex(val), " ".join(hex(h) for h in hits) or "-"))

    print()
    print("=== every offset where our build would look, and what is there ===")
    print("  %-18s %6s  %10s   %s" % ("field", "ours", "at ours", "device value there"))
    for field, off in sorted(OURS.items(), key=lambda kv: kv[1]):
        if off + 4 > 0x540:
            continue
        print("  %-18s %#6x  %#10x   %#x" % (field, off, off, u32(buf, off)))

    print()
    print("=== kernel pointers found in the dump (0x8xxxxxxx / 0x9xxxxxxx) ===")
    ptrs = []
    for off in range(0, 0x540 - 3, 4):
        v = u32(buf, off)
        if 0x80000000 <= v <= 0xAFFFFFFF:
            ptrs.append((off, v))
    for off, v in ptrs:
        print("  %#06x -> %#010x" % (off, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
