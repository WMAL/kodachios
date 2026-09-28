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
# Version: 9.0.1
# Last updated: 2026-04-16
#
# Description:
# Collects comprehensive system diagnostics for remote troubleshooting
# of Kodachi OS installations. Gathers boot logs, hardware info, network
# configuration, Kodachi service status, LUKS/nuke state, and more.
# All data is packaged into a zip file on the user's Desktop.
#
# Privacy:
# This script does NOT collect any personal data, browsing history,
# IP addresses, MAC addresses, WiFi passwords, home folder contents,
# or any data that could compromise user privacy. Only system/service
# diagnostics are collected. Network identifiers and WiFi credentials
# are automatically redacted before packaging.
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
#   ~/Desktop/kodachi-debug-HOSTNAME-YYYYMMDD-HHMMSS.zip
#
# ======================================================

set -Eo pipefail

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
trap cleanup_temp_dir EXIT
trap 'cleanup_temp_dir; exit 130' INT
trap 'cleanup_temp_dir; exit 143' TERM

COLLECTION_NAME="kodachi-debug-${HOSTNAME}-${TIMESTAMP}"
COLLECTION_DIR="${TEMP_DIR}/${COLLECTION_NAME}"
ZIP_FILE="${DESKTOP_DIR}/${COLLECTION_NAME}.zip"

mkdir -p "$COLLECTION_DIR"

# Progress indicator
progress() {
    STEP=$((STEP + 1))
    echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}]${NC} $1"
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
    eval "$cmd" > "$spool" 2>&1
    rc=$?

    local redacted_cmd
    redacted_cmd=$(printf '%s\n' "$cmd" | redact_secrets)

    if [[ $rc -ne 0 ]]; then
        echo "[EXIT CODE: $rc] Command failed: $redacted_cmd" >> "$output_file"
        [[ -s "$spool" ]] && redact_secrets < "$spool" >> "$output_file"
    elif [[ ! -s "$spool" ]]; then
        echo "[EXIT CODE: 0] Command produced no output: $redacted_cmd" >> "$output_file"
    else
        redact_secrets < "$spool" >> "$output_file"
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

    if [[ $file_size -gt $max_size ]]; then
        # Truncate large files, then redact private identifiers/secrets.
        local _pt=0; [[ -f "${dest}/$(basename "$src").truncated" ]] && _pt=$(stat -c%s "${dest}/$(basename "$src").truncated" 2>/dev/null || echo 0)
        tail -c 50M "$src" 2>/dev/null | redact_secrets > "${dest}/$(basename "$src").truncated" 2>/dev/null || true
        echo "Original file size: $file_size bytes (truncated to last 50MB, redacted)" >> "${dest}/$(basename "$src").truncated"
        should_mark "${dest}/$(basename "$src").truncated" "$_pt" && mark_redacted "${dest}/$(basename "$src").truncated"
    else
        local _pc=0; [[ -f "${dest}/$(basename "$src")" ]] && _pc=$(stat -c%s "${dest}/$(basename "$src")" 2>/dev/null || echo 0)
        redact_secrets < "$src" > "${dest}/$(basename "$src")" 2>/dev/null || echo "Failed to copy: $src" > "${dest}/$(basename "$src").error"
        should_mark "${dest}/$(basename "$src")" "$_pc" && mark_redacted "${dest}/$(basename "$src")"
    fi
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
    awk '
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
    }' | sed -E '
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
        s/(^|[^A-Za-z0-9])("?(passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(passphrase|pass[-_]?phrase|master[-_]?password|recovery[-_]?code|seed[-_]?phrase|mnemonic|credential|private-key-password|leap-password|wep-key[0-9]*|preshared[-_]?key|private[-_]?key|privkey|api[-_]?key|apikey|secret[-_]?key|access[-_]?key|client[-_]?secret|access[-_]?token|refresh[-_]?token|session[-_]?token|auth[-_]?token|proxy-authorization|authorization|set-cookie|cookie|password|passwd|secret|token|psk|pass)"?[[:space:]]*[:=][[:space:]]*)([^"}[:space:]][^"}]*)/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(signature|uuid|key|sig|pin)"?[[:space:]]*[:=][[:space:]]*")[^"]*/\1\2[REDACTED]/Ig
        s/(^|[^A-Za-z0-9])("?(signature|uuid|key|sig|pin)"?[[:space:]]*[:=][[:space:]]*)([^"{},[:space:]]+)/\1\2[REDACTED]/Ig
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
        s/("?e?ssid"?[[:space:]]*[:=][[:space:]]*"?)[^"{},]*/\1[REDACTED-SSID]/Ig
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
    ' | awk '
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
            while (match(rest, /[0-9A-Fa-f:]+(%[A-Za-z0-9_.-]+)?/)) {
                tok   = substr(rest, RSTART, RLENGTH)
                pre   = substr(rest, 1, RSTART - 1)
                nxt   = substr(rest, RSTART + RLENGTH, 1)
                rest  = substr(rest, RSTART + RLENGTH)
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
            $0 = out rest
        }

        if ($0 !~ /[0-9]\.[0-9]/) { print $0; next }

        out = ""; rest = $0
        while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            ip    = substr(rest, RSTART, RLENGTH)
            pre   = substr(rest, 1, RSTART - 1)
            after = substr(rest, RSTART + RLENGTH, 1)
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
            ctx  = out pre
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
                tl = substr(rest, RSTART + RLENGTH)
                if (tl !~ /^[-+~][0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) isver = 1
            }
            out = out pre ((valid && !priv && !isver) ? "[REDACTED-IPV4]" : ip)
            rest = substr(rest, RSTART + RLENGTH)
        }
        print out rest
    }'
}

# Copy a file into the bundle THROUGH redact_secrets, preserving an optional
# relative sub-path. Truncates oversized files (still redacted).
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
    if [[ $fsz -gt $max_size ]]; then
        tail -c 50M "$src" 2>/dev/null | redact_secrets > "$dest" 2>/dev/null || true
        echo "[Original $fsz bytes; truncated to last 50MB, redacted]" >> "$dest"
    else
        redact_secrets < "$src" > "$dest" 2>/dev/null \
            || echo "Failed to copy (redacted): $src" > "${dest}.error"
    fi
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
        output=$(sudo -u "$REAL_USER" \
            XDG_RUNTIME_DIR="/run/user/${REAL_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${REAL_UID}/bus" \
            DISPLAY="${DISPLAY:-:0}" \
            HOME="$REAL_HOME" \
            bash -lc "$cmd" 2>&1)
        rc=$?
    else
        output=$(eval "$cmd" 2>&1)
        rc=$?
    fi

    local redacted_cmd
    redacted_cmd=$(printf '%s\n' "$cmd" | redact_secrets)
    if [[ -n "$output" ]]; then
        output=$(printf '%s\n' "$output" | redact_secrets)
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
        sudo -u "$REAL_USER" cat "$src" 2>/dev/null | redact_secrets > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy (perm denied): $src" > "${dest}/$(basename "$src").error"
    else
        redact_secrets < "$src" > "${dest}/$(basename "$src")" 2>/dev/null \
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
        sudo -u "$REAL_USER" cat "$src" 2>/dev/null | redact_secrets \
            > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy (perm denied): $src" > "${dest}/$(basename "$src").error"
    else
        redact_secrets < "$src" > "${dest}/$(basename "$src")" 2>/dev/null \
            || echo "Failed to copy: $src" > "${dest}/$(basename "$src").error"
    fi
    should_mark "${dest}/$(basename "$src")" "$_pu" && mark_redacted "${dest}/$(basename "$src")"
}

# ---- Interactive category selection menu ----

show_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         KODACHI OS DEBUG COLLECTOR v1.6                  ║"
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
    echo "║         KODACHI OS DEBUG COLLECTOR v1.6                  ║"
    echo "║    Comprehensive System Diagnostics Tool                 ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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
            ACTIVE_SLOTS=$(echo "$DUMP" | grep -c "ENABLED" 2>/dev/null)
            [[ "$ACTIVE_SLOTS" =~ ^[0-9]+$ ]] || ACTIVE_SLOTS=0
            echo "    Active key slots: $ACTIVE_SLOTS"
            echo "$DUMP" | grep -E "(Key Slot|ENABLED|DISABLED)" | head -16 | sed 's/^/    /'
            if [[ "$ACTIVE_SLOTS" -ge 2 ]]; then
                NUKE_STATUS="LIKELY ENABLED (multiple key slots active)"
                echo "    NOTE: Multiple key slots active - nuke password is likely configured"
            fi
        fi
    done
else
    echo "  (no LUKS devices to check)"
fi

echo ""
echo ">>> NUKE PASSWORD: $NUKE_STATUS <<<"
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
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo); do
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
echo "  Nuke Password:      ${NUKE_STATUS}"
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
safe_exec "$COLLECTION_DIR/03-network/nftables-boot-units.txt" "systemctl status nftables kodachi-firewall-restore kodachi-tor-pool-boot --no-pager -l"
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
    safe_exec "$COLLECTION_DIR/03-network/dnscrypt-service.txt" "systemctl status dnscrypt-proxy --no-pager -l"
    safe_exec "$COLLECTION_DIR/03-network/dnscrypt-journal.txt" "journalctl -b -u dnscrypt-proxy --no-pager -n 400"
fi

# WireGuard status (redact private/preshared keys)
if command -v wg &> /dev/null; then
    wg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_secrets \
        > "$COLLECTION_DIR/03-network/wireguard-show.txt" 2>/dev/null || true
fi

# AmneziaWG status, same redaction. Separate tool, separate netlink family.
if command -v awg &> /dev/null; then
    awg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_secrets \
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
    find /etc/NetworkManager -type f 2>/dev/null | while read -r nm_file; do
        dest_file="$COLLECTION_DIR/03-network/NetworkManager-config/${nm_file#/etc/NetworkManager/}"
        mkdir -p "$(dirname "$dest_file")"
        if echo "$nm_file" | grep -qE "(system-connections|secrets)"; then
            # Redact passwords, PSK, secrets from connection profiles
            # NM-specific narrow pass THEN the general redactor, which also
            # covers WireGuard-in-NM private-key=/preshared-key=, inline PEM
            # and credential URIs the narrow sed missed.
            sed -E 's/(psk=).*/\1[REDACTED]/g; s/(password=).*/\1[REDACTED]/g; s/(secret=).*/\1[REDACTED]/g; s/(wep-key[0-9]*=).*/\1[REDACTED]/g; s/(leap-password=).*/\1[REDACTED]/g; s/(pin=).*/\1[REDACTED]/g; s/(private-key-password=).*/\1[REDACTED]/g' \
                "$nm_file" 2>/dev/null | redact_secrets > "$dest_file" 2>/dev/null || true
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

safe_exec "$COLLECTION_DIR/04-tor/tor-service-status.txt" "systemctl status tor* --no-pager"

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

safe_exec "$COLLECTION_DIR/05-vpn/openvpn-service-status.txt" "systemctl status openvpn* --no-pager"

# WireGuard service and interface status
safe_exec "$COLLECTION_DIR/05-vpn/wireguard-service-status.txt" "systemctl status wg-quick* --no-pager 2>/dev/null || echo 'no wg-quick service'"
if command -v wg &> /dev/null; then
    wg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_secrets \
        > "$COLLECTION_DIR/05-vpn/wireguard-detail.txt" 2>/dev/null || true
fi

# AmneziaWG service and interface status.
safe_exec "$COLLECTION_DIR/05-vpn/amneziawg-service-status.txt" "systemctl status awg-quick* --no-pager 2>/dev/null || echo 'no awg-quick service'"
if command -v awg &> /dev/null; then
    awg show all 2>/dev/null | sed -E 's/(private key|preshared key): .*/\1: [REDACTED]/g' | redact_secrets \
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

for hooks_pattern in "${KODACHI_HOOKS_DIRS[@]}"; do
    for hooks_dir in $hooks_pattern; do
        if [[ -d "$hooks_dir" ]]; then
            echo "Found Kodachi hooks at: $hooks_dir" >> "$COLLECTION_DIR/06-kodachi/hooks-locations.txt"

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
        "$binary" --version >> "$COLLECTION_DIR/06-kodachi/binary-status.txt" 2>&1 || echo "  (no version info)" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    else
        echo "✗ $binary: NOT FOUND" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
    fi
done
echo "" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
echo "[Optional / AI subsystem]" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
for binary in "${KODACHI_BINARIES_OPTIONAL[@]}"; do
    if command -v "$binary" &> /dev/null; then
        echo "✓ $binary: FOUND" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
        "$binary" --version >> "$COLLECTION_DIR/06-kodachi/binary-status.txt" 2>&1 || echo "  (no version info)" >> "$COLLECTION_DIR/06-kodachi/binary-status.txt"
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
            # Copy config files but skip signkeys and any credential files
            find "$hooks_dir/config" -type f \( -name "*.json" -o -name "*.conf" -o -name "*.toml" \) \
                ! -path "*/signkeys/*" ! -path "*/secrets/*" ! -path "*credential*" ! -path "*password*" ! -path "*token*" \
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

# Per-unit deep dive: status, definition, restart counters and journal slice
# for every kodachi* unit. A crash-looping service is invisible without
# NRestarts/ExecMainStatus and its own journal lines.
mkdir -p "$COLLECTION_DIR/06-kodachi/units"
systemctl list-units 'kodachi*' --all --no-legend --plain 2>/dev/null | awk '{print $1}' | while read -r kunit; do
    [[ -n "$kunit" ]] || continue
    uname_safe="${kunit//[^A-Za-z0-9._-]/_}"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-status.txt" "systemctl status '$kunit' --no-pager -l"
    safe_exec "$COLLECTION_DIR/06-kodachi/units/${uname_safe}-show.txt" "systemctl show '$kunit' -p ActiveState,SubState,Result,NRestarts,ExecMainStatus,ExecMainStartTimestamp,Restart,RestartUSec,FragmentPath"
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
        for sdir in state cache db flags .soc-state; do
            [[ -d "$hooks_dir/$sdir" ]] || continue
            find "$hooks_dir/$sdir" -type f -size -2M 2>/dev/null | head -200 | while read -r sfile; do
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
if command -v health-control &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-security-score.txt" "health-control security-score --json 2>/dev/null || echo 'security-score unavailable'"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-net-check.txt" "health-control net-check --json 2>/dev/null || echo 'net-check unavailable'"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-ipv6-status.txt" "health-control ipv6-status --json 2>/dev/null || echo 'ipv6-status unavailable'"
    safe_exec "$COLLECTION_DIR/06-kodachi/health-control-swap-status.txt" "health-control swap-status --json 2>/dev/null || echo 'swap-status unavailable'"
fi

# DNS-switch status
if command -v dns-switch &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/dns-switch-status.txt" "dns-switch status --json 2>/dev/null || echo 'dns-switch unavailable'"
fi

# Routing-switch state
if command -v routing-switch &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/routing-switch-status.txt" "routing-switch status --json 2>/dev/null || echo 'routing-switch unavailable'"
fi

# Kodachi SOC host-security telemetry snapshot (read-only collector)
if command -v kodachi-soc &> /dev/null; then
    safe_exec "$COLLECTION_DIR/06-kodachi/kodachi-soc-snapshot.json" "kodachi-soc snapshot --json 2>/dev/null || echo 'kodachi-soc unavailable'"
fi

fi # end CATEGORY 6

# ============================================================================
# CATEGORY 7: Installation & Package Logs
# ============================================================================
if [[ "${CAT_ENABLED[7]}" == "1" ]]; then
progress "Collecting installation and package logs..."

mkdir -p "$COLLECTION_DIR/07-installation-packages"

# Calamares installer logs (check all known locations)
CALAMARES_DIRS=(
    "/var/log/installer"
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
# Post-install Kodachi finish logs
safe_copy "/target/tmp/kodachi-grub-theme.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-finish-install.log" "$COLLECTION_DIR/07-installation-packages"

# audit 2026-05-07: extra Kodachi install / first-boot logs that were
# previously missed. Each is independently captured because Calamares,
# kodachi-finish-install, plymouth-firstboot, and crypttab-repair write to
# different locations and any of them can fingerprint a slow-boot incident.
safe_copy "/var/log/kodachi-cryptswap-activate.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-plymouth-firstboot.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-deps-install.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-binary-install.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-autoshield.log" "$COLLECTION_DIR/07-installation-packages"
safe_copy "/var/log/kodachi-fix-resolvconf.log" "$COLLECTION_DIR/07-installation-packages"

# Anything else under /var/log named kodachi-*.log
mkdir -p "$COLLECTION_DIR/07-installation-packages/kodachi-logs"
find /var/log -maxdepth 2 -name 'kodachi-*.log' -o -name 'kodachi*.log' 2>/dev/null | head -50 | while read -r kl; do
    safe_copy "$kl" "$COLLECTION_DIR/07-installation-packages/kodachi-logs"
done

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

# Crypttab repair logs (Kodachi's boot-time cryptswap fixer)
safe_copy "/var/log/kodachi-crypttab-fix.log" "$COLLECTION_DIR/07-installation-packages"

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
    safe_exec "$COLLECTION_DIR/07-installation-packages/efi-boot/efi-vars-list.txt" "ls -la /sys/firmware/efi/efivars/ | head -50"
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
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-user-current-boot.txt" \
    "journalctl --user -b --no-pager"
safe_exec_user "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-user-warnings.txt" \
    "journalctl --user -b -p warning --no-pager"
safe_exec "$COLLECTION_DIR/08-display-desktop/user-session/journalctl-uid.txt" \
    "journalctl _UID=${REAL_UID:-1001} -b --no-pager"
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
        rel="$(echo "$d" | tr '/' '_')"
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
        pkcs11-register --version 2>&1 | head -3
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
    /usr/bin/xfce4-session --version 2>&1 | head -5
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
    echo "=== /var/log/kodachi-finish-install.log ==="
    if [[ -f /var/log/kodachi-finish-install.log ]]; then
        cat /var/log/kodachi-finish-install.log 2>/dev/null | head -100
    else
        echo "  (not present, kodachi-finish-install did not run)"
    fi
    echo ""
    echo "=== /tmp/kodachi-grub-theme.log (during install) ==="
    if [[ -f /tmp/kodachi-grub-theme.log ]]; then
        cat /tmp/kodachi-grub-theme.log 2>/dev/null | head -50
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
                    cmdline) tr '\0' ' '  < "/proc/$pid/$f" 2>/dev/null | redact_secrets > "$ppath/$f.txt" || true ;;
                    environ) tr '\0' '\n' < "/proc/$pid/$f" 2>/dev/null | redact_secrets > "$ppath/$f.txt" || true ;;
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
                tr '\0' ' ' < "/proc/$pid/$f" 2>/dev/null | redact_secrets > "$ppath/$f.txt" || true
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
safe_exec "$COLLECTION_DIR/10-security-permissions/sysctl-kernel.txt" "sysctl kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled kernel.yama.ptrace_scope kernel.randomize_va_space kernel.kexec_load_disabled kernel.sysrq kernel.perf_event_paranoid net.core.bpf_jit_harden fs.protected_symlinks fs.protected_hardlinks net.ipv4.tcp_syncookies net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null"

# sysctl.d drop-in configs
if [[ -d "/etc/sysctl.d" ]]; then
    mkdir -p "$COLLECTION_DIR/10-security-permissions/sysctl.d"
    for sconf in /etc/sysctl.d/*.conf; do
        [[ -f "$sconf" ]] && cp "$sconf" "$COLLECTION_DIR/10-security-permissions/sysctl.d/" 2>/dev/null || true
    done
fi

# chkrootkit config and status
safe_copy "/etc/chkrootkit/chkrootkit.conf" "$COLLECTION_DIR/10-security-permissions"
safe_exec "$COLLECTION_DIR/10-security-permissions/chkrootkit-service.txt" "systemctl status chkrootkit.service --no-pager 2>/dev/null || echo 'chkrootkit service not found'"

# fail2ban status
if command -v fail2ban-client &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/fail2ban-status.txt" "fail2ban-client status 2>/dev/null || echo 'fail2ban not running'"
fi

# auditd rules and status
if command -v auditctl &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/auditd-rules.txt" "auditctl -l 2>/dev/null || echo 'auditd not running'"
    safe_exec "$COLLECTION_DIR/10-security-permissions/auditd-status.txt" "systemctl status auditd --no-pager 2>/dev/null"
fi

# usbguard status
if command -v usbguard &> /dev/null; then
    safe_exec "$COLLECTION_DIR/10-security-permissions/usbguard-rules.txt" "usbguard list-rules 2>/dev/null || echo 'usbguard not active'"
    safe_exec "$COLLECTION_DIR/10-security-permissions/usbguard-devices.txt" "usbguard list-devices 2>/dev/null || echo 'usbguard not active'"
fi

# NTP service status (for IPv6 bind error debugging)
safe_exec "$COLLECTION_DIR/10-security-permissions/ntpsec-status.txt" "systemctl status ntpsec --no-pager 2>/dev/null || systemctl status ntp --no-pager 2>/dev/null || echo 'no NTP service'"
safe_copy "/etc/ntpsec/ntp.conf" "$COLLECTION_DIR/10-security-permissions"

# Sudoers (list files only, don't copy contents, too sensitive)
safe_exec "$COLLECTION_DIR/10-security-permissions/sudoers-files.txt" "ls -la /etc/sudoers.d/ 2>/dev/null || echo 'no sudoers.d'"

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

fi # end CATEGORY 12

# ============================================================================
# CATEGORY 13: Collection Metadata (always runs)
# ============================================================================
progress "Generating collection metadata..."

mkdir -p "$COLLECTION_DIR/00-metadata"

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
    local file tmp sz swept=0 skipped=0 nontext=0 empty=0 total=0
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
        if redact_secrets < "$file" > "$tmp" 2>/dev/null; then
            cat "$tmp" > "$file" 2>/dev/null || true
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

final_redaction_sweep

# Collection tree
tree "$COLLECTION_DIR" > "$COLLECTION_DIR/00-metadata/directory-tree.txt" 2>/dev/null || \
    find "$COLLECTION_DIR" -type f > "$COLLECTION_DIR/00-metadata/file-list.txt"

# ============================================================================
# CATEGORY 14: Create ZIP Archive (always runs)
# ============================================================================
progress "Creating compressed archive..."

cd "$TEMP_DIR" || exit 1
if zip -r "$ZIP_FILE" "$COLLECTION_NAME" > /dev/null 2>&1; then
    ZIP_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
    echo -e "${GREEN}✓ Archive created successfully${NC}"
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
