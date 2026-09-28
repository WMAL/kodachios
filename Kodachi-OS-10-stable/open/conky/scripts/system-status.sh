#!/usr/bin/env bash

# system-status.sh
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
FIELD="${1:-nuke}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    nuke|autologin|diskenc|swapenc|swapcount)
        conky_gateway_get_or_default "system-status.$FIELD" "N/A" 2 "$BIN"
        ;;
    swapperc)
        conky_gateway_get_or_default "system-status.$FIELD" "0" 2 "$BIN"
        ;;
    *)
        echo "N/A"
        ;;
esac
