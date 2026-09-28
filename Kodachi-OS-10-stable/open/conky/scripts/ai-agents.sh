#!/usr/bin/env bash

# ai-agents.sh
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
FIELD="${1:-list}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi

read_ai_snapshot_field() {
    local jq_expr="$1"
    local snapshot_file

    snapshot_file=$(conky_gateway_snapshot_path 2>/dev/null || true)
    [[ -n "$snapshot_file" && -s "$snapshot_file" ]] || return 1
    jq -r "$jq_expr // empty" "$snapshot_file" 2>/dev/null
}

case "$FIELD" in
    count)
        snapshot_count="$(read_ai_snapshot_field '.data.system.runtime.ai.count' || true)"
        if [[ -n "${snapshot_count:-}" ]]; then
            printf '%s\n' "$snapshot_count"
            exit 0
        fi
        conky_gateway_get_or_default "data.system.runtime.ai.count" "0" 2 "$BIN"
        ;;
    list)
        snapshot_list="$(read_ai_snapshot_field '.data.system.runtime.ai.conky' || true)"
        if [[ -n "${snapshot_list:-}" ]]; then
            printf '%s\n' "$snapshot_list"
            exit 0
        fi
        # A BLANK PANEL IS NOT A STATUS. Measured on the <lab-host>-3 live ISO: all 8
        # ai-* binaries are installed and none is running, so the snapshot carries
        # ai.entries=[] / count=0 and this rendered an empty region with no
        # explanation. Say so instead, and distinguish "not installed" from
        # "installed but idle" so the panel is actionable either way.
        ai_list="$(conky_gateway_get_multiline_or_default "ai-agents.list" "" 5 "$BIN")"
        if [[ -n "${ai_list//[[:space:]]/}" ]]; then
            printf '%s\n' "$ai_list"
        elif ls /opt/kodachi/dashboard/hooks/ai-* >/dev/null 2>&1; then
            echo "no agents running"
        else
            echo "not installed"
        fi
        ;;
    *)
        echo "N/A"
        ;;
esac
