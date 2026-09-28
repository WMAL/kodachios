#!/usr/bin/env bash

# conky-gateway-common.sh
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


# Kodachi Conky Gateway Helper
# ===========================================================
#
# Shared helper for Conky wrapper scripts that delegate lookups
# to the Rust conky-status gateway while keeping safe fallback behavior.

# Error logging configuration
CONKY_ERROR_LOG="${HOME}/.cache/kodachi/conky-error.log"
CONKY_LOG_MAX_BYTES="${CONKY_LOG_MAX_BYTES:-1048576}"
CONKY_ERROR_RATE_LIMIT_SEC="${CONKY_ERROR_RATE_LIMIT_SEC:-30}"
CONKY_ERROR_RATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/kodachi-conky-error-rate"

# Ensure cache directory exists
conky_gateway_ensure_cache_dir() {
    local cache_dir="${HOME}/.cache/kodachi"
    if [[ ! -d "$cache_dir" ]]; then
        mkdir -p "$cache_dir" 2>/dev/null || true
    fi
}

conky_gateway_rotate_log() {
    local file="${1:-}"
    local max_bytes="${2:-$CONKY_LOG_MAX_BYTES}"
    local size=0

    [[ -n "$file" ]] || return 0
    [[ -f "$file" ]] || return 0
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=1048576
    (( max_bytes < 1024 )) && max_bytes=1024

    size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    if (( size < max_bytes )); then
        return 0
    fi

    if [[ -f "${file}.2" ]]; then
        rm -f "${file}.2" 2>/dev/null || true
    fi
    if [[ -f "${file}.1" ]]; then
        mv -f "${file}.1" "${file}.2" 2>/dev/null || true
    fi
    mv -f "$file" "${file}.1" 2>/dev/null || true
}

conky_gateway_mktemp_file() {
    local base_dir="${XDG_RUNTIME_DIR:-$HOME/.cache/kodachi}"
    mkdir -p "$base_dir" 2>/dev/null || true
    mktemp "$base_dir/conky-gateway.XXXXXX" 2>/dev/null || mktemp
}

# Log error with timestamp
conky_gateway_log_error() {
    local message="$1"
    local key="${2:-unknown}"
    local now_ts last_ts rate_limit key_hash stamp_file

    conky_gateway_ensure_cache_dir
    conky_gateway_rotate_log "$CONKY_ERROR_LOG"

    rate_limit="${CONKY_ERROR_RATE_LIMIT_SEC:-30}"
    [[ "$rate_limit" =~ ^[0-9]+$ ]] || rate_limit=30

    if (( rate_limit > 0 )); then
        mkdir -p "$CONKY_ERROR_RATE_DIR" 2>/dev/null || true
        if command -v sha1sum >/dev/null 2>&1; then
            key_hash=$(printf '%s|%s' "$key" "$message" | sha1sum | awk '{print $1}')
        else
            key_hash=$(printf '%s' "$key" | tr '/ ' '__')
        fi
        stamp_file="$CONKY_ERROR_RATE_DIR/${key_hash}.ts"
        now_ts=$(date +%s 2>/dev/null || echo 0)
        last_ts=$(cat "$stamp_file" 2>/dev/null || echo 0)
        [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

        if (( now_ts - last_ts < rate_limit )); then
            return 0
        fi
        echo "$now_ts" > "$stamp_file" 2>/dev/null || true
    fi

    if [[ -w "$(dirname "$CONKY_ERROR_LOG")" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] key=$key error=$message" >> "$CONKY_ERROR_LOG" 2>/dev/null || true
    fi
}

conky_gateway_snapshot_path() {
    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
    echo "$config_base/kodachi/conky/data/conky-status.json"
}

# ============ SNAPSHOT DIRECT-READ FAST PATH ============
# Reads values directly from the JSON snapshot file using jq,
# bypassing the conky-status binary entirely for cached reads.
# Reduces process chain from 7 to 2 per execi call.

# Key alias map (mirrors Rust query.rs KEY_ALIASES exactly)
declare -gA _CONKY_KEY_ALIASES=(
    ["internet-status"]="data.health.internet.status"
    ["auth-status"]="data.auth.login"
    ["auth-detail.authenticated"]="data.auth.authenticated_human"
    ["auth-detail.group"]="data.auth.group"
    ["auth-detail.blocked"]="data.auth.blocked_human"
    ["auth-detail.sessionid"]="data.auth.session_id"
    ["auth-detail.secureid"]="data.auth.secure_id"
    ["ip-cache.ip"]="data.ip.effective.ip"
    ["ip-cache.country"]="data.ip.effective.country"
    ["ip-cache.city"]="data.ip.effective.city"
    ["ip-public.ip"]="data.ip.public"
    ["ip-public.country"]="data.ip.country"
    ["ip-public.city"]="data.ip.city"
    ["random-ping"]="data.system.network.ping_ms"
    ["dns-cache.mode"]="data.dns.mode"
    ["dns-cache.ns1"]="data.dns.ns1"
    ["dns-cache.ns2"]="data.dns.ns2"
    ["dns-cache.ns3"]="data.dns.ns3"
    ["knet-status"]="data.online_info.knet"
    ["network-status.localip"]="data.system.network.local_ip"
    ["process-age.vpn"]="data.system.process_age.vpn.value"
    ["process-age.tor"]="data.system.process_age.tor.value"
    ["tor-exit.ip"]="data.ip.tor.ip"
    ["tor-exit.country"]="data.ip.tor.country"
    ["tor-status.onoff"]="data.tor.onoff"
    # Added 2026-09-05 (conky gap sweep). Keep in step with query.rs KEY_ALIASES.
    ["tor-status.pool"]="data.tor.instances_display"
    ["network-status.macrandom"]="data.system.network.mac_randomized_human"
    ["network-status.listen"]="data.system.network.listening.display"
    ["network-status.ipv6"]="data.system.network.ipv6_human"
    ["dns-cache.servers"]="data.dns.dnscrypt_servers_display"
    ["system-meta.ntp"]="data.system.os.ntp_human"
    ["runtime-detector.vpn-onoff"]="data.system.runtime.vpn.onoff"
    ["runtime-detector.firewall-onoff"]="data.system.runtime.firewall.onoff"
    ["runtime-detector.conky-vpn"]="data.system.runtime.vpn.conky"
    ["runtime-detector.conky-firewall"]="data.system.runtime.firewall.conky"
    ["ai-agents.list"]="data.system.runtime.ai.conky"
    ["crypto-price.btc"]="data.online_info.prices.btc"
    ["crypto-price.eth"]="data.online_info.prices.eth"
    ["crypto-price.xmr"]="data.online_info.prices.xmr"
    ["crypto-price.azero"]="data.online_info.prices.azero"
    ["crypto-price.xau"]="data.online_info.prices.xau"
    ["crypto-price.xag"]="data.online_info.prices.xag"
    ["version-check.binary"]="data.versions.binary.status"
    ["version-check.terminal"]="data.versions.terminal.status"
    ["version-check.desktop"]="data.versions.desktop.status"
    ["system-meta.files"]="data.system.os.files_count"
    ["system-meta.timezone"]="data.system.os.timezone"
    ["system-meta.resolution"]="data.system.os.resolution"
    ["system-meta.boot"]="data.system.os.boot"
    ["system-meta.mode"]="data.system.os.mode"
    ["system-meta.hostname"]="data.system.os.hostname"
    ["system-meta.kernel"]="data.system.os.kernel"
    ["system-meta.binary-cur"]="data.versions.binary.cur"
    ["system-meta.binary-on"]="data.versions.binary.on"
    ["system-meta.binary-nb"]="data.versions.binary.nb"
    ["system-meta.terminal-cur"]="data.versions.terminal.cur"
    ["system-meta.terminal-on"]="data.versions.terminal.on"
    ["system-meta.terminal-nb"]="data.versions.terminal.nb"
    ["system-meta.desktop-cur"]="data.versions.desktop.cur"
    ["system-meta.desktop-on"]="data.versions.desktop.on"
    ["system-meta.desktop-nb"]="data.versions.desktop.nb"
    ["system-status.nuke"]="data.system.system_security.nuke"
    ["system-status.autologin"]="data.system.system_security.autologin"
    ["system-status.diskenc"]="data.system.system_security.diskenc"
    ["system-status.swapenc"]="data.system.system_security.swapenc"
    ["system-status.swapcount"]="data.system.system_security.swapcount"
    ["system-status.swapperc"]="data.system.system_security.swapperc"
    ["net-traffic.iface"]="data.system.network.traffic.iface"
    ["net-traffic.up"]="data.system.network.traffic.up_kib_s"
    ["net-traffic.down"]="data.system.network.traffic.down_kib_s"
    ["net-traffic.totalup"]="data.system.network.traffic.totalup"
    ["net-traffic.totaldown"]="data.system.network.traffic.totaldown"
    ["net-traffic.totalbytes_up"]="data.system.network.traffic.totalup_bytes"
    ["net-traffic.totalbytes_down"]="data.system.network.traffic.totaldown_bytes"
    ["net-traffic.totalpercent"]="data.system.network.traffic.total_percent"
    ["cloud-status.users"]="data.online_info.cloud.users"
    ["cloud-status.tusers"]="data.online_info.cloud.tusers"
    ["cloud-status.challenges"]="data.online_info.cloud.challenges"
    ["cloud-status.cards"]="data.online_info.cloud.cards"
    ["cloud-status.digi77"]="data.online_info.cloud.digi77"
    ["cloud-status.kodachi_cloud"]="data.online_info.cloud.kodachi_cloud"
    ["security-status.auth"]="data.auth.authenticated"
    ["security-status.vpn"]="data.routing.connected"
    ["security-status.torrified"]="data.tor.torrified"
    ["security-status.dns"]="data.dns.dnscrypt_active"
)

# Fast path: read a value directly from the snapshot JSON without spawning
# the conky-status binary. Uses jq for extraction. Returns 1 if snapshot
# is stale/missing or key not found (caller falls back to binary).
_conky_snapshot_read() {
    local key="${1:-}"
    local allow_stale="${2:-false}"
    [[ -n "$key" ]] || return 1

    # user.* keys are computed on-the-fly by the binary, not in snapshot
    case "$key" in user.*) return 1 ;; esac

    # jq must be available for the fast path
    command -v jq >/dev/null 2>&1 || return 1

    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
    local snapshot_file="$config_base/kodachi/conky/data/conky-status.json"
    # READER TOLERANCE MUST EXCEED THE REFRESH TRIGGER, OR EVERY CYCLE HAS A
    # GUARANTEED SLOW-PATH WINDOW (fix 2026-08-17, VM-measured).
    #   focus-alert.sh only triggers a refresh once age > FOCUS_ALERT_GATEWAY_TTL (120)
    #   readers here counted the snapshot fresh only while age <= CONKY_GATEWAY_TTL (120)
    # Both thresholds were the SAME number, so the instant a refresh became
    # eligible was the instant reads started missing the fast path, and the
    # window lasted for the whole duration of the refresh it had just triggered.
    # Measured on testvm-kodachi-91fb5c: age cycled 113 -> 123 -> 133 -> 143 -> 4,
    # i.e. ~20-30s of every ~150s spent on the slow path, which spawns the binary
    # ONCE PER KEY (route-mode.sh alone asks for 12).
    # 180 puts the reader tolerance 60s above the trigger, comfortably clearing
    # the ~23s a full collection takes. This is SEMANTICALLY NEUTRAL: the slow
    # path returned this very same cached data anyway (`conky-status get` runs
    # with force_refresh=false and answers from stale_from_cached), so no
    # displayed value changes; only the per-key process spawns disappear.
    local ttl="${CONKY_GATEWAY_TTL:-180}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=180

    # Check snapshot exists and is within TTL
    [[ -s "$snapshot_file" ]] || return 1
    local now_ts file_ts age
    printf -v now_ts '%(%s)T' -1 2>/dev/null || now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    [[ "$file_ts" =~ ^[0-9]+$ ]] || return 1
    if [[ "$allow_stale" != "true" ]]; then
        age=$((now_ts - file_ts))
        (( age <= ttl )) || return 1
    fi

    # Resolve virtual key to JSON dot-path
    local json_path=""
    if [[ -n "${_CONKY_KEY_ALIASES[$key]+x}" ]]; then
        json_path="${_CONKY_KEY_ALIASES[$key]}"
    else
        case "$key" in
            data.*|meta.*|adapters.*) json_path="$key" ;;
            *) json_path="data.$key" ;;
        esac
    fi
    [[ -n "$json_path" ]] || return 1

    # Extract value with jq (single lightweight process)
    local value
    value=$(jq -r "
        .${json_path} as \$v |
        if \$v == null then \"__CONKY_NULL__\"
        else (\$v | tostring)
        end
    " "$snapshot_file" 2>/dev/null) || return 1

    [[ -n "$value" && "$value" != "__CONKY_NULL__" ]] || return 1
    printf '%s\n' "$value"
}

_conky_snapshot_fast_read() {
    _conky_snapshot_read "${1:-}" "false"
}

_conky_snapshot_stale_read() {
    _conky_snapshot_read "${1:-}" "true"
}

# True when the snapshot file exists and is within TTL. Used to distinguish a
# fast-path miss caused by a *stale* snapshot (fall through to the binary, which
# can refresh) from one caused by a *genuinely absent key* in a fresh snapshot
# (the binary would only re-read the same fresh cache and return the default,
# so spawning it per panel per cycle is pure waste). Requires jq so it only
# claims "fresh" when the fast path was actually attempted.
_conky_snapshot_is_fresh() {
    command -v jq >/dev/null 2>&1 || return 1
    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
    local snapshot_file="$config_base/kodachi/conky/data/conky-status.json"
    local ttl="${CONKY_GATEWAY_TTL:-180}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=180
    [[ -s "$snapshot_file" ]] || return 1
    local now_ts file_ts age
    printf -v now_ts '%(%s)T' -1 2>/dev/null || now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    [[ "$file_ts" =~ ^[0-9]+$ ]] || return 1
    age=$((now_ts - file_ts))
    (( age <= ttl ))
}

conky_gateway_effective_timeout() {
    local requested="${1:-3}"
    # Full conky-status refresh can exceed 20s when remote adapters are slow.
    # Keep defaults high enough so stale cache recovery can actually complete.
    # Keep warmup/refresh timeouts short to prevent process accumulation.
    # 49 execi calls × 30s timeout = 700MB+ memory; 5s caps it at ~120MB.
    local warmup_min="${CONKY_GATEWAY_WARMUP_TIMEOUT:-5}"
    local refresh_min="${CONKY_GATEWAY_REFRESH_TIMEOUT:-5}"
    local cache_ttl="${CONKY_GATEWAY_TTL:-180}"
    local snapshot_file

    [[ "$requested" =~ ^[0-9]+$ ]] || requested=3
    [[ "$warmup_min" =~ ^[0-9]+$ ]] || warmup_min=30
    [[ "$refresh_min" =~ ^[0-9]+$ ]] || refresh_min=30
    [[ "$cache_ttl" =~ ^[0-9]+$ ]] || cache_ttl=180

    snapshot_file="$(conky_gateway_snapshot_path)"
    if [[ ! -s "$snapshot_file" ]]; then
        if (( requested < warmup_min )); then
            requested="$warmup_min"
        fi
        echo "$requested"
        return 0
    fi

    local now_ts file_ts age
    now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    age=$((now_ts - file_ts))
    if (( age > cache_ttl )) && (( requested < refresh_min )); then
        requested="$refresh_min"
    fi

    echo "$requested"
}

conky_gateway_binary_healthy() {
    local bin="${1:-}"
    # Only check file existence + executable bit.
    # Eliminates 2 processes (timeout + conky-status --version) per call.
    # The binary is validated by the installer; runtime --version checks are wasteful.
    [[ -n "$bin" && -x "$bin" ]]
}

# Path of the cross-process memo for conky_gateway_find_binary. See that function.
_conky_bin_memo_file() {
    printf '%s/kodachi/conky/data/.conky-gateway-bin\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

conky_gateway_find_binary() {
    if [[ -n "${CONKY_GATEWAY_BIN_CACHE:-}" ]] && conky_gateway_binary_healthy "${CONKY_GATEWAY_BIN_CACHE:-}"; then
        echo "$CONKY_GATEWAY_BIN_CACHE"
        return 0
    fi

    # CROSS-PROCESS MEMO. CONKY_GATEWAY_BIN_CACHE above is a shell variable and every panel
    # script is a FRESH shell, so that cache has never survived a single invocation: the
    # candidate enumeration below ran on every call every panel made.
    #
    # Measured on testvm-kodachi-0425b0 (live <lab-host> beta) 2026-09-04, INTERLEAVED A/B/A/B,
    # 15 calls per block, 5 rounds, medians: 39 ms without the memo, 33 ms with it, and the
    # memo won every one of the 5 rounds. 25 panel scripts call this and the panels make
    # roughly 100 calls a minute, so it is worth about 0.6 CPU-seconds a minute.
    #
    # THE FIRST NUMBER I MEASURED FOR THIS WAS 45 ms AND IT WAS WRONG, which is worth leaving
    # here because the mistake is easy to repeat on these boxes. Sequential blocks (all of
    # "old", then all of "new") on a VM whose load moves between 3 and 10 attribute the load
    # drift to the change: the same script measured 200 ms in one block and 110 ms twenty
    # minutes later with no code difference at all. Only alternating the two variants inside
    # the same window cancels that, and it cut the apparent effect from 45 ms to 6 ms.
    # conky_gateway_binary_healthy is genuinely free (a [[ -x ]] builtin, no fork), so the
    # enumeration below is still the only cost here, it is just a smaller one than it looked.
    #
    # SEMANTICALLY NEUTRAL: the memo is re-validated on every read with the SAME
    # conky_gateway_binary_healthy the enumeration uses, so a binary that is moved, deleted or
    # made non-executable falls straight through to a full re-resolution, and so does a torn
    # or truncated read. The TTL bounds the one case validation cannot see: a HIGHER-priority
    # candidate appearing later. The ordering comment below is explicit that installed
    # binaries must outrank developer checkouts, and a memo of a lower candidate would
    # otherwise outlive that.
    local _memo_file _memo_ttl _memo_ts _memo_path _now
    _memo_file="$(_conky_bin_memo_file)"
    _memo_ttl="${CONKY_GATEWAY_BIN_CACHE_TTL:-300}"
    [[ "$_memo_ttl" =~ ^[0-9]+$ ]] || _memo_ttl=300
    if [[ -s "$_memo_file" ]]; then
        printf -v _now '%(%s)T' -1 2>/dev/null || _now=0
        _memo_ts=$(stat -c %Y "$_memo_file" 2>/dev/null || echo 0)
        if [[ "$_memo_ts" =~ ^[0-9]+$ ]] && (( _now > 0 )) && (( _now - _memo_ts <= _memo_ttl )); then
            IFS= read -r _memo_path < "$_memo_file" 2>/dev/null || _memo_path=""
            if conky_gateway_binary_healthy "$_memo_path"; then
                CONKY_GATEWAY_BIN_CACHE="$_memo_path"
                echo "$_memo_path"
                return 0
            fi
        fi
    fi

    if [[ -n "${KODACHI_CONKY_STATUS_BIN:-}" ]] && conky_gateway_binary_healthy "${KODACHI_CONKY_STATUS_BIN:-}"; then
        CONKY_GATEWAY_BIN_CACHE="$KODACHI_CONKY_STATUS_BIN"
        echo "$KODACHI_CONKY_STATUS_BIN"
        return 0
    fi

    local home_dir="${HOME:-}"
    local script_dir=""
    local conky_root=""
    local via_path=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        conky_root="$(cd "$script_dir/.." && pwd)"
    fi

    via_path=$(command -v conky-status 2>/dev/null || true)

    # Installed, installer-validated binaries must outrank developer checkouts.
    # A half-built checkout must never become the desktop status producer merely
    # because the installed binary is absent from PATH.
    local candidates=(
        "/opt/kodachi/dashboard/hooks/conky-status"
        "/usr/local/bin/conky-status"
    )
    if [[ -n "$via_path" ]]; then
        candidates+=("$via_path")
    fi

    if [[ -n "$home_dir" ]]; then
        candidates+=(
            "$home_dir/k900/dashboard/hooks/conky-status"
            "$home_dir/dashboard/hooks/conky-status"
            "$home_dir/Desktop/dashboard/hooks/conky-status"
        )
    fi
    if [[ -n "$conky_root" ]]; then
        candidates+=(
            "$conky_root/bin/conky-status"
        )
    fi
    local candidate
    for candidate in "${candidates[@]}"; do
        if conky_gateway_binary_healthy "$candidate"; then
            CONKY_GATEWAY_BIN_CACHE="$candidate"
            # Refresh the memo, best effort. Written in place rather than through a temp file
            # plus rename: the payload is one short line, and a reader that catches a torn
            # write simply fails conky_gateway_binary_healthy and re-resolves, which is the
            # same path a missing memo takes. A failure here (read-only home, full disk) must
            # never stop the caller getting its answer, hence the guards.
            conky_gateway_ensure_cache_dir 2>/dev/null || true
            printf '%s\n' "$candidate" > "$(_conky_bin_memo_file)" 2>/dev/null || true
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

conky_gateway_get() {
    local key="$1"
    local default_value="$2"
    local timeout_seconds="${3:-3}"
    local bin="${4:-}"
    local effective_timeout
    local cache_ttl="${CONKY_GATEWAY_TTL:-180}"

    [[ -n "$key" ]] || return 1
    [[ "$cache_ttl" =~ ^[0-9]+$ ]] || cache_ttl=180

    # Close the raw-get bypass at the shared choke point. Several callers use
    # this lower-level helper directly, so they must receive the same in-shell
    # fresh-snapshot behavior as get_or_default and multiline.
    local _fast_val
    if _fast_val=$(_conky_snapshot_fast_read "$key" 2>/dev/null); then
        printf '%s\n' "$_fast_val"
        return 0
    fi
    if [[ "$key" != user.* ]] && _conky_snapshot_is_fresh; then
        printf '%s\n' "$default_value"
        return 0
    fi

    if [[ -z "$bin" ]]; then
        bin=$(conky_gateway_find_binary) || {
            conky_gateway_log_error "binary not found" "$key"
            return 1
        }
    fi

    if [[ "$key" == user.* ]]; then
        [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=2
        effective_timeout="$timeout_seconds"
    else
        effective_timeout=$(conky_gateway_effective_timeout "$timeout_seconds")
    fi

    local error_output
    local result
    error_output=$(conky_gateway_mktemp_file)

    if result=$(timeout "$effective_timeout" "$bin" get "$key" "--default=$default_value" --ttl "$cache_ttl" 2>"$error_output"); then
        rm -f "$error_output"
        echo "$result"
        return 0
    else
        local exit_code=$?
        local error_msg
        error_msg=$(cat "$error_output" 2>/dev/null | head -n1)
        rm -f "$error_output"

        if [[ $exit_code -eq 124 ]]; then
            conky_gateway_log_error "timeout after ${effective_timeout}s" "$key"
        elif [[ -n "$error_msg" ]]; then
            conky_gateway_log_error "$error_msg" "$key"
        else
            conky_gateway_log_error "exit code $exit_code" "$key"
        fi
        return $exit_code
    fi
}

conky_gateway_get_or_default() {
    local key="$1"
    local default_value="$2"
    local timeout_seconds="${3:-3}"
    local bin="${4:-}"

    # Fast path: read directly from snapshot JSON (no binary spawn)
    local _fast_val
    if _fast_val=$(_conky_snapshot_fast_read "$key" 2>/dev/null); then
        printf '%s\n' "$_fast_val"
        return 0
    fi

    # Fresh-snapshot short-circuit: the fast path missed but the snapshot is
    # fresh, so this key is genuinely absent this cycle (e.g. online_info.* on a
    # box not attached to the VPS fleet, or any adapter during post-restore
    # warmup). The binary would serve the same fresh cache and return this very
    # default, so skip the per-panel spawn+timeout stampede. user.* keys are
    # computed live by the binary (not in the snapshot) and must still go there.
    if [[ "$key" != user.* ]] && _conky_snapshot_is_fresh; then
        echo "$default_value"
        return 0
    fi

    # Slow path: fall back to binary (snapshot stale/missing or user.* key)
    if [[ -z "$bin" ]]; then
        bin=$(conky_gateway_find_binary 2>/dev/null || true)
    fi

    if [[ -z "$bin" ]]; then
        conky_gateway_log_error "binary not found" "$key"
        # Last-resort: try a direct stale snapshot read so the conky panels
        # don't collapse to "Off"/"Offline" when the binary can't be found
        # (e.g. signature missing on one path while the other path is healthy
        # but not on PATH). The stale read uses jq directly on the JSON file.
        local _fallback_stale
        _fallback_stale=$(_conky_snapshot_stale_read "$key" 2>/dev/null | tr -d '\r' | head -n1 || true)
        if [[ -n "$_fallback_stale" ]]; then
            echo "$_fallback_stale"
        else
            echo "$default_value"
        fi
        return 0
    fi

    local value
    value=$(conky_gateway_get "$key" "$default_value" "$timeout_seconds" "$bin" | tr -d '\r' | head -n1)
    if [[ -z "$value" ]]; then
        local stale_value
        stale_value=$(_conky_snapshot_stale_read "$key" 2>/dev/null | tr -d '\r' | head -n1 || true)
        if [[ -n "$stale_value" ]]; then
            echo "$stale_value"
        else
            echo "$default_value"
        fi
    else
        echo "$value"
    fi
}

conky_gateway_get_multiline_or_default() {
    local key="$1"
    local default_value="$2"
    local timeout_seconds="${3:-3}"
    local bin="${4:-}"

    local _fast_val
    if _fast_val=$(_conky_snapshot_fast_read "$key" 2>/dev/null); then
        printf '%s\n' "$_fast_val"
        return 0
    fi

    # Fresh-snapshot short-circuit (see conky_gateway_get_or_default): a fresh
    # snapshot missing this key means it is genuinely absent, so return the
    # default instead of stampeding the binary. user.* stays on the slow path.
    if [[ "$key" != user.* ]] && _conky_snapshot_is_fresh; then
        printf '%s\n' "$default_value"
        return 0
    fi

    if [[ -z "$bin" ]]; then
        bin=$(conky_gateway_find_binary 2>/dev/null || true)
    fi

    if [[ -z "$bin" ]]; then
        conky_gateway_log_error "binary not found" "$key"
        local _fallback_stale_ml
        _fallback_stale_ml=$(_conky_snapshot_stale_read "$key" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$_fallback_stale_ml" ]]; then
            printf '%s\n' "$_fallback_stale_ml"
        else
            printf '%s\n' "$default_value"
        fi
        return 0
    fi

    local value
    value=$(conky_gateway_get "$key" "$default_value" "$timeout_seconds" "$bin" | tr -d '\r')
    if [[ -z "$value" ]]; then
        local stale_value
        stale_value=$(_conky_snapshot_stale_read "$key" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$stale_value" ]]; then
            printf '%s\n' "$stale_value"
        else
            printf '%s\n' "$default_value"
        fi
    else
        printf '%s\n' "$value"
    fi
}

conky_gateway_bool_01() {
    local raw="$1"
    raw=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)

    case "$raw" in
        1|true|on|yes|y)
            echo "1"
            ;;
        *)
            echo "0"
            ;;
    esac
}

conky_gateway_bool_onoff() {
    local raw="$1"
    raw=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)

    case "$raw" in
        1|true|on|yes|y)
            echo "On"
            ;;
        # AN UNKNOWN TOKEN IS NOT "Off". conky-status publishes "?" for a reading it
        # could not take (adapters/tor.rs, routing.rs, online_auth.rs, and "Unknown"
        # from dns.rs), and this case statement's catch-all used to turn every one of
        # them into a positive assertion of "off". Callers that cannot render a third
        # state should test for "Unknown" explicitly rather than have this helper lie
        # for them.
        \?|unknown|null|n/a|na|"")
            echo "Unknown"
            ;;
        *)
            echo "Off"
            ;;
    esac
}

# Get value with status indicator
conky_gateway_get_with_status() {
    local key="$1"
    local default_value="$2"
    local timeout_seconds="${3:-3}"
    local bin="${4:-}"
    local effective_timeout
    local cache_ttl="${CONKY_GATEWAY_TTL:-180}"

    if [[ -z "$bin" ]]; then
        bin=$(conky_gateway_find_binary 2>/dev/null || true)
    fi

    if [[ -z "$bin" ]]; then
        echo "$default_value ✗"
        return 0
    fi

    [[ "$cache_ttl" =~ ^[0-9]+$ ]] || cache_ttl=180
    effective_timeout=$(conky_gateway_effective_timeout "$timeout_seconds")

    local error_output
    local result
    error_output=$(conky_gateway_mktemp_file)

    if result=$(timeout "$effective_timeout" "$bin" get "$key" "--default=$default_value" --ttl "$cache_ttl" 2>"$error_output"); then
        rm -f "$error_output"
        echo "$result ✓"
        return 0
    else
        local exit_code=$?
        rm -f "$error_output"

        if [[ $exit_code -eq 124 ]]; then
            echo "$default_value ⚠"
        else
            echo "$default_value ✗"
        fi
        return $exit_code
    fi
}

# Get adapter health status
conky_gateway_adapter_status() {
    local adapter="$1"
    local bin="${2:-}"

    if [[ -z "$bin" ]]; then
        bin=$(conky_gateway_find_binary 2>/dev/null || true)
    fi

    if [[ -z "$bin" ]]; then
        echo "✗"
        return 0
    fi

    local status
    status=$(timeout 5 "$bin" snapshot --json --cached 2>/dev/null | jq -r ".adapters.$adapter.status" 2>/dev/null || echo "error")

    case "$status" in
        ok)
            echo "✓"
            ;;
        degraded)
            echo "⚠"
            ;;
        *)
            echo "✗"
            ;;
    esac
}

# Format value with appropriate color code for Conky
conky_gateway_with_color() {
    local value="$1"
    local status="${2:-ok}"  # ok, warn, error

    case "$status" in
        ok|online|on|active)
            echo "\${color green}$value\${color}"
            ;;
        warn|degraded|stale)
            echo "\${color yellow}$value\${color}"
            ;;
        error|offline|off|failed)
            echo "\${color red}$value\${color}"
            ;;
        *)
            echo "$value"
            ;;
    esac
}

# ============ MULTI-KEY SNAPSHOT READ ============
# ONE stat AND ONE jq FOR N KEYS, INSTEAD OF N OF EACH.
#
# WHY. Measured on testvm-kodachi-0425b0 (live <lab-host> beta), 2026-09-04, idle desktop:
# a single `conky_gateway_get_or_default` call costs ~322 ms and ~15 forks, and the panels
# make roughly 100 of them a minute. Broken down over 20-call blocks with the ambient fork
# rate subtracted: bash startup 31 ms, sourcing this file +21 ms, conky_gateway_find_binary
# +40 ms, jq alone 48 ms, and the rest inside the per-key path. The whole live image forks
# 5,180 processes a minute at idle on 4 vCPUs, and /proc/<pid>/stat cutime+cstime deltas
# attribute 73.4 CPU-seconds per minute of that to the four conky panels, 30.6% of the box.
# The cost is per KEY, so conkyrc-security.conf's 46 ${execi} directives pay it 46 times.
#
# The 2026-08-17 TTL fix in _conky_snapshot_read removed the per-key BINARY spawn. This
# removes the per-key STAT AND JQ for callers that want several keys at once, which is the
# only remaining per-key cost on the fast path.
#
# SEMANTICS ARE IDENTICAL TO CALLING conky_gateway_get_or_default PER KEY, deliberately:
# same TTL, same alias resolution, same user.* exclusion, same "absent means default".
# If the batch fast path cannot be served for ANY reason (jq missing, snapshot stale or
# absent, a user.* key present, jq itself failing) this falls back to the existing per-key
# function for every key, so behaviour can only ever be what it already was.
#
# Usage:  conky_gateway_get_many "<default>" key1 key2 ...
#         prints one line per key, in the order given, "<default>" where the key is absent.
conky_gateway_get_many() {
    local default_value="${1:-}"
    shift || return 1
    (( $# > 0 )) || return 0

    local keys=("$@")

    # Per-key fallback, used whenever the batch path is not applicable. Identical output to
    # what each caller would have got on its own.
    # The fallback forwards the caller's timeout and already-resolved binary, so a batch that
    # cannot be served costs exactly what the per-key calls it replaces cost: without them a
    # caller that had resolved $BIN once would re-resolve it once per key (live-ISO gap b25,
    # 2026-09-04, route-mode.sh: twelve resolutions instead of one on the stale-snapshot path).
    # CONKY_GATEWAY_MANY_TIMEOUT / CONKY_GATEWAY_MANY_BIN are read from the environment so the
    # positional signature stays "<default> key..." for every existing caller.
    _conky_many_fallback() {
        local k
        for k in "${keys[@]}"; do
            conky_gateway_get_or_default "$k" "$default_value" "${CONKY_GATEWAY_MANY_TIMEOUT:-3}" "${CONKY_GATEWAY_MANY_BIN:-}"
        done
    }

    command -v jq >/dev/null 2>&1 || { _conky_many_fallback; return 0; }

    # user.* keys are computed live by the binary and are never in the snapshot, so a batch
    # containing one cannot be served from the file at all.
    local k
    for k in "${keys[@]}"; do
        case "$k" in user.*) _conky_many_fallback; return 0 ;; esac
    done

    local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
    local snapshot_file="$config_base/kodachi/conky/data/conky-status.json"
    local ttl="${CONKY_GATEWAY_TTL:-180}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=180
    [[ -s "$snapshot_file" ]] || { _conky_many_fallback; return 0; }

    local now_ts file_ts age
    printf -v now_ts '%(%s)T' -1 2>/dev/null || now_ts=$(date +%s 2>/dev/null || echo 0)
    file_ts=$(stat -c %Y "$snapshot_file" 2>/dev/null || echo 0)
    [[ "$file_ts" =~ ^[0-9]+$ ]] || { _conky_many_fallback; return 0; }
    age=$((now_ts - file_ts))
    (( age <= ttl )) || { _conky_many_fallback; return 0; }

    # Resolve every key to its JSON dot-path with the SAME rules as _conky_snapshot_read,
    # then ask jq for all of them in one program. jq emits exactly one line per path.
    local -a paths=()
    local json_path
    for k in "${keys[@]}"; do
        if [[ -n "${_CONKY_KEY_ALIASES[$k]+x}" ]]; then
            json_path="${_CONKY_KEY_ALIASES[$k]}"
        else
            case "$k" in
                data.*|meta.*|adapters.*) json_path="$k" ;;
                *) json_path="data.$k" ;;
            esac
        fi
        [[ -n "$json_path" ]] || { _conky_many_fallback; return 0; }
        paths+=("$json_path")
    done

    local jq_program="" p
    for p in "${paths[@]}"; do
        # One output line per key. A null or missing path yields the sentinel, which is
        # translated to the caller's default below, exactly as the single-key path does.
        jq_program+=".${p} as \$v | (if \$v == null then \"__CONKY_NULL__\" else (\$v | tostring) end),"
    done
    jq_program="${jq_program%,}"

    local out
    out=$(jq -r "$jq_program" "$snapshot_file" 2>/dev/null) || { _conky_many_fallback; return 0; }

    # ANTI-VACUITY: jq must have produced exactly one line per key. A short read means the
    # program did not do what this function claims, and silently printing fewer values than
    # the caller asked for would shift every value it unpacks by one.
    local line_count
    line_count=$(printf '%s\n' "$out" | grep -c '' )
    if [[ "$line_count" -ne "${#keys[@]}" ]]; then
        _conky_many_fallback
        return 0
    fi

    printf '%s\n' "$out" | while IFS= read -r line; do
        if [[ -z "$line" || "$line" == "__CONKY_NULL__" ]]; then
            printf '%s\n' "$default_value"
        else
            printf '%s\n' "$line"
        fi
    done
}
