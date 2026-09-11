include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-campus-redial
PKG_VERSION:=1.0.1
PKG_RELEASE:=1
# 许可全文在仓库根的 LICENSE（SDK 构建时包目录会被单独复制，所以这里不引用文件路径）
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Campus network automatic redial
  DEPENDS:=+luci-base +rpcd +rpcd-mod-luci +uclient-fetch +ca-bundle +ppp +ppp-mod-pppoe +ip +kmod-macvlan +mwan3
endef

define Package/$(PKG_NAME)/description
 LuCI interface and procd service for PPPoE campus network redial testing.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/campus-redial
/etc/campus-redial/stats.json
/etc/campus-redial/last-run.json
/etc/campus-redial/firewall-managed-networks
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/campus-redial-bind.c $(PKG_BUILD_DIR)/campus-redial-bind.c
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -fPIC -shared -Wl,--no-undefined \
		-o $(PKG_BUILD_DIR)/campus-redial-bind.so \
		$(PKG_BUILD_DIR)/campus-redial-bind.c -ldl
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/campus-redial $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./root/etc/config/campus-redial $(1)/etc/config/campus-redial
	$(INSTALL_BIN) ./root/etc/init.d/campus-redial $(1)/etc/init.d/campus-redial
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-campus-redial-permissions $(1)/etc/uci-defaults/99-campus-redial-permissions
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/campus-rediald $(1)/usr/sbin/campus-rediald
	$(INSTALL_BIN) ./root/usr/sbin/campus-redialctl $(1)/usr/sbin/campus-redialctl
	$(INSTALL_BIN) ./root/usr/sbin/campus-redial-mwan3 $(1)/usr/sbin/campus-redial-mwan3
	# 守护进程用 `[ -x ... ]` 调它把每条会话的默认路由注入 mwan3 自己的路由表；
	# 漏装时不会报错，但 mwan3 会把次要会话判成 error (16) 并静默丢弃分流。
	$(INSTALL_BIN) ./root/usr/sbin/campus-redial-mwan3route $(1)/usr/sbin/campus-redial-mwan3route
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/campus-redial-bind.so $(1)/usr/lib/campus-redial-bind.so
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d $(1)/usr/libexec/rpcd
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-campus-redial.json $(1)/usr/share/luci/menu.d/luci-app-campus-redial.json
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-campus-redial.json $(1)/usr/share/rpcd/acl.d/luci-app-campus-redial.json
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/campus_redial $(1)/usr/libexec/rpcd/campus_redial
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./root/lib/upgrade/keep.d/luci-app-campus-redial $(1)/lib/upgrade/keep.d/luci-app-campus-redial
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/campus-redial
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/campus-redial/overview.js $(1)/www/luci-static/resources/view/campus-redial/overview.js
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -f /etc/config/campus-redial ] && chmod 600 /etc/config/campus-redial
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/campus-redial enable
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# 升级不打断服务：早期实现无条件 stop + disable，而 postinst 只 enable 不 start，
# 于是 opkg 升级之后守护进程不会自己起来（表现为“升级完就不拨号了”，直到手动
# /etc/init.d/campus-redial start）。升级时直接返回，运行中的实例在下次重启或手动
# restart 时才换到新代码。
if [ "$${1:-}" = upgrade ]; then
	exit 0
fi

/etc/init.d/campus-redial stop >/dev/null 2>&1 || true
/etc/init.d/campus-redial disable >/dev/null 2>&1 || true

# 以下是真正的“卸载”清理：只动本包标记过的段（wan2..wan24 及其 macvlan / mwan3 段）
# 与临时 IPv6 委派改动，lan 与主 wan 原样保留。

firewall_state=/etc/campus-redial/firewall-managed-networks
if [ -r "$${firewall_state}" ] && [ -f /etc/config/firewall ]; then
	zone_index=0; wan_zone=
	while uci -q get "firewall.@zone[$${zone_index}]" >/dev/null 2>&1; do
		if [ "$$(uci -q get "firewall.@zone[$${zone_index}].name" 2>/dev/null || true)" = wan ]; then
			wan_zone="@zone[$${zone_index}]"; break
		fi
		zone_index=$$((zone_index + 1))
	done
	if [ -n "$${wan_zone}" ]; then
		while IFS= read -r name; do
			case "$${name}" in ''|*[!a-zA-Z0-9_-]*) continue ;; esac
			uci -q del_list "firewall.$${wan_zone}.network=$${name}" >/dev/null 2>&1 || true
		done < "$${firewall_state}"
		uci commit firewall >/dev/null 2>&1 || true
		/etc/init.d/firewall reload >/dev/null 2>&1 || true
	fi
	rm -f "$${firewall_state}"
fi

wan="$$(uci -q get campus-redial.main.wan_interface 2>/dev/null || true)"
[ -n "$${wan}" ] || wan=wan
case "$${wan}" in lan|loopback|br-lan|*[!a-zA-Z0-9_-]*) wan=wan ;; esac
if [ "$$(uci -q get network.$${wan}.campus_redial_ipv6_managed 2>/dev/null || true)" = 1 ]; then
	state=/etc/campus-redial/main-network-state
	if [ -r "$${state}" ]; then
		ipv6="$$(grep -m 1 '^ipv6=' "$${state}" 2>/dev/null | sed 's/^ipv6=//' || true)"
		delegate="$$(grep -m 1 '^delegate=' "$${state}" 2>/dev/null | sed 's/^delegate=//' || true)"
		case "$${ipv6}" in '') uci -q delete network.$${wan}.ipv6 ;; 0|1) uci set network.$${wan}.ipv6="$${ipv6}" ;; esac
		case "$${delegate}" in '') uci -q delete network.$${wan}.delegate ;; 0|1) uci set network.$${wan}.delegate="$${delegate}" ;; esac
	fi
	uci -q delete network.$${wan}.campus_redial_ipv6_managed || true
fi

for i in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
	if [ "$$(uci -q get network.wan$${i}.campus_redial_managed 2>/dev/null || true)" = 1 ]; then
		ifdown wan$${i} >/dev/null 2>&1 || true
		uci -q delete network.wan$${i} || true
		uci -q delete network.campus_wan$${i}_device || true
	fi
done
uci commit network >/dev/null 2>&1 || true

if [ -f /etc/config/mwan3 ]; then
	for name in "$${wan}" wan2 wan3 wan4 wan5 wan6 wan7 wan8 wan9 wan10 wan11 wan12 wan13 wan14 wan15 wan16 wan17 wan18 wan19 wan20 wan21 wan22 wan23 wan24; do
		uci -q delete mwan3.campus_redial_$${name}_member || true
		if [ "$$(uci -q get mwan3.$${name}.campus_redial_managed 2>/dev/null || true)" = 1 ]; then
			uci -q delete mwan3.$${name} || true
		fi
		uci -q delete mwan3.campus_redial_$${name} || true
	done
	uci -q delete mwan3.campus_redial_balanced || true
	uci -q delete mwan3.campus_redial_default_ipv4 || true
	uci commit mwan3 >/dev/null 2>&1 || true
fi
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
