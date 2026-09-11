#!/bin/bash
# Build AX3000 (ipq50xx / QSDK 11.5.0.5 / Linux 5.4.164) kernel modules from the
# device's own /proc/config.gz dump, so that struct layouts (not just vermagic)
# match the running kernel.
#
# Run inside WSL/Linux as root.  Produces:
#   out/macvlan.ko         -> multi-PPPoE sessions need one MAC per session
#   out/xt_statistic.ko    -> mwan3 needs -m statistic
#   out/tun.ko             -> reference build, disassembled and compared against
#                             the vendor tun.ko already on the device (ABI proof)
#   out/cr_abicheck.ko     -> read-only net_device ABI canary, loaded first
set -eu

SRC=${SRC:-/mnt/d/CampusNetworkRedial/campus-network-redial/CampusRedialWrt/kmod-build}
DST=${DST:-/opt/kmod-build}
TCNAME=armv7-eabihf--glibc--stable-2022.08-1
K=$DST/linux-5.4.164
TC=$DST/$TCNAME
CROSS=$TC/bin/arm-buildroot-linux-gnueabihf-
J=$(nproc)
OUT=$DST/out

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -x "${CROSS}gcc" ] || { echo "toolchain missing: ${CROSS}gcc"; exit 1; }
[ -f "$K/Makefile" ] || { echo "kernel source missing: $K"; exit 1; }
mkdir -p "$OUT"

say "toolchain"
"${CROSS}gcc" --version | head -1

# --- config --------------------------------------------------------------
say "installing device config + enabling the two leaf modules we need"
cp "$SRC/config-5.4.164-ax3000" "$K/.config"
"$K/scripts/config" --file "$K/.config" \
	--module MACVLAN \
	--module NETFILTER_XT_MATCH_STATISTIC
make -C "$K" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig >/dev/null
grep -E '^CONFIG_(MACVLAN|NETFILTER_XT_MATCH_STATISTIC|ARM_MODULE_PLTS|SMP|PREEMPT|WIRELESS_EXT|NET_NS)=' "$K/.config"
grep -q '^# CONFIG_MODVERSIONS is not set' "$K/.config" || { echo "MODVERSIONS unexpectedly on"; exit 1; }

say "modules_prepare"
make -C "$K" ARCH=arm CROSS_COMPILE="$CROSS" -j"$J" modules_prepare

# --- build helpers -------------------------------------------------------
# try an in-tree single .ko target, fall back to the whole directory
buildmod() {
	dir=$1; ko=$2
	say "build $ko"
	if make -C "$K" ARCH=arm CROSS_COMPILE="$CROSS" -j"$J" "$ko" >/tmp/build.log 2>&1; then
		tail -2 /tmp/build.log
	else
		echo "  single-target build failed, retrying M=$dir"
		make -C "$K" ARCH=arm CROSS_COMPILE="$CROSS" -j"$J" M="$dir" modules >/tmp/build.log 2>&1 \
			|| { tail -40 /tmp/build.log; return 1; }
	fi
	test -f "$K/$ko" || { echo "  NOT PRODUCED: $K/$ko"; return 1; }
	cp "$K/$ko" "$OUT/$(basename "$ko")"
	echo "  -> $OUT/$(basename "$ko")  ($(stat -c%s "$OUT/$(basename "$ko")") bytes)"
}

buildmod drivers/net     drivers/net/macvlan.ko
buildmod drivers/net     drivers/net/tun.ko
buildmod net/netfilter   net/netfilter/xt_statistic.ko

# --- ABI canary module ---------------------------------------------------
say "build cr_abicheck.ko (read-only net_device ABI canary)"
mkdir -p "$DST/abicheck"
cp "$SRC/abicheck/Makefile" "$SRC/abicheck/cr_abicheck.c" "$DST/abicheck/"
make -C "$K" ARCH=arm CROSS_COMPILE="$CROSS" -j"$J" M="$DST/abicheck" modules >/tmp/build-abicheck.log 2>&1 \
	|| { tail -40 /tmp/build-abicheck.log; exit 1; }
cp "$DST/abicheck/cr_abicheck.ko" "$OUT/cr_abicheck.ko"
echo "  -> $OUT/cr_abicheck.ko"

# --- strip debug info (the device has little flash; vendor modules are stripped)
say "stripping debug sections"
for f in "$OUT"/*.ko; do
	"$TC/bin/arm-buildroot-linux-gnueabihf-strip" --strip-debug "$f"
done

# --- report --------------------------------------------------------------
say "results"
for f in "$OUT"/*.ko; do
	printf '%-24s %8s bytes  sha256=%s\n' "$(basename "$f")" "$(stat -c%s "$f")" "$(sha256sum "$f" | cut -c1-32)"
done

say "vermagic (every module must be: 5.4.164 SMP preempt mod_unload ARMv7 p2v8)"
for f in "$OUT"/*.ko; do
	printf '%-24s %s\n' "$(basename "$f")" "$(strings "$f" | grep -m1 '^vermagic=' || echo '<none>')"
done

say "ELF sections (ARM_MODULE_PLTS=y => .plt/.rel.plt must be present)"
for f in "$OUT"/macvlan.ko "$OUT"/xt_statistic.ko "$OUT"/tun.ko; do
	printf '%-24s %s\n' "$(basename "$f")" "$(readelf -S "$f" | grep -oE '\.(plt|rel\.plt|text)\b' | sort -u | tr '\n' ' ')"
done

say "done"
