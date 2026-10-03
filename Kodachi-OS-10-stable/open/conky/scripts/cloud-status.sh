#!/usr/bin/env bash

# cloud-status.sh
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
FIELD="${1:-users}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
# `<site>-conky` prints the Digi77 / Kodachi.cloud row's coloured token for ${execpi}:
# On / Off, and a neutral "?" when the stats read did not say (inspector pass 8: the
# two-way if_match drew conky-status's "?" as a red "Off").
case "$FIELD" in
    digi77-conky|kodachi_cloud-conky)
        value="?"
        [[ -n "$BIN" ]] && value="$(conky_gateway_get_or_default "cloud-status.${FIELD%-conky}" "?" 2 "$BIN")"
        case "$value" in
            On) printf '%s\n' '${color1}On' ;;
            Off) printf '%s\n' '${color6}Off' ;;
            *) printf '%s\n' '${color3}?' ;;
        esac
        exit 0
        ;;
esac
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    users|tusers|challenges|cards|digi77|kodachi_cloud)
        conky_gateway_get_or_default "cloud-status.$FIELD" "N/A" 2 "$BIN"
        ;;
    *)
        echo "N/A"
        ;;
esac
