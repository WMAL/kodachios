#!/usr/bin/env bash

# process-age.sh
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
FIELD="${1:-vpn}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

compact_age() {
    local raw="${1:-}"
    local value=""
    local days=0
    local hours=0
    local minutes=0
    local seconds=0

    value=$(echo "$raw" | tr -d '\r' | xargs)
    if [[ -z "$value" ]] || [[ "$value" == "N/A" ]]; then
        echo "N/A"
        return 0
    fi

    if [[ "$value" =~ ^([0-9]+)-([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
        days=$((10#${BASH_REMATCH[1]}))
        hours=$((10#${BASH_REMATCH[2]}))
        minutes=$((10#${BASH_REMATCH[3]}))
        seconds=$((10#${BASH_REMATCH[4]}))
    elif [[ "$value" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
        hours=$((10#${BASH_REMATCH[1]}))
        minutes=$((10#${BASH_REMATCH[2]}))
        seconds=$((10#${BASH_REMATCH[3]}))
    elif [[ "$value" =~ ^([0-9]+):([0-9]{2})$ ]]; then
        minutes=$((10#${BASH_REMATCH[1]}))
        seconds=$((10#${BASH_REMATCH[2]}))
    elif [[ "$value" =~ ^([0-9]+)$ ]]; then
        seconds=$((10#${BASH_REMATCH[1]}))
    else
        echo "$value"
        return 0
    fi

    if (( seconds >= 60 )); then
        minutes=$((minutes + seconds / 60))
        seconds=$((seconds % 60))
    fi
    if (( minutes >= 60 )); then
        hours=$((hours + minutes / 60))
        minutes=$((minutes % 60))
    fi
    if (( hours >= 24 )); then
        days=$((days + hours / 24))
        hours=$((hours % 24))
    fi

    if (( days > 0 )); then
        if (( hours > 0 )); then
            echo "${days}d ${hours}h"
        else
            echo "${days}d"
        fi
    elif (( hours > 0 )); then
        if (( minutes > 0 )); then
            echo "${hours}h ${minutes}m"
        else
            echo "${hours}h"
        fi
    elif (( minutes > 0 )); then
        if (( seconds > 0 )); then
            echo "${minutes}m ${seconds}s"
        else
            echo "${minutes}m"
        fi
    else
        echo "${seconds}s"
    fi
}

if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    vpn|tor)
        raw_age=$(conky_gateway_get_or_default "process-age.$FIELD" "N/A" 2 "$BIN")
        compact_age "$raw_age"
        ;;
    *)
        echo "N/A"
        ;;
esac
