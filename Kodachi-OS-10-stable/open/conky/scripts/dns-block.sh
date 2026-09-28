#!/usr/bin/env bash

# dns-block.sh
# ===========================================================
#
# SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.1
# Copyright (c) 2013-2026 Warith Al Maawali
#
# This file is part of Kodachi OS.
# For full license terms, see LICENSE.md or visit:
# https://kodachi.cloud/docs/license.html
#
# Commercial or organizational use requires a written license.
# Contact: warith@digi77.com
#
# Author: Warith Al Maawali
# Version: <lab-host>
# Last updated: 2026-09-05
#
# Description:
# Renders the nameserver rows of the DNS section in conkyrc-security.conf as
# ONE ${execpi} block. Replaces three ${execi} directives (ns1, ns2, ns3) that
# each forked bash + jq every 61 s and that rendered EMPTY ROWS: under
# dnscrypt-proxy the resolver list is exactly [127.0.0.1], so two of the three
# rows were blank (or "N/A" on older script copies) on every Kodachi desktop.
#
# Prints only the rows that carry a value, and adds the row the section was
# missing: WHICH upstream resolver dnscrypt-proxy is configured to trust
# (data.dns.dnscrypt_servers_display, read by conky-status from
# dnscrypt-proxy.toml). That row is shown only while DNSCrypt is On or Up, so a
# stopped proxy does not advertise a resolver it is not using.
#
# One snapshot read for all five keys via conky_gateway_get_many, the same
# batching route-mode.sh uses (live-ISO gaps b21/b25).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

ROW_PREFIX='${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}'

if [[ -z "$BIN" ]]; then
    printf '%s\n' "${ROW_PREFIX}"'${color1}N/A'
    exit 0
fi

DNS_KEYS=(dns-cache.ns1 dns-cache.ns2 dns-cache.ns3 dns-cache.servers data.dns.dnscrypt_onoff)
DNS_ABSENT="__CONKY_DNS_ABSENT__"
vals=()
if declare -F conky_gateway_get_many >/dev/null 2>&1; then
    mapfile -t vals < <(CONKY_GATEWAY_MANY_TIMEOUT=2 CONKY_GATEWAY_MANY_BIN="$BIN" conky_gateway_get_many "$DNS_ABSENT" "${DNS_KEYS[@]}" 2>/dev/null)
fi
if [[ "${#vals[@]}" -ne "${#DNS_KEYS[@]}" ]]; then
    vals=()
    for k in "${DNS_KEYS[@]}"; do
        vals+=("$(conky_gateway_get_or_default "$k" "$DNS_ABSENT" 2 "$BIN")")
    done
fi

clean() {
    # The sentinel, an explicit null and a bare N/A all mean "no value here".
    local v="${1:-}"
    case "$v" in
        "$DNS_ABSENT"|"null"|"N/A"|"") printf '' ;;
        *) printf '%s' "$v" ;;
    esac
}

ns1="$(clean "${vals[0]}")"
ns2="$(clean "${vals[1]}")"
ns3="$(clean "${vals[2]}")"
servers="$(clean "${vals[3]}")"
dnscrypt_state="$(clean "${vals[4]}")"

# Never print an empty section: when nothing is known say so once.
if [[ -z "$ns1$ns2$ns3" ]]; then
    printf '%s\n' "${ROW_PREFIX}"'${color1}N/A'
else
    # Row 1: ns1 left, ns2 right (only when ns2 exists).
    if [[ -n "$ns2" ]]; then
        printf '%s\n' "${ROW_PREFIX}"'${color1}'"${ns1:-$ns2}"'${alignr}${color1}'"${ns2}"
    else
        printf '%s\n' "${ROW_PREFIX}"'${color1}'"${ns1}"
    fi
    # Row 2: ns3 only when it exists. No blank rows.
    if [[ -n "$ns3" ]]; then
        printf '%s\n' "${ROW_PREFIX}"'${color1}'"${ns3}"
    fi
fi

# Row 3: the upstream DNSCrypt resolver(s), only while dnscrypt-proxy is up.
case "$dnscrypt_state" in
    On|Up)
        if [[ -n "$servers" ]]; then
            printf '%s\n' "${ROW_PREFIX}"'${color3}Upstream: ${color1}'"${servers}"
        fi
        ;;
esac
