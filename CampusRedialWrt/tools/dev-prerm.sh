#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
/etc/init.d/campus-redial stop >/dev/null 2>&1 || true
/etc/init.d/campus-redial disable >/dev/null 2>&1 || true

if [ "${1:-}" = upgrade ]; then
    exit 0
fi

firewall_state=/etc/campus-redial/firewall-managed-networks
if [ -r "$firewall_state" ] && [ -f /etc/config/firewall ]; then
    zone_index=0; wan_zone=
    while uci -q get "firewall.@zone[$zone_index]" >/dev/null 2>&1; do
        if [ "$(uci -q get "firewall.@zone[$zone_index].name" 2>/dev/null || true)" = wan ]; then
            wan_zone="@zone[$zone_index]"; break
        fi
        zone_index=$((zone_index + 1))
    done
    if [ -n "$wan_zone" ]; then
        while IFS= read -r name; do
            case "$name" in ''|*[!a-zA-Z0-9_-]*) continue ;; esac
            uci -q del_list "firewall.$wan_zone.network=$name" >/dev/null 2>&1 || true
        done < "$firewall_state"
        uci commit firewall >/dev/null 2>&1 || true
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi
    rm -f "$firewall_state"
fi

wan="$(uci -q get campus-redial.main.wan_interface 2>/dev/null || true)"
[ -n "$wan" ] || wan=wan
case "$wan" in
    lan|loopback|br-lan|*[!a-zA-Z0-9_-]*) wan=wan ;;
esac

if [ "$(uci -q get network.${wan}.campus_redial_ipv6_managed 2>/dev/null || true)" = 1 ]; then
    state=/etc/campus-redial/main-network-state
    if [ -r "$state" ]; then
        ipv6="$(grep -m 1 '^ipv6=' "$state" 2>/dev/null | sed 's/^ipv6=//' || true)"
        delegate="$(grep -m 1 '^delegate=' "$state" 2>/dev/null | sed 's/^delegate=//' || true)"
        case "$ipv6" in
            '') uci -q delete network.${wan}.ipv6 ;;
            0|1) uci set network.${wan}.ipv6="$ipv6" ;;
        esac
        case "$delegate" in
            '') uci -q delete network.${wan}.delegate ;;
            0|1) uci set network.${wan}.delegate="$delegate" ;;
        esac
    fi
    uci -q delete network.${wan}.campus_redial_ipv6_managed || true
fi

for i in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
    if [ "$(uci -q get network.wan${i}.campus_redial_managed 2>/dev/null || true)" = 1 ]; then
        ifdown wan${i} >/dev/null 2>&1 || true
        uci -q delete network.wan${i} || true
        uci -q delete network.campus_wan${i}_device || true
    fi
done
uci commit network >/dev/null 2>&1 || true

if [ -f /etc/config/mwan3 ]; then
    for name in "$wan" wan2 wan3 wan4 wan5 wan6 wan7 wan8 wan9 wan10 wan11 wan12 wan13 wan14 wan15 wan16 wan17 wan18 wan19 wan20 wan21 wan22 wan23 wan24; do
        uci -q delete mwan3.campus_redial_${name}_member || true
        if [ "$(uci -q get mwan3.${name}.campus_redial_managed 2>/dev/null || true)" = 1 ]; then
            uci -q delete mwan3.${name} || true
        fi
        uci -q delete mwan3.campus_redial_${name} || true
    done
    uci -q delete mwan3.campus_redial_balanced || true
    uci -q delete mwan3.campus_redial_default_ipv4 || true
    uci commit mwan3 >/dev/null 2>&1 || true
fi
exit 0
