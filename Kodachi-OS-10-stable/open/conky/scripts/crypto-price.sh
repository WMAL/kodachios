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
