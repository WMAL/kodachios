#!/usr/bin/env bash

# knet-status.sh
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
# A KNet check that did not answer is "?", never "Off" (inspector pass 6): conky-status
# publishes knet "?" for it, and a missing key or binary is the same unread state.
if [[ -z "$BIN" ]]; then
    value="?"
else
    value="$(conky_gateway_get_or_default "knet-status" "?" 2 "$BIN")"
fi
# `conky` prints the coloured token for ${execpi}, so the panel has a third, amber
# state without a second exec; no argument prints the plain value as before.
if [[ "${1:-}" == "conky" ]]; then
    case "$value" in
        On) printf '%s\n' '${color1}On' ;;
        Off) printf '%s\n' '${color6}Off' ;;
        *) printf '%s\n' '${color7}?' ;;
    esac
else
    printf '%s\n' "$value"
fi
