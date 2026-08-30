#!/bin/bash -eu

IFACE_ETH0="eth0"
IFACE_LO="lo"
PREFIX_LEN="128"

md=$(curl -s 169.254.169.254/metadata/v1.json)
md_rip6_json=$(echo "${md}" | jq -r '.reserved_ip.ipv6')
static_ipv6_subnet="$(echo "${md}" | jq -r '.interfaces.public[0].ipv6.gateway')/64"

case "$(echo "${md_rip6_json}" | jq -r '.active')" in
    "true")
        rip6=$(echo "${md_rip6_json}" | jq -r '.ip_address')
        ip -6 addr replace "${rip6}/${PREFIX_LEN}" dev ${IFACE_LO} scope global
        echo "Assigned ${rip6}/${PREFIX_LEN} to ${IFACE_LO}"
        ip -6 route replace default dev ${IFACE_ETH0} src ${rip6}
        echo "Created default IPv6 route via ${IFACE_ETH0} with source ${rip6}"
        if [[ "${static_ipv6_subnet}" != "null/64" && "${static_ipv6_subnet}" != "/64" ]]; then
            ip -6 route delete ${static_ipv6_subnet} dev ${IFACE_ETH0}
            ip -6 route add ${static_ipv6_subnet} dev ${IFACE_ETH0} src ${rip6}
            echo "Updated static IPv6 subnet route with source ${rip6}"
        fi
        ;;
    "false")
        ip -6 addr flush dev ${IFACE_LO} scope global
        echo "Removed all Reserved IPv6 addresses from ${IFACE_LO}"
        if [[ "${static_ipv6_subnet}" != "null/64" && "${static_ipv6_subnet}" != "/64" ]]; then
            ip -6 route replace default dev ${IFACE_ETH0}
            echo "Restored default IPv6 route via ${IFACE_ETH0}"
            ip -6 route replace ${static_ipv6_subnet} dev ${IFACE_ETH0}
            echo "Restored static IPv6 subnet route"
        elif [[ "$(ip -6 route show default dev ${IFACE_ETH0})" != "" && "$(ip -6 addr show dev ${IFACE_ETH0} scope global)" == "" ]]; then
            ip -6 route delete default dev ${IFACE_ETH0}
            echo "Deleted default IPv6 route via ${IFACE_ETH0}"
        fi
        ;;
esac
