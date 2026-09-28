#!/usr/bin/env bash

# card-info-block.sh
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD_SCRIPT="$SCRIPT_DIR/card-info.sh"

# No output means no visual gap in conky when card data is unavailable.
if [[ ! -x "$CARD_SCRIPT" ]]; then
    exit 0
fi

if [[ "$("$CARD_SCRIPT" available 2>/dev/null)" != "Yes" ]]; then
    exit 0
fi

cat <<'EOF'
${goto 5}${font Liberation Sans Narrow:size=10:bold}${color3}VPS CARD INFO ${color5}${stippled_hr}${font}
${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}IPv4: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh ipv4}${alignr}${color3}Country: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh vpscountry}
${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}IPv6: ${color1}${alignr}${exec ~/.config/kodachi/conky/scripts/card-info.sh ipv6}
${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}Type: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh type}${alignr}${color3}Host: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh hostname}
${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}Load: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh load}${alignr}${color3}Mem: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh memory} MB
${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}Uptime: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh uptime}${alignr}${color3}Services: ${color1}${exec ~/.config/kodachi/conky/scripts/card-info.sh services}
${color5}${stippled_hr}${font}
EOF
