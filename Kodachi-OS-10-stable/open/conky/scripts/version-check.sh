#!/usr/bin/env bash

# version-check.sh
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
# changed (conky-snapshot-memo.sh explains why the output is identical). This script
# reads through system-meta.sh, which also reads build-meta.json, so system-meta.sh
# and every build-meta candidate it may pick are declared: a change to any of them is
# a miss. Any doubt falls through to the unchanged body below.
if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
    # shellcheck disable=SC2034  # read by conky_memo_run in the sourced helper
    CONKY_MEMO_DEPS=(
        "${BASH_SOURCE[0]%/*}/system-meta.sh"
        "${BUILD_META_FILE_CACHE:-}"
        "${KODACHI_BUILD_META_FILE:-}"
        "/opt/kodachi/dashboard/hooks/config/build-meta.json"
        "$HOME/k900/dashboard/hooks/config/build-meta.json"
        "$HOME/dashboard/hooks/config/build-meta.json"
        "$HOME/Desktop/dashboard/hooks/config/build-meta.json"
        "/usr/share/kodachi/config/build-meta.json"
    )
    . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
    unset CONKY_MEMO_DEPS
fi
COMPONENT="${1:-any}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

normalize_version_value() {
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="$(echo "$value" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    if [[ -z "$value" || "$value" == "N/A" ]]; then
        echo "N/A"
    else
        echo "$value"
    fi
}

compare_versions() {
    local left=""
    local right=""
    local first_sorted=""

    left="$(normalize_version_value "${1:-}")"
    right="$(normalize_version_value "${2:-}")"

    if [[ "$left" == "N/A" || "$right" == "N/A" ]]; then
        return 3
    fi

    left="${left#v}"
    right="${right#v}"

    if [[ "$left" == "$right" ]]; then
        return 0
    fi

    first_sorted="$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n1)"
    if [[ "$first_sorted" == "$left" ]]; then
        return 2
    fi

    return 1
}

get_status() {
    local comp="$1"
    local local_version=""
    local remote_version=""

    local_version="$(normalize_version_value "$("$SCRIPT_DIR/system-meta.sh" "${comp}_cur" 2>/dev/null || echo "N/A")")"
    remote_version="$(normalize_version_value "$("$SCRIPT_DIR/system-meta.sh" "${comp}_on" 2>/dev/null || echo "N/A")")"

    if [[ "$local_version" == "N/A" || "$remote_version" == "N/A" ]]; then
        echo "N/A"
        return 0
    fi

    compare_versions "$local_version" "$remote_version"
    case $? in
        0|1)
            echo "current"
            ;;
        2)
            echo "update"
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

case "$COMPONENT" in
    binary|terminal|desktop)
        get_status "$COMPONENT"
        ;;
    any)
        # AN EDITION THIS MACHINE DOES NOT CARRY MUST NOT MAKE THE AGGREGATE UNKNOWN
        # (2026-09-26). A desktop install has no local terminal ISO, so terminal reports N/A
        # by design. Folding that into the aggregate turned a perfectly current machine into
        # "N/A", which is the same false signal as the old stale-version "update", just
        # quieter. Skip non-applicable editions; a genuine N/A on an applicable one still
        # makes the aggregate unknown, because that really is unknown.
        agg_update=0
        agg_unknown=0
        for comp in binary terminal desktop; do
            if [[ "$("$SCRIPT_DIR/system-meta.sh" "${comp}_applicable" 2>/dev/null)" == "no" ]]; then
                continue
            fi
            case "$(get_status "$comp")" in
                update) agg_update=1 ;;
                N/A)    agg_unknown=1 ;;
            esac
        done
        if [[ "$agg_update" == 1 ]]; then
            echo "update"
        elif [[ "$agg_unknown" == 1 ]]; then
            echo "N/A"
        else
            echo "current"
        fi
        ;;
    *)
        echo "N/A"
        ;;
esac
