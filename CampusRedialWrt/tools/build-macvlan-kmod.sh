#!/bin/sh
# build-macvlan-kmod.sh
#
# Build a macvlan.ko that is ABI-compatible with the Redmi AX3000
# (ipq50xx / QSDK 11.5.0.5 / Linux 5.4.164) vendor kernel.
#
# Why this is needed: the community's prebuilt kmod-macvlan was compiled with a
# DIFFERENT kernel config (kernel dep hash 6be5791b..., device is 1d36e0ba...).
# vermagic matches, CONFIG_MODVERSIONS is off, so the kernel loads it happily and
# then panics in macvlan_common_newlink()->get_random_bytes() because
# struct net_device has a different layout. Only a module built from the device's
# own config is usable.
#
# MUST run on a Linux host (the Bootlin toolchain is Linux x86-64 ELF).
#
# Usage:
#   tools/build-macvlan-kmod.sh \
#       --kernel-src linux-5.4.164 \
#       --config     config-5.4.164-ax3000 \
#       --toolchain  armv7-eabihf--glibc--stable-2022.08-1 \
#       [--out out] [--jobs N]

set -eu

KERNEL_SRC=""
CONFIG_FILE=""
TOOLCHAIN=""
OUT="out"
JOBS=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--kernel-src) KERNEL_SRC="${2:-}"; shift 2 ;;
		--config)     CONFIG_FILE="${2:-}"; shift 2 ;;
		--toolchain)  TOOLCHAIN="${2:-}"; shift 2 ;;
		--out)        OUT="${2:-}"; shift 2 ;;
		--jobs)       JOBS="${2:-}"; shift 2 ;;
		-h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "$KERNEL_SRC" ] || die "--kernel-src is required"
[ -n "$CONFIG_FILE" ] || die "--config is required"
[ -n "$TOOLCHAIN" ] || die "--toolchain is required"

[ -d "$KERNEL_SRC" ]      || die "kernel tree not found: $KERNEL_SRC"
[ -f "$CONFIG_FILE" ]     || die "kernel config not found: $CONFIG_FILE"
[ -d "$TOOLCHAIN" ]       || die "toolchain not found: $TOOLCHAIN"

# --- locate cross prefix -------------------------------------------------
CROSS=""
for c in arm-buildroot-linux-gnueabihf- arm-linux-gnueabihf- \
         arm-none-linux-gnueabihf- arm-linux-gnueabi-; do
	if [ -x "$TOOLCHAIN/bin/${c}gcc" ]; then CROSS="$TOOLCHAIN/bin/$c"; break; fi
done
[ -n "$CROSS" ] || die "no ARM cross gcc found under $TOOLCHAIN/bin"
say "cross compiler: ${CROSS}gcc"
"${CROSS}gcc" --version | head -1

# --- sanity-check the config against the device facts -------------------
say "checking kernel config options that matter for ABI/vermagic"
check_on() {
	grep -q "^$1=y" "$CONFIG_FILE" || die "config is missing $1=y"
}
check_off() {
	grep -q "^# $1 is not set" "$CONFIG_FILE" || die "config should have '# $1 is not set'"
}
check_on  CONFIG_ARM_MODULE_PLTS
check_on  CONFIG_SMP
check_on  CONFIG_PREEMPT
check_off CONFIG_MODVERSIONS
check_off CONFIG_MODULE_SIG
check_off CONFIG_THUMB2_KERNEL
say "config OK (ARM_MODULE_PLTS=y, no MODVERSIONS, ARM mode)"

# --- build ---------------------------------------------------------------
KERNEL_SRC_ABS=$(cd "$KERNEL_SRC" && pwd)
OUT_ABS=$(mkdir -p "$OUT" && cd "$OUT" && pwd)

if [ -n "$JOBS" ]; then MKJ="-j$JOBS"; else MKJ="-j$(nproc 2>/dev/null || echo 4)"; fi

say "installing .config into the kernel tree"
cp "$CONFIG_FILE" "$KERNEL_SRC_ABS/.config"

# shellcheck disable=SC2086
say "make olddefconfig"
make -C "$KERNEL_SRC_ABS" ARCH=arm CROSS_COMPILE="$CROSS" olddefconfig

# shellcheck disable=SC2086
say "make modules_prepare"
make -C "$KERNEL_SRC_ABS" ARCH=arm CROSS_COMPILE="$CROSS" $MKJ modules_prepare

# shellcheck disable=SC2086
say "make M=drivers/net/macvlan modules"
make -C "$KERNEL_SRC_ABS" ARCH=arm CROSS_COMPILE="$CROSS" $MKJ \
	M=drivers/net/macvlan modules

KO="$KERNEL_SRC_ABS/drivers/net/macvlan/macvlan.ko"
[ -f "$KO" ] || die "macvlan.ko was not produced at $KO"

cp "$KO" "$OUT_ABS/macvlan.ko"
say "built $OUT_ABS/macvlan.ko"

# --- verify --------------------------------------------------------------
say "vermagic (must be exactly: 5.4.164 SMP preempt mod_unload ARMv7 p2v8)"
VM=$(strings "$OUT_ABS/macvlan.ko" | grep -m1 '^vermagic=' || true)
printf '    %s\n' "${VM:-<no vermagic found>}"
case "$VM" in
	vermagic=5.4.164\ SMP\ preempt\ mod_unload\ ARMv7\ p2v8) : ;;
	*) printf 'WARNING: vermagic does not match the expected device string\n' >&2 ;;
esac

if command -v readelf >/dev/null 2>&1; then
	say "sections"
	readelf -S "$OUT_ABS/macvlan.ko" | grep -E '\.text|\.plt' || true
fi

if command -v sha256sum >/dev/null 2>&1; then
	say "sha256"
	sha256sum "$OUT_ABS/macvlan.ko"
fi

cat <<EOF

Next steps (deploy to 192.168.6.1, ask the owner first):
  python sshvm.py upload $OUT_ABS/macvlan.ko /tmp/macvlan.ko
  python sshvm.py run 'cp /tmp/macvlan.ko /lib/modules/5.4.164/macvlan.ko; \\
      printf "%s\\n" macvlan > /etc/modules.d/30-macvlan; modprobe macvlan'
Then verify WITHOUT rebooting:
  ip link add link eth0 name crwan2 type macvlan mode bridge address 02:aa:bb:cc:dd:02
  ip link del crwan2
If the device reboots, the ABI still does not match: roll back and re-check. See
  docs/reference/AX3000-KMOD-BUILD.md
EOF
