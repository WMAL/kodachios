#!/usr/bin/env bash

# security-metrics.sh
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
FIELD="${1:-score}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi

normalize_onoff_value() {
    local raw="${1:-}"
    local lowered=""

    raw=$(printf '%s' "$raw" | tr -d '\r' | xargs 2>/dev/null || printf '%s' "$raw")
    lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')

    case "$lowered" in
        on) echo "On" ;;
        off) echo "Off" ;;
        *) echo "$raw" ;;
    esac
}

get_hardening_display() {
    local display

    display=$(conky_gateway_get_or_default "data.health.hardening.display" "N/A" 2 "$BIN")
    display=$(printf '%s' "$display" | tr -d '\r' | xargs 2>/dev/null || printf '%s' "$display")

    case "$display" in
        ""|"N/A"|"n/a"|"-") echo "N/A" ;;
        *)
            echo "$display"
            ;;
    esac
}

case "$FIELD" in
    usbguard)
        value=$(conky_gateway_get_or_default "data.system.services.usbguard" "N/A" 2 "$BIN")
        normalize_onoff_value "$value"
        ;;
    usbkill)
        value=$(conky_gateway_get_or_default "data.system.services.usbkill" "N/A" 2 "$BIN")
        normalize_onoff_value "$value"
        ;;
    # conkyrc-security.conf renders this as "<value>/100", so it MUST be the
    # normalised percentage, not the raw weighted point total. health-control
    # scores against an ADAPTIVE maximum (81 on a live ISO / legacy BIOS, 100 on
    # an installed EFI box) because checks that cannot physically apply are
    # dropped from the denominator rather than failed. `score_display` is that
    # raw total, so pairing it with "/100" under-reports: 43.8 points out of an
    # applicable 81 is 54%, but rendered as "44/100".
    #
    # `percentage_display` is emitted by conky-status >= the build that added it.
    # Fall back to the raw total on older binaries so the panel keeps showing a
    # number instead of N/A until the new conky-status is deployed.
    score)
        value=$(conky_gateway_get_or_default "data.health.percentage_display" "N/A" 2 "$BIN")
        if [ -z "$value" ] || [ "$value" = "N/A" ]; then
            value=$(conky_gateway_get_or_default "data.health.score_display" "N/A" 2 "$BIN")
        fi
        # DEGRADED CYCLE: when conky-status cannot compute the score it still
        # writes a full health block, but flags it (sections.score:false,
        # level "Unknown", score 0.0). That 0 is a NO-READING SENTINEL, not a
        # real score of zero. Rendering it as "Score: 0/100" tells the user their
        # machine is completely unprotected, which is a lie. Print "--" instead.
        # (A genuinely 0-scoring machine still gets a real level, e.g. "Critical",
        # so it is not suppressed by this check.)
        # "N/A" joined the sentinel set on 2026-09-28: conky-status used to publish
        # `score: 0` / `percentage_display: "0"` on a degraded cycle and now publishes
        # null / "N/A", which is more honest at the source but reaches this script as
        # its own "N/A" default and so missed the guard below. Both spellings of "no
        # reading" now print this panel's own sentinel.
        level=$(conky_gateway_get_or_default "data.health.level" "" 2 "$BIN")
        if [ "$level" = "Unknown" ] && { [ "$value" = "0" ] || [ -z "$value" ] || [ "$value" = "N/A" ]; }; then
            value="--"
        fi
        printf '%s\n' "$value"
        ;;
    # The underlying raw weighted points and their adaptive ceiling, for callers
    # that want the absolute figures rather than the percentage.
    score_points) conky_gateway_get_or_default "data.health.score_display" "N/A" 2 "$BIN" ;;
    score_max) conky_gateway_get_or_default "data.health.max_score" "N/A" 2 "$BIN" ;;
    harden) get_hardening_display ;;
    *) echo "N/A" ;;
esac
