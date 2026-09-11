#!/bin/sh
set -eu

cat >&2 <<'EOF'
build-dev-apk.sh is a historical OpenWrt 25.12/APK helper.
The current acceptance target is OpenWrt 21.02.7 and must be built with its
matching SDK make/opkg (.ipk) flow; this script is intentionally disabled.
EOF
exit 2

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
pkg_dir="$repo_dir/luci-app-campus-redial"
sdk_dir=${1:-${OPENWRT_SDK:-}}
out_file=${2:-"$repo_dir/luci-app-campus-redial-1.0.0-r1.dev.apk"}

[ -n "$sdk_dir" ] || { echo "usage: $0 /path/to/openwrt-sdk [output.apk]" >&2; exit 2; }
apk_bin="$sdk_dir/staging_dir/host/bin/apk"
[ -x "$apk_bin" ] || { echo "missing SDK host apk: $apk_bin" >&2; exit 2; }

target_cc=${TARGET_CC:-}
if [ -z "$target_cc" ]; then
    for candidate in "$sdk_dir"/staging_dir/toolchain-*/bin/*-openwrt-linux-*-gcc; do
        if [ -x "$candidate" ]; then
            target_cc=$candidate
            break
        fi
    done
fi
[ -x "$target_cc" ] || { echo "missing SDK target compiler (set TARGET_CC)" >&2; exit 2; }

arch=${OPENWRT_ARCH:-}
if [ -z "$arch" ] && [ -r "$sdk_dir/.config" ]; then
    arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"/\1/p' "$sdk_dir/.config" | head -n 1)
fi
if [ -z "$arch" ]; then
    case "$(basename "$target_cc")" in
        x86_64-*) arch=x86_64 ;;
    esac
fi
[ -n "$arch" ] || { echo "cannot determine APK architecture (set OPENWRT_ARCH)" >&2; exit 2; }

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
root="$tmp_dir/root"
mkdir -p "$root"
cp -a "$pkg_dir/root/." "$root/"
mkdir -p "$root/www/luci-static/resources/view/campus-redial"
cp -f "$pkg_dir/htdocs/luci-static/resources/view/campus-redial/overview.js" \
    "$root/www/luci-static/resources/view/campus-redial/overview.js"
mkdir -p "$root/usr/lib"
"$target_cc" -Os -fPIC -shared -Wl,--no-undefined \
    -o "$root/usr/lib/campus-redial-bind.so" \
    "$pkg_dir/src/campus-redial-bind.c" -ldl

find "$root" -type f -exec chmod 755 {} \;
chmod 644 "$root/etc/config/campus-redial" \
	"$root/usr/lib/campus-redial-bind.so" \
	"$root/lib/upgrade/keep.d/luci-app-campus-redial" \
    "$root/usr/share/luci/menu.d/luci-app-campus-redial.json" \
    "$root/usr/share/rpcd/acl.d/luci-app-campus-redial.json" \
    "$root/usr/share/rpcd/ucode/campus_redial.uc" \
    "$root/www/luci-static/resources/view/campus-redial/overview.js"
mkdir -p "$root/lib/apk/packages"
cat > "$root/lib/apk/packages/luci-app-campus-redial.conffiles" <<'EOF'
/etc/config/campus-redial
/etc/campus-redial/stats.json
/etc/campus-redial/last-run.json
/etc/campus-redial/firewall-managed-networks
EOF
printf '/etc/config/campus-redial %s\n' \
    "$(sha256sum "$root/etc/config/campus-redial" | cut -d' ' -f1)" \
    > "$root/lib/apk/packages/luci-app-campus-redial.conffiles_static"

cat > "$tmp_dir/postinst" <<'EOF'
#!/bin/sh
[ -f /etc/config/campus-redial ] && chmod 600 /etc/config/campus-redial
[ -n "$IPKG_INSTROOT" ] || /etc/init.d/campus-redial enable
exit 0
EOF
chmod 755 "$tmp_dir/postinst"
chmod 755 "$pkg_dir/tools/dev-prerm.sh"

mkdir -p "$(dirname "$out_file")"
PATH="$sdk_dir/staging_dir/host/bin:$PATH" "$apk_bin" mkpkg --compat 3.0.0 \
    --info 'name:luci-app-campus-redial' \
    --info 'version:1.0.0-r1' \
    --info "arch:$arch" \
    --info 'description:Campus network automatic redial' \
    --info 'depends:luci-base rpcd rpcd-mod-ucode ucode uclient-fetch ca-bundle ppp ppp-mod-pppoe ip-tiny kmod-macvlan mwan3' \
    --script "post-install:$tmp_dir/postinst" \
    --script "pre-deinstall:$pkg_dir/tools/dev-prerm.sh" \
    --files "$root" \
    --output "$out_file"
printf 'wrote %s\n' "$out_file"
