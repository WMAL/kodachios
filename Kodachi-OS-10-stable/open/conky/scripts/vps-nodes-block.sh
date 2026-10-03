#!/usr/bin/env bash
# vps-nodes-block.sh
# ===========================================================
# Emit one Conky row per live VPS node, DYNAMICALLY (any count).
# Replaces the old hardcoded VPS1..VPS4 rows so the panel auto-adjusts
# when the elastic worker fleet grows or shrinks.
#
# Robustness: reads the whole nodes array in a SINGLE `conky-status get`
# call (no per-key gateway timeout that can transiently return the "Off"
# default and blank the list), then renders every real node. Padded /
# empty slots (vpsdisplay == "Off" or empty) are SKIPPED, never break the
# loop, so a transient miss on one node cannot drop the rest.
#
# SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.0
# Copyright (c) 2013-2026 Warith Al Maawali

set -o pipefail
# F19: answer from the snapshot-generation memo when nothing this script reads has
# changed (conky-snapshot-memo.sh explains why the output is identical). Any doubt
# falls through to the unchanged body below.
if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
    . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

BIN=$(conky_gateway_find_binary 2>/dev/null || true)
[[ -z "$BIN" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Through the gateway helper, not a bare spawn (finding #104): a fresh
# snapshot answers in-shell via jq. An absent or stale snapshot falls back to
# the binary under the helper's own floor (conky_gateway_effective_timeout, 5s
# by default; the "2" below only applies when CONKY_GATEWAY_WARMUP_TIMEOUT /
# CONKY_GATEWAY_REFRESH_TIMEOUT are configured below it), which replaces the
# previous UNBOUNDED raw `get` on every execpi cycle.
arr=$(conky_gateway_get_multiline_or_default data.online_info.vps.nodes "" 2 "$BIN" 2>/dev/null)
[[ -z "$arr" ]] && exit 0

n=0
unread=0
while IFS=$'\t' read -r disp status torvis country; do
    status_known=0
    [[ "$status" == "On" || "$status" == "Off" ]] && status_known=1
    # A node is shown whenever something about it was read, a name or a status; it
    # keeps its number, and an unknown status is drawn neutral with a "?" (inspector
    # pass 9: a read node that only left out services.online vanished).
    # Only a node with no name AND no status was not read at all (pass 8, #6).
    if [[ -z "$disp" || "$disp" == "Off" || "$disp" == "?" ]]; then
        if (( ! status_known )); then
            unread=$((unread + 1))
            continue
        fi
        # A read status with no name: the old producer's "Off" placeholder rows stay
        # hidden as before; a name the producer could not read is shown as "?".
        [[ "$disp" == "?" ]] || continue
    fi
    n=$((n + 1))
    case "$status" in
        On) color='${color1}'; mark="" ;;
        Off) color='${color6}'; mark="" ;;
        *) color='${color3}'; mark=" ?" ;;
    esac
    line='${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}VPS'"$n"': '"$color$disp$mark"
    if [[ "$torvis" == "Yes" ]]; then
        line="$line"'${alignr}${color3}Tor'"$n"': ${color1}'"$country"
    fi
    printf '%s\n' "$line"
done < <(printf '%s' "$arr" | jq -r '.[]? | [.vpsdisplay, .status, .torvisible, .country] | @tsv' 2>/dev/null)

# A BLANK SECTION IS NOT A STATUS (same class as the ai-agents fix). Measured on
# <lab-host>, 2026-09-05: the fleet endpoint answered five nodes all carrying
# vpsdisplay "Off" and an empty country, every row was skipped above, and the
# VPS NODES header sat over nothing. Say so in one grey row, so the user can tell
# "no node is reachable right now" from "the panel is broken".
if (( n == 0 )); then
    if (( unread > 0 )); then
        printf '%s\n' '${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}fleet not read'
    else
        printf '%s\n' '${voffset 6}${goto 5}${font Liberation Sans Narrow:size=10}${color3}no node reachable'
    fi
fi
