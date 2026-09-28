#!/usr/bin/env bash

# random-ping.sh
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
# ping_ms is "0" when neither net-check nor the fallback ICMP probe produced a
# number (torrified boxes drop ICMP, offline boxes answer nothing). A real
# 0 ms round trip to an internet target does not exist, so "0" is a NO-READING
# sentinel and rendering it as "Ping: 0 ms" told the user their link was
# perfect while it was unmeasured. Same class as the security score sentinel
# (Conky-Status playbook RULE 1.5). Print "--" so the row reads "Ping: -- ms".
value=$(conky_gateway_get_or_default "random-ping" "0" 2 "$BIN")
case "$value" in
    ""|"0"|"N/A"|"null") echo "--" ;;
    *) printf '%s\n' "$value" ;;
esac
