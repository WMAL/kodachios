#!/usr/bin/env bash

# conky-snapshot-memo.sh
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
# Last updated: 2026-09-30
#
# Description:
# SOURCED, never executed. Serves a panel script's previous output when nothing
# that script reads has changed since it was computed, with no process spawned.
#
# WHY (F19, measured 2026-09-30 on the live <lab-host> VM <lab-host>, idle
# desktop, dashboard minimized, not torrified): the conky stack cost 5,697
# forks/min and 47% CPU on 2 vCPUs against 1,269 forks/min and 19% with conky
# off. A bpftrace fork tree put 7,946 of the box's 12,588 forks in 120 s under
# conky. Every per-field script pays a bash startup, a `cd`/`dirname`
# subshell, conky_gateway_find_binary, and a stat plus jq per key, while the
# only thing it reads, the conky-status snapshot, is rewritten about every
# 90 s. And every `${execi}` that focus-alert.sh prints inside its
# `${execpi 10}` output is re-created on every re-parse, so its "17 s" and
# "120 s" intervals really fire every 10 s.
#
# WHY THE ANSWER IS IDENTICAL, not merely close:
#   * Only scripts whose output is a deterministic function of the snapshot
#     bytes, the snapshot's freshness, and their own arguments opt in (they
#     read through conky-gateway-common.sh only, never a user.* key, never the
#     clock, never another file unless it is declared in CONKY_MEMO_DEPS).
#   * conky-status writes every snapshot through a rename (cache.rs
#     write_snapshot) and builds every one with a new nanosecond
#     `meta.generated_at` (collector/mod.rs), so the first bytes of the file
#     identify its generation. A different generation is a miss.
#   * The gateway reads the file only while it is at most CONKY_GATEWAY_TTL
#     seconds old; past that it spawns the binary, which may refresh inline. A
#     memo is stored only for a snapshot that was fresh, and served only while
#     it is still fresh, so the stale path always runs the real script. Age is
#     taken from `generated_at`, which is set BEFORE the write, so it is never
#     younger than the mtime age the gateway uses: this errs toward running the
#     script, never toward serving a memo the gateway would not have served.
#   * The script, conky-gateway-common.sh and this file being newer than the
#     memo is a miss, so a deploy is picked up at once.
#   * CONKY_MEMO_MAX_AGE (default 120 s) bounds anything not listed above.
#   * Only exit status 0 is stored. Any doubt at all (no jq, no snapshot, a
#     header without a UTC generated_at, a relative script path, an unowned
#     memo directory) returns 1 and the caller runs its own body exactly as
#     before.
#
# A MISS COSTS AT MOST ONE EXTRA PROCESS. The caller's own body runs in the
# same process with its stdout captured into a private file (a redirection, not
# a fork); an EXIT trap prints the captured text to the real stdout and
# publishes it with one `mv`, or drops it with one `rm`. An opted-in script
# must therefore not set its own EXIT trap, `exec` another program, or leave a
# background job writing to stdout; none of the opted-in scripts does (checked
# 2026-09-30).
#
# Usage, at the top of an opted-in script, right after `set -u`:
#   if [[ -z "${CONKY_MEMO_INNER:-}" && -r "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" ]]; then
#       . "${BASH_SOURCE[0]%/*}/conky-snapshot-memo.sh" && conky_memo_run "${BASH_SOURCE[0]}" "$@"
#   fi
# conky_memo_run exits 0 on a hit. Otherwise it returns and the caller's body
# runs as before: captured for the memo (status 0) or untouched (status 1).
#
# Optional: CONKY_MEMO_DEPS=(file ...) before the call. The memo is also a miss
# when any listed file appears, disappears, or is newer than the memo.
# CONKY_MEMO_DISABLE=1 turns the whole thing off.

# UTC epoch seconds of the snapshot header's generated_at, pure arithmetic.
# conky-status writes chrono::Utc::now().to_rfc3339(), i.e. "...+00:00". Anything
# else returns 1, which the caller treats as "do not memoize".
_conky_memo_gen_epoch() {
    local -n _cm_ge_out="$1"
    local _cm_ge_re='"generated_at":"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|\+00:00)"'
    [[ "$2" =~ $_cm_ge_re ]] || return 1
    local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
    local hh=$((10#${BASH_REMATCH[4]})) mi=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
    local era yoe doy doe
    (( m <= 2 )) && y=$((y - 1))
    era=$(( (y >= 0 ? y : y - 399) / 400 ))
    yoe=$(( y - era * 400 ))
    doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
    doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    _cm_ge_out=$(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mi * 60 + ss ))
}

# EXIT trap armed by a miss: restore stdout, print what the body wrote, and
# publish it as the memo only when the body exited 0 and the snapshot generation
# did not change under the run and is still fresh.
_conky_memo_finish() {
    local _cm_rc="${1:-1}" _cm_content="" _cm_body _cm_hdr2="" _cm_now2=0 _cm_keep=0
    trap - EXIT
    exec 1>&"$_CONKY_MEMO_FD" {_CONKY_MEMO_FD}>&-
    IFS= read -r -d '' _cm_content < "$_CONKY_MEMO_TMP" 2>/dev/null
    _cm_body="${_cm_content#*$'\n'}"
    _cm_body="${_cm_body#*$'\n'}"
    _cm_body="${_cm_body#*$'\n'}"
    printf '%s' "$_cm_body"
    if [[ "$_cm_rc" == "0" && "$_cm_content" == "KODACHI-CONKY-MEMO-2"$'\n'* ]]; then
        IFS= read -r -N 160 _cm_hdr2 < "$_CONKY_MEMO_SNAP" 2>/dev/null
        printf -v _cm_now2 '%(%s)T' -1 2>/dev/null || _cm_now2=0
        if [[ "$_cm_hdr2" == "$_CONKY_MEMO_HDR" ]] && (( _cm_now2 - _CONKY_MEMO_GEN <= _CONKY_MEMO_TTL )); then
            _cm_keep=1
        fi
    fi
    if (( _cm_keep )); then
        mv -f "$_CONKY_MEMO_TMP" "$_CONKY_MEMO_FILE" 2>/dev/null || rm -f "$_CONKY_MEMO_TMP" 2>/dev/null
    else
        rm -f "$_CONKY_MEMO_TMP" 2>/dev/null
    fi
    exit "$_cm_rc"
}

conky_memo_run() {
    local _cm_script="${1:-}"
    shift || return 1
    [[ "${CONKY_MEMO_DISABLE:-0}" == "1" ]] && return 1
    [[ -n "$_cm_script" && "$_cm_script" == /* && -r "$_cm_script" ]] || return 1
    # The gateway fast path needs jq; without it every read goes to the binary.
    type -P jq >/dev/null 2>&1 || return 1

    local _cm_snap="${XDG_CONFIG_HOME:-$HOME/.config}/kodachi/conky/data/conky-status.json"
    [[ -s "$_cm_snap" ]] || return 1

    local _cm_ttl="${CONKY_GATEWAY_TTL:-180}"
    [[ "$_cm_ttl" =~ ^[0-9]+$ ]] || _cm_ttl=180
    local _cm_max="${CONKY_MEMO_MAX_AGE:-120}"
    [[ "$_cm_max" =~ ^[0-9]+$ ]] || _cm_max=120

    local _cm_dir
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
        _cm_dir="${XDG_RUNTIME_DIR}/kodachi-conky-memo"
    else
        _cm_dir="/tmp/kodachi-conky-memo-${EUID}"
    fi

    local _cm_hdr=""
    IFS= read -r -N 160 _cm_hdr < "$_cm_snap" 2>/dev/null
    [[ "$_cm_hdr" == *generated_at* && "$_cm_hdr" != *$'\n'* ]] || return 1
    local _cm_gen=0
    _conky_memo_gen_epoch _cm_gen "$_cm_hdr" || return 1
    # Round 3b (inspector B, V8): a snapshot generated at or before the last Kodachi state
    # change is never memoized nor answered from a memo, because the gateway reads it as a
    # miss (conky-gateway-common.sh _conky_snapshot_times) and a memo of it would replay the
    # pre-change panel. Builtin read only, so the hit path still spawns nothing; a missing or
    # garbage stamp reads as 0. The ownership check is the gateway's: honouring an untrusted
    # stamp here can only skip the memo, never serve a value.
    local _cm_stamp="" _cm_stamp_rest=""
    { IFS=' ' read -r _cm_stamp _cm_stamp_rest < /run/kodachi/state-changed-at; } 2>/dev/null || true
    [[ "$_cm_stamp" =~ ^[0-9]{1,18}$ ]] || _cm_stamp=0
    (( _cm_gen > 10#$_cm_stamp )) || return 1

    local _cm_key="${_cm_script##*/}" _cm_a
    for _cm_a in "$@"; do
        _cm_key+="__${#_cm_a}_${_cm_a//[^A-Za-z0-9_.-]/_}"
    done
    # djb2 over the script's FULL path and any declared dependency paths, so two
    # installed copies of one script (~/.config/... and /usr/share/...) and two
    # callers declaring different files (KODACHI_BUILD_META_FILE differs per caller)
    # never share an entry.
    local _cm_depsig="" _cm_d _cm_joined="$_cm_script"$'\x1f' _cm_h=5381 _cm_i _cm_c
    if declare -p CONKY_MEMO_DEPS >/dev/null 2>&1; then
        for _cm_d in "${CONKY_MEMO_DEPS[@]}"; do
            [[ -n "$_cm_d" ]] || continue
            if [[ -e "$_cm_d" ]]; then _cm_depsig+="1"; else _cm_depsig+="0"; fi
            _cm_joined+="$_cm_d"$'\x1f'
        done
    fi
    for ((_cm_i = 0; _cm_i < ${#_cm_joined}; _cm_i++)); do
        printf -v _cm_c '%d' "'${_cm_joined:_cm_i:1}"
        _cm_h=$(( (_cm_h * 33 + _cm_c) & 0xFFFFFFFF ))
    done
    _cm_key+="__p${_cm_h}"
    local _cm_file="$_cm_dir/$_cm_key"

    local _cm_now
    printf -v _cm_now '%(%s)T' -1 2>/dev/null || return 1
    [[ "$_cm_now" =~ ^[0-9]+$ ]] || return 1
    # A snapshot past the gateway TTL sends the gateway to the binary: never memoize.
    (( _cm_now - _cm_gen <= _cm_ttl )) || return 1

    # ---- hit path: builtins only ----
    if [[ -d "$_cm_dir" && -O "$_cm_dir" && ! -L "$_cm_dir" && -f "$_cm_file" && -O "$_cm_file" ]]; then
        local _cm_l1="" _cm_l2="" _cm_l3="" _cm_body="" _cm_at _cm_rc _cm_sig _cm_valid=1
        {
            IFS= read -r _cm_l1
            IFS= read -r _cm_l2
            IFS= read -r _cm_l3
            IFS= read -r -d '' _cm_body
        } < "$_cm_file" 2>/dev/null
        read -r _cm_at _cm_rc _cm_sig <<< "$_cm_l3"
        [[ "$_cm_l1" == "KODACHI-CONKY-MEMO-2" && "$_cm_l2" == "$_cm_hdr" ]] || _cm_valid=0
        [[ "${_cm_at:-}" =~ ^[0-9]+$ && "${_cm_rc:-}" == "0" ]] || _cm_valid=0
        [[ "${_cm_sig:-x}" == "x$_cm_depsig" ]] || _cm_valid=0
        if (( _cm_valid )); then
            (( _cm_now >= _cm_at && _cm_now - _cm_at < _cm_max )) || _cm_valid=0
        fi
        if (( _cm_valid )); then
            [[ "$_cm_script" -nt "$_cm_file" ]] && _cm_valid=0
            [[ "${_cm_script%/*}/conky-gateway-common.sh" -nt "$_cm_file" ]] && _cm_valid=0
            [[ "${BASH_SOURCE[0]}" -nt "$_cm_file" ]] && _cm_valid=0
            if declare -p CONKY_MEMO_DEPS >/dev/null 2>&1; then
                for _cm_d in "${CONKY_MEMO_DEPS[@]}"; do
                    [[ -n "$_cm_d" && "$_cm_d" -nt "$_cm_file" ]] && _cm_valid=0
                done
            fi
        fi
        if (( _cm_valid )); then
            printf '%s' "$_cm_body"
            exit 0
        fi
    fi

    # ---- miss path: arm the capture; the caller's body runs in THIS process ----
    if [[ ! -d "$_cm_dir" ]]; then
        mkdir -m 700 "$_cm_dir" 2>/dev/null || true
    fi
    [[ -d "$_cm_dir" && -O "$_cm_dir" && ! -L "$_cm_dir" ]] || return 1
    _CONKY_MEMO_TMP="$_cm_dir/.$_cm_key.$$"
    _CONKY_MEMO_FILE="$_cm_file"
    _CONKY_MEMO_HDR="$_cm_hdr"
    _CONKY_MEMO_SNAP="$_cm_snap"
    _CONKY_MEMO_TTL="$_cm_ttl"
    _CONKY_MEMO_GEN="$_cm_gen"
    printf 'KODACHI-CONKY-MEMO-2\n%s\n%s 0 x%s\n' "$_cm_hdr" "$_cm_now" "$_cm_depsig" \
        > "$_CONKY_MEMO_TMP" 2>/dev/null || return 1
    exec {_CONKY_MEMO_FD}>&1 || return 1
    if ! exec 1>>"$_CONKY_MEMO_TMP"; then
        exec {_CONKY_MEMO_FD}>&-
        return 1
    fi
    trap '_conky_memo_finish "$?"' EXIT
    return 0
}
