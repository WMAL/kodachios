#!/usr/bin/env bash

# auth-detail.sh
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
FIELD="${1:-authenticated}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
    echo "N/A"
    exit 0
fi
case "$FIELD" in
    group)
        # The auth-shared JSON exposes the user's tier in lowercase
        # (normal / premium / custom / vip / …). Conky rendered it
        # verbatim, so the Security panel showed "premium" with a
        # lowercase "p" in the SIGNAL DECK. UX feedback 2026-05-25
        # (Image #38) plus user follow-up 2026-05-25 ("how about
        # normal custom, will they all have the fix? you have to be
        # smart"): mirror the dashboard's tier mapping so conky and
        # dashboard agree (see LaunchReadiness.svelte: vip→Premium,
        # premium→Premium, custom→Custom, normal→Normal, fallback
        # first-letter-cap). Bash `${val^}` alone would render `vip`
        # as `Vip` which is wrong (it's an acronym, and the dashboard
        # collapses vip into Premium).
        _val=$(conky_gateway_get_or_default "auth-detail.$FIELD" "N/A" 2 "$BIN")
        if [[ -z "$_val" || "$_val" == "N/A" ]]; then
            echo "$_val"
        else
            _lc="${_val,,}"
            case "$_lc" in
                vip|premium)   echo "Premium" ;;
                custom)        echo "Custom" ;;
                normal)        echo "Normal" ;;
                *)             echo "${_lc^}" ;;
            esac
        fi
        ;;
    authenticated|blocked|sessionid|secureid)
        conky_gateway_get_or_default "auth-detail.$FIELD" "N/A" 2 "$BIN"
        ;;
    *)
        echo "N/A"
        ;;
esac
