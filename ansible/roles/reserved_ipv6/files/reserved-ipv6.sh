#!/bin/bash
set -euo pipefail

IFACE_ETH0="eth0"
IFACE_LO="lo"
PREFIX_LEN="128"
# Loose shape check for metadata values before they become ip(8) arguments.
IPV6_RE='^[0-9a-fA-F:]*:[0-9a-fA-F:.]*$'

md=$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 --noproxy '*' http://169.254.169.254/metadata/v1.json)
if [[ -z "${md}" ]]; then
    echo "Empty response from the metadata service" >&2
    exit 1
fi
md_rip6_json=$(jq -r '.reserved_ip.ipv6' <<<"${md}")
static_ipv6_subnet="$(jq -r '.interfaces.public[0].ipv6.gateway' <<<"${md}")/64"

case "$(jq -r '.active' <<<"${md_rip6_json}")" in
    "true")
        rip6=$(jq -r '.ip_address' <<<"${md_rip6_json}")
        if [[ ! "${rip6}" =~ ${IPV6_RE} ]]; then
            echo "Metadata returned an invalid reserved IPv6 address: ${rip6}" >&2
            exit 1
        fi
        ip -6 addr replace "${rip6}/${PREFIX_LEN}" dev "${IFACE_LO}" scope global
        echo "Assigned ${rip6}/${PREFIX_LEN} to ${IFACE_LO}"
        ip -6 route replace default dev "${IFACE_ETH0}" src "${rip6}"
        echo "Created default IPv6 route via ${IFACE_ETH0} with source ${rip6}"
        if [[ "${static_ipv6_subnet}" != "null/64" && "${static_ipv6_subnet}" != "/64" ]]; then
            # The route may already be gone on re-runs; that is fine.
            ip -6 route delete "${static_ipv6_subnet}" dev "${IFACE_ETH0}" || true
            ip -6 route add "${static_ipv6_subnet}" dev "${IFACE_ETH0}" src "${rip6}"
            echo "Updated static IPv6 subnet route with source ${rip6}"
        fi
        ;;
    "false")
        ip -6 addr flush dev "${IFACE_LO}" scope global
        echo "Removed all Reserved IPv6 addresses from ${IFACE_LO}"
        if [[ "${static_ipv6_subnet}" != "null/64" && "${static_ipv6_subnet}" != "/64" ]]; then
            ip -6 route replace default dev "${IFACE_ETH0}"
            echo "Restored default IPv6 route via ${IFACE_ETH0}"
            ip -6 route replace "${static_ipv6_subnet}" dev "${IFACE_ETH0}"
            echo "Restored static IPv6 subnet route"
        elif [[ "$(ip -6 route show default dev "${IFACE_ETH0}")" != "" && "$(ip -6 addr show dev "${IFACE_ETH0}" scope global)" == "" ]]; then
            # The route may already be gone on re-runs; that is fine.
            ip -6 route delete default dev "${IFACE_ETH0}" || true
            echo "Deleted default IPv6 route via ${IFACE_ETH0}"
        fi
        ;;
    *)
        echo "Unexpected reserved_ip.ipv6.active value in metadata; refusing to touch routes" >&2
        exit 1
        ;;
esac
