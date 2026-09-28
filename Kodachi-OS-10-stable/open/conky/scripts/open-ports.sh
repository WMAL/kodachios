#!/usr/bin/env bash

# open-ports.sh
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
# Last updated: 2026-03-05
#
# Description:
# Kodachi Conky helper script for ESTABLISHED CONNECTIONS section.
# Replaces native tcp_portmon calls with smart domain shortening
# to prevent long hostnames from overflowing the 260px panel.
#
# Usage: Called via ${execpi 20 ...} from conkyrc-system.conf
#        No arguments needed - outputs full Conky-formatted section.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true

MAX_HOST_LEN=28
MAX_ROWS=8
DNS_TIMEOUT=2
PTR_ALLOWED=false

# Reverse DNS can disclose every peer IP to a cleartext resolver. Permit it
# only when a fresh shared snapshot proves DNSCrypt or Tor DNS is active.
snapshot_file="$(conky_gateway_snapshot_path 2>/dev/null || true)"
if [[ -n "$snapshot_file" ]] && _conky_snapshot_is_fresh 2>/dev/null && command -v jq >/dev/null 2>&1; then
    if [[ "$(jq -r '(.data.dns.dnscrypt_active == true) or (.data.tor.tor_dns == true)' "$snapshot_file" 2>/dev/null)" == "true" ]]; then
        PTR_ALLOWED=true
    fi
fi

# ── Smart domain shortening ─────────────────────────────────
# Strips leftmost subdomains until the host fits MAX_HOST_LEN.
# Raw IPs pass through (they're always short enough).
shorten_host() {
    local host="$1"

    # Already fits - return as-is
    if [[ ${#host} -le $MAX_HOST_LEN ]]; then
        printf '%s' "$host"
        return
    fi

    # Raw IPv4 - always fits (max 15 chars), but guard anyway
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$host"
        return
    fi

    # Raw IPv6 - hard truncate if needed (rare)
    if [[ "$host" =~ : ]]; then
        printf '%s..' "${host:0:$((MAX_HOST_LEN - 2))}"
        return
    fi

    # Domain name: strip leftmost subdomains one at a time
    # Keep track of the best (longest) result that fits
    local remaining="$host"
    local best=""
    while true; do
        local stripped="${remaining#*.}"
        # No dots left - can't strip further
        if [[ "$stripped" == "$remaining" ]]; then
            break
        fi
        remaining="$stripped"
        if [[ ${#remaining} -le $MAX_HOST_LEN ]]; then
            best="$remaining"
            break
        fi
    done

    # If we found a fitting multi-part subdomain, use it
    # Bare TLDs (no dots, like "com") are useless - prefer truncation
    if [[ -n "$best" && "$best" == *.* ]]; then
        printf '%s' "$best"
        return
    fi

    # Nothing useful after stripping - hard truncate the original with ".."
    printf '%s..' "${host:0:$((MAX_HOST_LEN - 2))}"
}

# ── Try reverse DNS for a single IP (with timeout) ──────────
resolve_host() {
    local ip="$1"
    local resolved
    resolved=$(timeout "${DNS_TIMEOUT}s" getent hosts "$ip" 2>/dev/null | awk '{print $2}')
    if [[ -n "$resolved" && "$resolved" != "$ip" ]]; then
        printf '%s' "$resolved"
    else
        printf '%s' "$ip"
    fi
}

# ── Gather connection data ──────────────────────────────────
# Use numeric-only ss for speed and reliable parsing
raw_data=$(ss -tn state established 2>/dev/null) || raw_data=""

# Parse connections: extract remote host and port
# ss -tn format: "Recv-Q Send-Q Local-Addr:Port Peer-Addr:Port"
declare -a hosts=()
declare -a ports=()
count=0
total_count=0

while IFS= read -r line; do
    # Skip header line
    [[ "$line" =~ ^Recv-Q ]] && continue

    total_count=$((total_count + 1))

    # Only collect up to MAX_ROWS for display
    [[ $count -ge $MAX_ROWS ]] && continue

    # Extract peer address:port (4th column)
    peer=$(awk '{print $4}' <<< "$line")
    [[ -z "$peer" ]] && continue

    # Split host and port
    local_host=""
    local_port=""
    if [[ "$peer" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        # IPv6: [::1]:443
        local_host="${BASH_REMATCH[1]}"
        local_port="${BASH_REMATCH[2]}"
    elif [[ "$peer" =~ ^(.+):([0-9]+)$ ]]; then
        # IPv4: 1.2.3.4:443
        local_host="${BASH_REMATCH[1]}"
        local_port="${BASH_REMATCH[2]}"
    else
        continue
    fi

    # Skip localhost and wildcard
    case "$local_host" in
        127.0.0.1|::1|localhost|"*"|0.0.0.0|::) continue ;;
    esac

    # Resolve peers only through an encrypted DNS path proven by the snapshot.
    if [[ "$PTR_ALLOWED" == "true" ]]; then
        local_host=$(resolve_host "$local_host")
    fi

    hosts+=("$local_host")
    ports+=("$local_port")
    count=$((count + 1))
done <<< "$raw_data"

# ── Output Conky markup ─────────────────────────────────────
# Section header with port count
echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10:bold}\${color3}CONNECTIONS \${color1}${total_count} \${color5}\${stippled_hr}\${font}"

# Listening sockets, from the snapshot (conky-status reads /proc/net/{tcp,udp}
# directly, so it sees every user's sockets; `ss -p` as the desktop user does
# not). Public = bound on something other than loopback, wildcard included. A
# non-zero public count is highlighted: it is the box's exposure to its LAN.
listen_display=""
listen_public=""
if [[ -n "$snapshot_file" ]] && _conky_snapshot_is_fresh 2>/dev/null && command -v jq >/dev/null 2>&1; then
    # One jq for both values: this script already runs jq once for the PTR gate, and
    # every extra jq is a fork per 43 s cycle.
    IFS=$'\t' read -r listen_display listen_public < <(jq -r '[(.data.system.network.listening.display // ""), ((.data.system.network.listening.public // "") | tostring)] | @tsv' "$snapshot_file" 2>/dev/null || true)
fi
if [[ -n "$listen_display" ]]; then
    if [[ "$listen_public" =~ ^[0-9]+$ ]] && (( listen_public > 0 )); then
        echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color3}Listening: \${color7}${listen_display}"
    else
        echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color3}Listening: \${color1}${listen_display}"
    fi
fi

# Column labels
echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color2}IP\${alignr}PORT"

# Connection rows
if [[ $count -eq 0 ]]; then
    echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color3}No connections"
else
    for ((i = 0; i < count; i++)); do
        short=$(shorten_host "${hosts[$i]}")
        echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color1}${short}\${alignr}${ports[$i]}"
    done
fi

# Pad remaining rows to keep consistent section height
for ((i = count; i < MAX_ROWS; i++)); do
    echo "\${voffset 6}\${goto 5}\${font Liberation Sans Narrow:size=10}\${color5} "
done
