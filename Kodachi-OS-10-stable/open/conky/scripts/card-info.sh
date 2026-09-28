#!/usr/bin/env bash

# card-info.sh
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

FIELD="${1:-available}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

BIN=""
if declare -F conky_gateway_find_binary >/dev/null 2>&1; then
    BIN=$(conky_gateway_find_binary 2>/dev/null || true)
fi

default_for_field() {
    case "${1:-}" in
        ipv4) echo "-" ;;
        ipv6) echo "-" ;;
        vpscountry) echo "-" ;;
        type) echo "-" ;;
        hostname) echo "-" ;;
        load) echo "-" ;;
        memory) echo "-/-" ;;
        uptime) echo "-" ;;
        services) echo "0" ;;
        *) echo "-" ;;
    esac
}

lower_trim() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

compact_duration() {
    local raw="${1:-}"
    local text=""
    local weeks=0
    local days=0
    local hours=0
    local minutes=0
    local seconds=0

    text=$(lower_trim "$raw")
    case "$text" in
        ""|"-"|"n/a"|"na"|"none")
            echo "-"
            return 0
            ;;
    esac

    if [[ "$text" =~ ^([0-9]+)-([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
        days=$((10#${BASH_REMATCH[1]}))
        hours=$((10#${BASH_REMATCH[2]}))
        minutes=$((10#${BASH_REMATCH[3]}))
        seconds=$((10#${BASH_REMATCH[4]}))
    elif [[ "$text" =~ ^([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
        hours=$((10#${BASH_REMATCH[1]}))
        minutes=$((10#${BASH_REMATCH[2]}))
        seconds=$((10#${BASH_REMATCH[3]}))
    elif [[ "$text" =~ ^([0-9]+):([0-9]{2})$ ]]; then
        minutes=$((10#${BASH_REMATCH[1]}))
        seconds=$((10#${BASH_REMATCH[2]}))
    else
        if [[ "$text" =~ ([0-9]+)[[:space:]]*(weeks?|w) ]]; then
            weeks=$((10#${BASH_REMATCH[1]}))
        fi
        if [[ "$text" =~ ([0-9]+)[[:space:]]*(days?|d) ]]; then
            days=$((10#${BASH_REMATCH[1]}))
        fi
        if [[ "$text" =~ ([0-9]+)[[:space:]]*(hours?|hrs?|h) ]]; then
            hours=$((10#${BASH_REMATCH[1]}))
        fi
        if [[ "$text" =~ ([0-9]+)[[:space:]]*(minutes?|mins?|m) ]]; then
            minutes=$((10#${BASH_REMATCH[1]}))
        fi
        if [[ "$text" =~ ([0-9]+)[[:space:]]*(seconds?|secs?|s) ]]; then
            seconds=$((10#${BASH_REMATCH[1]}))
        fi

        if (( weeks == 0 && days == 0 && hours == 0 && minutes == 0 && seconds == 0 )); then
            echo "-"
            return 0
        fi
    fi

    days=$((days + weeks * 7))
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

gateway_get_value() {
    local key="${1:-}"
    local default_value="${2:-}"
    local value=""
    [[ -n "$BIN" ]] || return 1
    declare -F conky_gateway_get >/dev/null 2>&1 || return 1
    value=$(conky_gateway_get "$key" "$default_value" 2 "$BIN" 2>/dev/null) || return 1
    value=$(printf '%s' "$value" | tr -d '\r' | head -n1)
    case "$(lower_trim "$value")" in
        security:*|error:*|*signature\ verification\ failed*|*permission\ denied*)
            return 1
            ;;
    esac
    printf '%s\n' "$value"
}

gateway_card_state() {
    local raw=""
    if raw=$(gateway_get_value "data.online_info.vps.card.available" "false"); then
        case "$(lower_trim "$raw")" in
            1|true|yes|on) echo "yes" ;;
            0|false|no|off|"") echo "no" ;;
            *) echo "no" ;;
        esac
    else
        echo "unknown"
    fi
}

find_card_cache() {
    local home_dir="${HOME:-}"
    local search_dirs=()
    local dir=""
    local found=""

    if [[ -n "${KODACHI_HOOKS_DIR:-}" ]]; then
        search_dirs+=("${KODACHI_HOOKS_DIR}/results")
    fi
    if [[ -n "$home_dir" ]]; then
        search_dirs+=(
            "$home_dir/dashboard/hooks/results"
            "$home_dir/Desktop/dashboard/hooks/results"
            "$home_dir/k900/dashboard/hooks/results"
        )
    fi
    search_dirs+=(
        "/opt/kodachi/dashboard/hooks/results"
        "/usr/local/share/kodachi/hooks/results"
    )

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        found=$(ls -t "$dir"/cached_card_*.json 2>/dev/null | head -n1 || true)
        if [[ -n "$found" ]] && [[ -f "$found" ]]; then
            echo "$found"
            return 0
        fi
    done

    return 1
}

CARD_FILE="$(find_card_cache 2>/dev/null || true)"

has_local_card() {
    [[ -n "$CARD_FILE" ]] && [[ -f "$CARD_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e '.card_data.vps_info' "$CARD_FILE" >/dev/null 2>&1
}

cached_vps_country() {
    local cache_home="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}"
    local cloud_cache="${cache_home}/kodachi/cloud-cache.json"
    local country=""

    # ASK THE SOURCE THAT ACTUALLY HAS THE DATA FIRST.
    #
    # THE DEFECT: this function read ONLY ~/.cache/kodachi/cloud-cache.json, and
    # that file DOES NOT EXIST on a live boot. Measured on <lab-host>: the
    # file is absent, so every call fell through to the bare "-" below, and the
    # panel rendered "IPv4: 198.105.112.55" with a floating unlabelled hyphen at
    # the right margin, while every other card field was healthy.
    #
    # The data was there the whole time, one block lower on the same panel.
    # vps-nodes-block.sh reads `data.online_info.vps.nodes` through the conky
    # gateway and happily prints "Netherlands". Measured on the same box, same
    # second, that gateway path returns
    #     {"country":"","vpscountry":"Netherlands","vpsdisplay":"Netherlands",...}
    # for node 0. Note WHICH key: `country` is EMPTY and `vpscountry` is the
    # populated one, so a reader that picks the obvious-looking name gets a blank.
    # The correct path is already written down elsewhere in this very file, in the
    # gateway branch of cached_field_value, and this function simply never used it.
    #
    # Reported by <agent> on the <lab-host> live ISO.
    # FETCH THE NODES ARRAY AND READ FIELD 0, do NOT ask for a dotted index path.
    # Measured on <lab-host>: the gateway's snapshot fast path CANNOT index
    # into an array, so `data.online_info.vps.nodes.0.vpscountry` comes back MISS,
    # while `data.online_info.vps.nodes` returns the whole array and the binary
    # resolves the indexed form perfectly. My first attempt at this fix used the
    # dotted path, still printed "-", and only a re-measure caught it.
    # Reading the array also keeps this on the fast path with no binary spawn,
    # which is exactly what vps-nodes-block.sh already does one block lower.
    if command -v jq >/dev/null 2>&1 && declare -F conky_gateway_get_or_default >/dev/null 2>&1; then
        local nodes_json=""
        nodes_json=$(conky_gateway_get_or_default "data.online_info.vps.nodes" "" 2 "${BIN:-}" 2>/dev/null)
        if [[ -n "$nodes_json" ]]; then
            # `vpscountry`, NOT `country`. Measured on the same box, `country` is
            # the EMPTY string on every node while `vpscountry` carries the name,
            # so the obvious-looking key is the wrong one.
            country=$(printf '%s' "$nodes_json" | jq -r '.[0].vpscountry // empty' 2>/dev/null | head -n1)
            if [[ -n "$country" && "$country" != "null" && "$country" != "-" ]]; then
                echo "$country"
                return 0
            fi
        fi
        country=""
    fi

    command -v jq >/dev/null 2>&1 || {
        echo "-"
        return 0
    }

    # Kept as a fallback rather than deleted: on a machine where the cache file
    # does exist it is a cheaper read than the gateway, and removing a working
    # path to fix a missing one is how the next regression gets written.
    if [[ -f "$cloud_cache" ]]; then
        country=$(jq -r '.infrastructure.vps_nodes[0].country.name // .data.infrastructure.vps_nodes[0].country.name // empty' "$cloud_cache" 2>/dev/null | head -n1)
        if [[ -n "$country" ]]; then
            echo "$country"
            return 0
        fi
    fi

    echo "-"
}

cached_field_value() {
    local f="${1:-}"

    if ! has_local_card; then
        echo "$(default_for_field "$f")"
        return 0
    fi

    case "$f" in
        ipv4)
            jq -r '.card_data.vps_info.network.ipv4 // .card_data.services.dante.ipv4.host // "-"' "$CARD_FILE" 2>/dev/null
            ;;
        ipv6)
            jq -r '.card_data.vps_info.network.ipv6 // .card_data.services.dante.ipv6.host // "-"' "$CARD_FILE" 2>/dev/null
            ;;
        vpscountry)
            cached_vps_country
            ;;
        type)
            jq -r '.card_data.vps_info.card_type // "-"' "$CARD_FILE" 2>/dev/null
            ;;
        hostname)
            local host
            host=$(jq -r '.card_data.vps_info.hostname // "-"' "$CARD_FILE" 2>/dev/null)
            if [[ "${#host}" -gt 18 ]]; then
                echo "${host:0:18}"
            else
                echo "$host"
            fi
            ;;
        load)
            jq -r '
                .card_data.vps_info.cpu_load as $load |
                if $load then
                    (($load."1min" | tonumber) + ($load."5min" | tonumber) + ($load."15min" | tonumber)) / 3 |
                    . * 100 | floor / 100 | tostring
                else "-" end
            ' "$CARD_FILE" 2>/dev/null || echo "-"
            ;;
        memory)
            jq -r '
                .card_data.vps_info.memory as $mem |
                if $mem then "\($mem.used_mb)/\($mem.total_mb)" else "-/-" end
            ' "$CARD_FILE" 2>/dev/null || echo "-/-"
            ;;
        uptime)
            local up
            up=$(jq -r '.card_data.vps_info.uptime // "-"' "$CARD_FILE" 2>/dev/null)
            compact_duration "$up"
            ;;
        services)
            jq -r '.card_data.services | keys | length' "$CARD_FILE" 2>/dev/null || echo "0"
            ;;
        *)
            echo "$(default_for_field "$f")"
            ;;
    esac
}

gateway_field_value() {
    local f="${1:-}"
    case "$f" in
        ipv4) gateway_get_value "data.online_info.vps.card.ipv4" "-" ;;
        ipv6) gateway_get_value "data.online_info.vps.card.ipv6" "-" ;;
        # THIS is the branch that actually fires for vpscountry on a live box, and
        # the dotted INDEX path it used returns MISS: the gateway's snapshot fast
        # reader cannot index into an array, so this fell through to "-" and the
        # panel printed a bare unlabelled hyphen. Traced with bash -x on
        # <lab-host> after two earlier attempts patched cached_vps_country,
        # which this path never reaches. cached_vps_country now holds the working
        # array-based lookup, so both entry points share one implementation.
        vpscountry) cached_vps_country ;;
        type) gateway_get_value "data.online_info.vps.card.type" "-" ;;
        hostname) gateway_get_value "data.online_info.vps.card.hostname" "-" ;;
        load) gateway_get_value "data.online_info.vps.card.load" "-" ;;
        memory)
            local mem=""
            mem=$(gateway_get_value "data.online_info.vps.card.memory.display" "N_A") || return 1
            if [[ "$mem" == "N_A" || -z "$mem" ]]; then
                echo "-/-"
            else
                echo "$mem"
            fi
            ;;
        uptime)
            local up=""
            up=$(gateway_get_value "data.online_info.vps.card.uptime" "-") || return 1
            compact_duration "$up"
            ;;
        services) gateway_get_value "data.online_info.vps.card.services" "0" ;;
        *) return 1 ;;
    esac
}

GW_STATE="$(gateway_card_state)"

case "$FIELD" in
    available)
        case "$GW_STATE" in
            yes) echo "Yes" ;;
            no) echo "No" ;;
            *)
                if has_local_card; then
                    echo "Yes"
                else
                    echo "No"
                fi
                ;;
        esac
        ;;
    *)
        if [[ "$GW_STATE" == "yes" ]]; then
            value="$(gateway_field_value "$FIELD" 2>/dev/null || true)"
            if [[ -n "$value" ]]; then
                echo "$value"
                exit 0
            fi
        fi

        if [[ "$GW_STATE" == "no" ]]; then
            echo "$(default_for_field "$FIELD")"
            exit 0
        fi

        cached_field_value "$FIELD"
        ;;
esac
