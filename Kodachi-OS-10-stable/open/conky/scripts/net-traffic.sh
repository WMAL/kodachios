#!/usr/bin/env bash

# net-traffic.sh
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
FIELD="${1:-iface}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    gauges)
        # BATCH FIELD FOR THE GAUGES PANEL: up, down and totalpercent in ONE invocation,
        # emitted as three lines in that order.
        #
        # conky-gauges.lua asked for these three separately on every 3-second draw, so the
        # panel paid three bash startups, three stat calls and three jq calls twenty times a
        # minute. Measured on testvm-kodachi-0425b0 (live <lab-host> beta) 2026-09-04: one
        # gateway call costs ~322 ms and ~15 forks, and /proc cutime+cstime attributed
        # 16.33 CPU-seconds per minute of child work to this one panel.
        #
        # This changes NOTHING about refresh rate or displayed values: the three keys come
        # out of the same snapshot read that a single one would have used, and
        # conky_gateway_get_many falls back to the per-key path whenever the batch cannot be
        # served, so the values are identical either way.
        # Defensive: conky_gateway_get_many lives in conky-gateway-common.sh, which is
        # sourced above with `|| true`. If that source ever fails, the function is undefined
        # and the batch would emit nothing at all, which the Lua caller would read as a short
        # read. Fall back to the three single-key calls, which is exactly what it did before.
        if declare -F conky_gateway_get_many >/dev/null 2>&1; then
            conky_gateway_get_many "0" "net-traffic.up" "net-traffic.down" "net-traffic.totalpercent"
        else
            conky_gateway_get_or_default "net-traffic.up" "0" 2 "$BIN"
            conky_gateway_get_or_default "net-traffic.down" "0" 2 "$BIN"
            conky_gateway_get_or_default "net-traffic.totalpercent" "0" 2 "$BIN"
        fi
        ;;
    iface|up|down|totalup|totaldown)
        conky_gateway_get_or_default "net-traffic.$FIELD" "N/A" 2 "$BIN"
        ;;
    totalbytes_up|totalbytes_down|totalpercent)
        conky_gateway_get_or_default "net-traffic.$FIELD" "0" 2 "$BIN"
        ;;
    *)
        echo "N/A"
        ;;
esac
