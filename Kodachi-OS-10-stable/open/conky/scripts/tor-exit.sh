#!/usr/bin/env bash

# tor-exit.sh
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
FIELD="${1:-ip}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

BIN=$(conky_gateway_find_binary 2>/dev/null || true)
CACHE_DIR="${HOME}/.cache/kodachi"
CACHE_FILE="$CACHE_DIR/tor-exit-cache.json"
CACHE_TTL=30

ensure_cache_dir() {
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
}

cache_is_fresh() {
    [[ -f "$CACHE_FILE" ]] || return 1
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    age=$((now - mtime))
    (( age < CACHE_TTL ))
}

cache_get() {
    local key="$1"
    jq -r --arg key "$key" '.[$key] // empty' "$CACHE_FILE" 2>/dev/null
}

is_unset_value() {
    local value="${1:-}"
    case "$value" in
        ""|"null"|"-"|"N/A") return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_ip_literal() {
    local value="${1:-}"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$value" == *:* ]]
}

lookup_country_with_ip_fetch() {
    local ip="${1:-}"
    local json=""
    local country=""

    is_valid_ip_literal "$ip" || return 1
    command -v ip-fetch >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1

    json=$(timeout 5 ip-fetch "$ip" --json 2>/dev/null || true)
    [[ -n "$json" ]] || return 1

    country=$(jq -r '.data.records[0].country_name // .data.raw[0].country_name // .data.country // empty' <<<"$json" 2>/dev/null || true)
    is_unset_value "$country" && return 1
    printf '%s\n' "$country"
}

fetch_tor_exit() {
    local ip=""
    local country=""
    local fallback_country=""

    # Gateway-only data path.
    if [[ -n "$BIN" ]]; then
        ip=$(conky_gateway_get_or_default "tor-exit.ip" "N/A" 2 "$BIN")
        country=$(conky_gateway_get_or_default "tor-exit.country" "N/A" 2 "$BIN")
    fi

    is_unset_value "$ip" && ip="N/A"
    is_unset_value "$country" && country="N/A"

    # Fallback: if snapshot has Tor IP but missing country, geolocate the IP directly.
    if [[ "$country" == "N/A" && "$ip" != "N/A" ]]; then
        fallback_country="$(lookup_country_with_ip_fetch "$ip" 2>/dev/null || true)"
        if [[ -n "$fallback_country" ]]; then
            country="$fallback_country"
        fi
    fi

    jq -n --arg ip "$ip" --arg country "$country" '{"ip":$ip,"country":$country}'
}

refresh_cache_if_needed() {
    ensure_cache_dir
    if cache_is_fresh; then
        return 0
    fi

    local snapshot tmp_file
    snapshot=$(fetch_tor_exit)
    [[ -n "$snapshot" ]] || return 1

    tmp_file="${CACHE_FILE}.tmp.$$"
    printf '%s\n' "$snapshot" > "$tmp_file" 2>/dev/null || return 1
    mv -f "$tmp_file" "$CACHE_FILE" 2>/dev/null || true
}

refresh_cache_force() {
    ensure_cache_dir

    local snapshot tmp_file
    snapshot=$(fetch_tor_exit)
    [[ -n "$snapshot" ]] || return 1

    tmp_file="${CACHE_FILE}.tmp.$$"
    printf '%s\n' "$snapshot" > "$tmp_file" 2>/dev/null || return 1
    mv -f "$tmp_file" "$CACHE_FILE" 2>/dev/null || true
}

case "$FIELD" in
    ip|country)
        refresh_cache_if_needed
        value=$(cache_get "$FIELD")
        # If cached country is missing, force a live refresh to recover quickly.
        if [[ "$FIELD" == "country" ]] && is_unset_value "$value"; then
            refresh_cache_force
            value=$(cache_get "$FIELD")
        fi
        if [[ -n "$value" ]]; then
            echo "$value"
        elif [[ -n "$BIN" ]]; then
            conky_gateway_get_or_default "tor-exit.$FIELD" "N/A" 2 "$BIN"
        else
            echo "N/A"
        fi
        ;;
    *)
        echo "N/A"
        ;;
esac
