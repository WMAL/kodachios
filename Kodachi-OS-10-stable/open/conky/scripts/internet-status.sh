#!/usr/bin/env bash

# internet-status.sh
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
FIELD="${1:-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
# The health adapter has classified connectivity into a QUALITY tier since
# 2026-05 (green: IP+DNS fine; yellow: routable but DNS broken or cache-only;
# red: only HTTP works, the classic Tor/proxy path; off: nothing answers) and
# documented that the panel should show it. The panel only ever rendered the
# On/Off string. `tier` exposes it; `conky` renders the whole coloured value in
# ONE execpi call so the conf does not need three nested ${if_match} probes.
# Both fall back to the plain status so an older snapshot still renders.
tier_value() {
    local t
    t=$(conky_gateway_get_or_default "internet-tier" "" 2 "$BIN")
    case "$t" in
        green|yellow|red|off) printf '%s\n' "$t"; return 0 ;;
    esac
    case "$(conky_gateway_get_or_default "internet-status" "N/A" 2 "$BIN")" in
        Online) echo "green" ;;
        Offline) echo "off" ;;
        *) echo "unknown" ;;
    esac
}
case "$FIELD" in
    tier) tier_value ;;
    conky)
        case "$(tier_value)" in
            green)      printf '%s\n' '${color1}On' ;;
            yellow|red) printf '%s\n' '${color7}On' ;;
            off)        printf '%s\n' '${color6}Off' ;;
            *)          printf '%s\n' '${color3}?' ;;
        esac
        ;;
    *) conky_gateway_get_or_default "internet-status" "N/A" 2 "$BIN" ;;
esac
