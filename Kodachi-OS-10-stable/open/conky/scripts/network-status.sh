#!/usr/bin/env bash

# network-status.sh
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
# Version: 9.0.1
# Last updated: 2026-03-02
#
# Description:
# Kodachi Conky helper script for dashboard/runtime panel data.
# Uses the conky-status gateway where applicable.

set -u
FIELD="${1:-active}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    active) conky_gateway_get_or_default "data.system.network.interface" "N/A" 2 "$BIN" ;;
    gateway) conky_gateway_get_or_default "data.system.network.gateway" "N/A" 2 "$BIN" ;;
    mac) conky_gateway_get_or_default "data.system.network.mac" "N/A" 2 "$BIN" ;;
    interfaces) conky_gateway_get_or_default "data.system.network.interfaces" "N/A" 2 "$BIN" ;;
    localip) conky_gateway_get_or_default "data.system.network.local_ip" "N/A" 2 "$BIN" ;;
    # Added 2026-09-05. macrandom answers Yes/No/Yes*/No*/?. The kernel reports a
    # permaddr only when the running MAC differs from the hardware one, and the
    # sysfs addr_assign_type decides when it does not (see conky-status
    # adapters/system.rs mac_randomized_from). A trailing "*" means the reading
    # was CARRIED from the previous cycle because this cycle's detection phase
    # tripped its deadline (at most two cycles, then it becomes "?"). "?" means
    # unmeasured: the snapshot predates the field, the interface has no Ethernet
    # address, or the carry expired.
    macrandom) conky_gateway_get_or_default "network-status.macrandom" "?" 2 "$BIN" ;;
    # One execpi call renders the whole coloured value, instead of the two or
    # three execi calls a nested ${if_match} in the conf would cost per cycle.
    # The carried forms keep their value and show the marker in the stale colour,
    # the same treatment the firewall/VPN rows get; the round-3 inspector found
    # the first version collapsed them into "?" through the default arm.
    macrandom-conky)
        value=$(conky_gateway_get_or_default "network-status.macrandom" "?" 2 "$BIN")
        case "$value" in
            Yes)    printf '%s\n' '${color1}Yes' ;;
            No)     printf '%s\n' '${color6}No' ;;
            "Yes*") printf '%s\n' '${color1}Yes${color6}*' ;;
            "No*")  printf '%s\n' '${color6}No*' ;;
            *)      printf '%s\n' '${color3}?' ;;
        esac
        ;;
    # Bound sockets from /proc/net: "<public> pub/<total>". Public means bound on
    # something other than loopback, including the wildcard address.
    listen) conky_gateway_get_or_default "network-status.listen" "" 2 "$BIN" ;;
    ipv6) conky_gateway_get_or_default "network-status.ipv6" "?" 2 "$BIN" ;;
    *) echo "N/A" ;;
esac
