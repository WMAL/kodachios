#!/usr/bin/env bash

# Kodachi Conky Script - Security Status Checks
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
# Returns security gauges state through the conky-status gateway only.
# Output format is binary for Conky gauges: 1=active, 0=inactive.
#
# Usage:
#   security-status.sh auth
#   security-status.sh vpn
#   security-status.sh torrified
#   security-status.sh dns
#   security-status.sh all

set -u

FIELD="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

to_bin() {
    local key="$1"
    if [[ -z "$BIN" ]]; then
        echo "0"
        return
    fi
    local raw
    raw=$(conky_gateway_get_or_default "$key" "false" 2 "$BIN")
    conky_gateway_bool_01 "$raw"
}

# 2 = unknown. conky-status publishes a null boolean plus `<field>_known: false`
# when a readback failed, and the gateway turns a JSON null into THIS script's own
# default, so `to_bin` reads it as 0 = off and the gauge would draw a flat
# "inactive" for a reading that never happened. The gauge in
# lua/conky-gauges.lua:229-234 already renders 2 as a distinct unknown state.
#
# DNS has had this since the 2026-09-17 DNSCrypt report. auth, VPN and torrified
# did NOT, so those three gauges kept asserting inactive on a failed read, which is
# the same defect a user reported on the dashboard's Tor row on 2026-09-28. The
# `_known` companions for them are published by conky-status adapters/online_auth.rs,
# adapters/routing.rs and adapters/tor.rs.
#
# The known-key default is "true" so a snapshot written before these fields existed
# keeps the old On/Off rendering rather than going all-unknown.
unknown_if_unread() {
    local current="$1" known_key="$2"
    # Only a 0 can be an unread-as-off; a 1 is positive evidence and nothing here
    # may take that away.
    if [[ -z "$BIN" || "$current" != "0" ]]; then
        printf '%s' "$current"
        return
    fi
    local raw
    raw=$(conky_gateway_get_or_default "$known_key" "true" 2 "$BIN")
    if [[ "${raw,,}" == "false" ]]; then
        printf '2'
    else
        printf '%s' "$current"
    fi
}

AUTH="$(unknown_if_unread "$(to_bin security-status.auth)" data.auth.authenticated_known)"
VPN="$(unknown_if_unread "$(to_bin security-status.vpn)" data.routing.connected_known)"
TORRIFIED="$(unknown_if_unread "$(to_bin security-status.torrified)" data.tor.torrified_known)"
DNS="$(unknown_if_unread "$(to_bin security-status.dns)" data.dns.dnscrypt_known)"

case "$FIELD" in
    auth)
        echo "$AUTH"
        ;;
    vpn)
        echo "$VPN"
        ;;
    torrified)
        echo "$TORRIFIED"
        ;;
    dns)
        echo "$DNS"
        ;;
    all)
        echo "$AUTH $VPN $TORRIFIED $DNS"
        ;;
    *)
        echo "0"
        ;;
esac
