#!/bin/bash

# Kodachi OS Debug Collector
# ======================================================
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
# Last updated: 2026-09-17
# Collector version: 1.8
#
# Description:
# Collects comprehensive system diagnostics for remote troubleshooting
# of Kodachi OS installations. Gathers boot logs, hardware info, network
# configuration, Kodachi service status, LUKS/nuke state, and more.
# All data is packaged into a zip file on the user's Desktop.
#
# Privacy:
# This script does NOT collect browsing history or home folder contents.
# Only system/service diagnostics are collected, and before packaging every
# text file is redacted of: routable IP addresses, MAC addresses, WiFi
# names and credentials, keys and tokens, geolocation fields, current and
# previous hostnames, human account names and full names, and location data
# (time zone region, country, locale; the UTC offset and character set are
# kept). A login or host name that is very short or an ordinary word is
# redacted only where the text marks it as one, not in free prose.
#
# Links:
# - Website: https://www.digi77.com
# - Website: https://www.kodachi.cloud
# - GitHub: https://github.com/WMAL
# - Discord: https://discord.gg/KEFErEx
# - LinkedIn: https://om.linkedin.com/in/warith1977
# - X (Twitter): https://x.com/warith2020
#
# Usage:
#   # Run with sudo (required for system log access)
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-debug-collector.sh | sudo bash
#
#   # or for fully automated
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-debug-collector.sh | sudo bash -s -- --all
#
#   # Or run locally
#   sudo bash kodachi-debug-collector.sh
#
#   # Skip interactive menu (collect everything)
#   sudo bash kodachi-debug-collector.sh --all
#
# Output:
#   ~/Desktop/kodachi-debug-YYYYMMDD-HHMMSS-<random id>.zip
#   (v1.8: the hostname is no longer part of the name, see COLLECTION_NAME)
#
# ======================================================

set -Eo pipefail

# The documented invocation is `curl ... | sudo bash -s -- --all`, i.e. bash
# reads THIS SCRIPT FROM STDIN, one byte at a time, so that child processes see
# the rest of the stream. Any child that reads stdin therefore eats the rest of
# the script and bash exits 0 at the spot it stopped, with no error at all.
#
# Measured 2026-09-06 on an installed Kodachi VM (<agent>): the served
# copy stopped after step [5/16] "Collecting Tor information" with exit 0 and no
# zip. The culprit was `ausearch -m AVC,USER_AVC -ts today` in that step, which
# reads its input from stdin whenever stdin is not a tty. Kodachi ships auditd,
# so EVERY user who followed the documented command got nothing, silently, and
# the EXIT trap then removed the staging directory. Proven with a control:
#   printf 'a\nb\n' | { ausearch -m AVC -ts today; cat | wc -l; }   -> 0 lines
#   ...            | { ausearch ...   </dev/null; cat | wc -l; }   -> 2 lines
#
# Two defences, both needed. The whole body lives in main() and is invoked on
# the LAST line, so bash has parsed the entire script before a single command
# runs and nothing is left on stdin to steal. And every helper that runs a
# collected command gives it </dev/null explicitly, so the same class cannot
# come back through a locally-run copy whose stdin is a terminal.
if [[ "$(id -u)" != "0" ]]; then
    echo "This collector must run as root, because most of what it gathers (journal," >&2
    echo "auth log, LUKS state, Kodachi hook results) is unreadable otherwise." >&2
    echo "  sudo bash kodachi-debug-collector.sh --all" >&2
    echo "  curl -sSL https://kodachi.cloud/apps/os/install/kodachi-debug-collector.sh | sudo bash -s -- --all" >&2
    exit 1
fi

main() {

COLLECTOR_VERSION="1.9"
INVOKED_AS="$0"
INVOKED_ARGS="$*"
if [[ -f "$0" ]]; then
    SCRIPT_SOURCE="file $0 (md5 $(md5sum < "$0" 2>/dev/null | cut -c1-32))"
else
    SCRIPT_SOURCE="stdin (piped, e.g. curl | sudo bash -s)"
fi
RUN_T0=$(date +%s)
RUN_STARTED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- CLI argument parsing ----
SKIP_MENU=0
for arg in "$@"; do
    case "$arg" in
        --all|--no-interactive) SKIP_MENU=1 ;;
    esac
done

# ---- Category selection state ----
CAT_ENABLED=(1 1 1 1 1 1 1 1 1 1 1 1 1)
CAT_LABEL=(
    "Kodachi Meta"
    "Boot & System Logs"
    "Hardware Info"
    "Network Config"
    "Tor"
    "VPN"
    "Kodachi Services"
    "Installation"
    "Display & Desktop"
    "Performance"
    "Security"
    "Live System"
    "System Config"
)
CAT_DESC=(
    "Version, live/installed, LUKS, nuke status"
    "dmesg, journalctl, failed services, syslog"
    "CPU cores, RAM, SSD/HDD, GPU, disk space"
    "Routes, firewall rules, DNS, ports"
    "Tor status, logs, config (redacted)"
    "OpenVPN/WireGuard status and logs"
    "Binary versions, service logs and results"
    "Installer logs, EFI boot, initramfs, packages"
    "Xorg, display manager, screen resolution"
    "Processes, CPU/memory/IO load"
    "AppArmor status, login history"
    "Mount points, persistence, fstab"
    "Locale, timezone, GRUB config"
)

# Progress counter (set dynamically after menu)
STEP=0
TOTAL_STEPS=16

# Detect real user (even when run via sudo)
detect_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${USER:-}" ]] && [[ "$USER" != "root" ]]; then
        echo "$USER"
    else
        # Fallback: detect from console login. NOTE: who can succeed with
        # EMPTY output (headless/ssh-root), which used to leave REAL_USER
        # blank and pollute / with a /Desktop dir; test the value, not rc.
        local from_who
        from_who=$(who | awk 'NR==1{print $1}')
        if [[ -n "$from_who" ]]; then
            echo "$from_who"
        else
            echo "kodachi"
        fi
    fi
}

REAL_USER=$(detect_real_user)
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DESKTOP_DIR="${REAL_HOME}/Desktop"

# Ensure Desktop directory exists. The collector runs as root, so a Desktop
# that IT creates would be root-owned and the user could no longer write to
# their own Desktop afterwards. Only chown when this script created it.
if [[ ! -d "$DESKTOP_DIR" ]]; then
    mkdir -p "$DESKTOP_DIR"
    if [[ "$(id -u)" == "0" ]] && [[ -n "${REAL_USER:-}" ]] && [[ "$REAL_USER" != "root" ]]; then
        chown "${REAL_USER}:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" \
            "$DESKTOP_DIR" 2>/dev/null || true
    fi
fi

# Create temp collection directory
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
HOSTNAME=$(hostname)
TEMP_DIR=$(mktemp -d -t kodachi-debug-XXXXXX)
[[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] || { echo "Cannot create a staging directory under ${TMPDIR:-/tmp} (full?)" >&2; exit 1; }

# v1.7: every collected command and every step is timed into these two files,
# which land in 00-metadata/. When a run hangs or takes 26 minutes (measured
# 2026-09-06, the redactor on a 1.1 MB single-line catalog), the timing file is
# what says WHICH command, without anyone having to reproduce it.
CMD_TIMING_LOG="${TEMP_DIR}/.command-timing.txt"
STEP_TIMING_LOG="${TEMP_DIR}/.step-timing.txt"
: > "$CMD_TIMING_LOG"
: > "$STEP_TIMING_LOG"

# Remove the staging tree on ANY exit, not only the happy path. Observed
# 2026-08-19: a run interrupted by a dropped SSH session left
# /tmp/kodachi-debug-XXXXXX behind holding the whole partially-collected
# tree, which on an installed machine reaches ~150 MB. Repeated support
# sessions therefore filled /tmp, and on a live ISO /tmp is RAM.
# The zip is written to the Desktop before this fires, so a completed run
# keeps its bundle; only the staging copy goes.
cleanup_temp_dir() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR" 2>/dev/null || true
    fi
}
# v1.7: an interrupted run used to take its timing evidence down with the
# staging tree, so a user who Ctrl-C'd a stall had nothing to show which
# command stalled. The step and command timings are saved next to where the
# zip would have gone, then the staging tree is removed as before.
save_interrupt_evidence() {
    local f="${DESKTOP_DIR}/${COLLECTION_NAME:-kodachi-debug}-INTERRUPTED.txt"
    [[ -n "${STEP_TIMING_LOG:-}" ]] || return 0
    command -v redact_secrets >/dev/null 2>&1 || return 0
    {
        echo "Kodachi debug collector INTERRUPTED at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "during step ${STEP:-?}: ${STEP_LABEL:-}"
        echo ""
        echo "Step timing so far:"
        cat "$STEP_TIMING_LOG" 2>/dev/null
        echo ""
        echo "Last 25 commands / copies (seconds, rc, command):"
        tail -25 "$CMD_TIMING_LOG" 2>/dev/null
    } 2>/dev/null | redact_secrets > "$f" 2>/dev/null || return 0
    [[ -s "$f" ]] || { rm -f "$f" 2>/dev/null; return 0; }
    chown "${REAL_USER}:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$f" 2>/dev/null \
        || chown "${REAL_USER}" "$f" 2>/dev/null || true
    echo "" >&2
    echo "Interrupted. Timing evidence saved to: $f" >&2
}
trap cleanup_temp_dir EXIT
trap 'save_interrupt_evidence; cleanup_temp_dir; exit 130' INT
trap 'save_interrupt_evidence; cleanup_temp_dir; exit 143' TERM

# v1.8: the name used to be kodachi-debug-<hostname>-<timestamp>. That put the
# raw hostname in the zip file name, in the top directory of EVERY entry inside
# the zip, and in the -INTERRUPTED.txt name, none of which the redactor can
# reach, while the same name was redacted inside every text file. A short
# random id keeps two runs in the same second apart.
KDC_RUN_ID=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[[ "$KDC_RUN_ID" =~ ^[0-9a-f]{6}$ ]] || KDC_RUN_ID="p$$"
COLLECTION_NAME="kodachi-debug-${TIMESTAMP}-${KDC_RUN_ID}"
COLLECTION_DIR="${TEMP_DIR}/${COLLECTION_NAME}"
ZIP_FILE="${DESKTOP_DIR}/${COLLECTION_NAME}.zip"

mkdir -p "$COLLECTION_DIR"

# Progress indicator
# v1.7: a dim sub-step line inside the long steps, so a user watching the
# terminal can tell a 5-minute log copy from a hang.
substep() {
    echo -e "    ${CYAN}-${NC} $1"
}

progress() {
    local now
    now=$(date +%s)
    if [[ -n "${STEP_T0:-}" ]] && [[ -n "${STEP_TIMING_LOG:-}" ]]; then
        printf '%5ds  step %2s  %s\n' "$((now - STEP_T0))" "$STEP" "${STEP_LABEL:-}" >> "$STEP_TIMING_LOG" 2>/dev/null || true
    fi
    STEP=$((STEP + 1))
    STEP_T0=$now
    STEP_LABEL="$1"
    echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}]${NC} $1 ${CYAN}(${NC}$((now - RUN_T0))s elapsed${CYAN})${NC}"
}

# ---- Redaction manifest ----------------------------------------------------
# Every helper below already writes its output THROUGH redact_secrets, and the
# final sweep then redacted all of it a SECOND time. On an ordinary installed
# machine that means re-processing the whole boot journal, auth.log and syslog
# for no change at all. Measured 2026-08-19 on an installed VM: 148 MB of
# collected text and the run had still not finished after 15 minutes.
#
# The manifest records each file's size at the moment it was redacted. The
# sweep skips a file only when its size is UNCHANGED, so anything appended
# raw afterwards is still swept: the optimisation is fail-closed, an unknown
# or moved file is always redacted again.
#
# It lives in TEMP_DIR and never in COLLECTION_DIR, so it cannot enter the zip.
REDACTED_MANIFEST="${TEMP_DIR}/.redacted-manifest"
: > "$REDACTED_MANIFEST"

declare -A REDACTED_OK=()

mark_redacted() {
    local f="$1" sz
    [[ -f "$f" ]] || return 0
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    REDACTED_OK["$f"]="$sz"
    printf '%s\t%s\n' "$sz" "$f" >> "$REDACTED_MANIFEST"
}

# Provenance guard for the append-style helpers.
#
# The manifest lets the final sweep skip a file, so a file may only be marked
# when EVERY byte in it arrived through redact_secrets. safe_exec appends, so
# if some earlier RAW write had already put unredacted bytes in the same file,
# marking it afterwards would skip those bytes forever.
#
# A source audit on 2026-08-19 found exactly one path written both ways
# (03-network/resolvectl.txt) and its two writers are mutually exclusive
# if/else branches, so the hole is not reachable today. This guard makes that
# a property of the CODE rather than of that audit: the file is marked only
# when it was empty before the append, or when the size it had before the
# append is exactly the size this run last recorded as fully redacted.
#
# Round 2 (inspector F9): the guard originally covered 2 of the 5 places that
# mark a file, and the other 3 were argued safe because each is preceded by a
# truncating ">". That is the same audit-shaped reasoning this guard exists to
# replace, and it silently stops being true the day someone changes a ">" to a
# ">>". All 5 now go through should_mark. The failure mode is fail-CLOSED and
# costs only work: an unmarked file is swept again, never skipped wrongly.
should_mark() {
    local f="$1" pre="$2"
    [[ "$pre" == "0" ]] && return 0
    [[ "${REDACTED_OK[$f]:-}" == "$pre" ]] && return 0
    return 1
}

# Safe command execution with error handling.
# The output is streamed through a spool file instead of being captured into a
# shell variable: `journalctl -b` alone produced 30 MB on the measurement VM,
# and $(...) holds a full copy of that in the shell's heap before redaction
# even starts, then a second copy for the redacted result.
safe_exec() {
    local output_file="$1"
    shift
    local cmd="$*"
    local rc spool pre=0

    [[ -f "$output_file" ]] && pre=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
    spool="${TEMP_DIR}/.safe_exec.$$"
    # v1.7: the command runs in its own bash under `timeout`, with stdin from
    # /dev/null. Three properties, each of which has already cost a bundle:
    #   stdin=/dev/null  a child can no longer read the script off the curl pipe
    #                    (ausearch did, see the header) or block on a terminal.
    #   timeout          one hung probe (dig with no route, a binary waiting on
    #                    a lock, a network status call on an offline machine) can
    #                    no longer stall the whole collection; the file records
    #                    [TIMEOUT] and the run moves on. KDC_CMD_TIMEOUT
    #                    overrides the default per call.
    #   own group        `timeout` runs the command in its own process group and
    #                    kills the GROUP on expiry, so a pipeline's stuck member
    #                    does not survive as an orphan.
    # Shell functions used inside command strings (redact_secrets) are exported.
    local t0 t1
    t0=$(date +%s.%N)
    timeout -k 10 "${KDC_CMD_TIMEOUT:-180}" bash -c "$cmd" < /dev/null > "$spool" 2>&1
    rc=$?
    t1=$(date +%s.%N)

    local redacted_cmd
    redacted_cmd=$(printf '%s\n' "$cmd" | redact_secrets)
    [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8.2fs rc=%-3s %s\n' "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" "$rc" "$redacted_cmd" >> "$CMD_TIMING_LOG" 2>/dev/null

    if [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; then
        echo "[TIMEOUT after ${KDC_CMD_TIMEOUT:-180}s, killed] Command: $redacted_cmd" >> "$output_file"
        [[ -s "$spool" ]] && redact_bounded < "$spool" >> "$output_file"
    elif [[ $rc -ne 0 ]]; then
        echo "[EXIT CODE: $rc] Command failed: $redacted_cmd" >> "$output_file"
        [[ -s "$spool" ]] && redact_bounded < "$spool" >> "$output_file"
    elif [[ ! -s "$spool" ]]; then
        echo "[EXIT CODE: 0] Command produced no output: $redacted_cmd" >> "$output_file"
    else
        redact_bounded < "$spool" >> "$output_file"
    fi
    rm -f "$spool" 2>/dev/null || true
    should_mark "$output_file" "$pre" && mark_redacted "$output_file"
}

# Safe file copy with size check
safe_copy() {
    local src="$1"
    local dest="$2"
    local max_size=$((50 * 1024 * 1024)) # 50MB

    if [[ ! -f "$src" ]]; then
        echo "File not found: $src" > "${dest}/$(basename "$src").missing"
        return
    fi

    local file_size
    file_size=$(stat -c%s "$src" 2>/dev/null || echo 0)

    local _ct0 _ct1
    _ct0=$(date +%s.%N)
    if [[ $file_size -gt $max_size ]]; then
        # Truncate large files, then redact private identifiers/secrets.
        local _pt=0; [[ -f "${dest}/$(basename "$src").truncated" ]] && _pt=$(stat -c%s "${dest}/$(basename "$src").truncated" 2>/dev/null || echo 0)
        tail -c 50M "$src" 2>/dev/null | redact_bounded > "${dest}/$(basename "$src").truncated" 2>/dev/null || true
        echo "Original file size: $file_size bytes (truncated to last 50MB, redacted)" >> "${dest}/$(basename "$src").truncated"
        should_mark "${dest}/$(basename "$src").truncated" "$_pt" && mark_redacted "${dest}/$(basename "$src").truncated"
    else
        local _pc=0; [[ -f "${dest}/$(basename "$src")" ]] && _pc=$(stat -c%s "${dest}/$(basename "$src")" 2>/dev/null || echo 0)
        redact_bounded < "$src" > "${dest}/$(basename "$src")" 2>/dev/null || echo "Failed to copy: $src" > "${dest}/$(basename "$src").error"
        should_mark "${dest}/$(basename "$src")" "$_pc" && mark_redacted "${dest}/$(basename "$src")"
    fi
    _ct1=$(date +%s.%N)
    [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8.2fs rc=%-3s [copy %s bytes] %s\n' "$(awk -v a="$_ct0" -v b="$_ct1" 'BEGIN{print b-a}')" "0" "$file_size" "$src" >> "$CMD_TIMING_LOG" 2>/dev/null
}

# ---- Credential redaction (defense-in-depth) ----
# audit 2026-05-17 (Conference-Room-A bundle): hooks-results/hooks-config/
# hooks-logs were copied with NO or incomplete redaction, leaking live
# routing secrets (cached_card_*.json contained an OpenVPN private key,
# WireGuard keys, a password, and hysteria2:// / ss:// URIs). This filter
# is applied to EVERY Kodachi config/result/log file before it enters the
# bundle. It over-redacts on purpose, privacy beats completeness here.
#
# awk handles multi-line secret blocks (PEM keys, OpenVPN inline <key>/
# <tls-crypt>/<tls-auth>/<static> tags); sed handles single-line key/value,
# WireGuard keys, auth-user-pass, and credential-bearing proxy URIs.
# Patterns avoid gawk-only IGNORECASE so this works under Debian's mawk.
redact_secrets() {
    # v1.7 (2026-09-06): every stage runs under LC_ALL=C. In a UTF-8 locale GNU
    # sed and gawk treat the record as multibyte CHARACTERS, so on a long single
    # line every substr/length/regex step re-walks the bytes from the start and
    # the cost goes quadratic. Measured on a 1.39 MB one-line JSON (the
    # kodachi-soc snapshot): sed 50.5s -> 0.25s, gawk 12.1s -> 0.36s, output
    # byte-identical (checked with cmp on that file, on a 43 MB journal, and on
    # a synthetic set with 24,000 addresses). Every rule below is ASCII, so the
    # C locale changes no match; non-ASCII bytes pass through untouched.
    LC_ALL=C awk '
    BEGIN { inblock = 0; blocklines = 0 }
    {
        if (inblock) {
            if ($0 ~ /-----END / || $0 ~ /^[ \t]*<\/(key|cert|ca|tls-crypt|tls-crypt-v2|tls-auth|static)>/) {
                print $0; inblock = 0; blocklines = 0
                next
            }
            blocklines++
            if (blocklines <= 200) { print "[REDACTED]"; next }
            # audit 2026-08-19: an UNTERMINATED block used to redact every
            # remaining line of the file. safe_copy produces exactly that
            # shape routinely (tail -c 50M can start mid-key), so one
            # truncated key destroyed the whole diagnostic tail instead of
            # one secret. No real PEM or inline OpenVPN key is 200 lines.
            print "[REDACTION: unterminated key block, line-by-line redaction resumed]"
            inblock = 0; blocklines = 0
        }
        # Whole secret block already on ONE physical line (JSON-escaped with
        # literal \n, single-line .ovpn fragment, etc.): do NOT enter
        # multi-line mode (that would over-redact the rest of the file and
        # the print $0 would emit the key). Leave it to the sed single-line
        # collapse rules below.
        if ( ($0 ~ /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/ && $0 ~ /-----END [A-Z0-9 ]*PRIVATE KEY-----/) || \
             ($0 ~ /-----BEGIN OpenVPN Static key/ && $0 ~ /-----END OpenVPN Static key/) || \
             ($0 ~ /<(key|tls-crypt|tls-crypt-v2|tls-auth|static)>/ && $0 ~ /<\/(key|tls-crypt|tls-crypt-v2|tls-auth|static)>/) ) {
            print $0; next
        }
        if ($0 ~ /-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----/ || $0 ~ /-----BEGIN OpenVPN Static key/) {
            print $0; print "[REDACTED]"; inblock = 1; blocklines = 0; next
        }
        if ($0 ~ /^[ \t]*<(key|tls-crypt|tls-crypt-v2|tls-auth|static)>/) {
            print $0; print "[REDACTED]"; inblock = 1; blocklines = 0; next
        }
        print $0
    }' | LC_ALL=C sed -E '
        # JSON-safe: bound block collapses with [^"] so a PEM/inline tag
        # inside ONE JSON string value cannot swallow the closing quote and
        # the following keys (the greedy .* form corrupted cached_card JSON).
        # Flat .conf/.ovpn files have no " so [^"]* still spans the block.
        s/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[^"]*-----END [A-Z0-9 ]*PRIVATE KEY-----/[REDACTED-KEY-BLOCK]/Ig
        s/-----BEGIN OpenVPN Static key[^"]*-----END OpenVPN Static key[A-Za-z0-9 ]*-----/[REDACTED-KEY-BLOCK]/Ig
        s#<(key|tls-crypt|tls-crypt-v2|tls-auth|static|cert|ca)>[^"]*</(key|tls-crypt|tls-crypt-v2|tls-auth|static|cert|ca)>#<\1>[REDACTED]</\1>#Ig
        # Credential key/value. audit 2026-08-19: the value class used to be
        # [^",}[:space:]]+, i.e. it stopped at the FIRST SPACE, so
        #   password = correct horse battery staple
        # published everything after "correct" and
        #   {"password": "correct horse battery staple"}
        # published everything after the first word of the quoted value. Any
        # passphrase with a space in it leaked. The class now allows spaces
        # and stops only at " { } , so a JSON/object boundary is still never
        # crossed and the rest of the record stays readable.
        # passphrase/master-password/recovery-code/mnemonic added 2026-08-19:
        # the alternation carried "pass" but nothing that could match
        # "passphrase: <value>", because after "pass" the regex requires
        # a separator and finds "phrase". A bare "passphrase:" line leaked
        # in full, in v1.5 and earlier. Longer alternatives are listed FIRST.
        # authorization/cookie/session added: a Bearer or Basic header in a
        # service log or a curl trace is a live credential and was not
        # matched by any rule.
        # audit 2026-08-19 round 2, inspector F4/F5. Two separate defects in
        # the single rule this replaces.
        #
        # (a) NO LEFT WORD BOUNDARY. The alternation carries "key", "pass",
        #     "pin", "sig" and "uuid", so "monkey: x" matched on "key" and
        #     "bypass = false" matched on "pass", and each truncated its own
        #     diagnostic line. Every key now needs a non-alphanumeric
        #     character (or the line start) in front of it.
        #
        # (b) ONE VALUE CLASS CANNOT SERVE BOTH JOBS. Stopping at whitespace
        #     leaks a passphrase containing a space; running to the line end
        #     destroys "key=AAAA BBBB CCCC". The split is by KEY STRENGTH,
        #     because that is what decides which error is acceptable:
        #       passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass (password, passphrase, token, psk, authorization...)
        #         the line is a credential line, so over-redaction costs
        #         nothing and the value runs to the end. A comma no longer
        #         terminates it, which is what published the tail of
        #         "password = corr,ect horse".
        #       signature|uuid|key|sig|pin (key, sig, pin, uuid, signature)
        #         these appear in benign contexts constantly, so the value
        #         stops at whitespace exactly as it did before.
        #     A quoted value is handled first in both cases and may contain
        #     anything except the closing quote.
        #
        # v1.7 (2026-09-06): THE BARE VALUE MAY NOT START WITH `{` OR `[`.
        # the kodachi-soc cpath baseline is a compact JSON map KEYED BY PATH, so
        # it contains `"/usr/bin/passwd":{"size":118168,...}`. The rule matched
        # `passwd"` as a credential key and replaced the opening brace of the
        # object, and that single character made a 676 KB file stop parsing
        # while the original on the machine parsed fine. A secret never starts
        # with a structural character.
        # v1.7 (inspector round 2 follow-up, 2026-09-06): A BARE JSON LITERAL
        # UNDER A REDACTED KEY BROKE THE FILE. Measured on the live ISO:
        # tor-switch-config.json carries `"hashed_control_password": null` three
        # times; the credential rule below matches a bare value with [^"}]*, so
        # it consumed `null,` INCLUDING the comma and the file stopped parsing
        # (the original on the machine parses fine). null / true / false are
        # never secrets and never locations, so they are protected here with a
        # token no rule can match, and restored immediately after the three
        # families that would otherwise eat them.
        s/(^|[^A-Za-z0-9])("?(passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass|city|region|region_name|region_code|state_name|country|country_name|country_code|latitude|longitude|lat|lon|loc|postal|postal_code|zip|zip_code|timezone_name|isp|asn|asn_org|org|organization|[A-Za-z0-9_]*_b64|payload|tier_claim|entitlement|licen[cs]e[-_]?key)"?[[:space:]]*[:=][[:space:]]*)(null|true|false)([[:space:]]*[],}]|[[:space:]]*$)/\1\2@@KDCLIT-\4-@@\5/Ig
        s/(^|[^A-Za-z0-9])("?(passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass)"?[[:space:]]*[:=][[:space:]]*)([^"{}[,@[:space:]][^"}]*)/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(signature|uuid|key|sig|pin)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(signature|uuid|key|sig|pin)"?[[:space:]]*[:=][[:space:]]*)([^"{},@[:space:]]+)/\1\2[REDACTED]/Ig
        s/((PrivateKey|PresharedKey|PublicKey)[[:space:]]*=[[:space:]]*)[A-Za-z0-9+/=]+/\1[REDACTED]/Ig
        # `wg show` / `awg show` print the PEER public key on its own line. It is not a
        # secret cryptographically, but it uniquely identifies WHICH server the user
        # connects to, which is the thing a privacy tool must not ship in a bug report.
        # Anchored and base64-terminated so the ordinary word "peer" is never touched.
        s/^([[:space:]]*peer:[[:space:]]*)[A-Za-z0-9+/]+=/\1[REDACTED]/
        s/(auth-user-pass[[:space:]])[^"]*/\1[REDACTED]/Ig
        # audit 2026-08-19 round 3, F21. Confirmed independently by
        # <agent> and <agent>, with a live producer.
        #
        # EVERY credential rule above requires a `:` or `=` after the key
        # name, because they were written for config files and JSON. An
        # ARGV line is KEY <SPACE> VALUE by construction, so a command line
        # captured by `ps auxww` (03-network, 05-vpn, 09-processes) or by
        # `systemctl cat` walked straight through all of them:
        #
        #   --password=secret   caught by the key/value rules
        #   --password secret   MISSED
        #   microsocks -u kodachi -P Tr0ub4dor-3   MISSED, and this one is
        #     emitted verbatim by routing-switch (commands/microsocks.rs,
        #     `.arg("-u").arg(&username).arg("-P").arg(&password)`) and is
        #     grepped INTO the bundle by the proxy-processes capture below.
        #
        # LONG FLAGS are safe to handle generically: the mandatory `--`
        # prevents any collision with `mkdir -p`, `ps -p`, `cp -p`, `ssh -p`.
        s/(^|[[:space:]])(--(username|password|passwd|passphrase|pass|preshared[-_]?key|private[-_]?key|privkey|client[-_]?secret|secret[-_]?key|access[-_]?key|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|api[-_]?key|apikey|secret|token|psk|key)[[:space:]]+)[^[:space:]]+/\1\2[REDACTED]/Ig
        # SHORT FLAGS CANNOT BE HANDLED GENERICALLY. A bare `-p`, `-k`, `-P`
        # or `-u` means something different in almost every program, and
        # redacting the token after them unconditionally would destroy
        # `mkdir -p /path`, `ssh -p 22`, `curl -k https://...` and every
        # port number in the bundle. So each is gated on the program that
        # actually takes a secret there, and ONLY the flags that carry one:
        # microsocks -p is the PORT and stays readable, -P is the password.
        #
        # F21 SECOND MEMBER, 2026-08-19 (<agent>). The trailing class used to be
        # [^A-Za-z0-9_-], which EXCLUDES a hyphen, so the address did not match
        #     sudo routing-switch microsocks-enable -u <user> -p <password>
        # the Kodachi CLI that starts the proxy. That line IS captured, because the
        # ps grep in this collector matches on the `microsocks` substring. Its password
        # flag is also lowercase -p, which the raw binary uses for the PORT, so the two
        # forms need different value predicates rather than one flag list.
        # DISCRIMINATOR: a port is all digits, a password is not. `-p 9050` stays
        # readable; `-p Xy7QpLm2Zr9TvBn4Ke1WaS6d` does not.
        # EVERY RULE BELOW BINDS THE FLAG TO THE PROGRAM IN ONE MATCH. An earlier
        # version used a sed ADDRESS plus a separate s command, which reads as
        # "microsocks -P" and MEANS "any -P on any line that mentions microsocks".
        # A sed address is scoped to the LINE, not to the command that owns the
        # flag, so program-gating bounds WHICH LINES a rule considers and says
        # nothing about WHICH TOKENS on them it rewrites. Measured on this host,
        # that form destroyed real output through three separate gates:
        #     find /var/lib/mysql -name "*.err" -print  ->  -p[REDACTED]
        #     cp -pr /var/lib/mysql /backup             ->  -p[REDACTED]
        #     sshpass -V && rsync -p file host:/dst     ->  the FILENAME destroyed
        #     tar -kxf backup.tar -C /opt && which ss-local -> -k[REDACTED]
        # A BRIDGE is what fixes it: the flag must FOLLOW the program name on the
        # same line with no shell separator between them, so a second command on
        # the line can no longer arm the first commands rule.
        # THE BRIDGE MUST BE A TOKEN WALK, NOT A CHARACTER RUN. A permissive
        # [^;&|]{0,150} bridge is greedy and POSIX takes leftmost-LONGEST, so it
        # slides forward to the LAST occurrence of the flag on the line and /g
        # then resumes past everything it swallowed. The secret sits INSIDE the
        # bridge, the one region the rule is guaranteed never to rewrite:
        #     sshpass -p SECRET ssh -p 2222 host  ->  the PORT was redacted and
        #                                             the password shipped in clear
        # That is the canonical sshpass invocation against a non-default port, not
        # an edge case. Found by <agent>, who applied the leftmost-longest
        # argument below back to the bridge itself.
        # So each bridge is a repetition over WHOLE TOKENS, and the token
        # alternation cannot match a token that begins with the flag being bound.
        # The walk therefore physically cannot step over the first such flag, and
        # leftmost-longest has nowhere further to slide.
        # Flags are split one per rule on purpose. A combined [Pu] class would
        # match greedily to the LAST of the two and /g would resume past it, so
        # the earlier flag would silently survive.
        # The sshpass bridge additionally refuses -f, -e and -d, which are the
        # three MUTUALLY EXCLUSIVE alternatives to -p (file, environment, file
        # descriptor). A line carrying one of them has no sshpass password on it
        # at all, so without this the walk crosses into the NEXT program and
        # redacts its port: `sshpass -f /run/pw ssh -p 2222 host` lost the 2222.
        # That is destruction rather than a leak, and narrowing here cannot
        # create a leak because the excluded tokens exclude -p by definition.
        # Residual raised by <agent>, who judged it acceptable; it was
        # three characters to close, so it is closed.
        # THE CONTINUATION TOKEN ALSO STOPS AT `<` AND `>`. Without that, the walk
        # eats a shell REDIRECT and leaves a dangling fragment:
        #   -P My Pass > /var/log/ms.log 2>&1   ->   -P [REDACTED]&1
        # No secret escapes, so this is destruction rather than a leak, but a
        # bundle reading `[REDACTED]&1` tells an engineer nothing about where the
        # daemon output went, and it looks like corruption. The exclusion is on the
        # FIRST character of a continuation token only: excluding <> from the
        # second class too would break a spaced password whose later word contains
        # `>` (`-P My Pa>ss`), which is a real shape and is tested.
        # Found by <agent>, 2026-08-20.
        # THE VALUE IS MULTI-TOKEN ON THE FOUR microsocks GATES AND SINGLE-TOKEN
        # EVERYWHERE ELSE, and that asymmetry is load-bearing. A one-token value
        # ([^[:space:]]+) leaks everything after the first SPACE in a password,
        # and microsocks-enable takes `password: String` from clap with no charset
        # restriction, so a space is accepted and never warned about. The four
        # microsocks gates can swallow following NON-FLAG tokens safely because
        # their producer always follows the secret with a flag:
        #   microsocks.rs:192-199   -u user -P password -b 0.0.0.0 -p port
        # sshpass does NOT get this: it is always followed by a COMMAND, so
        # `sshpass -p SECRET ssh admin@host` would lose `ssh admin@host`.
        # The ss/obfs family does NOT get it either, and the reason is now read
        # rather than unknown: routing-switch starts ss-local with a CONFIG FILE
        # (protocols/clients/shadowsocks.rs:200, CONFIG_ARG plus a path), so this
        # product never emits `ss-local -k` at all and nothing establishes what
        # follows the key on a hand-typed line. Found by <agent>.
        # KNOWN RESIDUAL, deliberate: a flag REPEATED on one command line is
        # redacted only on its first occurrence, because /g resumes past the
        # program name. Closing it needs a :label + t loop, whose termination
        # guard would require rejecting values that begin with [ and would
        # therefore open a new leak class. No producer here emits a duplicate
        # flag; ss-local -k A ... -k B is a user error, not a shape we ship.
        #
        # mysql/mysqldump/mariadb was REMOVED outright rather than repaired:
        # `mysql` is a directory name (/var/lib/mysql), a service name and a log
        # path, so it is a common token by the same test, and this product has no
        # mysql client producer at all (the only repo hit is this file).
        # Found by <agent> applying my own rule back to a rule I kept.
        #
        # microsocks daemon: -P is the password, -u the user, and -p is the PORT
        # and must stay readable. microsocks.rs:192-197 is the producer.
        s/((^|[^A-Za-z0-9_-])microsocks([[:space:]]+(-[^P;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-P[[:space:]]+)[^[:space:]]+([[:space:]]+[^-<>;&|[:space:]][^;&|[:space:]]*)*/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])microsocks([[:space:]]+(-[^u;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-u[[:space:]]+)[^[:space:]]+([[:space:]]+[^-<>;&|[:space:]][^;&|[:space:]]*)*/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])microsocks([[:space:]]+(-[^P;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-P)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])microsocks([[:space:]]+(-[^u;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-u)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        # microsocks-enable, the Kodachi CLI that STARTS it, INVERTS the letters:
        # main.rs:374-387 declares -u/--username, -p/--password and a LONG-ONLY
        # --port, so lowercase -p is unambiguously the secret here and there is no
        # short port flag to protect. Gated on the full name, so a daemon line
        # (which never contains "microsocks-enable") can never reach this.
        s/((^|[^A-Za-z0-9_-])microsocks-enable([[:space:]]+(-[^p;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-p[[:space:]]+)[^[:space:]]+([[:space:]]+[^-<>;&|[:space:]][^;&|[:space:]]*)*/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])microsocks-enable([[:space:]]+(-[^p;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-p)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        # -u/--username on the CLI too. The daemon rule above CANNOT reach this
        # line: its bridge is a token walk that must begin at whitespace, and
        # `microsocks` here is followed immediately by `-enable`, so the walk
        # never starts. Under the earlier character-run bridge this line was
        # covered by accident, which is why the pair had to be spelled out.
        s/((^|[^A-Za-z0-9_-])microsocks-enable([[:space:]]+(-[^u;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-u[[:space:]]+)[^[:space:]]+([[:space:]]+[^-<>;&|[:space:]][^;&|[:space:]]*)*/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])microsocks-enable([[:space:]]+(-[^u;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-u)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        # shadowsocks / obfs family: -k is the key, -p is the PORT and stays.
        s/((^|[^A-Za-z0-9_-])(ss-local|ss-redir|ss-server|ss-tunnel|obfs-local|obfs-server)([[:space:]]+(-[^k;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-k[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])(ss-local|ss-redir|ss-server|ss-tunnel|obfs-local|obfs-server)([[:space:]]+(-[^k;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-k)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        # sshpass -p, both spaced and attached.
        s/((^|[^A-Za-z0-9_-])sshpass([[:space:]]+(-[^pfed;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-p[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g
        s/((^|[^A-Za-z0-9_-])sshpass([[:space:]]+(-[^pfed;&|[:space:]][^;&|[:space:]]*|[^-;&|[:space:]][^;&|[:space:]]*|-))*[[:space:]]-p)[^][:space:]=-][^[:space:]]*/\1[REDACTED]/g
        # The Kodachi CLI that STARTS microsocks is a SECOND member of this class
        # and the daemon rule above cannot reach it: the trailing boundary excludes
        # a hyphen, so `microsocks-enable` does not match `microsocks`. The two
        # addresses are therefore disjoint, which is what makes this safe, because
        # the flag meanings INVERT between them. Found by <agent>.
        #   daemon:  microsocks        -P password   -p PORT
        #   CLI:     microsocks-enable -p password   --port PORT  (long only)
        # routing-switch/src/main.rs:374-387 declares -u/--username, -p/--password
        # and a long-only --port, so lowercase -p here is unambiguously the secret
        # and there is no short port flag to protect.
        # audit 2026-08-19 round 4, F23. <agent> measured the rules above
        # against five argv grammars. Grammars 4 and 5 put the separator INSIDE one
        # argv token (curl -u user:pass, smbclient -U user%pass, 7z -pSECRET, and the
        # attached -PSECRET), so no whitespace-anchored rule can reach them.
        #
        # I WROTE RULES FOR ALL OF THEM AND THEN REMOVED FOUR, because a sed address is
        # scoped to the LINE, not to the command that owns the flag. Measured against
        # 40,565 real lines of ps auxww + journal on the dev host, a curl or a .zip
        # ANYWHERE on a line armed the flag rule against every unrelated flag on it:
        #     find /var -name "*.zip" -print    ->  -p[REDACTED]   (twice)
        #     ls kodachi-debug.zip && pwd -P    ->  -P[REDACTED]
        #     echo x > log.zip; cp -P /a /b     ->  the SOURCE PATH destroyed
        #     curl https://x/a.zip; date -u +%Y ->  -u [REDACTED]
        # find -print and a .zip filename are both routine in this bundle, and the
        # collector writes its own .zip name into its own logs, so those rules would
        # have corrupted real diagnostics on nearly every run. curl, smbclient, 7z and
        # zip have no client-side producer in this product (the single curl case is
        # server-side, in server-side-vps-setup-master-node-hosts/root/setup-scripts/
        # optional/netdata_setup.sh), so they closed a grammar nothing here emits at
        # the cost of destroying output everything here emits. Widening a rule to close
        # a leak opens a destruction class, and when the leak has no producer the trade
        # is strictly negative.
        #
        # WHAT STAYS is the ATTACHED form for the three programs that DO carry a secret
        # on argv here, made deliberate rather than left to the accident of some other
        # rule. Their gates are rare program names and they changed 0 of those same
        # 40,565 lines. The negated class after the flag letter is what stops these
        # re-matching the "-P [REDACTED]" the whitespace rules just produced.
        #
        # NOTE FOR THE NEXT EDITOR: this whole sed script is inside a SINGLE-QUOTED
        # string, so an apostrophe in a comment (a possessive, a contraction) silently
        # terminates it and everything below becomes shell. Keep comments apostrophe-free.
        # Tor control-port credentials. The hashed form is offline-crackable
        # and the plain form is a credential outright; torrc is collected.
        s/((HashedControlPassword|ControlPassword)[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig
        # WiFi network names. The banner promises WiFi data is redacted, and a
        # home SSID locates a user as precisely as a MAC does (wardriving
        # databases are public). NM system-connections, wpa_supplicant.conf
        # and iwconfig/iw output all carry them and none was redacted.
        # v1.7 (2026-09-06): THE SSID RULE HAD NO LEFT WORD BOUNDARY, the same
        # defect this file already records for the credential rule. It matched
        # the tail of any word ending in "ssid", so the kodachi-soc cpath
        # baseline, a JSON map keyed by path, had a token INSERTED in front of
        # a structural brace at "/sbin/linssid":{...} and a 676 KB file stopped
        # parsing. Found by parsing every JSON in a real bundle, not by reading.
        s/(^|[^A-Za-z0-9_-])("?e?ssid"?[[:space:]]*[:=][[:space:]]*"?)[^"{},]*/\1\2[REDACTED-SSID]/Ig
        # v1.7 (inspector, 2026-09-06): a signed entitlement claim is a
        # credential and its keys are payload_b64 / signature_b64, which no
        # rule above matched ("signature" had to be the whole key). Any key
        # ending in _b64, plus payload / tier_claim / entitlement / license key,
        # is redacted whether the value is quoted or bare.
        #
        # The key class is [A-Za-z0-9_], not [A-Za-z_]: a digit in the key
        # (`sha256_b64`) made the `(^|[^A-Za-z0-9])` guard reject the match, so
        # the comment claimed more than the rule did (inspector).
        #
        # The bare value class is [^"{},] like every other bare rule in this
        # file, NOT [^"}]. The wider class ate the opening brace of
        #     "payload": {          and    "all_servers_csv_with_ovpn_b64": {
        # in two SHIPPED config files, and the comma in compact JSON, so the
        # the collected hook results stopped parsing. The first character
        # additionally may not be `{` or `[`, so an object or array VALUE is
        # left alone: its contents are redacted by the rules that apply to
        # them, and a structural token is never swallowed.
        s/(^|[^A-Za-z0-9])("?([A-Za-z0-9_]*_b64|payload|tier_claim|entitlement|licen[cs]e[-_]?key)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?([A-Za-z0-9_]*_b64|payload|tier_claim|entitlement|licen[cs]e[-_]?key)"?[[:space:]]*[:=][[:space:]]*)([^"{}[,@[:space:]][^"{},]*)/\1\2[REDACTED]/Ig
        # v1.7 (inspector, 2026-09-06): IP redaction is defeated by the
        # geolocation stored NEXT to the address (city, region, coordinates,
        # ISP, ASN organisation), which ip-fetch caches per IP and conky-status
        # publishes. The header promises no location data, so these keys go too.
        #
        # THE BARE ARM RUNS TO THE STRUCTURAL BOUNDARY, NOT TO THE FIRST SPACE.
        # Round 2 of this rule used [^"{},[:space:]]+ and therefore published
        # every multi-word value minus its first word, which is not a
        # redaction at all (inspector, measured):
        #     City: Salt Lake City          -> City: [REDACTED-GEO] Lake City
        #     ISP: Etisalat Oman Telecom    -> ISP: [REDACTED-GEO] Oman Telecom
        #     Country: Oman <flag emoji>    -> the flag survived and names the
        #                                      country exactly
        # and `ip-fetch` prints exactly those shapes (cli.rs:1386,1395,1398).
        # It now matches [^"{},]* like the SSID rule three lines above, so the
        # value runs to a comma, a brace, a quote or the end of the line. That
        # over-redacts a trailing unrelated token on a `key: value` LINE, which
        # is the direction a privacy tool must fail in.
        #
        # THE BARE ARM CARRIES A SHORTER KEY LIST than the quoted arm, because
        # a bare short word is ambiguous in a way a JSON key is not: `org` made
        # `https://gitlab.torproject.org:443/...` lose its port and path, and
        # `region`/`zip`/`loc`/`lat`/`lon`/`asn`/`postal` are common tokens in
        # apt, systemd and kernel output. Those keys are still redacted when
        # they appear as a JSON key with a quoted value, which is how every
        # geolocation producer here emits them.
        s/(^|[^A-Za-z0-9])("?(city|region|region_name|region_code|state_name|country|country_name|country_code|latitude|longitude|lat|lon|loc|postal|postal_code|zip|zip_code|timezone_name|isp|asn|asn_org|org|organization)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED-GEO]/Ig
        s/(^|[^A-Za-z0-9])("?(city|region_name|state_name|country|country_name|country_code|latitude|longitude|postal_code|zip_code|timezone_name|isp|asn_org)"?[[:space:]]*[:=][[:space:]]*)([^"{},@[:space:]][^"{},]*)/\1\2[REDACTED-GEO]/Ig
        s/@@KDCLIT-(null|true|false)-@@/\1/Ig
        # A bare [REDACTED...] token where JSON expects a value reads as the
        # start of an ARRAY, so a redacted bare value made the document
        # unparseable even when the comma survived (e.g. "latitude": 23.5).
        # Quote it back into a valid JSON string. In a flat .conf this turns
        # `password = [REDACTED]` into `password = "[REDACTED]"`, which is
        # cosmetic and costs nothing.
        s/("[[:space:]]*:[[:space:]]*)(\[REDACTED[A-Z0-9_-]*\])([[:space:]]*)([],}]|$)/\1"\2"\3\4/g
        # Generic credential-in-URL for ANY scheme (the previous allowlist
        # missed mierus:// and any future proxy scheme). Only the userinfo
        # is redacted, preserving scheme+host so the bundle stays diagnostic
        # and the JSON string boundary (") is never crossed.
        s#([a-zA-Z][a-zA-Z0-9.+-]*://)[^/@"[:space:]<>]+(:[^/@"[:space:]<>]*)?@#\1[REDACTED]@#Ig
        # Known PROXY schemes only: nuke the whole URL (these embed creds/
        # tokens in the path/fragment). http(s) is intentionally NOT here -
        # ordinary URLs must stay readable for diagnostics; real https
        # credentials are already covered by the userinfo rule above and the
        # key-name rule (token=/key=/password= in query strings).
        s#((ss|ssr|vmess|vless|trojan|hysteria2?|hy2|tuic|socks5?)://)[^[:space:]"<>]+#\1[REDACTED]#Ig
        # Identifier fields (hardware/machine/device IDs, license, serial,
        # activation): mask keeping a 4-char prefix so support can correlate
        # a bundle with server records without exposing the full value.
        # These names do NOT overlap the full-redact rule above (no pass/key/
        # token substring), so a masked value is never re-redacted.
        s#("?(hardware[-_]?id|hwid|machine[-_]?id|device[-_]?id|license|licence|serial([-_]?number)?|activation([-_]?code)?)"?[[:space:]]*[:=][[:space:]]*"?)([A-Za-z0-9][A-Za-z0-9+/._-]{3})[^"{},]*#\1\5[MASKED]#Ig
        # MAC addresses, colon form and the dash form ip/ethtool never emits
        # but Windows-exported profiles and some firmware dumps do.
        s/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/[REDACTED-MAC]/Ig
        s/([[:xdigit:]]{2}-){5}[[:xdigit:]]{2}/[REDACTED-MAC]/Ig
    ' | LC_ALL=C awk '
    # ---- Network identifiers -------------------------------------------
    # Both families are SELECTIVE, for the reason recorded in the 2026-07-02
    # audit: a blanket rule gutted the very service logs this bundle exists
    # for. Loopback / RFC1918 / link-local / ULA are kept because Kodachi
    # diagnostics are ABOUT them (127.0.0.1 binds, 10.x DNS, fe80:: leak
    # checks); routable addresses are redacted.
    #
    # audit 2026-08-19, IPv6: the old single sed rule was
    #   ([[:xdigit:]]{0,4}:){3,7}[[:xdigit:]]{0,4}
    # whose {0,4} matched EMPTY groups, so any run of three colons with short
    # fields between them was replaced. Measured casualties:
    #   root:x:0:0:root:/root:/bin/bash  ->  root:x[REDACTED-IPV6]root:...
    #   19000:0:99999:7:::               ->  ...:9[REDACTED-IPV6]
    # i.e. passwd/shadow-shaped and any colon-delimited numeric record was
    # corrupted, while ::1 and fe80:: (which are safe AND diagnostic) were
    # thrown away. v6class() below parses the token properly instead.
    function ishex(s,   i, c) {
        if (length(s) > 4) return 0
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (index("0123456789abcdefABCDEF", c) == 0) return 0
        }
        return 1
    }
    # 0 = not an address (leave the text alone)
    # 1 = address, privacy-safe and diagnostic (keep)
    # 2 = address, routable (redact)
    # netstat and ss print an IPv6 socket UNBRACKETED, as host:port. Read as a
    # literal, "::1:9050" is a routable address and the Tor SOCKS listener,
    # one of the most diagnostically valuable lines in the whole bundle, was
    # replaced with a placeholder. The eight-hextet form is worse: a 5-digit
    # port fails the 4-character hextet test, so the WHOLE token was rejected
    # as "not an address" and a routable address survived (inspector F3).
    #
    # So: if the token ends in a decimal group, classify the part before it
    # first. If that is a real address the tail was a port. If it is not, fall
    # through and classify the token whole, which keeps 2001:db8::443 (a real
    # address whose last hextet happens to be decimal) redacted.
    function v6class(tok,   base, c) {
        if (tok ~ /:[0-9]+$/) {
            base = tok
            sub(/:[0-9]+$/, "", base)
            if (index(base, ":") > 0) {
                c = v6core(base)
                if (c != 0) return c
            }
        }
        return v6core(tok)
    }
    function v6core(tok,   n, p, i, runs, inrun, rstart, rend, nonempty, first, low) {
        if (index(tok, ":::") > 0) return 0
        n = split(tok, p, ":")
        if (n - 1 < 2) return 0
        runs = 0; inrun = 0; rstart = 0; rend = 0; nonempty = 0; first = ""
        for (i = 1; i <= n; i++) {
            if (!ishex(p[i])) return 0
            if (p[i] == "") {
                if (!inrun) { runs++; inrun = 1; rstart = i }
                rend = i
            } else {
                inrun = 0
                nonempty++
                if (first == "") first = p[i]
            }
        }
        if (runs > 1) return 0
        if (runs == 0) {
            # no "::" compression, so it must be the full eight-hextet form.
            # This is what keeps 16:04:31 (a timestamp) and 12:34:56:78 out.
            if (n != 8) return 0
        } else {
            if (n > 9) return 0
            if (nonempty > 7) return 0
            # A "::" is TWO adjacent colons, which split() reports as one
            # empty field in the middle and two at either end. A single
            # stray leading/trailing colon (the passwd-line case) is not.
            if (rstart == 1) { if (rend < 2) return 0 }
            else if (rend == n) { if (rend - rstart < 1) return 0 }
            else if (rstart != rend) return 0
        }
        if (nonempty == 0) return 1
        low = tolower(first)
        if (substr(tok, 1, 2) == "::") {
            if (tok == "::1") return 1
            if (low == "ffff") return 1
            return 2
        }
        if (substr(low, 1, 3) == "fe8" || substr(low, 1, 3) == "fe9" || \
            substr(low, 1, 3) == "fea" || substr(low, 1, 3) == "feb") return 1
        if (substr(low, 1, 2) == "fc" || substr(low, 1, 2) == "fd") return 1
        return 2
    }
    {
        # Cheap pre-filter: only lines that could hold an IPv6 literal pay for
        # the tokeniser. A timestamp (two colons) never reaches it.
        if ($0 ~ /::/ || $0 ~ /:[0-9A-Fa-f][0-9A-Fa-f]*:[0-9A-Fa-f][0-9A-Fa-f]*:[0-9A-Fa-f][0-9A-Fa-f]*:/) {
            out = ""; rest = $0
            while (length(rest) > 0) v6pass(nextchunk())
            $0 = out
        }

        if ($0 !~ /[0-9]\.[0-9]/) { print $0; next }

        out = ""; rest = $0
        while (length(rest) > 0) v4pass(nextchunk())
        print out
    }
    # v1.7 (2026-09-06): the two passes above used to run
    #     while (match(rest, ...)) { ...; rest = substr(rest, RSTART + RLENGTH) }
    # over the WHOLE record, and every iteration copies the remainder, so the
    # cost is O(length x matches). The IPv6 tokeniser matches every hex-looking
    # run ("a", "e", "10", "cafe"), so on a compact 1.4 MB single-line JSON
    # (kodachi-soc snapshot, the SOC cpath baseline, a language catalog) that is
    # tens of thousands of copies of a megabyte each: the 26-minute hang measured
    # on en.json and the 6-minute step 7 measured after it was excluded.
    #
    # Now the record is cut into chunks of at least 4096 characters, each pass
    # runs per chunk, and a remainder copy can never exceed one chunk (the
    # IPv4 pass additionally trims its lookback to 60 characters, see there,
    # because `out` itself grows to the record length). The cut is placed
    # only AFTER a character that can belong to neither token class
    # ([0-9A-Za-z:%_.+~-] covers IPv6, scope ids, IPv4, and the -/+/~ revision
    # suffix the IPv4 rule inspects), so no token, no neighbour check (prv/nxt/
    # after) and no revision lookahead can straddle a boundary. The 40-character
    # version lookback reads `out pre`, and `out` accumulates across chunks, so
    # it sees exactly what it saw before. Output is byte-identical to the old
    # form; only the cost changed.
    function nextchunk(   n, cut, c) {
        n = length(rest)
        if (n <= 4096) { c = rest; rest = ""; return c }
        cut = 4096
        while (cut < n && substr(rest, cut, 1) ~ /[0-9A-Za-z:%_.+~-]/) cut++
        c = substr(rest, 1, cut)
        rest = substr(rest, cut + 1)
        return c
    }
    function v6pass(chunk,   r, tok, pre, nxt, prv, scope, sp) {
            r = chunk
            while (match(r, /[0-9A-Fa-f:]+(%[A-Za-z0-9_.-]+)?/)) {
                tok   = substr(r, RSTART, RLENGTH)
                pre   = substr(r, 1, RSTART - 1)
                nxt   = substr(r, RSTART + RLENGTH, 1)
                r     = substr(r, RSTART + RLENGTH)
                if (length(pre) > 0)      prv = substr(pre, length(pre), 1)
                else if (length(out) > 0) prv = substr(out, length(out), 1)
                else                      prv = ""
                scope = ""
                sp = index(tok, "%")
                if (sp > 0) { scope = substr(tok, sp); tok = substr(tok, 1, sp - 1) }
                # A C++/Rust/GLib symbol path has hex-ish text GLUED to the
                # colons: std::bad_alloc, core::fmt::Error, standard::name,
                # RunEvent::Exit. Two colons is enough for the classifier, so
                # the tokeniser grabbed "d::na" out of "standard::name" and
                # the first cut of this rule destroyed 2153 lines per 60,000
                # of real syslog, none of them addresses (inspector F1).
                #
                # A real address is always delimited: space, tab, "/", "[",
                # "]", "=", ",", quote, or the line edge. Requiring a
                # non-alphanumeric neighbour on BOTH sides removes every one
                # of those 2153 and costs nothing on an address.
                if (prv ~ /[0-9A-Za-z_]/ || nxt ~ /[0-9A-Za-z_]/) {
                    out = out pre tok scope
                } else if (v6class(tok) == 2) {
                    out = out pre "[REDACTED-IPV6]"
                } else {
                    out = out pre tok scope
                }
            }
            out = out r
    }
    function v4pass(chunk,   r, ip, pre, after, n, o, valid, priv, ctx, tail, isver, tl) {
        r = chunk
        while (match(r, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            ip    = substr(r, RSTART, RLENGTH)
            pre   = substr(r, 1, RSTART - 1)
            after = substr(r, RSTART + RLENGTH, 1)
            n = split(ip, o, ".")
            valid = (n == 4 && o[1] <= 255 && o[2] <= 255 && o[3] <= 255 && o[4] <= 255 && length(o[1]) <= 3 && length(o[2]) <= 3 && length(o[3]) <= 3 && length(o[4]) <= 3)
            priv = (o[1] == 10 || o[1] == 127 || o[1] == 0 || \
                    (o[1] == 192 && o[2] == 168) || \
                    (o[1] == 172 && o[2] >= 16 && o[2] <= 31) || \
                    (o[1] == 169 && o[2] == 254) || \
                    (o[1] == 255 && o[2] == 255))
            # audit 2026-08-19: a four-part VERSION is a valid dotted quad, so
            # the collector was redacting the fields support reads first.
            #   NIGHTLY_VERSION=9.8.4.183   ->  NIGHTLY_VERSION=[REDACTED-IPV4]
            #   ii tor 0.4.8.12-1           ->  ii tor [REDACTED-IPV4]-1
            # Three structural tells separate a version from an address: a
            # version key introduces it, a letter runs straight into it
            # (v9.8.4), or a Debian revision / fifth component follows it.
            # Only the last 40 characters are ever read, so only the last 60 of
            # `out` are taken. `ctx = out pre` copied the WHOLE accumulated
            # record on every match, which left this pass superlinear after the
            # chunking (inspector, 2026-09-06: 4.1 MB IPv4-dense line 145s ->
            # 2.3s with this line alone, output byte-identical).
            ctx  = substr(out, (length(out) > 60 ? length(out) - 59 : 1)) pre
            tail = tolower(substr(ctx, length(ctx) - 39))
            # audit 2026-08-19 round 2, inspector F2: the first cut of this
            # guard had FOUR ways for a routable address to survive, and two
            # of them are the commonest shapes in real logs.
            #   after == "."   kept every address ending a sentence
            #                  ("Connected to 203.0.113.5.") and every rDNS
            #                  name ("203.0.113.5.static.example.net"),
            #                  which sshd, mail and mtr emit constantly.
            #   tail ~ [a-z]$  kept "v203.0.113.9".
            #   a 40-character lookback for the keyword kept the address in
            #                  "Version 9.8.4.183 build 203.0.113.5".
            #   after == "-"   kept the first half of an nftables range
            #                  "198.51.100.10-198.51.100.20".
            # All four are gone. A privacy tool fails CLOSED: anything
            # ambiguous is redacted, and a redacted version string is a
            # cosmetic loss while a published address is not.
            isver = 0
            # (1) a version keyword IMMEDIATELY before, at most three
            #     separator characters between it and the number. version,
            #     release and revision are unambiguous so they may be
            #     separated by a space; the weaker words must be glued on
            #     with "=", ":" or a quote, which is what stops "build ".
            if (tail ~ /(version|release|revision)[^0-9a-z]?[^0-9a-z]?[^0-9a-z]?$/) isver = 1
            else if (tail ~ /(build|nightly|pack|kernel|firmware|uname)[=:"'"'"']$/) isver = 1
            # (2) a Debian revision or vendor suffix follows (0.4.8.12-1,
            #     6.12.94.1-amd64, 1.0.7.0-k), but NOT an address range,
            #     which carries a second dotted quad after the separator.
            if (!isver && (after == "-" || after == "+" || after == "~")) {
                tl = substr(r, RSTART + RLENGTH)
                if (tl !~ /^[-+~][0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) isver = 1
            }
            out = out pre ((valid && !priv && !isver) ? "[REDACTED-IPV4]" : ip)
            r = substr(r, RSTART + RLENGTH)
        }
        out = out r
    }' | LC_ALL=C awk '
    # v1.8 (NA-Central-Hub bundle, 2026-09-17): addresses were redacted but
    # hostnames and account names were not. Kodachi rotates the hostname, so
    # every journal, syslog and auth.log line carried the CURRENT name and each
    # PREVIOUS one, and the login name appeared in about 79,000 places (sudo
    # and polkit lines, /home paths, the installer log, collector-run.txt),
    # which identifies the person who shared the bundle.
    #
    # Two lists, both "token:mode:name" separated by spaces and built once per
    # run so a name gets the same token in every file:
    #   KDC_REDACT_HOSTNAMES -> [REDACTED-HOSTNAME-<token>]
    #   KDC_REDACT_USERS     -> [REDACTED-USER-<token>]
    # All entries of both lists are applied LONGEST NAME FIRST, so a shorter
    # name (MacBook) can never cut a piece out of a longer one
    # (MacBook-Pro-16inch) that was already replaced.
    #
    # mode W (word): replaced anywhere in the text on a boundary.
    # mode C (context): the name is also an ordinary word or very short, so
    #   it is replaced only where the text says it is a hostname or an account
    #   name (see HCTX and UCTX below). Replacing "Avalon" or "data" everywhere
    #   would destroy unrelated text.
    #
    # Boundary: the character before the name may not be a letter or digit
    # (or "_" for account names, which may contain it); the character after
    # may not be a letter, digit or "_", nor a "-" followed by a letter or
    # digit, nor a "." followed by a digit, so the name is never the front
    # part of a longer dotted or hyphenated name.
    # NOTE: this program sits inside a single-quoted shell string, keep every
    # comment free of apostrophes.
    function contd(r, at,   c, d) {
        c = substr(r, at, 1)
        if (c ~ /[A-Za-z0-9_]/) return 1
        d = substr(r, at + 1, 1)
        if (c == "-" && d ~ /[A-Za-z0-9]/) return 1
        if (c == "." && d ~ /[0-9]/) return 1
        return 0
    }
    function redw(line, name, tok, pb,   out, r, q, hl, pre, pre2) {
        out = ""; r = line; hl = length(name)
        while ((q = index(r, name)) > 0) {
            if (q > 1) pre = substr(r, q - 1, 1)
            else pre = (out == "") ? "" : substr(out, length(out), 1)
            # A JSON or C escape (backslash n, t, r) right before the name is
            # a separator, not part of a word: "Active sessions:\nNAME seat0".
            pre2 = (q > 2) ? substr(r, q - 2, 1) : ""
            if (pre2 == "\\" && pre ~ /[ntr]/) pre = " "
            if (pre !~ pb && !contd(r, q + hl)) out = out substr(r, 1, q - 1) tok
            else out = out substr(r, 1, q + hl - 1)
            r = substr(r, q + hl)
        }
        return out r
    }
    function redc(line, name, re_first, re_rest, tok,   out, r, hl, e, first, ok) {
        out = ""; r = line; hl = length(name); first = 1
        while (1) {
            ok = first ? match(r, re_first) : match(r, re_rest)
            if (!ok) break
            e = RSTART + RLENGTH
            if (!contd(r, e)) out = out substr(r, 1, e - hl - 1) tok
            else out = out substr(r, 1, e - 1)
            r = substr(r, e); first = 0
        }
        return out r
    }
    # Column-aware replacement for a context-mode ACCOUNT name. The name is
    # replaced only when a whole whitespace-separated FIELD equals it and the
    # line has the shape of a listing whose column there is a user or group:
    #   ls -l / ls -la:      PERMS LINKS OWNER GROUP ...
    #   find -printf %M %u %g (hooks-tree-ownership, user-state listings):
    #                        PERMS OWNER [GROUP] ...
    #   find -ls:            INODE BLOCKS PERMS LINKS OWNER GROUP ...
    #   stat %a %U:%G:       MODE OWNER:GROUP PATH
    #   ps aux, ps -ef:      USER PID CPU-or-PPID ...
    #   ps -eo pid,user, top, loginctl list-users:  PID USER STATE-ish ...
    #   loginctl list-sessions:  SESSION UID USER ...
    #   who:                 USER tty/pts/:N ...
    # Free prose is never touched by this function.
    function isperm(f) {
        return f ~ /^[-dlcbspD?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][-rwxsStT?][.+@]?$/
    }
    function cols(line, name, tok,   r, nf, W, S, i, k, o, g, hit, out, parts) {
        r = line; nf = 0
        while (match(r, /[^ \t]+/)) {
            nf++; S[nf] = substr(r, 1, RSTART - 1); W[nf] = substr(r, RSTART, RLENGTH)
            r = substr(r, RSTART + RLENGTH)
            if (nf >= 12) break
        }
        if (nf < 2) return line
        hit = 0
        for (k = 1; k <= 3 && k <= nf; k++) if (isperm(W[k])) break
        if (k <= 3 && k <= nf && (k == 1 || (W[1] ~ /^[0-9]+$/))) {
            o = k + 1
            if (o <= nf && W[o] ~ /^[0-9]+$/ && o + 1 <= nf) o++
            g = o + 1
            if (o <= nf && W[o] == name) { W[o] = tok; hit = 1 }
            if (g <= nf && W[g] == name) { W[g] = tok; hit = 1 }
        } else if (nf >= 3 && W[1] ~ /^[0-7][0-7][0-7][0-7]?$/ && index(W[2], ":") > 0) {
            split(W[2], parts, ":")
            if (parts[1] == name) { parts[1] = tok; hit = 1 }
            if (parts[2] == name) { parts[2] = tok; hit = 1 }
            if (hit) W[2] = parts[1] ":" parts[2]
        } else if (nf >= 3 && W[1] == name && W[2] ~ /^[0-9]+$/ && W[3] ~ /^[0-9][0-9.:]*$/) {
            W[1] = tok; hit = 1
        } else if (nf >= 3 && W[1] ~ /^[0-9]+$/ && W[2] == name && (W[3] ~ /^[0-9][0-9:.-]*$/ || W[3] ~ /^(rt|no|yes|active|online|lingering|closing)$/ || (length(W[3]) <= 5 && W[3] ~ /^[DIRSTWXZ][sl<N+L]*$/))) {
            W[2] = tok; hit = 1
        } else if (nf >= 3 && W[1] ~ /^c?[0-9]+$/ && W[2] ~ /^[0-9]+$/ && W[3] == name) {
            W[3] = tok; hit = 1
        } else if (nf >= 2 && W[1] == name && W[2] ~ /^(tty[0-9]*|pts\/[0-9]+|:[0-9]+|seat[0-9]+)$/) {
            W[1] = tok; hit = 1
        }
        if (!hit) return line
        out = ""
        for (i = 1; i <= nf; i++) out = out S[i] W[i]
        return out r
    }
    # A group or gshadow record, name:x:gid:m1,m2,m3 or name:!::m1,m2: every
    # member position that equals the name is replaced, not only the first.
    function grp(line, name, tok,   F, n, M2, k, i, out) {
        if (line !~ /^[A-Za-z0-9_.-]+:[^:]*:[0-9]*:[^:]*$/) return line
        n = split(line, F, ":")
        if (n != 4 || F[4] == "") return line
        k = split(F[4], M2, ",")
        out = ""
        for (i = 1; i <= k; i++) out = out (i > 1 ? "," : "") (M2[i] == name ? tok : M2[i])
        return F[1] ":" F[2] ":" F[3] ":" out
    }
    # NAME(uid=N): the account name is identified by what FOLLOWS it (PAM
    # "session opened for user root(uid=0) by NAME(uid=1000)", polkit).
    function redsuf(line, name, suf, tok, pb,   out, r, q, hl, pre, nd) {
        out = ""; r = line; nd = name suf; hl = length(name)
        while ((q = index(r, nd)) > 0) {
            if (q > 1) pre = substr(r, q - 1, 1)
            else pre = (out == "") ? "" : substr(out, length(out), 1)
            if (pre !~ pb) out = out substr(r, 1, q - 1) tok
            else out = out substr(r, 1, q + hl - 1)
            r = substr(r, q + hl)
        }
        return out r
    }
    # Regex-escape a name for use after a context pattern. Letters, digits,
    # space, underscore, hyphen and non-ASCII bytes stand for themselves;
    # every other ASCII character is put in a bracket expression.
    function esc_re(str,   out, i, c) {
        out = ""
        for (i = 1; i <= length(str); i++) {
            c = substr(str, i, 1)
            if (c ~ /[A-Za-z0-9 _-]/ || c > "~") out = out c
            else if (c == "^") out = out "\\^"
            else if (c == "\\") out = out "\\\\"
            else out = out "[" c "]"
        }
        return out
    }
    function dec(str) {
        gsub(/%20/, " ", str); gsub(/%3[Aa]/, ":", str); gsub(/%25/, "%", str)
        return str
    }
    function load(list, kind, prefix, anch, ctx, pb,   n, i, P, F) {
        KANYF[kind] = "(" (anch == "" ? "" : anch "|") ctx ")"
        KANYR[kind] = "(" ctx ")"
        KEND[kind] = "(" ctx ")$"
        KANCH[kind] = (anch == "") ? "" : "^(" anch ")$"
        n = split(list, P, " ")
        for (i = 1; i <= n; i++) {
            if (split(P[i], F, ":") != 3 || F[1] == "" || F[3] == "") continue
            if (F[2] != "W" && F[2] != "C") continue
            m++
            H[m] = dec(F[3]); M[m] = F[2]; K[m] = kind; PB[m] = pb
            T[m] = "[REDACTED-" prefix "-" F[1] "]"
            RF[m] = KANYF[kind] esc_re(H[m])
            if (M[m] == "C") HASC[kind] = 1
            # ps truncates a long USER column to 7 characters plus "+".
            TR[m] = (kind == "U" && length(H[m]) > 8) ? substr(H[m], 1, 7) "+" : ""
        }
    }
    # Context test per OCCURRENCE (v1.8, inspector N5). The earlier form ran
    # one regex per name over the whole line and cost 12 s for five short
    # names on a 2.2 MB journal. Now a context-mode name is looked up with
    # index() and, only where it occurs, the at most 100 characters before
    # it are tested against ONE end-anchored regex of all contexts of that
    # list; the line-start forms (syslog host column) are tested only for
    # the first occurrence in the segment.
    function ctxpass(seg, kind,   j, out, r, q, hl, t1, w, k, first) {
        for (j = 1; j <= m; j++) {
            if (K[j] != kind || M[j] != "C" || index(seg, H[j]) == 0) continue
            hl = length(H[j]); out = ""; r = seg; first = 1
            while ((q = index(r, H[j])) > 0) {
                t1 = substr(r, 1, q - 1)
                if (length(t1) >= 100) w = substr(t1, length(t1) - 99)
                else { k = length(out) - (100 - length(t1)); w = (k > 0 ? substr(out, k + 1) : out) t1 }
                if (!contd(r, q + hl) && (match(w, KEND[kind]) || (first && KANCH[kind] != "" && match(t1, KANCH[kind]))))
                    out = out t1 T[j]
                else
                    out = out t1 H[j]
                r = substr(r, q + hl); first = 0
            }
            seg = out r
        }
        return seg
    }
    # PREFIX NAME SUFFIX literal forms that are only an account name because
    # of what follows it: "by NAME(uid=1000)", "User NAME authorized",
    # "user NAME added", "Added NAME to group".
    function redps(line, name, pre, suf, tok, pb,   out, r, q, nd, pl, hl, before) {
        out = ""; r = line; nd = pre name suf; pl = length(pre); hl = length(name)
        while ((q = index(r, nd)) > 0) {
            before = (q > 1) ? substr(r, q - 1, 1) : ((out == "") ? "" : substr(out, length(out), 1))
            if (pre != "" || before !~ pb) out = out substr(r, 1, q + pl - 1) tok
            else out = out substr(r, 1, q + pl + hl - 1)
            r = substr(r, q + pl + hl)
        }
        return out r
    }
    # owner:group written as NAME:NAME (chown-style, "ownership set to").
    function pairsub(line, name, tok, pb,   out, r, q, nd, before) {
        out = ""; r = line; nd = name ":" name
        while ((q = index(r, nd)) > 0) {
            before = (q > 1) ? substr(r, q - 1, 1) : ((out == "") ? "" : substr(out, length(out), 1))
            if (before !~ pb && !contd(r, q + length(nd))) out = out substr(r, 1, q - 1) tok ":" tok
            else out = out substr(r, 1, q + length(nd) - 1)
            r = substr(r, q + length(nd))
        }
        return out r
    }
    function hasc(seg, kind,   j) {
        for (j = 1; j <= m; j++) if (K[j] == kind && M[j] == "C" && index(seg, H[j]) > 0) return 1
        return 0
    }
    # Context-mode processing of one segment (a line, or a piece of a line
    # between JSON "\n" escapes, which is treated as its own line start).
    function csegment(seg,   i, k) {
        for (i = 1; i <= m; i++) {
            if (M[i] != "C" || index(seg, H[i]) == 0) continue
            if (K[i] == "U") {
                if (substr(seg, 1, length(H[i]) + 1) == H[i] ":") seg = T[i] substr(seg, length(H[i]) + 1)
                seg = grp(seg, H[i], T[i])
                for (k = 1; k <= NSP; k++)
                    if (index(seg, SPRE[k] H[i] SSUF[k]) > 0) seg = redps(seg, H[i], SPRE[k], SSUF[k], T[i], PB[i])
                if (index(seg, H[i]) > 0) seg = cols(seg, H[i], T[i])
            }
            if (K[i] == "U" && index(seg, H[i] ":" H[i]) > 0) seg = pairsub(seg, H[i], T[i], PB[i])
            if (K[i] == "H" && index(seg, "\"aliases\"") > 0)
                seg = redc(seg, H[i], ALIASCTX esc_re(H[i]), ALIASCTX esc_re(H[i]), T[i])
        }
        if (HASC["H"] && hasc(seg, "H")) seg = ctxpass(seg, "H")
        if (HASC["U"] && hasc(seg, "U")) seg = ctxpass(seg, "U")
        if (HASC["F"] && hasc(seg, "F")) seg = ctxpass(seg, "F")
        return seg
    }
    # v1.8 (inspector N7): location data. The installer records the chosen
    # country, time zone and locale, and ip-fetch logs the time zone of the
    # exit address. The time zone region and the country part of a locale
    # are replaced; the UTC offset and the character set are kept, because
    # those are what a clock or encoding bug actually needs.
    function tzsub(line,   out, r) {
        out = ""; r = line
        while (match(r, /(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|Brazil|Canada|Chile|Mexico|US)(\\?\/[A-Za-z0-9_+-]+)+/)) {
            out = out substr(r, 1, RSTART - 1) "[REDACTED-TIMEZONE]"
            r = substr(r, RSTART + RLENGTH)
        }
        return out r
    }
    function locsub(line,   out, r, pre, post) {
        out = ""; r = line
        while (match(r, /[a-z][a-z][a-z]?_[A-Z][A-Z]/)) {
            pre = (RSTART > 1) ? substr(r, RSTART - 1, 1) : substr(out, length(out), 1)
            post = substr(r, RSTART + RLENGTH, 1)
            if (pre !~ /[A-Za-z0-9_]/ && post !~ /[A-Za-z0-9_]/) out = out substr(r, 1, RSTART - 1) "[REDACTED-LOCALE]"
            else out = out substr(r, 1, RSTART + RLENGTH - 1)
            r = substr(r, RSTART + RLENGTH)
        }
        return out r
    }
    function geoline(line,   out, r) {
        if (line ~ /[Tt]ime ?[Zz]one|TZ=|zoneinfo|localechooser|tzsetup|clock-setup|debconf|calamares|Calamares/) line = tzsub(line)
        if (line ~ /LANG=|LANGUAGE=|LC_[A-Z]+=|[Ll]ocale|localechooser|debconf|calamares|Calamares|language/) line = locsub(line)
        if (line ~ /[Cc]ountry|shortlist/) {
            out = ""; r = line
            while (match(r, /([Cc]ountry|shortlist)[^A-Za-z0-9\n]*[ =:][ \t]*\x27?[A-Z][A-Z]([^A-Za-z0-9]|$)/)) {
                out = out substr(r, 1, RSTART + RLENGTH - 1)
                sub(/[A-Z][A-Z]([^A-Za-z0-9]|$)$/, "[REDACTED-GEO]&", out)
                sub(/\[REDACTED-GEO\][A-Z][A-Z]/, "[REDACTED-GEO]", out)
                r = substr(r, RSTART + RLENGTH)
            }
            line = out r
        }
        gsub(/tzsetup\/country\/[A-Z][A-Z]/, "tzsetup/country/[REDACTED-GEO]", line)
        gsub(/localechooser\/countrylist\/[A-Za-z_]+/, "localechooser/countrylist/[REDACTED-GEO]", line)
        return line
    }
    BEGIN {
        HANCH = "^[A-Z][a-z][a-z] [ 0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] |^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+([-+][0-9][0-9]:?[0-9][0-9]|Z)? "
        HCTX = "_HOSTNAME=|[Hh]ostname=|[Hh]ostname:[ \t]*|[Hh]ostname to:[ \t]*|thumbs-|\\\\?\"[A-Za-z_]*[Hh]ostname\\\\?\"[ \t]*:[ \t]*\\\\?\"|[Hh]ostname set to <|set-hostname[ \t]+|[Hh]ostname changed from \"|\" to \"|Linux |hostnamectl( set-hostname| hostname)[ \t]+"
        # Account-name contexts: home paths and systemd-escaped home units,
        # environment and audit key=value pairs, id(1) and polkit forms, PAM,
        # logind, lightdm, pkexec, sudo, su, sshd, cron, usermod and useradd
        # phrasing, the collector own "Real User:" rows and JSON user keys.
        # passwd and group records, ls/ps/who columns and NAME(uid=N) are
        # handled by grp, cols and redps.
        UCTX = "/home/|home-|/run/user/[0-9]+/|/var/lib/lightdm/data/|(SUDO_)?USER=|LOGNAME=|[Ll]ogname=|r?user=|[ug]id=[0-9]+\\(|(groups=|,)[0-9]+\\(|[Ff]or user \\(?|[Oo]f [Uu]ser |[Rr]eal [Uu]ser:?[ \t]*|[Uu]ser:[ \t]*|[Uu]sername:[ \t]*|unix-user:|[ \t]-u[ \t]+|--user(-override)?[ =]|--owner[ =]|sudo(\\[[0-9]+\\])?:[ \t]+|pkexec(\\[[0-9]+\\])?:[ \t]+|\\\\?\"(user|username|owner|login|groupname)\\\\?\"[ \t]*:[ \t]*\\\\?\"|[Uu]ser override:[ \t]*|Requested-By:[ \t]*|[Ss]tarted for |[Aa]uthentication for |[Uu]ser(name)? \x27|new name: |[Aa]dd \x27|[Cc]hange \x27|\x27 to \x27|[Pp]assword for \\[?|runtime dirs |CRON\\[[0-9]+\\]: \\(|\\(to [A-Za-z0-9_.-]+\\) |Accepted [A-Za-z0-9-]+ for |[Ff]ailed [A-Za-z0-9-]+ for (invalid user )?|[Ii]nvalid user |[Pp]assword changed for |[Cc]ompleted for |[Oo]wnership set to |for \x27"
        FCTX = "[Ff]ull ?name:[ \t]*|\\\\?\"(full_?name|real_?name|gecos)\\\\?\"[ \t]*:[ \t]*\\\\?\""
        ALIASCTX = "\"aliases\"[ \t]*:[ \t]*\\[(\"[^\"]*\"[ \t]*,[ \t]*)*\""
        NSP = 5
        SPRE[5] = "User "; SSUF[5] = " is new"
        SPRE[1] = "";      SSUF[1] = "(uid="
        SPRE[2] = "User "; SSUF[2] = " authorized"
        SPRE[3] = "user "; SSUF[3] = " added"
        SPRE[4] = "Added "; SSUF[4] = " to group"
        m = 0
        load(ENVIRON["KDC_REDACT_HOSTNAMES"], "H", "HOSTNAME", HANCH, HCTX, "[A-Za-z0-9]")
        load(ENVIRON["KDC_REDACT_USERS"], "U", "USER", "^[ \t]*[0-9]+ - ", UCTX, "[A-Za-z0-9_]")
        load(ENVIRON["KDC_REDACT_FULLNAMES"], "F", "FULLNAME", "", FCTX, "[A-Za-z0-9]")
        # Longest first across all lists (insertion sort, m is small).
        for (i = 2; i <= m; i++) {
            for (j = i; j > 1 && length(H[j]) > length(H[j - 1]); j--) {
                t = H[j]; H[j] = H[j - 1]; H[j - 1] = t
                t = M[j]; M[j] = M[j - 1]; M[j - 1] = t
                t = K[j]; K[j] = K[j - 1]; K[j - 1] = t
                t = PB[j]; PB[j] = PB[j - 1]; PB[j - 1] = t
                t = T[j]; T[j] = T[j - 1]; T[j - 1] = t
                t = RF[j]; RF[j] = RF[j - 1]; RF[j - 1] = t
                t = TR[j]; TR[j] = TR[j - 1]; TR[j - 1] = t
            }
        }
        # debconf records (questions.dat / templates.dat) whose values are
        # personal or location data, and the token each value becomes.
        DC["passwd/user-fullname"] = "[REDACTED-FULLNAME]"
        DC["passwd/username"] = "[REDACTED-USER]"
        DC["netcfg/get_hostname"] = "[REDACTED-HOSTNAME]"
        DC["netcfg/hostname"] = "[REDACTED-HOSTNAME]"
        DC["netcfg/get_domain"] = "[REDACTED-HOSTNAME]"
        n = split("time/zone debian-installer/country debian-installer/locale debian-installer/language debconf/language localechooser/preferred-locale localechooser/shortlist localechooser/languagelist localechooser/supported-locales mirror/country mirror/http/countries mirror/https/countries keyboard-configuration/layout keyboard-configuration/layoutcode keyboard-configuration/variant keyboard-configuration/variantcode keyboard-configuration/xkb-keymap", G, " ")
        for (i = 1; i <= n; i++) DC[G[i]] = "[REDACTED-GEO]"
        rec = ""
    }
    {
        line = $0
        # ---- debconf record state (one record per blank-line block)
        if (line ~ /^Name: /) {
            rec = substr(line, 7)
            if (rec ~ /^tzsetup\/country\// || rec ~ /^localechooser\/countrylist\//) rtok = "[REDACTED-GEO]"
            else rtok = (rec in DC) ? DC[rec] : ""
        } else if (line == "") {
            rec = ""; rtok = ""
        } else if (rtok != "") {
            if (line ~ /^[A-Za-z][A-Za-z0-9_.-]*: / && line !~ /^(Name|Template|Type|Owners|Flags|Description|Extended_description)[^:]*: /)
                line = substr(line, 1, index(line, ": ") + 1) rtok
            else if (line ~ /^ [A-Za-z_-]+ = /)
                line = substr(line, 1, index(line, " = ") + 2) rtok
        }
        # ---- direct records
        if (line ~ /[Ii]nstall fullname:[ \t]*[^ \t]/) { match(line, /[Ii]nstall fullname:[ \t]*/); line = substr(line, 1, RSTART + RLENGTH - 1) "[REDACTED-FULLNAME]" }
        if (line ~ /[Ii]nstall username:[ \t]*[^ \t]/) { match(line, /[Ii]nstall username:[ \t]*/); line = substr(line, 1, RSTART + RLENGTH - 1) "[REDACTED-USER]" }
        # passwd record of a human account: GECOS (field 5) is the full name.
        if (line ~ /^[A-Za-z0-9_.-]+:[^:]*:[0-9]+:[0-9]+:[^:]+:[^:]*:[^:]*$/) {
            nf5 = split(line, PF, ":")
            if (nf5 == 7 && PF[3] + 0 >= 1000 && PF[3] + 0 <= 59999 && PF[5] !~ /^,*$/)
                line = PF[1] ":" PF[2] ":" PF[3] ":" PF[4] ":[REDACTED-FULLNAME]:" PF[6] ":" PF[7]
        }
        line = geoline(line)
        if (m == 0) { print line; next }
        # ---- word-mode names, longest first, anywhere in the text
        for (i = 1; i <= m; i++) {
            if (TR[i] != "" && index(line, TR[i]) > 0) line = redw(line, TR[i], T[i], PB[i])
            if (M[i] == "W" && index(line, H[i]) > 0) line = redw(line, H[i], T[i], PB[i])
        }
        # ---- context-mode names, per segment between JSON \n escapes
        anyc = 0
        for (i = 1; i <= m; i++) if (M[i] == "C" && index(line, H[i]) > 0) { anyc = 1; break }
        if (anyc) {
            if (index(line, "\\n") == 0) line = csegment(line)
            else {
                out = ""; r = line
                while ((q = index(r, "\\n")) > 0) {
                    out = out csegment(substr(r, 1, q - 1)) "\\n"
                    r = substr(r, q + 2)
                }
                line = out csegment(r)
            }
        }
        print line
    }'
}

# v1.8: normalise one hostname candidate. A domain suffix is removed only
# when the text after the first dot starts with a letter (host.local,
# host.example.org). Pool names such as Windows8.1-Pro or Ubuntu-24.04-LTS
# keep their dots, because there the dot is part of a version number.
kdc_norm_hostname() {
    local n="${1%$'\r'}" rest
    n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
    if [[ "$n" == *.* ]]; then
        rest="${n#*.}"
        [[ "$rest" =~ ^[A-Za-z] ]] && n="${n%%.*}"
    fi
    printf '%s' "$n"
}

# v1.8: build the hostname redaction list used by the last stage of
# redact_secrets. Sources, current and historical:
#   hostname, /etc/hostname, the 127.0.1.1 line of /etc/hosts
#   every _HOSTNAME the journal recorded
#   the host column of /var/log/syslog*, auth.log*, kern.log* (rotated and
#     compressed included), which reach further back than the journal
#   Kodachi hostname-aliases.json and hostname-log.log* ("changed hostname
#     to: X") under both hooks roots
# Generic names are skipped because redacting them would destroy ordinary
# text ("kodachi" is the default hostname AND the product name). The current
# name is tagged CURRENT, the rest are numbered. Output entries are
# token:mode:name, longest name first (see the awk stage for W and C).
# v1.8 (inspector N6): each list source runs under its own timeout, and a
# source that hit it is recorded here so redaction-sweep.txt can say which
# names may be missing from the list. It lives in TEMP_DIR, never in the zip.
KDC_LIST_TIMEOUTS="${TEMP_DIR}/.list-timeouts"
: > "$KDC_LIST_TIMEOUTS"
kdc_src() {
    # kdc_src <label> <seconds> <command...>: run one list source bounded.
    local label="$1" secs="$2" rc
    shift 2
    timeout -k 5 "$secs" "$@" < /dev/null 2>/dev/null
    rc=$?
    if [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; then
        printf '%s: timed out after %ss, names from it may be missing\n' "$label" "$secs" >> "$KDC_LIST_TIMEOUTS" 2>/dev/null
    fi
    return 0
}
kdc_build_hostname_list() {
    local cur
    cur=$(kdc_norm_hostname "$(hostname 2>/dev/null)")
    {
        printf '%s\n' "$cur"
        # /etc/hostname often has no trailing newline, which glued it to the
        # next source's first line.
        cat /etc/hostname 2>/dev/null; echo
        awk '$1 == "127.0.1.1" { for (i = 2; i <= NF; i++) print $i }' /etc/hosts 2>/dev/null
        kdc_src "hostname list: journalctl --field=_HOSTNAME" 30 journalctl --field=_HOSTNAME --no-pager
        for _sl in /var/log/syslog* /var/log/auth.log* /var/log/kern.log*; do
            [[ -f "$_sl" ]] || continue
            kdc_src "hostname list: $_sl" 60 zcat -f -- "$_sl" \
                | LC_ALL=C awk '
                    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { h = $2 }
                    $1 ~ /^[A-Z][a-z][a-z]$/ && $3 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ { h = $4 }
                    h != "" { if (!s[h]++) print h; h = "" }'
        done
        for _hr in /opt/kodachi/dashboard/hooks "${REAL_HOME}/dashboard/hooks"; do
            if [[ -f "$_hr/results/hostname-aliases.json" ]]; then
                tr -d '\n' < "$_hr/results/hostname-aliases.json" 2>/dev/null \
                    | grep -oE '"aliases"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
                    | grep -oE '"[^"]+"' | grep -v '^"aliases"$' | tr -d '"'
            fi
            for _hl in "$_hr"/logs/hostname-log.log*; do
                [[ -f "$_hl" ]] || continue
                kdc_src "hostname list: $_hl" 30 zcat -f -- "$_hl" \
                    | sed -n 's/.*changed hostname to:[[:space:]]*\([^[:space:]]*\).*/\1/p'
            done
        done
    } | while IFS= read -r n; do
        n=$(kdc_norm_hostname "$n")
        [[ ${#n} -ge 3 ]] || continue
        [[ "$n" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || continue
        [[ "$n" =~ ^[0-9.-]+$ ]] && continue
        case "${n,,}" in
            localhost|kodachi|debian|ubuntu|live|user|root|none|unknown|linux|kali|host|default|false|true|null) continue ;;
        esac
        printf '%s %s\n' "${#n}" "$n"
    done | sort -rn -k1,1 | awk '!seen[$2]++ { print $2 }' | {
        idx=0; out=""
        while IFS= read -r n; do
            [[ -n "$n" ]] || continue
            if [[ "$n" == "$cur" ]]; then
                tok="CURRENT"
            else
                idx=$((idx + 1)); tok="$idx"
            fi
            # The machine's own current name is the identifier the bundle most
            # needs to lose, and as context-only it survived wherever no
            # hostname keyword preceded it: uname -a, hostname.txt, the iostat
            # header, collection-info (measured on a VM named Serenity, 12 hits).
            # A current name of 5+ characters is replaced anywhere.
            if [[ "$n" == "$cur" ]] && [[ ${#n} -ge 5 ]]; then
                mode="W"
            elif [[ "$n" =~ ^[A-Za-z]+$ ]] || [[ ${#n} -eq 3 ]]; then
                mode="C"
            else
                mode="W"
            fi
            out="${out:+$out }${tok}:${mode}:${n}"
        done
        printf '%s' "$out"
    }
}
KDC_REDACT_HOSTNAMES=$(kdc_build_hostname_list)
export KDC_REDACT_HOSTNAMES

# v1.8: build the account-name redaction list used by the same stage.
# Human accounts only: uid 1000 to 59999 from the passwd database, plus
# SUDO_USER and the detected real user when they are human accounts too.
# Never redacted: root, nobody, system and service accounts (uid below 1000,
# debian-tor, kodachi service users), and "kodachi", which is the live
# default account AND the product name. Mode C (context only) when the name
# is 4 characters or shorter, or is an ordinary word (the system word list
# when present, plus a built-in list of words people commonly use as login
# names); every other name is mode W and is replaced anywhere in text.
kdc_build_user_list() {
    local words=/usr/share/dict/words
    {
        getent passwd 2>/dev/null | awk -F: '$3 >= 1000 && $3 <= 59999 { print $1 }'
        for _u in "${SUDO_USER:-}" "${REAL_USER:-}"; do
            [[ -n "$_u" ]] || continue
            _uid=$(id -u "$_u" 2>/dev/null) || continue
            [[ "$_uid" =~ ^[0-9]+$ ]] && (( _uid >= 1000 && _uid <= 59999 )) && printf '%s\n' "$_u"
        done
    } | while IFS= read -r n; do
        [[ ${#n} -ge 2 ]] || continue
        [[ "$n" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || continue
        case "${n,,}" in
            root|nobody|kodachi|debian-tor|live|user|guest) continue ;;
        esac
        printf '%s %s\n' "${#n}" "$n"
    done | sort -rn -k1,1 | awk '!seen[$2]++ { print $2 }' | {
        idx=0; out=""
        while IFS= read -r n; do
            [[ -n "$n" ]] || continue
            idx=$((idx + 1))
            mode="W"
            if [[ ${#n} -le 4 ]]; then
                mode="C"
            else
                case "${n,,}" in
                    admin|master|owner|server|client|default|public|private|secret|shared|backup|office|home|work|data|info|support|system|linux|debian|ubuntu|student|teacher|family|music|video|games|developer|hacker|ghost|shadow|phoenix|dragon|tiger|eagle|falcon|hunter|ninja|samurai|matrix|alpha|gamma|delta|omega|sigma|test|tester|demo|light|night|storm|river|ocean|forest|anonymous|privacy|secure|freedom|liberty|tails|whonix) mode="C" ;;
                esac
                if [[ "$mode" == "W" ]] && [[ -r "$words" ]] && grep -qixF -- "$n" "$words" 2>/dev/null; then
                    mode="C"
                fi
            fi
            out="${out:+$out }${idx}:${mode}:${n}"
        done
        printf '%s' "$out"
    }
}
KDC_REDACT_USERS=$(kdc_build_user_list)
export KDC_REDACT_USERS

# v1.8 (inspector N1): the full name of each human account (GECOS field 5,
# up to the first comma). The installer log and debconf questions.dat carried
# it verbatim. Entries are token:mode:name with space, colon and percent
# percent-encoded, because a full name usually contains a space. Mode C (only
# after "fullname:" and JSON full_name/real_name/gecos keys) for a single
# word of 4 characters or less or an ordinary word; otherwise mode W.
kdc_build_fullname_list() {
    local words=/usr/share/dict/words
    getent passwd 2>/dev/null \
        | awk -F: '$3 >= 1000 && $3 <= 59999 { split($5, g, ","); if (g[1] != "") print g[1] }' \
        | while IFS= read -r n; do
            n="${n#"${n%%[![:space:]]*}"}"; n="${n%"${n##*[![:space:]]}"}"
            [[ ${#n} -ge 2 ]] || continue
            case "${n,,}" in
                kodachi|root|user|guest|admin|administrator|live|"live user"|"kodachi user"|debian) continue ;;
            esac
            printf '%s\t%s\n' "${#n}" "$n"
        done | sort -rn -k1,1 | awk -F'\t' '!seen[$2]++ { print $2 }' | {
            idx=0; out=""
            while IFS= read -r n; do
                [[ -n "$n" ]] || continue
                idx=$((idx + 1))
                mode="W"
                if [[ "$n" != *" "* ]]; then
                    if [[ ${#n} -le 4 ]]; then
                        mode="C"
                    elif [[ -r "$words" ]] && grep -qixF -- "$n" "$words" 2>/dev/null; then
                        mode="C"
                    fi
                fi
                enc="${n//%/%25}"; enc="${enc// /%20}"; enc="${enc//:/%3A}"
                out="${out:+$out }${idx}:${mode}:${enc}"
            done
            printf '%s' "$out"
        }
}
KDC_REDACT_FULLNAMES=$(kdc_build_fullname_list)
export KDC_REDACT_FULLNAMES

# Copy a file into the bundle THROUGH redact_secrets, preserving an optional
# relative sub-path. Truncates oversized files (still redacted).
# safe_exec runs its command in a child bash (see there), so the redactor must
# be visible to it. Two command strings pipe through it today (ps trees).
export -f redact_secrets

# v1.8: `systemctl status` exits 3 for a unit that is simply not running,
# which is the normal state of every oneshot that already finished and every
# unit whose Condition*= skipped it. safe_exec recorded that as
# "[EXIT CODE: 3] Command failed", so TRIAGE listed six healthy Kodachi units
# as failed probes (NA-Central-Hub bundle), and `status X || echo 'not found'`
# printed BOTH the status and "not found" for an inactive unit. Exit 3 now
# returns 0 and appends the properties that say WHY the unit is inactive.
# Every other status (4 = no such unit) is passed through unchanged.
kdc_unit_status() {
    local rc
    systemctl status "$@" --no-pager -l 2>&1
    rc=$?
    if [[ $rc -eq 3 ]]; then
        echo ""
        echo "[systemctl status exit 3: not active, which is a unit state and not a probe failure]"
        systemctl show "$@" -p Id,LoadState,UnitFileState,ActiveState,SubState,Result,ConditionResult,ConditionTimestamp,AssertResult,ExecMainStatus,InactiveEnterTimestamp 2>/dev/null
        return 0
    fi
    return $rc
}
export -f kdc_unit_status

# v1.7: every FILE that goes through the redactor goes through this instead.
# safe_exec bounds the producer with `timeout`, but the redaction of its
# output and every copied file was unbounded, so a single multi-megabyte
# single-line record could still stall the run with no [TIMEOUT] row, and the
# INT trap then deleted the staging tree (inspector, 2026-09-06). On expiry
# the destination holds whatever was redacted so far plus a visible marker:
# nothing unredacted is ever written, and the timing log names the file.
redact_bounded() {
    local rc
    # `set -o pipefail` inside the child: without it the pipeline's status is
    # the last awk's, so a failure of the awk or sed stage before it was
    # invisible and the sweep below would then have shipped a truncated file
    # believing it was complete (inspector).
    timeout -k 10 "${KDC_REDACT_TIMEOUT:-300}" bash -c 'set -o pipefail; redact_secrets'
    rc=$?
    if [[ $rc -eq 124 ]] || [[ $rc -eq 137 ]]; then
        printf '\n[REDACTION TIMEOUT after %ss: the rest of this file was NOT copied]\n' "${KDC_REDACT_TIMEOUT:-300}"
        [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8ss rc=124 [redaction timeout, file truncated at the marker]\n' "${KDC_REDACT_TIMEOUT:-300}" >> "$CMD_TIMING_LOG" 2>/dev/null
        # RETURNS 0 ON PURPOSE. Every caller is shaped
        #     redact_bounded < src > dest || echo "Failed to copy..." > dest.error
        # so a non-zero here wrote a `.error` sibling claiming the copy failed
        # NEXT TO a file that is present, correctly redacted and merely
        # truncated at a visible marker (inspector measured 2,560,068 good
        # bytes beside a "Failed to copy" note). The marker in the file and
        # the row in command-timing.txt are the report; a false error is not.
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        # A GENUINE redactor failure. Fail CLOSED: say so in the output rather
        # than letting a caller's `||` arm leave, or a sweep leave in place,
        # anything that did not pass through the redactor.
        printf '\n[REDACTION FAILED with status %s: this file was NOT fully redacted and its remainder was withheld]\n' "$rc"
        [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8s rc=%-3s [redaction FAILED, remainder withheld]\n' "-" "$rc" >> "$CMD_TIMING_LOG" 2>/dev/null
    fi
    return $rc
}

safe_copy_redacted() {
    local src="$1"
    local dest_dir="$2"
    local rel="${3:-$(basename "$1")}"
    local dest="$dest_dir/$rel"
    local max_size=$((50 * 1024 * 1024))

    if [[ ! -f "$src" ]]; then
        echo "File not found: $src" > "${dest_dir}/$(basename "$src").missing"
        return
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true

    local fsz _pd=0
    [[ -f "$dest" ]] && _pd=$(stat -c%s "$dest" 2>/dev/null || echo 0)
    fsz=$(stat -c%s "$src" 2>/dev/null || echo 0)
    local _t0 _t1
    _t0=$(date +%s.%N)
    if [[ $fsz -gt $max_size ]]; then
        tail -c 50M "$src" 2>/dev/null | redact_bounded > "$dest" 2>/dev/null || true
        echo "[Original $fsz bytes; truncated to last 50MB, redacted]" >> "$dest"
    else
        redact_bounded < "$src" > "$dest" 2>/dev/null \
            || echo "Failed to copy (redacted): $src" > "${dest}.error"
    fi
    _t1=$(date +%s.%N)
    # v1.7: file copies are timed like commands, so a slow redaction on one
    # large single-line file shows up by name in command-timing-slowest.txt.
    [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8.2fs rc=%-3s [copy %s bytes] %s\n' "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN{print b-a}')" "0" "$fsz" "$src" >> "$CMD_TIMING_LOG" 2>/dev/null
    should_mark "$dest" "$_pd" && mark_redacted "$dest"
}

# Run a command as the real (non-root) user with full graphical-session env so
# that systemctl --user, journalctl --user, xfconf-query, xrandr, dconf, etc.
# all reach the right session bus and runtime directory. We do not assume the
# user is root, if collector is run as the user already, fall back to plain
# eval. audit 2026-05-07 (login-stall investigation): without this helper,
# user-systemd state and ~/.xsession-errors were never captured, so xfce4
# session hangs were undiagnosable.
REAL_UID=$(id -u "${REAL_USER}" 2>/dev/null || echo "")
safe_exec_user() {
    local output_file="$1"
    shift
    local cmd="$*"
    local output rc pre=0

    [[ -f "$output_file" ]] && pre=$(stat -c%s "$output_file" 2>/dev/null || echo 0)

    if [[ -z "$REAL_UID" ]]; then
        echo "[SKIP] real user UID unknown for: $cmd" >> "$output_file"
        return
    fi

    if [[ "$(id -u)" == "0" ]] && [[ -n "${REAL_USER:-}" ]] && [[ "$REAL_USER" != "root" ]]; then
        # Running as root, drop to real user with their session env restored.
        # v1.7: stdin from /dev/null and a timeout, for the reasons in safe_exec.
        output=$(timeout -k 10 "${KDC_CMD_TIMEOUT:-180}" sudo -u "$REAL_USER" \
            XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" \
            DISPLAY="${DISPLAY:-:0}" \
            HOME="$REAL_HOME" \
            bash -lc "$cmd" < /dev/null 2>&1)
        rc=$?
    else
        output=$(timeout -k 10 "${KDC_CMD_TIMEOUT:-180}" bash -c "$cmd" < /dev/null 2>&1)
        rc=$?
    fi
    [[ -n "${CMD_TIMING_LOG:-}" ]] && printf '%8s rc=%-3s [user] %s\n' "-" "$rc" "$(printf '%s' "$cmd" | redact_secrets)" >> "$CMD_TIMING_LOG" 2>/dev/null

    local redacted_cmd
    redacted_cmd=$(printf '%s\n' "$cmd" | redact_secrets)
    if [[ -n "$output" ]]; then
        output=$(printf '%s\n' "$output" | redact_bounded)
    fi

    if [[ $rc -ne 0 ]]; then
        echo "[EXIT CODE: $rc] Command failed: $redacted_cmd" >> "$output_file"
        [[ -n "$output" ]] && echo "$output" >> "$output_file"
    elif [[ -z "$output" ]]; then
        echo "[EXIT CODE: 0] Command produced no output: $redacted_cmd" >> "$output_file"
    else
        echo "$output" >> "$output_file"
    fi
    should_mark "$output_file" "$pre" && mark_redacted "$output_file"
}

# Copy a file owned by REAL_USER (e.g., ~/.xsession-errors). Falls back to
# plain copy if collector is already running as that user.
safe_copy_user() {
    local src="$1"
    local dest="$2"

    if [[ "$src" != /* ]]; then
        # Resolve relative-to-home paths.
        src="${REAL_HOME}/${src#~/}"
    fi

    if [[ ! -e "$src" ]]; then
        echo "File not found: $src" > "${dest}/$(basename "$src").missing"
        return
    fi

    local _pu=0
    [[ -f "${dest}/$(basename "$src")" ]] && _pu=$(stat -c%s "${dest}/$(basename "$src")" 2>/dev/null || echo 0)

    if [[ "$(id -u)" == "0" ]]; then
        # Use sudo cat to preserve permissions / handle non-root home dirs, then redact.
        sudo -u "$REAL_USER" cat "$src" 2>/dev/null | redact_bounded > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy (perm denied): $src" > "${dest}/$(basename "$src").error"
    else
        redact_bounded < "$src" > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy: $src" > "${dest}/$(basename "$src").error"
    fi
    should_mark "${dest}/$(basename "$src")" "$_pu" && mark_redacted "${dest}/$(basename "$src")"
}

# Like safe_copy_user, but pipes the content through redact_secrets.
# User-session logs (~/.xsession-errors) capture app stderr that has been
# observed to contain Discord account/session identifiers and similar
# sensitive data, so they must not enter the bundle verbatim.
safe_copy_user_redacted() {
    local src="$1"
    local dest="$2"

    if [[ "$src" != /* ]]; then
        src="${REAL_HOME}/${src#~/}"
    fi

    if [[ ! -e "$src" ]]; then
        echo "File not found: $src" > "${dest}/$(basename "$src").missing"
        return
    fi

    local _pu=0
    [[ -f "${dest}/$(basename "$src")" ]] && _pu=$(stat -c%s "${dest}/$(basename "$src")" 2>/dev/null || echo 0)

    if [[ "$(id -u)" == "0" ]]; then
        sudo -u "$REAL_USER" cat "$src" 2>/dev/null | redact_bounded \
            > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy (perm denied): $src" > "${dest}/$(basename "$src").error"
    else
        redact_bounded < "$src" > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy: $src" > "${dest}/$(basename "$src").error"
    fi
    should_mark "${dest}/$(basename "$src")" "$_pu" && mark_redacted "${dest}/$(basename "$src")"
}

# ---- Interactive category selection menu ----

show_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         KODACHI OS DEBUG COLLECTOR v1.8                  ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "Select what to collect (all selected by default):"
    echo ""
    for i in "${!CAT_LABEL[@]}"; do
        local num=$((i + 1))
        local mark="X"
        local color="${GREEN}"
        if [[ "${CAT_ENABLED[$i]}" == "0" ]]; then
            mark=" "
            color="${RED}"
        fi
        printf "  ${color}[%s]${NC} %2d. ${BOLD}%-22s${NC} %s\n" "$mark" "$num" "${CAT_LABEL[$i]}" "${CAT_DESC[$i]}"
    done
    echo ""
    echo -e "  ${YELLOW}No IPs, passwords, browsing data, or personal files are collected.${NC}"
    echo ""
    echo -e "  Toggle: type number (${CYAN}1-13${NC}) | ${CYAN}a${NC}=all | ${CYAN}n${NC}=none | ${CYAN}ENTER${NC}=start"
}

interactive_select() {
    local input
    while true; do
        show_menu
        printf "> "
        read -r input < /dev/tty || break

        # Empty input = proceed with current selection
        if [[ -z "$input" ]]; then
            break
        fi

        case "$input" in
            a|A)
                for i in "${!CAT_ENABLED[@]}"; do CAT_ENABLED[$i]=1; done
                ;;
            n|N)
                for i in "${!CAT_ENABLED[@]}"; do CAT_ENABLED[$i]=0; done
                ;;
            [1-9]|1[0-3])
                local idx=$((input - 1))
                if [[ $idx -ge 0 ]] && [[ $idx -lt ${#CAT_ENABLED[@]} ]]; then
                    if [[ "${CAT_ENABLED[$idx]}" == "1" ]]; then
                        CAT_ENABLED[$idx]=0
                    else
                        CAT_ENABLED[$idx]=1
                    fi
                fi
                ;;
            *)
                # Ignore invalid input
                ;;
        esac
    done
}

# Banner (shown when menu is skipped)
show_banner() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         KODACHI OS DEBUG COLLECTOR v1.8                  ║"
    echo "║    Comprehensive System Diagnostics Tool                 ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "v1.8 (2026-09-17): the zip name no longer carries the hostname, and"
    echo "current and previous hostnames and human account names are redacted"
    echo "inside the bundle; LUKS2"
    echo "key slots are counted; inactive units are no longer failed probes;"
    echo "installed-but-unloaded kodachi units, real installer logs, Secure Boot"
    echo "state and held packages are collected; installer logs are copied once;"
    echo "no root dbus-daemon is left behind."
    echo "Privacy note: a login name that is 4 characters or shorter, or an"
    echo "ordinary dictionary word, is redacted only where the text marks it as an"
    echo "account (/home paths, USER=, uid=N(name), ls/stat/ps/top/who columns,"
    echo "passwd and group records). The same word in free prose is left as is."
    echo ""
    echo "v1.7 (2026-09-06): the curl | sudo bash path now completes (it used to"
    echo "stop silently at the Tor step with no zip); every probe is bounded by a"
    echo "timeout and timed; the bundle now carries a TRIAGE.txt index, every"
    echo "hook binary's version/md5/signature state, integrity-check and"
    echo "deps-checker verdicts, apt channel state, Kodachi /etc and per-user"
    echo "state, and the exact command that produced every file."
    echo ""
    echo "v1.6 (audit 2026-08-19): redaction hardened AND made non-destructive."
    echo "Now redacted: passphrases containing spaces, Authorization/Cookie"
    echo "headers, WiFi SSIDs, Tor HashedControlPassword, dash-form MACs."
    echo "No longer destroyed: version strings, dpkg rows, /etc/passwd lines,"
    echo "log timestamps, loopback/link-local/ULA IPv6. Large command output"
    echo "streams to disk and is redacted once instead of two or three times."
    echo ""
    echo "v1.5 (audit 2026-05-08): autostart Phase= summary table, dbus alias"
    echo "state, masked-services list, install-method detect (Calamares vs"
    echo "debian-installer), live xfce4-session pid strace/wchan, /etc/X11/"
    echo "Xsession + /usr/bin/startxfce4 + /etc/xdg/xfce4/xinitrc capture,"
    echo "pcscd state, pkcs11-register inspect, opensc autostart triage."
    echo ""
    echo "v1.4 (audit 2026-05-07): user-systemd, ~/.xsession-errors, xfconf,"
    echo "autostart, Calamares, kodachi-* logs, prev-boot journals, ordering"
    echo "cycles, cgroup hierarchy."
    echo ""
    echo "Collecting: version, live/installed, LUKS, nuke, Tor, VPN,"
    echo "  boot logs, hardware, network, Kodachi services, and more."
    echo ""
    echo -e "${YELLOW}Privacy:${NC} No IP addresses, browsing data, passwords, or personal"
    echo "  files are collected. WiFi credentials and MACs are redacted."
    echo ""
    echo "Output will be saved to: ${ZIP_FILE}"
    echo ""
}

# ---- Run interactive menu or show banner ----
if [[ "$SKIP_MENU" == "0" ]] && [[ -e "/dev/tty" ]]; then
    interactive_select
    # Print a compact summary of what will be collected
    echo ""
    ENABLED_LIST=""
    for i in "${!CAT_ENABLED[@]}"; do
        if [[ "${CAT_ENABLED[$i]}" == "1" ]]; then
            [[ -n "$ENABLED_LIST" ]] && ENABLED_LIST+=", "
            ENABLED_LIST+="${CAT_LABEL[$i]}"
        fi
    done
    if [[ -z "$ENABLED_LIST" ]]; then
        echo -e "${RED}No categories selected. Nothing to collect.${NC}"
        rm -rf "$TEMP_DIR"
        exit 0
    fi
    echo -e "${GREEN}Collecting:${NC} ${ENABLED_LIST}"
    echo -e "Output: ${ZIP_FILE}"
    echo ""
else
    show_banner
fi

# ---- Compute dynamic step count ----
ENABLED_COUNT=0
for e in "${CAT_ENABLED[@]}"; do
    [[ "$e" == "1" ]] && ENABLED_COUNT=$((ENABLED_COUNT + 1))
done
TOTAL_STEPS=$((ENABLED_COUNT + 3)) # +3 for metadata, zip, cleanup

# ============================================================================
# CATEGORY 0: KODACHI META SUMMARY (version, live/installed, LUKS, nuke, etc.)
# ============================================================================
if [[ "${CAT_ENABLED[0]}" == "1" ]]; then
progress "Collecting Kodachi meta information..."

mkdir -p "$COLLECTION_DIR/00-kodachi-meta"

(
set +e
echo "=============================================="
echo "   KODACHI OS - SYSTEM META SUMMARY"
echo "=============================================="
echo ""
echo "Collection Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Hostname:        $(hostname 2>/dev/null || echo 'unknown')"
echo "Real User:       ${REAL_USER}"
echo "Kernel:          $(uname -r 2>/dev/null || echo 'unknown')"
echo ""

# ------- Kodachi Version -------
echo "----------------------------------------------"
echo "  KODACHI VERSION"
echo "----------------------------------------------"

# Try multiple version sources
KODACHI_VERSION="unknown"

if [[ -f "/etc/kodachi-version" ]]; then
    # /etc/kodachi-version is a multi-line ASCII banner. Display the full
    # content for context but extract ONLY the "Version: X.Y.Z" line into
    # the scalar, capturing the whole banner into $KODACHI_VERSION breaks
    # downstream consumers (meta-vars.txt, summary box).
    echo "kodachi-version file content:"
    sed 's/^/  /' /etc/kodachi-version 2>/dev/null
    KV_LINE=$(grep -oP '^\s*Version:\s*\K[0-9][0-9A-Za-z.+-]*' /etc/kodachi-version 2>/dev/null | head -1)
    if [[ -n "$KV_LINE" ]]; then
        KODACHI_VERSION="$KV_LINE"
        echo "Version (parsed): $KODACHI_VERSION"
    fi
fi

if [[ -f "/etc/kodachi_version" ]]; then
    echo "Version (kodachi_version file): $(cat /etc/kodachi_version 2>/dev/null)"
fi

# Check build-meta.json (primary Kodachi version source)
for build_meta in /opt/*/dashboard/hooks/config/build-meta.json "${REAL_HOME}"/*/dashboard/hooks/config/build-meta.json /opt/kodachi*/dashboard/hooks/config/build-meta.json; do
    if [[ -f "$build_meta" ]]; then
        echo "build-meta.json ($build_meta):"
        cat "$build_meta" 2>/dev/null | sed 's/^/  /'
        # Extract version and build info from build-meta
        if [[ "$KODACHI_VERSION" == "unknown" ]]; then
            BM_VER=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$build_meta" 2>/dev/null | head -1)
            if [[ -n "$BM_VER" ]]; then
                KODACHI_VERSION="$BM_VER"
            fi
        fi
        NIGHTLY_VERSION=$(grep -oP '"nightly_version"\s*:\s*"\K[^"]+' "$build_meta" 2>/dev/null | head -1)
        BUILD_NUMBER=$(grep -oP '"build_number"\s*:\s*\K[0-9]+' "$build_meta" 2>/dev/null | head -1)
        PACK_DATE=$(grep -oP '"pack_date"\s*:\s*"\K[^"]+' "$build_meta" 2>/dev/null | head -1)
    fi
done

# Check os-release for kodachi info
if grep -qi kodachi /etc/os-release 2>/dev/null; then
    echo "OS Release:"
    grep -i -E "(PRETTY_NAME|VERSION|NAME)" /etc/os-release 2>/dev/null | sed 's/^/  /'
    # Extract version from os-release if not already found
    if [[ "$KODACHI_VERSION" == "unknown" ]]; then
        OS_VER=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [[ -n "$OS_VER" ]]; then
            KODACHI_VERSION="$OS_VER"
        fi
    fi
fi

# Check lsb_release
if command -v lsb_release &>/dev/null; then
    echo "LSB Release: $(lsb_release -d 2>/dev/null | cut -f2)"
fi

# Check main-info.json if present
for info_json in /opt/*/installers/main-info.json /opt/kodachi*/main-info.json "${REAL_HOME}"/*/installers/main-info.json; do
    if [[ -f "$info_json" ]]; then
        echo "main-info.json ($info_json):"
        cat "$info_json" 2>/dev/null | sed 's/^/  /'
    fi
done

# Check installed kodachi packages
echo ""
echo "Installed Kodachi packages:"
dpkg -l 2>/dev/null | grep -i kodachi | sed 's/^/  /' || echo "  (none found via dpkg)"

echo ""

# ------- Live vs Installed -------
echo "----------------------------------------------"
echo "  SYSTEM TYPE: LIVE vs INSTALLED"
echo "----------------------------------------------"

SYSTEM_TYPE="UNKNOWN"

# Method 1: /run/live directory
if [[ -d "/run/live" ]]; then
    SYSTEM_TYPE="LIVE"
    echo "Detection: /run/live exists -> LIVE SYSTEM"
    echo "Live medium contents:"
    ls -la /run/live/ 2>/dev/null | sed 's/^/  /'
    if [[ -d "/run/live/medium" ]]; then
        echo "Live medium mount:"
        ls -la /run/live/medium/ 2>/dev/null | sed 's/^/  /'
    fi
    if [[ -d "/run/live/persistence" ]]; then
        echo "Persistence: ENABLED"
        ls -la /run/live/persistence/ 2>/dev/null | sed 's/^/  /'
    else
        echo "Persistence: NOT DETECTED"
    fi
fi

# Method 2: Kernel cmdline
if grep -q "boot=live" /proc/cmdline 2>/dev/null; then
    SYSTEM_TYPE="LIVE"
    echo "Detection: boot=live in kernel cmdline -> LIVE SYSTEM"
    echo "Boot params: $(cat /proc/cmdline 2>/dev/null)"
fi

# Method 3: Root filesystem type
ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")
echo "Root filesystem type: $ROOT_FS"
echo "Root source: $ROOT_SOURCE"

if [[ "$ROOT_FS" == "overlay" ]] || [[ "$ROOT_FS" == "tmpfs" ]] || [[ "$ROOT_FS" == "aufs" ]]; then
    SYSTEM_TYPE="LIVE"
    echo "Detection: Root is $ROOT_FS -> LIVE SYSTEM"
elif [[ "$ROOT_FS" == "ext4" ]] || [[ "$ROOT_FS" == "btrfs" ]] || [[ "$ROOT_FS" == "xfs" ]]; then
    if [[ "$SYSTEM_TYPE" == "UNKNOWN" ]]; then
        SYSTEM_TYPE="INSTALLED"
        echo "Detection: Root is $ROOT_FS on real partition -> INSTALLED SYSTEM"
    fi
fi

# Method 4: Check if /cdrom or /media/cdrom exists
if [[ -d "/cdrom" ]] || [[ -d "/lib/live" ]]; then
    echo "Live system libraries/media detected"
    [[ "$SYSTEM_TYPE" == "UNKNOWN" ]] && SYSTEM_TYPE="LIVE"
fi

echo ""
echo ">>> SYSTEM TYPE: $SYSTEM_TYPE <<<"
echo ""

# ------- LUKS Encryption -------
echo "----------------------------------------------"
echo "  LUKS ENCRYPTION STATUS"
echo "----------------------------------------------"

LUKS_ACTIVE="NO"

# Check for dm-crypt devices
echo "DM-Crypt mappings:"
if command -v dmsetup &>/dev/null; then
    DMSETUP_OUT=$(dmsetup ls 2>/dev/null)
    if [[ -n "$DMSETUP_OUT" ]] && [[ "$DMSETUP_OUT" != "No devices found" ]]; then
        echo "$DMSETUP_OUT" | sed 's/^/  /'
    else
        echo "  (no dm-crypt devices)"
    fi
fi

# Check lsblk for crypto_LUKS
echo ""
echo "LUKS partitions (lsblk):"
LUKS_PARTS=$(lsblk -f 2>/dev/null | grep -i "crypto_LUKS" || true)
if [[ -n "$LUKS_PARTS" ]]; then
    LUKS_ACTIVE="YES"
    echo "$LUKS_PARTS" | sed 's/^/  /'
else
    echo "  (no LUKS partitions detected)"
fi

# Check /etc/crypttab
echo ""
echo "Crypttab:"
if [[ -f "/etc/crypttab" ]]; then
    cat /etc/crypttab 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/  /'
    [[ -n "$(cat /etc/crypttab 2>/dev/null | grep -v '^#' | grep -v '^$')" ]] && LUKS_ACTIVE="YES"
else
    echo "  /etc/crypttab not found"
fi

# Check blkid for LUKS
echo ""
echo "LUKS UUIDs (blkid):"
BLKID_LUKS=$(blkid 2>/dev/null | grep -i "LUKS" || true)
if [[ -n "$BLKID_LUKS" ]]; then
    LUKS_ACTIVE="YES"
    echo "$BLKID_LUKS" | sed 's/^/  /'
else
    echo "  (no LUKS entries in blkid)"
fi

# Try cryptsetup status on known mappings
echo ""
echo "Active LUKS volumes:"
if command -v cryptsetup &>/dev/null; then
    for dm_dev in /dev/mapper/*; do
        dm_name=$(basename "$dm_dev" 2>/dev/null)
        [[ "$dm_name" == "control" ]] && continue
        status=$(cryptsetup status "$dm_name" 2>/dev/null || true)
        if echo "$status" | grep -qi "active"; then
            LUKS_ACTIVE="YES"
            echo "  $dm_name: ACTIVE"
            echo "$status" | sed 's/^/    /'
        fi
    done
fi

# Check if root is on LUKS
echo ""
if echo "$ROOT_SOURCE" | grep -q "/dev/mapper"; then
    echo "Root partition is on dm-crypt: $ROOT_SOURCE"
    LUKS_ACTIVE="YES"
fi

echo ""
echo ">>> LUKS ENCRYPTION: $LUKS_ACTIVE <<<"
echo ""

# ------- Nuke Password -------
echo "----------------------------------------------"
echo "  NUKE PASSWORD STATUS"
echo "----------------------------------------------"

NUKE_STATUS="NOT DETECTED"

# Check if cryptsetup-nuke-password package is installed.
# audit 2026-05-10: dpkg -l | grep proved unreliable, observed bundle had
# "ii cryptsetup-nuke-password 8" in dpkg-list.txt yet the collector
# reported NOT INSTALLED. Likely cause: dpkg-query column wrap on narrow
# COLUMNS env in the collector context, where the package name was split
# across the "ii" status word and the next dpkg pager line. dpkg-query
# bypasses the formatter and queries the database directly.
if dpkg-query -W -f='${Status}' cryptsetup-nuke-password 2>/dev/null | grep -q '^install ok installed$'; then
    NUKE_STATUS="PACKAGE INSTALLED"
    echo "cryptsetup-nuke-password package: INSTALLED"
    dpkg -l cryptsetup-nuke-password 2>/dev/null | tail -1 | sed 's/^/  /'
else
    echo "cryptsetup-nuke-password package: NOT INSTALLED"
fi

# Check for nuke initramfs hook
if [[ -f "/usr/share/initramfs-tools/hooks/cryptsetup-nuke" ]] || [[ -f "/etc/initramfs-tools/hooks/cryptsetup-nuke" ]]; then
    NUKE_STATUS="HOOK PRESENT"
    echo "Nuke initramfs hook: FOUND"
fi

# v1.8: whether a nuke password is actually CONFIGURED is deliberately not
# probed. A bundle is shared with third parties, and "this disk has a nuke
# password" is exactly what an adversary holding the machine wants to know.
# Only the package state above is reported.

# Check LUKS key slots for nuke slot (slot 1 is typically nuke)
echo ""
echo "LUKS key slot analysis:"
if command -v cryptsetup &>/dev/null && [[ "$LUKS_ACTIVE" == "YES" ]]; then
    # Find LUKS devices
    for luks_dev in $(blkid 2>/dev/null | grep -i "LUKS" | cut -d: -f1); do
        echo "  Device: $luks_dev"
        DUMP=$(cryptsetup luksDump "$luks_dev" 2>/dev/null || true)
        if [[ -n "$DUMP" ]]; then
            # Count active key slots
            # NOTE: grep -c prints 0 AND exits 1 on no match; the old
            # "|| echo 0" appended a second line making ACTIVE_SLOTS "0\n0"
            # and breaking the -ge test below.
            #
            # v1.8: "ENABLED" is LUKS1 only. LUKS2 (the Debian default since
            # buster, and what the d-i installs) prints a "Keyslots:" section
            # with one "  N: luks2" line per active slot and no ENABLED word,
            # so every LUKS2 machine reported 0 slots. Count both formats.
            _ver=$(echo "$DUMP" | awk '/^Version:/{print $2; exit}')
            if [[ "$_ver" == "2" ]]; then
                ACTIVE_SLOTS=$(echo "$DUMP" | awk '/^Keyslots:/{k=1; next} /^[A-Za-z]/{k=0} k && /^[[:space:]]+[0-9]+: luks2/{n++} END{print n+0}')
            else
                ACTIVE_SLOTS=$(echo "$DUMP" | grep -c "ENABLED" 2>/dev/null)
            fi
            [[ "$ACTIVE_SLOTS" =~ ^[0-9]+$ ]] || ACTIVE_SLOTS=0
            echo "    LUKS version: ${_ver:-unknown}"
            echo "    Active key slots: $ACTIVE_SLOTS"
            echo "$DUMP" | grep -E "(Key Slot|ENABLED|DISABLED|^[[:space:]]+[0-9]+: luks2)" | head -16 | sed 's/^/    /'
            # v1.8 (inspector N4): no inference from the slot count. A second
            # slot is just as often a recovery passphrase or a keyfile, and a
            # guess about a nuke password does not belong in a shared bundle.
        fi
    done
else
    echo "  (no LUKS devices to check)"
fi

echo ""
# v1.8: the label was "NUKE PASSWORD:", which the credential redaction rule
# treats as a key/value pair, so every bundle shipped "[REDACTED]" here.
echo ">>> NUKE STATUS: $NUKE_STATUS <<<"
echo ""

# ------- Additional Kodachi Meta -------
echo "----------------------------------------------"
echo "  ADDITIONAL KODACHI METADATA"
echo "----------------------------------------------"

# Swap encryption
echo "Swap status:"
swapon --show 2>/dev/null | sed 's/^/  /' || echo "  (no swap active)"
if swapon --show 2>/dev/null | grep -q "/dev/mapper"; then
    echo "  Swap is ENCRYPTED (on dm-crypt)"
elif swapon --show 2>/dev/null | grep -q "zram"; then
    echo "  Swap is ZRAM (compressed RAM, no disk)"
else
    SWAP_DEV=$(swapon --show 2>/dev/null | tail -n+2 | awk '{print $1}')
    if [[ -z "$SWAP_DEV" ]]; then
        echo "  No swap active"
    else
        echo "  Swap is on: $SWAP_DEV (check if encrypted above)"
    fi
fi
echo ""

# MAC address randomization (MACs masked for privacy - only shows randomization status)
echo "MAC Randomization Status:"
# v1.8: `grep -v lo` dropped every name CONTAINING lo (wlo1, vlo*), which on a
# laptop is the only wireless card, so the section printed nothing. Match the
# loopback name exactly, and strip the "@parent" suffix veth/vlan names carry.
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); if ($2 != "lo") print $2}'); do
    MAC=$(ip link show "$iface" 2>/dev/null | grep ether | awk '{print $2}')
    PERM_MAC=$(ethtool -P "$iface" 2>/dev/null | awk '{print $NF}' || echo "unavailable")
    if [[ -n "$MAC" ]]; then
        # Mask MACs: show only vendor prefix (first 3 octets) for debugging driver issues
        MASKED_MAC=$(echo "$MAC" | cut -d: -f1-3)":XX:XX:XX"
        if [[ "$MAC" != "$PERM_MAC" ]] && [[ "$PERM_MAC" != "unavailable" ]] && [[ "$PERM_MAC" != "00:00:00:00:00:00" ]]; then
            echo "  $iface: vendor=$MASKED_MAC -> MAC RANDOMIZATION ACTIVE"
        else
            echo "  $iface: vendor=$MASKED_MAC -> USING HARDWARE MAC"
        fi
    fi
done
echo ""

# Tor mode
echo "Tor Status:"
# tor@default.service, NOT tor.service: the plain unit is a Type=oneshot /bin/true
# master that reports "active" with no Tor daemon running, so this test used to say
# RUNNING on a box with no Tor at all , in a DEBUG COLLECTOR, whose whole job is to
# tell the truth about a broken system.
if systemctl is-active tor@default.service 2>/dev/null | grep -q "active"; then
    echo "  Tor service: RUNNING"
    # Check if system is fully torrified
    TOR_SOCKS=$(ss -tulnp 2>/dev/null | grep ":9050 " || true)
    if [[ -n "$TOR_SOCKS" ]]; then
        echo "  SOCKS proxy (9050): LISTENING"
    fi
    TOR_TRANS=$(ss -tulnp 2>/dev/null | grep ":9040 " || true)
    if [[ -n "$TOR_TRANS" ]]; then
        echo "  TransPort (9040): LISTENING (transparent proxy active)"
    fi
    TOR_DNS=$(ss -tulnp 2>/dev/null | grep ":5353 " || true)
    if [[ -n "$TOR_DNS" ]]; then
        echo "  DNS Port (5353): LISTENING"
    fi
else
    echo "  Tor service: NOT RUNNING"
fi
echo ""

# VPN
echo "VPN Status:"
VPN_IFACES=$(ip -o link show 2>/dev/null | grep -E "(tun|tap|wg)" | awk -F': ' '{print $2}')
if [[ -n "$VPN_IFACES" ]]; then
    echo "  VPN interfaces found: $VPN_IFACES"
    for viface in $VPN_IFACES; do
        ip addr show "$viface" 2>/dev/null | grep inet | sed 's/^/    /'
    done
else
    echo "  No VPN interfaces detected"
fi
OPENVPN_PROCS=$(pgrep -a openvpn 2>/dev/null || true)
if [[ -n "$OPENVPN_PROCS" ]]; then
    echo "  OpenVPN processes: $OPENVPN_PROCS"
fi
WG_STATUS=$(wg show 2>/dev/null || true)
if [[ -n "$WG_STATUS" ]]; then
    echo "  WireGuard:"
    echo "$WG_STATUS" | sed 's/^/    /'
fi
# AmneziaWG uses its own tool over a different netlink family, so `wg show`
# reports nothing for an awg0 tunnel and the bundle would look VPN-less.
AWG_STATUS=$(awg show 2>/dev/null || true)
if [[ -n "$AWG_STATUS" ]]; then
    echo "  AmneziaWG:"
    echo "$AWG_STATUS" | sed 's/^/    /'
fi
echo ""

# DNSCrypt
echo "DNSCrypt Status:"
if systemctl is-active dnscrypt-proxy 2>/dev/null | grep -q "active"; then
    echo "  dnscrypt-proxy: RUNNING"
elif pgrep -x dnscrypt-proxy &>/dev/null; then
    echo "  dnscrypt-proxy: RUNNING (not systemd)"
else
    echo "  dnscrypt-proxy: NOT RUNNING"
fi
echo ""

# Conky
echo "Conky Status:"
if pgrep -x conky &>/dev/null; then
    echo "  Conky: RUNNING"
else
    echo "  Conky: NOT RUNNING"
fi
echo ""

# Dashboard status
echo "Kodachi Dashboard:"
if pgrep -f "kodachi-dashboard" &>/dev/null; then
    echo "  Dashboard process: RUNNING"
else
    echo "  Dashboard process: NOT RUNNING"
fi
echo ""

# Secure Boot
echo "Secure Boot:"
if command -v mokutil &>/dev/null; then
    mokutil --sb-state 2>/dev/null | sed 's/^/  /' || echo "  (mokutil failed)"
elif [[ -d "/sys/firmware/efi" ]]; then
    echo "  UEFI boot: YES"
    SB=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}' || echo "unknown")
    if [[ "$SB" == "1" ]]; then
        echo "  Secure Boot: ENABLED"
    elif [[ "$SB" == "0" ]]; then
        echo "  Secure Boot: DISABLED"
    else
        echo "  Secure Boot: UNKNOWN"
    fi
else
    echo "  Legacy BIOS boot (no UEFI/SecureBoot)"
fi
echo ""

# Boot mode
echo "Boot Mode:"
if [[ -d "/sys/firmware/efi" ]]; then
    echo "  UEFI"
else
    echo "  Legacy BIOS"
fi
echo ""

# RAM and storage summary
echo "Quick Resource Summary:"
echo "  RAM: $(free -h 2>/dev/null | awk '/Mem:/{print $2 " total, " $3 " used, " $7 " available"}')"
echo "  Root disk: $(df -h / 2>/dev/null | awk 'NR==2{print $2 " total, " $3 " used, " $4 " free (" $5 " used)"}')"
echo ""

# ------- QUICK SUMMARY BOX -------
echo "=============================================="
echo "   QUICK DIAGNOSIS SUMMARY"
echo "=============================================="
echo ""
echo "  Kodachi Version:    ${KODACHI_VERSION}"
echo "  Nightly Build:      ${NIGHTLY_VERSION:-unknown}"
echo "  Build Number:       ${BUILD_NUMBER:-unknown}"
echo "  Pack Date:          ${PACK_DATE:-unknown}"
echo "  System Type:        ${SYSTEM_TYPE}"
echo "  LUKS Encryption:    ${LUKS_ACTIVE}"
echo "  Nuke Status:        ${NUKE_STATUS}"
echo "  Root Filesystem:    ${ROOT_FS} (${ROOT_SOURCE})"
echo "  Boot Mode:          $(if [[ -d /sys/firmware/efi ]]; then echo 'UEFI'; else echo 'Legacy BIOS'; fi)"
# tor@default.service is the real daemon; tor.service is the /bin/true master.
echo "  Tor Running:        $(systemctl is-active tor@default.service 2>/dev/null || echo 'unknown')"
VPN_LABEL="NO"; [[ -n "${VPN_IFACES:-}" ]] && VPN_LABEL="YES"
echo "  VPN Active:         ${VPN_LABEL}"
echo "  DNSCrypt:           $(if pgrep -x dnscrypt-proxy &>/dev/null; then echo 'RUNNING'; else echo 'NOT RUNNING'; fi)"
echo ""
echo "=============================================="

) > "$COLLECTION_DIR/00-kodachi-meta/kodachi-meta-summary.txt" 2>&1

# Also save raw data for parsing (re-detect since subshell variables don't propagate)
(
set +e
KODACHI_VERSION="unknown"
if [[ -f "/etc/kodachi-version" ]]; then
    # Extract the scalar version from the banner file (see meta-summary section).
    KV=$(grep -oP '^\s*Version:\s*\K[0-9][0-9A-Za-z.+-]*' /etc/kodachi-version 2>/dev/null | head -1)
    [[ -n "$KV" ]] && KODACHI_VERSION="$KV"
fi
if [[ -f "/etc/kodachi_version" ]]; then
    KV=$(grep -oP '^\s*Version:\s*\K[0-9][0-9A-Za-z.+-]*' /etc/kodachi_version 2>/dev/null | head -1)
    [[ -n "$KV" ]] && KODACHI_VERSION="$KV"
fi
# Check build-meta.json
if [[ "$KODACHI_VERSION" == "unknown" ]]; then
    for bm in /opt/*/dashboard/hooks/config/build-meta.json; do
        if [[ -f "$bm" ]]; then
            BM_V=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$bm" 2>/dev/null | head -1)
            if [[ -n "$BM_V" ]]; then KODACHI_VERSION="$BM_V"; break; fi
        fi
    done
fi
# Check os-release
if [[ "$KODACHI_VERSION" == "unknown" ]]; then
    OS_V=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -n "$OS_V" ]]; then KODACHI_VERSION="$OS_V"; fi
fi

SYSTEM_TYPE="UNKNOWN"
if [[ -d "/run/live" ]] || grep -q "boot=live" /proc/cmdline 2>/dev/null; then
    SYSTEM_TYPE="LIVE"
else
    ROOT_FS_TYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
    if [[ "$ROOT_FS_TYPE" == "ext4" ]] || [[ "$ROOT_FS_TYPE" == "btrfs" ]] || [[ "$ROOT_FS_TYPE" == "xfs" ]]; then
        SYSTEM_TYPE="INSTALLED"
    fi
fi

LUKS_ACTIVE="NO"
lsblk -f 2>/dev/null | grep -qi "crypto_LUKS" && LUKS_ACTIVE="YES"

NUKE_STATUS="NOT DETECTED"
# dpkg-query, not "dpkg -l | grep": grep matches removed-but-not-purged
# packages too, making this disagree with the meta-summary detection.
dpkg-query -W -f='${Status}' cryptsetup-nuke-password 2>/dev/null | grep -q '^install ok installed$' && NUKE_STATUS="PACKAGE INSTALLED"

ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")
ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")

echo "KODACHI_VERSION=${KODACHI_VERSION}"
# Extract build info from build-meta.json (re-detect in subshell)
_NV="unknown"; _BN="unknown"; _PD="unknown"
for _bm in /opt/*/dashboard/hooks/config/build-meta.json "${REAL_HOME}"/*/dashboard/hooks/config/build-meta.json; do
    if [[ -f "$_bm" ]]; then
        _NV=$(grep -oP '"nightly_version"\s*:\s*"\K[^"]+' "$_bm" 2>/dev/null | head -1)
        _BN=$(grep -oP '"build_number"\s*:\s*\K[0-9]+' "$_bm" 2>/dev/null | head -1)
        _PD=$(grep -oP '"pack_date"\s*:\s*"\K[^"]+' "$_bm" 2>/dev/null | head -1)
        break
    fi
done
echo "NIGHTLY_VERSION=${_NV:-unknown}"
echo "BUILD_NUMBER=${_BN:-unknown}"
echo "PACK_DATE=${_PD:-unknown}"
echo "SYSTEM_TYPE=${SYSTEM_TYPE}"
echo "LUKS_ACTIVE=${LUKS_ACTIVE}"
echo "NUKE_STATUS=${NUKE_STATUS}"
echo "ROOT_FS=${ROOT_FS}"
echo "ROOT_SOURCE=${ROOT_SOURCE}"
echo "BOOT_MODE=$(if [[ -d /sys/firmware/efi ]]; then echo 'UEFI'; else echo 'BIOS'; fi)"
) > "$COLLECTION_DIR/00-kodachi-meta/meta-vars.txt" 2>&1

fi # end CATEGORY 0

# ============================================================================
# CATEGORY 1: System & Boot Information
# ============================================================================
if [[ "${CAT_ENABLED[1]}" == "1" ]]; then
progress "Collecting system and boot information..."

mkdir -p "$COLLECTION_DIR/01-system-boot"

safe_exec "$COLLECTION_DIR/01-system-boot/os-release.txt" "cat /etc/os-release"
safe_exec "$COLLECTION_DIR/01-system-boot/uname.txt" "uname -a"
safe_exec "$COLLECTION_DIR/01-system-boot/kernel-cmdline.txt" "cat /proc/cmdline"
safe_exec "$COLLECTION_DIR/01-system-boot/kernel-version.txt" "cat /proc/version"
safe_exec "$COLLECTION_DIR/01-system-boot/uptime.txt" "uptime"
safe_exec "$COLLECTION_DIR/01-system-boot/loadavg.txt" "cat /proc/loadavg"
safe_exec "$COLLECTION_DIR/01-system-boot/dmesg.txt" "dmesg --ctime"
substep "journal for this boot and the previous one (largest single capture)"
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-full.txt" "journalctl -b --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-errors.txt" "journalctl -b -p err --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-warnings.txt" "journalctl -b -p warning --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemctl-failed.txt" "systemctl --failed --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemctl-all-units.txt" "systemctl list-units --all --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemctl-timers.txt" "systemctl list-timers --all --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-time.txt" "systemd-analyze time"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-blame.txt" "systemd-analyze blame"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-critical.txt" "systemd-analyze critical-chain"
safe_exec "$COLLECTION_DIR/01-system-boot/kernel-taint.txt" "cat /proc/sys/kernel/tainted"

# audit 2026-05-07: extra system-side data that helps when symptoms only
# manifest "this morning" / "after a few reboots". Without these we can't
# correlate the slow boot to anything that changed across boots.
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-prev-boot.txt" \
    "journalctl -b -1 --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-prev-boot-errors.txt" \
    "journalctl -b -1 -p err --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/journalctl-list-boots.txt" \
    "journalctl --list-boots --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-plot.svg" \
    "systemd-analyze plot"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-cgls.txt" \
    "systemd-cgls --no-pager"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-dump-targets.txt" \
    "systemd-analyze dump | grep -E '^(Unit|.*: dependency|Following|swap|local-fs|cryptsetup|graphical-session)' | head -200"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-units-graphical.txt" \
    "systemd-analyze critical-chain graphical.target"
safe_exec "$COLLECTION_DIR/01-system-boot/systemd-analyze-units-multi-user.txt" \
    "systemd-analyze critical-chain multi-user.target"

# Cycle-detection helper, surfaces any "Found ordering cycle" lines from
# THIS boot together with the units involved so reviewers don't have to
# grep journalctl-full.txt by hand.
safe_exec "$COLLECTION_DIR/01-system-boot/ordering-cycles.txt" \
    "journalctl -b --no-pager | grep -E 'ordering cycle|deleted to break|Found dependency on' || echo 'No ordering cycles detected this boot.'"

# Copy system logs
safe_copy "/var/log/syslog" "$COLLECTION_DIR/01-system-boot"
safe_copy "/var/log/kern.log" "$COLLECTION_DIR/01-system-boot"
safe_copy "/var/log/boot.log" "$COLLECTION_DIR/01-system-boot"
# auth.log. audit 2026-08-19: this was the LARGEST file in a real bundle
# (32.5 MB on the measurement VM) and the only large capture that bypassed
# redact_secrets completely. A four-key sed ran in its place, matching only
# password=/credential=/secret=/token= in the `key=value` form, so an
# `Authorization:` header, a `passphrase: <value>` echo, an SSID or a public
# IP address in an sshd line reached the file verbatim. The final sweep
# rescued it, so nothing leaked into the zip, but the file sat unredacted on
# disk in the interim and was then rewritten a second time, which is two
# full passes over the biggest file in the bundle.
#
# safe_copy_redacted applies the whole ruleset on the FIRST write, records
# the result in the redaction manifest so the sweep does not repeat the
# work, and gives auth.log the same size cap as every other copied log.
if [[ -f "/var/log/auth.log" ]]; then
    safe_copy_redacted "/var/log/auth.log" "$COLLECTION_DIR/01-system-boot"
fi
safe_copy "/var/log/daemon.log" "$COLLECTION_DIR/01-system-boot"

fi # end CATEGORY 1

# ============================================================================
# CATEGORY 2: Hardware & Drivers (Privacy-Hardened)
# ============================================================================
if [[ "${CAT_ENABLED[2]}" == "1" ]]; then
progress "Collecting hardware and driver information..."

mkdir -p "$COLLECTION_DIR/02-hardware-drivers"

# Concise PCI device list with IDs (enough to identify driver issues, no verbose subsystem dump)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/lspci.txt" "lspci -nn"
# Basic USB list (no -v flag, avoids dumping device serial numbers)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/lsusb.txt" "lsusb"
# Filesystem info
safe_exec "$COLLECTION_DIR/02-hardware-drivers/lsblk.txt" "lsblk -f"
# CPU info (cores, architecture, cache, model)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/lscpu.txt" "lscpu"
# Loaded kernel modules (driver issues)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/lsmod.txt" "lsmod"
# Detailed memory stats
safe_exec "$COLLECTION_DIR/02-hardware-drivers/meminfo.txt" "cat /proc/meminfo"
# RAM total/used/available
safe_exec "$COLLECTION_DIR/02-hardware-drivers/free.txt" "free -h"
# Disk space usage
safe_exec "$COLLECTION_DIR/02-hardware-drivers/df.txt" "df -h"
# Wireless kill switches
safe_exec "$COLLECTION_DIR/02-hardware-drivers/rfkill.txt" "rfkill list all"
# Firmware messages
safe_exec "$COLLECTION_DIR/02-hardware-drivers/dmesg-firmware.txt" "dmesg | grep -i firmware"
# Error messages
safe_exec "$COLLECTION_DIR/02-hardware-drivers/dmesg-errors.txt" "dmesg | grep -i error"
# GPU model only (VGA/3D/display controllers)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/gpu-info.txt" "lspci | grep -iE 'vga|3d|display'"
# SSD vs HDD detection (ROTA=0 means SSD, ROTA=1 means HDD)
safe_exec "$COLLECTION_DIR/02-hardware-drivers/disk-type.txt" "lsblk -d -o NAME,SIZE,ROTA,TRAN,TYPE"
# System brand/model only, no serial numbers, no UUIDs, no asset tags
safe_exec "$COLLECTION_DIR/02-hardware-drivers/dmidecode-system.txt" "dmidecode --type system 2>/dev/null | grep -iE 'manufacturer|product|family' || echo 'dmidecode not available'"

# Sensors if available
if command -v sensors &> /dev/null; then
    safe_exec "$COLLECTION_DIR/02-hardware-drivers/sensors.txt" "sensors"
fi

# Modprobe configs (blacklists, driver options)
if [[ -d "/etc/modprobe.d" ]]; then
    mkdir -p "$COLLECTION_DIR/02-hardware-drivers/modprobe.d"
    for mconf in /etc/modprobe.d/*.conf; do
        [[ -f "$mconf" ]] && cp "$mconf" "$COLLECTION_DIR/02-hardware-drivers/modprobe.d/" 2>/dev/null || true
    done
fi

# DKMS module status
if command -v dkms &> /dev/null; then
    safe_exec "$COLLECTION_DIR/02-hardware-drivers/dkms-status.txt" "dkms status"
fi

# NVMe health (if nvme-cli installed)
if command -v nvme &> /dev/null; then
    safe_exec "$COLLECTION_DIR/02-hardware-drivers/nvme-smart.txt" "nvme smart-log /dev/nvme0n1 2>/dev/null || echo 'No NVMe device'"
fi

# S.M.A.R.T disk health
if command -v smartctl &> /dev/null; then
    safe_exec "$COLLECTION_DIR/02-hardware-drivers/smart-health.txt" "smartctl -H /dev/sda 2>/dev/null || smartctl -H /dev/nvme0n1 2>/dev/null || echo 'No SMART-capable device'"
fi

# Virtualization detection
safe_exec "$COLLECTION_DIR/02-hardware-drivers/virt-detect.txt" "systemd-detect-virt 2>/dev/null || echo 'not detected'"

# CPU microcode version
safe_exec "$COLLECTION_DIR/02-hardware-drivers/cpu-microcode.txt" "grep -m1 microcode /proc/cpuinfo 2>/dev/null || echo 'no microcode info'"

fi # end CATEGORY 2

# ============================================================================
# CATEGORY 3: Network Configuration (CRITICAL for Kodachi)
# ============================================================================
if [[ "${CAT_ENABLED[3]}" == "1" ]]; then
progress "Collecting network configuration..."

mkdir -p "$COLLECTION_DIR/03-network"

safe_exec "$COLLECTION_DIR/03-network/ip-addr.txt" "ip addr show"
safe_exec "$COLLECTION_DIR/03-network/ip-route.txt" "ip route show"
safe_exec "$COLLECTION_DIR/03-network/ip-route-all.txt" "ip route show table all"
safe_exec "$COLLECTION_DIR/03-network/resolv.conf.txt" "cat /etc/resolv.conf"
safe_exec "$COLLECTION_DIR/03-network/iptables-filter.txt" "iptables -L -v -n"
safe_exec "$COLLECTION_DIR/03-network/iptables-nat.txt" "iptables -t nat -L -v -n"
safe_exec "$COLLECTION_DIR/03-network/nftables.txt" "nft list ruleset"
# PERSISTED ruleset, not the live one. `nft list ruleset` shows what is loaded
# NOW; this file is what gets reloaded at every boot. They diverge in exactly the
# case that matters: torrify-system persists its fail-closed ruleset here on
# purpose, and on releases whose tor-switch has no `boot-restore-torrified` verb
# nothing restarts the Tor pool those rules point at, so the machine boots with
# all traffic redirected to ports with no listener. `health-control
# recover-internet` clears the LIVE ruleset and never rewrites this file, so the
# black hole returns on the next boot and a live-only capture cannot see why.
# Field case 2026-08-19 (dedicated-server user, release binaries): diagnosed from
# source because the bundle carried no copy of this file.
safe_copy "/etc/nftables.conf" "$COLLECTION_DIR/03-network"
safe_copy "/etc/nftables.conf.kodachi-baseline" "$COLLECTION_DIR/03-network"
safe_exec "$COLLECTION_DIR/03-network/nftables-boot-units.txt" "kdc_unit_status nftables kodachi-firewall-restore kodachi-tor-pool-boot"
safe_exec "$COLLECTION_DIR/03-network/listening-ports.txt" "ss -tulnp"
safe_exec "$COLLECTION_DIR/03-network/socket-stats.txt" "ss -s"

# DNS stack configs (critical for DNS degradation debugging)
safe_copy "/etc/systemd/resolved.conf" "$COLLECTION_DIR/03-network"
if [[ -d "/etc/systemd/resolved.conf.d" ]]; then
    mkdir -p "$COLLECTION_DIR/03-network/resolved.conf.d"
    cp /etc/systemd/resolved.conf.d/*.conf "$COLLECTION_DIR/03-network/resolved.conf.d/" 2>/dev/null || true
fi
# DNSCrypt config (redact server_names/stamps that could identify provider choice)
if [[ -f "/etc/dnscrypt-proxy/dnscrypt-proxy.toml" ]]; then
    grep -v -E "^(stamp|server_names)" /etc/dnscrypt-proxy/dnscrypt-proxy.toml \
        > "$COLLECTION_DIR/03-network/dnscrypt-proxy.toml" 2>/dev/null || true
    # DNSCrypt runtime state: the .toml alone cannot explain resolution
    # failures (cold-start window, cert refresh errors live in the journal).
    safe_exec "$COLLECTION_DIR/03-network/dnscrypt-service.txt" "kdc_unit_status dnscrypt-proxy"
    safe_exec "$COLLECTION_DIR/03-network/dnscrypt-journal.txt" "journalctl -b -u dnscrypt-proxy --no-pager -n 400"
fi

# WireGuard status (redact private/preshared keys)
if command -v wg &> /dev/null; then
    wg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_bounded \
        > "$COLLECTION_DIR/03-network/wireguard-show.txt" 2>/dev/null || true
fi

# AmneziaWG status, same redaction. Separate tool, separate netlink family.
if command -v awg &> /dev/null; then
    awg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_bounded \
        > "$COLLECTION_DIR/03-network/amneziawg-show.txt" 2>/dev/null || true
fi

# NetworkManager dispatcher scripts (list only, don't copy contents)
safe_exec "$COLLECTION_DIR/03-network/nm-dispatcher-scripts.txt" "ls -la /etc/NetworkManager/dispatcher.d/ 2>/dev/null || echo 'no dispatcher scripts'"

# NetworkManager
if command -v nmcli &> /dev/null; then
    safe_exec "$COLLECTION_DIR/03-network/nmcli-general.txt" "nmcli general status"
    safe_exec "$COLLECTION_DIR/03-network/nmcli-connections.txt" "nmcli connection show"
fi

# Copy NetworkManager configs (redact WiFi passwords and sensitive credentials)
if [[ -d "/etc/NetworkManager" ]]; then
    mkdir -p "$COLLECTION_DIR/03-network/NetworkManager-config"
    # Copy structure but redact secrets from connection files
    _nm_n=0
    find /etc/NetworkManager -type f 2>/dev/null | while read -r nm_file; do
        dest_file="$COLLECTION_DIR/03-network/NetworkManager-config/${nm_file#/etc/NetworkManager/}"
        if echo "$nm_file" | grep -qE "(system-connections|secrets)"; then
            # v1.7 (inspector, 2026-09-06): an NM profile is NAMED after the
            # network, so copying it under its own name published the SSID as
            # a path and as a zip entry name, where no line-based redactor can
            # ever reach it. The SSID rule at the top of redact_secrets exists
            # precisely to stop that. The file keeps its content (redacted)
            # under a numbered name, and the connection's own id/ssid lines
            # inside it are redacted as before.
            _nm_n=$((_nm_n + 1))
            dest_file="$COLLECTION_DIR/03-network/NetworkManager-config/system-connections/connection-${_nm_n}.nmconnection"
        fi
        mkdir -p "$(dirname "$dest_file")"
        if echo "$nm_file" | grep -qE "(system-connections|secrets)"; then
            # Redact passwords, PSK, secrets from connection profiles
            # NM-specific narrow pass THEN the general redactor, which also
            # covers WireGuard-in-NM private-key=/preshared-key=, inline PEM
            # and credential URIs the narrow sed missed.
            sed -E 's/(psk=).*/\1[REDACTED]/g; s/(password=).*/\1[REDACTED]/g; s/(secret=).*/\1[REDACTED]/g; s/(wep-key[0-9]*=).*/\1[REDACTED]/g; s/(leap-password=).*/\1[REDACTED]/g; s/(pin=).*/\1[REDACTED]/g; s/(private-key-password=).*/\1[REDACTED]/g' \
                "$nm_file" 2>/dev/null | redact_bounded > "$dest_file" 2>/dev/null || true
        else
            cp "$nm_file" "$dest_file" 2>/dev/null || true
        fi
    done
fi

# resolvectl only when systemd-resolved is actually running. Kodachi uses
# DNSCrypt with systemd-resolved masked, so calling resolvectl there just
# spams "Unit dbus-org.freedesktop.resolve1.service is masked" failures.
if command -v resolvectl &> /dev/null; then
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        safe_exec "$COLLECTION_DIR/03-network/resolvectl.txt" "resolvectl status"
    else
        echo "[SKIPPED] systemd-resolved is not active (masked/disabled), resolvectl not applicable on this DNS setup" \
            > "$COLLECTION_DIR/03-network/resolvectl.txt"
    fi
fi

# DNS resolution testing (tests functionality only, no IP collection)
safe_exec "$COLLECTION_DIR/03-network/dns-test-dig.txt" "dig google.com"
safe_exec "$COLLECTION_DIR/03-network/dns-test-nslookup.txt" "nslookup google.com"

# NOTE: No IP address fetching (ipinfo.io, torproject check, etc.)
# to protect user privacy. Only local network config is collected.

fi # end CATEGORY 3

# ============================================================================
# CATEGORY 4: Tor Configuration & Status
# ============================================================================
if [[ "${CAT_ENABLED[4]}" == "1" ]]; then
progress "Collecting Tor information..."

mkdir -p "$COLLECTION_DIR/04-tor"

safe_exec "$COLLECTION_DIR/04-tor/tor-service-status.txt" "kdc_unit_status 'tor*'"

# Tor commonly logs to the journal (not /var/log/tor) on systemd distros;
# without this slice bootstrap failures are invisible in the bundle.
safe_exec "$COLLECTION_DIR/04-tor/tor-journal.txt" "journalctl -b -u tor@default -u tor --no-pager -n 400"

# Copy Tor logs
if [[ -d "/var/log/tor" ]]; then
    mkdir -p "$COLLECTION_DIR/04-tor/logs"
    for logfile in /var/log/tor/*.log; do
        [[ -f "$logfile" ]] && safe_copy "$logfile" "$COLLECTION_DIR/04-tor/logs"
    done
fi

# Copy Tor config (redact all sensitive data: bridges, passwords, auth cookies, hidden service keys)
if [[ -f "/etc/tor/torrc" ]]; then
    grep -v -E "(Bridge |ServerTransport|Cookie|Password|HiddenService|ClientOnionAuth)" /etc/tor/torrc \
        | sed -E 's/(HashedControlPassword ).*/\1[REDACTED]/g' \
        > "$COLLECTION_DIR/04-tor/torrc.txt" 2>/dev/null || \
        echo "Could not read torrc" > "$COLLECTION_DIR/04-tor/torrc.txt"
fi

# ---------------------------------------------------------------------------
# tor-switch INSTANCE POOL (added 2026-08-16 after user "mattrim"'s bundle)
#
# The bundle above could not answer "why did the pool exit 1". Everything the
# collector gathered described tor@default and /etc/tor/torrc, while the six
# failing instances live under /etc/tor/kodachi_tor_data/<tag>/ and log through
# a path nothing here captured. The tor-switch log that DOES name the reason
# rotates in roughly three hours under dashboard polling, so it was already
# gone. Collect the instance state directly instead of hoping for the log.
# ---------------------------------------------------------------------------
if [[ -d /etc/tor/kodachi_tor_data ]]; then
    mkdir -p "$COLLECTION_DIR/04-tor/instances"

    # Permissions and ownership: Tor refuses any DataDirectory where
    # mode & 0077 != 0 ("needs to be chmod 0700") and exits 1. Without this
    # listing that failure mode is undiagnosable from a bundle.
    safe_exec "$COLLECTION_DIR/04-tor/instances/dir-permissions.txt" \
        "stat -c '%a %U:%G %n' /etc/tor/kodachi_tor_data /etc/tor/kodachi_tor_data/*/ 2>/dev/null"

    # Same question for the main daemon's data dir, which is the other
    # documented exit-1 cause ("/var/lib/tor is not owned by this user").
    safe_exec "$COLLECTION_DIR/04-tor/instances/main-datadir-permissions.txt" \
        "stat -c '%a %U:%G %n' /var/lib/tor /var/log/tor /run/tor 2>/dev/null"

    # What systemd-tmpfiles would do to that tree on the next boot. A recursive
    # rule here can re-break every instance after a reboot.
    safe_exec "$COLLECTION_DIR/04-tor/instances/tmpfiles-dryrun.txt" \
        "systemd-tmpfiles --create --dry-run /etc/tmpfiles.d/kodachi-tor.conf 2>&1"

    # Per-instance torrc + torrc.custom, redacted like the main torrc above.
    for _inst_dir in /etc/tor/kodachi_tor_data/*/; do
        [[ -d "$_inst_dir" ]] || continue
        _inst_tag="$(basename "$_inst_dir")"
        for _cfg in torrc torrc.custom; do
            [[ -f "$_inst_dir/$_cfg" ]] || continue
            grep -v -E "(Bridge |ServerTransport|Cookie|Password|HiddenService|ClientOnionAuth)" \
                "$_inst_dir/$_cfg" 2>/dev/null \
                | sed -E 's/(HashedControlPassword ).*/\1[REDACTED]/g' \
                > "$COLLECTION_DIR/04-tor/instances/${_inst_tag}.${_cfg}.txt" 2>/dev/null || true
        done
        # Directory listing only: never copy keys/ or the control auth cookie.
        ls -la "$_inst_dir" \
            > "$COLLECTION_DIR/04-tor/instances/${_inst_tag}.listing.txt" 2>&1 || true
    done

    # Which instance ports are actually bound right now. "Configured but no
    # listener" is the signature of a pool that never came up.
    safe_exec "$COLLECTION_DIR/04-tor/instances/listening-ports.txt" \
        "ss -ltnp 2>/dev/null | grep -E ':(90[0-9][0-9]|1[0-9]{4})' || echo 'no tor instance ports listening'"

    # Live tor processes with their -f torrc path, which names the instance.
    safe_exec "$COLLECTION_DIR/04-tor/instances/processes.txt" \
        "ps -eo pid,user,etime,args | grep -E '[t]or ' || echo 'no tor processes'"
fi

# AppArmor / audit denials. auditd is enabled on Kodachi, so kernel MAC denials
# land in /var/log/audit/audit.log and NEVER in the journal. A bundle that only
# carries journalctl shows 0 denials even when a profile is actively blocking.
safe_exec "$COLLECTION_DIR/04-tor/apparmor-denials.txt" \
    "{ ausearch -m AVC,USER_AVC -ts today 2>/dev/null || grep -h 'apparmor=\"DENIED\"' /var/log/audit/audit.log 2>/dev/null | tail -200 || echo 'no audit log readable'; }"
safe_exec "$COLLECTION_DIR/04-tor/apparmor-tor-profile.txt" \
    "{ aa-status 2>/dev/null | grep -i tor; echo '--- profile mode ---'; systemctl show tor@default -p AppArmorProfile --no-pager 2>/dev/null; }"

fi # end CATEGORY 4

# ============================================================================
# CATEGORY 5: VPN Configuration & Status
# ============================================================================
if [[ "${CAT_ENABLED[5]}" == "1" ]]; then
progress "Collecting VPN information..."

mkdir -p "$COLLECTION_DIR/05-vpn"

safe_exec "$COLLECTION_DIR/05-vpn/openvpn-service-status.txt" "kdc_unit_status 'openvpn*'"

# WireGuard service and interface status
safe_exec "$COLLECTION_DIR/05-vpn/wireguard-service-status.txt" "kdc_unit_status 'wg-quick*' 2>/dev/null || echo 'no wg-quick service'"
if command -v wg &> /dev/null; then
    wg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_bounded \
        > "$COLLECTION_DIR/05-vpn/wireguard-detail.txt" 2>/dev/null || true
fi

# AmneziaWG service and interface status.
safe_exec "$COLLECTION_DIR/05-vpn/amneziawg-service-status.txt" "kdc_unit_status 'awg-quick*' 2>/dev/null || echo 'no awg-quick service'"
if command -v awg &> /dev/null; then
    awg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_bounded \
        > "$COLLECTION_DIR/05-vpn/amneziawg-detail.txt" 2>/dev/null || true
fi

# Proxy tunnel processes (tun2socks, xray, hysteria, shadowsocks)
safe_exec "$COLLECTION_DIR/05-vpn/proxy-processes.txt" "{ ps auxww | grep -E 'tun2socks|xray|hysteria|ss-local|ss-redir|microsocks|redsocks' | grep -v grep || echo 'no proxy tunnels running'; } | redact_secrets"

# Copy VPN logs
if [[ -d "/var/log/openvpn" ]]; then
    mkdir -p "$COLLECTION_DIR/05-vpn/logs"
    for logfile in /var/log/openvpn/*.log; do
        [[ -f "$logfile" ]] && safe_copy "$logfile" "$COLLECTION_DIR/05-vpn/logs"
    done
fi

# VPN routing tables (custom tables used by routing-switch)
safe_exec "$COLLECTION_DIR/05-vpn/ip-rule-list.txt" "ip rule list"

fi # end CATEGORY 5

# ============================================================================
# CATEGORY 6: Kodachi-Specific Logs & Services (CRITICAL)
# ============================================================================
if [[ "${CAT_ENABLED[6]}" == "1" ]]; then
progress "Collecting Kodachi-specific logs and services..."

mkdir -p "$COLLECTION_DIR/06-kodachi"

# Search for Kodachi hooks dynamically
KODACHI_HOOKS_DIRS=(
    "/opt/kodachi/dashboard/hooks"
    "${REAL_HOME}/dashboard/hooks"
    "/opt/*/dashboard/hooks"
)

# v1.7: the three patterns above overlap ("/opt/kodachi/dashboard/hooks" is
# also matched by "/opt/*/dashboard/hooks"), and this loop had no memory, so
# every hook log and result file was copied and redacted TWICE. Measured
# 2026-09-06: 496 duplicate copies, 26.6s of redaction plus the per-file
# overhead, for bytes already in the bundle. Each real directory is now
# visited once.
declare -A _seen_hooks_dir=()
for hooks_pattern in "${KODACHI_HOOKS_DIRS[@]}"; do
    for hooks_dir in $hooks_pattern; do
        if [[ -d "$hooks_dir" ]]; then
            _hk=$(readlink -f "$hooks_dir" 2>/dev/null || echo "$hooks_dir")
            [[ -n "${_seen_hooks_dir[$_hk]:-}" ]] && continue
            _seen_hooks_dir[$_hk]=1
            echo "Found Kodachi hooks at: $hooks_dir" >> "$COLLECTION_DIR/06-kodachi/hooks-locations.txt"
            substep "hook logs and results from $hooks_dir"

            # Copy logs (redacted, hook execution output can echo secrets)
            if [[ -d "$hooks_dir/logs" ]]; then
                mkdir -p "$COLLECTION_DIR/06-kodachi/hooks-logs"
                find "$hooks_dir/logs" -type f 2>/dev/null | while read -r lfile; do
                    lrel="${lfile#"$hooks_dir"/logs/}"
                    safe_copy_redacted "$lfile" "$COLLECTION_DIR/06-kodachi/hooks-logs" "$lrel"
                done
            fi

            # Copy results (excluding privacy-sensitive files)
            if [[ -d "$hooks_dir/results" ]]; then
                mkdir -p "$COLLECTION_DIR/06-kodachi/hooks-results"
                # Use rsync or find to exclude IP-containing files
                find "$hooks_dir/results" -type f 2>/dev/null | while read -r rfile; do
                    rbase=$(basename "$rfile")
                    # Skip files that contain user IP addresses or personal data
                    case "$rbase" in
                        myip.json|ip_history.json|ip_info.json|my_ip.json|*ip_cache*)
                            echo "EXCLUDED for privacy: $rbase" >> "$COLLECTION_DIR/06-kodachi/hooks-results/PRIVACY_EXCLUDED.txt"
                            continue
                            ;;
                    esac
                    # Determine relative path and recreate structure.
                    # EVERY result file is copied through redact_secrets -
                    # the previous code left non-configs/ files and all
                    # non-json/conf/ovpn files unredacted, which is exactly
                    # how cached_card_*.json leaked live keys.
                    rrel="${rfile#"$hooks_dir"/results/}"
                    safe_copy_redacted "$rfile" "$COLLECTION_DIR/06-kodachi/hooks-results" "$rrel"
                done
            fi
        fi
    done
done

# Check Kodachi binaries in /usr/local/bin/.
# Required binaries are part of every shipped ISO and must be present.
# Optional binaries are AI/experimental components that may not be shipped
# in every release (the orchestrator `kodachi-ai` is not yet bundled in the
# v9.0.1 ISO cache, only the subagents ai-admin/ai-cmd/.../ai-trainer are
# shipped); flagging them as ✗ NOT FOUND in field debug bundles caused
# noise reports against systems that were operating correctly.
KODACHI_BINARIES_REQUIRED=(
    "health-control"
    "tor-switch"
    "dns-switch"
    "dns-leak"
    "routing-switch"
    "ip-fetch"
    "online-auth"
    "integrity-check"
    "permission-guard"
    "logs-hook"
    "deps-checker"
    "workflow-manager"
    "global-launcher"
    "kodachi-soc"
)
KODACHI_BINARIES_OPTIONAL=(
    "kodachi-ai"
    "ai-admin"
    "ai-cmd"
    "ai-discovery"
    "ai-gateway"
    "ai-learner"
    "ai-monitor"
    "ai-scheduler"
    "ai-trainer"
)

echo "Kodachi Binary Status:" > "$COLLECTION_DIR/06-kodachi/binary-status.txt"
echo "" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
echo "[Required]" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
for binary in "${KODACHI_BINARIES_REQUIRED[@]}"; do
    if command -v "$binary" &> /dev/null; then
        echo "✓ $binary: FOUND" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
        timeout -k 3 15 "$binary" --version < /dev/null >> "$COLLECTION_DIR/06-kodachi/binary-status.txt" 2>&1 || echo "  (no version info)" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    else
        echo "✗ $binary: NOT FOUND" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    fi
done
echo "" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
echo "[Optional / AI subsystem]" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
for binary in "${KODACHI_BINARIES_OPTIONAL[@]}"; do
    if command -v "$binary" &> /dev/null; then
        echo "✓ $binary: FOUND" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
        timeout -k 3 15 "$binary" --version < /dev/null >> "$COLLECTION_DIR/06-kodachi/binary-status.txt" 2>&1 || echo "  (no version info)" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    else
        echo "○ $binary: not installed (optional)" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    fi
done

# List /opt/kodachi* contents
ls -lah /opt/kodachi* > "$COLLECTION_DIR/06-kodachi/opt-kodachi-listing.txt" 2>&1 || echo "No /opt/kodachi* directories" > "$COLLECTION_DIR/06-kodachi/opt-kodachi-listing.txt"

# Copy build-meta.json (version/build info)
for build_meta in /opt/*/dashboard/hooks/config/build-meta.json; do
    if [[ -f "$build_meta" ]]; then
        cp "$build_meta" "$COLLECTION_DIR/06-kodachi/build-meta.json" 2>/dev/null || true
        break
    fi
done

# Copy Kodachi config files (non-sensitive)
for hooks_pattern in "/opt/kodachi/dashboard/hooks" "${REAL_HOME}/dashboard/hooks" "/opt/*/dashboard/hooks"; do
    for hooks_dir in $hooks_pattern; do
        if [[ -d "$hooks_dir/config" ]]; then
            mkdir -p "$COLLECTION_DIR/06-kodachi/hooks-config"
            # Copy config files but skip signkeys and any credential files.
            #
            # languages/ is excluded for a MEASURED reason, not tidiness. Audit
            # 2026-09-06 on the live ISO <lab-host> build 8: `--all` sat at step
            # [7/16] for over 15 minutes, and the stuck process was this
            # bundle's own IPv6/IPv4 redaction awk, at 97.7% CPU with 15m19s of
            # CPU time consumed, writing 06-kodachi/hooks-config/languages/en.json.
            #
            # Cause: that redactor walks each RECORD with
            #   while (match(rest, ...)) { ...; rest = substr(rest, RSTART+RLENGTH) }
            # which is O(n^2) in the record length. Measured on this loop shape:
            # 6.6 KB 0.028s, 26 KB 0.183s, 53 KB 0.642s, 106 KB 2.719s, i.e.
            # doubling the input quadruples the time.
            #
            # en.json is the ONLY file in the whole config tree with a line over
            # 100k characters: it is serialised compact, so all 1,131,097 bytes
            # are ONE line, while the other ten catalogs are 13,590 lines with a
            # longest line under 2,081. It alone therefore costs minutes.
            #
            # These catalogs are also worthless in a debug bundle: they are
            # shipped product data, byte-identical on every install, carry no
            # user state, and are 16 MB of the config tree's 17 MB.
            #
            # v1.7 (2026-09-06) made the redactor linear (LC_ALL=C, chunking,
            # a bounded lookback), so the catalogs would no longer hang it;
            # they stay excluded because they carry no state and cost 16 MB.
            #
            # dns-database.json and vpn-providers-public-api.json are excluded
            # for the same reason plus a second one. They are SHIPPED public
            # catalogs, byte-identical on every install, and they are almost
            # entirely country/city fields: the geolocation rules therefore
            # rewrote 285 of their lines (inspector measured 262 + 23) while
            # protecting nothing, because none of it is the user's location.
            # What the machine actually SELECTED is in dns-switch status,
            # dns-mode.json and the routing-switch state, all still collected.
            find "$hooks_dir/config" -type f \( -name "*.json" -o -name "*.conf" -o -name "*.toml" \) \
                ! -path "*/signkeys/*" ! -path "*/secrets/*" ! -path "*credential*" ! -path "*password*" ! -path "*token*" \
                ! -path "*/languages/*" \
                ! -name "license*" ! -name "licence*" ! -name "*entitlement*" ! -name "*claim*" \
                ! -name "dns-database*.json" ! -name "vpn-providers-public-api.json" \
                2>/dev/null | while read -r cfile; do
                crel="${cfile#"$hooks_dir"/config/}"
                # Path-based exclusions above are not enough, a file named
                # general-config.json can still embed credentials. Redact
                # every copied config file as well.
                safe_copy_redacted "$cfile" "$COLLECTION_DIR/06-kodachi/hooks-config" "$crel"
            done
            break 2
        fi
    done
done

# Kodachi systemd services
safe_exec "$COLLECTION_DIR/06-kodachi/kodachi-services.txt" "systemctl list-units 'kodachi*' --all --no-pager"
# v1.8: list-units only shows units systemd has LOADED. A unit that is
# installed but disabled and never pulled in (kodachi-cleanup-live-apt,
# kodachi-fallback-user-cleanup) was absent from the bundle entirely, which is
# exactly the state a "why did X not run" report needs to see.
safe_exec "$COLLECTION_DIR/06-kodachi/kodachi-services.txt" "echo; echo '== installed kodachi* unit files (loaded or not)'; systemctl list-unit-files 'kodachi*' --no-pager"

# Per-unit deep dive: status, definition, restart counters and journal slice
# for every kodachi* unit. A crash-looping service is invisible without
# NRestarts/ExecMainStatus and its own journal lines.
mkdir -p "$COLLECTION_DIR/06-kodachi/units"
{
    systemctl list-units 'kodachi*' --all --no-legend --plain 2>/dev/null | awk '{print $1}'
    # Template units (name@.service) cannot be queried without an instance.
    systemctl list-unit-files 'kodachi*' --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -v '@\.'
} | sort -u | while read -r kunit; do
    [[ -n "$kunit" ]] || continue
    uname_safe="${kunit//[^A-Za-z0-9._-]/_}"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-status.txt" "kdc_unit_status '$kunit'"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-show.txt" "systemctl show '$kunit' -p LoadState,UnitFileState,ActiveState,SubState,Result,ConditionResult,ConditionTimestamp,AssertResult,NRestarts,ExecMainStatus,ExecMainStartTimestamp,Restart,RestartUSec,FragmentPath"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-cat.txt" "systemctl cat '$kunit' --no-pager"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-journal.txt" "journalctl -b -u '$kunit' --no-pager -n 500"
done

# Crash evidence: coredumps and kernel core routing. Rust service panics and
# segfaults leave no trace in the bundle without this.
safe_exec "$COLLECTION_DIR/06-kodachi/coredumps.txt" "coredumpctl list --no-pager 2>/dev/null | tail -60 || echo 'coredumpctl unavailable'"
safe_exec "$COLLECTION_DIR/06-kodachi/coredumps.txt" "coredumpctl info --no-pager 2>/dev/null | head -200 || true"
safe_exec "$COLLECTION_DIR/06-kodachi/coredumps.txt" "cat /proc/sys/kernel/core_pattern"
safe_exec "$COLLECTION_DIR/06-kodachi/coredumps.txt" "ls -lah /var/crash/ /var/lib/systemd/coredump/ 2>/dev/null || echo 'no crash dirs'"

# Hooks state files outside config/results/logs: top-level JSON plus the
# state/cache/db/flags dirs hold runtime state needed for root-causing
# (autoshield state, DNS cache meta, session flags).
for hooks_pattern in "/opt/kodachi/dashboard/hooks" "${REAL_HOME}/dashboard/hooks"; do
    for hooks_dir in $hooks_pattern; do
        [[ -d "$hooks_dir" ]] || continue
        mkdir -p "$COLLECTION_DIR/06-kodachi/hooks-state"
        find "$hooks_dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null | while read -r sfile; do
            safe_copy_redacted "$sfile" "$COLLECTION_DIR/06-kodachi/hooks-state" "top-level/$(basename "$sfile")"
        done
        for sdir in state cache db flags .soc-state conky tmp; do
            [[ -d "$hooks_dir/$sdir" ]] || continue
            # cache/ip-fetch/ips/<ip>.json is one geolocation record per
            # address the machine has had (city, coordinates, ISP); it is
            # exactly what the results loop already excludes as ip_history.
            find "$hooks_dir/$sdir" -type f -size -2M -not -path '*/ip-fetch/ips/*' -not -name '*ip_history*' 2>/dev/null | head -200 | while read -r sfile; do
                srel="${sfile#"$hooks_dir"/}"
                safe_copy_redacted "$sfile" "$COLLECTION_DIR/06-kodachi/hooks-state" "$srel"
            done
        done
        break 2
    done
done

# Native dashboard app-side logs/state (~/.local/share, ~/.config): the GUI
# shell writes WebKit/renderer diagnostics outside hooks/logs.
mkdir -p "$COLLECTION_DIR/06-kodachi/dashboard-app"
for dapp_dir in "$REAL_HOME/.local/share/kodachi-dashboard" "$REAL_HOME/.local/share/cloud.kodachi.dashboard" "$REAL_HOME/.config/kodachi-dashboard"; do
    [[ -d "$dapp_dir" ]] || continue
    find "$dapp_dir" -type f \( -name "*.log" -o -name "*.json" -o -name "*.txt" \) -size -5M 2>/dev/null | head -50 | while read -r dfile; do
        safe_copy_redacted "$dfile" "$COLLECTION_DIR/06-kodachi/dashboard-app" "$(basename "$dapp_dir")-$(basename "$dfile")"
    done
done

# Health-control diagnostics (read-only commands, safe to run)
# v1.8: each probe used to end in `|| echo 'X unavailable'`, so a binary that
# is present and exited non-zero (dns-switch status exit 1 on NA-Central-Hub)
# was recorded as exit 0 plus a false "unavailable". The probe now keeps its
# real exit code, which safe_exec writes as [EXIT CODE: n] and TRIAGE lists.
if command -v health-control &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-security-score.txt" "health-control security-score --json 2>/dev/null"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-net-check.txt" "health-control net-check --json 2>/dev/null"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-ipv6-status.txt" "health-control ipv6-status --json 2>/dev/null"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-swap-status.txt" "health-control swap-status --json 2>/dev/null"
fi

# DNS-switch status
if command -v dns-switch &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/dns-switch-status.txt" "dns-switch status --json 2>/dev/null"
fi

# Routing-switch state
if command -v routing-switch &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/routing-switch-status.txt" "routing-switch status --json 2>/dev/null"
fi

# Kodachi SOC host-security telemetry snapshot (read-only collector)
if command -v kodachi-soc &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/kodachi-soc-snapshot.json" "kodachi-soc snapshot --json 2>/dev/null"
fi

# ============================================================================
# v1.7: what an engineer needs to TRACE a bug, not only to see that it happened.
# Everything below is read-only and bounded by safe_exec's timeout.
# ============================================================================
substep "binary inventory, signature and dependency verdicts, status probes"
KDC_HOOKS=""
for _hp in /opt/kodachi/dashboard/hooks "${REAL_HOME}/dashboard/hooks" /opt/*/dashboard/hooks; do
    if [[ -d "$_hp" ]]; then KDC_HOOKS="$_hp"; break; fi
done
# Resolve a Kodachi binary: the hooks root first (what the dashboard runs),
# then PATH (the global-launcher symlinks). `command -v` alone misses every
# binary on a system whose symlinks were never deployed, which is itself a bug
# the bundle must be able to show.
kbin() {
    if [[ -n "$KDC_HOOKS" ]] && [[ -x "$KDC_HOOKS/$1" ]]; then
        echo "$KDC_HOOKS/$1"
    else
        command -v "$1" 2>/dev/null
    fi
}

if [[ -n "$KDC_HOOKS" ]]; then
    # Every executable in the hooks root with size, mtime, md5 and the version
    # it reports. This is the only way to know WHICH BUILD the user is running
    # when a bug is reported: build-meta.json describes the pack, not what is
    # on disk after a partial update. Every binary is asked for its version
    # with the flag it really supports (see the case below); GUI and session
    # binaries answer --version before any window or daemon code runs.
    _ph0=$(date +%s.%N)
    {
        echo "Hooks root: $KDC_HOOKS"
        echo "One row per executable: size, mtime, md5, then the version it reports."
        echo ""
        for _b in "$KDC_HOOKS"/*; do
            [[ -f "$_b" ]] && [[ -x "$_b" ]] || continue
            _n=$(basename "$_b")
            printf '%-28s %11s bytes  mtime %s  md5 %s\n' "$_n" \
                "$(stat -c%s "$_b" 2>/dev/null)" \
                "$(stat -c%y "$_b" 2>/dev/null | cut -d. -f1)" \
                "$(md5sum < "$_b" 2>/dev/null | cut -c1-32)"
            # v1.8: these used to get no version row at all, and oniux (upstream,
            # no version flag) printed a clap usage error. kodachi-dashboard and
            # kodachi-session-helper both handle --version before any window or
            # daemon code (dashboard main.rs CLI-mode match, session-helper
            # handle_version); tun2socks is Go and uses the single-dash flag.
            case "$_n" in
                oniux)
                    _own=$(dpkg-query -S "$_b" 2>/dev/null | head -1 | cut -d: -f1)
                    if [[ -n "$_own" ]]; then
                        _v="(no version flag upstream) package $_own $(dpkg-query -W -f='${Version}' "$_own" 2>/dev/null)"
                    else
                        _v="(no version flag upstream, not owned by a package: identify it by md5)"
                    fi
                    printf '%-28s   version: %s\n' "" "$_v"
                    continue ;;
                tun2socks*)
                    _v=$(timeout -k 3 15 "$_b" -version < /dev/null 2>&1 | head -3 | tr '\n' ' ') ;;
                *)
                    _v=$(timeout -k 3 15 "$_b" --version < /dev/null 2>&1 | head -3 | tr '\n' ' ') ;;
            esac
            printf '%-28s   version: %s\n' "" "${_v:-(no output)}"
        done
        echo ""
        echo "Detached signatures present in results/signatures, by stamp:"
        ls -1 "$KDC_HOOKS/results/signatures" 2>/dev/null \
            | sed -E 's/^.*_v//; s/\.sig(\.info)?$//' | sort | uniq -c \
            || echo "  (no signatures directory)"
    } > "$COLLECTION_DIR/06-kodachi/binary-inventory.txt" 2>&1
    printf '%8.2fs rc=0   [phase] binary-inventory (md5 + --version of every hook binary)\n' "$(awk -v a="$_ph0" -v b="$(date +%s.%N)" 'BEGIN{print b-a}')" >> "$CMD_TIMING_LOG" 2>/dev/null

    # Ownership and permissions of the hooks tree, two levels deep. A root-owned
    # cache or results file written by a sudo run is a recurring bug class here
    # (the unprivileged dashboard then cannot update it) and only a listing that
    # carries the OWNER can show it. languages/ is skipped: 11 catalogs, no state.
    safe_exec "$COLLECTION_DIR/06-kodachi/hooks-tree-ownership.txt" \
        "find '$KDC_HOOKS' -maxdepth 2 -not -path '*/languages/*' -printf '%M %-8u %-8g %11s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -k7"
fi

# Authoritative verdicts the binaries can give about themselves. Each one
# answers a question support otherwise has to ask the user:
#   integrity-check check-signatures  are the binaries the ones we shipped
#   deps-checker check-all            which apt packages are missing for which binary
#   global-launcher verify            are the /usr/local/bin symlinks intact
#   permission-guard status           is the permission fixer armed and what did it do
#   tor-switch *                      which Tor instances exist and what state they are in
#   online-auth check-login/license   is the user logged in / licensed (ids are redacted)
#   conky-status snapshot             what the desktop HUD is actually showing
#   health-control *-status           every read-only status verb the hardening has
_ic=$(kbin integrity-check)
[[ -n "$_ic" ]] && safe_exec "$COLLECTION_DIR/06-kodachi/integrity-check-signatures.txt" "'$_ic' check-signatures --json"
_dc=$(kbin deps-checker)
[[ -n "$_dc" ]] && safe_exec "$COLLECTION_DIR/06-kodachi/deps-checker-check-all.txt" "'$_dc' check-all --json"
_gl=$(kbin global-launcher)
[[ -n "$_gl" ]] && safe_exec "$COLLECTION_DIR/06-kodachi/global-launcher-verify.txt" "'$_gl' verify --json"
_pg=$(kbin permission-guard)
[[ -n "$_pg" ]] && safe_exec "$COLLECTION_DIR/06-kodachi/permission-guard-status.txt" "'$_pg' status --json"
_ts=$(kbin tor-switch)
if [[ -n "$_ts" ]]; then
    for _verb in tor-status-all status-main-tor list-instances; do
        KDC_CMD_TIMEOUT=60 safe_exec "$COLLECTION_DIR/06-kodachi/tor-switch-${_verb}.txt" "'$_ts' $_verb --json"
    done
fi
_oa=$(kbin online-auth)
if [[ -n "$_oa" ]]; then
    KDC_CMD_TIMEOUT=60 safe_exec "$COLLECTION_DIR/06-kodachi/online-auth-check-login.txt" "'$_oa' check-login --json"
    # license-status is NOT copied whole: measured 2026-09-06, its JSON carries
    # tier_claim.payload_b64 / signature, a signed entitlement claim, which is a
    # credential. Only the scalar facts support needs survive, by name.
    KDC_CMD_TIMEOUT=60 safe_exec "$COLLECTION_DIR/06-kodachi/online-auth-license-status.txt" \
        "'$_oa' license-status --json 2>&1 | tr -d '\\n' | grep -oE '\"(status|has_license|tier|is_blocked|devices_allowed|devices_used|activated_at|expires_at|features)\":(\"[^\"]*\"|\[[^]]*\]|[^,}]*)' || echo 'license-status: no parsable fields'"
fi
_cs=$(kbin conky-status)
[[ -n "$_cs" ]] && KDC_CMD_TIMEOUT=90 safe_exec "$COLLECTION_DIR/06-kodachi/conky-status-snapshot.txt" "'$_cs' snapshot --json"
_hc=$(kbin health-control)
if [[ -n "$_hc" ]]; then
    mkdir -p "$COLLECTION_DIR/06-kodachi/health-control"
    for _verb in internet-status kill-switch-status monitoring-status disk-encryption-status \
                 tirdad-status kloak-status entropy-status usb-status security-status \
                 emergency-lockdown-status coldboot-defense-status screensaver-status \
                 dpms-status conky-status auto-updates-status ram-wipe-status swap-encrypt-status \
                 ipv6-status encryption-status 2fa-status lynis-status password-policy-status \
                 user-security-status system-maintenance-status; do
        KDC_CMD_TIMEOUT=60 safe_exec "$COLLECTION_DIR/06-kodachi/health-control/${_verb}.txt" "'$_hc' $_verb --json"
    done
fi

substep "Kodachi files under /etc and per-user state"
# Kodachi's own files under /etc: sudoers rules (which decide whether a hook
# may escalate), AppArmor profiles, tmpfiles, units, autostart entries. None
# of these is a secret; all of them are where "permission denied" bugs live.
mkdir -p "$COLLECTION_DIR/06-kodachi/etc"
for _ep in /etc/kodachi* /etc/default/kodachi* /etc/tmpfiles.d/kodachi* \
           /etc/apparmor.d/kodachi* /etc/systemd/system/kodachi* \
           /etc/xdg/autostart/kodachi* /etc/sudoers.d/kodachi* /etc/profile.d/kodachi*; do
    [[ -e "$_ep" ]] || continue
    _tag=$(printf '%s' "${_ep#/etc/}" | tr '/' '_')
    if [[ -d "$_ep" ]]; then
        safe_exec "$COLLECTION_DIR/06-kodachi/etc/${_tag}.listing.txt" "ls -laR '$_ep'"
        find "$_ep" -maxdepth 2 -type f -size -1M 2>/dev/null | head -60 | while read -r _ef; do
            safe_copy_redacted "$_ef" "$COLLECTION_DIR/06-kodachi/etc" "${_tag}/${_ef#"$_ep"/}"
        done
    elif [[ -f "$_ep" ]]; then
        safe_copy_redacted "$_ep" "$COLLECTION_DIR/06-kodachi/etc" "$_tag"
    fi
done

# Per-user Kodachi state: the conky watchdog and error logs, the launcher's
# cache, the AI subsystem's logs, and the dashboard's own app-data directory
# (listing only for the WebKit/localstorage blobs; text logs and json copied).
# launcher-cache holds copied binaries and the .kst2 entitlement is a
# credential, both are skipped by name.
mkdir -p "$COLLECTION_DIR/06-kodachi/user-state"
for _ud in "$REAL_HOME/.cache/kodachi" "$REAL_HOME/.config/kodachi" \
           "$REAL_HOME/.local/share/kodachi" "$REAL_HOME/.local/share/com.kodachi.dashboard" \
           "$REAL_HOME/.local/share/kodachi-dashboard" "$REAL_HOME/.config/kodachi-dashboard"; do
    [[ -d "$_ud" ]] || continue
    _tag=$(printf '%s' "${_ud#"$REAL_HOME"/}" | tr '/' '_')
    safe_exec "$COLLECTION_DIR/06-kodachi/user-state/${_tag}.listing.txt" \
        "find '$_ud' -maxdepth 3 -not -path '*/launcher-cache/*' -not -path '*/WebKitCache/*' -printf '%M %-8u %11s %TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | head -400"
    find "$_ud" -maxdepth 4 -type f \( -name '*.log' -o -name '*.json' -o -name '*.conf' \) -size -2M \
        -not -path '*/launcher-cache/*' -not -path '*/WebKitCache/*' -not -path '*/localstorage/*' \
        -not -name '*.kst2' 2>/dev/null | head -120 | while read -r _uf; do
        safe_copy_redacted "$_uf" "$COLLECTION_DIR/06-kodachi/user-state/${_tag}" "${_uf#"$_ud"/}"
    done
done

fi # end CATEGORY 6

# ============================================================================
# CATEGORY 7: Installation & Package Logs
# ============================================================================
if [[ "${CAT_ENABLED[7]}" == "1" ]]; then
progress "Collecting installation and package logs..."

mkdir -p "$COLLECTION_DIR/07-installation-packages"

# Calamares installer logs (check all known locations)
# v1.8: /var/log/installer is the DEBIAN-INSTALLER log directory and is
# copied once, below, into debian-installer/. Listing it here too shipped the
# same files twice (14.8 MB on NA-Central-Hub) under a misleading calamares/.
CALAMARES_DIRS=(
    "/var/log/calamares"
    "${REAL_HOME}/.cache/calamares"
    "/tmp/calamares-logs"
    "/var/log/Calamares"
)
for calamares_dir in "${CALAMARES_DIRS[@]}"; do
    if [[ -d "$calamares_dir" ]]; then
        mkdir -p "$COLLECTION_DIR/07-installation-packages/calamares"
        cp -r "$calamares_dir"/* "$COLLECTION_DIR/07-installation-packages/calamares/" 2>/dev/null || true
        echo "Found: $calamares_dir" >> "$COLLECTION_DIR/07-installation-packages/calamares/sources.txt"
    fi
done
# Single-file Calamares log
safe_copy "/var/log/Calamares.log" "$COLLECTION_DIR/07-installation-packages"

# Debian installer logs (d-i)
if [[ -d "/var/log/installer" ]]; then
    mkdir -p "$COLLECTION_DIR/07-installation-packages/debian-installer"
    cp -r /var/log/installer/* "$COLLECTION_DIR/07-installation-packages/debian-installer/" 2>/dev/null || true
fi
# Post-install Kodachi finish logs.
# v1.8: the fixed names this block used to copy (kodachi-finish-install.log,
# kodachi-deps-install.log, kodachi-binary-install.log, kodachi-autoshield.log,
# kodachi-fix-resolvconf.log, kodachi-plymouth-firstboot.log and
# /target/tmp/kodachi-grub-theme.log) are written by nothing in Kodachi, so
# every bundle carried seven ".missing" stubs that read like failed installs.
# What the product really writes, verified against the sources:
#   /var/log/kodachi-di-install.log       d-i finish-install.d hooks (05, 14, 90)
#   /var/log/kodachi-di-verify.log        kodachi-finish-install verification
#   /var/log/kodachi-grub-theme.log       kodachi-apply-grub-theme (installed system)
#   /var/log/kodachi-post-install.log     post-install cleanup units
#   /var/log/kodachi-cryptswap-activate.log, kodachi-crypttab-fix.log
#   /var/log/kodachi/kodachi-deps-install-<timestamp>.log
# All of them match the kodachi* sweep below and land ONCE in kodachi-logs/.

# Anything else under /var/log named kodachi-*.log
mkdir -p "$COLLECTION_DIR/07-installation-packages/kodachi-logs"
# v1.7: any file named kodachi*, not only *.log. /var/log/kodachi-binary-audit.json
# and the root-only /var/log/kodachi/kodachi-deps-install-<date>.log were both
# missed by the *.log pattern. No size predicate: safe_copy already keeps the
# last 50 MB of an oversized file, and a runaway kodachi log is exactly what a
# support bundle exists to carry (a -size cap here silently dropped it).
find /var/log -maxdepth 2 -type f -name 'kodachi*' 2>/dev/null | head -80 | while read -r kl; do
    safe_copy "$kl" "$COLLECTION_DIR/07-installation-packages/kodachi-logs"
done

# v1.7: apt channel state. Since 10.x Kodachi installs and updates through apt
# (stable / beta / dev channels), so "which channel is this machine on and which
# kodachi-* package versions are installed vs available" is the first question
# for any update or missing-component report.
mkdir -p "$COLLECTION_DIR/07-installation-packages/apt-channels"
safe_copy "/etc/apt/sources.list" "$COLLECTION_DIR/07-installation-packages/apt-channels"
for _sl in /etc/apt/sources.list.d/*; do
    [[ -f "$_sl" ]] && safe_copy "$_sl" "$COLLECTION_DIR/07-installation-packages/apt-channels"
done
safe_exec "$COLLECTION_DIR/07-installation-packages/apt-channels/kodachi-packages.txt" \
    "echo '== installed kodachi* packages (dpkg)'; dpkg-query -W -f='\${Package}\t\${Version}\t\${Status}\n' 'kodachi*' 2>/dev/null; echo; echo '== apt-cache policy for every kodachi* package apt knows'; apt-cache policy \$(apt-cache search --names-only '^kodachi' 2>/dev/null | awk '{print \$1}') 2>/dev/null"
# v1.8: a held package silently blocks the kodachi-* upgrade path.
safe_exec "$COLLECTION_DIR/07-installation-packages/apt-channels/apt-mark-showhold.txt" "apt-mark showhold"
safe_exec "$COLLECTION_DIR/07-installation-packages/apt-channels/apt-keys-and-pins.txt" \
    "ls -la /etc/apt/trusted.gpg.d/ /etc/apt/keyrings/ /usr/share/keyrings/ 2>/dev/null | grep -iE 'kodachi|total|^/' ; echo; ls -la /etc/apt/preferences.d/ 2>/dev/null; cat /etc/apt/preferences.d/* 2>/dev/null"

# /var/lib/kodachi marker files (one-shot install/upgrade markers, their
# presence/absence tells us which post-install hooks have run).
if [[ -d /var/lib/kodachi ]]; then
    mkdir -p "$COLLECTION_DIR/07-installation-packages/kodachi-state"
    cp -r /var/lib/kodachi/* "$COLLECTION_DIR/07-installation-packages/kodachi-state/" 2>/dev/null || true
    safe_exec "$COLLECTION_DIR/07-installation-packages/kodachi-state/listing.txt" \
        "ls -laR /var/lib/kodachi"
fi

# /var/log/live-build/ if it survived install (rare but useful for live-ISO
# build-time issues that surface only after install).
if [[ -d /var/log/live-build ]]; then
    mkdir -p "$COLLECTION_DIR/07-installation-packages/live-build"
    cp -r /var/log/live-build/* "$COLLECTION_DIR/07-installation-packages/live-build/" 2>/dev/null || true
fi

# Crypttab (raw copy, critical for cryptswap timeout debugging)
safe_copy "/etc/crypttab" "$COLLECTION_DIR/07-installation-packages"

# Crypttab repair log (Kodachi boot-time cryptswap fixer): collected once, by
# the kodachi* sweep above, into kodachi-logs/.

# Partition layout
if command -v parted &> /dev/null; then
    safe_exec "$COLLECTION_DIR/07-installation-packages/parted-list.txt" "parted -l 2>/dev/null || echo 'parted failed'"
fi

# Preseed configuration (used during installation)
for preseed in /cdrom/preseed*.cfg /preseed*.cfg /tmp/preseed*.cfg; do
    if [[ -f "$preseed" ]]; then
        safe_copy "$preseed" "$COLLECTION_DIR/07-installation-packages"
    fi
done

# EFI boot entries (critical for UEFI boot debugging)
mkdir -p "$COLLECTION_DIR/07-installation-packages/efi-boot"
if command -v efibootmgr &>/dev/null; then
    safe_exec "$COLLECTION_DIR/07-installation-packages/efi-boot/efibootmgr.txt" "efibootmgr -v"
fi
if [[ -d "/boot/efi" ]]; then
    safe_exec "$COLLECTION_DIR/07-installation-packages/efi-boot/efi-contents.txt" "find /boot/efi -type f"
fi
if [[ -d "/sys/firmware/efi" ]]; then
    # v1.8: `| head -50` cut the listing before SecureBoot, MokList and
    # SbatLevel on a real firmware. Names only (no values) are small, so all of
    # them are listed, and the three Secure Boot state variables are decoded.
    # An efivars file is 4 attribute bytes followed by the value.
    safe_exec "$COLLECTION_DIR/07-installation-packages/efi-boot/efi-vars-list.txt" "ls -1 /sys/firmware/efi/efivars/"
    {
        for _ev in SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c MokSBStateRT-605dab50-e046-4300-abb6-3dd810dd8b23; do
            _evf="/sys/firmware/efi/efivars/$_ev"
            if [[ -r "$_evf" ]]; then
                printf '%-14s %s\n' "${_ev%%-*}" "$(od -An -t u1 -j4 "$_evf" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
            else
                printf '%-14s %s\n' "${_ev%%-*}" "absent"
            fi
        done
        echo "(SecureBoot 1 = enforcing, SetupMode 1 = no platform key enrolled, MokSBStateRT 1 = shim validation disabled)"
        command -v mokutil >/dev/null 2>&1 && timeout -k 3 15 mokutil --sb-state < /dev/null 2>&1
    } > "$COLLECTION_DIR/07-installation-packages/efi-boot/secure-boot-state.txt" 2>&1
fi

# initramfs configuration (affects boot)
mkdir -p "$COLLECTION_DIR/07-installation-packages/initramfs"
if [[ -d "/etc/initramfs-tools" ]]; then
    cp -r /etc/initramfs-tools/* "$COLLECTION_DIR/07-installation-packages/initramfs/" 2>/dev/null || true
fi
# Check which initramfs hooks are installed
safe_exec "$COLLECTION_DIR/07-installation-packages/initramfs/hooks-list.txt" "ls -la /usr/share/initramfs-tools/hooks/ 2>/dev/null"
safe_exec "$COLLECTION_DIR/07-installation-packages/initramfs/scripts-list.txt" "ls -laR /usr/share/initramfs-tools/scripts/ 2>/dev/null"
# dracut if used instead
if [[ -d "/etc/dracut.conf.d" ]]; then
    mkdir -p "$COLLECTION_DIR/07-installation-packages/dracut"
    cp -r /etc/dracut.conf.d/* "$COLLECTION_DIR/07-installation-packages/dracut/" 2>/dev/null || true
fi

# Package management logs
safe_copy "/var/log/apt/history.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/apt/term.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/dpkg.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/alternatives.log" "$COLLECTION_DIR/07-installation-packages"

# Installed packages list
safe_exec "$COLLECTION_DIR/07-installation-packages/dpkg-list.txt" "dpkg -l"
safe_exec "$COLLECTION_DIR/07-installation-packages/apt-list.txt" "apt list --installed 2>/dev/null"

fi # end CATEGORY 7

# ============================================================================
# CATEGORY 8: Display & Desktop Environment + User-session diagnostics
# audit 2026-05-07: massively expanded to capture user-systemd, xsession-errors,
# xfconf state, autostart entries, and session timing, without these the
# 135 s post-login stall on the CentOS-Stream-9 / GLaDOS bundles was
# undiagnosable from the collected data alone.
# ============================================================================
if [[ "${CAT_ENABLED[8]}" == "1" ]]; then
progress "Collecting display, desktop, and user-session information..."

mkdir -p "$COLLECTION_DIR/08-display-desktop"
mkdir -p "$COLLECTION_DIR/08-display-desktop/user-session"
mkdir -p "$COLLECTION_DIR/08-display-desktop/xfce-config"
mkdir -p "$COLLECTION_DIR/08-display-desktop/autostart"

safe_copy "/var/log/Xorg.0.log" "$COLLECTION_DIR/08-display-desktop"
safe_copy "/var/log/Xorg.0.log.old" "$COLLECTION_DIR/08-display-desktop"

# Display manager logs (lightdm + greeter + per-seat X server logs)
for dm_dir in "/var/log/lightdm" "/var/log/sddm" "/var/log/gdm3"; do
    if [[ -d "$dm_dir" ]]; then
        mkdir -p "$COLLECTION_DIR/08-display-desktop/display-manager"
        cp -r "$dm_dir"/* "$COLLECTION_DIR/08-display-desktop/display-manager/" 2>/dev/null || true
    fi
done

# Basic display info
safe_exec "$COLLECTION_DIR/08-display-desktop/xrandr.txt" "xrandr --verbose"
safe_exec "$COLLECTION_DIR/08-display-desktop/session-type.txt" "echo \${XDG_SESSION_TYPE:-not_set}"
safe_exec "$COLLECTION_DIR/08-display-desktop/desktop-session.txt" "echo \${DESKTOP_SESSION:-not_set}"

# ---- USER-SIDE SYSTEMD STATE ---------------------------------------------
# Without this, post-login hangs (xfce4-session waiting on a user service or
# a stuck autostart entry) are invisible. Boot-side journalctl-full.txt
# captures system events but NOT systemd[uid].
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemd-analyze-user-time.txt" \
    "systemd-analyze --user time"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemd-analyze-user-blame.txt" \
    "systemd-analyze --user blame"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemd-analyze-user-critical-chain.txt" \
    "systemd-analyze --user critical-chain"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemctl-user-all-units.txt" \
    "systemctl --user list-units --all --no-pager"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemctl-user-failed.txt" \
    "systemctl --user --failed --no-pager"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/systemctl-user-timers.txt" \
    "systemctl --user list-timers --all --no-pager"
substep "user journal, XFCE config, autostart entries"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-user-current-boot.txt" \
    "journalctl --user -b --no-pager"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-user-warnings.txt" \
    "journalctl --user -b -p warning --no-pager"
# v1.8: this is the FALLBACK for when the user journal above could not be
# read. Run unconditionally it duplicated journalctl-user-current-boot.txt
# (1.1 MB each on NA-Central-Hub).
_ujf="$COLLECTION_DIR/08-display-desktop/user-session/journalctl-user-current-boot.txt"
# "Readable" also excludes the two replies journalctl gives when it could
# not see the user journal at all, which are not a journal.
if [[ -n "${REAL_UID:-}" ]] && { [[ ! -s "$_ujf" ]] || [[ "$(head -c1 "$_ujf" 2>/dev/null)" == "[" ]] \
        || grep -qE '^-- No entries --$|No journal files were found' "$_ujf" 2>/dev/null; }; then
    safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-uid.txt" \
        "journalctl _UID=${REAL_UID} -b --no-pager"
fi
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/loginctl-sessions.txt" \
    "loginctl list-sessions --no-pager && echo '---' && loginctl list-users --no-pager"
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/loginctl-session-status.txt" \
    "for s in \$(loginctl list-sessions --no-legend | awk '{print \$1}'); do echo '=== Session '\$s' ==='; loginctl session-status \$s --no-pager; echo; done"
# audit 2026-05-10: last(1) and lastlog(1) were dropped from the default
# Trixie install (replaced by lastlog2 / wtmpdb). Probe several backends
# in order so the bundle keeps producing useful login history regardless
# of which tools the host actually ships.
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/last-logins.txt" \
    "if command -v last >/dev/null 2>&1; then last -n 30; \
     elif command -v wtmpdb >/dev/null 2>&1; then wtmpdb last 2>/dev/null | head -30; \
     else journalctl _COMM=systemd-logind --no-pager -n 100 2>/dev/null | grep -E 'New session|Removed session' | tail -30; fi"
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/lastlog.txt" \
    "if command -v lastlog >/dev/null 2>&1; then lastlog; \
     elif command -v lastlog2 >/dev/null 2>&1; then lastlog2; \
     else echo '(no lastlog/lastlog2, Trixie ships neither by default; falling back to per-user systemd journal:)'; \
          for u in \$(awk -F: '\$3>=1000 && \$3<60000 {print \$1}' /etc/passwd); do \
              echo \"--- \$u ---\"; \
              journalctl _UID=\$(id -u \"\$u\" 2>/dev/null) --no-pager -n 1 -o short-iso 2>/dev/null | tail -1 || true; \
          done; fi"

# ---- ~/.xsession-errors AND XFCE LOGS ------------------------------------
# This is THE file that captures every Xsession.d/* and autostart .desktop
# stdout/stderr, slow login symptoms always surface here first.
safe_copy_user_redacted "${REAL_HOME}/.xsession-errors" "$COLLECTION_DIR/08-display-desktop/user-session"
safe_copy_user_redacted "${REAL_HOME}/.xsession-errors.old" "$COLLECTION_DIR/08-display-desktop/user-session"
safe_copy_user "${REAL_HOME}/.cache/sessions/xfce4-session-:0" "$COLLECTION_DIR/08-display-desktop/user-session"
# XFCE-specific log files (xfsettingsd, conky, kodachi user-side scripts)
if [[ -n "$REAL_HOME" ]] && [[ -d "$REAL_HOME/.cache" ]]; then
    sudo -u "$REAL_USER" find "$REAL_HOME/.cache" -maxdepth 2 -type f \
        \( -name '*.log' -o -name 'xfsettingsd*' -o -name 'kodachi-*' \) \
        -size -5M 2>/dev/null | while read -r logf; do
        safe_copy_user "$logf" "$COLLECTION_DIR/08-display-desktop/user-session"
    done
fi

# Saved XFCE session files (a stale saved session is a known cause of
# 90-180 s post-login stalls, xfce4-session retries restore with timeouts).
if sudo -u "$REAL_USER" test -d "$REAL_HOME/.cache/sessions" 2>/dev/null; then
    safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/cache-sessions-listing.txt" \
        "ls -laR \$HOME/.cache/sessions"
fi

# ---- XFCE CONFIG (xfconf channels) ---------------------------------------
# xfconf is XFCE's per-user settings DB. Slow logins can be caused by stale
# session restore flags, broken keyboard shortcuts pointing at missing bins,
# or panel layouts referencing dead D-Bus services.
safe_exec_user "$COLLECTION_DIR/08-display-desktop/xfce-config/xfconf-channels.txt" \
    "xfconf-query -l"
for chan in xfce4-session xfwm4 xsettings xfce4-desktop xfce4-panel xfce4-keyboard-shortcuts displays; do
    safe_exec_user "$COLLECTION_DIR/08-display-desktop/xfce-config/xfconf-${chan}.txt" \
        "xfconf-query -c '$chan' -lv"
done

# Per-user XFCE XML configs (always-up-to-date snapshot, even if xfconfd is
# the one hung). Captured via filesystem to bypass any xfconfd issue.
if sudo -u "$REAL_USER" test -d "$REAL_HOME/.config/xfce4" 2>/dev/null; then
    sudo -u "$REAL_USER" find "$REAL_HOME/.config/xfce4" -maxdepth 5 -type f \
        \( -name '*.xml' -o -name '*.rc' \) -size -2M 2>/dev/null | while read -r f; do
        # Preserve relative path under xfce-config/
        rel="${f#${REAL_HOME}/.config/xfce4/}"
        target="$COLLECTION_DIR/08-display-desktop/xfce-config/files/$rel"
        mkdir -p "$(dirname "$target")"
        # shellcheck disable=SC2024
        # SC2024 warns that sudo does not affect the redirect. That is exactly
        # what is wanted here and is not a defect: the READ must drop to the
        # desktop user so a root-only file is never pulled in, while the WRITE
        # goes to the staging tree, which only root can write. Swapping to
        # "| sudo tee" as the check suggests would invert both halves.
        sudo -u "$REAL_USER" cat "$f" > "$target" 2>/dev/null || true
    done
fi

# ---- AUTOSTART ENTRIES (system + user) -----------------------------------
# These are the .desktop files that xfce4-session iterates at login. A
# blocking exec here surfaces directly as a login stall.
# v1.5: also produce a Phase= / Hidden= / Exec= SUMMARY TABLE so root cause
# is identifiable without parsing each .desktop by hand. Phase=Initialization
# entries are the ones that BLOCK xfce4-session, they are the prime suspects
# in any post-login stall. Reproduces the macOS-Ventura bundle finding where
# pkcs11-register's Phase=Initialization caused a 60-90 s pcscd stall.
for d in /etc/xdg/autostart "${REAL_HOME}/.config/autostart"; do
    if [[ -d "$d" ]]; then
        # v1.8: the user directory was flattened to _home_<login>_.config_autostart,
        # which put the login name into a zip entry path the redactor cannot reach.
        if [[ "$d" == /etc/* ]]; then
            rel="$(echo "$d" | tr '/' '_')"
        else
            rel="_user-home_.config_autostart"
        fi
        mkdir -p "$COLLECTION_DIR/08-display-desktop/autostart/${rel}"
        if [[ "$d" == /etc/* ]]; then
            cp -r "$d"/*.desktop "$COLLECTION_DIR/08-display-desktop/autostart/${rel}/" 2>/dev/null || true
        else
            sudo -u "$REAL_USER" sh -c "cp -r '$d'/*.desktop '$COLLECTION_DIR/08-display-desktop/autostart/${rel}/'" 2>/dev/null || true
        fi
    fi
done

# Phase= / Hidden= / NotShowIn= summary across every visible autostart entry.
# Output is a fixed-width table you can grep for "Initialization" to surface
# blocking entries instantly.
{
    printf '%-50s %-20s %-10s %-30s %s\n' "FILE" "PHASE" "HIDDEN" "ONLY/NOTSHOWIN" "EXEC"
    printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
    for src in /etc/xdg/autostart "${REAL_HOME}/.config/autostart" /usr/share/xdg/autostart; do
        [[ -d "$src" ]] || continue
        for f in "$src"/*.desktop; do
            [[ -f "$f" ]] || continue
            phase=$(grep -m1 '^X-GNOME-Autostart-Phase=' "$f" 2>/dev/null | cut -d= -f2-)
            phase="${phase:-Application}"
            hidden=$(grep -m1 '^Hidden=' "$f" 2>/dev/null | cut -d= -f2-)
            hidden="${hidden:-false}"
            only=$(grep -m1 '^OnlyShowIn=' "$f" 2>/dev/null | cut -d= -f2-)
            notshow=$(grep -m1 '^NotShowIn=' "$f" 2>/dev/null | cut -d= -f2-)
            scope="${only:+only=$only }${notshow:+not=$notshow}"
            scope="${scope:- - }"
            execv=$(grep -m1 '^Exec=' "$f" 2>/dev/null | cut -d= -f2-)
            printf '%-50s %-20s %-10s %-30s %s\n' "$(basename "$f")" "$phase" "$hidden" "$scope" "${execv:0:80}"
        done
    done | sort -k2,2
} > "$COLLECTION_DIR/08-display-desktop/autostart/SUMMARY-phase-table.txt" 2>/dev/null

# Highlight Phase=Initialization entries, these BLOCK xfce4-session startup.
{
    echo "=== Phase=Initialization autostart entries (BLOCKING xfce4-session) ==="
    echo "These run synchronously and xfce4-session waits for each to exit"
    echo "or hit its timeout before continuing to WindowManager phase."
    echo ""
    for src in /etc/xdg/autostart "${REAL_HOME}/.config/autostart" /usr/share/xdg/autostart; do
        [[ -d "$src" ]] || continue
        for f in "$src"/*.desktop; do
            [[ -f "$f" ]] || continue
            if grep -q '^X-GNOME-Autostart-Phase=Initialization' "$f" 2>/dev/null; then
                hidden=$(grep -m1 '^Hidden=' "$f" 2>/dev/null | cut -d= -f2-)
                if [[ "${hidden:-false}" != "true" ]]; then
                    echo "BLOCKING: $f"
                    grep -E '^(Name|Exec|TryExec|X-GNOME-Autostart-)' "$f" 2>/dev/null | sed 's/^/  /'
                    echo ""
                fi
            fi
        done
    done
} > "$COLLECTION_DIR/08-display-desktop/autostart/INITIALIZATION-PHASE-blocking.txt" 2>/dev/null

# pkcs11-register inspection (top suspect for login stalls, its
# Phase=Initialization + pcscd 60s idle timeout = ~60-90 s stall).
{
    echo "=== pkcs11-register binary + autostart status ==="
    if command -v pkcs11-register >/dev/null 2>&1; then
        timeout -k 3 15 pkcs11-register --version < /dev/null 2>&1 | head -3
        echo ""
        echo "Autostart file:"
        ls -la /etc/xdg/autostart/pkcs11-register.desktop 2>/dev/null || echo "  (not present in /etc/xdg/autostart)"
        if [[ -f /etc/xdg/autostart/pkcs11-register.desktop ]]; then
            echo ""
            echo "Hidden override status:"
            hidden=$(grep -m1 '^Hidden=' /etc/xdg/autostart/pkcs11-register.desktop 2>/dev/null | cut -d= -f2-)
            echo "  Hidden=${hidden:-false}"
        fi
        echo ""
        echo "User override:"
        ls -la "${REAL_HOME}/.config/autostart/pkcs11-register.desktop" 2>/dev/null || echo "  (no user override)"
    else
        echo "pkcs11-register binary NOT installed."
    fi
    echo ""
    echo "=== pcscd state (triggered by pkcs11-register) ==="
    systemctl status pcscd.service pcscd.socket 2>/dev/null | head -40 || true
    echo ""
    echo "=== opensc package state ==="
    dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 'opensc*' 'pcscd' 2>/dev/null || true
} > "$COLLECTION_DIR/08-display-desktop/autostart/pkcs11-register-triage.txt" 2>/dev/null

# Listing of /etc/X11/Xsession.d/, the Debian-style scripts that run in
# series on every graphical login. A slow one here = 100% login-stall culprit.
safe_exec "$COLLECTION_DIR/08-display-desktop/Xsession.d-listing.txt" \
    "ls -la /etc/X11/Xsession.d/ /etc/X11/Xsession 2>/dev/null"
if [[ -d /etc/X11/Xsession.d ]]; then
    mkdir -p "$COLLECTION_DIR/08-display-desktop/Xsession.d"
    cp -r /etc/X11/Xsession.d/* "$COLLECTION_DIR/08-display-desktop/Xsession.d/" 2>/dev/null || true
fi
# v1.5: capture the upstream xfce4-session entry-point chain. Without these
# we cannot tell whether a 134 s post-login stall is in the Xsession script,
# in startxfce4, in /etc/xdg/xfce4/xinitrc, or in xfce4-session itself.
mkdir -p "$COLLECTION_DIR/08-display-desktop/xfce4-startup-chain"
for src in \
    /etc/X11/Xsession \
    /etc/X11/Xsession.options \
    /usr/bin/startxfce4 \
    /usr/bin/xfce4-session \
    /etc/xdg/xfce4/xinitrc \
    /etc/xdg/xfce4-session/xfce4-session.rc \
    /etc/xdg/xfce4/defaults.list \
    /usr/share/xfce4-session/xinitrc.d ; do
    if [[ -e "$src" ]]; then
        dst="$COLLECTION_DIR/08-display-desktop/xfce4-startup-chain/$(basename "$src")"
        if [[ -d "$src" ]]; then
            cp -rL "$src" "$dst" 2>/dev/null || true
        else
            cp -L "$src" "$dst" 2>/dev/null || true
        fi
    fi
done
{
    echo "=== xfce4-session binary inspect ==="
    ls -la /usr/bin/xfce4-session /usr/bin/startxfce4 2>/dev/null
    echo ""
    # v1.8: NOT `xfce4-session --version`. With no session bus in the
    # environment xfce4-session re-executes itself under
    # `dbus-launch --exit-with-session`, and with no X session to exit, the
    # root dbus-daemon it started was left running after every collector run
    # (seen in ps-tree.txt of the NA-Central-Hub bundle). Read the package.
    dpkg-query -W -f='xfce4-session package version ${Version}\n' xfce4-session 2>/dev/null || echo "xfce4-session: not installed as a package"
    echo ""
    echo "=== /etc/xdg/xfce4/ tree ==="
    find /etc/xdg/xfce4 -maxdepth 3 -type f 2>/dev/null | head -20
} > "$COLLECTION_DIR/08-display-desktop/xfce4-startup-chain/INSPECT.txt" 2>/dev/null

# v1.5: dbus alias state, the bug discovered in the macOS-Ventura bundle
# was 12 dbus-org.freedesktop.resolve1.service "File exists" failures because
# the alias symlink survived `systemctl mask systemd-resolved`. Capture the
# full state of every dbus-* alias unit so this regression is detectable.
{
    echo "=== /etc/systemd/system/dbus-* alias links ==="
    ls -la /etc/systemd/system/dbus-* 2>/dev/null || echo "  (none in /etc/systemd/system)"
    echo ""
    echo "=== /usr/lib/systemd/system/dbus-* alias links ==="
    ls -la /usr/lib/systemd/system/dbus-* 2>/dev/null | head -30 || true
    echo ""
    echo "=== systemctl is-enabled state for key dbus aliases ==="
    for unit in dbus-org.freedesktop.resolve1.service dbus-org.freedesktop.timedate1.service dbus-org.freedesktop.hostname1.service dbus-org.freedesktop.locale1.service systemd-resolved.service; do
        state=$(systemctl is-enabled "$unit" 2>&1)
        active=$(systemctl is-active "$unit" 2>&1)
        printf '  %-50s enabled=%-15s active=%s\n' "$unit" "$state" "$active"
    done
    echo ""
    echo "=== deb-systemd-helper state (alias resurrection breadcrumbs) ==="
    ls -la /var/lib/systemd/deb-systemd-helper-enabled/ 2>/dev/null | head -30 || true
    echo ""
    if [[ -f /var/lib/systemd/deb-systemd-helper-enabled/systemd-resolved.service.dsh-also ]]; then
        echo "=== systemd-resolved.service.dsh-also (will replay these aliases on reinstall) ==="
        cat /var/lib/systemd/deb-systemd-helper-enabled/systemd-resolved.service.dsh-also 2>/dev/null
    fi
    echo ""
    echo "=== Recent dbus activation failures from journal ==="
    journalctl -b 2>/dev/null | grep -E "Activation via systemd failed|failed to load properly" | tail -30
} > "$COLLECTION_DIR/08-display-desktop/dbus-alias-state.txt" 2>/dev/null

# v1.5: list of all MASKED services (those that were /dev/null-symlinked).
# This is essential for verifying the install hook actually applied, when
# the macOS-Ventura bundle's mask was incomplete, the mask state was
# invisible without explicit listing.
{
    echo "=== Masked system units (/etc/systemd/system → /dev/null) ==="
    find /etc/systemd/system -maxdepth 2 -type l 2>/dev/null | while read -r f; do
        target=$(readlink "$f" 2>/dev/null)
        if [[ "$target" == "/dev/null" ]]; then
            printf '  MASKED   %s\n' "$f"
        fi
    done
    echo ""
    echo "=== Disabled-and-not-masked Kodachi-relevant services ==="
    for unit in systemd-resolved.service systemd-resolved.socket avahi-daemon.service \
                cups.service cups.socket cups-browsed.service ModemManager.service \
                bluetooth.service bluetooth.target wpa_supplicant.service; do
        state=$(systemctl is-enabled "$unit" 2>&1)
        active=$(systemctl is-active "$unit" 2>&1)
        printf '  %-40s enabled=%-15s active=%s\n' "$unit" "$state" "$active"
    done
} > "$COLLECTION_DIR/08-display-desktop/masked-services.txt" 2>/dev/null

# v1.5: install-method detection, Calamares vs debian-installer. Critical
# for triaging hook bugs because our 9999-zzz install hook runs in the
# chroot at ISO build time (always present in squashfs), but post-install
# regenerations can vary by installer flavour.
{
    echo "=== Install method detection ==="
    if [[ -f /var/log/Calamares.log ]]; then
        echo "Method: CALAMARES"
        echo "  /var/log/Calamares.log: $(stat -c '%y' /var/log/Calamares.log 2>/dev/null)"
        echo "  Last 30 lines:"
        tail -30 /var/log/Calamares.log 2>/dev/null | sed 's/^/    /'
    elif [[ -d /var/log/installer ]]; then
        echo "Method: DEBIAN-INSTALLER (d-i)"
        echo "  /var/log/installer/ contents:"
        ls -la /var/log/installer/ 2>/dev/null | sed 's/^/    /'
        if [[ -f /var/log/installer/syslog ]]; then
            echo ""
            echo "  /var/log/installer/syslog last 30 lines:"
            tail -30 /var/log/installer/syslog 2>/dev/null | sed 's/^/    /'
        fi
    else
        echo "Method: UNKNOWN (no Calamares.log, no /var/log/installer)"
    fi
    echo ""
    # v1.8: kodachi-finish-install never had a log of that name. The d-i
    # finish-install.d hooks write /var/log/kodachi-di-install.log and the
    # in-target verification writes /var/log/kodachi-di-verify.log, so the old
    # "(not present, kodachi-finish-install did not run)" line was printed on
    # a machine where it ran and FAILED.
    for _il in /var/log/kodachi-di-install.log /var/log/kodachi-di-verify.log; do
        echo "=== $_il ==="
        if [[ -f "$_il" ]]; then
            head -100 "$_il" 2>/dev/null
        else
            echo "  (not present)"
        fi
        echo ""
    done
    if [[ ! -f /var/log/kodachi-di-install.log ]] && [[ ! -f /var/log/Calamares.log ]]; then
        echo "  No Kodachi installer log at all: either a live session or kodachi-finish-install did not run."
        echo ""
    fi
    echo "=== Kodachi finish-install failures in the installer syslog ==="
    grep -hE 'kodachi[^ ]* returned error code|ERROR:' /var/log/installer/syslog 2>/dev/null | head -40 || true
    echo ""
    echo "=== /var/log/kodachi-grub-theme.log ==="
    if [[ -f /var/log/kodachi-grub-theme.log ]]; then
        head -50 /var/log/kodachi-grub-theme.log 2>/dev/null
    else
        echo "  (not present)"
    fi
} > "$COLLECTION_DIR/07-installation-packages/install-method.txt" 2>/dev/null

# /etc/profile.d/, also runs on login shell (incl. lightdm xsession). The
# Kodachi-specific kodachi-autoshield.sh and kodachi-path.sh live here.
if [[ -d /etc/profile.d ]]; then
    mkdir -p "$COLLECTION_DIR/08-display-desktop/profile.d"
    cp /etc/profile.d/*.sh "$COLLECTION_DIR/08-display-desktop/profile.d/" 2>/dev/null || true
fi

# User shell init files, if they have side-effects (network calls, slow
# command-not-found handlers, etc.) login feels slow even when systemd is fine.
for shf in .profile .bash_profile .bash_login .bashrc .zshrc .xprofile .xsessionrc .xinitrc; do
    if sudo -u "$REAL_USER" test -f "$REAL_HOME/$shf" 2>/dev/null; then
        safe_copy_user "$REAL_HOME/$shf" "$COLLECTION_DIR/08-display-desktop/user-session"
    fi
done

# ---- LIVE-PROCESS SNAPSHOT FOR THE USER SESSION --------------------------
# Captures the whole xfce4-session process subtree state at collection time.
# If a child is in 'D' (uninterruptible sleep) we see exactly which one.
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/process-tree-user.txt" \
    "ps -ef --forest -u ${REAL_USER}"
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/wchan-user.txt" \
    "ps -o pid,user,stat,wchan:30,cmd -u ${REAL_USER}"

# v1.5: deep inspection of xfce4-session if it's still running. The
# macOS-Ventura bundle proved that when xfce4-session stalls for 134 s
# during login, NONE of the existing data captures what it's blocked on.
# /proc/$pid/stack + status + io + a 5-second strace gives us syscalls
# visible at collection time, enough to prove "blocked on read() of
# Firefox cert9.db" or "blocked on connect() to dbus". 5 s is short
# enough not to disturb a healthy session and long enough to catch a
# blocked syscall.
XFCE_PIDS=$(pgrep -u "$REAL_USER" -x 'xfce4-session' 2>/dev/null || true)
if [[ -n "$XFCE_PIDS" ]]; then
    mkdir -p "$COLLECTION_DIR/08-display-desktop/user-session/xfce4-session-pid-inspect"
    for pid in $XFCE_PIDS; do
        ppath="$COLLECTION_DIR/08-display-desktop/user-session/xfce4-session-pid-inspect/pid-${pid}"
        mkdir -p "$ppath"
        # /proc snapshots, read once, no syscall trace
        # audit 2026-08-19, F22. `cmdline` and `environ` are NUL-SEPARATED, not
        # newline-separated, so a raw `cat` writes one enormous unbroken line.
        # Two consequences, and the second is the one that matters: the file is
        # unreadable, AND every redaction rule in this script is line-oriented
        # and space-anchored, so neither the write-time filter nor the final
        # sweep can see a `KEY=VALUE` pair or an argv flag inside it. The
        # shipped bundle carried the whole XFCE session environment verbatim
        # with zero redaction markers. Translating the separator first makes
        # both files readable and, more importantly, redactable.
        for f in status stat wchan stack syscall io comm cmdline environ limits; do
            if [[ -r "/proc/$pid/$f" ]]; then
                case "$f" in
                    cmdline) tr '\0' ' '  < "/proc/$pid/$f" 2>/dev/null | redact_bounded > "$ppath/$f.txt" || true ;;
                    environ) tr '\0' '\n' < "/proc/$pid/$f" 2>/dev/null | redact_bounded > "$ppath/$f.txt" || true ;;
                    *)       cat "/proc/$pid/$f" 2>/dev/null > "$ppath/$f.txt" || true ;;
                esac
            fi
        done
        # File descriptors, see what's open (sockets, files, pipes).
        ls -la "/proc/$pid/fd/" 2>/dev/null > "$ppath/fd-listing.txt" || true
        # Memory map, heavy but useful when a stuck mmap is suspected.
        ( cat "/proc/$pid/maps" 2>/dev/null | head -200 ) > "$ppath/maps-head200.txt" || true
        # Children, recurse one level.
        ls "/proc/$pid/task/" 2>/dev/null > "$ppath/threads.txt" || true
        # Short strace, only if strace is installed AND xfce4-session has been
        # alive for under 300 s (so we ONLY capture stalls during the post-login
        # window, never disturb a long-running healthy desktop).
        if command -v strace >/dev/null 2>&1; then
            # The session_age assignment that used to sit here computed
            # /proc/stat btime and was never read (shellcheck SC2034); the
            # age arithmetic below uses /proc/uptime and the process start
            # jiffies instead, which is what the 300 s window actually tests.
            start_jiffies=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
            hertz=$(getconf CLK_TCK 2>/dev/null || echo 100)
            uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
            if [[ -n "$start_jiffies" && -n "$uptime" ]]; then
                start_secs_after_boot=$((start_jiffies / hertz))
                age=$((uptime - start_secs_after_boot))
                echo "xfce4-session pid=$pid age=${age}s" > "$ppath/age.txt"
                if [[ "$age" -lt 300 ]]; then
                    echo "" >> "$ppath/age.txt"
                    echo "Age < 300s: capturing 5-second strace summary..." >> "$ppath/age.txt"
                    timeout 5 strace -f -c -p "$pid" 2>"$ppath/strace-summary.txt" || true
                    timeout 3 strace -f -p "$pid" -e trace=read,openat,connect,futex,poll 2>"$ppath/strace-blocking-syscalls.txt" || true
                fi
            fi
        fi
    done
fi
# Same deep-inspect for lightdm session-child (parent of Xsession), and
# any startxfce4 / ssh-agent processes still alive, these are the chain
# between PAM and xfce4-session.
for pname in lightdm startxfce4 ssh-agent; do
    pids=$(pgrep -u "$REAL_USER" -x "$pname" 2>/dev/null || true)
    [[ -z "$pids" ]] && continue
    for pid in $pids; do
        ppath="$COLLECTION_DIR/08-display-desktop/user-session/${pname}-pid-${pid}"
        mkdir -p "$ppath"
        # F22, same NUL-separator problem as the xfce4-session capture above.
        for f in status stat wchan stack syscall comm cmdline; do
            [[ -r "/proc/$pid/$f" ]] || continue
            if [[ "$f" == "cmdline" ]]; then
                tr '\0' ' ' < "/proc/$pid/$f" 2>/dev/null | redact_bounded > "$ppath/$f.txt" || true
            else
                cat "/proc/$pid/$f" 2>/dev/null > "$ppath/$f.txt" || true
            fi
        done
        ls -la "/proc/$pid/fd/" 2>/dev/null > "$ppath/fd-listing.txt" || true
    done
done

fi # end CATEGORY 8

# ============================================================================
# CATEGORY 9: Performance & Processes
# ============================================================================
if [[ "${CAT_ENABLED[9]}" == "1" ]]; then
progress "Collecting performance and process information..."

mkdir -p "$COLLECTION_DIR/09-performance-processes"

safe_exec "$COLLECTION_DIR/09-performance-processes/ps-tree.txt" "ps auxf | redact_secrets"
safe_exec "$COLLECTION_DIR/09-performance-processes/top-snapshot.txt" "top -bn1"
safe_exec "$COLLECTION_DIR/09-performance-processes/vmstat.txt" "vmstat 1 5"

if command -v iostat &> /dev/null; then
    safe_exec "$COLLECTION_DIR/09-performance-processes/iostat.txt" "iostat"
fi

# Pressure stall info
safe_exec "$COLLECTION_DIR/09-performance-processes/pressure-cpu.txt" "cat /proc/pressure/cpu"
safe_exec "$COLLECTION_DIR/09-performance-processes/pressure-memory.txt" "cat /proc/pressure/memory"
safe_exec "$COLLECTION_DIR/09-performance-processes/pressure-io.txt" "cat /proc/pressure/io"

# Top CPU and memory consumers (sorted)
safe_exec "$COLLECTION_DIR/09-performance-processes/top-cpu-consumers.txt" "ps aux --sort=-%cpu | head -25"
safe_exec "$COLLECTION_DIR/09-performance-processes/top-mem-consumers.txt" "ps aux --sort=-%mem | head -25"

# CPU frequency/throttling state
safe_exec "$COLLECTION_DIR/09-performance-processes/cpu-freq.txt" "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null && cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 'cpufreq not available'"

fi # end CATEGORY 9

# ============================================================================
# CATEGORY 10: Security & Permissions
# ============================================================================
if [[ "${CAT_ENABLED[10]}" == "1" ]]; then
progress "Collecting security and permissions information..."

mkdir -p "$COLLECTION_DIR/10-security-permissions"

safe_exec "$COLLECTION_DIR/10-security-permissions/id.txt" "id"
safe_exec "$COLLECTION_DIR/10-security-permissions/who.txt" "who"
safe_exec "$COLLECTION_DIR/10-security-permissions/w.txt" "w"
safe_exec "$COLLECTION_DIR/10-security-permissions/last.txt" "if command -v last >/dev/null 2>&1; then last -20; elif command -v wtmpdb >/dev/null 2>&1; then wtmpdb last 2>/dev/null | head -20; else echo 'last/wtmpdb unavailable (no wtmp login history on this system)'; fi"

# SELinux/AppArmor
safe_exec "$COLLECTION_DIR/10-security-permissions/getenforce.txt" "getenforce"
safe_exec "$COLLECTION_DIR/10-security-permissions/aa-status.txt" "aa-status"

# Kernel hardening sysctl values (critical for security scoring debug)
safe_exec "$COLLECTION_DIR/10-security-permissions/sysctl-kernel.txt" "sysctl -e kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled kernel.yama.ptrace_scope kernel.randomize_va_space kernel.kexec_load_disabled kernel.sysrq kernel.perf_event_paranoid net.core.bpf_jit_harden fs.protected_symlinks fs.protected_hardlinks net.ipv4.tcp_syncookies net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null"

# sysctl.d drop-in configs
if [[ -d "/etc/sysctl.d" ]]; then
    mkdir -p "$COLLECTION_DIR/10-security-permissions/sysctl.d"
    for sconf in /etc/sysctl.d/*.conf; do
        [[ -f "$sconf" ]] && cp "$sconf" "$COLLECTION_DIR/10-security-permissions/sysctl.d/" 2>/dev/null || true
    done
fi

# chkrootkit config and status
safe_copy "/etc/chkrootkit/chkrootkit.conf" "$COLLECTION_DIR/10-security-permissions"
safe_exec "$COLLECTION_DIR/10-security-permissions/chkrootkit-service.txt" "kdc_unit_status chkrootkit.service 2>/dev/null || echo 'chkrootkit service not found'"

# fail2ban status
if command -v fail2ban-client &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/fail2ban-status.txt" "fail2ban-client status 2>/dev/null || echo 'fail2ban not running'"
fi

# auditd rules and status
if command -v auditctl &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/auditd-rules.txt" "auditctl -l 2>/dev/null || echo 'auditd not running'"
    safe_exec "$COLLECTION_DIR/10-security-permissions/auditd-status.txt" "kdc_unit_status auditd 2>/dev/null"
fi

# usbguard status
if command -v usbguard &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/usbguard-rules.txt" "usbguard list-rules 2>/dev/null || echo 'usbguard not active'"
    safe_exec "$COLLECTION_DIR/10-security-permissions/usbguard-devices.txt" "usbguard list-devices 2>/dev/null || echo 'usbguard not active'"
fi

# NTP service status (for IPv6 bind error debugging)
safe_exec "$COLLECTION_DIR/10-security-permissions/ntpsec-status.txt" "kdc_unit_status ntpsec 2>/dev/null || kdc_unit_status ntp 2>/dev/null || echo 'no NTP service'"
safe_copy "/etc/ntpsec/ntp.conf" "$COLLECTION_DIR/10-security-permissions"

# Sudoers (list files only, don't copy contents, too sensitive)
safe_exec "$COLLECTION_DIR/10-security-permissions/sudoers-files.txt" "ls -la /etc/sudoers.d/ 2>/dev/null || echo 'no sudoers.d'"

# v1.9: WHAT THE FRAGMENTS ACTUALLY GRANT, not just that they exist.
#
# WHY, measured 2026-09-18 from a user debug bundle (Ubuntu-Studio, installed <lab-host>):
# /etc/sudoers.d/10-installer survived onto the installed system, 20 bytes, created at
# install time, while its sibling kodachi-calamares-wrapper was correctly removed by the
# post-install cleanup. Whether that is a leftover privilege grant or a legitimate rule
# for the account the installer created CANNOT BE ANSWERED from a directory listing, and
# the listing was all the bundle carried. The difference matters a lot: one is a cleanup
# gap, the other is the user's only route to sudo, and DELETING THE SECOND ONE BY MISTAKE
# locks them out of their own machine. So the bundle has to carry the content.
#
# SCOPED ON PURPOSE. Full content is transcribed only for fragments this product ships or
# that an installer is known to write; anything else (a rule the user or their organisation
# added) is reported by name, size, owner and mode, plus WHO it grants to, with the rule
# bodies left out. A support bundle should answer our questions about our own files without
# transcribing a third party's private policy.
safe_exec "$COLLECTION_DIR/10-security-permissions/sudoers-fragments.txt" "
  if [ ! -d /etc/sudoers.d ]; then echo 'no sudoers.d'; exit 0; fi
  echo '== fragments shipped by Kodachi or written by an installer: FULL CONTENT'
  for f in /etc/sudoers.d/*; do
    [ -f \"\$f\" ] || continue
    case \"\$(basename \"\$f\")\" in
      kodachi*|10-installer|99-*calamares*|*-calamares-*)
        echo \"--- \$f  (\$(stat -c '%s bytes, %U:%G, mode %a' \"\$f\" 2>/dev/null))\"
        cat \"\$f\" 2>/dev/null
        echo ;;
    esac
  done
  echo '== every OTHER fragment: metadata and grantee only, bodies deliberately omitted'
  for f in /etc/sudoers.d/*; do
    [ -f \"\$f\" ] || continue
    case \"\$(basename \"\$f\")\" in
      kodachi*|10-installer|99-*calamares*|*-calamares-*) continue ;;
    esac
    echo \"--- \$f  (\$(stat -c '%s bytes, %U:%G, mode %a' \"\$f\" 2>/dev/null))\"
    echo \"    grants to: \$(grep -oE '^[[:space:]]*[%+]?[A-Za-z0-9_.-]+[[:space:]]+ALL[[:space:]]*=' \"\$f\" 2>/dev/null | tr -d ' ' | sed 's/ALL=$//' | sort -u | tr '\n' ' ')\"
    echo \"    NOPASSWD rules: \$(grep -c 'NOPASSWD' \"\$f\" 2>/dev/null)\"
  done
  echo '== sudo would IGNORE these (a dot or a tilde in the name makes a fragment inert)'
  find /etc/sudoers.d -maxdepth 1 -type f \\( -name '*.*' -o -name '*~' \\) 2>/dev/null \
    | while IFS= read -r ig; do echo \"    inert: \$ig (\$(stat -c '%s bytes' \"\$ig\" 2>/dev/null))\"; done
  echo '== syntax check of the whole policy'
  visudo -c 2>&1 | tail -5
"

fi # end CATEGORY 10

# ============================================================================
# CATEGORY 11: Live System Information
# ============================================================================
if [[ "${CAT_ENABLED[11]}" == "1" ]]; then
progress "Collecting live system information..."

mkdir -p "$COLLECTION_DIR/11-live-system"

safe_exec "$COLLECTION_DIR/11-live-system/mount.txt" "mount"
safe_exec "$COLLECTION_DIR/11-live-system/proc-mounts.txt" "cat /proc/mounts"
safe_exec "$COLLECTION_DIR/11-live-system/findmnt.txt" "findmnt --real"
safe_copy "/etc/fstab" "$COLLECTION_DIR/11-live-system"

# Live system detection
if [[ -d "/run/live" ]]; then
    echo "Running from LIVE system" > "$COLLECTION_DIR/11-live-system/live-status.txt"
    ls -lah /run/live >> "$COLLECTION_DIR/11-live-system/live-status.txt"
    # Live-specific: squashfs info and overlay details
    safe_exec "$COLLECTION_DIR/11-live-system/squashfs-mounts.txt" "mount | grep -E 'squash|overlay|aufs'"
    if [[ -d "/run/live/medium" ]]; then
        safe_exec "$COLLECTION_DIR/11-live-system/live-medium-contents.txt" "ls -lah /run/live/medium/"
    fi
    if [[ -d "/run/live/persistence" ]]; then
        safe_exec "$COLLECTION_DIR/11-live-system/persistence-status.txt" "ls -lah /run/live/persistence/"
    fi
else
    echo "Running from INSTALLED system" > "$COLLECTION_DIR/11-live-system/live-status.txt"
fi

fi # end CATEGORY 11

# ============================================================================
# CATEGORY 12: Miscellaneous System Configuration
# ============================================================================
if [[ "${CAT_ENABLED[12]}" == "1" ]]; then
progress "Collecting miscellaneous system configuration..."

mkdir -p "$COLLECTION_DIR/12-misc-config"

safe_exec "$COLLECTION_DIR/12-misc-config/locale.txt" "locale"
safe_exec "$COLLECTION_DIR/12-misc-config/timedatectl.txt" "timedatectl"
safe_exec "$COLLECTION_DIR/12-misc-config/hostname.txt" "hostname"
safe_copy "/etc/default/grub" "$COLLECTION_DIR/12-misc-config"

# GRUB config (truncate if too large)
if [[ -f "/boot/grub/grub.cfg" ]]; then
    safe_copy "/boot/grub/grub.cfg" "$COLLECTION_DIR/12-misc-config"
fi

# GRUB drop-in configs
if [[ -d "/etc/default/grub.d" ]]; then
    mkdir -p "$COLLECTION_DIR/12-misc-config/grub.d"
    cp /etc/default/grub.d/*.cfg "$COLLECTION_DIR/12-misc-config/grub.d/" 2>/dev/null || true
fi

# systemd core configs
safe_copy "/etc/systemd/journald.conf" "$COLLECTION_DIR/12-misc-config"
safe_copy "/etc/systemd/system.conf" "$COLLECTION_DIR/12-misc-config"
if [[ -d "/etc/systemd/journald.conf.d" ]]; then
    mkdir -p "$COLLECTION_DIR/12-misc-config/journald.conf.d"
    cp /etc/systemd/journald.conf.d/*.conf "$COLLECTION_DIR/12-misc-config/journald.conf.d/" 2>/dev/null || true
fi

# Environment and defaults
safe_copy "/etc/environment" "$COLLECTION_DIR/12-misc-config"

# Kodachi-specific system configs
safe_copy "/etc/kodachi-version" "$COLLECTION_DIR/12-misc-config"
safe_copy "/etc/kodachi-release" "$COLLECTION_DIR/12-misc-config"

# v1.7: clock state. Tor refuses to bootstrap and every TLS check fails when
# the clock is off, and a live ISO boots with whatever the firmware says.
safe_exec "$COLLECTION_DIR/12-misc-config/time-sync.txt" \
    "date -u; echo; timedatectl timesync-status 2>&1 | head -20; echo; chronyc tracking 2>&1 | head -15; echo; ntpq -p 2>&1 | head -15; echo; hwclock --show 2>&1"

fi # end CATEGORY 12

# ============================================================================
# CATEGORY 13: Collection Metadata (always runs)
# ============================================================================
progress "Generating collection metadata..."

mkdir -p "$COLLECTION_DIR/00-metadata"

# v1.7: the run record and the timing files are written TWICE. Once before the
# triage index, because TRIAGE.txt reads command-timing-slowest.txt and that
# section was empty when these files were produced after it (inspector), and
# once after the final redaction sweep, so the triage and sweep phases are
# themselves timed. The second write passes through the (bounded) redactor,
# because the sweep has already run by then.
write_timing_files() {
    local redactor="${1:-cat}"
# v1.7: how THIS run happened, and how long each part took. The exact script
# (path + md5, or "stdin" for the curl form), the arguments, per-step and
# per-command timings sorted slowest-first. When a user says "it hung" or
# "it took forever", this is the file to open.
{
    echo "Kodachi debug collector run record"
    echo "=================================="
    echo "Collector version:   ${COLLECTOR_VERSION}"
    echo "Script source:       ${SCRIPT_SOURCE}"
    echo "Invocation:          ${INVOKED_AS} ${INVOKED_ARGS}"
    echo "Bash:                ${BASH_VERSION}"
    echo "Ran as uid:          $(id -u) (real user ${REAL_USER}, uid ${REAL_UID:-unknown})"
    echo "Started (UTC):       ${RUN_STARTED}"
    echo "Collection done:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Elapsed so far:      $(( $(date +%s) - RUN_T0 ))s"
    echo "Per-command timeout: ${KDC_CMD_TIMEOUT:-180}s (override with KDC_CMD_TIMEOUT=<seconds>)"
    echo ""
    echo "Step timing (seconds, step number, label):"
    cat "$STEP_TIMING_LOG" 2>/dev/null
    printf '%5ds  step %2s  %s\n' "$(( $(date +%s) - STEP_T0 ))" "$STEP" "${STEP_LABEL:-}"
} 2>&1 | "$redactor" > "$COLLECTION_DIR/00-metadata/collector-run.txt"
"$redactor" < "$CMD_TIMING_LOG" > "$COLLECTION_DIR/00-metadata/command-timing.txt" 2>/dev/null || true
{
    echo "Slowest 40 collected commands (seconds, exit code, command):"
    sort -rn "$CMD_TIMING_LOG" 2>/dev/null | head -40
    echo ""
    echo "Commands that timed out (rc=124) or were killed (rc=137):"
    grep -E 'rc=(124|137) ' "$CMD_TIMING_LOG" 2>/dev/null || echo "  none"
} 2>&1 | "$redactor" > "$COLLECTION_DIR/00-metadata/command-timing-slowest.txt"
}

# First write: TRIAGE.txt reads command-timing-slowest.txt below, so it has to
# exist by then. These bytes are produced before the final sweep, so they need
# no redactor here; the second write, after the sweep, passes one in.
write_timing_files

# v1.7: the run record and the timing files are written AFTER the triage index
# and the final redaction sweep (see below), so those two phases are timed too.

# Record which categories were collected
{
    echo "Kodachi Debug Collection Metadata"
    echo "=================================="
    echo "Collection Date: $(date)"
    echo "Hostname: $HOSTNAME"
    echo "Real User: $REAL_USER"
    echo "Real Home: $REAL_HOME"
    echo "Collection Directory: $COLLECTION_DIR"
    echo ""
    echo "Categories Collected:"
    echo "---------------------"
    for i in "${!CAT_LABEL[@]}"; do
        if [[ "${CAT_ENABLED[$i]}" == "1" ]]; then
            echo "  [X] $((i+1)). ${CAT_LABEL[$i]}"
        else
            echo "  [ ] $((i+1)). ${CAT_LABEL[$i]} (skipped)"
        fi
    done
    echo ""
    echo "System Information:"
    echo "-------------------"
    uname -a
    echo ""
    echo "Disk Space Available:"
    echo "---------------------"
    df -h "$DESKTOP_DIR"
    echo ""
} > "$COLLECTION_DIR/00-metadata/collection-info.txt" 2>&1


# Final privacy sweep: some collection paths intentionally copy whole config
# trees or generated summaries. Run every text-like file through the same
# redactor immediately before archiving so no raw IP/MAC/secret can bypass
# individual safe_copy/safe_exec call sites.
final_redaction_sweep() {
    local file tmp sz swept=0 skipped=0 nontext=0 empty=0 total=0 sweep_rc=0
    declare -A ALREADY=()
    if [[ -f "$REDACTED_MANIFEST" ]]; then
        while IFS=$'\t' read -r sz file; do
            [[ -n "$file" ]] && ALREADY["$file"]="$sz"
        done < "$REDACTED_MANIFEST"
    fi

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue

        # CLASSIFY BY FILE PROPERTY FIRST, BEFORE THE MANIFEST SHORT-CIRCUIT.
        # `grep -Iq .` is false for a BINARY file and equally false for an
        # EMPTY one, so both classes fall past the sweep and would otherwise
        # vanish from the arithmetic entirely. A report that says "every file"
        # while its own gate skipped hundreds is an overstated claim, and this
        # script exists to be trusted about exactly that.
        #
        # THE ORDERING MATTERS AND I GOT IT WRONG ONCE. With the manifest
        # `continue` placed above this block, these two counters only saw files
        # that were NOT in the manifest, so a real bundle reported "not text: 1"
        # and then NAMED 255 non-text files in the next paragraph. Independently
        # re-derived over that bundle: 25 empty, 260 non-text, 861 text.
        # Classifying first makes the four populations mutually exclusive and
        # exhaustive, so the printed total can be checked against a plain
        # `find "$COLLECTION_DIR" -type f | wc -l`. There is no behavioural
        # change: a binary or empty file is never swept under either ordering.
        # Measured 2026-08-19.
        if [[ ! -s "$file" ]]; then
            empty=$((empty + 1))
            continue
        fi
        if ! LC_ALL=C grep -Iq . "$file" 2>/dev/null; then
            nontext=$((nontext + 1))
            continue
        fi

        # Text and non-empty from here down.
        #
        # Redacted at write time AND untouched since: a second pass over it
        # cannot change a byte, and these are the largest files in the bundle.
        # Fail-closed: if the size moved, something was appended raw
        # afterwards, and the file is swept normally.
        if [[ -n "${ALREADY[$file]:-}" ]]; then
            sz=$(stat -c%s "$file" 2>/dev/null || echo -1)
            if [[ "$sz" == "${ALREADY[$file]}" ]]; then
                skipped=$((skipped + 1))
                continue
            fi
        fi

        tmp="${file}.redact.$$"
        # ONE rc policy, applied to every status: whatever came out of the
        # redactor replaces the raw file. On success that is the redacted
        # file; on a timeout it is the partial output plus its marker; on a
        # genuine failure it is whatever was redacted plus the FAILED marker
        # the function appends. Leaving the raw file in place on an error was
        # the one outcome that could ship unredacted bytes (inspector).
        redact_bounded < "$file" > "$tmp" 2>/dev/null
        sweep_rc=$?
        if [[ -s "$tmp" ]]; then
            cat "$tmp" > "$file" 2>/dev/null || true
        else
            # Nothing came back at all: refuse to ship the original.
            printf '[REDACTION PRODUCED NO OUTPUT (status %s): this file was withheld]\n' "$sweep_rc" > "$file" 2>/dev/null || true
        fi
        rm -f "$tmp" 2>/dev/null || true
        swept=$((swept + 1))
    done < <(find "$COLLECTION_DIR" -type f -print0 2>/dev/null)

    total=$((skipped + swept + nontext + empty))
    {
        echo "Final redaction sweep"
        echo "  text, redacted at write time and unchanged:     $skipped"
        echo "  text, swept by the final pass:                  $swept"
        echo "  empty, nothing to redact:                       $empty"
        echo "  not text, never passed through the redactor:    $nontext"
        echo "  ------------------------------------------------------"
        echo "  files examined:                                 $total"
        echo ""
        echo "Hostnames redacted (v1.8). Names are not printed, only token, length and mode."
        echo "  mode word: replaced anywhere in text (the name has a digit, hyphen or dot)"
        echo "  mode hostname-context: replaced only where the text marks it as a hostname"
        echo "  (letters-only and 3-character names, which are also ordinary words)"
        if [[ -n "${KDC_REDACT_HOSTNAMES:-}" ]]; then
            for _he in $KDC_REDACT_HOSTNAMES; do
                _htok="${_he%%:*}"; _hrest="${_he#*:}"; _hmode="${_hrest%%:*}"; _hname="${_hrest#*:}"
                printf '    HOSTNAME-%-8s %3s chars  %s\n' "$_htok" "${#_hname}" \
                    "$([[ "$_hmode" == "W" ]] && echo word || echo hostname-context)"
            done
        else
            echo "    (no hostname candidates found)"
        fi
        echo ""
        echo "Account names redacted (v1.8, human accounts uid 1000-59999). Names are not printed."
        echo "  mode word: replaced anywhere in text"
        echo "  mode user-context: 4 characters or shorter, or an ordinary word, replaced only in"
        echo "  account contexts (/home/<name>, USER=, uid=N(<name>), for user <name>, Real User:, ...)"
        if [[ -n "${KDC_REDACT_USERS:-}" ]]; then
            for _ue in $KDC_REDACT_USERS; do
                _utok="${_ue%%:*}"; _urest="${_ue#*:}"; _umode="${_urest%%:*}"; _uname="${_urest#*:}"
                printf '    USER-%-8s %3s chars  %s\n' "$_utok" "${#_uname}" \
                    "$([[ "$_umode" == "W" ]] && echo word || echo user-context)"
            done
        else
            echo "    (no human account names found)"
        fi
        echo ""
        echo "Full names redacted (v1.8, GECOS of human accounts). Names are not printed."
        if [[ -n "${KDC_REDACT_FULLNAMES:-}" ]]; then
            for _fe in $KDC_REDACT_FULLNAMES; do
                _ftok="${_fe%%:*}"; _frest="${_fe#*:}"; _fmode="${_frest%%:*}"; _fname="${_frest#*:}"
                _fname="${_fname//%20/ }"; _fname="${_fname//%3A/:}"; _fname="${_fname//%25/%}"
                printf '    FULLNAME-%-8s %3s chars  %s\n' "$_ftok" "${#_fname}" \
                    "$([[ "$_fmode" == "W" ]] && echo word || echo fullname-context)"
            done
        else
            echo "    (no full names found)"
        fi
        echo "  Also always redacted: installer 'Install fullname:' and 'Install username:' lines,"
        echo "  the GECOS field of human passwd records, and the values of debconf records"
        echo "  passwd/user-fullname, passwd/username, netcfg hostname and domain, and the"
        echo "  time zone, country, locale, language, mirror country and keyboard layout records."
        echo "  Time zone regions become [REDACTED-TIMEZONE] and locales [REDACTED-LOCALE];"
        echo "  UTC offsets and character sets are kept."
        echo ""
        echo "Name-list sources that timed out (names from them may be missing):"
        if [[ -s "${KDC_LIST_TIMEOUTS:-}" ]]; then
            sed 's/^/    /' "$KDC_LIST_TIMEOUTS"
        else
            echo "    none"
        fi
        echo ""
        echo "EVERY TEXT FILE in this bundle passed through redact_secrets at"
        echo "least once. A skipped file is one whose size is byte-identical to"
        echo "the size recorded immediately after it was redacted."
        echo ""
        echo "The non-text files above were NOT redacted, because the redactor"
        echo "is line-based and would corrupt them. They are signature blobs,"
        echo "PNG flag icons, lock files and the like. If you are reviewing this"
        echo "bundle before sharing it, they are the files no automatic pass has"
        echo "read:"
        if (( nontext )); then
            while IFS= read -r -d '' file; do
                [[ -s "$file" ]] || continue
                LC_ALL=C grep -Iq . "$file" 2>/dev/null && continue
                echo "    ${file#"$COLLECTION_DIR"/}"
            done < <(find "$COLLECTION_DIR" -type f -print0 2>/dev/null) | sort
        fi
    } > "$COLLECTION_DIR/00-metadata/redaction-sweep.txt" 2>/dev/null || true
}

# v1.7: a triage index, generated from the bundle itself, so whoever opens the
# zip reads ONE file first: what the system is, what failed, which collected
# probes errored, where the errors cluster, and the verdicts the binaries gave.
# Everything in it is derived from files already in the bundle (so it says
# nothing the bundle does not), and it is written BEFORE the final redaction
# sweep, so it passes through the redactor like everything else.
_ph0=$(date +%s.%N)
{
    echo "KODACHI DEBUG BUNDLE, TRIAGE INDEX (generated by the collector, read this first)"
    echo "=============================================================================="
    echo ""
    echo "== System (00-kodachi-meta/meta-vars.txt)"
    cat "$COLLECTION_DIR/00-kodachi-meta/meta-vars.txt" 2>/dev/null | sed 's/^/  /' || echo "  (meta category not collected)"
    echo ""
    echo "== Failed systemd units (01-system-boot/systemctl-failed.txt)"
    sed 's/^/  /' "$COLLECTION_DIR/01-system-boot/systemctl-failed.txt" 2>/dev/null | head -40 || echo "  (not collected)"
    echo ""
    echo "== Kodachi binaries missing from PATH (06-kodachi/binary-status.txt)"
    grep -F '✗' "$COLLECTION_DIR/06-kodachi/binary-status.txt" 2>/dev/null | sed 's/^/  /' || echo "  none missing"
    echo ""
    echo "== Signature verdict (06-kodachi/integrity-check-signatures.txt)"
    grep -oE '"(success|failed_count|missing_count|verified_count|total[a-z_]*)":[^,}]*' "$COLLECTION_DIR/06-kodachi/integrity-check-signatures.txt" 2>/dev/null | sed 's/^/  /' || echo "  (not collected)"
    echo ""
    echo "== Missing dependencies (06-kodachi/deps-checker-check-all.txt)"
    grep -oE '"(satisfied|with_missing|with_warnings|total_binaries)":[^,}]*' "$COLLECTION_DIR/06-kodachi/deps-checker-check-all.txt" 2>/dev/null | sed 's/^/  /'
    tr -d '\n ' < "$COLLECTION_DIR/06-kodachi/deps-checker-check-all.txt" 2>/dev/null | grep -oE '"all_missing_packages":\[[^]]*\]' | sed 's/^/  /' || echo "  (not collected, or no missing-package list)"
    echo ""
    echo "== Collected probes that failed, timed out, or printed nothing (count, message)"
    grep -rhoE '^\[(EXIT CODE: [1-9][0-9]*|TIMEOUT)[^]]*\] [^:]*: .{0,110}' "$COLLECTION_DIR" --include='*.txt' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -60 | sed 's/^/  /'
    echo ""
    # v1.8: unit results. systemctl status exit 3 is no longer a failed probe,
    # so the state that DOES matter is surfaced from the show properties.
    echo "== Kodachi units not in a clean state (06-kodachi/units/*-show.txt: Result, ConditionResult, ActiveState)"
    _ur=0
    for sf in "$COLLECTION_DIR"/06-kodachi/units/*-show.txt; do
        [[ -f "$sf" ]] || continue
        _res=$(grep -m1 '^Result=' "$sf" 2>/dev/null | cut -d= -f2)
        _cond=$(grep -m1 '^ConditionResult=' "$sf" 2>/dev/null | cut -d= -f2)
        _act=$(grep -m1 '^ActiveState=' "$sf" 2>/dev/null | cut -d= -f2)
        _ufs=$(grep -m1 '^UnitFileState=' "$sf" 2>/dev/null | cut -d= -f2)
        # ConditionResult reads "no" for a unit whose conditions were never
        # evaluated (installed, never started this boot), so it only counts
        # when ConditionTimestamp says the check actually ran.
        _ctime=$(grep -m1 '^ConditionTimestamp=' "$sf" 2>/dev/null | cut -d= -f2-)
        if { [[ -n "$_res" ]] && [[ "$_res" != "success" ]]; } || [[ "$_act" == "failed" ]] || { [[ "$_cond" == "no" ]] && [[ -n "$_ctime" ]]; }; then
            printf '  %-48s Result=%-10s ConditionResult=%-4s ActiveState=%-9s UnitFileState=%s\n' \
                "$(basename "$sf" -show.txt)" "${_res:-?}" "${_cond:-?}" "${_act:-?}" "${_ufs:-?}"
            _ur=$((_ur + 1))
        fi
    done
    [[ $_ur -eq 0 ]] && echo "  none (every collected kodachi* unit: Result=success, no evaluated condition failed, not failed)"
    echo ""
    # v1.8: cheap cross-checks that each exposed a real defect in a bundle.
    echo "== Consistency checks"
    _lsblk="$COLLECTION_DIR/02-hardware-drivers/lsblk.txt"
    _mem="$COLLECTION_DIR/02-hardware-drivers/meminfo.txt"
    if [[ -f "$_lsblk" ]] && [[ -f "$_mem" ]]; then
        _swapdev=$(awk '$2 == "swap" { n++ } END { print n+0 }' "$_lsblk" 2>/dev/null)
        _swaptot=$(awk '/^SwapTotal:/ { print $2 }' "$_mem" 2>/dev/null)
        if [[ "${_swapdev:-0}" -gt 0 ]] && [[ "${_swaptot:-0}" == "0" ]]; then
            echo "  SWAP: $_swapdev swap-formatted device(s) in lsblk but SwapTotal is 0 kB: swap exists and is not activated"
        else
            echo "  swap: ok (swap devices $_swapdev, SwapTotal ${_swaptot:-?} kB)"
        fi
    else
        echo "  swap: (lsblk or meminfo not collected)"
    fi
    _hold="$COLLECTION_DIR/07-installation-packages/apt-channels/apt-mark-showhold.txt"
    if [[ -f "$_hold" ]]; then
        _held=$(grep -v '^\[' "$_hold" 2>/dev/null | grep -c .)
        if [[ "${_held:-0}" -gt 0 ]]; then
            echo "  HELD PACKAGES ($_held): $(grep -v '^\[' "$_hold" | tr '\n' ' ' | cut -c1-200)"
        else
            echo "  held packages: none"
        fi
    else
        echo "  held packages: (not collected)"
    fi
    _kp="$COLLECTION_DIR/07-installation-packages/apt-channels/kodachi-packages.txt"
    if [[ -f "$_kp" ]]; then
        _meta=$(awk -F'\t' '$1 == "kodachi" && $3 == "install ok installed" { print "yes" }' "$_kp" 2>/dev/null)
        _others=$(awk -F'\t' '$1 ~ /^kodachi-/ && $3 == "install ok installed" { n++ } END { print n+0 }' "$_kp" 2>/dev/null)
        if [[ -z "$_meta" ]] && [[ "${_others:-0}" -gt 0 ]]; then
            echo "  KODACHI META PACKAGE: 'kodachi' is not installed while $_others kodachi-* package(s) are"
        else
            echo "  kodachi meta package: ${_meta:-not installed} (kodachi-* installed: ${_others:-0})"
        fi
    else
        echo "  kodachi meta package: (not collected)"
    fi
    _dss="$COLLECTION_DIR/06-kodachi/dns-switch-status.txt"
    if [[ -f "$_dss" ]]; then
        _dsrc=$(grep -m1 -oE '^\[EXIT CODE: [0-9]+\]' "$_dss" 2>/dev/null)
        echo "  dns-switch status: ${_dsrc:-exit 0}"
    fi
    echo ""
    echo "== Installer failures (07-installation-packages: d-i syslog and Kodachi installer logs)"
    grep -hE 'kodachi[^ ]* returned error code|ERROR:' \
        "$COLLECTION_DIR/07-installation-packages/debian-installer/syslog" \
        "$COLLECTION_DIR"/07-installation-packages/kodachi-logs/kodachi-di-install.log \
        "$COLLECTION_DIR"/07-installation-packages/kodachi-logs/kodachi-di-verify.log 2>/dev/null \
        | head -30 | cut -c1-220 | sed 's/^/  /'
    echo ""
    echo "== Error density per collected text file, top 40 (count of error|fail|panic|denied|warn lines)"
    find "$COLLECTION_DIR" -type f \( -name '*.txt' -o -name '*.log' -o -name '*.log.*' -o -name '*.json' \) -size +0 2>/dev/null | while read -r tf; do
        # grep -c prints "0" AND exits 1 on no match, so `|| echo 0` produced
        # "0\n0" and a swallowed syntax error on every clean file.
        c=$(LC_ALL=C grep -ciE 'error|fail|panic|denied|warn|traceback|segfault|oom-kill' "$tf" 2>/dev/null)
        c="${c%%[!0-9]*}"; [[ -n "$c" ]] || c=0
        [[ "$c" -gt 0 ]] && printf '%7d  %s\n' "$c" "${tf#"$COLLECTION_DIR"/}"
    done | sort -rn | head -40 | sed 's/^/  /'
    echo ""
    echo "== Last error/warning lines from each Kodachi hook log (06-kodachi/hooks-logs, 5 per file)"
    for hl in "$COLLECTION_DIR"/06-kodachi/hooks-logs/*.log; do
        [[ -f "$hl" ]] || continue
        m=$(LC_ALL=C grep -iE 'error|warn|panic|fail' "$hl" 2>/dev/null | tail -5)
        [[ -n "$m" ]] || continue
        echo "  -- $(basename "$hl")"
        printf '%s\n' "$m" | cut -c1-220 | sed 's/^/     /'
    done
    echo ""
    echo "== Kernel and journal errors this boot (first 40 lines of each)"
    echo "  -- 01-system-boot/journalctl-errors.txt"; head -40 "$COLLECTION_DIR/01-system-boot/journalctl-errors.txt" 2>/dev/null | cut -c1-220 | sed 's/^/     /'
    echo "  -- 02-hardware-drivers/dmesg-errors.txt"; head -40 "$COLLECTION_DIR/02-hardware-drivers/dmesg-errors.txt" 2>/dev/null | cut -c1-220 | sed 's/^/     /'
    echo ""
    echo "== Slowest collected commands (00-metadata/command-timing-slowest.txt)"
    head -12 "$COLLECTION_DIR/00-metadata/command-timing-slowest.txt" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "Where to look next:"
    echo "  00-metadata/collector-run.txt         how this run was invoked and how long each step took"
    echo "  00-kodachi-meta/kodachi-meta-summary  version, live/installed, LUKS, nuke, Tor/VPN/DNS one-liners"
    echo "  06-kodachi/binary-inventory.txt       every hook binary: version, md5, mtime, signatures present"
    echo "  06-kodachi/hooks-logs/                the Kodachi binaries' own logs (dashboard log included)"
    echo "  06-kodachi/hooks-results/             the last JSON result every binary wrote"
    echo "  06-kodachi/units/                     status, cat and journal of every kodachi* systemd unit"
    echo "  07-installation-packages/apt-channels which apt channel, which kodachi-* versions"
    echo "  08-display-desktop/user-session/      ~/.xsession-errors, user journal, autostart phases"
} > "$COLLECTION_DIR/00-metadata/TRIAGE.txt" 2>/dev/null || true
printf '%8.2fs rc=0   [phase] triage-index\n' "$(awk -v a="$_ph0" -v b="$(date +%s.%N)" 'BEGIN{print b-a}')" >> "$CMD_TIMING_LOG" 2>/dev/null

_ph0=$(date +%s.%N)
final_redaction_sweep
printf '%8.2fs rc=0   [phase] final-redaction-sweep (%s files examined)\n' "$(awk -v a="$_ph0" -v b="$(date +%s.%N)" 'BEGIN{print b-a}')" "$(find "$COLLECTION_DIR" -type f 2>/dev/null | wc -l)" >> "$CMD_TIMING_LOG" 2>/dev/null

# Refreshed here so the two phases below the first write (the triage index and
# the final redaction sweep) are covered as well.
write_timing_files redact_bounded

# Collection tree
# v1.8: written after the final sweep, so it goes through the redactor itself.
if command -v tree >/dev/null 2>&1; then
    tree "$COLLECTION_DIR" 2>/dev/null | redact_bounded > "$COLLECTION_DIR/00-metadata/directory-tree.txt" 2>/dev/null
else
    find "$COLLECTION_DIR" -type f 2>/dev/null | redact_bounded > "$COLLECTION_DIR/00-metadata/file-list.txt"
fi

# ============================================================================
# CATEGORY 14: Create ZIP Archive (always runs)
# ============================================================================
progress "Creating compressed archive..."

cd "$TEMP_DIR" || exit 1
_zip0=$(date +%s)
if zip -r "$ZIP_FILE" "$COLLECTION_NAME" > /dev/null 2>&1; then
    ZIP_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
    echo -e "${GREEN}✓ Archive created successfully${NC} (zip $(( $(date +%s) - _zip0 ))s, whole run $(( $(date +%s) - RUN_T0 ))s)"
else
    echo -e "${RED}✗ Failed to create archive${NC}"
    exit 1
fi

# ============================================================================
# CATEGORY 15: Cleanup & Summary (always runs)
# ============================================================================
progress "Cleaning up temporary files..."

rm -rf "$TEMP_DIR"

# Change ownership to real user (primary group looked up, not assumed
# equal to the username).
REAL_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
chown "$REAL_USER:$REAL_GROUP" "$ZIP_FILE" 2>/dev/null || chown "$REAL_USER" "$ZIP_FILE" 2>/dev/null || true

# Summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              COLLECTION COMPLETED SUCCESSFULLY            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Print the quick meta summary on screen too
if [[ -f "$ZIP_FILE" ]]; then
    echo -e "${YELLOW}--- Quick System Info ---${NC}"
    # We already cleaned up COLLECTION_DIR, so re-read from the zip isn't practical.
    # Instead, re-detect the key values quickly:
    # /etc/kodachi-version is a multi-line ASCII BANNER, so cat-ing it here
    # printed the whole banner inside a one-line summary box. The metadata
    # section at the top of this script already parses the scalar correctly
    # (grep -oP 'Version:'); this copy did not, and the two disagreed.
    _ver="unknown"
    for _vf in /etc/kodachi-version /etc/kodachi_version; do
        [[ -f "$_vf" ]] || continue
        _vl=$(grep -oP '^\s*Version:\s*\K[0-9][0-9A-Za-z.+-]*' "$_vf" 2>/dev/null | head -1)
        if [[ -z "$_vl" ]]; then
            _vl=$(grep -oE '[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' "$_vf" 2>/dev/null | head -1)
        fi
        [[ -n "$_vl" ]] && _ver="$_vl"
    done
    if [[ "$_ver" == "unknown" ]]; then
        for _bm in /opt/*/dashboard/hooks/config/build-meta.json; do
            if [[ -f "$_bm" ]]; then
                _bv=$(grep -oP '"version"\s*:\s*"\K[^"]+' "$_bm" 2>/dev/null | head -1)
                if [[ -n "$_bv" ]]; then _ver="$_bv"; break; fi
            fi
        done
    fi
    if [[ "$_ver" == "unknown" ]]; then
        _ov=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
        if [[ -n "$_ov" ]]; then _ver="$_ov"; fi
    fi
    if [[ -d "/run/live" ]] || grep -q "boot=live" /proc/cmdline 2>/dev/null; then
        _type="LIVE"
    else
        _type="INSTALLED"
    fi
    _luks="NO"
    if lsblk -f 2>/dev/null | grep -qi "crypto_LUKS"; then _luks="YES"; fi
    _nuke="NOT DETECTED"
    if dpkg-query -W -f='${Status}' cryptsetup-nuke-password 2>/dev/null | grep -q '^install ok installed$'; then _nuke="PACKAGE INSTALLED"; fi
    echo -e "  Version:     ${BLUE}${_ver}${NC}"
    echo -e "  System:      ${BLUE}${_type}${NC}"
    echo -e "  LUKS:        ${BLUE}${_luks}${NC}"
    echo -e "  Nuke:        ${BLUE}${_nuke}${NC}"
    # tor@default.service is the real daemon; tor.service is the /bin/true master.
    echo -e "  Tor:         ${BLUE}$(systemctl is-active tor@default.service 2>/dev/null || echo 'unknown')${NC}"
    echo ""
fi

echo -e "${YELLOW}Archive Location:${NC} $ZIP_FILE"
echo -e "${YELLOW}Archive Size:${NC} $ZIP_SIZE"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. The debug archive has been saved to your Desktop"
echo "  2. Upload the file to your preferred file sharing service"
echo "  3. Share the download link with Kodachi support team"
echo "  4. Include a brief description of the issue you're experiencing"
echo ""
echo -e "${YELLOW}Note:${NC} This archive contains system logs and configuration."
echo "       Review the contents if you have privacy concerns before sharing."
echo ""
echo -e "${GREEN}Thank you for helping improve Kodachi OS!${NC}"
echo ""

} # end main

# Invoked LAST, so that when this script arrives on stdin (curl | sudo bash -s)
# bash has read every byte of it before the first collected command runs.
main "$@"
