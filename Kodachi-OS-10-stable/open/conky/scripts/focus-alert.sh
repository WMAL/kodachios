#!/usr/bin/env bash

# focus-alert.sh
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
# Description:
# Focused top-center conky alert for high-signal privacy/security changes.
# It stays silent unless tracked backend values change, then shows all fields.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

COMMAND="${1:-render}"
DATA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kodachi/conky/data"
STATE_FILE="$DATA_DIR/.focus-alert-state"
LOCK_FILE="$DATA_DIR/.focus-alert.lock"
POLL_INTERVAL_ACTIVE="${FOCUS_ALERT_POLL_INTERVAL:-10}"
POLL_INTERVAL_IDLE="${FOCUS_ALERT_IDLE_POLL_INTERVAL:-20}"
ALERT_TTL="${FOCUS_ALERT_TTL:-90}"
STARTUP_TTL="${FOCUS_ALERT_STARTUP_TTL:-60}"
GATEWAY_TTL="${FOCUS_ALERT_GATEWAY_TTL:-120}"
REFRESH_COOLDOWN="${FOCUS_ALERT_REFRESH_COOLDOWN:-30}"
REFRESH_TIMEOUT="${FOCUS_ALERT_REFRESH_TIMEOUT:-15}"
# Longer cooldown between refreshes while the last snapshot reports offline: a
# refresh on a dead/blackholed network fans out sudo'd ROOT health-control probes
# that block for minutes and cannot be reaped from this unprivileged process.
# Space those retries far enough apart that at most one probe generation is in
# flight while still detecting recovery on its own (systemd timer also probes).
REFRESH_OFFLINE_COOLDOWN="${FOCUS_ALERT_REFRESH_OFFLINE_COOLDOWN:-300}"
# Keep --max-parallel flat so the refresh fan-out never floods the box with sudo
# children at once, and floor the external timeout ABOVE the gateway's own worst
# internal budget (health/online_info/ip caps floor at ~22-25s under Tor/VPN
# routing). Killing conky-status before it finishes is what orphans its child
# process groups; a generous external floor guarantees it exits on its own.
REFRESH_MAX_PARALLEL="${FOCUS_ALERT_REFRESH_MAX_PARALLEL:-4}"
REFRESH_EXTERNAL_MIN="${FOCUS_ALERT_REFRESH_EXTERNAL_MIN:-45}"
AUTH_CHECK_TIMEOUT="${FOCUS_ALERT_AUTH_CHECK_TIMEOUT:-2}"
ROUTING_CHECK_TIMEOUT="${FOCUS_ALERT_ROUTING_CHECK_TIMEOUT:-4}"
SHOW_ON_START="${FOCUS_ALERT_SHOW_ON_START:-0}"
REFRESH_MARK_FILE="$DATA_DIR/.focus-alert-refresh-ts"
REFRESH_LOCK_FILE="$DATA_DIR/.focus-alert-refresh.lock"
RENDER_CACHE_FILE="$DATA_DIR/.focus-alert-render-cache"
CHANGE_HISTORY_FILE="$DATA_DIR/.focus-alert-change-history"
CHANGE_HISTORY_WINDOW="${FOCUS_ALERT_CHANGE_WINDOW:-300}"
CHANGE_HISTORY_LIMIT="${FOCUS_ALERT_CHANGE_LIMIT:-5}"
NEWS_CACHE_FILE="$DATA_DIR/.focus-alert-news-cache"
NEWS_REFRESH_MARK_FILE="$DATA_DIR/.focus-alert-news-refresh-ts"
NEWS_REFRESH_LOCK="$DATA_DIR/.focus-alert-news-refresh.lock"
NEWS_REFRESH_INTERVAL="${FOCUS_ALERT_NEWS_REFRESH_INTERVAL:-600}"
NEWS_FETCH_TIMEOUT="${FOCUS_ALERT_NEWS_FETCH_TIMEOUT:-15}"
NEWS_FETCH_ITEMS="${FOCUS_ALERT_NEWS_FETCH_ITEMS:-10}"
NEWS_DISPLAY_ITEMS="${FOCUS_ALERT_NEWS_DISPLAY_ITEMS:-${FOCUS_ALERT_NEWS_ITEMS_LIMIT:-3}}"
NEWS_ROTATE_INTERVAL="${FOCUS_ALERT_NEWS_ROTATE_INTERVAL:-180}"

ALWAYS_VISIBLE="${FOCUS_ALERT_ALWAYS_VISIBLE:-1}"

FIELD_KEYS=(
    ip
    country
    hostname
    local_ip
    gateway
    interface
    mac
    vpn
    protocol
    dnscrypt
    firewall
    auth_status
    auth_session
    lknet
    timezone
    binary_cur
    terminal_cur
    desktop_on
    desktop_cur
)

CHANGE_KEYS=(
    ip
    country
    mac
    hostname
    vpn
    protocol
    dnscrypt
    firewall
    auth_status
    timezone
)

mkdir -p "$DATA_DIR"

if ! [[ "$POLL_INTERVAL_ACTIVE" =~ ^[0-9]+$ ]]; then POLL_INTERVAL_ACTIVE=2; fi
if ! [[ "$POLL_INTERVAL_IDLE" =~ ^[0-9]+$ ]]; then POLL_INTERVAL_IDLE=4; fi
if (( POLL_INTERVAL_IDLE < POLL_INTERVAL_ACTIVE )); then POLL_INTERVAL_IDLE="$POLL_INTERVAL_ACTIVE"; fi
if ! [[ "$ALERT_TTL" =~ ^[0-9]+$ ]]; then ALERT_TTL=90; fi
if ! [[ "$STARTUP_TTL" =~ ^[0-9]+$ ]]; then STARTUP_TTL=60; fi
if ! [[ "$GATEWAY_TTL" =~ ^[0-9]+$ ]]; then GATEWAY_TTL=120; fi
if ! [[ "$REFRESH_COOLDOWN" =~ ^[0-9]+$ ]]; then REFRESH_COOLDOWN=30; fi
if ! [[ "$REFRESH_TIMEOUT" =~ ^[0-9]+$ ]]; then REFRESH_TIMEOUT=15; fi
if ! [[ "$AUTH_CHECK_TIMEOUT" =~ ^[0-9]+$ ]]; then AUTH_CHECK_TIMEOUT=2; fi
if ! [[ "$ROUTING_CHECK_TIMEOUT" =~ ^[0-9]+$ ]]; then ROUTING_CHECK_TIMEOUT=4; fi
if ! [[ "$CHANGE_HISTORY_WINDOW" =~ ^[0-9]+$ ]]; then CHANGE_HISTORY_WINDOW=300; fi
if ! [[ "$CHANGE_HISTORY_LIMIT" =~ ^[0-9]+$ ]]; then CHANGE_HISTORY_LIMIT=5; fi
if ! [[ "$NEWS_REFRESH_INTERVAL" =~ ^[0-9]+$ ]]; then NEWS_REFRESH_INTERVAL=600; fi
if ! [[ "$NEWS_FETCH_TIMEOUT" =~ ^[0-9]+$ ]]; then NEWS_FETCH_TIMEOUT=15; fi
if ! [[ "$NEWS_FETCH_ITEMS" =~ ^[0-9]+$ ]]; then NEWS_FETCH_ITEMS=10; fi
if ! [[ "$NEWS_DISPLAY_ITEMS" =~ ^[0-9]+$ ]]; then NEWS_DISPLAY_ITEMS=3; fi
if ! [[ "$NEWS_ROTATE_INTERVAL" =~ ^[0-9]+$ ]]; then NEWS_ROTATE_INTERVAL=180; fi
if ! [[ "$ALWAYS_VISIBLE" =~ ^[01]$ ]]; then ALWAYS_VISIBLE=1; fi
if (( REFRESH_COOLDOWN < 5 )); then REFRESH_COOLDOWN=5; fi
if (( REFRESH_TIMEOUT < 10 )); then REFRESH_TIMEOUT=10; fi
if (( AUTH_CHECK_TIMEOUT < 1 )); then AUTH_CHECK_TIMEOUT=1; fi
if (( ROUTING_CHECK_TIMEOUT < 1 )); then ROUTING_CHECK_TIMEOUT=1; fi
if (( CHANGE_HISTORY_WINDOW < 60 )); then CHANGE_HISTORY_WINDOW=60; fi
if (( CHANGE_HISTORY_LIMIT < 1 )); then CHANGE_HISTORY_LIMIT=1; fi
if (( NEWS_REFRESH_INTERVAL < 60 )); then NEWS_REFRESH_INTERVAL=60; fi
if (( NEWS_FETCH_TIMEOUT < 4 )); then NEWS_FETCH_TIMEOUT=4; fi
if (( NEWS_FETCH_ITEMS < 3 )); then NEWS_FETCH_ITEMS=3; fi
if (( NEWS_FETCH_ITEMS > 25 )); then NEWS_FETCH_ITEMS=25; fi
if (( NEWS_DISPLAY_ITEMS < 1 )); then NEWS_DISPLAY_ITEMS=1; fi
if (( NEWS_DISPLAY_ITEMS > 10 )); then NEWS_DISPLAY_ITEMS=10; fi
if (( NEWS_DISPLAY_ITEMS > NEWS_FETCH_ITEMS )); then NEWS_DISPLAY_ITEMS="$NEWS_FETCH_ITEMS"; fi
if (( NEWS_ROTATE_INTERVAL < 30 )); then NEWS_ROTATE_INTERVAL=30; fi

# F19 (2026-09-30): PURE-BASH CORE OF sanitize_value, WRITTEN INTO A NAMED VARIABLE.
#
# Measured on the live <lab-host> VM <lab-host> with a bpftrace fork tree: this
# script rooted 3,049 of the 7,946 forks the whole conky tree made in 120 s (38%),
# and almost all of them were `$(echo "$v" | sed ...)` and `| tr | sed` inside
# sanitize_value / normalize_compare_value, called ~100 times per poll by
# is_unknown_value and is_real_change. This computes the SAME string with no
# process at all:
#   sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'  collapses every whitespace run to one
#   space and drops the (single, collapsed) leading and trailing space;
#   `echo "$v"` prints NO text when "$v" is a lone option word (-n, -e, -E, -neE),
#   so that input sanitizes to "N/A" exactly as before.
_fa_sanitize_into() {
    local -n _fa_si_out="$1"
    local _fa_si_v="${2:-}" _fa_si_r="" _fa_si_ch _fa_si_gap=0 _fa_si_i
    _fa_si_v="${_fa_si_v//$'\r'/ }"
    _fa_si_v="${_fa_si_v//$'\n'/ }"
    [[ "$_fa_si_v" =~ ^-[neE]+$ ]] && _fa_si_v=""
    if [[ "$_fa_si_v" != *[[:space:]][[:space:]]* && "$_fa_si_v" != [[:space:]]* \
          && "$_fa_si_v" != *[[:space:]] && "$_fa_si_v" != *[$'\t\v\f']* ]]; then
        # Already single-spaced with no edge whitespace: sed would not change it.
        _fa_si_r="$_fa_si_v"
    else
        for ((_fa_si_i = 0; _fa_si_i < ${#_fa_si_v}; _fa_si_i++)); do
            _fa_si_ch="${_fa_si_v:_fa_si_i:1}"
            if [[ "$_fa_si_ch" == [[:space:]] ]]; then
                _fa_si_gap=1
            else
                if (( _fa_si_gap )) && [[ -n "$_fa_si_r" ]]; then
                    _fa_si_r+=" "
                fi
                _fa_si_gap=0
                _fa_si_r+="$_fa_si_ch"
            fi
        done
    fi
    if [[ -z "$_fa_si_r" ]]; then
        _fa_si_out="N/A"
    elif [[ "$_fa_si_r" =~ ^-[neE]+$ ]]; then
        # The old body ended in `echo "$value"`, which prints NOTHING for a lone echo
        # option word, so its caller received an empty string, not "N/A".
        _fa_si_out=""
    else
        _fa_si_out="$_fa_si_r"
    fi
}

# Lowercased compare form. `tr '[:upper:]' '[:lower:]'` works byte by byte and only
# lowers ASCII, so ${v,,} runs under LC_ALL=C here to do exactly that. The sanitized
# value is already single-spaced and trimmed, so the old second sed was a no-op.
_fa_normalize_into() {
    local -n _fa_ni_out="$1"
    local _fa_ni_v
    _fa_sanitize_into _fa_ni_v "${2:-}"
    local LC_ALL=C
    _fa_ni_out="${_fa_ni_v,,}"
}

sanitize_value() {
    local value
    _fa_sanitize_into value "${1:-}"
    printf '%s\n' "$value"
}

normalize_compare_value() {
    local value
    _fa_normalize_into value "${1:-}"
    printf '%s\n' "$value"
}

is_unknown_value() {
    local norm
    _fa_normalize_into norm "${1:-}"
    # Inspector pass 7 (#2): "?" is what conky-status now publishes for a read that did
    # not answer (auth.login, online_info.knet, routing.onoff). Without it here an
    # unanswered KNet check counted as a reading, so On -> ? -> On fired "Security
    # posture changed" twice and recorded "?" as a value.
    case "$norm" in
        ""|n/a|na|n.a|n.a.|unknown|null|nil|-|--|\?)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_real_change() {
    local prev curr prev_norm curr_norm
    _fa_sanitize_into prev "${1:-}"
    _fa_sanitize_into curr "${2:-}"
    _fa_normalize_into prev_norm "$prev"
    _fa_normalize_into curr_norm "$curr"

    # Same normalized value is never a change.
    [[ "$prev_norm" == "$curr_norm" ]] && return 1

    # Unknown placeholders should not generate alerts.
    if is_unknown_value "$prev_norm" || is_unknown_value "$curr_norm"; then
        return 1
    fi

    return 0
}

escape_conky() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\$/\\$}"
    echo "$value"
}

bool_to_onoff() {
    local raw
    raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$raw" in
        1|true|on|yes|y) echo "On" ;;
        *) echo "Off" ;;
    esac
}

normalize_protocol_value() {
    local raw
    raw="$(sanitize_value "${1:-None}")"
    case "$(echo "$raw" | tr '[:upper:]' '[:lower:]')" in
        openvpn) echo "OpenVPN" ;;
        wireguard|wg) echo "WireGuard" ;;
        amneziawg|awg) echo "AmneziaWG" ;;
        shadowsocks|ss) echo "Shadowsocks" ;;
        tailscale) echo "Tailscale" ;;
        v2ray) echo "V2Ray" ;;
        xray) echo "Xray" ;;
        sing-box|singbox) echo "sing-box" ;;
        none|null|n/a|na|off|false|0|"") echo "None" ;;
        *) echo "$raw" ;;
    esac
}

format_status_value() {
    local raw="${1:-}"
    local value esc lower
    value="$(sanitize_value "$raw")"
    esc="$(escape_conky "$value")"
    lower="$(echo "$value" | tr '[:upper:]' '[:lower:]' | xargs)"

    case "$lower" in
        off|offline)
            echo "\${color6}${esc}\${color3}"
            ;;
        on|online)
            echo "\${color1}${esc}\${color3}"
            ;;
        *)
            echo "\${color1}${esc}\${color3}"
            ;;
    esac
}

compose_nightly_version() {
    local base nb
    base="$(sanitize_value "${1:-}")"
    nb="$(sanitize_value "${2:-}")"
    if [[ "$base" == "N/A" || "$nb" == "N/A" ]]; then
        echo "N/A"
    else
        echo "${base}.${nb}"
    fi
}

declare -A values
CHANGED_STYLE="\${font DejaVu Sans Mono:size=11}\${color6}.\${font Liberation Sans Narrow:size=10}\${color3}"
STABLE_STYLE="\${font DejaVu Sans Mono:size=9}\${color1}.\${font Liberation Sans Narrow:size=10}\${color3}"
owner_changed=0

state_reset() {
    last_poll=0
    snapshot_mtime=0
    visible_until=0
    session_id=""
    owner_session=""
    changed_fields=""
    headline="Critical status changed"
    owner_changed=0
    for key in "${FIELD_KEYS[@]}"; do
        values["$key"]="N/A"
    done
}

state_load() {
    state_reset
    [[ -f "$STATE_FILE" ]] || return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *"="* ]] || continue
        local key="${line%%=*}"
        local val="${line#*=}"

        case "$key" in
            last_poll) last_poll="${val:-0}" ;;
            snapshot_mtime) snapshot_mtime="${val:-0}" ;;
            visible_until) visible_until="${val:-0}" ;;
            session_id) session_id="$val" ;;
            owner_session) owner_session="$val" ;;
            changed_fields) changed_fields="$val" ;;
            headline) headline="$val" ;;
            value_*)
                local field="${key#value_}"
                values["$field"]="$val"
                ;;
        esac
    done < "$STATE_FILE"
}

state_save() {
    local tmp_file
    tmp_file="$(mktemp "$DATA_DIR/.focus-alert-state.XXXXXX")"
    {
        echo "last_poll=$last_poll"
        echo "snapshot_mtime=$snapshot_mtime"
        echo "visible_until=$visible_until"
        echo "session_id=$session_id"
        echo "owner_session=$owner_session"
        echo "changed_fields=$changed_fields"
        echo "headline=$headline"
        local key
        for key in "${FIELD_KEYS[@]}"; do
            echo "value_${key}=${values[$key]}"
        done
    } > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

contains_field() {
    local needle="$1"
    [[ ",$changed_fields," == *",$needle,"* ]]
}

line_marker() {
    local key="$1"
    if contains_field "$key"; then
        echo "[!]"
    else
        echo "[ ]"
    fi
}

line_marker_any() {
    local key
    for key in "$@"; do
        if contains_field "$key"; then
            echo "[!]"
            return
        fi
    done
    echo "[ ]"
}

status_glyph() {
    local key="$1"
    if contains_field "$key"; then
        echo "${CHANGED_STYLE}"
    else
        echo "${STABLE_STYLE}"
    fi
}

status_glyph_any() {
    local key
    for key in "$@"; do
        if contains_field "$key"; then
            echo "${CHANGED_STYLE}"
            return
        fi
    done
    echo "${STABLE_STYLE}"
}

item_is_changed() {
    local item="$1"
    case "$item" in
        identity) contains_field ip || contains_field country ;;
        host) contains_field hostname ;;
        local) contains_field local_ip || contains_field gateway ;;
        mac) contains_field mac || contains_field interface ;;
        vpn) contains_field vpn || contains_field protocol ;;
        dnscrypt) contains_field dnscrypt ;;
        firewall) contains_field firewall ;;
        auth) contains_field auth_status || contains_field auth_session ;;
        lknet) contains_field lknet ;;
        timezone) contains_field timezone ;;
        versions) contains_field binary_cur || contains_field terminal_cur || contains_field desktop_on || contains_field desktop_cur ;;
        watch) return 1 ;;
        *) return 1 ;;
    esac
}

truncate_value() {
    local value="${1:-}"
    local max_len="${2:-20}"

    if ! [[ "$max_len" =~ ^[0-9]+$ ]]; then
        max_len=20
    fi
    if (( max_len < 1 )); then
        echo ""
        return
    fi

    if (( ${#value} > max_len )); then
        echo "${value:0:max_len-1}~"
    else
        echo "$value"
    fi
}

build_headline() {
    if contains_field ip || contains_field country || contains_field local_ip || contains_field gateway || contains_field interface; then
        echo "Network identity changed"
    elif contains_field hostname; then
        echo "Host identity changed"
    elif contains_field mac; then
        echo "MAC identity changed"
    elif contains_field vpn || contains_field protocol; then
        echo "VPN route status changed"
    elif contains_field dnscrypt; then
        echo "Anonymity stack changed"
    elif contains_field firewall || contains_field auth_status || contains_field auth_session || contains_field lknet; then
        echo "Security posture changed"
    elif contains_field timezone; then
        echo "System timezone changed"
    elif contains_field binary_cur || contains_field terminal_cur || contains_field desktop_on || contains_field desktop_cur; then
        echo "Desktop version feed changed"
    else
        echo "Critical status changed"
    fi
}

change_key_label() {
    local key="${1:-}"
    case "$key" in
        ip) echo "External IP" ;;
        country) echo "Country" ;;
        mac) echo "MAC" ;;
        hostname) echo "Hostname" ;;
        vpn) echo "VPN" ;;
        protocol) echo "Protocol" ;;
        dnscrypt) echo "DNSCrypt" ;;
        firewall) echo "Firewall" ;;
        auth_status) echo "Auth" ;;
        timezone) echo "Timezone" ;;
        *) echo "$key" ;;
    esac
}

sanitize_history_value() {
    local value
    value="$(sanitize_value "${1:-}")"
    value="${value//|//}"
    echo "$value"
}

prune_change_history() {
    local now="${1:-0}"
    local tmp_file

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    [[ -f "$CHANGE_HISTORY_FILE" ]] || return 0
    # F19: an EMPTY history prunes to an empty history, so the mktemp + awk + mv
    # this function ran on every 10 s render changed nothing but the inode.
    [[ -s "$CHANGE_HISTORY_FILE" ]] || return 0

    tmp_file="$(mktemp "$DATA_DIR/.focus-alert-history.XXXXXX")"
    awk -F'|' -v now="$now" -v window="$CHANGE_HISTORY_WINDOW" -v limit="$CHANGE_HISTORY_LIMIT" '
        BEGIN { count=0 }
        $1 ~ /^[0-9]+$/ {
            age = now - $1
            if (age >= 0 && age <= window) {
                count++
                if (count <= limit) {
                    print $0
                }
            }
        }
    ' "$CHANGE_HISTORY_FILE" > "$tmp_file"
    mv "$tmp_file" "$CHANGE_HISTORY_FILE"
}

record_change_event() {
    local now="${1:-0}"
    local key="${2:-unknown}"
    local value="${3:-N/A}"
    local tmp_file entry

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    key="${key//|//}"
    value="$(sanitize_history_value "$value")"
    entry="${now}|${key}|${value}"

    tmp_file="$(mktemp "$DATA_DIR/.focus-alert-history.XXXXXX")"
    {
        echo "$entry"
        [[ -f "$CHANGE_HISTORY_FILE" ]] && cat "$CHANGE_HISTORY_FILE"
    } > "$tmp_file"
    mv "$tmp_file" "$CHANGE_HISTORY_FILE"
    prune_change_history "$now"
}

record_change_batch() {
    local now="$1"
    shift || true
    local key
    for key in "$@"; do
        [[ -n "$key" ]] || continue
        record_change_event "$now" "$key" "${values[$key]:-N/A}"
    done
}

build_recent_change_lines() {
    local now="${1:-0}"
    local count=0

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    prune_change_history "$now"

    if [[ ! -s "$CHANGE_HISTORY_FILE" ]]; then
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color3}No items changed in last 5 minutes"
        return 0
    fi

    while IFS='|' read -r ts key value; do
        local stamp label esc_stamp esc_label esc_value
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        stamp="$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
        label="$(change_key_label "$key")"
        esc_stamp="$(escape_conky "$stamp")"
        esc_label="$(escape_conky "$(truncate_value "$label" 14)")"
        esc_value="$(escape_conky "$(truncate_value "${value:-N/A}" 22)")"
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color2}${esc_stamp}\${goto 255}\${color7}${esc_label}\${goto 430}\${color1}${esc_value}"
        count=$((count + 1))
        if (( count >= CHANGE_HISTORY_LIMIT )); then
            break
        fi
    done < "$CHANGE_HISTORY_FILE"

    if (( count == 0 )); then
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color3}No items changed in last 5 minutes"
    fi
}

read_snapshot_values() {
    local snapshot_file="$1"
    local _fa_rsv_clean
    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi
    [[ -s "$snapshot_file" ]] || return 1

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        _fa_sanitize_into _fa_rsv_clean "$value"
        values["$key"]="$_fa_rsv_clean"
    done < <(
        jq -r '
            def safe(v; d):
                if v == null then d
                elif (v|type == "string") and (v|length == 0) then d
                else (v|tostring)
                end;
            def nightly(base; nb):
                (safe(base; "")) as $b
                | (safe(nb; "")) as $n
                | if $b != "" and $b != "N/A" and $n != "" and $n != "N/A" then ($b + "." + $n) else "" end;
            [
                # Inspector pass 8 (#8): the ip adapter publishes "Offline" when the
                # fetch failed. That is an unread address, not a new one, so it reads as
                # Unknown; recorded as a value, 1.2.3.4 -> Offline -> 1.2.3.4 fired two
                # IP-change alerts.
                "ip=" + (safe((.data.ip.effective.ip // .data.ip.public); "N/A") | if . == "Offline" then "Unknown" else . end),
                "country=" + safe((.data.ip.effective.country // .data.ip.country); "N/A"),
                "hostname=" + safe(.data.system.os.hostname; "N/A"),
                "local_ip=" + safe(.data.system.network.local_ip; "N/A"),
                "gateway=" + safe(.data.system.network.gateway; "N/A"),
                "interface=" + safe(.data.system.network.interface; "N/A"),
                "mac=" + safe(.data.system.network.mac; "N/A"),
                # Inspector pass 7 (#6): a missing key is a reading that did not happen,
                # so it defaults to Unknown (ignored as a change), never Off/None.
                "vpn=" + safe(.data.routing.onoff; "Unknown"),
                "protocol=" + safe(.data.routing.protocol; "Unknown"),
                "dnscrypt=" + safe(.data.dns.dnscrypt_onoff; "Unknown"),
                "firewall=" + (
                    if .data.system.runtime.firewall.onoff != null
                    then safe(.data.system.runtime.firewall.onoff; "Off")
                    # `firewall_known` is consulted because health.rs keeps
                    # `firewall: false` on a failed read and carries the provenance in
                    # the companion instead; without this the overlay asserted
                    # "firewall Off" off a reading that never happened.
                    elif (.data.health.firewall_known != true)
                    then "Unknown"
                    else (if .data.health.firewall == true then "On" else "Off" end)
                    end
                ),
                "auth_status=" + safe(.data.auth.login; "?"),
                "auth_session=" + safe(.data.auth.session_id; "N/A"),
                "lknet=" + safe(.data.online_info.knet; "?"),
                "timezone=" + safe(.data.system.os.timezone; "N/A"),
                "binary_cur=" + (
                    [
                        .data.online_info.releases.binary_pack.nightly_version,
                        nightly(.data.versions.binary.on; .data.versions.binary.nb),
                        .data.versions.binary.on
                    ]
                    | map(safe(.; ""))
                    | map(select(. != "" and . != "N/A" and . != "."))
                    | .[0] // "N/A"
                ),
                "terminal_cur=" + (
                    [
                        .data.online_info.releases.terminal.nightly_version,
                        nightly(.data.versions.terminal.on; .data.versions.terminal.nb),
                        .data.versions.terminal.on
                    ]
                    | map(safe(.; ""))
                    | map(select(. != "" and . != "N/A" and . != "."))
                    | .[0] // "N/A"
                ),
                "desktop_on=" + (
                    [ .data.online_info.releases.desktop.nightly_version, .data.versions.desktop.on, .data.versions.binary.on ]
                    | map(safe(.; ""))
                    | map(select(. != "" and . != "N/A"))
                    | .[0] // "N/A"
                ),
                "desktop_cur=" + (
                    [
                        .data.online_info.releases.desktop.nightly_version,
                        nightly(.data.versions.desktop.on; .data.versions.desktop.nb),
                        .data.versions.desktop.on
                    ]
                    | map(safe(.; ""))
                    | map(select(. != "" and . != "N/A" and . != "."))
                    | .[0] // "N/A"
                )
            ] | .[]
        ' "$snapshot_file" 2>/dev/null
    )
}

# F19: `ps -o ppid=` / `ps -o comm=` piped through `tr` cost four processes per
# ancestor, and this walk runs twice per render. /proc/<pid>/stat field 4 IS the ppid
# `ps -o ppid=` prints, and /proc/<pid>/comm IS what `ps -o comm=` prints, so these
# builtin reads return the same answer with no fork. A pid that has exited yields an
# empty answer here exactly as `ps` printed nothing for it.
_fa_proc_ppid_into() {
    local -n _fa_pp_out="$1"
    local _fa_pp_stat="" _fa_pp_rest
    local -a _fa_pp_f=()
    _fa_pp_out=""
    IFS= read -r _fa_pp_stat < "/proc/$2/stat" 2>/dev/null || return 0
    _fa_pp_rest="${_fa_pp_stat##*) }"
    read -r -a _fa_pp_f <<< "$_fa_pp_rest"
    _fa_pp_out="${_fa_pp_f[1]:-}"
}

_fa_proc_comm_into() {
    local -n _fa_pc_out="$1"
    local _fa_pc_comm=""
    IFS= read -r _fa_pc_comm < "/proc/$2/comm" 2>/dev/null || true
    _fa_pc_out="${_fa_pc_comm// /}"
}

detect_conky_session_id() {
    local pid ppid cmd depth
    pid="$$"

    # Walk a few ancestors and return a stable Conky PID when found.
    for depth in 1 2 3 4 5 6; do
        ppid=""
        [[ "$pid" =~ ^[0-9]+$ ]] && _fa_proc_ppid_into ppid "$pid"
        if [[ -z "$ppid" || "$ppid" == "0" ]]; then
            break
        fi
        _fa_proc_comm_into cmd "$ppid"
        if [[ "$cmd" == "conky" ]]; then
            echo "$ppid"
            return 0
        fi
        pid="$ppid"
    done

    echo "unknown"
}

conky_pid_alive() {
    local pid="${1:-}" comm=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    IFS= read -r comm < "/proc/$pid/comm" 2>/dev/null || return 1
    [[ "${comm// /}" == "conky" ]]
}

focus_owner_check() {
    local current_session="${1:-unknown}"
    owner_changed=0

    # If we cannot detect a conky PID, do not block rendering.
    if [[ "$current_session" == "unknown" ]]; then
        return 0
    fi

    if [[ -z "${owner_session:-}" ]]; then
        owner_session="$current_session"
        owner_changed=1
        return 0
    fi

    if [[ "$owner_session" == "$current_session" ]]; then
        return 0
    fi

    # Another focus panel already owns rendering and is still alive.
    if conky_pid_alive "$owner_session"; then
        return 1
    fi

    # Previous owner is gone; claim ownership.
    owner_session="$current_session"
    owner_changed=1
    return 0
}

snapshot_is_fresh() {
    local snapshot_file="$1"
    local max_age="$2"
    local now_ts file_ts age

    [[ -s "$snapshot_file" ]] || return 1
    [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=0

    now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    age=$((now_ts - file_ts))
    (( age < 0 )) && age=0

    (( age <= max_age ))
}

snapshot_mtime_value() {
    local snapshot_file="$1"
    stat -c %Y "$snapshot_file" 2>/dev/null || echo 0
}

overlay_hostname_from_user_key() {
    local bin="$1"
    local host_from_user_key
    host_from_user_key="$(sanitize_value "$(CONKY_GATEWAY_TTL=2 conky_gateway_get_or_default "user.hostname_short" "N/A" 1 "$bin")")"
    if [[ "$host_from_user_key" != "N/A" ]]; then
        values[hostname]="$host_from_user_key"
    fi
}

overlay_timezone_from_system_key() {
    local bin="$1"
    local timezone_from_user

    # Prefer user command path (fast local timedatectl via conky-status user registry).
    timezone_from_user="$(sanitize_value "$(CONKY_GATEWAY_TTL=2 conky_gateway_get_or_default "user.timezone_name" "N/A" 1 "$bin")")"
    if ! is_unknown_value "$timezone_from_user"; then
        values[timezone]="$timezone_from_user"
        return 0
    fi
}

overlay_auth_status_from_online_auth() {
    local auth_bin=""
    local auth_json auth_onoff

    command -v jq >/dev/null 2>&1 || return 0

    if command -v online-auth >/dev/null 2>&1; then
        auth_bin="$(command -v online-auth 2>/dev/null || true)"
    elif [[ -x "$HOME/k900/dashboard/hooks/online-auth" ]]; then
        auth_bin="$HOME/k900/dashboard/hooks/online-auth"
    elif [[ -x "/opt/kodachi/dashboard/hooks/online-auth" ]]; then
        auth_bin="/opt/kodachi/dashboard/hooks/online-auth"
    fi

    [[ -n "$auth_bin" ]] || return 0

    # AUDIT 2026-05-27: gate on kodachi-auth-ready marker so we don't spam
    # online-auth during the boot PoW window (5+ consumers fan-in caused
    # the ~22 invalid-session log lines per boot). If the marker is not
    # present yet, return early, the next refresh tick will retry, and
    # by then the auth flow will have completed.
    if [[ ! -f "/run/user/$(id -u)/kodachi-auth-ready" ]] \
       && [[ ! -f "/run/kodachi-auth-ready" ]]; then
        return 0
    fi

    auth_json="$(timeout "$AUTH_CHECK_TIMEOUT" "$auth_bin" check-login --json 2>/dev/null || true)"
    [[ -n "$auth_json" ]] || return 0

    auth_onoff="$(jq -r '
        if (.data.is_logged_in == true) or (.is_logged_in == true) then "On"
        elif ((.status // "") | ascii_downcase) == "success" then "On"
        else "Off"
        end
    ' <<< "$auth_json" 2>/dev/null || true)"

    case "$auth_onoff" in
        On|Off) values[auth_status]="$auth_onoff" ;;
    esac
}

overlay_routing_from_switch() {
    # Read routing status from the conky-status gateway cache.
    # The gateway's routing adapter already calls routing-switch with proper
    # permissions; no sudo is needed from the Conky session.
    local bin onoff protocol

    bin="$(conky_gateway_find_binary 2>/dev/null || true)"
    [[ -n "$bin" ]] || return 0

    # Inspector pass 7 (#6): a missing key defaults to Unknown, which the branch below
    # already renders as Unknown, never as "VPN Off / protocol None".
    onoff="$(conky_gateway_get_or_default "data.routing.onoff" "Unknown" 2 "$bin")"
    onoff="$(echo "$onoff" | tr '[:upper:]' '[:lower:]' | xargs)"

    # THIS OVERLAY OVERWRITES the value read further up, so a hardcoded "Off" here
    # wins over anything better. conky-status publishes "?" for `routing.onoff` when
    # `routing-switch status` did not answer, and a null `connected` reaches this
    # script as its own default, so the old form asserted "VPN Off / protocol None"
    # about a machine it had not measured. Same defect class as the dashboard Tor row
    # reported flapping on 2026-09-28. `connected_known` is the provenance
    # companion published by conky-status adapters/routing.rs.
    # Round 3d cross-review (A2): a MISSING `connected_known` is unknown provenance, so it
    # defaults to "false"; the producer always publishes it, so only an older binary (or a
    # partial snapshot) reaches this default, and an "Off" it carries is not a measured Off.
    local connected_known
    connected_known="$(conky_gateway_get_or_default "data.routing.connected_known" "false" 2 "$bin")"
    # Only a literal true is known (conky_known_is_true in conky-gateway-common.sh).
    local connected_measured=0
    conky_known_is_true "$connected_known" && connected_measured=1
    if [[ "$onoff" == "on" ]]; then
        protocol="$(conky_gateway_get_or_default "data.routing.protocol" "None" 2 "$bin")"
        values[vpn]="On"
        values[protocol]="$(normalize_protocol_value "$protocol")"
    elif [[ "$onoff" == "?" || "$onoff" == "unknown" || "$onoff" == "null" || "$onoff" == "" \
            || "$connected_measured" -eq 0 ]]; then
        values[vpn]="Unknown"
        values[protocol]="Unknown"
    else
        values[vpn]="Off"
        values[protocol]="None"
    fi
}

snapshot_age_seconds() {
    local snapshot_file="$1"
    local now_ts file_ts age

    [[ -s "$snapshot_file" ]] || {
        echo 999999
        return 0
    }

    now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    age=$((now_ts - file_ts))
    (( age < 0 )) && age=0
    echo "$age"
}

# Returns 0 (true) when the most recent snapshot already knows the box is
# offline. Used to back off refreshes: probing the network when it is down only
# spawns root health-control fan-out that blocks for minutes. Unknown/missing
# status is treated as NOT offline so a cold snapshot still gets one refresh.
snapshot_reports_offline() {
    local snapshot_file="$1"
    [[ -s "$snapshot_file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local online
    # NOTE: do NOT use jq's `//` alternative here: it treats boolean `false` as
    # empty and would swallow exactly the value we are looking for. Read raw and
    # compare; a missing key yields "null" and is correctly treated as unknown.
    online="$(jq -r '.data.health.internet.online' "$snapshot_file" 2>/dev/null || true)"
    [[ "$online" == "false" ]]
}

trigger_gateway_refresh_async() {
    local bin="$1"
    local snapshot_file="$2"
    local age now_ts last_ts cooldown ext

    age="$(snapshot_age_seconds "$snapshot_file")"
    [[ "$age" =~ ^[0-9]+$ ]] || age=$((GATEWAY_TTL + 1))
    # Round 3b (inspector B, V8): a snapshot written at or before the last Kodachi state
    # change is due NOW whatever its age (conky-gateway-common.sh _conky_snapshot_times),
    # and the cooldown below does not hold it back unless the last refresh attempt was
    # itself started after the change. Every panel reads it as a miss meanwhile.
    local pre_change=0 stamp_ts=0
    if _conky_snapshot_times "$snapshot_file" && (( _CONKY_SNAP_TS <= _CONKY_STAMP_TS )); then
        pre_change=1
        stamp_ts="$_CONKY_STAMP_TS"
    fi
    if (( age <= GATEWAY_TTL && pre_change == 0 )); then
        return 0
    fi

    # Back off hard while offline: a refresh cannot succeed with no route/DNS and
    # each attempt leaks unkillable root probes. Still retry occasionally so a
    # recovered network is picked up without waiting on the systemd timer.
    cooldown="$REFRESH_COOLDOWN"
    if snapshot_reports_offline "$snapshot_file"; then
        cooldown="$REFRESH_OFFLINE_COOLDOWN"
    fi

    now_ts=$(date +%s 2>/dev/null || echo 0)
    last_ts=$(cat "$REFRESH_MARK_FILE" 2>/dev/null || echo 0)
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

    # Only a real, past stamp lifts the cooldown: an untrusted stamp reads as "changed now
    # and later" and would otherwise start a refresh on every poll.
    if (( now_ts - last_ts < cooldown )) && ! (( pre_change == 1 && last_ts <= stamp_ts && stamp_ts <= now_ts )); then
        return 0
    fi

    echo "$now_ts" > "$REFRESH_MARK_FILE" 2>/dev/null || true

    # Keep the external timeout strictly above the gateway's internal budget so
    # it never has to kill conky-status mid-refresh (which would orphan the child
    # process groups it spawned). REFRESH_EXTERNAL_MIN clears the ~22-25s adapter
    # floors with headroom.
    ext="$REFRESH_TIMEOUT"
    (( ext < REFRESH_EXTERNAL_MIN )) && ext="$REFRESH_EXTERNAL_MIN"

    (
        # Single-flight: if a refresh is already running, skip rather than stack
        # another one on top (the root cause of the observed pile-up).
        exec 9>"$REFRESH_LOCK_FILE" 2>/dev/null || exit 0
        flock -n 9 || exit 0
        timeout -k 5 "$ext" "$bin" snapshot --refresh \
            --max-parallel "$REFRESH_MAX_PARALLEL" \
            --ttl "$GATEWAY_TTL" >/dev/null 2>&1 || true
    ) &
}

overlay_fast_local_fields() {
    local _bin="$1"
    # Stay snapshot-driven here; direct binary calls were duplicating expensive
    # work already handled by conky-status and spiking live-session CPU.
    return 0
}

fetch_values() {
    local bin="$1"
    local snapshot_file current_mtime
    snapshot_file="$(conky_gateway_snapshot_path)"
    current_mtime="$(snapshot_mtime_value "$snapshot_file")"

    trigger_gateway_refresh_async "$bin" "$snapshot_file"

    # Consume shared gateway snapshot only (non-blocking path).
    if [[ -s "$snapshot_file" ]]; then
        if [[ "${snapshot_mtime:-0}" != "$current_mtime" ]] || (( last_poll == 0 )); then
            if read_snapshot_values "$snapshot_file"; then
                snapshot_mtime="$current_mtime"
            fi
        fi
    fi

    overlay_fast_local_fields "$bin"
}

build_progress_bar() {
    local percentage="${1:-0}"
    local width=38
    local filled=0
    local bar=""
    local i

    if ! [[ "$percentage" =~ ^[0-9]+$ ]]; then
        percentage=0
    fi
    (( percentage < 0 )) && percentage=0
    (( percentage > 100 )) && percentage=100

    filled=$((percentage * width / 100))
    for ((i = 0; i < width; i++)); do
        if (( i < filled )); then
            bar+="#"
        else
            bar+="-"
        fi
    done
    echo "$bar"
}

merge_changed_fields() {
    local incoming_csv="$1"
    local entry key
    local -a merged=()
    local -a existing_parts=() incoming_parts=()
    local -A seen=()

    if [[ -n "${changed_fields:-}" ]]; then
        IFS=',' read -r -a existing_parts <<< "$changed_fields"
    fi
    if [[ -n "$incoming_csv" ]]; then
        IFS=',' read -r -a incoming_parts <<< "$incoming_csv"
    fi

    for entry in "${existing_parts[@]}"; do
        [[ -n "$entry" ]] && seen["$entry"]=1
    done
    for entry in "${incoming_parts[@]}"; do
        [[ -n "$entry" ]] && seen["$entry"]=1
    done

    # Keep a stable field order for consistent rendering.
    for key in "${CHANGE_KEYS[@]}"; do
        if [[ -n "${seen[$key]:-}" ]]; then
            merged+=("$key")
        fi
    done

    (IFS=,; echo "${merged[*]}")
}

filter_changed_fields_csv() {
    local incoming_csv="${1:-}"
    local key out=()
    local csv=",$incoming_csv,"

    [[ -n "$incoming_csv" ]] || {
        echo ""
        return 0
    }

    for key in "${CHANGE_KEYS[@]}"; do
        if [[ "$csv" == *",$key,"* ]]; then
            out+=("$key")
        fi
    done
    (IFS=,; echo "${out[*]}")
}

poll_if_needed() {
    local now="$1"
    local current_session startup_due=0 poll_interval was_visible=0 new_changed_csv
    if (( now < visible_until )); then
        was_visible=1
    fi
    if (( now < visible_until )); then
        poll_interval="$POLL_INTERVAL_ACTIVE"
    else
        poll_interval="$POLL_INTERVAL_IDLE"
    fi

    if (( now - last_poll < poll_interval )) && (( last_poll > 0 )); then
        return 1
    fi

    local bin
    bin="$(conky_gateway_find_binary 2>/dev/null || true)"
    [[ -n "$bin" ]] || return 1

    local key
    declare -A previous=()
    for key in "${FIELD_KEYS[@]}"; do
        previous["$key"]="${values[$key]}"
    done

    fetch_values "$bin"

    # Ignore temporary unknown fetches and keep last known value.
    for key in "${FIELD_KEYS[@]}"; do
        if is_unknown_value "${values[$key]}" && ! is_unknown_value "${previous[$key]}"; then
            values["$key"]="${previous[$key]}"
        fi
    done

    current_session="$(detect_conky_session_id)"
    if [[ "$SHOW_ON_START" == "1" ]]; then
        if [[ -z "${session_id:-}" ]]; then
            startup_due=1
        elif [[ "$current_session" != "unknown" && "$session_id" != "$current_session" ]]; then
            startup_due=1
        fi
    fi

    local changed=()
    for key in "${CHANGE_KEYS[@]}"; do
        if is_real_change "${previous[$key]}" "${values[$key]}"; then
            if (( last_poll > 0 )) || [[ "$SHOW_ON_START" == "1" ]]; then
                changed+=("$key")
            fi
        fi
    done

    if (( ${#changed[@]} > 0 )); then
        record_change_batch "$now" "${changed[@]}"
        new_changed_csv="$(IFS=,; echo "${changed[*]}")"
        if (( was_visible == 1 )) && [[ -n "${changed_fields:-}" ]]; then
            changed_fields="$(merge_changed_fields "$new_changed_csv")"
        else
            changed_fields="$new_changed_csv"
        fi
        headline="$(build_headline)"
        if (( was_visible == 0 )); then
            visible_until=$((now + ALERT_TTL))
        fi
    fi

    if (( startup_due == 1 )); then
        changed_fields=""
        headline=""
        visible_until=$((now + STARTUP_TTL))
    fi

    if [[ "$current_session" != "unknown" ]]; then
        session_id="$current_session"
    elif [[ -z "${session_id:-}" ]]; then
        session_id="unknown"
    fi
    last_poll="$now"
    return 0
}

compute_refresh_countdown() {
    local now="$1"
    local interval elapsed remaining

    if (( now < visible_until )); then
        interval="$POLL_INTERVAL_ACTIVE"
    else
        interval="$POLL_INTERVAL_IDLE"
    fi

    if (( last_poll <= 0 )); then
        echo "${interval}:${interval}"
        return 0
    fi

    elapsed=$((now - last_poll))
    (( elapsed < 0 )) && elapsed=0
    remaining=$((interval - elapsed))
    (( remaining < 0 )) && remaining=0

    echo "${remaining}:${interval}"
}

build_dot_line() {
    local width="${1:-120}"
    local i out=""

    if ! [[ "$width" =~ ^[0-9]+$ ]]; then
        width=150
    fi
    (( width < 20 )) && width=20

    for ((i = 0; i < width; i++)); do
        if (( i % 3 == 0 )); then
            out+="·"
        else
            out+=" "
        fi
    done
    echo "$out"
}

news_refresh_due() {
    local now="${1:-0}"
    local last_ts=0

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    if [[ ! -f "$NEWS_REFRESH_MARK_FILE" ]]; then
        return 0
    fi

    last_ts="$(cat "$NEWS_REFRESH_MARK_FILE" 2>/dev/null || echo 0)"
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
    (( now - last_ts >= NEWS_REFRESH_INTERVAL ))
}

news_mark_refresh() {
    local now="${1:-0}"
    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    printf '%s\n' "$now" > "$NEWS_REFRESH_MARK_FILE" 2>/dev/null || true
}

extract_news_headlines_from_json() {
    local json_file="$1"
    command -v jq >/dev/null 2>&1 || return 1
    [[ -s "$json_file" ]] || return 1

    jq -r '
        def title_of:
            if type == "string" then .
            elif type == "object" then (.title // .headline // .name // .summary // .description // empty)
            else empty
            end;
        [
            (.data.rss.items[]? | title_of),
            (.data.rss[]? | title_of),
            (.rss.items[]? | title_of),
            (.rss[]? | title_of),
            (.data.items[]? | title_of),
            (.items[]? | title_of),
            (.data.news.items[]? | title_of),
            (.data.news[]? | title_of),
            (.news.items[]? | title_of),
            (.news[]? | title_of),
            (.data.online_info.rss.items[]? | title_of),
            (.data.online_info.rss[]? | title_of),
            (.data.online_info.news.items[]? | title_of),
            (.data.online_info.news[]? | title_of)
        ]
        | map(select(type == "string"))
        | map(gsub("[\\r\\n\\t]+"; " "))
        | map(gsub("^\\s+|\\s+$"; ""))
        | map(select(length > 0))
        | .[]
    ' "$json_file" 2>/dev/null || true
}

refresh_news_cache() {
    local bin="${1:-}"
    local now="${2:-0}"
    local tmp_json tmp_out headlines

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    tmp_json="$(mktemp "$DATA_DIR/.focus-alert-news-json.XXXXXX")"
    tmp_out="$(mktemp "$DATA_DIR/.focus-alert-news.XXXXXX")"

    if command -v online-info-switch >/dev/null 2>&1; then
        timeout "$NEWS_FETCH_TIMEOUT" online-info-switch rss --random --json > "$tmp_json" 2>/dev/null || true
    fi

    headlines="$(extract_news_headlines_from_json "$tmp_json" || true)"
    if [[ -n "$headlines" ]]; then
        printf '%s\n' "$headlines" | awk -v limit="$NEWS_FETCH_ITEMS" 'NF && !seen[$0]++ { print; c++; if (c >= limit) exit }' > "$tmp_out"
        if [[ -s "$tmp_out" ]]; then
            mv "$tmp_out" "$NEWS_CACHE_FILE"
        fi
    fi

    rm -f "$tmp_json" "$tmp_out"
    news_mark_refresh "$now"
}

trigger_news_refresh_async() {
    local bin="${1:-}"
    local now="${2:-0}"

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
    if ! news_refresh_due "$now"; then
        return 0
    fi

    news_mark_refresh "$now"
    (
        if command -v flock >/dev/null 2>&1; then
            exec 8>"$NEWS_REFRESH_LOCK"
            flock -n 8 || exit 0
        fi
        refresh_news_cache "$bin" "$now"
    ) >/dev/null 2>&1 &
}

build_news_lines() {
    local now="${1:-0}"
    local line esc_line
    local -a cached_items=()
    local total=0
    local display_count=0
    local start_index=0
    local slot=0
    local i idx line_no=1

    [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"

    if [[ ! -s "$NEWS_CACHE_FILE" ]]; then
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color3}RSS news unavailable"
        return 0
    fi

    while IFS= read -r line; do
        _fa_sanitize_into line "$line"
        [[ -n "$line" && "$line" != "N/A" ]] || continue
        cached_items+=("$line")
    done < "$NEWS_CACHE_FILE"

    total="${#cached_items[@]}"
    if (( total == 0 )); then
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color3}RSS news unavailable"
        return 0
    fi

    display_count="$NEWS_DISPLAY_ITEMS"
    if (( display_count > total )); then
        display_count="$total"
    fi

    if (( total > display_count )); then
        slot=$((now / NEWS_ROTATE_INTERVAL))
        start_index=$((slot % total))
    fi

    for ((i = 0; i < display_count; i++)); do
        idx=$(((start_index + i) % total))
        esc_line="$(escape_conky "$(truncate_value "${cached_items[$idx]}" 90)")"
        printf '%s\n' "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color7}${line_no}. ${esc_line}"
        line_no=$((line_no + 1))
    done
}

render() {
    local now dot_line
    local news_refresh_minutes=0
    local news_rotate_minutes=0
    local cache_tmp
    local current_session bin
    local -a changed_lines=() news_lines=() output_lines=()
    # F19: builtin clock, same epoch seconds as `date +%s` without a process.
    printf -v now '%(%s)T' -1 2>/dev/null || now="$(date +%s)"

    state_load
    changed_fields="$(filter_changed_fields_csv "${changed_fields:-}")"
    current_session="$(detect_conky_session_id)"
    if ! focus_owner_check "$current_session"; then
        if [[ -s "$RENDER_CACHE_FILE" ]]; then
            cat "$RENDER_CACHE_FILE"
        fi
        exit 0
    fi

    if poll_if_needed "$now" || (( owner_changed == 1 )); then
        state_save
    fi

    if (( now > visible_until )) && [[ "$ALWAYS_VISIBLE" != "1" ]]; then
        rm -f "$RENDER_CACHE_FILE"
        exit 0
    fi

    if [[ "$ALWAYS_VISIBLE" == "1" ]] && (( now > visible_until )); then
        changed_fields=""
        headline=""
    fi

    bin="$(conky_gateway_find_binary 2>/dev/null || true)"
    trigger_news_refresh_async "$bin" "$now"
    dot_line="$(build_dot_line 120)"
    mapfile -t news_lines < <(build_news_lines "$now")
    mapfile -t changed_lines < <(build_recent_change_lines "$now")
    news_refresh_minutes=$((NEWS_REFRESH_INTERVAL / 60))
    (( news_refresh_minutes < 1 )) && news_refresh_minutes=1
    news_rotate_minutes=$((NEWS_ROTATE_INTERVAL / 60))
    (( news_rotate_minutes < 1 )) && news_rotate_minutes=1

    output_lines+=(
        "\${voffset 6}\${goto 20}\${font DejaVu Sans Mono:size=11}\${color7}[KD]\${goto 62}\${font Impact:size=18}\${color7}KODACHI \${color1}SIGNAL \${color2}GLASS \${color6}HUD"
        "\${goto 20}\${font Liberation Sans Narrow:size=11:bold}\${color2}ACTIVE ROUTE: \${color1}\${execi 17 ~/.config/kodachi/conky/scripts/route-mode.sh mode}"
        "\${goto 20}\${font Liberation Sans Narrow:size=10:bold}\${color3}NET \${color1}\${execi 31 ~/.config/kodachi/conky/scripts/internet-status.sh}  \${color3}AUTH \${color1}\${execi 37 ~/.config/kodachi/conky/scripts/auth-status.sh}  \${color3}TOR \${color1}\${execi 31 ~/.config/kodachi/conky/scripts/tor-status.sh tor}  \${color3}DNSCRYPT \${color1}\${execi 31 ~/.config/kodachi/conky/scripts/tor-status.sh dnscrypt}"
        "\${goto 20}\${font Liberation Sans Narrow:size=10}\${color3}IP \${color1}\${execi 17 ~/.config/kodachi/conky/scripts/ip-cache.sh ip}  \${color3}PING \${color1}\${execi 31 ~/.config/kodachi/conky/scripts/random-ping.sh}ms  \${color3}SCORE \${color1}\${execi 120 ~/.config/kodachi/conky/scripts/security-metrics.sh score}/100"
        "\${goto 20}\${font Liberation Sans Narrow:size=11}\${color3}ONLINE NEWS RSS (rotate ${news_rotate_minutes}m, refresh ${news_refresh_minutes}m)"
        "\${goto 20} "
    )

    for line in "${news_lines[@]}"; do
        output_lines+=("$line")
    done

    output_lines+=(
        "\${goto 20} "
    )

    output_lines+=(
        "\${voffset 2}\${goto 20}\${font DejaVu Sans Mono:size=8}\${color5}${dot_line}"
        "\${goto 20}\${font Liberation Sans Narrow:size=11:bold}\${color6}LAST 5 CHANGES (5 MIN WINDOW)"
        "\${goto 20}\${font Liberation Sans Narrow:size=10:bold}\${color2}Timestamp\${goto 255}\${color7}Item\${goto 430}\${color1}Value"
    )

    for line in "${changed_lines[@]}"; do
        output_lines+=("$line")
    done

    output_lines+=(
        "\${voffset 1}\${goto 20}\${font DejaVu Sans Mono:size=8}\${color5}${dot_line}"
    )

    cache_tmp="$(mktemp "$DATA_DIR/.focus-alert-render.XXXXXX")"
    printf '%s\n' "${output_lines[@]}" > "$cache_tmp"
    mv "$cache_tmp" "$RENDER_CACHE_FILE" 2>/dev/null || true
    printf '%s\n' "${output_lines[@]}"
}

with_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            if [[ "$COMMAND" == "render" ]]; then
                if [[ -s "$RENDER_CACHE_FILE" ]]; then
                    cat "$RENDER_CACHE_FILE"
                else
                    printf '%s\n' '${goto 20}${font Liberation Sans Narrow:size=10}${color3}Monitor loading...'
                fi
            fi
            exit 0
        fi
    fi
}

with_lock

case "$COMMAND" in
    render) render ;;
    status) state_load; printf 'visible_until=%s changed_fields=%s headline=%s\n' "$visible_until" "$changed_fields" "$headline" ;;
    reset)
        rm -f "$STATE_FILE" "$RENDER_CACHE_FILE" "$CHANGE_HISTORY_FILE" "$NEWS_CACHE_FILE" "$NEWS_REFRESH_MARK_FILE" "$NEWS_REFRESH_LOCK"
        ;;
    *)
        render
        ;;
esac
