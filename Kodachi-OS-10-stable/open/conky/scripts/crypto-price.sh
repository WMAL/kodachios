#!/usr/bin/env bash

# crypto-price.sh
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
COIN="${1:-btc}"
COIN_LC=$(printf '%s' "$COIN" | tr '[:upper:]' '[:lower:]')
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi

case "$COIN_LC" in
    state)
        # F17 (2026-09-30): "off" while the price ticker is switched off (the default),
        # "on" when conky-status polled prices, "unknown" when the state was not read.
        # conkyrc-system.conf shows one "Prices off" row for "off", and the price rows
        # otherwise. Unknown is NOT off: an unread state keeps the rows and their N/A.
        conky_gateway_get_or_default "crypto-price.state" "unknown" 2 "$BIN"
        ;;
    btc|eth|xmr|azero|xau|xag)
        conky_gateway_get_or_default "crypto-price.$COIN_LC" "N/A" 2 "$BIN"
        ;;
    gold)
        conky_gateway_get_or_default "crypto-price.xau" "N/A" 2 "$BIN"
        ;;
    silver)
        conky_gateway_get_or_default "crypto-price.xag" "N/A" 2 "$BIN"
        ;;
    *)
        echo "N/A"
        ;;
esac
