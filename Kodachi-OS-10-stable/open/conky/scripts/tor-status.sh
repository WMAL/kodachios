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
# F19: answer from the snapshot-generation memo when nothing this script reads has
# changed (conky-snapshot-memo.sh explains why the output is identical). Any doubt
# falls through to the unchanged body below.
if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
    . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
fi
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
    # F17 conky side (2026-09-30): the security panel rendered these three rows as
    #   ${if_match "${execi 17 tor-status.sh X}" == "On"}${color1}On${else}${color6}Off${endif}
    # so "?" (adapters/tor.rs publishes it when tor-switch did not answer) and "N/A"
    # (no tor block in the snapshot) both printed a red "Off": a failed read shown as
    # "not Tor". These modes print the coloured value for ${execpi}: On and Off exactly
    # as before, anything else "Unknown". One process per row instead of one per
    # if_match branch.
    tor-conky|tordns-conky|torrified-conky)
        case "$FIELD" in
            tor-conky) _tor_key="data.tor.onoff" ;;
            tordns-conky) _tor_key="data.tor.tor_dns_onoff" ;;
            *) _tor_key="data.tor.torrified_onoff" ;;
        esac
        case "$(conky_gateway_get_or_default "$_tor_key" "N/A" 2 "$BIN")" in
            On) printf '%s\n' '${color1}On' ;;
            Off) printf '%s\n' '${color6}Off' ;;
            *) printf '%s\n' '${color7}Unknown' ;;
        esac
        ;;
    # DNSCrypt's row, one exec with an amber third state (inspector pass 6): the old
    # two-exec if_match chain printed "Off" for "Unknown", which conky-status
    # publishes when the dnscrypt read failed or lacked a field.
    dnscrypt-conky)
        case "$(conky_gateway_get_or_default "data.dns.dnscrypt_onoff" "N/A" 2 "$BIN")" in
            On) printf '%s\n' '${color1}On' ;;
            Up) printf '%s\n' '${color7}Up' ;;
            Off) printf '%s\n' '${color6}Off' ;;
            *) printf '%s\n' '${color7}Unknown' ;;  # dnscrypt read failed or lacked a field
        esac
        ;;
    *) echo "N/A" ;;
esac
