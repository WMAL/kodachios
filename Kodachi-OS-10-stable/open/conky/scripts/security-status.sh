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
# Output for Conky gauges: 1=active, 0=inactive, 2=unknown (no conky-status
# binary was found, or the snapshot did not read that state: its *_known key is false).
#
# Usage:
#   security-status.sh auth
#   security-status.sh vpn
#   security-status.sh torrified
#   security-status.sh dns
#   security-status.sh all

set -u
# F19: answer from the snapshot-generation memo when nothing this script reads has
# changed (conky-snapshot-memo.sh explains why the output is identical). Any doubt
# falls through to the unchanged body below.
if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
    . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
fi

FIELD="${1:-all}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

to_bin() {
    local key="$1"
    if [[ -z "$BIN" ]]; then
        # No conky-status binary: nothing was read, so unknown (2), never "off".
        echo "2"
        return
    fi
    local raw
    raw=$(conky_gateway_get_or_default "$key" "__CONKY_SS_ABSENT__" 2 "$BIN")
    # Round 4 (V8): an absent value (a timed-out or refused per-key read) is unknown,
    # whatever its `_known` companion says when that companion is read a moment later
    # from a newer snapshot (route-mode.sh has the measured case).
    if [[ "$raw" == "__CONKY_SS_ABSENT__" ]]; then
        echo "2"
        return
    fi
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
# The known-key default is "false" (inspector B, round 3c, the R4 sibling): every <lab-host>
# conky-status publishes these companions, and after a state stamp the gateway misses
# ON PURPOSE, so a missing key means "not read", never a known Off.
unknown_if_unread() {
    local current="$1" known_key="$2"
    # Only a 0 can be an unread-as-off; a 1 is positive evidence and nothing here
    # may take that away.
    if [[ -z "$BIN" || "$current" != "0" ]]; then
        printf '%s' "$current"
        return
    fi
    local raw
    raw=$(conky_gateway_get_or_default "$known_key" "false" 2 "$BIN")
    # Round 3d cross-review (A3): only a literal true is known; "false", null, "?", an
    # empty answer or any other token is unknown.
    if ! conky_known_is_true "$raw"; then
        printf '2'
    else
        printf '%s' "$current"
    fi
}

# F19 (2026-09-30): ONE SNAPSHOT READ FOR ALL NINE KEYS, NO PIPELINES.
#
# conky-gauges.lua runs `security-status.sh all` every 15 s. Measured on the live
# <lab-host> VM <lab-host> with a bpftrace fork tree: 560 forks per 120 s, about
# 70 per run, because every key paid its own subshell + stat + jq and every boolean
# paid `echo | tr | xargs`. This reads the same keys (nine since inspector pass 7 #4
# added data.dns.dnscrypt_active_known) through
# conky_gateway_get_many (one stat, one jq, identical TTL, alias and default rules,
# per-key fallback when the batch cannot be served) and applies the SAME rules as
# to_bin and unknown_if_unread below:
#   a value key missing -> "false"; a *_known key missing -> "false" (unknown);
#   bool: lowercase, trim, 1|true|on|yes|y -> 1, anything else -> 0;
#   a 0 whose *_known is not literally "true" -> 2 (unknown), a 1 is never downgraded.
# If the batch cannot return exactly nine lines, the original per-key path runs.
_ss_bool01() {
    local -n _ss_b_out="$1"
    local _ss_b_v="$2"
    local LC_ALL=C
    _ss_b_v="${_ss_b_v,,}"
    _ss_b_v="${_ss_b_v#"${_ss_b_v%%[![:space:]]*}"}"
    _ss_b_v="${_ss_b_v%"${_ss_b_v##*[![:space:]]}"}"
    case "$_ss_b_v" in
        1|true|on|yes|y) _ss_b_out=1 ;;
        *) _ss_b_out=0 ;;
    esac
}

_SS_BATCHED=0
if [[ -n "$BIN" ]] && declare -F conky_gateway_get_many >/dev/null 2>&1; then
    _SS_MISS="__CONKY_SS_MISS__"
    _ss_vals=()
    mapfile -t _ss_vals < <(CONKY_GATEWAY_MANY_TIMEOUT=2 CONKY_GATEWAY_MANY_BIN="$BIN" \
        conky_gateway_get_many "$_SS_MISS" \
        security-status.auth security-status.vpn security-status.torrified security-status.dns \
        data.auth.authenticated_known data.routing.connected_known data.tor.torrified_known data.dns.dnscrypt_known \
        data.dns.dnscrypt_active_known \
        2>/dev/null)
    # conky_gateway_bool_01 trims through `xargs`, which also strips quotes and
    # backslashes; a value carrying one takes the per-key path so nothing differs.
    _ss_plain=1
    for _ss_v in "${_ss_vals[@]}"; do
        [[ "$_ss_v" == *[\'\"\\]* ]] && _ss_plain=0
    done
    if (( ${#_ss_vals[@]} == 9 && _ss_plain == 1 )); then
        _ss_out=()
        for _ss_i in 0 1 2 3; do
            _ss_raw="${_ss_vals[$_ss_i]}"
            _ss_absent=0
            if [[ "$_ss_raw" == "$_SS_MISS" ]]; then
                _ss_raw="false"
                _ss_absent=1
            fi
            _ss_bool01 _ss_cur "$_ss_raw"
            _ss_known="${_ss_vals[$((_ss_i + 4))]}"
            # Inspector pass 7 (#4): the DNS gauge reads dnscrypt_active, whose provenance
            # is dnscrypt_active_known (null active with known false must be unknown, not
            # inactive). An older binary without that key keeps dnscrypt_known.
            if (( _ss_i == 3 )) && [[ "${_ss_vals[8]}" != "$_SS_MISS" ]]; then
                _ss_known="${_ss_vals[8]}"
            fi
            [[ "$_ss_known" == "$_SS_MISS" ]] && _ss_known="false"
            # Round 4 (V8): an absent value is unread whatever its companion says; on the
            # gateway's per-key fallback the two are separate reads (see to_bin).
            (( _ss_absent )) && _ss_known="false"
            if [[ "$_ss_cur" == "0" ]] && ! conky_known_is_true "$_ss_known"; then
                _ss_cur=2
            fi
            _ss_out+=("$_ss_cur")
        done
        AUTH="${_ss_out[0]}"
        VPN="${_ss_out[1]}"
        TORRIFIED="${_ss_out[2]}"
        DNS="${_ss_out[3]}"
        _SS_BATCHED=1
    fi
fi

if (( _SS_BATCHED == 0 )); then
AUTH="$(unknown_if_unread "$(to_bin security-status.auth)" data.auth.authenticated_known)"
VPN="$(unknown_if_unread "$(to_bin security-status.vpn)" data.routing.connected_known)"
TORRIFIED="$(unknown_if_unread "$(to_bin security-status.torrified)" data.tor.torrified_known)"
# Inspector pass 7 (#4): same known-key rule as the batched path above:
# dnscrypt_active_known when published, else dnscrypt_known, else "false".
DNS="$(to_bin security-status.dns)"
if [[ -n "$BIN" && "$DNS" == "0" ]]; then
    _ss_dns_known=$(conky_gateway_get_or_default "data.dns.dnscrypt_active_known" "__absent__" 2 "$BIN")
    if [[ "$_ss_dns_known" == "__absent__" ]]; then
        _ss_dns_known=$(conky_gateway_get_or_default "data.dns.dnscrypt_known" "false" 2 "$BIN")
    fi
    if ! conky_known_is_true "$_ss_dns_known"; then
        DNS=2
    fi
fi
fi

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
