#!/usr/bin/env bash

# snapshot-age.sh
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
# Version: <lab-host>
# Last updated: 2026-09-05
#
# Description:
# Staleness marker for the PRIVACY STATUS header. Every row on the security
# panel is read from ONE shared snapshot (conky-status.json). When the refresh
# stops (dead network, wedged lock, timer not running, snapshot never written)
# the panel keeps showing the LAST values with nothing to say they are old:
# a "VPN: On" that is twenty minutes stale reads exactly like a live one. That
# is the least acceptable failure for a privacy HUD, so this prints a red
# marker into the header once the snapshot is older than STALE_AFTER_SECONDS,
# and nothing at all while it is fresh.
#
# Pure file stat, no jq, no binary: it must work precisely when the pipeline
# behind it does not. Output is parsed by ${execpi}, so it may carry conky
# colour variables.

set -u
STALE_AFTER_SECONDS="${CONKY_SNAPSHOT_STALE_AFTER:-300}"
[[ "$STALE_AFTER_SECONDS" =~ ^[0-9]+$ ]] || STALE_AFTER_SECONDS=300

config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
snapshot_file="$config_base/kodachi/conky/data/conky-status.json"

if [[ ! -s "$snapshot_file" ]]; then
    printf '%s\n' '${color6}no data '
    exit 0
fi

now_ts=""
printf -v now_ts '%(%s)T' -1 2>/dev/null || now_ts=$(date +%s 2>/dev/null || echo 0)
file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
[[ "$now_ts" =~ ^[0-9]+$ && "$file_ts" =~ ^[0-9]+$ ]] || exit 0

age=$(( now_ts - file_ts ))
if (( age <= STALE_AFTER_SECONDS )); then
    exit 0
fi

if (( age >= 3600 )); then
    printf '${color6}stale %dh \n' "$(( age / 3600 ))"
else
    printf '${color6}stale %dm \n' "$(( age / 60 ))"
fi
