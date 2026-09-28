#!/usr/bin/env bash

# Kodachi Conky Launcher - Panel Management Script
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
# Last updated: 2026-02-05
#
# Description:
# Launches all Kodachi conky panels with proper initialization.
# NO external data aggregator needed - panels fetch data directly.
#
# Links:
# - Website: https://www.digi77.com
# - Website: https://www.kodachi.cloud
# - GitHub: https://github.com/WMAL
# - Discord: https://discord.gg/KEFErEx
# - LinkedIn: https://om.linkedin.com/in/warith1977
# - X (Twitter): https://x.com/warith2020
#
# Usage:
#   conky-launcher.sh          # Launch all conky panels
#   conky-launcher.sh --stop   # Stop all conky panels
#
# Features:
#   - Dynamic path detection (no hardcoded paths)
#   - Launches gauges, security, and system panels
#   - Supports Cairo Lua gauges
#   - Automatic panel positioning
#
# IMPORTANT: Uses ONLY dynamic path detection.
# NO hardcoded paths or usernames.

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CONKY_WATCHDOG_SERVICE="conky-watchdog.service"

# ===== DYNAMIC PATH DETECTION =====
# Detect current user dynamically - NEVER hardcode
get_current_user() {
    if [[ -n "${USER:-}" ]]; then
        echo "$USER"
    elif [[ -n "${LOGNAME:-}" ]]; then
        echo "$LOGNAME"
    elif command -v whoami &>/dev/null; then
        whoami
    elif command -v id &>/dev/null; then
        id -un
    else
        getent passwd "$(id -u)" | cut -d: -f1
    fi
}

# Detect home directory dynamically
get_home_dir() {
    if [[ -n "${HOME:-}" ]]; then
        echo "$HOME"
    else
        local user
        user="$(get_current_user)"
        getent passwd "$user" | cut -d: -f6
    fi
}

# Find conky configuration directory
get_conky_dir() {
    local home_dir
    home_dir="$(get_home_dir)"

    # Search in common locations (priority order)
    local search_paths=(
        "${XDG_CONFIG_HOME:-$home_dir/.config}/kodachi/conky"
        "$home_dir/.config/kodachi/conky"
        "$home_dir/.kodachi/conky"
        "/etc/kodachi/conky"
        "/opt/kodachi/conky"
        # Also check k900 livebuild-assets for development
        "$home_dir/k900/livebuild-assets/conky"
    )

    for path in "${search_paths[@]}"; do
        if [[ -d "$path/configs" ]]; then
            echo "$path"
            return 0
        fi
    done

    # Default to XDG config location
    echo "${XDG_CONFIG_HOME:-$home_dir/.config}/kodachi/conky"
}

# ===== LOGGING =====
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $*" >&2
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ===== LAYOUT AUTO-SPACING =====
parse_xrandr_geometry() {
    local geometry="$1"

    if [[ "$geometry" =~ ^([0-9]+)/[0-9]+x([0-9]+)/[0-9]+\+(-?[0-9]+)\+(-?[0-9]+)$ ]]; then
        echo "${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

get_root_geometry() {
    local width="" height=""

    if command -v xrandr &>/dev/null; then
        read -r width height < <(
            xrandr --current 2>/dev/null \
                | awk '/\*/ { split($1, size, "x"); print size[1], size[2]; exit }'
        )
    fi

    if [[ -z "$width" || -z "$height" ]] && command -v xdpyinfo &>/dev/null; then
        read -r width height < <(
            xdpyinfo 2>/dev/null \
                | awk '/dimensions:/ { split($2, size, "x"); print size[1], size[2]; exit }'
        )
    fi

    [[ "$width" =~ ^[0-9]+$ ]] || width=1920
    [[ "$height" =~ ^[0-9]+$ ]] || height=1080

    echo "0 0 ${width} ${height}"
}

get_target_monitor_geometry() {
    local first_candidate=""

    if command -v xrandr &>/dev/null; then
        while read -r idx flags geom name _; do
            local parsed candidate

            [[ -n "$idx" && -n "$geom" ]] || continue
            idx="${idx%:}"

            parsed="$(parse_xrandr_geometry "$geom" || true)"
            [[ -n "$parsed" ]] || continue

            candidate="${idx} ${parsed} ${name:-monitor-${idx}}"
            [[ -n "$first_candidate" ]] || first_candidate="$candidate"

            if [[ "$flags" == *"*"* ]]; then
                echo "$candidate"
                return 0
            fi
        done < <(xrandr --listactivemonitors 2>/dev/null | tail -n +2)
    fi

    if [[ -n "$first_candidate" ]]; then
        echo "$first_candidate"
        return 0
    fi

    echo "0 $(get_root_geometry) root"
}

get_workarea_geometry() {
    if command -v xprop &>/dev/null; then
        local workarea parsed
        workarea=$(xprop -root _NET_WORKAREA 2>/dev/null | sed -n 's/.*= //p' | head -n1 || true)

        if [[ -n "$workarea" ]]; then
            parsed=$(echo "$workarea" | awk -F',' 'NF >= 4 { gsub(/ /, ""); printf "%s %s %s %s\n", $1, $2, $3, $4; exit }')
            if [[ -n "$parsed" ]]; then
                echo "$parsed"
                return 0
            fi
        fi
    fi

    get_root_geometry
}

get_monitor_workarea() {
    local mon_x="$1"
    local mon_y="$2"
    local mon_w="$3"
    local mon_h="$4"
    local work_x work_y work_w work_h

    read -r work_x work_y work_w work_h < <(get_workarea_geometry)

    local mon_right=$((mon_x + mon_w))
    local mon_bottom=$((mon_y + mon_h))
    local work_right=$((work_x + work_w))
    local work_bottom=$((work_y + work_h))
    local left=$((mon_x > work_x ? mon_x : work_x))
    local top=$((mon_y > work_y ? mon_y : work_y))
    local right=$((mon_right < work_right ? mon_right : work_right))
    local bottom=$((mon_bottom < work_bottom ? mon_bottom : work_bottom))

    if (( right <= left || bottom <= top )); then
        echo "${mon_x} ${mon_y} ${mon_w} ${mon_h}"
        return 0
    fi

    echo "${left} ${top} $((right - left)) $((bottom - top))"
}

clamp_number() {
    local value="$1"
    local min_value="$2"
    local max_value="$3"

    (( value < min_value )) && value=$min_value
    (( value > max_value )) && value=$max_value
    echo "$value"
}

get_config_numeric_value() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null || true
}

get_config_minimum_size() {
    local file="$1"

    awk '$1 == "minimum_size" { print $2, $3; exit }' "$file" 2>/dev/null || true
}

get_config_panel_width() {
    local file="$1"
    local fallback="$2"
    local max_width min_width min_height

    max_width="$(get_config_numeric_value "$file" maximum_width)"
    read -r min_width min_height < <(get_config_minimum_size "$file")

    if [[ "$max_width" =~ ^[0-9]+$ ]]; then
        echo "$max_width"
    elif [[ "$min_width" =~ ^[0-9]+$ ]]; then
        echo "$min_width"
    else
        echo "$fallback"
    fi
}

get_config_panel_height() {
    local file="$1"
    local fallback="$2"
    local min_width min_height

    read -r min_width min_height < <(get_config_minimum_size "$file")

    if [[ "$min_height" =~ ^[0-9]+$ ]]; then
        echo "$min_height"
    else
        echo "$fallback"
    fi
}

set_or_insert_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local anchor="${4:-alignment}"

    [[ -f "$file" ]] || return 0

    if grep -Eq "^${key}[[:space:]]+" "$file"; then
        sed -i -E "s#^${key}[[:space:]].*#${key} ${value}#" "$file"
    elif grep -Eq "^${anchor}[[:space:]]+" "$file"; then
        sed -i -E "/^${anchor}[[:space:]]+.*/a ${key} ${value}" "$file"
    else
        printf '\n%s %s\n' "$key" "$value" >>"$file"
    fi
}

remove_config_value() {
    local file="$1"
    local key="$2"

    [[ -f "$file" ]] || return 0
    sed -i -E "/^${key}[[:space:]]+/d" "$file"
}

set_config_gap_x() {
    set_or_insert_config_value "$1" gap_x "$2" alignment
}

set_config_gap_y() {
    set_or_insert_config_value "$1" gap_y "$2" gap_x
}

set_config_minimum_size() {
    local file="$1"
    local width="$2"
    local height="$3"

    [[ -f "$file" ]] || return 0

    if grep -Eq '^minimum_size[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$file"; then
        sed -i -E "s/^minimum_size[[:space:]]+[0-9]+[[:space:]]+[0-9]+/minimum_size ${width} ${height}/" "$file"
    elif grep -Eq '^gap_y[[:space:]]+' "$file"; then
        sed -i -E "/^gap_y[[:space:]]+.*/a minimum_size ${width} ${height}" "$file"
    else
        printf '\nminimum_size %s %s\n' "$width" "$height" >>"$file"
    fi
}

CONKY_SUPPORTS_XINERAMA_CACHE=""
conky_supports_xinerama() {
    if [[ -n "$CONKY_SUPPORTS_XINERAMA_CACHE" ]]; then
        [[ "$CONKY_SUPPORTS_XINERAMA_CACHE" == "yes" ]]
        return $?
    fi

    if command -v conky &>/dev/null && conky -v 2>/dev/null | grep -qi 'xinerama'; then
        CONKY_SUPPORTS_XINERAMA_CACHE="yes"
        return 0
    fi

    CONKY_SUPPORTS_XINERAMA_CACHE="no"
    return 1
}

get_runtime_root() {
    echo "${XDG_RUNTIME_DIR:-/tmp}/kodachi-conky-runtime"
}

get_runtime_config_dir() {
    echo "$(get_runtime_root)/configs"
}

apply_auto_layout() {
    local configs_dir="$1"
    [[ -d "$configs_dir" ]] || return 0

    local system_conf="$configs_dir/conkyrc-system.conf"
    local security_conf="$configs_dir/conkyrc-security.conf"
    local resources_conf="$configs_dir/conkyrc-resources.conf"
    local gauges_conf="$configs_dir/conkyrc-gauges.conf"
    local focus_conf="$configs_dir/conkyrc-focus-alert.conf"

    local root_x root_y root_w root_h
    read -r root_x root_y root_w root_h < <(get_root_geometry)

    local monitor_index mon_x mon_y mon_w mon_h monitor_name
    read -r monitor_index mon_x mon_y mon_w mon_h monitor_name < <(get_target_monitor_geometry)

    [[ "$monitor_index" =~ ^-?[0-9]+$ ]] || monitor_index=0
    [[ "$mon_x" =~ ^-?[0-9]+$ ]] || mon_x=0
    [[ "$mon_y" =~ ^-?[0-9]+$ ]] || mon_y=0
    [[ "$mon_w" =~ ^[0-9]+$ ]] || mon_w=$root_w
    [[ "$mon_h" =~ ^[0-9]+$ ]] || mon_h=$root_h

    local work_x work_y work_w work_h
    read -r work_x work_y work_w work_h < <(get_monitor_workarea "$mon_x" "$mon_y" "$mon_w" "$mon_h")

    [[ "$work_x" =~ ^-?[0-9]+$ ]] || work_x=$mon_x
    [[ "$work_y" =~ ^-?[0-9]+$ ]] || work_y=$mon_y
    [[ "$work_w" =~ ^[0-9]+$ ]] || work_w=$mon_w
    [[ "$work_h" =~ ^[0-9]+$ ]] || work_h=$mon_h

    local left_strut=$((work_x - mon_x))
    local top_strut=$((work_y - mon_y))
    local right_strut=$(((mon_x + mon_w) - (work_x + work_w)))
    local outer_padding
    outer_padding="$(clamp_number $((work_w / 90)) 12 48)"

    local system_width security_width resources_width gauges_width gauges_height focus_height
    system_width="$(get_config_panel_width "$system_conf" 260)"
    security_width="$(get_config_panel_width "$security_conf" 280)"
    resources_width="$(get_config_panel_width "$resources_conf" 285)"
    gauges_width="$(get_config_panel_width "$gauges_conf" 195)"
    gauges_height="$(get_config_panel_height "$gauges_conf" 310)"
    focus_height="$(get_config_panel_height "$focus_conf" 270)"

    local widest_left_column="$resources_width"
    if (( gauges_width > widest_left_column )); then
        widest_left_column=$gauges_width
    fi

    local available_inner=$((work_w - (2 * outer_padding)))
    if (( available_inner < widest_left_column )); then
        available_inner=$widest_left_column
    fi

    local panel_width_total=$((system_width + security_width + widest_left_column))
    local column_spacing
    column_spacing=$(((available_inner - panel_width_total) / 2))
    # 2026-05-25 user feedback: previous (18, 35) gap was too wide between the
    # 3 right-side columns (resources / security / system). Tightened to (4, 12)
    # so the columns sit visually grouped instead of feeling like 3 separated
    # widgets. Lower floor 4 still keeps text in adjacent columns from
    # touching.
    column_spacing="$(clamp_number "$column_spacing" 4 12)"

    local gauges_offset
    gauges_offset=$(((resources_width - gauges_width) / 2))
    gauges_offset="$(clamp_number "$gauges_offset" 0 60)"

    local top_padding stack_spacing focus_top_padding
    top_padding="$(clamp_number $((work_h / 60)) 18 30)"
    stack_spacing="$(clamp_number $((work_h / 72)) 12 28)"
    focus_top_padding="$(clamp_number $((top_padding / 2)) 8 18)"

    local system_gap_local=$((right_strut + outer_padding))
    local security_gap_local=$((system_gap_local + system_width + column_spacing))
    local resources_gap_local=$((security_gap_local + security_width + column_spacing))
    local gauges_gap_local=$((resources_gap_local + gauges_offset))

    local columns_gap_y_local=$((top_strut + top_padding))
    local resources_gap_y_local=$((columns_gap_y_local + gauges_height + stack_spacing))
    local focus_gap_y_local=$((top_strut + focus_top_padding))

    local leftmost_edge=$((mon_w - resources_gap_local - resources_width))
    local gauges_left_edge=$((mon_w - gauges_gap_local - gauges_width))
    if (( gauges_left_edge < leftmost_edge )); then
        leftmost_edge=$gauges_left_edge
    fi

    local min_left=$((left_strut + outer_padding))
    if (( leftmost_edge < min_left )); then
        local shift=$((min_left - leftmost_edge))
        local min_gap=$((right_strut + 8))

        system_gap_local=$((system_gap_local - shift))
        security_gap_local=$((security_gap_local - shift))
        resources_gap_local=$((resources_gap_local - shift))
        gauges_gap_local=$((gauges_gap_local - shift))

        (( system_gap_local < min_gap )) && system_gap_local=$min_gap
        (( security_gap_local < min_gap )) && security_gap_local=$min_gap
        (( resources_gap_local < min_gap )) && resources_gap_local=$min_gap
        (( gauges_gap_local < min_gap )) && gauges_gap_local=$min_gap
    fi

    # focus-alert geometry, adaptive width that NEVER intersects the gauges
    # column. The gauges panel is right-anchored (`alignment top_right` with
    # gap_x measured from the right edge), so its left edge slides leftward
    # as monitor width shrinks. A fixed 720-px focus-alert at left-anchored
    # gap_x=612 works on 2560-wide displays (clean 370-px gap to gauges) but
    # would punch into the gauges column on 1920 (gauges left edge ≈ 1062)
    # and especially 1366 (gauges left edge ≈ 508). Inspector audit 2026-05-24
    # GREEN LIGHT with this exact caveat, addressed below.
    #
    # Content profile: longest news headline ~74 chars at Liberation Sans
    # Narrow size=10 ≈ 410 px, dotted separator 148 chars at DejaVu Sans
    # Mono size=8 ≈ 680 px, LAST 5 CHANGES value column at goto-430 + ~100 px
    # value text ≈ 530 px. Target 720 px when there is room; floor at 380 px
    # (still legible, keeps news headlines + sudoers timestamps readable).
    #
    # Position profile: prefer (work_w / 5 - 170) left margin, on 2560
    # that lands at 342 px (~3.8 icon widths from the screen edge). The
    # 2026-05-25 user feedback was that the previous +100 offset placed
    # the panel too far right and crowded the Athena wallpaper; the
    # current -170 offset gives back roughly 3 icon-widths of space while
    # still keeping desktop-icon column 1 visible. On a narrow screen
    # where that margin + floor width would not fit before the gauges,
    # the margin gets squeezed down to outer_padding so the panel still
    # fits with a legible width (icons end up obscured but gauges stay
    # visible, the inverse trade-off is worse because gauges are the
    # primary live signal).
    local focus_padding focus_width
    focus_padding="$(clamp_number $((work_w / 64)) 20 64)"
    focus_width=$((work_w - (2 * focus_padding)))
    if (( focus_width > 560 )); then
        focus_width=560
    fi

    local use_xinerama=false
    if conky_supports_xinerama; then
        use_xinerama=true
    fi

    local monitor_right_offset=$((root_w - (mon_x + mon_w)))
    local focus_left_margin
    focus_left_margin="$(clamp_number $(((work_w / 5) - 170)) 80 600)"

    # Recompute gauges_left_edge using FINAL gauges_gap_local (the shift
    # logic above may have adjusted gauges_gap_local on overflow screens).
    local gauges_left_edge_final=$((mon_w - gauges_gap_local - gauges_width))
    local focus_breathing=40
    local focus_right_max=$((gauges_left_edge_final - focus_breathing))
    local min_focus_width=380

    # If preferred margin + floor width does not fit before gauges, squeeze
    # the left margin first. outer_padding (12 to 48 px) keeps the panel off
    # the strut edge but lets us reclaim hundreds of pixels of width.
    if (( focus_left_margin + min_focus_width > focus_right_max )); then
        focus_left_margin=$outer_padding
    fi

    # Final width cap by available pre-gauges space, then floor for legibility.
    local focus_width_avail=$((focus_right_max - focus_left_margin))
    if (( focus_width > focus_width_avail )); then
        focus_width=$focus_width_avail
    fi
    if (( focus_width < min_focus_width )); then
        focus_width=$min_focus_width
    fi

    local focus_gap_x=$focus_left_margin
    local system_gap security_gap resources_gap gauges_gap
    local columns_gap_y resources_gap_y focus_gap_y

    if [[ "$use_xinerama" == "true" ]]; then
        system_gap=$system_gap_local
        security_gap=$security_gap_local
        resources_gap=$resources_gap_local
        gauges_gap=$gauges_gap_local
        columns_gap_y=$columns_gap_y_local
        resources_gap_y=$resources_gap_y_local
        focus_gap_y=$focus_gap_y_local
        focus_gap_x=$focus_left_margin
    else
        system_gap=$((monitor_right_offset + system_gap_local))
        security_gap=$((monitor_right_offset + security_gap_local))
        resources_gap=$((monitor_right_offset + resources_gap_local))
        gauges_gap=$((monitor_right_offset + gauges_gap_local))
        columns_gap_y=$((mon_y + columns_gap_y_local))
        resources_gap_y=$((mon_y + resources_gap_y_local))
        focus_gap_y=$((mon_y + focus_gap_y_local))
        # alignment top_left: gap_x is relative to root window left edge.
        # On multi-monitor non-xinerama, push to the target monitor + margin.
        focus_gap_x=$((mon_x + focus_left_margin))
    fi

    local conky_files=(
        "$system_conf"
        "$security_conf"
        "$resources_conf"
        "$gauges_conf"
        "$focus_conf"
    )
    local file
    for file in "${conky_files[@]}"; do
        if [[ "$use_xinerama" == "true" ]]; then
            set_or_insert_config_value "$file" xinerama_head "$monitor_index" alignment
        else
            remove_config_value "$file" xinerama_head
        fi
    done

    set_config_gap_x "$system_conf" "$system_gap"
    set_config_gap_x "$security_conf" "$security_gap"
    set_config_gap_x "$resources_conf" "$resources_gap"
    set_config_gap_x "$gauges_conf" "$gauges_gap"
    set_config_gap_x "$focus_conf" "$focus_gap_x"

    set_config_gap_y "$system_conf" "$columns_gap_y"
    set_config_gap_y "$security_conf" "$columns_gap_y"
    set_config_gap_y "$gauges_conf" "$columns_gap_y"
    set_config_gap_y "$resources_conf" "$resources_gap_y"
    set_config_gap_y "$focus_conf" "$focus_gap_y"

    set_config_minimum_size "$focus_conf" "$focus_width" "$focus_height"
    set_or_insert_config_value "$focus_conf" maximum_width "$focus_width" minimum_size

    # Bug #17 fix (2026-05-25, third revision per user feedback that the
    # work_h-clamped height was STILL the wrong knob): the actual problem
    # was that security + system shipped with a static minimum_size HEIGHT
    # of 1100 which made conky paint a 1100 px tall window even when the
    # CONTENT (PRIVACY STATUS through WEBSITES sections) only needed
    # ~700 px. That left a big blank "ghost" of conky window covering the
    # wallpaper below the visible content. Setting height to 0 tells conky
    # "no floor, render exactly the content height". Content naturally
    # stays within work_h on any reasonable screen.
    set_config_minimum_size "$system_conf"    "$system_width"    "0"
    set_config_minimum_size "$security_conf"  "$security_width"  "0"
    set_config_minimum_size "$resources_conf" "$resources_width" "0"

    log_info "Auto layout applied on ${monitor_name}: monitor=${mon_w}x${mon_h}+${mon_x}+${mon_y} workarea=${work_w}x${work_h}+${work_x}+${work_y} xinerama=${use_xinerama} gaps(system=${system_gap}, security=${security_gap}, resources=${resources_gap}, gauges=${gauges_gap}, focus_x=${focus_gap_x}) heights(content-driven)"
}

# ===== SYSTEMD (USER) HELPERS =====
run_systemctl_user_quiet() {
    if ! command -v systemctl &>/dev/null; then
        return 1
    fi
    systemctl --user "$@" >/dev/null 2>&1
}

stop_watchdog_service() {
    log_info "Stopping user service: $CONKY_WATCHDOG_SERVICE"
    if run_systemctl_user_quiet stop "$CONKY_WATCHDOG_SERVICE"; then
        log_info "Stopped service: $CONKY_WATCHDOG_SERVICE"
    else
        log_warn "Could not stop $CONKY_WATCHDOG_SERVICE (continuing)"
    fi
}

start_watchdog_service() {
    log_info "Starting user service: $CONKY_WATCHDOG_SERVICE"
    if run_systemctl_user_quiet start "$CONKY_WATCHDOG_SERVICE"; then
        log_info "Started service: $CONKY_WATCHDOG_SERVICE"
    else
        log_warn "Could not start $CONKY_WATCHDOG_SERVICE (continuing)"
    fi
}

# ===== LOW-CPU THROTTLE =====
# Single-core hosts (2-core machines are fine) saturate the conky DATA pipeline,
# not the renderer: `snapshot --refresh` forks 30+ sudo children (find/getcap/
# debsums/FIM hash/health-control) every 90 s, and the 5 panels each fire ~100
# synchronous execp commands per cycle. On one core that pegs ~85% sys time and
# starves Xorg/conky repaint, so the desktop "renders in a bad way" (load 50+,
# idle ~0%). One ISO boots on both tiny and large machines, so the throttle is
# detected at RUNTIME rather than baked into the shipped configs. When nproc<=1:
#   1. double each runtime panel's update_interval (slower execp cadence), and
#   2. install systemd-user drop-ins that stretch the snapshot-refresh timer
#      90 s -> 300 s and cap the refresh service at CPUQuota=60%.
# On nproc>=2 any drop-ins left from a previous single-core run are removed so
# re-imaging onto a bigger box reverts cleanly. Only RUNTIME config copies are
# edited; the shipped source configs stay intact.
CONKY_SNAPSHOT_REFRESH_UNIT="conky-snapshot-refresh"

apply_lowcpu_throttle() {
    local runtime_configs_dir="$1"
    local cores
    cores=$(nproc 2>/dev/null || echo 2)
    [[ "$cores" =~ ^[0-9]+$ ]] || cores=2

    local user_systemd_dir timer_dropin_dir service_dropin_dir
    user_systemd_dir="$(get_home_dir)/.config/systemd/user"
    timer_dropin_dir="$user_systemd_dir/${CONKY_SNAPSHOT_REFRESH_UNIT}.timer.d"
    service_dropin_dir="$user_systemd_dir/${CONKY_SNAPSHOT_REFRESH_UNIT}.service.d"

    if (( cores > 1 )); then
        # Healthy core count: drop any throttle left over from a 1-core boot.
        if [[ -f "$timer_dropin_dir/lowcpu.conf" || -f "$service_dropin_dir/lowcpu.conf" ]]; then
            log_info "nproc=$cores (>1): removing stale low-CPU conky throttle drop-ins"
            rm -f "$timer_dropin_dir/lowcpu.conf" "$service_dropin_dir/lowcpu.conf" 2>/dev/null || true
            rmdir "$timer_dropin_dir" "$service_dropin_dir" 2>/dev/null || true
            run_systemctl_user_quiet daemon-reload || true
        fi
        return 0
    fi

    log_warn "nproc=$cores: applying low-CPU conky throttle (update_interval x2 + snapshot timer 300s + CPUQuota 60%)"

    # 1. Double update_interval in each runtime panel config (runtime copies only).
    local file current doubled
    shopt -s nullglob
    for file in "$runtime_configs_dir"/*.conf; do
        current=$(grep -oE '^[[:space:]]*update_interval[[:space:]]+[0-9]+' "$file" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ "$current" =~ ^[0-9]+$ ]] || continue
        doubled=$(( current * 2 ))
        sed -i -E "s/^([[:space:]]*update_interval[[:space:]]+)[0-9]+/\1${doubled}/" "$file" 2>/dev/null || true
    done
    shopt -u nullglob

    # 2. systemd-user drop-ins for the snapshot-refresh timer + service.
    if command -v systemctl &>/dev/null; then
        mkdir -p "$timer_dropin_dir" "$service_dropin_dir" 2>/dev/null || true
        cat > "$timer_dropin_dir/lowcpu.conf" <<'LOWCPU_TIMER'
# Auto-generated by conky-launcher.sh on single-core hosts (nproc<=1).
# Stretches the snapshot-refresh cadence 90s -> 300s so the sudo fork storm
# runs ~3.3x less often. Removed automatically on the next multi-core boot.
[Timer]
OnUnitActiveSec=300
LOWCPU_TIMER
        cat > "$service_dropin_dir/lowcpu.conf" <<'LOWCPU_SERVICE'
# Auto-generated by conky-launcher.sh on single-core hosts (nproc<=1). Caps the
# snapshot refresh (find/getcap/health-control fork storm) at 60% of one core
# so it can never fully starve Xorg/conky repaint. Removed on multi-core boots.
[Service]
CPUQuota=60%
LOWCPU_SERVICE
        run_systemctl_user_quiet daemon-reload || true
    fi
}

# ===== DEPENDENCY CHECKS =====
check_dependencies() {
    local missing=()

    if ! command -v conky &>/dev/null; then
        missing+=("conky")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install: sudo apt install ${missing[*]}"
        return 1
    fi

    return 0
}

# ===== PROCESS MANAGEMENT =====
cleanup_runtime_artifacts() {
    local conky_dir="$1"
    local data_dir="$conky_dir/data"
    local snapshot_file="$data_dir/conky-status.json"
    local lock_file="$data_dir/.conky-status.lock"
    local runtime_root
    local snapshot_max_age="${CONKY_SNAPSHOT_MAX_AGE_SEC:-900}"

    [[ -d "$data_dir" ]] || return 0
    runtime_root="$(get_runtime_root)"

    # Remove stale lock backups and orphaned temp files from previous sessions.
    # Pattern coverage:
    #   .conky-status.lock.bak.*, old lock backups
    #   .user-commands.tmp-*, interrupted user-commands writes (>10 min stale)
    #   .conky-status.tmp-*, interrupted snapshot writes (atomic-rename
    #                               temps; the conky-status binary writes
    #                               .conky-status.tmp-<PID> then renames into
    #                               place, so a SIGKILL'd or timed-out write
    #                               leaves the .tmp orphan behind. Production
    #                               machines have been observed accumulating
    #                               50+ of these zero-byte files indefinitely.)
    #   .focus-alert-state.*, analogous temps from the focus-alert script.
    #   .focus-alert-news-json.*  - interrupted news fetch JSON writes.
    #   .focus-alert-news.*       - interrupted news cache writes.
    #   .focus-alert-render.*     - interrupted render cache writes.
    #   .focus-alert-history.*    - interrupted change-history writes.
    # The 5-minute mmin gate avoids racing live writes from the conky-status
    # binary that may have a temp file in flight at launcher startup.
    find "$data_dir" -maxdepth 1 -type f -name '.conky-status.lock.bak.*' -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.user-commands.tmp-*' -mmin +10 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.conky-status.tmp-*' -mmin +5 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.focus-alert-state.*' -mmin +5 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.focus-alert-news-json.*' -mmin +5 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.focus-alert-news.*' -mmin +5 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.focus-alert-render.*' -mmin +5 -delete 2>/dev/null || true
    find "$data_dir" -maxdepth 1 -type f -name '.focus-alert-history.*' -mmin +5 -delete 2>/dev/null || true
    rm -rf "$runtime_root/configs" 2>/dev/null || true

    # Conky is not running yet when launcher cleanup happens, so any refresh lock here is stale.
    rm -f "$lock_file" 2>/dev/null || true

    # Drop very old snapshots so bundled or abandoned cache data cannot pin the panel to old values.
    if [[ "$snapshot_max_age" =~ ^[0-9]+$ ]] && [[ -f "$snapshot_file" ]]; then
        local now_ts snapshot_ts snapshot_age
        now_ts=$(date +%s 2>/dev/null || echo 0)
        snapshot_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
        [[ "$now_ts" =~ ^[0-9]+$ ]] || now_ts=0
        [[ "$snapshot_ts" =~ ^[0-9]+$ ]] || snapshot_ts=0

        if (( snapshot_ts == 0 )); then
            rm -f "$snapshot_file" 2>/dev/null || true
        else
            snapshot_age=$((now_ts - snapshot_ts))
            if (( snapshot_age > snapshot_max_age )); then
                log_info "Removing stale conky snapshot (${snapshot_age}s old): $snapshot_file"
                rm -f "$snapshot_file" 2>/dev/null || true
            fi
        fi
    fi
}

prepare_runtime_configs() {
    local conky_dir="$1"
    local source_configs_dir="$conky_dir/configs"
    local runtime_root runtime_configs_dir
    local copied=0
    local file

    if [[ ! -d "$source_configs_dir" ]]; then
        log_error "Source configs directory not found: $source_configs_dir"
        return 1
    fi

    runtime_root="$(get_runtime_root)"
    runtime_configs_dir="$runtime_root/configs"

    rm -rf "$runtime_configs_dir"
    mkdir -p "$runtime_configs_dir"

    shopt -s nullglob
    for file in "$source_configs_dir"/*.conf; do
        cp -f "$file" "$runtime_configs_dir/"
        copied=1
    done
    shopt -u nullglob

    if [[ "$copied" -ne 1 ]]; then
        log_error "No conky config files found in: $source_configs_dir"
        return 1
    fi

    resolve_lua_load_paths "$runtime_configs_dir"
    apply_auto_layout "$runtime_configs_dir"
    echo "$runtime_configs_dir"
}

# Make every `lua_load` path absolute in the RUNTIME copies.
#
# THE UBUNTU GNOME "GAUGES PANEL IS EMPTY" BUG (operator report, reproduced 2026-09-05
# in Docker: ubuntu:26.04 + gnome-shell + kodachi-conky from the beta channel). The
# shipped configs say `lua_load ~/.config/kodachi/conky/lua/conky-gauges.lua`. The
# conky binary itself opens that file, so no shell ever expands the tilde. Kodachi's
# conky (Debian trixie, 1.22.1) expands `~` in that setting; Ubuntu's conky
# (26.04, 1.22.2-1build1) does not, and prints
#
#     conky: llua_load: specified script file '~/.config/kodachi/conky/lua/conky-gauges.lua' doesn't exist
#     conky: llua_do_call: function conky_main execution failed: attempt to call a nil value
#
# so conky_main is never defined and NO gauge is drawn, while the panel's text
# (title, tagline) still renders. The four text panels are unaffected because their
# `${execi ~/.config/...}` paths run through `sh -c`, which does expand the tilde.
# The same container, the same config with the absolute path: script loaded, gauges
# drawn. This is the whole difference, so the fix is to hand conky an absolute path
# on every distro, which is what a cross-distro package must do anyway.
#
# Rewritten in the runtime copies only (the shipped configs keep `~` so a config
# copied to another user keeps working), using bash pattern replacement rather than
# sed so a home directory containing `&`, `#` or `/` cannot corrupt the line.
resolve_lua_load_paths() {
    local configs_dir="$1"
    local home_dir file line rewritten changed
    home_dir="$(get_home_dir)"
    [[ -n "$home_dir" && -d "$home_dir" ]] || return 0

    shopt -s nullglob
    for file in "$configs_dir"/*.conf; do
        changed=0
        rewritten=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*lua_load[[:space:]] ]]; then
                # `lua_load` may name several scripts separated by spaces; every
                # `~/` that starts a token becomes the real home directory.
                local fixed=" ${line}"
                fixed="${fixed// ~\// ${home_dir}/}"
                # conky 1.10 Lua syntax quotes the path: lua_load = '~/x.lua'
                fixed="${fixed//\'~\//\'${home_dir}/}"
                fixed="${fixed//\"~\//\"${home_dir}/}"
                fixed="${fixed:1}"
                if [[ "$fixed" != "$line" ]]; then
                    line="$fixed"
                    changed=1
                fi
                # Say so when a form this pass does not know slipped through:
                # the Ubuntu symptom would otherwise return with no log line.
                if [[ "$fixed" == *'~/'* ]]; then
                    log_warn "lua_load in $(basename "$file") still carries a ~ this pass could not resolve: $fixed"
                fi
                if [[ "$home_dir" == *' '* && "$fixed" =~ ^[[:space:]]*lua_load[[:space:]]+[^=\'\"] ]]; then
                    log_warn "home directory contains a space; conky's whitespace-separated lua_load cannot carry it: $fixed"
                fi
            fi
            rewritten+="${line}"$'\n'
        done < "$file"
        if [[ "$changed" -eq 1 ]]; then
            printf '%s' "$rewritten" > "$file"
            log_info "Resolved lua_load paths to $home_dir in $(basename "$file")"
        fi
    done
    shopt -u nullglob
}

# Kill existing conky instances gracefully
kill_existing_conky() {
    log_info "Stopping existing conky instances..."

    # Try graceful termination first
    if pgrep -x conky &>/dev/null; then
        pkill -x conky 2>/dev/null || true
        sleep 1

        # Force kill if still running
        if pgrep -x conky &>/dev/null; then
            pkill -9 -x conky 2>/dev/null || true
            sleep 0.5
        fi
    fi

    log_info "Existing conky instances stopped"
}

# ===== CONKY PANEL LAUNCHER =====
launch_panel() {
    local config_file="$1"
    local panel_name
    panel_name=$(basename "$config_file" .conf)

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi

    log_info "Launching panel: $panel_name"

    # Keep conky inside the watchdog service cgroup so logout/shutdown can stop it.
    # Close flock FD 8 in child so the launcher lock is released when launcher exits,
    # not held open by long-lived conky processes.
    conky -q -c "$config_file" >/dev/null 2>&1 8>&- &

    # Stagger panel launches to avoid subprocess storms on boot.
    # Each panel's execi commands fire on first render; 3 seconds gives the
    # previous panel time to finish its initial collection before the next starts.
    sleep 3
}

# Launch all panels in order
launch_all_panels() {
    local conky_dir="$1"
    local source_configs_dir="$conky_dir/configs"
    local configs_dir=""

    if [[ ! -d "$source_configs_dir" ]]; then
        log_error "Configs directory not found: $source_configs_dir"
        return 1
    fi

    configs_dir="$(prepare_runtime_configs "$conky_dir")" || return 1
    RUNTIME_CONFIGS_DIR="$configs_dir"
    log_info "Launching conky panels from runtime configs: $configs_dir"

    # Single-core hosts: throttle the data pipeline so it can't starve the
    # renderer (slower update_interval + snapshot timer 300s + CPUQuota 60%).
    apply_lowcpu_throttle "$configs_dir"

    # Pre-warm the conky-status snapshot cache BEFORE launching any panels.
    # Without this, all 40+ execi commands fire simultaneously on first render,
    # each triggering a conky-status collection that spawns sudo health-control,
    # ufw status, nft list ruleset, etc., causing an OOM kill on live ISOs.
    # One cached snapshot is shared by all panels via the file-based TTL cache.
    #
    # Timeout sizing (audit 2026-05-01, LAX-PROXY-02 cold-cache reproduction):
    #   First boot on hysteria2/wireguard/Tor presents the slowest case, #   online-auth's HTTPS handshake + cert pinning takes 8-12 s alone, and
    #   net-check's full ip+dns+http probe needs ~10 s on a slow tunnel. The
    #   old 8 s adapter cap timed out every network adapter on the very first
    #   refresh, then `build_snapshot` persisted the fallback "Off"/"Offline"
    #   payload because no previous cache existed (cache-cold poisoning). The
    #   conky panel then rendered "Login: Off" + "Internet: Off" indefinitely
    #   until a later timer cycle happened to succeed.
    #
    #   New sizing: --timeout-ms 20000 (20 s per adapter, matches the new
    #   FORCE_REFRESH_TIMEOUT_SECS=75 budget), --max-parallel 4 (the
    #   bounded-stream concurrency limit that build_snapshot uses), and a
    #   90 s bash timeout (matches the systemd unit's TimeoutSec=90). This
    #   gives ~45 s of worst-case adapter time + ~10 s of process/IO overhead
    #   inside a 90 s wall budget.
    local _prewarm_bin
    _prewarm_bin=$(command -v conky-status 2>/dev/null || true)
    if [[ -n "$_prewarm_bin" && -x "$_prewarm_bin" ]]; then
        log_info "Pre-warming conky-status cache..."
        # CFA-04 FIX 2026-09-01: share the single-flight refresh lock with
        # focus-alert.sh and conky-snapshot-refresh.service. This prewarm forks
        # 30+ sudo children, and the unit's own header records that doing that
        # during desktop bring-up starves xfce4-session of PAM/dbus/disk. The
        # FD-8 lock above is a DIFFERENT resource: it serialises launcher runs,
        # not refreshes, which is why it never prevented this.
        # Skipping is safe: a refresh is already in flight, so the cache is
        # about to be warm anyway, and a cold panel is far cheaper than a
        # doubled sudo fan-out at login.
        (
            mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/kodachi/conky/data" 2>/dev/null || true
            exec 9>"${XDG_CONFIG_HOME:-$HOME/.config}/kodachi/conky/data/.focus-alert-refresh.lock" 2>/dev/null || exit 0
            flock -n 9 || exit 0
            timeout 90 "$_prewarm_bin" snapshot --refresh --max-parallel 4 --timeout-ms 20000 >/dev/null 2>&1 || true
        )
        log_info "Cache pre-warm complete"
    fi

    # Define panel order - gauges LAST since it loads lua
    # No logo panel by default to avoid overlap
    local panels=(
        "conkyrc-resources.conf"
        "conkyrc-security.conf"
        "conkyrc-system.conf"
        "conkyrc-focus-alert.conf"
        "conkyrc-gauges.conf"
    )

    local launched=0
    for panel in "${panels[@]}"; do
        local config_path="$configs_dir/$panel"
        if [[ -f "$config_path" ]]; then
            launch_panel "$config_path"
            ((launched++))
        else
            log_warn "Panel config not found: $panel"
        fi
    done

    if [[ $launched -eq 0 ]]; then
        log_error "No conky panels were launched!"
        return 1
    fi

    log_info "Successfully launched $launched conky panel(s)"
    return 0
}

# ===== USAGE =====
show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Launches Kodachi conky desktop panels.
NO external data aggregator needed - panels fetch data directly.

Options:
  --enable      Safe enable: start watchdog service and relaunch panels
  --disable     Safe disable: stop watchdog service and stop conky
  --restart     Kill existing conky instances and restart
  --stop        Stop all conky instances
  --status      Show status of running conky instances
  --with-logo   Also launch the logo/branding panel
  --help, -h    Show this help message

Configuration directory search order:
  1. \$XDG_CONFIG_HOME/kodachi/conky
  2. ~/.config/kodachi/conky
  3. ~/.kodachi/conky
  4. /etc/kodachi/conky
  5. /opt/kodachi/conky
  6. ~/k900/livebuild-assets/conky (development)

Panels launched:
  - Resources (CPU, Memory, Disk info)
  - Security (Privacy status, VPN, Tor, DNS)
  - System (Traffic, Ports, System info)
  - Focus Alert (top-center change-driven critical status strip)
  - Gauges (Cairo circular gauges - CPU, MEM, DISK)

EOF
}

# ===== STATUS CHECK =====
show_status() {
    echo "=== Conky Status ==="
    if pgrep -x conky &>/dev/null; then
        echo "Conky is running:"
        pgrep -a conky 2>/dev/null || true
    else
        echo "Conky is not running"
    fi
    echo ""

    local conky_dir
    conky_dir="$(get_conky_dir)"

    echo "=== Configuration ==="
    echo "Conky directory: $conky_dir"
    echo ""

    echo "=== Available Panels ==="
    if [[ -d "$conky_dir/configs" ]]; then
        ls -la "$conky_dir/configs/"*.conf 2>/dev/null || echo "No config files found"
    else
        echo "Config directory not found"
    fi
}

# ===== MAIN =====
main() {
    local do_enable=false
    local do_restart=false
    local do_stop=false
    local do_status=false
    local with_logo=false

    # Prevent concurrent launcher runs that can race and duplicate panels.
    if command -v flock &>/dev/null; then
        local lock_file="${XDG_RUNTIME_DIR:-/tmp}/kodachi-conky-launcher.lock"
        exec 8>"$lock_file"
        if ! flock -n 8; then
            log_warn "Another conky-launcher instance is already running; exiting"
            exit 0
        fi
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --enable)
                do_enable=true
                do_restart=true
                shift
                ;;
            --disable)
                do_stop=true
                shift
                ;;
            --restart)
                do_restart=true
                shift
                ;;
            --stop)
                do_stop=true
                shift
                ;;
            --status)
                do_status=true
                shift
                ;;
            --with-logo)
                with_logo=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Handle status
    if [[ "$do_status" == "true" ]]; then
        show_status
        exit 0
    fi

    # Handle stop
    if [[ "$do_stop" == "true" ]]; then
        # Safe disable path: stop watchdog first, then terminate only conky.
        stop_watchdog_service
        kill_existing_conky
        log_info "All conky instances stopped"
        exit 0
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Get conky directory
    local conky_dir
    conky_dir="$(get_conky_dir)"
    log_info "Using conky directory: $conky_dir"

    # Ensure configs directory exists
    if [[ ! -d "$conky_dir/configs" ]]; then
        log_error "Configs directory not found: $conky_dir/configs"
        log_error "Please ensure conky configuration files are installed"
        exit 1
    fi

    cleanup_runtime_artifacts "$conky_dir"

    # Kill existing if restart or fresh start
    if [[ "$do_restart" == "true" ]] || pgrep -x conky &>/dev/null; then
        kill_existing_conky
    fi

    # Launch all panels
    if ! launch_all_panels "$conky_dir"; then
        log_error "Failed to launch conky panels"
        exit 1
    fi

    # Optionally launch logo panel
    if [[ "$with_logo" == "true" ]]; then
        local logo_config="${RUNTIME_CONFIGS_DIR:-}/conkyrc-logo.conf"
        if [[ -f "$logo_config" ]]; then
            launch_panel "$logo_config"
        fi
    fi

    # Safe enable path: once panels are running, ensure watchdog is active.
    if [[ "$do_enable" == "true" ]]; then
        start_watchdog_service
    fi

    log_info "Kodachi conky panels launched successfully"
}

main "$@"
