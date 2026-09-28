#!/usr/bin/env bash

# tor-status.sh
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
FIELD="${1:-tor}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    tor) conky_gateway_get_or_default "data.tor.onoff" "N/A" 2 "$BIN" ;;
    tordns) conky_gateway_get_or_default "data.tor.tor_dns_onoff" "N/A" 2 "$BIN" ;;
    torrified) conky_gateway_get_or_default "data.tor.torrified_onoff" "N/A" 2 "$BIN" ;;
    backend) conky_gateway_get_or_default "data.tor.backend" "N/A" 2 "$BIN" ;;
    dnscrypt) conky_gateway_get_or_default "data.dns.dnscrypt_onoff" "N/A" 2 "$BIN" ;;
    # "N of M" Kodachi Tor instances, compacted to "(N/M)" for the Tor row. The
    # snapshot has carried instances_display since 2026-08-18 (check-tor-all is
    # the only producer of it) and no panel row ever showed it: "Tor: On" with
    # 0 of 5 instances alive read exactly like 5 of 5. Empty when the snapshot
    # predates the field or the pool probe failed, so the row degrades to the
    # old plain "Tor: On".
    pool)
        value=$(conky_gateway_get_or_default "tor-status.pool" "" 2 "$BIN")
        case "$value" in
            ""|"N/A"|"null") ;;
            *) printf '(%s)\n' "${value// of //}" ;;
        esac
        ;;
    *) echo "N/A" ;;
esac
