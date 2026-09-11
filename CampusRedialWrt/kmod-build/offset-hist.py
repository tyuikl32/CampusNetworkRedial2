#!/usr/bin/env python3
"""Compare struct-field offsets used by two ARM kernel modules.

Reads two `arm-linux-objdump -dr` listings and extracts, per function, the set of
immediate displacement values used in ldr/str-with-immediate instructions that
fall inside the range a `struct net_device` can occupy.

If both modules were compiled from the same source against the same struct
layout, the immediate sets per function must agree.  A layout change shows up as
offset values shifting (e.g. 0x144 -> 0x150), which is exactly the failure mode
that panicked the router.

Usage: offset-hist.py <a.asm> <b.asm>
"""
import collections
import re
import sys

FUNC_RE = re.compile(r"^([0-9a-f]+) <([^>]+)>:")
# ldr/str family with an immediate displacement, base register rN
# NOTE: we must capture the BASE register too.  [sp, #N] / [pc, #N] are stack
# frame / literal-pool displacements, which differ wildly between compilers and
# have nothing to do with struct layout -- counting them buries the real signal.
MEM_RE = re.compile(
    r"\b(?:ldr|str|ldrb|strb|ldrh|strh|ldrsb|ldrsh|ldrd|strd)\w*\s+"
    r"(?:r\d+|lr|pc)\s*,\s*\[(r\d+|sp|pc)\s*(?:,\s*#(-?(?:0x[0-9a-fA-F]+|\d+)))?\]"
)

# struct net_device lives well below this; anything larger is another object.
LO, HI = 0x40, 0xC00


def scan(path):
    funcs = collections.OrderedDict()
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = FUNC_RE.match(line)
            if m:
                cur = m.group(2)
                funcs.setdefault(cur, collections.Counter())
                continue
            if cur is None:
                continue
            if ">" in line and ":" not in line[:12]:
                # relocation banner line, e.g. "  1c: R_ARM_ABS32  foo"
                continue
            mm = MEM_RE.search(line)
            if not mm:
                continue
            base = mm.group(1)
            if base in ("sp", "pc"):
                # stack-frame / literal-pool displacement: compiler-specific noise
                continue
            disp = mm.group(2)
            if disp is None:
                continue
            try:
                v = int(disp, 0)
            except ValueError:
                continue
            if v < 0:
                continue
            if LO <= v <= HI:
                funcs[cur][v] += 1
    return funcs


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a_name, b_name = sys.argv[1], sys.argv[2]
    a, b = scan(a_name), scan(b_name)

    only_a = [f for f in a if f not in b]
    only_b = [f for f in b if f not in a]
    shared = [f for f in a if f in b]

    print("functions: %s=%d  %s=%d  shared=%d" % (a_name, len(a), b_name, len(b), len(shared)))
    if only_a:
        print("  only in A: %s" % ", ".join(only_a[:12]))
    if only_b:
        print("  only in B: %s" % ", ".join(only_b[:12]))

    same = diff = 0
    report = []
    for f in shared:
        sa, sb = set(a[f]), set(b[f])
        if sa == sb:
            same += 1
        else:
            diff += 1
            report.append((f, sorted(sa - sb), sorted(sb - sa)))

    print("  offset-set identical: %d   different: %d" % (same, diff))
    if report:
        print("\n--- functions whose net_device offsets differ ---")
        for f, miss, extra in report[:40]:
            print("  %-40s A-only=%s  B-only=%s" % (
                f,
                " ".join("0x%x" % v for v in miss[:12]) or "-",
                " ".join("0x%x" % v for v in extra[:12]) or "-",
            ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
