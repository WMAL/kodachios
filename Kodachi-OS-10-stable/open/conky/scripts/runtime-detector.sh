#!/usr/bin/env bash

# runtime-detector.sh
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
FIELD="${1:-conky-vpn}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

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

normalize_onoff_text() {
    sed \
        -e 's/\<ON\>/On/g' \
        -e 's/\<OFF\>/Off/g' \
        -e 's/\<UP\>/Up/g' \
        -e 's/\<on\>/On/g' \
        -e 's/\<off\>/Off/g' \
        -e 's/\<up\>/Up/g'
}

normalize_vpn_protocol_value() {
    local raw="${1:-}"
    local lowered=""

    raw=$(printf '%s' "$raw" | tr -d '\r' | xargs 2>/dev/null || printf '%s' "$raw")
    lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')

    case "$lowered" in
        ""|"n/a"|"na"|"none"|"null"|"off"|"false"|"0")
            echo "None"
            ;;
        openvpn)
            echo "OpenVPN"
            ;;
        wireguard|wg)
            echo "WireGuard"
            ;;
        amneziawg|awg)
            echo "AmneziaWG"
            ;;
        shadowsocks|ss)
            echo "Shadowsocks"
            ;;
        v2ray)
            echo "V2Ray"
            ;;
        xray)
            echo "Xray"
            ;;
        tailscale)
            echo "Tailscale"
            ;;
        sing-box|singbox)
            echo "sing-box"
            ;;
        *)
            echo "$raw"
            ;;
    esac
}

# All routing data is fetched from the conky-status gateway cache.
# The gateway's routing adapter already calls routing-switch with proper
# permissions; there is no need to invoke sudo from the Conky session.

gateway_routing_onoff() {
    local raw
    raw="$(conky_gateway_get_or_default "data.routing.onoff" "Off" 2 "$BIN")"
    normalize_onoff_value "$raw"
}

gateway_routing_protocol() {
    local raw
    raw="$(conky_gateway_get_or_default "data.routing.protocol" "None" 2 "$BIN")"
    normalize_vpn_protocol_value "$raw"
}

gateway_routing_connected_text() {
    local onoff
    onoff="$(gateway_routing_onoff)"
    if [[ "$onoff" == "On" ]]; then
        echo "Connected"
    else
        echo "Disconnected"
    fi
}

build_conky_routing_line() {
    local routing_onoff="${1:-Off}"
    local routing_protocol="${2:-None}"

    routing_onoff="$(normalize_onoff_value "$routing_onoff")"
    routing_protocol="$(normalize_vpn_protocol_value "$routing_protocol")"

    if [[ "$routing_onoff" != "On" ]]; then
        routing_protocol="None"
    fi

    printf '%s\n' "\${voffset 4}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color3}Routing:\${color1}${routing_onoff}\${alignr}\${color3}Protocol: \${color1}${routing_protocol}"
}

insert_line_after_first() {
    local block="${1:-}"
    local line="${2:-}"

    [[ -n "$block" ]] || return 0
    [[ -n "$line" ]] || {
        printf '%s\n' "$block"
        return 0
    }

    printf '%s\n' "$block" | awk -v insert="$line" '
        NR==1 { print; print insert; next }
        { print }
    '
}

rewrite_vpn_block_states_by_routing() {
    local block="${1:-}"
    local on_count=0
    local up_count=0
    local off_count=0

    [[ -n "$block" ]] || return 0

    # No ON->UP rewriting here: conky-status decides each row's state and this function only
    # re-derives the three header numbers from the row tokens.
    # Routing status is shown on its own dedicated line.
    #
    # THIS IS A SECOND IMPLEMENTATION OF THE BINARY'S HEADER ARITHMETIC, and that is the thing
    # to be careful about. It is called at line 223, BEFORE insert_line_after_first() adds the
    # routing row at 224, so the inserted row cannot disturb these counts: the recount is a pure
    # re-derivation of numbers conky-status already publishes correctly. It is therefore
    # redundant, and harmless ONLY while it agrees with the producer. Change the semantics in
    # adapters/system.rs render_vpn_conky() and you must change them here in the same commit, or
    # the HUD will render this file's answer and silently contradict every JSON consumer.
    #
    # ON, UP and OFF are DISJOINT and must stay so. cairo-dock kodachi_session_report.py
    # vpn_tunnels() renders the same three counts and its docstring records the measurement:
    # collapsing them makes one tunnel count twice and breaks ON + UP + OFF == total.
    #   OFF  no process and no unit      ON  process or unit, but NO tunnel device
    #   UP   process or unit WITH the tunnel device IFF_UP
    on_count="$(grep -o '\${color1}ON' <<<"$block" | wc -l | tr -d '[:space:]')"
    up_count="$(grep -o '\${color7}UP' <<<"$block" | wc -l | tr -d '[:space:]')"
    off_count="$(grep -o '\${color6}OFF' <<<"$block" | wc -l | tr -d '[:space:]')"

    [[ -n "$on_count" ]] || on_count=0
    [[ -n "$up_count" ]] || up_count=0
    [[ -n "$off_count" ]] || off_count=0

    block="$(printf '%s\n' "$block" | sed -E \
        -e "0,/(ON:[[:space:]]*\\$\\{color1\\})[0-9]+/s//\\1${on_count}/" \
        -e "0,/(UP:[[:space:]]*\\$\\{color7\\})[0-9]+/s//\\1${up_count}/" \
        -e "0,/(OFF:[[:space:]]*\\$\\{color6\\})[0-9]+/s//\\1${off_count}/")"

    printf '%s\n' "$block"
}

case "$FIELD" in
    vpn-connected)
        gateway_routing_connected_text
        ;;
    vpn-onoff)
        gateway_routing_onoff
        ;;
    vpn-protocol)
        gateway_routing_protocol
        ;;
    firewall-onoff)
        fw_state=$(conky_gateway_get_or_default "runtime-detector.firewall-onoff" "N/A" 2 "$BIN")
        normalize_onoff_value "$fw_state"
        ;;
    conky-vpn)
        routing_onoff="$(gateway_routing_onoff)"
        routing_protocol="None"
        routing_line=""
        if [[ "$routing_onoff" == "On" ]]; then
            routing_protocol="$(gateway_routing_protocol)"
        fi
        # Gateway helper, not a raw spawn (finding #104): the alias is served
        # in-shell from a fresh snapshot, so the binary is reached only when the
        # snapshot is absent or stale. On those two paths the helper applies ITS
        # OWN floor (conky_gateway_effective_timeout: 5s by default, lowered
        # only via CONKY_GATEWAY_WARMUP_TIMEOUT / CONKY_GATEWAY_REFRESH_TIMEOUT),
        # so the "2" below is the cap only when those floors are configured
        # below it. The old hard `timeout 2` is gone on purpose: cutting a
        # refresh at 2s is what made this block vanish for a whole cycle.
        vpn_block="$(conky_gateway_get_multiline_or_default "runtime-detector.conky-vpn" "" 2 "$BIN" 2>/dev/null || true)"
        routing_line="$(build_conky_routing_line "$routing_onoff" "$routing_protocol")"
        if [[ -n "$vpn_block" ]]; then
            vpn_block="$(rewrite_vpn_block_states_by_routing "$vpn_block")"
            vpn_block="$(insert_line_after_first "$vpn_block" "$routing_line")"
            # Tor status has its own dedicated Conky line; do not duplicate it here.
            printf '%s\n' "$vpn_block" | sed '/Tor:[[:space:]]/d' | sed -E 's/Liberation Sans Narrow:size=(8|9)\}/Liberation Sans Narrow:size=10}/g' | normalize_onoff_text
        else
            # Keep routing/protocol visible even if gateway VPN block read is transiently empty.
            printf '%s\n' "$routing_line"
        fi
        ;;
    conky-firewall)
        # Same helper and the same 5s-floor caveat as the conky-vpn arm above.
        firewall_block="$(conky_gateway_get_multiline_or_default "runtime-detector.conky-firewall" "" 2 "$BIN" 2>/dev/null || true)"
        if [[ -n "$firewall_block" ]]; then
            printf '%s\n' "$firewall_block" | sed -E 's/Liberation Sans Narrow:size=(8|9)\}/Liberation Sans Narrow:size=10}/g' | normalize_onoff_text
        fi
        ;;
    ai-list)
        # Same helper and the same 5s-floor caveat as the conky-vpn arm above.
        conky_gateway_get_multiline_or_default "data.system.runtime.ai.entries" "[]" 2 "$BIN" 2>/dev/null
        ;;
    vpn-list|firewall-list|all)
        echo "N/A"
        ;;
    *)
        echo "N/A"
        ;;
esac
