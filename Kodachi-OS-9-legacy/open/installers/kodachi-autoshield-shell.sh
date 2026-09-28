#!/bin/bash
set -o pipefail

# Kodachi AutoShield Script - MANUAL TESTING VARIANT
# ===========================================================
#
# !!! READ THIS FIRST !!!
# This file is the MANUAL-TESTING / DEVELOPER variant of kodachi-autoshield.sh.
# It is NOT shipped in the ISO and NOT installed at /etc/profile.d/.
# The production file that runs on user login is kodachi-autoshield.sh
# (no -shell suffix), which lives in the same directory and is copied to
# /etc/profile.d/kodachi-autoshield.sh by the live-build overlay.
#
# Differences from the production kodachi-autoshield.sh:
#   1. The early-return gating block has been removed
#      (no KODACHI_SKIP_WELCOME / non-interactive / KODACHI_WELCOME_AUTO checks),
#      so this variant ALWAYS runs main() when executed.
#   2. Top-level function wrappers for sleep / curl / timeout / read add
#      SIGINT/SIGTERM propagation through terminate_autoshield. These wrappers
#      live at script scope on purpose for the standalone-execution model.
#   3. propagate_signal_exit calls are inserted after every PIPESTATUS capture
#      in the DNSCrypt setup paths.
#
# DO NOT install this file at /etc/profile.d/ and DO NOT source it from a
# login shell. If sourced, the top-level function wrappers and the missing
# interactive guard will pollute the calling shell and break non-interactive
# sessions (ssh, scp, rsync, cron). Use kodachi-autoshield.sh for that role.
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
# Last updated: 2026-05-23
#
# Description:
# Manual-testing harness for the AutoShield login flow. Displays system status,
# security information, and network details. Optimized for 80x24 terminal.
# Provides interactive menu for executing common system profiles and workflows.
#
# Links:
# - Website: https://www.digi77.com
# - Website: https://www.kodachi.cloud
# - GitHub: https://github.com/WMAL
# - Discord: https://discord.gg/KEFErEx
# - LinkedIn: https://om.linkedin.com/in/warith1977
# - X (Twitter): https://x.com/warith2020
#
# Usage (manual testing only):
#   chmod +x kodachi-autoshield-shell.sh
#   ./kodachi-autoshield-shell.sh
#   ./kodachi-autoshield-shell.sh --force-dns-setup    # re-run DNSCrypt setup
#
# Features:
#   - Binary deployment verification
#   - Online authentication status
#   - DNSCrypt configuration
#   - Network and system information display
#   - Security score and hardening status
#   - Cryptocurrency prices and news headlines
#   - Interactive profile menu for system workflows

# Parse command-line arguments
FORCE_DNS_SETUP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-dns-setup)
            FORCE_DNS_SETUP=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Build signature - AUTO-UPDATED BY pack-kodachi.sh
# Source: main-info.json (terminal section)
# DO NOT EDIT MANUALLY - Run pack-kodachi.sh to update these values
BUILD_VERSION="9.0.1"  # From: terminal.main_version
BUILD_NUM="179"          # From: terminal.build_number (auto-incremented)
BUILD_DATE="2026-06-26"  # From: terminal.last_build_date
SCRIPT_VERSION="${BUILD_VERSION}.${BUILD_NUM}"

# Color codes for compact display (optimized for black terminal)
RED='\033[0;31m'
GREEN='\033[1;32m'    # Lime green for positive/success values
YELLOW='\033[1;35m'   # Bright magenta for progress/working messages
BLUE='\033[1;36m'     # Bright cyan (was dark blue - invisible on black terminal)
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Kodachi version and website
# The header used to print BUILD_VERSION, which only pack-kodachi.sh rewrites. The ISO
# build copies this file as-is, so the <lab-host> live ISO of 2026-09-04 shipped a header
# reading "Kodachi OS 9.0.1" while /etc/os-release and every hook binary said <lab-host>
# (measured 2026-09-06 on <lab-host>). The OS release file is written by the
# branding hook for exactly this purpose, so read it at runtime and keep BUILD_VERSION
# only as the last fallback and as the terminal-track build stamp on the Build: line.
detect_os_version() {
    local version=""
    # The two file paths are overridable so the regression suite can feed fixtures.
    local os_release="${AUTOSHIELD_OS_RELEASE_FILE:-/etc/os-release}"
    local issue_net="${AUTOSHIELD_ISSUE_NET_FILE:-/etc/issue.net}"

    # Only trust VERSION_ID when the release file is Kodachi's own; on a plain Debian
    # host it would read "13".
    if [ -r "$os_release" ] && grep -q '^ID=kodachi' "$os_release" 2>/dev/null; then
        version=$(sed -nE 's/^VERSION_ID="?([0-9][0-9.]*)"?.*/\1/p' "$os_release" 2>/dev/null | head -1)
    fi

    if [ -z "$version" ] && [ -r "$issue_net" ]; then
        version=$(sed -nE '1{s/^Kodachi[[:space:]]+(OS[[:space:]]+)?([0-9][0-9.]*).*/\2/p;q}' "$issue_net" 2>/dev/null)
    fi

    [ -n "$version" ] && echo "$version" || echo "$BUILD_VERSION"
}

KODACHI_VERSION="$(detect_os_version)"
KODACHI_WEBSITE="kodachi.cloud"

# Detect edition label from runtime branding so Terminal/XFCE builds show distinct headers.
detect_edition_label() {
    local edition=""

    # /etc/issue.net is generated per build variant and includes "<Edition> Edition".
    if [ -r /etc/issue.net ]; then
        edition=$(sed -n '1{s/^Kodachi[[:space:]][0-9.]\+[[:space:]]\+\(.* Edition\).*/\1/p;q}' /etc/issue.net 2>/dev/null)
    fi

    # Fallback: derive from PRETTY_NAME when issue.net is unavailable.
    if [ -z "$edition" ] && [ -r /etc/os-release ]; then
        edition=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null | head -1)
    fi

    [ -n "$edition" ] && echo "$edition" || echo "Privacy & Security OS"
}

KODACHI_EDITION_LABEL="$(detect_edition_label)"

# On desktop editions the ISO install hook re-links welcome/shield/kodachi to
# kodachi-dashboard-launcher (AutoShield lives in the dashboard there), so the old
# "type 'kodachi' and press Enter" hint on the Exit row opened the GUI instead of
# returning here. Say what the link actually does on this system.
detect_relaunch_hint() {
    local target=""
    target=$(readlink -f /usr/local/bin/welcome 2>/dev/null || true)
    case "$(basename "${target:-}")" in
        kodachi-dashboard-launcher) echo "${CYAN}'welcome'${NC} opens the GUI dashboard" ;;
        welcome) echo "${CYAN}'welcome'${NC} returns here" ;;
        *) echo "no relaunch shortcut on this system" ;;
    esac
}

AUTOSHIELD_RELAUNCH_HINT="$(detect_relaunch_hint)"

# Auto-refresh timeout in seconds (600 = 10 minutes)
# Change this value to adjust auto-refresh interval
AUTO_REFRESH_TIMEOUT=600

# Detect real user home directory (even when running with sudo)
if [ -n "$SUDO_USER" ]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_HOME="$HOME"
fi

# Global variable to store actual DNS mode (verified, not assumed)
ACTUAL_DNS_MODE="Unknown"

# Global variables for Tor DNS verification
TOR_DNS_DIRECT_STATUS="unknown"
TOR_DNS_PORT_STATUS="unknown"
TOR_DNS_OVERALL_STATUS="false"
TOR_DNS_DETAILED=""
TOR_DNS_FIREWALL_STATUS="unknown"      # Firewall confirmation status
TOR_DNS_FIREWALL_BACKEND="none"        # Which firewall is managing (iptables/nftables)
TOR_DNS_FIREWALL_VERIFIED="false"      # Boolean for firewall confirmation

# Global variables for consolidated status display
DEPLOY_STATUS=""
AUTH_STATUS=""
DNS_STATUS_MSG=""
INFO_STATUS=""
PERM_GUARD_STATUS=""
TIME_SYNC_STATUS=""
PROFILE_COUNT=""
LOGS_COUNT=""
BINARIES_COUNT=""
LATEST_VERSION=""
CRYPTO_PRICES=""
NEWS_HEADLINES=""
HAS_INTERNET=false
KNET_STATUS="${YELLOW}[KNet:?]${NC}"  # Kodachi Network status

# Flag to skip refresh when returning from submenu
SKIP_REFRESH=false

# Hooks directory
HOOKS_DIR=""

# Command resolution and runtime safety settings
SAFE_COMMAND_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Prefer /run/kodachi for cross-process lock files when the current user can
# actually create files there. Live sessions may expose a root-only directory,
# so fall back to /tmp instead of failing with "Permission denied".
detect_dns_lock_file() {
    local runtime_dir="/run/kodachi"
    local lock_file="$runtime_dir/kodachi-autoshield-dns.lock"
    local probe_file="$runtime_dir/.kodachi-autoshield-lock-probe.$$"

    if [ ! -d "$runtime_dir" ]; then
        sudo -n mkdir -p "$runtime_dir" 2>/dev/null || true
    fi

    if [ -d "$runtime_dir" ]; then
        if [ -e "$lock_file" ]; then
            if [ -w "$lock_file" ]; then
                echo "$lock_file"
                return 0
            fi
        elif touch "$probe_file" >/dev/null 2>&1; then
            rm -f "$probe_file" 2>/dev/null || true
            echo "$lock_file"
            return 0
        fi
    fi

    # ONE lock for the whole machine. setup_dnscrypt reconfigures SYSTEM DNS, so the lock
    # has to exclude every user on the box, and a per-user lock would turn a loud
    # fail-closed skip into a silent concurrent reconfiguration.
    #
    # The failure this addresses, measured 2026-09-06 on <lab-host>: a
    # `sudo ... --force-dns-setup` creates the lock as root with the default 0644, and every
    # later run by the desktop user then fails to open it (EACCES) and skips DNS setup
    # entirely. The fix is to make the shared lock OPENABLE by everyone, not to give each
    # user a lock of their own: create it world-writable, and widen an existing one when we
    # can. If it still cannot be opened, with_dns_lock reports it and refuses, which is the
    # correct fail-closed behaviour for a system-wide reconfiguration.
    local shared_lock="/tmp/kodachi-autoshield-dns.lock"
    if [ ! -e "$shared_lock" ]; then
        ( umask 000; : >"$shared_lock" ) 2>/dev/null || true
    fi
    if [ -e "$shared_lock" ] && [ ! -w "$shared_lock" ]; then
        sudo -n chmod 0666 "$shared_lock" >/dev/null 2>&1 || true
    fi

    echo "$shared_lock"
}

DNS_LOCK_FILE="$(detect_dns_lock_file)"
RUNTIME_TMP_DIR=""
GRUB_THEME_LOG=""
VERIFY_CHECK_JSON=""
VERIFY_RESULT_JSON=""
DEPLOY_OUTPUT_LOG=""
DNS_SWITCH_LOG=""
AUTOSHIELD_RUNNING_AS_SCRIPT=false

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    AUTOSHIELD_RUNNING_AS_SCRIPT=true
fi

is_allowed_run_command() {
    case "$1" in
        health-control|ip-fetch|tor-switch|online-auth|dns-switch|routing-switch|workflow-manager|permission-guard|online-info-switch|integrity-check|dns-leak)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Pre-flight check for critical system dependencies
check_critical_dependencies() {
    local missing=()
    local critical_tools=(curl flock timeout mktemp getent)

    for tool in "${critical_tools[@]}"; do
        if ! type -P "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}WARNING: Missing critical system tools: ${missing[*]}${NC}" >&2
        echo -e "${YELLOW}Some AutoShield features may not work correctly.${NC}" >&2
        return 1
    fi
    return 0
}

init_runtime_environment() {
    if [ -n "$RUNTIME_TMP_DIR" ] && [ -d "$RUNTIME_TMP_DIR" ]; then
        return 0
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null) || tmp_dir=$(mktemp -d "/tmp/kodachi-autoshield.XXXXXX") || {
        echo "ERROR: failed to create secure runtime temp directory" >&2
        return 1
    }
    chmod 700 "$tmp_dir" 2>/dev/null || true

    RUNTIME_TMP_DIR="$tmp_dir"
    GRUB_THEME_LOG="$RUNTIME_TMP_DIR/kodachi-grub-theme.log"
    VERIFY_CHECK_JSON="$RUNTIME_TMP_DIR/verify-check.json"
    VERIFY_RESULT_JSON="$RUNTIME_TMP_DIR/verify-result.json"
    DEPLOY_OUTPUT_LOG="$RUNTIME_TMP_DIR/deploy-output.txt"
    DNS_SWITCH_LOG="$RUNTIME_TMP_DIR/dns-switch.log"
}

cleanup_runtime_environment() {
    if [ -n "$RUNTIME_TMP_DIR" ] && [ -d "$RUNTIME_TMP_DIR" ]; then
        rm -rf "$RUNTIME_TMP_DIR" 2>/dev/null || true
    fi
    RUNTIME_TMP_DIR=""
    GRUB_THEME_LOG=""
    VERIFY_CHECK_JSON=""
    VERIFY_RESULT_JSON=""
    DEPLOY_OUTPUT_LOG=""
    DNS_SWITCH_LOG=""
}

is_signal_exit_status() {
    case "$1" in
        130|143)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

terminate_autoshield() {
    local status="${1:-130}"

    cleanup_runtime_environment
    clear_runtime_signal_traps

    if [ "$AUTOSHIELD_RUNNING_AS_SCRIPT" = "true" ]; then
        exit "$status"
    fi

    return "$status"
}

propagate_signal_exit() {
    local status="$1"

    if is_signal_exit_status "$status"; then
        terminate_autoshield "$status"
    fi

    return "$status"
}

sleep() {
    command sleep "$@"
    local sleep_status=$?
    propagate_signal_exit "$sleep_status"
    return "$sleep_status"
}

curl() {
    command curl "$@"
    local curl_status=$?
    propagate_signal_exit "$curl_status"
    return "$curl_status"
}

timeout() {
    command timeout "$@"
    local timeout_status=$?
    propagate_signal_exit "$timeout_status"
    return "$timeout_status"
}

read() {
    builtin read "$@"
    local read_status=$?
    propagate_signal_exit "$read_status"
    return "$read_status"
}

handle_runtime_sigint() {
    terminate_autoshield 130
}

handle_runtime_sigterm() {
    terminate_autoshield 143
}

# AUTOSHIELD_RUNNING_AS_SCRIPT is this file's single answer to "is this process mine";
# terminate_autoshield already keys on it, and these must use the SAME predicate.
setup_runtime_signal_traps() {
    trap handle_runtime_sigint INT
    trap handle_runtime_sigterm TERM
    if [ "$AUTOSHIELD_RUNNING_AS_SCRIPT" = "true" ]; then
        trap cleanup_runtime_environment EXIT
    fi
}

clear_runtime_signal_traps() {
    trap - INT TERM
    if [ "$AUTOSHIELD_RUNNING_AS_SCRIPT" = "true" ]; then
        trap - EXIT
    fi
}

resolve_run_command_path() {
    local cmd="$1"
    local resolved=""

    if ! is_allowed_run_command "$cmd"; then
        echo "ERROR: command '$cmd' is not in AutoShield allowlist" >&2
        return 1
    fi

    if [ "$DEPLOY_STATUS" = "${GREEN}[GDeploy:+]${NC}" ] && [ -x "/usr/local/bin/$cmd" ]; then
        resolved="/usr/local/bin/$cmd"
    elif [ -n "$HOOKS_DIR" ] && [ -x "$HOOKS_DIR/$cmd" ]; then
        resolved="$HOOKS_DIR/$cmd"
    else
        resolved=$(PATH="$SAFE_COMMAND_PATH" command -v -- "$cmd" 2>/dev/null || true)
        if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
            echo "ERROR: failed to resolve executable path for '$cmd'" >&2
            return 1
        fi
    fi

    echo "$resolved"
}

execute_sudo_command_with_timeout() {
    local resolved_cmd="$1"
    local timeout_val="$2"
    shift 2
    local -a args=("$@")
    local -a timeout_cmd=()
    local command_status=0

    if [ -n "$timeout_val" ] && [ "$timeout_val" != "0" ]; then
        if [[ ! "$timeout_val" =~ ^[0-9]+$ ]]; then
            echo "ERROR: invalid timeout value '$timeout_val'" >&2
            return 1
        fi
        timeout_cmd=(timeout "$timeout_val")
    fi

    # Use sudo -n (non-interactive) to fail fast if NOPASSWD is missing
    if [ "${#timeout_cmd[@]}" -gt 0 ]; then
        "${timeout_cmd[@]}" sudo -n "$resolved_cmd" "${args[@]}"
        command_status=$?
    else
        sudo -n "$resolved_cmd" "${args[@]}"
        command_status=$?
    fi

    propagate_signal_exit "$command_status"
    return "$command_status"
}

run_privileged_command() {
    local command_status=0

    if sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
        command_status=$?
    elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
        sudo "$@"
        command_status=$?
    else
        return 1
    fi

    propagate_signal_exit "$command_status"
    return "$command_status"
}

with_dns_lock() {
    local lock_fd
    exec {lock_fd}>"$DNS_LOCK_FILE" || {
        echo "ERROR: unable to open DNS lock file: $DNS_LOCK_FILE" >&2
        return 1
    }

    if ! flock -w 30 "$lock_fd"; then
        echo "ERROR: timeout waiting for DNS lock" >&2
        exec {lock_fd}>&-
        return 1
    fi

    "$@"
    local action_status=$?
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-
    return $action_status
}

# Detect if we are running from the live ISO environment
is_live_session() {
    if grep -q "boot=live\|persistent=0\|boot=casper" /proc/cmdline 2>/dev/null; then
        return 0
    fi

    if mount | grep -q "/run/live" 2>/dev/null; then
        return 0
    fi

    if [ -d /run/live/medium ] || [ -d /run/live/rootfs ]; then
        return 0
    fi

    return 1
}

# Ensure installed system has Kodachi GRUB branding applied
ensure_grub_theme() {
    local helper="/usr/local/bin/kodachi-apply-grub-theme"
    local theme_txt="/boot/grub/live-theme/theme.txt"
    local splash_png="/boot/grub/live-theme/splash.png"
    local cfg_file="/etc/default/grub.d/40-kodachi-theme.cfg"

    echo -e "${CYAN}▸ Checking Kodachi GRUB theme...${NC}"

    # Live sessions do not ship the GRUB helper; skip silently
    if is_live_session; then
        echo -e "${CYAN}▸ Live session detected - skipping GRUB theme check${NC}"
        return 0
    fi

    # Helper only exists on installed systems; warn if missing
    if [ ! -x "$helper" ]; then
        echo -e "${YELLOW}! Theme helper not found (${helper}) - skipping${NC}"
        return 0
    fi

    local needs_fix=0
    [ -f "$theme_txt" ] || needs_fix=1
    [ -f "$splash_png" ] || needs_fix=1
    if [ ! -s "$cfg_file" ] || ! grep -q "live-theme/theme.txt" "$cfg_file" 2>/dev/null; then
        needs_fix=1
    fi

    if [ $needs_fix -eq 1 ]; then
        echo -e "${CYAN}▸ Restoring Kodachi GRUB theme...${NC}"
        init_runtime_environment || return 1
        if run_privileged_command "$helper" >"$GRUB_THEME_LOG" 2>&1; then
            echo -e "${GREEN}+ GRUB theme synchronized${NC}"
        else
            echo -e "${YELLOW}! Unable to apply GRUB theme (see $GRUB_THEME_LOG)${NC}"
        fi
    else
        echo -e "${GREEN}+ GRUB theme already applied${NC}"
    fi
}

# Function to check if jq is available
check_jq() {
    command -v jq >/dev/null 2>&1
}

# Function to parse JSON with fallback
parse_json() {
    local json="$1"
    local key="$2"

    if check_jq; then
        echo "$json" | jq -r "$key" 2>/dev/null | head -1
    else
        # Fallback to grep/sed (strip leading dot from jq-style path)
        local clean_key="${key#.}"
        # Match numeric values for time, or quoted strings for other data
        if echo "$json" | grep -q "\"$clean_key\"[[:space:]]*:[[:space:]]*[0-9]"; then
            # Numeric value
            echo "$json" | grep -o "\"$clean_key\"[[:space:]]*:[[:space:]]*[0-9]*" | grep -o "[0-9]*$" | head -1
        else
            # String value
            echo "$json" | grep -o "\"$clean_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)"$/\1/' | head -1
        fi
    fi
}

# Function to display compact header
show_header() {
    local header_text=" Kodachi OS ${KODACHI_VERSION} - ${KODACHI_EDITION_LABEL} - ${KODACHI_WEBSITE}"
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    # Keep output fixed-width for clean 80-column rendering even when edition text changes.
    printf "%b║%b%-78.78s%b%b║%b\n" "${CYAN}" "${NC}${BOLD}" "$header_text" "${NC}" "${CYAN}" "${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Simple timing utility - stores duration in OPERATION_TIME global variable
start_timer() {
    TIMER_START=$(date +%s 2>/dev/null || echo "0")
}

end_timer() {
    local end_time
    end_time=$(date +%s 2>/dev/null || echo "0")
    if [[ "${TIMER_START:-0}" =~ ^[0-9]+$ ]] && [ "${TIMER_START:-0}" -gt 0 ] && [ "$end_time" -ge "${TIMER_START:-0}" ]; then
        OPERATION_TIME=$((end_time - TIMER_START))
    else
        OPERATION_TIME=0
    fi
}

format_duration() {
    local seconds="$1"
    if [ "$seconds" -lt 1 ]; then
        echo "<1s"
    else
        echo "${seconds}s"
    fi
}

# Function to display section headers
print_section_header() {
    local section_name="$1"
    echo -e "\n${CYAN}═══ ${section_name} ═══${NC}"
}

# Function to verify hooks directory structure
verify_hooks_structure() {
    local dir="$1"

    # Count how many core binaries exist in this directory
    local binary_count=0
    local core_binaries=("health-control" "ip-fetch" "tor-switch" "online-auth" "dns-switch" "global-launcher")

    for binary in "${core_binaries[@]}"; do
        [ -f "$dir/$binary" ] && [ -x "$dir/$binary" ] && ((binary_count++))
    done

    # Need at least 3 core binaries to be considered valid hooks directory
    [ $binary_count -lt 3 ] && return 1

    # Should have at least one of these essential subdirectories
    [ -d "$dir/config" ] || [ -d "$dir/logs" ] || [ -d "$dir/tmp" ] || [ -d "$dir/results" ]
}

# Function to search for binaries in home directory (fallback)
search_binaries_in_home() {
    echo -e "${YELLOW}▸ Searching for binaries in home directory...${NC}"

    # Strategy 1: Quick search for directories with multiple core binaries (any depth up to 5)
    # Check multiple depth levels with glob patterns
    local best_dir=""
    local best_count=0
    local depth
    local -a depth_dirs=()

    for depth in 1 2 3 4 5; do
        # Expand each depth with the home part QUOTED, so a home directory containing a
        # space is one path and not several (the old unquoted $pattern word-split it).
        # An unmatched glob stays literal and is dropped by the -d test below.
        case "$depth" in
            1) depth_dirs=("$REAL_HOME"/*) ;;
            2) depth_dirs=("$REAL_HOME"/*/*) ;;
            3) depth_dirs=("$REAL_HOME"/*/*/*) ;;
            4) depth_dirs=("$REAL_HOME"/*/*/*/*) ;;
            5) depth_dirs=("$REAL_HOME"/*/*/*/*/*) ;;
        esac
        for dir in "${depth_dirs[@]}"; do
            # Only check directories
            [ ! -d "$dir" ] && continue

            # Skip known trash/backup/system directories
            if echo "$dir" | grep -qE "(trash-bin|backup|archive|\.Trash|/old/|-old|-before-|/cache/|/chroot/|/bootstrap/|\.git/)"; then
                continue
            fi

            # Quick check: does it have at least one core binary?
            if [ -f "$dir/health-control" ] || [ -f "$dir/global-launcher" ] || [ -f "$dir/ip-fetch" ]; then
                # Verify full structure
                if verify_hooks_structure "$dir"; then
                    # Count binaries to find the best match
                    local count=$(find "$dir" -maxdepth 1 -type f -executable ! -name "*.sh" 2>/dev/null | wc -l)

                    # Pick directory with most binaries
                    if [ $count -gt $best_count ]; then
                        best_count=$count
                        best_dir="$dir"
                    fi
                fi
            fi
        done

        # If we found a good match (5+ binaries), use it immediately
        if [ -n "$best_dir" ] && [ $best_count -ge 5 ]; then
            HOOKS_DIR="$best_dir"
            echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
            return 0
        fi
    done

    # If we found any valid directory (even with fewer binaries), use it
    if [ -n "$best_dir" ] && [ $best_count -ge 3 ]; then
        HOOKS_DIR="$best_dir"
        echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
        return 0
    fi

    # Strategy 2: Search for dashboard/hooks pattern with timeout (medium depth)
    local hooks_dirs=$(timeout 10 find "$REAL_HOME" -maxdepth 4 -type d -name "hooks" -path "*/dashboard/hooks" \
        ! -path "*/trash-bin/*" \
        ! -path "*/backup/*" \
        ! -path "*/archive/*" \
        ! -path "*/.Trash/*" \
        ! -path "*/old/*" \
        ! -path "*-old/*" \
        ! -path "*-before-*" \
        ! -path "*/chroot/*" \
        ! -path "*/cache/*" \
        ! -path "*/bootstrap/*" \
        2>/dev/null)

    # Find the best match by counting binaries
    local best_dir=""
    local best_count=0

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        if verify_hooks_structure "$dir"; then
            local count=$(find "$dir" -maxdepth 1 -type f -executable ! -name "*.sh" 2>/dev/null | wc -l)

            if [ $count -gt $best_count ]; then
                best_count=$count
                best_dir="$dir"
            fi
        fi
    done <<< "$hooks_dirs"

    if [ -n "$best_dir" ] && [ $best_count -ge 3 ]; then
        HOOKS_DIR="$best_dir"
        echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
        return 0
    fi

    # Strategy 3: Search for core binaries (broader search with timeout)
    local core_binaries=("health-control" "global-launcher" "ip-fetch")

    for binary_name in "${core_binaries[@]}"; do
        local found_binary=$(timeout 10 find "$REAL_HOME" -maxdepth 5 -name "$binary_name" -type f -executable \
            ! -path "*/trash-bin/*" \
            ! -path "*/backup/*" \
            ! -path "*/archive/*" \
            ! -path "*/chroot/*" \
            ! -path "*/cache/*" \
            2>/dev/null | head -1)

        if [ -n "$found_binary" ]; then
            local binary_dir=$(dirname "$found_binary")

            if verify_hooks_structure "$binary_dir"; then
                HOOKS_DIR="$binary_dir"
                echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
                return 0
            fi
        fi
    done

    # Not found
    HOOKS_DIR=""
    return 1
}

# Function to detect hooks directory
detect_hooks_dir() {
    echo -e "${YELLOW}▸ Detecting binaries location...${NC}"

    # Check current directory first
    if [ -f "./global-launcher" ] && verify_hooks_structure "."; then
        HOOKS_DIR="$(pwd)"
        echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
        return 0
    fi

    # Check explicit env vars and canonical install locations before searching home.
    local candidate_dirs=()
    [ -n "${HOOKS_DIR:-}" ] && candidate_dirs+=("$HOOKS_DIR")
    [ -n "${KODACHI_HOOKS_DIR:-}" ] && candidate_dirs+=("$KODACHI_HOOKS_DIR")
    [ -n "${KODACHI_HOME:-}" ] && candidate_dirs+=("$KODACHI_HOME")
    candidate_dirs+=(
        "/opt/kodachi/dashboard/hooks"
        "/usr/local/share/kodachi/hooks"
        "$REAL_HOME/dashboard/hooks"
        "$REAL_HOME/Desktop/dashboard/hooks"
        "$REAL_HOME/k900/dashboard/hooks"
        "$HOME/dashboard/hooks"
        "$HOME/Desktop/dashboard/hooks"
        "$HOME/k900/dashboard/hooks"
    )

    local dir
    for dir in "${candidate_dirs[@]}"; do
        [ -n "$dir" ] || continue
        if verify_hooks_structure "$dir"; then
            HOOKS_DIR="$dir"
            echo -e "${GREEN}+ Found binaries at: ${HOOKS_DIR}${NC}"
            return 0
        fi
    done

    # Search for health-control in home directory (PRIMARY METHOD)
    if search_binaries_in_home; then
        return 0
    fi

    # Last resort: Hooks directory not found
    echo -e "${YELLOW}! Hooks directory not found, using system binaries only${NC}"
    HOOKS_DIR=""
    return 1
}

# Helper function to execute commands with fallback to hooks directory
run_command() {
    local cmd="$1"
    local timeout_val="${2:-0}"  # Second arg is timeout (default: 0 = no timeout)
    shift 2
    local -a args=("$@")
    local resolved_cmd=""

    if ! resolved_cmd=$(resolve_run_command_path "$cmd"); then
        return 1
    fi

    local command_status=0
    execute_sudo_command_with_timeout "$resolved_cmd" "$timeout_val" "${args[@]}"
    command_status=$?
    if [ "$command_status" -eq 124 ]; then
        echo "ERROR: $cmd timed out after ${timeout_val}s" >&2
        return "$command_status"
    fi
    if [ "$command_status" -ne 0 ]; then
        echo "ERROR: $cmd exited with status $command_status (if sudo asked for a password, check /etc/sudoers.d/kodachi-binaries)" >&2
        return "$command_status"
    fi
    return 0
}

# Function to deploy binaries with proper verification
deploy_binaries() {
    echo -e "${YELLOW}▸ Checking binary deployment...${NC}"
    init_runtime_environment || return 1

    # Try to detect hooks directory
    if ! detect_hooks_dir; then
        # No hooks directory found - this is normal for ISO users!
        # Binaries are installed system-wide in /usr/local/bin
        echo -e "${GREEN}+ Using system-wide binaries${NC}"
        DEPLOY_STATUS="${GREEN}[GDeploy:N/A]${NC}"
        return 0
    fi

    # Hooks directory found - verify it's accessible (no cd to avoid changing working directory)
    if [ ! -d "$HOOKS_DIR" ] || [ ! -r "$HOOKS_DIR" ]; then
        echo -e "${YELLOW}! Cannot access hooks directory${NC}"
        DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
        return 0  # Not fatal - will use hooks directory directly
    fi

    # Check if global-launcher exists
    if [ ! -f "$HOOKS_DIR/global-launcher" ]; then
        echo -e "${YELLOW}! global-launcher not found${NC}"
        DEPLOY_STATUS="${GREEN}[GDeploy:N/A]${NC}"
        return 0
    fi

    # First check if already deployed and verified
    echo -e "${GREEN}  • Checking existing deployment...${NC}"
    if "$HOOKS_DIR/global-launcher" verify --json >"$VERIFY_CHECK_JSON" 2>&1; then
        # Use grep-first approach (reliable, no jq dependency)
        if grep -q '"verification_success":true' "$VERIFY_CHECK_JSON" 2>/dev/null; then
            # Extract count using grep/sed (works without jq)
            local count=$(grep -o '"total_verified":[0-9]*' "$VERIFY_CHECK_JSON" 2>/dev/null | grep -o '[0-9]*' | head -1)

            # Validate we got a count
            if [ -n "$count" ] && [ "$count" -gt 0 ]; then
                echo -e "${GREEN}  + Already deployed ($count binaries verified)${NC}"
                DEPLOY_STATUS="${GREEN}[GDeploy:+]${NC}"
                rm -f "$VERIFY_CHECK_JSON"
                return 0
            fi
        fi
    fi

    # If we reached here, verification failed or returned unexpected data
    # Safe to proceed with deployment

    # Need to deploy
    echo -e "  • Deploying binaries to /usr/local/bin/..."
    run_privileged_command "$HOOKS_DIR/global-launcher" deploy 2>&1 | tee "$DEPLOY_OUTPUT_LOG"
    local deploy_exit=${PIPESTATUS[0]}
    propagate_signal_exit "$deploy_exit"
    if [ "$deploy_exit" -eq 0 ]; then
        # Deployment command succeeded - now VERIFY it actually worked
        echo -e "  • Verifying deployment..."
        sleep 1

        if "$HOOKS_DIR/global-launcher" verify --json >"$VERIFY_RESULT_JSON" 2>&1; then
            if check_jq; then
                # The envelope puts the payload under .data (measured 2026-09-06 on the
                # <lab-host> binary); accept the bare form too for an older launcher.
                local verified=$(jq -r '.data.verification_success // .verification_success // empty' "$VERIFY_RESULT_JSON" 2>/dev/null)
                local count=$(jq -r '.data.total_verified // .total_verified // empty' "$VERIFY_RESULT_JSON" 2>/dev/null)
                local broken=$(jq -r '.data.total_broken // .total_broken // empty' "$VERIFY_RESULT_JSON" 2>/dev/null)

                # Check if jq actually returned values (not null/empty)
                if [ -n "$verified" ] && [ -n "$count" ] && [ -n "$broken" ]; then
                    if [ "$verified" = "true" ] && [ "$count" -gt 0 ] && [ "$broken" = "0" ]; then
                        echo -e "${GREEN}  + Deployment successful ($count/$count binaries verified)${NC}"
                        DEPLOY_STATUS="${GREEN}[GDeploy:+]${NC}"
                        rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                        return 0
                    else
                        echo -e "${RED}  - Verification failed ($count verified, $broken broken)${NC}"
                        echo -e "${YELLOW}  ! Falling back to local execution from hooks directory${NC}"
                        DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
                        rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                        return 0
                    fi
                else
                    # jq returned null/empty - fallback to grep
                    if grep -q '"verification_success":true' "$VERIFY_RESULT_JSON" 2>/dev/null; then
                        echo -e "${GREEN}  + Deployment successful (verified via grep)${NC}"
                        DEPLOY_STATUS="${GREEN}[GDeploy:+]${NC}"
                        rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                        return 0
                    else
                        echo -e "${RED}  - Verification parsing failed${NC}"
                        echo -e "${YELLOW}  ! Falling back to local execution from hooks directory${NC}"
                        DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
                        rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                        return 0
                    fi
                fi
            else
                # No jq - check if verify command succeeded
                if grep -q '"verification_success":true' "$VERIFY_RESULT_JSON" 2>/dev/null; then
                    echo -e "${GREEN}  + Deployment successful${NC}"
                    DEPLOY_STATUS="${GREEN}[GDeploy:+]${NC}"
                    rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                    return 0
                else
                    echo -e "${RED}  - Verification failed${NC}"
                    echo -e "${YELLOW}  ! Falling back to local execution from hooks directory${NC}"
                    DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
                    rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
                    return 0
                fi
            fi
        else
            echo -e "${RED}  - Verification command failed${NC}"
            echo -e "${YELLOW}  ! Falling back to local execution from hooks directory${NC}"
            DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
            rm -f "$VERIFY_RESULT_JSON" "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
            return 0
        fi
    else
        # Deployment failed
        echo -e "${RED}  - Deployment failed${NC}"
        if [ -f "$DEPLOY_OUTPUT_LOG" ]; then
            echo -e "${YELLOW}  ! Error: $(cat "$DEPLOY_OUTPUT_LOG" | head -1)${NC}"
        fi
        echo -e "${YELLOW}  ! Falling back to local execution from hooks directory${NC}"
        DEPLOY_STATUS="${YELLOW}[GDeploy:Local]${NC}"
        rm -f "$DEPLOY_OUTPUT_LOG" "$VERIFY_CHECK_JSON"
        return 0
    fi
}

# Function to authenticate silently
authenticate() {
    # CHECK FIRST if already logged in (50s timeout)
    LOGIN_CHECK=$(run_command online-auth 50 check-login --json 2>/dev/null)
    IS_LOGGED_IN=$(parse_json "$LOGIN_CHECK" ".data.is_logged_in")

    if [ "$IS_LOGGED_IN" = "true" ]; then
        # Already logged in - store status
        AUTH_STATUS="${GREEN}[Auth:+]${NC}"
        return 0
    fi

    # NOT logged in - authenticate now (50s timeout)
    run_command online-auth 50 authenticate --relogin >/dev/null 2>&1

    # Verify it worked (50s timeout)
    LOGIN_CHECK=$(run_command online-auth 50 check-login --json 2>/dev/null)
    IS_LOGGED_IN=$(parse_json "$LOGIN_CHECK" ".data.is_logged_in")

    if [ "$IS_LOGGED_IN" = "true" ]; then
        AUTH_STATUS="${GREEN}[Auth:+]${NC}"
        return 0
    else
        # Failed - print error immediately
        echo -e "${RED}- Authentication FAILED - Not logged in${NC}"
        AUTH_STATUS="${RED}[Auth:-]${NC}"
        return 1
    fi
}

# Function to configure DNSCrypt
setup_dnscrypt() {
    # Check if this is first run - only force configuration on first boot
    # Detect hooks directory silently (function prints output, we just need the path)
    # Use a function-local copy of HOOKS_DIR so we never accidentally clobber
    # the global one set by detect_hooks_dir for the rest of the script.
    detect_hooks_dir >/dev/null 2>&1
    local _hooks_dir="${HOOKS_DIR:-${KODACHI_HOOKS_DIR:-${KODACHI_HOME:-/opt/kodachi/dashboard/hooks}}}"
    if ! verify_hooks_structure "$_hooks_dir"; then
        _hooks_dir="$REAL_HOME/dashboard/hooks"
    fi
    local DNS_MARKER="$_hooks_dir/results/dns-configured"
    local IS_FIRST_RUN=false

    if [ ! -f "$DNS_MARKER" ] || [ "$FORCE_DNS_SETUP" = "true" ]; then
        IS_FIRST_RUN=true
        if [ "$FORCE_DNS_SETUP" = "true" ]; then
            echo -e "${GREEN}+ Force DNS setup enabled - reconfiguring DNSCrypt${NC}"
        else
            echo -e "${GREEN}+ First boot detected - will configure DNSCrypt if needed${NC}"
        fi
    else
        echo -e "${CYAN}  • Not first boot - skipping DNSCrypt auto-configuration${NC}"
    fi

    local max_retries=3
    local retry_delay=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        if [ $attempt -gt 1 ]; then
            echo -e "${YELLOW}▸ Retrying DNS configuration (attempt $attempt/$max_retries)...${NC}"
            sleep $retry_delay
        fi

        # CRITICAL: Reset ALL DNS variables to ensure fresh detection after profile changes
        ACTUAL_DNS_MODE="Unknown"
        DNS_STATUS_MSG=""
        TOR_DNS_DIRECT_STATUS="unknown"
        TOR_DNS_PORT_STATUS="unknown"
        TOR_DNS_OVERALL_STATUS="false"
        TOR_DNS_DETAILED=""

        # STEP 1: Check ACTUAL current DNS (always, no caching)
        DNS_STATUS=$(run_command dns-switch 50 status --json 2>/dev/null)

        # Parse nameservers array
        if check_jq; then
            NAMESERVERS=$(echo "$DNS_STATUS" | jq -r '.data.nameservers[]' 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
        else
            # Fallback parsing without jq
            NAMESERVERS=$(echo "$DNS_STATUS" | grep -o '"nameservers":\[[^]]*\]' | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/,/, /g')
        fi

        # DEBUG: Show what nameservers we detected
        echo -e "${CYAN}  • Current nameservers: ${NAMESERVERS}${NC}"

        # Handle empty nameservers
        if [ -z "$NAMESERVERS" ]; then
            echo -e "${RED}  - Failed to detect DNS servers${NC}"
            ACTUAL_DNS_MODE="Unknown"
            DNS_STATUS_MSG="${RED}[SDNS:-]${NC}"
            # Don't return yet - will retry
            attempt=$((attempt + 1))
            continue
        fi

        # STEP 2: Smart DNSCrypt verification and auto-fix
        # Check if DNSCrypt is running but being bypassed by systemd-resolved

        # Get DNSCrypt service status
        DNSCRYPT_CHECK=$(run_command dns-switch 50 dnscrypt --json 2>/dev/null)
        SERVICE_ACTIVE=$(parse_json "$DNSCRYPT_CHECK" ".data.service_active")
        LISTENING=$(parse_json "$DNSCRYPT_CHECK" ".data.listening")
        CONFIGURED_AS_RESOLVER=$(parse_json "$DNSCRYPT_CHECK" ".data.configured_as_resolver")

        # Check if DNSCrypt is running AND listening but NOT configured as resolver - HIJACKED!
        if [ "$SERVICE_ACTIVE" = "true" ] && [ "$LISTENING" = "true" ] && [ "$CONFIGURED_AS_RESOLVER" != "true" ]; then
            # DNSCrypt is running but NOT configured as resolver - HIJACKED!
            echo -e "${YELLOW}! DNSCrypt is running but NOT configured as resolver (current DNS: $NAMESERVERS)${NC}"
            echo -e "${YELLOW}! Fixing DNSCrypt configuration...${NC}"

            # Re-configure DNSCrypt as resolver (dns-switch handles systemd-resolved automatically)
            echo -e "${YELLOW}  • Configuring DNSCrypt as DNS resolver...${NC}"
            run_command dns-switch 120 switch --names dnscrypt 2>&1 | tee "$DNS_SWITCH_LOG"
            local dns_switch_status=${PIPESTATUS[0]}
            propagate_signal_exit "$dns_switch_status"
            if [ "$dns_switch_status" -eq 0 ]; then
                echo -e "${GREEN}  + DNSCrypt configuration fixed${NC}"
            else
                echo -e "${RED}  - Failed to fix DNSCrypt (see $DNS_SWITCH_LOG)${NC}"
            fi
            sleep 2

            # Verify fix worked
            DNSCRYPT_CHECK=$(run_command dns-switch 50 dnscrypt --json 2>/dev/null)
            CONFIGURED_AS_RESOLVER=$(parse_json "$DNSCRYPT_CHECK" ".data.configured_as_resolver")

            if [ "$CONFIGURED_AS_RESOLVER" = "true" ]; then
                echo -e "${GREEN}  + DNSCrypt successfully configured as resolver${NC}"
            else
                echo -e "${RED}  - Failed to configure DNSCrypt as resolver${NC}"
            fi

            # Update NAMESERVERS for display
            DNS_STATUS=$(run_command dns-switch 50 status --json 2>/dev/null)
            if check_jq; then
                NAMESERVERS=$(echo "$DNS_STATUS" | jq -r '.data.nameservers[]' 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
            else
                NAMESERVERS=$(echo "$DNS_STATUS" | grep -o '"nameservers":\[[^]]*\]' | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '"' | sed 's/,/, /g')
            fi
        fi

        # STEP 3: Report actual DNS based on verification (always truthful, no caching)
        # This always runs, even on refresh, to detect DNS changes
        # Check for 127.0.0.1 and determine if it's Tor DNS or DNSCrypt
        if echo "$NAMESERVERS" | grep -q "127.0.0.1"; then
            echo -e "${CYAN}  • Detected 127.0.0.1 - checking if Tor DNS or DNSCrypt${NC}"
            # First check if this is Tor DNS by trying to verify it
            # Tor DNS uses port 9053, so verify-tor-dns will succeed if Tor DNS is active
            verify_tor_dns

            if [ "$TOR_DNS_OVERALL_STATUS" = "true" ]; then
                # Tor DNS is active and both methods successful - GREEN
                # Show detailed status only when fully working
                ACTUAL_DNS_MODE="(Tor DNS) ${TOR_DNS_DETAILED}"
                DNS_STATUS_MSG="${GREEN}[SDNS:Tor:++]${NC}"
                return 0
            fi

            # Tor DNS failed - don't show detailed breakdown, just show it's not working

            # Not Tor DNS or Tor DNS failed - check if it's DNSCrypt
            DNSCRYPT_CHECK=$(run_command dns-switch 50 dnscrypt --json 2>/dev/null)
            DNSCRYPT_STATUS=$(parse_json "$DNSCRYPT_CHECK" ".data.status")
            SERVICE_ACTIVE=$(parse_json "$DNSCRYPT_CHECK" ".data.service_active")
            CONFIGURED_AS_RESOLVER=$(parse_json "$DNSCRYPT_CHECK" ".data.configured_as_resolver")
            LISTENING=$(parse_json "$DNSCRYPT_CHECK" ".data.listening")

            # DEBUG: Show DNSCrypt status
            echo -e "${CYAN}  • DNSCrypt: status=$DNSCRYPT_STATUS, active=$SERVICE_ACTIVE, set_as_resolver=$CONFIGURED_AS_RESOLVER, listening=$LISTENING${NC}"

            if [ "$DNSCRYPT_STATUS" = "success" ] && \
               [ "$SERVICE_ACTIVE" = "true" ] && \
               [ "$CONFIGURED_AS_RESOLVER" = "true" ] && \
               [ "$LISTENING" = "true" ]; then
                # DNSCrypt is fully operational
                echo -e "${GREEN}  + DNSCrypt is fully operational${NC}"

                # Create marker file if it doesn't exist
                if [ ! -f "$DNS_MARKER" ]; then
                    mkdir -p "$(dirname "$DNS_MARKER")"
                    touch "$DNS_MARKER"
                fi

                ACTUAL_DNS_MODE="127.0.0.1 (DNSCrypt)"
                DNS_STATUS_MSG="${GREEN}[SDNS:+]${NC}"
                return 0
            else
                # 127.0.0.1 configured but DNSCrypt not fully operational
                # Check if DNSCrypt is configured but service not running
                if [ "$SERVICE_ACTIVE" = "false" ] && [ "$CONFIGURED_AS_RESOLVER" = "true" ]; then
                    if [ "$IS_FIRST_RUN" = "true" ]; then
                        # FIRST BOOT - Auto-start DNSCrypt
                        echo -e "${YELLOW}! DNSCrypt configured but not running - starting service (first boot)...${NC}"
                        echo -e "${YELLOW}  • Starting DNSCrypt service...${NC}"

                        run_command dns-switch 120 switch --names dnscrypt 2>&1 | tee -a "$DNS_SWITCH_LOG"
                        local dns_switch_status=${PIPESTATUS[0]}
                        propagate_signal_exit "$dns_switch_status"
                        if [ "$dns_switch_status" -eq 0 ]; then
                            echo -e "${GREEN}  + DNSCrypt service started${NC}"
                        else
                            echo -e "${RED}  - Failed to start DNSCrypt (see $DNS_SWITCH_LOG)${NC}"
                        fi
                        sleep 3

                        # Retry to verify it worked
                        attempt=$((attempt + 1))
                        continue
                    else
                        # SUBSEQUENT BOOT - Do not auto-start, just report
                        echo -e "${CYAN}  • DNSCrypt service is stopped (not first boot - skipping auto-start)${NC}"
                        ACTUAL_DNS_MODE="127.0.0.1 (DNSCrypt stopped)"
                        DNS_STATUS_MSG="${RED}[SDNS:Stopped]${NC}"
                        return 0
                    fi
                else
                    # Some other DNSCrypt issue (not just stopped service)
                    ACTUAL_DNS_MODE="127.0.0.1 (service not running)"
                    DNS_STATUS_MSG="${RED}[SDNS:-]${NC}"
                    # Don't return yet - will retry
                    attempt=$((attempt + 1))
                    continue
                fi
            fi
        else
            # NAMESERVERS is not 127.0.0.1 - check if DNSCrypt service is running
            echo -e "${CYAN}  • Nameservers NOT 127.0.0.1 - checking if DNSCrypt service is running${NC}"

            # If DNSCrypt is running but not configured as resolver yet, RETRY
            DNSCRYPT_CHECK=$(run_command dns-switch 30 dnscrypt --json 2>/dev/null)
            SERVICE_ACTIVE=$(parse_json "$DNSCRYPT_CHECK" ".data.service_active")
            LISTENING=$(parse_json "$DNSCRYPT_CHECK" ".data.listening")
            CONFIGURED_AS_RESOLVER=$(parse_json "$DNSCRYPT_CHECK" ".data.configured_as_resolver")

            echo -e "${CYAN}  • DNSCrypt: active=$SERVICE_ACTIVE, listening=$LISTENING, set_as_resolver=$CONFIGURED_AS_RESOLVER${NC}"

            if [ "$SERVICE_ACTIVE" = "false" ]; then
                if [ "$IS_FIRST_RUN" = "true" ]; then
                    # FIRST BOOT - Auto-start DNSCrypt
                    echo -e "${YELLOW}! DNSCrypt service is not running - starting service (first boot)...${NC}"

                    # Start and configure DNSCrypt service
                    echo -e "${YELLOW}  • Starting DNSCrypt service and setting as resolver...${NC}"
                    run_command dns-switch 120 switch --names dnscrypt 2>&1 | tee -a "$DNS_SWITCH_LOG"
                    local dns_switch_status=${PIPESTATUS[0]}
                    propagate_signal_exit "$dns_switch_status"
                    if [ "$dns_switch_status" -eq 0 ]; then
                        echo -e "${GREEN}  + DNSCrypt service started and configured${NC}"
                    else
                        echo -e "${RED}  - Failed to start DNSCrypt (see $DNS_SWITCH_LOG)${NC}"
                    fi
                    sleep 3

                    # Create marker file to indicate DNS has been configured
                    mkdir -p "$(dirname "$DNS_MARKER")"
                    touch "$DNS_MARKER"

                    # Retry to verify it worked
                    attempt=$((attempt + 1))
                    continue
                else
                    # SUBSEQUENT BOOT - Do not auto-start, just report and check alternatives
                    echo -e "${CYAN}  • DNSCrypt service is stopped (not first boot - skipping auto-start)${NC}"

                    # Check if Tor DNS is available as alternative
                    echo -e "${CYAN}  • Checking if Tor DNS is available...${NC}"
                    verify_tor_dns

                    if [ "$TOR_DNS_OVERALL_STATUS" = "true" ]; then
                        # Tor DNS is working - show it with green status
                        ACTUAL_DNS_MODE="(Tor DNS) ${TOR_DNS_DETAILED}"
                        DNS_STATUS_MSG="${GREEN}[SDNS:Tor:++]${NC}"
                        return 0
                    else
                        # No Tor DNS - show actual DNS servers
                        ACTUAL_DNS_MODE="$NAMESERVERS"
                        DNS_STATUS_MSG="${YELLOW}[SDNS:Direct]${NC}"
                        return 0
                    fi
                fi
            elif [ "$SERVICE_ACTIVE" = "true" ] && [ "$LISTENING" = "true" ] && [ "$CONFIGURED_AS_RESOLVER" != "true" ]; then
                # DNSCrypt running but not set as resolver - AUTO-RECOVER by setting it
                echo -e "${YELLOW}! DNSCrypt running but not set as resolver (DNS: $NAMESERVERS)${NC}"
                echo -e "${YELLOW}! Auto-recovering by setting DNSCrypt as system resolver...${NC}"

                # Set DNSCrypt as system resolver
                echo -e "${YELLOW}  • Configuring DNSCrypt resolver...${NC}"
                run_command dns-switch 120 switch --names dnscrypt 2>&1 | tee -a "$DNS_SWITCH_LOG"
                local dns_switch_status=${PIPESTATUS[0]}
                propagate_signal_exit "$dns_switch_status"
                if [ "$dns_switch_status" -eq 0 ]; then
                    echo -e "${GREEN}  + DNSCrypt resolver configured${NC}"
                else
                    echo -e "${RED}  - Failed to configure DNSCrypt resolver (see $DNS_SWITCH_LOG)${NC}"
                fi
                sleep 2

                # Create marker file
                mkdir -p "$(dirname "$DNS_MARKER")"
                touch "$DNS_MARKER"

                # Retry to verify it worked
                attempt=$((attempt + 1))
                continue
            elif [ "$SERVICE_ACTIVE" = "true" ] && [ "$LISTENING" = "true" ] && [ "$CONFIGURED_AS_RESOLVER" = "true" ]; then
                # Service running, listening, AND set as resolver but nameservers not 127.0.0.1 yet - wait and retry
                echo -e "${YELLOW}! DNSCrypt set as resolver but nameservers not updated yet - retrying...${NC}"
                sleep 2
                attempt=$((attempt + 1))
                continue
            else
                # Something else wrong - retry
                echo -e "${YELLOW}! DNSCrypt in unexpected state - retrying...${NC}"
                attempt=$((attempt + 1))
                continue
            fi
        fi
    done

    # All retries exhausted - DNSCrypt configuration failed
    echo -e "${RED}- DNSCrypt configuration failed after $max_retries attempts${NC}"
    ACTUAL_DNS_MODE="Unknown"
    DNS_STATUS_MSG="${RED}[SDNS:-]${NC}"
    return 1
}

setup_dnscrypt_locked() {
    with_dns_lock setup_dnscrypt
}

print_dns_setup_result() {
    if [[ "$DNS_STATUS_MSG" == *"SDNS:+"* ]] || [[ "$DNS_STATUS_MSG" == *"SDNS:Tor:++"* ]]; then
        echo -e " ${GREEN}+ DNSCrypt configured${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    elif [[ "$DNS_STATUS_MSG" == *"SDNS:Stopped"* ]]; then
        echo -e " ${YELLOW}! DNSCrypt not started${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    elif [[ "$DNS_STATUS_MSG" == *"SDNS:Direct"* ]]; then
        echo -e " ${YELLOW}! DNSCrypt unchanged - direct DNS remains active${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    else
        echo -e " ${RED}! DNSCrypt setup failed${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    fi
}

# Function to verify Tor DNS at firewall level using which-is-active
verify_tor_dns_firewall() {
    # Reset firewall verification variables
    TOR_DNS_FIREWALL_STATUS="unknown"
    TOR_DNS_FIREWALL_BACKEND="none"
    TOR_DNS_FIREWALL_VERIFIED="false"

    # Call tor-switch which-is-active with 60s timeout
    local FIREWALL_JSON=$(run_command tor-switch 60 which-is-active --json 2>/dev/null)

    # Parse firewall status
    local ACTIVE_FIREWALL="none"
    local TOR_DNS_IPTABLES="false"
    local TOR_DNS_NFTABLES="false"
    local SERVICE_REPORTED="false"
    local INDEPENDENT_CHECKED="false"
    local INDEPENDENT_VERIFIED="false"
    local INDEPENDENT_BACKEND="none"

    if check_jq; then
        ACTIVE_FIREWALL=$(echo "$FIREWALL_JSON" | jq -r '.data.active_firewall // "none"' 2>/dev/null)
        TOR_DNS_IPTABLES=$(echo "$FIREWALL_JSON" | jq -r '.data.tor_dns_iptables // false' 2>/dev/null)
        TOR_DNS_NFTABLES=$(echo "$FIREWALL_JSON" | jq -r '.data.tor_dns_nftables // false' 2>/dev/null)
    else
        # Fallback parsing without jq
        ACTIVE_FIREWALL=$(parse_json "$FIREWALL_JSON" ".data.active_firewall" || echo "none")
        TOR_DNS_IPTABLES=$(parse_json "$FIREWALL_JSON" ".data.tor_dns_iptables" || echo "false")
        TOR_DNS_NFTABLES=$(parse_json "$FIREWALL_JSON" ".data.tor_dns_nftables" || echo "false")
    fi

    # Record service-reported state
    if [ "$TOR_DNS_IPTABLES" = "true" ] || [ "$TOR_DNS_NFTABLES" = "true" ]; then
        SERVICE_REPORTED="true"
    fi

    # Independent iptables verification (only if command is readable with sudo -n)
    if command -v iptables >/dev/null 2>&1; then
        local iptables_ruleset=""
        if iptables_ruleset=$(sudo -n iptables -t nat -S 2>/dev/null); then
            INDEPENDENT_CHECKED="true"
            if echo "$iptables_ruleset" | grep -Eq 'dport[[:space:]]+53.*9053|--dport[[:space:]]+53.*--to-ports[[:space:]]+9053|REDIRECT.*9053'; then
                INDEPENDENT_VERIFIED="true"
                INDEPENDENT_BACKEND="iptables"
            fi
        fi
    fi

    # Independent nftables verification (only if command is readable with sudo -n)
    if command -v nft >/dev/null 2>&1; then
        local nft_ruleset=""
        if nft_ruleset=$(sudo -n nft list ruleset 2>/dev/null); then
            INDEPENDENT_CHECKED="true"
            if echo "$nft_ruleset" | grep -Eq 'dport[[:space:]]+53.*9053|9053.*dport[[:space:]]+53'; then
                INDEPENDENT_VERIFIED="true"
                INDEPENDENT_BACKEND="nftables"
            fi
        fi
    fi

    # Prefer independent verification when available; otherwise fallback to service report.
    if [ "$INDEPENDENT_CHECKED" = "true" ]; then
        if [ "$INDEPENDENT_VERIFIED" = "true" ]; then
            TOR_DNS_FIREWALL_VERIFIED="true"
            TOR_DNS_FIREWALL_STATUS="active"
            TOR_DNS_FIREWALL_BACKEND="$INDEPENDENT_BACKEND"
            if [ "$SERVICE_REPORTED" != "true" ]; then
                echo -e "${YELLOW}  ! Firewall rules detected but tor-switch reports inactive${NC}"
            fi
            return 0
        fi

        TOR_DNS_FIREWALL_VERIFIED="false"
        TOR_DNS_FIREWALL_STATUS="inactive"
        TOR_DNS_FIREWALL_BACKEND="$ACTIVE_FIREWALL"
        if [ "$SERVICE_REPORTED" = "true" ]; then
            echo -e "${YELLOW}  ! tor-switch reports Tor DNS active but independent firewall check found no matching rules${NC}"
        fi
        return 1
    fi

    TOR_DNS_FIREWALL_BACKEND="$ACTIVE_FIREWALL"
    if [ "$SERVICE_REPORTED" = "true" ]; then
        TOR_DNS_FIREWALL_VERIFIED="true"
        TOR_DNS_FIREWALL_STATUS="active"
        return 0
    fi

    TOR_DNS_FIREWALL_VERIFIED="false"
    TOR_DNS_FIREWALL_STATUS="inactive"
    return 1
}

# Function to verify Tor DNS with both direct and port methods
# Enhanced with dual-layer verification: functional + firewall confirmation
verify_tor_dns() {
    echo -e "${YELLOW}  • Verifying Tor DNS configuration...${NC}"

    # Reset global variables to ensure fresh verification
    TOR_DNS_DIRECT_STATUS="unknown"
    TOR_DNS_PORT_STATUS="unknown"
    TOR_DNS_OVERALL_STATUS="false"
    TOR_DNS_DETAILED=""

    local max_retries=3
    local retry_count=0
    local functional_verified=false
    local firewall_verified=false

    # First, check firewall status (quick check)
    verify_tor_dns_firewall
    if [ "$TOR_DNS_FIREWALL_VERIFIED" = "true" ]; then
        firewall_verified=true
        echo -e "${GREEN}  + Firewall confirms Tor DNS is configured ($TOR_DNS_FIREWALL_BACKEND)${NC}"
    else
        echo -e "${CYAN}  • Firewall shows Tor DNS is not configured${NC}"
        # OPTIMIZATION: Skip functional verification if no firewall rules exist
        # No point running expensive DNS queries when rules aren't configured
        echo -e "${CYAN}  • Skipping functional verification (no firewall rules detected)${NC}"
        TOR_DNS_OVERALL_STATUS="false"
        TOR_DNS_DETAILED=""
        return 1
    fi

    # Perform functional verification with retry logic if firewall shows it should work
    while [ $retry_count -lt $max_retries ]; do
        # Call tor-switch verify-tor-dns with 60s timeout
        local TOR_DNS_JSON=$(run_command tor-switch 60 verify-tor-dns --json 2>/dev/null)

        # Parse direct_method and port_method (boolean values)
        if check_jq; then
            TOR_DNS_DIRECT_STATUS=$(echo "$TOR_DNS_JSON" | jq -r '.data.direct_method // "unknown"' 2>/dev/null)
            TOR_DNS_PORT_STATUS=$(echo "$TOR_DNS_JSON" | jq -r '.data.port_method // "unknown"' 2>/dev/null)
        else
            # Fallback parsing without jq
            TOR_DNS_DIRECT_STATUS=$(parse_json "$TOR_DNS_JSON" ".data.direct_method" || echo "unknown")
            TOR_DNS_PORT_STATUS=$(parse_json "$TOR_DNS_JSON" ".data.port_method" || echo "unknown")
        fi

        # Convert boolean values to consistent format
        if [ "$TOR_DNS_DIRECT_STATUS" = "true" ]; then
            TOR_DNS_DIRECT_STATUS="success"
        else
            TOR_DNS_DIRECT_STATUS="failed"
        fi

        if [ "$TOR_DNS_PORT_STATUS" = "true" ]; then
            TOR_DNS_PORT_STATUS="success"
        else
            TOR_DNS_PORT_STATUS="failed"
        fi

        # Check if functional verification passed
        if [ "$TOR_DNS_DIRECT_STATUS" = "success" ] && [ "$TOR_DNS_PORT_STATUS" = "success" ]; then
            functional_verified=true
            break
        fi

        # Retry logic: only retry if firewall shows Tor DNS should be working
        if [ "$firewall_verified" = true ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo -e "${YELLOW}  • Functional verification failed, retrying ($retry_count/$max_retries)...${NC}"
                sleep 2
            fi
        else
            # No point retrying if firewall doesn't show Tor DNS configured
            break
        fi
    done

    # CONSERVATIVE APPROACH: Both functional and firewall verification must pass
    if [ "$functional_verified" = true ] && [ "$firewall_verified" = true ]; then
        TOR_DNS_OVERALL_STATUS="true"
        TOR_DNS_DETAILED="[Direct:+ Port:+]"
        echo -e "${GREEN}  + Tor DNS is active (dual-layer verified)${NC}"
        return 0
    elif [ "$functional_verified" = true ] && [ "$firewall_verified" = false ]; then
        # Functional test passed but firewall doesn't confirm - likely false positive
        TOR_DNS_OVERALL_STATUS="false"
        TOR_DNS_DETAILED=""
        echo -e "${YELLOW}  ! Tor DNS functional test passed but firewall not configured${NC}"
        return 1
    elif [ "$functional_verified" = false ] && [ "$firewall_verified" = true ]; then
        # Firewall configured but functional test failed - service may not be ready
        TOR_DNS_OVERALL_STATUS="false"
        TOR_DNS_DETAILED=""
        echo -e "${YELLOW}  ! Tor DNS firewall configured but functional test failed${NC}"
        return 1
    else
        # Both failed - Tor DNS is definitely not active
        TOR_DNS_OVERALL_STATUS="false"
        TOR_DNS_DETAILED=""
        echo -e "${CYAN}  • Tor DNS not detected (both verifications failed)${NC}"
        return 1
    fi
}

# Function to count profiles
count_profiles() {
    # Only count if hooks directory exists
    if [ -n "$HOOKS_DIR" ] && [ -d "$HOOKS_DIR/config/profiles" ]; then
        local count=$(ls -1 "$HOOKS_DIR/config/profiles"/*.json 2>/dev/null | wc -l)
        PROFILE_COUNT="Profiles: ${GREEN}${count}${NC}"
        PROFILE_COUNT_RAW="$count"
    else
        # Hooks directory not found - show N/A (normal for ISO users)
        PROFILE_COUNT="Profiles: ${GREEN}N/A${NC}"
        PROFILE_COUNT_RAW="0"
    fi
}

# Function to count log files
count_logs() {
    # Only count if hooks directory exists
    if [ -n "$HOOKS_DIR" ] && [ -d "$HOOKS_DIR/logs" ]; then
        # Count only FILES, not folders
        local count=$(find "$HOOKS_DIR/logs" -maxdepth 1 -type f 2>/dev/null | wc -l)
        LOGS_COUNT="Logs: ${GREEN}${count}${NC}"
    else
        # Hooks directory not found - show N/A (normal for ISO users)
        LOGS_COUNT="Logs: ${GREEN}N/A${NC}"
    fi
}

# Function to count binaries
count_binaries() {
    # Only count if hooks directory exists
    if [ -n "$HOOKS_DIR" ] && [ -d "$HOOKS_DIR" ]; then
        # Count executable binary files in hooks directory (actual deployed binaries)
        local count=$(find "$HOOKS_DIR" -maxdepth 1 -type f -executable ! -name "*.sh" ! -name ".*" 2>/dev/null | wc -l)
        # The OS release and the hook binaries can carry different versions on an
        # updated install (measured 2026-09-06: 9.0.1 OS with <lab-host> hooks), so show
        # the binary version here where the count already comes from the hooks dir.
        local hook_version=""
        if [ -x "$HOOKS_DIR/health-control" ]; then
            hook_version=$("$HOOKS_DIR/health-control" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
        if [ -n "$hook_version" ]; then
            BINARIES_COUNT="Binaries: ${GREEN}${count}${NC} (v${hook_version})"
        else
            BINARIES_COUNT="Binaries: ${GREEN}${count}${NC}"
        fi
    else
        # Hooks directory not found - show N/A (normal for ISO users)
        BINARIES_COUNT="Binaries: ${GREEN}N/A${NC}"
    fi
}

# Function to check permission guard status
check_permission_guard() {
    local PERM_JSON=$(run_command permission-guard 30 status --json 2>/dev/null)
    local STATUS=$(parse_json "$PERM_JSON" ".data.status" || echo "")

    if [ "$STATUS" = "ok" ]; then
        PERM_GUARD_STATUS="${GREEN}[PermG:+]${NC}"
    else
        PERM_GUARD_STATUS="${RED}[PermG:-]${NC}"
    fi
}

# Function to fetch latest version and compare with local build
fetch_latest_version() {
    local RELEASE_JSON=$(run_command online-info-switch 60 releases --json 2>/dev/null)
    local MAIN_VERSION=$(parse_json "$RELEASE_JSON" ".terminal.main_version" || echo "N/A")
    local NIGHTLY_VERSION=$(parse_json "$RELEASE_JSON" ".terminal.nightly_version" || echo "")

    # Local vs Remote comparison
    local LOCAL_BUILD="${SCRIPT_VERSION}"  # e.g., "9.0.1.4" (embedded in script)
    local REMOTE_BUILD="${NIGHTLY_VERSION:-$MAIN_VERSION}"  # Prefer nightly, fallback to main

    # Version comparison and status
    local VERSION_STATUS=""
    local VERSION_COLOR="${GREEN}"

    # Compare versions if remote data is available
    if [ "$REMOTE_BUILD" != "N/A" ] && [ -n "$REMOTE_BUILD" ] && [ "$REMOTE_BUILD" != "null" ]; then
        # Full version comparison across all octets (e.g., 9.0.1.4 vs 9.1.0.1)
        # Compares major, minor, patch, then build number sequentially
        local _ver_result="equal"
        local _i
        for _i in 1 2 3 4; do
            local _local_part=$(echo "$LOCAL_BUILD" | awk -F'.' -v i="$_i" '{print $i}')
            local _remote_part=$(echo "$REMOTE_BUILD" | awk -F'.' -v i="$_i" '{print $i}')
            _local_part="${_local_part:-0}"
            _remote_part="${_remote_part:-0}"
            if [[ "$_local_part" =~ ^[0-9]+$ ]] && [[ "$_remote_part" =~ ^[0-9]+$ ]]; then
                if [ "$_local_part" -gt "$_remote_part" ]; then
                    _ver_result="ahead"; break
                elif [ "$_local_part" -lt "$_remote_part" ]; then
                    _ver_result="behind"; break
                fi
            else
                _ver_result="unknown"; break
            fi
        done

        case "$_ver_result" in
            equal|ahead)
                VERSION_STATUS="+"  # Up-to-date or ahead
                VERSION_COLOR="${GREEN}"
                ;;
            behind)
                VERSION_STATUS="^"  # Update available
                VERSION_COLOR="${YELLOW}"
                ;;
            *)
                VERSION_STATUS="•"  # Cannot compare (fallback)
                VERSION_COLOR="${GREEN}"
                ;;
        esac

        # Build comparison display string - compact format to save space
        LATEST_VERSION="${VERSION_COLOR}${VERSION_STATUS} Build: ${LOCAL_BUILD} | ${REMOTE_BUILD}${NC}"
    else
        # Offline or API unavailable
        LATEST_VERSION="Build: ${GREEN}${LOCAL_BUILD}${NC} | ${RED}Offline${NC}"
    fi
}

# Function to fetch cryptocurrency prices
fetch_crypto_prices() {
    local CRYPTO_JSON=$(run_command online-info-switch 60 price all --json 2>/dev/null)

    if check_jq && [ -n "$CRYPTO_JSON" ]; then
        local BTC=$(echo "$CRYPTO_JSON" | jq -r '.prices[] | select(.coin=="BTC") | .price_usd' 2>/dev/null | cut -d. -f1 || echo "N/A")
        local ETH=$(echo "$CRYPTO_JSON" | jq -r '.prices[] | select(.coin=="ETH") | .price_usd' 2>/dev/null | cut -d. -f1 || echo "N/A")
        local XMR=$(echo "$CRYPTO_JSON" | jq -r '.prices[] | select(.coin=="XMR") | .price_usd' 2>/dev/null | cut -d. -f1 || echo "N/A")
        local AZERO=$(echo "$CRYPTO_JSON" | jq -r '.prices[] | select(.coin=="AZERO") | .price_usd' 2>/dev/null || echo "N/A")

        # Format AZERO to 2 decimal places if numeric
        if [[ "$AZERO" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            AZERO=$(printf "%.2f" "$AZERO")
        fi

        CRYPTO_PRICES="${BOLD}BTC:${NC} ${GREEN}\$${BTC}${NC} | ${BOLD}ETH:${NC} ${GREEN}\$${ETH}${NC} | ${BOLD}XMR:${NC} ${GREEN}\$${XMR}${NC} | ${BOLD}AZERO:${NC} ${GREEN}\$${AZERO}${NC}"
    else
        CRYPTO_PRICES="${YELLOW}Crypto prices unavailable${NC}"
    fi
}

# Function to fetch news headlines
fetch_news_headlines() {
    local MAX_RETRIES=3
    local retry_count=0
    local HEADLINE1=""
    local HEADLINE2=""
    local NEWS_JSON=""

    # Retry loop to handle empty/failed RSS feeds
    while [ $retry_count -lt $MAX_RETRIES ]; do
        NEWS_JSON=$(run_command online-info-switch 50 rss --random --max-items 2 --json 2>/dev/null)

        if check_jq && [ -n "$NEWS_JSON" ]; then
            # Get first 2 headlines and add ellipsis if truncated (max 71 chars + "...")
            HEADLINE1=$(echo "$NEWS_JSON" | jq -r '.items[0].title' 2>/dev/null || echo "")
            HEADLINE2=$(echo "$NEWS_JSON" | jq -r '.items[1].title' 2>/dev/null || echo "")

            # Truncate with ellipsis if too long
            if [ -n "$HEADLINE1" ] && [ "$HEADLINE1" != "null" ]; then
                if [ ${#HEADLINE1} -gt 71 ]; then
                    HEADLINE1="${HEADLINE1:0:71}..."
                fi
            fi

            if [ -n "$HEADLINE2" ] && [ "$HEADLINE2" != "null" ]; then
                if [ ${#HEADLINE2} -gt 71 ]; then
                    HEADLINE2="${HEADLINE2:0:71}..."
                fi
            fi

            # Check if we got at least one valid headline
            if [ -n "$HEADLINE1" ] && [ "$HEADLINE1" != "null" ]; then
                # Success - we have valid news
                break
            fi
        fi

        # No valid headlines - retry
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            sleep 1  # Wait 1 second before retry
        fi
    done

    # Set final NEWS_HEADLINES based on result
    if [ -n "$HEADLINE1" ] && [ "$HEADLINE1" != "null" ]; then
        NEWS_HEADLINES="${BOLD}•${NC} ${GREEN}${HEADLINE1}${NC}"
        if [ -n "$HEADLINE2" ] && [ "$HEADLINE2" != "null" ]; then
            NEWS_HEADLINES="${NEWS_HEADLINES}\n${BOLD}•${NC} ${GREEN}${HEADLINE2}${NC}"
        fi
    else
        NEWS_HEADLINES="${YELLOW}No news available${NC}"
    fi
}

# Function to fetch and parse system information
fetch_system_info() {
    # SYSTEM INFORMATION section
    print_section_header "SYSTEM INFORMATION"

    if [ "$HAS_INTERNET" = "true" ]; then
        # Fetch IP information (60s timeout for Tor-friendly operation)
        echo -ne "${YELLOW}▸ Fetching IP geolocation...${NC}"
        start_timer
        IP_JSON=$(run_command ip-fetch 60 --json 2>/dev/null | tail -1)
        IP_ADDR=$(parse_json "$IP_JSON" ".data.records[0].ip" || echo "N/A")
        COUNTRY=$(parse_json "$IP_JSON" ".data.records[0].country_name" || echo "N/A")
        CITY=$(parse_json "$IP_JSON" ".data.records[0].city" || echo "N/A")
        FLAG=$(parse_json "$IP_JSON" ".data.records[0].flag" || echo "")
        end_timer
        echo -e " ${GREEN}+ IP location retrieved${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

        # Fetch Tor status with dynamic color (60s timeout)
        echo -ne "${YELLOW}▸ Checking Tor connection...${NC}"
        start_timer
        TOR_CHECK=$(run_command ip-fetch 60 check-tor --json 2>/dev/null)
        IS_TOR=$(parse_json "$TOR_CHECK" ".IsTor" || echo "false")
        if [ "$IS_TOR" = "true" ]; then
            TOR_STATUS="${GREEN}+ Tor${NC}"       # Bright green when using Tor
        else
            TOR_STATUS="${RED}- Direct${NC}"      # Red when NOT using Tor
        fi
        end_timer
        echo -e " ${GREEN}+ Tor status confirmed${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

        # Fetch network connection status (50s timeout)
        # Bright green for VPN, RED for no VPN
        echo -ne "${YELLOW}▸ Checking VPN status...${NC}"
        start_timer
        ROUTING_JSON=$(run_command routing-switch 50 status --json 2>/dev/null)
        CONNECTED=$(parse_json "$ROUTING_JSON" ".data.connected" || echo "false")
        PROTOCOL=$(parse_json "$ROUTING_JSON" ".data.protocol" || echo "none")
        # 2026-05-24: routing-switch status now also carries provider_name +
        # connection_source (kodachi | provider:<id>) when raised via the
        # providers panel. Surface it: "wireguard via Mullvad" beats bare
        # "wireguard" when the user has multiple VPN paths.
        VPN_SOURCE=$(parse_json "$ROUTING_JSON" ".data.connection_source" || echo "")
        VPN_PROVIDER_NAME=$(parse_json "$ROUTING_JSON" ".data.provider_name" || echo "")
        if [ "$CONNECTED" = "true" ]; then
            if [ -n "$VPN_PROVIDER_NAME" ] && [ "$VPN_PROVIDER_NAME" != "null" ]; then
                NET_STATUS="${GREEN}${PROTOCOL} via ${VPN_PROVIDER_NAME}${NC}"
            elif [ "$VPN_SOURCE" = "kodachi" ]; then
                NET_STATUS="${GREEN}${PROTOCOL} (Kodachi)${NC}"
            else
                NET_STATUS="${GREEN}${PROTOCOL}${NC}"  # Bright green for VPN
            fi
        else
            NET_STATUS="${RED}No VPN${NC}"
        fi
        end_timer
        echo -e " ${GREEN}+ VPN status retrieved${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

        # Check Kodachi Network status (5s timeout - quick check)
        echo -ne "${YELLOW}▸ Checking Kodachi Network...${NC}"
        start_timer
        local curl_cert_args=()
        if [ -n "$HOOKS_DIR" ] && [ -f "$HOOKS_DIR/tmp/kodachi-cert-bundle.pem" ]; then
            curl_cert_args=(--cacert "$HOOKS_DIR/tmp/kodachi-cert-bundle.pem")
        elif [ -f "/etc/kodachi/kodachi-cert-bundle.pem" ]; then
            curl_cert_args=(--cacert "/etc/kodachi/kodachi-cert-bundle.pem")
        fi
        KNET_JSON=$(curl -s --max-time 5 "${curl_cert_args[@]}" "https://kodachi.cloud/apps/ip-extract.php" 2>/dev/null)
        IS_KODACHI=$(parse_json "$KNET_JSON" ".is_kodachi" || echo "false")
        if [ "$IS_KODACHI" = "true" ]; then
            KNET_STATUS="${GREEN}[KNet:+]${NC}"
        else
            KNET_STATUS="${RED}[KNet:-]${NC}"
        fi
        end_timer
        echo -e " ${GREEN}+ KNet status checked${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    else
        # Offline mode - set placeholders
        echo -e "${YELLOW}⊘ Skipping IP geolocation (offline mode)${NC}"
        echo -e "${YELLOW}⊘ Skipping Tor connection check (offline mode)${NC}"
        echo -e "${YELLOW}⊘ Skipping VPN status check (offline mode)${NC}"

        IP_ADDR="${YELLOW}Offline${NC}"
        COUNTRY="${YELLOW}N/A${NC}"
        CITY="${YELLOW}N/A${NC}"
        FLAG=""
        TOR_STATUS="${YELLOW}⊘ N/A${NC}"
        NET_STATUS="${YELLOW}Offline${NC}"
        KNET_STATUS="${YELLOW}[KNet:?]${NC}"
    fi

    # SECURITY VERIFICATION section (always runs - local operations)
    print_section_header "SECURITY VERIFICATION"

    # Fetch hardening verification (50s timeout)
    echo -ne "${YELLOW}▸ Verifying system hardening...${NC}"
    start_timer
    HARDENING_JSON=$(run_command health-control 50 security-verify --json 2>/dev/null)
    if check_jq; then
        HARDENED=$(echo "$HARDENING_JSON" | jq '[.data.modules[] | select(.hardening_status == "hardened")] | length' 2>/dev/null || echo "?")
        TOTAL=$(echo "$HARDENING_JSON" | jq '.data.modules | length' 2>/dev/null || echo "?")
    else
        HARDENED="?"
        TOTAL="?"
    fi
    HARDENING_STATUS="${HARDENED}/${TOTAL} Modules"
    end_timer
    echo -e " ${GREEN}+ Hardening verified${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Fetch security score (50s timeout)
    echo -ne "${YELLOW}▸ Calculating security score...${NC}"
    start_timer
    SCORE_JSON=$(run_command health-control 50 security-score --json 2>/dev/null)
    # `.data.total_score` is a RAW weighted point total measured against
    # health-control's ADAPTIVE maximum (81 on a live ISO / legacy BIOS, 100 on an
    # installed EFI box): checks that cannot physically apply are dropped from the
    # denominator instead of failed. This value is printed below as "<score>/100"
    # and colour-coded against percentage bands, so it must be the normalised
    # percentage, not the raw total (43.8 of an applicable 81 is 54%, not 44%).
    # `.data.percentage` is exactly that figure. Fall back to the raw total only if
    # an older health-control does not publish it.
    SEC_SCORE=$(parse_json "$SCORE_JSON" ".data.percentage" || echo "")
    if [ -z "$SEC_SCORE" ] || [ "$SEC_SCORE" = "null" ]; then
        SEC_SCORE=$(parse_json "$SCORE_JSON" ".data.total_score" || echo "N/A")
    fi
    SEC_STATUS=$(parse_json "$SCORE_JSON" ".data.security_level" || echo "UNKNOWN")
    end_timer
    echo -e " ${GREEN}+ Score calculated${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Fetch hostname, timezone, and MAC (30s timeout - local calls)
    echo -ne "${YELLOW}▸ Reading system configuration...${NC}"
    start_timer
    HOST_JSON=$(run_command health-control 30 get-hostname --json 2>/dev/null)
    HOSTNAME=$(parse_json "$HOST_JSON" ".data.hostname" || echo "N/A")

    TZ_JSON=$(run_command health-control 30 show-timezone --json 2>/dev/null)
    TIMEZONE=$(parse_json "$TZ_JSON" ".data.timezone" || echo "N/A")

    MAC_JSON=$(run_command health-control 30 mac-show-macs --json 2>/dev/null)
    MAC_ADDR=$(parse_json "$MAC_JSON" ".data.interfaces[0].mac_address" || echo "N/A")
    end_timer
    echo -e " ${GREEN}+ Configuration loaded${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Store status. Three states, never one unconditional green: offline is reported as
    # offline with the same marker the auth and DNS pills use, a failed lookup while online
    # is red, and green means an address was actually retrieved.
    if [ "$HAS_INTERNET" != "true" ]; then
        INFO_STATUS="${YELLOW}[Net:⊘]${NC}"
    elif [ -z "$IP_ADDR" ] || [ "$IP_ADDR" = "N/A" ] || [ "$IP_ADDR" = "null" ]; then
        INFO_STATUS="${RED}[Net:-]${NC}"
    else
        INFO_STATUS="${GREEN}[Net:+]${NC}"
    fi
}

# Function to detect boot mode (UEFI or Legacy BIOS)
detect_boot_mode() {
    # Check if running in UEFI mode
    if [ -d /sys/firmware/efi ]; then
        echo "UEFI"
    else
        echo "Legacy"
    fi
}

health_control_reports_encryption() {
    local encryption_json="$1"

    [ -n "$encryption_json" ] || return 1

    if check_jq; then
        jq -e '
            (.data.system_encrypted // false) or
            (.data.full_disk_encryption // false) or
            (.data.root_encrypted // false) or
            (.data.home_encryption // false)
        ' >/dev/null 2>&1 <<<"$encryption_json"
        return $?
    fi

    echo "$encryption_json" | grep -Eq '"(system_encrypted|full_disk_encryption|root_encrypted|home_encryption)"[[:space:]]*:[[:space:]]*true' && return 0
    return 1
}

local_system_encryption_detected() {
    local root_source=""
    local root_resolved=""
    local root_type=""
    local dm_uuid=""

    if lsblk -P -o TYPE,MOUNTPOINT 2>/dev/null | grep -q 'TYPE="crypt".*MOUNTPOINT="/"'; then
        return 0
    fi

    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
    [ -n "$root_source" ] || return 1

    root_resolved=$(readlink -f "$root_source" 2>/dev/null || echo "$root_source")
    root_type=$(lsblk -no TYPE "$root_resolved" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [ "$root_type" = "crypt" ]; then
        return 0
    fi

    dm_uuid=$(dmsetup info -C --noheadings -o uuid "$root_resolved" 2>/dev/null | tr -d '[:space:]')
    case "$dm_uuid" in
        CRYPT-*)
            return 0
            ;;
    esac

    if [[ "$root_source" == /dev/mapper/* ]] && sudo -n cryptsetup status "${root_source#/dev/mapper/}" >/dev/null 2>&1; then
        return 0
    fi

    if grep -qsE '^[^#[:space:]]' /etc/crypttab 2>/dev/null && lsblk -rno FSTYPE 2>/dev/null | grep -qi '^crypto_LUKS$'; then
        return 0
    fi

    return 1
}

# Function to detect system status (Live vs Installed + Encryption + Boot Mode)
detect_system_status() {
    # Method 1: Live ISO Detection (robust - checks multiple indicators)
    # is_live_session() checks boot=live/persistent=0/boot=casper and /run/live, so an
    # installed system running a podman or docker container (an overlay mount) is no
    # longer reported as "Live" and its disk encryption state is still shown.
    if is_live_session; then
        local boot_mode=$(detect_boot_mode)
        echo "Live - ${boot_mode}"
        return 0
    fi

    # Method 2: Encryption Detection (uses health-control if available)
    local boot_mode=$(detect_boot_mode)

    # Try to use health-control binary for comprehensive encryption check
    if command -v health-control >/dev/null 2>&1; then
        # Call health-control encryption-status command
        ENCRYPTION_JSON=$(run_command health-control 30 encryption-status --json 2>/dev/null)

        if health_control_reports_encryption "$ENCRYPTION_JSON" || local_system_encryption_detected; then
            echo "Installed - Encrypted - ${boot_mode}"
        else
            echo "Installed - Not Encrypted - ${boot_mode}"
        fi
    else
        if local_system_encryption_detected; then
            echo "Installed - Encrypted - ${boot_mode}"
        else
            echo "Installed - Not Encrypted - ${boot_mode}"
        fi
    fi
}

# Function to display system info compactly
display_info() {
    # Detect system status
    SYSTEM_STATUS=$(detect_system_status)

    # Get uptime and load average (single average value)
    local UPTIME_RAW=$(uptime -p | sed 's/up //; s/ hours\?/h/; s/ minutes\?/m/; s/ days\?/d/; s/,//g')
    local LOAD_AVG=$(cat /proc/loadavg | awk '{printf "%.2f", ($1 + $2 + $3) / 3}')

    # Apply color based on status
    # Bright green for: Live OR Encrypted (same as PermG:+)
    # Red for: Not Encrypted (installed without encryption)
    if [[ "$SYSTEM_STATUS" == *"Not Encrypted"* ]]; then
        SYSTEM_STATUS_COLORED="${RED}${SYSTEM_STATUS}${NC}"
    elif [[ "$SYSTEM_STATUS" == *"Live"* ]] || [[ "$SYSTEM_STATUS" == *"Encrypted"* ]]; then
        SYSTEM_STATUS_COLORED="${GREEN}${SYSTEM_STATUS}${NC}"  # Bright green (same as PermG:+)
    else
        SYSTEM_STATUS_COLORED="${SYSTEM_STATUS}"  # Fallback (no color)
    fi

    echo ""
    echo -e "${BOLD}SSTATUS:${NC} ${SYSTEM_STATUS_COLORED} | ${BOLD}Uptime:${NC} ${GREEN}${UPTIME_RAW}${NC} | ${BOLD}Load:${NC} ${GREEN}${LOAD_AVG}${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"

    # Security score with color based on value (handle both int and float)
    # Color scheme: RED (<60), YELLOW (60-79), GREEN (≥80)
    if [[ "$SEC_SCORE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        # Convert to integer for comparison (drop decimal part)
        SCORE_INT=$(echo "$SEC_SCORE" | cut -d. -f1)
        if [ "$SCORE_INT" -ge 80 ]; then
            SCORE_COLOR="${GREEN}"    # Bright green (same as PermG:+)
        elif [ "$SCORE_INT" -ge 60 ]; then
            SCORE_COLOR="${YELLOW}"   # Magenta (warning)
        else
            SCORE_COLOR="${RED}"      # Red (critical)
        fi
    else
        SCORE_COLOR="${RED}"
    fi

    # Show ACTUAL DNS mode (verified, not hardcoded)
    # Truncate DNS mode if too long (allow space for [Direct:+ Port:+])
    DNS_DISPLAY=$(echo "$ACTUAL_DNS_MODE" | cut -c1-65)

    # Color DNS based on status
    if [[ "$ACTUAL_DNS_MODE" == *"[Direct:+ Port:+]"* ]]; then
        DNS_COLOR="${GREEN}"  # Bright green for Tor DNS with both methods successful
    elif [[ "$ACTUAL_DNS_MODE" == *"DNSCrypt stopped"* ]]; then
        DNS_COLOR="${RED}"  # Red for DNSCrypt stopped (broken DNS)
    elif [[ "$ACTUAL_DNS_MODE" == *"DNSCrypt"* ]]; then
        DNS_COLOR="${GREEN}"  # Bright green for DNSCrypt working
    elif [[ "$ACTUAL_DNS_MODE" == *"service not running"* ]]; then
        DNS_COLOR="${RED}"  # Red for service not running
    else
        DNS_COLOR="${YELLOW}"  # Yellow for direct DNS or anything else
    fi

    # Line 1: Security Score | Hardening | Torrified Status
    echo -e "${BOLD}Security:${NC} ${SCORE_COLOR}${SEC_SCORE}/100 [${SEC_STATUS}]${NC} | ${BOLD}Hardening:${NC} ${GREEN}${HARDENING_STATUS}${NC} | ${BOLD}Torrified:${NC} ${TOR_STATUS}"

    # Line 2: Network Connection | DNS
    echo -e "${BOLD}Network:${NC} ${NET_STATUS} | ${BOLD}DNS:${NC} ${DNS_COLOR}${DNS_DISPLAY}${NC} | ${KNET_STATUS}"

    # Line 3: IP, Country, City (bright green - same as PermG:+)
    echo -e "${BOLD}IP:${NC} ${GREEN}${IP_ADDR}${NC} | ${BOLD}Country:${NC} ${GREEN}${FLAG} ${COUNTRY}${NC} | ${BOLD}City:${NC} ${GREEN}${CITY}${NC}"

    # Line 4: Hostname, MAC, Timezone (bright green - same as PermG:+)
    echo -e "${BOLD}Hostname:${NC} ${GREEN}${HOSTNAME}${NC} | ${BOLD}MAC:${NC} ${GREEN}${MAC_ADDR}${NC} | ${BOLD}TZ:${NC} ${GREEN}${TIMEZONE}${NC}"

    echo ""
    # Crypto prices line
    echo -e "${BOLD}CRYPTO PRICES:${NC}"
    echo -e "${CRYPTO_PRICES}"

    echo ""
    # News headlines
    echo -e "${BOLD}LATEST NEWS:${NC}"
    echo -e "${NEWS_HEADLINES}"

    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
}

# Function to display profile menu
# CRITICAL: Keep menu display under 50 lines total (currently 36 lines)
show_menu() {
    echo -e "${BOLD}SELECT PROFILE:${NC}"
    echo ""
    echo -e "${CYAN}=== VPN PROTOCOLS ===${NC}"
    echo -e " ${GREEN}[1]${NC} ${BOLD}WireGuard${NC}  ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[2]${NC} ${BOLD}OpenVPN${NC}    ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[3]${NC} ${BOLD}V2Ray${NC}      ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[4]${NC} ${BOLD}More VPN Protocols...${NC} (9 more)"
    echo ""
    echo -e "${CYAN}=== TOR/PRIVACY & DNS ===${NC}"
    echo -e " ${GREEN}[5]${NC} ${BOLD}Torrify: Round-Robin${NC}     ${CYAN}→${NC} Auth ${CYAN}→${NC} Torrify ${CYAN}→${NC} nftables ${CYAN}→${NC} DNS ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[6]${NC} ${BOLD}Torrify: Consistent-Hash${NC} ${CYAN}→${NC} Auth ${CYAN}→${NC} Torrify ${CYAN}→${NC} nftables ${CYAN}→${NC} DNS ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[7]${NC} ${BOLD}Torrify: Weighted${NC}        ${CYAN}→${NC} Auth ${CYAN}→${NC} Torrify ${CYAN}→${NC} nftables ${CYAN}→${NC} DNS ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[8]${NC} ${BOLD}WireGuard + Torrify RR${NC}   ${CYAN}→${NC} Auth ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Torrify ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[9]${NC} ${BOLD}More Tor Options...${NC} (8 more)"
    echo ""
    echo -e "${CYAN}=== NETWORK & SYSTEM ===${NC}"
    echo -e " ${GREEN}[10]${NC} ${BOLD}Disconnect Routing${NC}          ${CYAN}→${NC} Disconnect ${CYAN}→${NC} Status ${CYAN}→${NC} IP Fetch"
    echo -e " ${GREEN}[11]${NC} ${BOLD}Detorrify System${NC}            ${CYAN}→${NC} Remove iptables ${CYAN}→${NC} Remove nftables ${CYAN}→${NC} Stop DNS ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[12]${NC} ${BOLD}Emergency Network Recovery${NC}  ${CYAN}→${NC} Detorrify ${CYAN}→${NC} Disconnect ${CYAN}→${NC} Recover ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[13]${NC} ${BOLD}More System Options...${NC} (8 more)"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}NOTE:${NC} ${CYAN}health-control -e${NC}, ${CYAN}routing-switch -e${NC} | ${PROFILE_COUNT_RAW}+ profiles: ${CYAN}workflow-manager list${NC}"
    echo -e "${YELLOW}TIP:${NC} MicroSOCKS: ${CYAN}routing-switch microsocks-enable -u USER -p PASS${NC}"
    echo ""
    # Calculate and display timeout dynamically
    if [ $AUTO_REFRESH_TIMEOUT -ge 60 ]; then
        local timeout_minutes=$((AUTO_REFRESH_TIMEOUT / 60))
        echo -ne "${BOLD}Enter choice [1-13]${NC} ${CYAN}(auto-refresh in ${timeout_minutes} min)${NC}: "
    else
        echo -ne "${BOLD}Enter choice [1-13]${NC} ${CYAN}(auto-refresh in ${AUTO_REFRESH_TIMEOUT} sec)${NC}: "
    fi
}

# Submenu: More VPN Protocols
show_vpn_submenu() {
    clear
    show_header
    echo ""
    echo -e "${CYAN}MORE VPN PROTOCOLS:${NC}"
    echo ""
    echo -e " ${GREEN}[1]${NC} ${BOLD}Xray-VLESS-Reality${NC}      ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[2]${NC} ${BOLD}Xray-VLESS${NC}              ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[3]${NC} ${BOLD}Xray-Trojan${NC}             ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[4]${NC} ${BOLD}Shadowsocks${NC}             ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[5]${NC} ${BOLD}Hysteria2${NC}               ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[6]${NC} ${BOLD}Mita${NC}                    ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[7]${NC} ${BOLD}Dante SOCKS5${NC}            ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[8]${NC} ${BOLD}AmneziaWG${NC}               ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[9]${NC} ${BOLD}OpenVPN over Cloak${NC}      ${CYAN}→${NC} Auth ${CYAN}→${NC} Status ${CYAN}→${NC} Harden ${CYAN}→${NC} Connect ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[0]${NC} ${BOLD}Back to main menu${NC}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "${BOLD}Enter choice [0-9]${NC}: "
}

# Submenu: More Tor Options (DNS items + restart)
show_tor_submenu() {
    clear
    show_header
    echo ""
    echo -e "${CYAN}MORE TOR OPTIONS:${NC}"
    echo ""
    echo -e " ${GREEN}[1]${NC} ${BOLD}Enable DNSCrypt${NC}             ${CYAN}→${NC} Stop Tor DNS ${CYAN}→${NC} Enable DNSCrypt ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[2]${NC} ${BOLD}Enable Tor DNS${NC}              ${CYAN}→${NC} Auth ${CYAN}→${NC} Start Tor ${CYAN}→${NC} DNS nftables ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[3]${NC} ${BOLD}Set Random Reputable Servers${NC} ${CYAN}→${NC} Switch to random reputable DNS servers"
    echo -e " ${GREEN}[4]${NC} ${BOLD}Set DNS Fallback${NC}            ${CYAN}→${NC} Use hardcoded fallback DNS servers"
    echo -e " ${GREEN}[5]${NC} ${BOLD}Remote Tor via RedSocks${NC}      ${CYAN}→${NC} Auth ${CYAN}→${NC} RedSocks ${CYAN}→${NC} Tor ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[6]${NC} ${BOLD}Torrify Single Default Node${NC}  ${CYAN}→${NC} Auth ${CYAN}→${NC} Torrify ${CYAN}→${NC} Verify"
    echo -e " ${GREEN}[7]${NC} ${BOLD}Restart All Tor Instances${NC}   ${CYAN}→${NC} Restart all Tor instances"
    echo -e " ${GREEN}[8]${NC} ${BOLD}List Tor Instances (IPs & Countries)${NC} ${CYAN}→${NC} Show all instances with IPs"
    echo -e " ${GREEN}[0]${NC} ${BOLD}Back to main menu${NC}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "${BOLD}Enter choice [0-8]${NC}: "
}

# Submenu: DNS Options
show_dns_submenu() {
    clear
    show_header
    echo ""
    echo -e "${CYAN}DNS OPTIONS:${NC}"
    echo ""
    echo -e " ${GREEN}[1]${NC} ${BOLD}Random DNS Selection${NC}  ${CYAN}→${NC} Switch to random reputable DNS servers"
    echo -e " ${GREEN}[2]${NC} ${BOLD}Fallback DNS${NC}          ${CYAN}→${NC} Use hardcoded fallback DNS servers"
    echo -e " ${GREEN}[0]${NC} ${BOLD}Back to Tor Options${NC}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "${BOLD}Enter choice [0-2]${NC}: "
}

# Submenu: More System Options
show_system_submenu() {
    clear
    show_header
    echo ""
    echo -e "${CYAN}MORE SYSTEM OPTIONS:${NC}"
    echo ""
    echo -e " ${GREEN}[1]${NC} ${BOLD}Check Security Score${NC}  ${CYAN}→${NC} Display comprehensive security report"
    echo -e " ${GREEN}[2]${NC} ${BOLD}System Integrity Check${NC} ${CYAN}→${NC} Verify system integrity"
    echo -e " ${GREEN}[3]${NC} ${BOLD}Test DNS Leaks${NC}        ${CYAN}→${NC} Test for DNS leaks"
    echo -e " ${GREEN}[4]${NC} ${BOLD}Check Releases${NC}        ${CYAN}→${NC} Check latest Kodachi releases"
    echo -e " ${GREEN}[5]${NC} ${BOLD}Flush iptables and nftables${NC} ${CYAN}→${NC} Clear firewall rules"
    echo -e " ${GREEN}[6]${NC} ${BOLD}Reboot System${NC}         ${CYAN}→${NC} Restart the system"
    echo -e " ${GREEN}[7]${NC} ${BOLD}Shutdown System${NC}       ${CYAN}→${NC} Power off the system"
    echo -e " ${GREEN}[8]${NC} ${BOLD}Exit${NC}                  ${CYAN}→${NC} Skip to shell (${AUTOSHIELD_RELAUNCH_HINT})"
    echo -e " ${GREEN}[0]${NC} ${BOLD}Back to main menu${NC}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo -ne "${BOLD}Enter choice [0-8]${NC}: "
}

# Function to execute selected profile
execute_profile() {
    local choice="$1"

    case "$choice" in
        1)
            echo -e "\n${YELLOW}Connecting to WireGuard...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_wireguard_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        2)
            echo -e "\n${YELLOW}Connecting to Xray-VLESS-Reality...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_xray_vless_reality_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        3)
            echo -e "\n${YELLOW}Connecting to OpenVPN...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_openvpn_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        4)
            echo -e "\n${YELLOW}Connecting to V2Ray...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_v2ray_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        5)
            echo -e "\n${YELLOW}Connecting to Hysteria2...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_hysteria2_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        6)
            echo -e "\n${YELLOW}Connecting to Xray-VLESS...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_xray_vless_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        7)
            echo -e "\n${YELLOW}Connecting to Xray-Trojan...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_xray_trojan_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        8)
            echo -e "\n${YELLOW}Connecting to Mita...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_mita_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        9)
            echo -e "\n${YELLOW}Torrifying System (Round-Robin)...${NC}\n"
            run_command workflow-manager 0 run torrify-balance-nftables-roundrobin
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        10)
            echo -e "\n${YELLOW}Torrifying System (Consistent-Hash)...${NC}\n"
            run_command workflow-manager 0 run torrify-balance-nftables-consistent
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        11)
            echo -e "\n${YELLOW}Torrifying System (Weighted)...${NC}\n"
            run_command workflow-manager 0 run torrify-balance-nftables-weighted
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        12)
            echo -e "\n${YELLOW}Connecting WireGuard...${NC}\n"
            if run_command workflow-manager 0 run initial_terminal_setup_wireguard_only; then
                echo -e "\n${YELLOW}Torrifying System (Round-Robin)...${NC}\n"
                run_command workflow-manager 0 run torrify-balance-nftables-roundrobin
            else
                echo -e "\n${RED}WireGuard connect failed - skipping torrification so traffic is not sent through Tor without the VPN you selected${NC}\n"
            fi
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        13)
            echo -e "\n${YELLOW}Enabling DNSCrypt...${NC}\n"
            run_command workflow-manager 0 run dns-dnscrypt-enable
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        14)
            echo -e "\n${YELLOW}Enabling Tor DNS...${NC}\n"
            run_command workflow-manager 0 run tor-dns-nftables-full
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        15)
            echo -e "\n${YELLOW}Disconnecting Routing...${NC}\n"
            run_command workflow-manager 0 run routing-disconnect-clean
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        16)
            echo -e "\n${YELLOW}Detorrifying System...${NC}\n"
            run_command workflow-manager 0 run detorrify-complete-verify
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        17)
            echo -e "\n${YELLOW}Running Emergency Network Recovery...${NC}\n"
            run_command workflow-manager 0 run recovery-master-complete
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        18)
            echo -e "\n${YELLOW}Checking Security Score...${NC}\n"
            run_command health-control 0 security-score
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        19)
            # NOTE: reboot and shutdown intentionally bypass is_allowed_run_command
            # and call sudo -n directly. The allowlist gates the Kodachi service
            # binaries (health-control, dns-switch, etc); system power verbs are
            # standard /sbin tools and are gated by the y/N confirmation above.
            # Do not "fix" by adding them to is_allowed_run_command.
            echo -e "\n${YELLOW}Reboot System${NC}"
            echo -ne "${RED}Are you sure you want to reboot? [y/N]:${NC} "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -e "${GREEN}Rebooting system...${NC}"
                sudo -n reboot
            else
                echo -e "${YELLOW}Reboot cancelled.${NC}"
                sleep 1
            fi
            ;;
        20)
            # See note on case 19: power verbs intentionally bypass the allowlist.
            echo -e "\n${YELLOW}Shutdown System${NC}"
            echo -ne "${RED}Are you sure you want to shutdown? [y/N]:${NC} "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                echo -e "${GREEN}Shutting down system...${NC}"
                sudo -n shutdown -h now
            else
                echo -e "${YELLOW}Shutdown cancelled.${NC}"
                sleep 1
            fi
            ;;
        21)
            echo -e "\n${GREEN}Exiting to shell...${NC}\n"
            return 1
            ;;
        # IMPORTANT: Keep these workflow launches behind run_command.
        # It enforces sudo/context consistently; raw workflow-manager calls here
        # previously caused routing state permission errors and connect failures.
        22)
            echo -e "\n${YELLOW}Connecting to Dante SOCKS5...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_dante_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        23)
            echo -e "\n${YELLOW}Connecting to Shadowsocks...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_shadowsocks_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        24)
            echo -e "\n${YELLOW}Connecting Remote Tor via RedSocks...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_tor_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        25)
            echo -e "\n${YELLOW}Torrifying Single Default Node...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_auth_torrify_only
            echo ""
            echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        26)
            echo -e "\n${YELLOW}Connecting to AmneziaWG...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_amneziawg_only
            echo ""
            echo -e "${CYAN}═════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        27)
            echo -e "\n${YELLOW}Connecting to OpenVPN over Cloak...${NC}\n"
            run_command workflow-manager 0 run initial_terminal_setup_openvpn_cloak_only
            echo ""
            echo -e "${CYAN}═════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}Return to Menu Options:${NC}"
            echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
            echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
            echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
            echo ""
            echo -ne "${BOLD}Your choice:${NC} "
            read -r refresh_choice
            ;;
        *)
            echo -e "\n${RED}Invalid choice. Please try again...${NC}\n"
            sleep 1
            ;;
    esac
}

# Function to handle submenu navigation
handle_submenu() {
    local menu_type="$1"
    local submenu_executed=false

    while true; do
        case "$menu_type" in
            "vpn")
                show_vpn_submenu
                read -r vpn_choice
                case "$vpn_choice" in
                    1) execute_profile "2" || return $?; submenu_executed=true ;; # Xray-VLESS-Reality
                    2) execute_profile "6" || return $?; submenu_executed=true ;; # Xray-VLESS
                    3) execute_profile "7" || return $?; submenu_executed=true ;; # Xray-Trojan
                    4) execute_profile "23" || return $?; submenu_executed=true ;; # Shadowsocks
                    5) execute_profile "5" || return $?; submenu_executed=true ;; # Hysteria2
                    6) execute_profile "8" || return $?; submenu_executed=true ;; # Mita
                    7) execute_profile "22" || return $?; submenu_executed=true ;; # Dante SOCKS5
                    8) execute_profile "26" || return $?; submenu_executed=true ;; # AmneziaWG
                    9) execute_profile "27" || return $?; submenu_executed=true ;; # OpenVPN over Cloak
                    0) SKIP_REFRESH=true; break ;; # Back to main menu (no refresh)
                    *) echo -e "${RED}Invalid choice. Try again.${NC}"; sleep 2 ;;
                esac
                ;;
            "tor")
                show_tor_submenu
                read -r tor_choice
                case "$tor_choice" in
                    1) execute_profile "13" || return $?; submenu_executed=true ;; # Enable DNSCrypt
                    2) execute_profile "14" || return $?; submenu_executed=true ;; # Enable Tor DNS
                    3) # Set Random Reputable Servers
                        echo -e "\n${YELLOW}Switching to Random Reputable DNS Servers...${NC}\n"
                        run_command dns-switch 30 random
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    4) # Set DNS Fallback
                        echo -e "\n${YELLOW}Switching to Fallback DNS Servers...${NC}\n"
                        run_command dns-switch 30 fallback
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    5) execute_profile "24" || return $?; submenu_executed=true ;; # Remote Tor via RedSocks
                    6) execute_profile "25" || return $?; submenu_executed=true ;; # Torrify Single Default Node
                    7) # Restart All Tor Instances
                        echo -e "\n${YELLOW}Restarting All Tor Instances...${NC}\n"
                        run_command tor-switch 60 restart-all-instances
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    8) # List Tor Instances (IPs & Countries)
                        echo -e "\n${YELLOW}Listing Tor Instances with IPs and Countries...${NC}\n"
                        run_command tor-switch 30 list-instances-with-ip
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    0) SKIP_REFRESH=true; break ;; # Back to main menu (no refresh)
                    *) echo -e "${RED}Invalid choice. Try again.${NC}"; sleep 2 ;;
                esac
                ;;
            "system")
                show_system_submenu
                read -r sys_choice
                case "$sys_choice" in
                    1) execute_profile "18" || return $?; submenu_executed=true ;; # Check Security Score
                    2) # System Integrity Check
                        echo -e "\n${YELLOW}Running System Integrity Check...${NC}\n"
                        run_command integrity-check 120 check-all
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    3) # Test DNS Leaks
                        echo -e "\n${YELLOW}Testing DNS Leaks...${NC}\n"
                        run_command dns-leak 120 test
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    4) # Check Releases
                        echo -e "\n${YELLOW}Checking Latest Releases...${NC}\n"
                        run_command online-info-switch 30 releases
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    5) # Flush iptables and nftables
                        echo -e "\n${YELLOW}Flushing iptables and nftables...${NC}\n"
                        # --force: flush-iptables/flush-nftables are destructive
                        # force-gated ops; selecting menu option 5 IS the user
                        # confirmation, so pass --force or the calls refuse and
                        # the flush silently no-ops.
                        run_command tor-switch 30 flush-iptables --force
                        run_command tor-switch 30 flush-nftables --force
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    6) execute_profile "19" || return $?; submenu_executed=true ;; # Reboot System
                    7) execute_profile "20" || return $?; submenu_executed=true ;; # Shutdown System
                    8) execute_profile "21" || return $?; submenu_executed=true ;; # Exit
                    0) SKIP_REFRESH=true; break ;; # Back to main menu (no refresh)
                    *) echo -e "${RED}Invalid choice. Try again.${NC}"; sleep 2 ;;
                esac
                ;;
            "dns")
                show_dns_submenu
                read -r dns_choice
                case "$dns_choice" in
                    1) # Random DNS Selection
                        echo -e "\n${YELLOW}Switching to Random DNS Servers...${NC}\n"
                        run_command dns-switch 30 random
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    2) # Fallback DNS
                        echo -e "\n${YELLOW}Switching to Fallback DNS Servers...${NC}\n"
                        run_command dns-switch 30 fallback
                        echo ""
                        echo -e "${CYAN}════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}Return to Menu Options:${NC}"
                        echo -e "  ${GREEN}[Enter]${NC} - Refresh data and show menu (recommended)"
                        echo -e "  ${GREEN}[s]${NC}     - Skip refresh and show menu (fast)"
                        echo -e "  ${GREEN}[Ctrl+C]${NC} - Exit to shell"
                        echo ""
                        echo -ne "${BOLD}Your choice:${NC} "
                        read -r refresh_choice
                        submenu_executed=true
                        ;;
                    0) SKIP_REFRESH=true; break ;; # Back to Tor Options
                    *) echo -e "${RED}Invalid choice. Try again.${NC}"; sleep 2 ;;
                esac
                ;;
        esac

        # If submenu item was executed, break to return to main menu
        if [ "$submenu_executed" = true ]; then
            break
        fi
    done
}

# Main execution
main() {
    # Pre-flight dependency check (warnings only, non-fatal)
    check_critical_dependencies

    if ! init_runtime_environment; then
        return 1
    fi
    setup_runtime_signal_traps

    # Display header
    show_header

    # Print build signature once at start
    echo -e "${CYAN}▸ Welcome Script v${SCRIPT_VERSION} | Build: ${BUILD_DATE} | Runtime: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}▸ You can stop this script anytime by pressing ${BOLD}Ctrl+C${NC}${CYAN} keys${NC}"

    # SYSTEM INITIALIZATION section
    print_section_header "SYSTEM INITIALIZATION"

    # Ensure installed GRUB menu shows Kodachi branding
    echo -ne "${YELLOW}▸ Ensuring GRUB theme...${NC}"
    start_timer
    ensure_grub_theme
    end_timer
    echo -e " ${GREEN}+ Theme configured${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Deploy binaries (detect_hooks_dir will print status)
    echo -ne "${YELLOW}▸ Deploying binaries...${NC}"
    start_timer
    deploy_binaries
    end_timer
    echo -e " ${GREEN}+ Deployed successfully${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Sleep to ensure internet connectivity is established
    echo -ne "${YELLOW}▸ Waiting for network (5s)...${NC}"
    start_timer
    sleep 5
    end_timer
    echo -e " ${GREEN}+ Network ready${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

    # Check internet connectivity using health-control
    echo -ne "${YELLOW}▸ Checking internet connectivity...${NC}"
    start_timer
    CONNECTIVITY_CHECK=$(run_command health-control 30 net-check --domain-only --json 2>/dev/null)
    DOMAIN_CONNECTIVITY=$(parse_json "$CONNECTIVITY_CHECK" ".domain_connectivity")
    end_timer

    if [ "$DOMAIN_CONNECTIVITY" = "true" ]; then
        echo -e " ${GREEN}+ Internet available${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
        HAS_INTERNET=true
    else
        echo -e " ${YELLOW}⊘ Offline mode detected${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
        HAS_INTERNET=false
    fi

    # Check authentication status and attempt login if needed
    if [ "$HAS_INTERNET" = "true" ]; then
        echo -ne "${YELLOW}▸ Checking authentication status...${NC}"
        start_timer
        LOGIN_CHECK=$(run_command online-auth 50 check-login --json 2>/dev/null)
        IS_LOGGED_IN=$(parse_json "$LOGIN_CHECK" ".data.is_logged_in")
        end_timer

        if [ "$IS_LOGGED_IN" = "true" ]; then
            echo -e " ${GREEN}+ Already authenticated${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
            AUTH_STATUS="${GREEN}[Auth:+]${NC}"

            # Authenticated - use DNSCrypt (requires auth)
            echo -ne "${YELLOW}▸ Configuring DNSCrypt...${NC}"
            start_timer
            if setup_dnscrypt_locked; then
                end_timer
                print_dns_setup_result
            else
                end_timer
                echo -e " ${RED}! DNSCrypt setup failed${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
            fi
        else
            echo -e " ${YELLOW}! Not authenticated${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
            echo -e "${YELLOW}  Attempting login...${NC}"

            # Attempt authentication immediately
            start_timer
            if authenticate; then
                end_timer
                echo -e "${GREEN}+ Authentication successful${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
                AUTH_STATUS="${GREEN}[Auth:+]${NC}"

                # Authenticated - use DNSCrypt (requires auth)
                echo -ne "${YELLOW}▸ Configuring DNSCrypt...${NC}"
                start_timer
                if setup_dnscrypt_locked; then
                    end_timer
                    print_dns_setup_result
                else
                    end_timer
                    echo -e " ${RED}! DNSCrypt setup failed${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
                fi
            else
                end_timer
                echo -e "${RED}! Authentication failed - using fallback DNS${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
                AUTH_STATUS="${RED}[Auth:-]${NC}"

                # Not authenticated - use fallback DNS (no auth required)
                run_command dns-switch 50 fallback >/dev/null 2>&1

                # Set DNS status message for fallback
                DNS_STATUS_MSG="${YELLOW}[SDNS:Fallback]${NC}"
            fi
        fi
    else
        # Offline mode - skip authentication
        echo -e "${YELLOW}⊘ Skipping authentication (offline mode)${NC}"
        echo -e "${CYAN}  • Using local DNS configuration${NC}"
        AUTH_STATUS="${YELLOW}[Auth:⊘]${NC}"
        DNS_STATUS_MSG="${YELLOW}[DNS:Local]${NC}"

        # Query local DNS (doesn't require internet)
        echo -ne "${YELLOW}▸ Detecting DNS configuration...${NC}"
        start_timer
        DNS_STATUS=$(run_command dns-switch 30 status --json 2>/dev/null)

        if check_jq; then
            NAMESERVERS=$(echo "$DNS_STATUS" | jq -r '.data.nameservers[]' 2>/dev/null | tr '\n' ', ' | sed 's/, $//')
        else
            NAMESERVERS="Unknown"
        fi

        # Detect DNS type (simplified for offline mode)
        if echo "$NAMESERVERS" | grep -q "127.0.0.1"; then
            # Check if DNSCrypt or Tor DNS
            DNSCRYPT_CHECK=$(run_command dns-switch 30 dnscrypt --json 2>/dev/null)
            DNSCRYPT_ACTIVE=$(parse_json "$DNSCRYPT_CHECK" ".data.service_active" || echo "false")

            if [ "$DNSCRYPT_ACTIVE" = "true" ]; then
                ACTUAL_DNS_MODE="127.0.0.1 (DNSCrypt)"
            else
                # Could be Tor DNS - simplified check without full verification
                ACTUAL_DNS_MODE="127.0.0.1 (Local)"
            fi
        else
            ACTUAL_DNS_MODE="$NAMESERVERS"
        fi

        end_timer
        echo -e " ${GREEN}+ DNS detected${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    fi

    # TIME SYNCHRONIZATION section
    print_section_header "TIME SYNCHRONIZATION"

    if [ "$HAS_INTERNET" = "true" ]; then
        # Synchronize system time using multiple methods (first success wins)
        echo -ne "${YELLOW}▸ Synchronizing system time...${NC}"
        start_timer

        # Track if at least one sync succeeded
        any_sync_succeeded=false

        # Method 1: ntpdig with time.cloudflare.com (PRIORITY - privacy-focused, most accurate)
        if ! $any_sync_succeeded; then
            if run_privileged_command ntpdig -S time.cloudflare.com >/dev/null 2>&1; then
                any_sync_succeeded=true
            fi
        fi

        # Method 2: ntpdig with pool.ntp.org (if Cloudflare fails)
        if ! $any_sync_succeeded; then
            if run_privileged_command ntpdig -S pool.ntp.org >/dev/null 2>&1; then
                any_sync_succeeded=true
            fi
        fi

        # Method 3: ntpdig with time.nist.gov (if both above fail)
        if ! $any_sync_succeeded; then
            if run_privileged_command ntpdig -S time.nist.gov >/dev/null 2>&1; then
                any_sync_succeeded=true
            fi
        fi

        # Method 4: timedatectl (if all ntpdig fail). `set-ntp true` only ENABLES
        # systemd-timesyncd and returns 0 whether or not the clock ever syncs; on a
        # torrified or UDP-blocked host it never will, and this used to paint [TSync:+]
        # over a clock that was never touched. Count it only when the kernel's
        # synchronized flag actually flips within a bounded wait.
        if ! $any_sync_succeeded; then
            if run_privileged_command timedatectl set-ntp true 2>/dev/null; then
                local ntp_wait=0
                while [ "$ntp_wait" -lt 6 ]; do
                    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
                        any_sync_succeeded=true
                        break
                    fi
                    sleep 1
                    ntp_wait=$((ntp_wait + 1))
                done
            fi
        fi

        # Method 5: ntpdate with pool.ntp.org (legacy fallback)
        if ! $any_sync_succeeded; then
            if command -v ntpdate >/dev/null 2>&1; then
                if run_privileged_command ntpdate pool.ntp.org >/dev/null 2>&1; then
                    any_sync_succeeded=true
                fi
            elif [ -x /usr/sbin/ntpdate ]; then
                if run_privileged_command /usr/sbin/ntpdate pool.ntp.org >/dev/null 2>&1; then
                    any_sync_succeeded=true
                fi
            fi
        fi

        # Method 6: ntpdate with time.nist.gov (legacy fallback)
        if ! $any_sync_succeeded; then
            if command -v ntpdate >/dev/null 2>&1; then
                if run_privileged_command ntpdate time.nist.gov >/dev/null 2>&1; then
                    any_sync_succeeded=true
                fi
            elif [ -x /usr/sbin/ntpdate ]; then
                if run_privileged_command /usr/sbin/ntpdate time.nist.gov >/dev/null 2>&1; then
                    any_sync_succeeded=true
                fi
            fi
        fi

        # Method 7: ntpd one-shot sync (final fallback)
        if ! $any_sync_succeeded; then
            if [ -x /usr/sbin/ntpd ]; then
                if run_privileged_command /usr/sbin/ntpd -gq >/dev/null 2>&1; then
                    any_sync_succeeded=true
                fi
            fi
        fi

        # Report accurate status based on actual results
        end_timer
        if [ "$any_sync_succeeded" = "true" ]; then
            echo -e " ${GREEN}+ Time sync completed${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
            TIME_SYNC_STATUS="${GREEN}[TSync:+]${NC}"
        else
            echo -e " ${YELLOW}! Time sync attempted (may need manual verification)${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
            TIME_SYNC_STATUS="${YELLOW}[TSync:~]${NC}"
        fi
    else
        # Offline mode - skip time synchronization
        echo -e "${YELLOW}⊘ Skipping time synchronization (offline mode)${NC}"
        echo -e "${CYAN}  • System time: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        TIME_SYNC_STATUS="${YELLOW}[TSync:⊘]${NC}"
    fi

    # Authentication already attempted before time sync - no retry needed

    # Fetch system information (individual operations show their own timing)
    fetch_system_info

    # Count profiles, logs, and binaries (silent operation)
    start_timer
    count_profiles
    count_logs
    count_binaries
    end_timer

    # Check permission guard status
    check_permission_guard

    # ONLINE DATA RETRIEVAL section
    print_section_header "ONLINE DATA RETRIEVAL"

    if [ "$HAS_INTERNET" = "true" ]; then
        # Fetch online data (show each item being fetched)
        echo -ne "${YELLOW}▸ Fetching latest version info...${NC}"
        start_timer
        fetch_latest_version
        end_timer
        echo -e " ${GREEN}+ Version retrieved${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

        echo -ne "${YELLOW}▸ Fetching cryptocurrency prices...${NC}"
        start_timer
        fetch_crypto_prices
        end_timer
        echo -e " ${GREEN}+ Prices retrieved${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"

        echo -ne "${YELLOW}▸ Fetching news headlines...${NC}"
        start_timer
        fetch_news_headlines
        end_timer
        echo -e " ${GREEN}+ Headlines retrieved${NC} ${CYAN}(took $(format_duration $OPERATION_TIME))${NC}"
    else
        # Offline mode - skip online data retrieval
        echo -e "${YELLOW}⊘ Skipping online data retrieval (offline mode)${NC}"

        # Set offline placeholders
        LATEST_VERSION="Build: ${GREEN}${SCRIPT_VERSION}${NC} | ${YELLOW}Offline${NC}"
        CRYPTO_PRICES="${YELLOW}Crypto prices unavailable (offline)${NC}"
        NEWS_HEADLINES="${YELLOW}No news available (offline)${NC}"
    fi

    echo -e "${GREEN}+ All checks complete!${NC}"
    sleep 0.5

    # Clear and redisplay header
    clear
    show_header

    # Print consolidated status line
    echo -e "${DEPLOY_STATUS} | ${AUTH_STATUS} | ${TIME_SYNC_STATUS} | ${DNS_STATUS_MSG} | ${INFO_STATUS} | ${PERM_GUARD_STATUS}"

    # Build counts line only if we have hooks directory info
    local counts_line=""
    [ -n "$PROFILE_COUNT" ] && counts_line="${PROFILE_COUNT}"
    [ -n "$LOGS_COUNT" ] && counts_line="${counts_line:+$counts_line | }${LOGS_COUNT}"
    [ -n "$BINARIES_COUNT" ] && counts_line="${counts_line:+$counts_line | }${BINARIES_COUNT}"
    [ -n "$LATEST_VERSION" ] && counts_line="${counts_line:+$counts_line | }${LATEST_VERSION}"

    # Only print counts line if we have something to show
    [ -n "$counts_line" ] && echo -e "$counts_line"

    # Display information
    display_info

    # Menu loop - continue until user selects Exit
    while true; do
        # Show menu and get user choice
        show_menu
        read -t $AUTO_REFRESH_TIMEOUT -r choice
        local read_status=$?

        # END OF INPUT means there is nobody to answer the menu, so leave.
        #
        # This variant deliberately has NO non-interactive gating block (see the header),
        # which is correct for a manual harness but means a closed stdin reaches this loop
        # directly. `read` returns exactly 1 on EOF, which is neither 130 (SIGINT) nor
        # greater than 128 (timeout), so without this the empty `choice` falls to the `*)`
        # invalid-choice arm and loops with no delay. The `read` wrapper at the top of this
        # file returns the builtin's status verbatim, so EOF is still 1 here.
        # NOTE: the production script's `[ ! -t 0 ]` guard is deliberately NOT added here.
        # This file's documented contract is that it always runs main() when executed.
        if [ "$read_status" -eq 1 ]; then
            echo ""
            return 0 2>/dev/null || exit 0
        fi

        # SIGINT during menu input should exit, not be treated as an auto-refresh timeout.
        if [ "$read_status" -eq 130 ]; then
            return 130
        fi

        # Check if read timed out (status > 128 means timeout)
        if [ $read_status -gt 128 ]; then
            # Timeout occurred - trigger auto-refresh
            local timeout_minutes=$((AUTO_REFRESH_TIMEOUT / 60))
            echo ""
            echo -e "${CYAN}▸ Auto-refresh triggered (${timeout_minutes} minutes elapsed)${NC}"
            echo -e "${CYAN}▸ Refreshing system data...${NC}"

            # Re-check internet connectivity
            CONNECTIVITY_CHECK=$(run_command health-control 30 net-check --domain-only --json 2>/dev/null)
            DOMAIN_CONNECTIVITY=$(parse_json "$CONNECTIVITY_CHECK" ".domain_connectivity")
            if [ "$DOMAIN_CONNECTIVITY" = "true" ]; then
                HAS_INTERNET=true
            else
                HAS_INTERNET=false
            fi

            # Re-fetch dynamic data (respects offline mode)
            fetch_system_info
            count_profiles
            count_logs
            count_binaries
            check_permission_guard

            # Only fetch online data if internet is available
            if [ "$HAS_INTERNET" = "true" ]; then
                fetch_latest_version
                fetch_crypto_prices
                fetch_news_headlines
            else
                echo -e "${YELLOW}⊘ Still offline - skipping online operations${NC}"
            fi

            echo -e "${GREEN}+ Auto-refresh complete!${NC}"
            sleep 0.5

            # Clear and redisplay everything
            clear
            show_header
            echo -e "${DEPLOY_STATUS} | ${AUTH_STATUS} | ${TIME_SYNC_STATUS} | ${DNS_STATUS_MSG} | ${INFO_STATUS} | ${PERM_GUARD_STATUS}"

            # Build counts line
            local counts_line=""
            [ -n "$PROFILE_COUNT" ] && counts_line="${PROFILE_COUNT}"
            [ -n "$LOGS_COUNT" ] && counts_line="${counts_line:+$counts_line | }${LOGS_COUNT}"
            [ -n "$BINARIES_COUNT" ] && counts_line="${counts_line:+$counts_line | }${BINARIES_COUNT}"
            [ -n "$LATEST_VERSION" ] && counts_line="${counts_line:+$counts_line | }${LATEST_VERSION}"

            # Only print counts line if we have something to show
            [ -n "$counts_line" ] && echo -e "$counts_line"

            # Display information
            display_info

            # Continue to next iteration (show menu again)
            continue
        fi

        # Reset refresh_choice to avoid stale value from previous iteration
        refresh_choice=""

        # Handle menu choices with submenu support
        case "$choice" in
            1)  # WireGuard
                execute_profile "1"
                ;;
            2)  # OpenVPN
                execute_profile "3"
                ;;
            3)  # V2Ray
                execute_profile "4"
                ;;
            4)  # More VPN Protocols submenu
                handle_submenu "vpn"
                ;;
            5)  # Torrify: Round-Robin
                execute_profile "9"
                ;;
            6)  # Torrify: Consistent-Hash (moved from submenu to main)
                execute_profile "10"
                ;;
            7)  # Torrify: Weighted (moved from submenu to main)
                execute_profile "11"
                ;;
            8)  # WireGuard + Torrify RR
                execute_profile "12"
                ;;
            9)  # More Tor Options submenu (DNS items + Restart Tor)
                handle_submenu "tor"
                ;;
            10) # Disconnect Routing
                execute_profile "15"
                ;;
            11) # Detorrify System
                execute_profile "16"
                ;;
            12) # Emergency Network Recovery
                execute_profile "17"
                ;;
            13) # More System Options submenu (Security Score, Detorrify, Reboot, Shutdown, Exit, Releases, Integrity, DNS Leak)
                handle_submenu "system"
                ;;
            *)  # Invalid choice
                echo -e "\n${RED}Invalid choice. Please try again...${NC}\n"
                sleep 1
                continue
                ;;
        esac

        # Check if user wants to exit (execute_profile returns 1 for Exit choice)
        if [ $? -eq 1 ]; then
            break  # Exit selected
        fi

        # Check if we should skip refresh (returning from submenu with [0])
        if [ "$SKIP_REFRESH" = true ]; then
            # Skip refresh and reset flag
            SKIP_REFRESH=false
            clear
            show_header
            echo -e "${DEPLOY_STATUS} | ${AUTH_STATUS} | ${TIME_SYNC_STATUS} | ${DNS_STATUS_MSG} | ${INFO_STATUS} | ${PERM_GUARD_STATUS}"

            # Build counts line
            local counts_line=""
            [ -n "$PROFILE_COUNT" ] && counts_line="${PROFILE_COUNT}"
            [ -n "$LOGS_COUNT" ] && counts_line="${counts_line:+$counts_line | }${LOGS_COUNT}"
            [ -n "$BINARIES_COUNT" ] && counts_line="${counts_line:+$counts_line | }${BINARIES_COUNT}"
            [ -n "$LATEST_VERSION" ] && counts_line="${counts_line:+$counts_line | }${LATEST_VERSION}"

            # Only print counts line if we have something to show
            [ -n "$counts_line" ] && echo -e "$counts_line"

            # Display information
            display_info
            continue
        fi

        # Check user's refresh preference
        if [ "$refresh_choice" != "s" ] && [ "$refresh_choice" != "S" ]; then
            # User pressed Enter (or anything else) - FULL REFRESH
            echo ""
            echo -e "${CYAN}▸ Refreshing system data...${NC}"

            # Re-check internet connectivity
            CONNECTIVITY_CHECK=$(run_command health-control 30 net-check --domain-only --json 2>/dev/null)
            DOMAIN_CONNECTIVITY=$(parse_json "$CONNECTIVITY_CHECK" ".domain_connectivity")
            if [ "$DOMAIN_CONNECTIVITY" = "true" ]; then
                HAS_INTERNET=true
            else
                HAS_INTERNET=false
            fi

            # Re-fetch dynamic data (respects offline mode)
            if [ "$HAS_INTERNET" = "true" ]; then
                setup_dnscrypt_locked  # Re-detect DNS configuration (requires internet)
            fi
            fetch_system_info
            count_profiles
            count_logs
            count_binaries
            check_permission_guard

            # Only fetch online data if internet is available
            if [ "$HAS_INTERNET" = "true" ]; then
                fetch_latest_version
                fetch_crypto_prices
                fetch_news_headlines
            else
                echo -e "${YELLOW}⊘ Still offline - skipping online operations${NC}"
            fi

            echo -e "${GREEN}+ Data refresh complete!${NC}"
            sleep 0.5
        else
            # User pressed 's' - SKIP REFRESH
            echo ""
            echo -e "${YELLOW}▸ Skipping data refresh (using cached data)${NC}"
            sleep 0.3
        fi

        # Clear and redisplay header with status
        clear
        show_header
        echo -e "${DEPLOY_STATUS} | ${AUTH_STATUS} | ${TIME_SYNC_STATUS} | ${DNS_STATUS_MSG} | ${INFO_STATUS} | ${PERM_GUARD_STATUS}"

        # Build counts line only if we have hooks directory info
        local counts_line=""
        [ -n "$PROFILE_COUNT" ] && counts_line="${PROFILE_COUNT}"
        [ -n "$LOGS_COUNT" ] && counts_line="${counts_line:+$counts_line | }${LOGS_COUNT}"
        [ -n "$BINARIES_COUNT" ] && counts_line="${counts_line:+$counts_line | }${BINARIES_COUNT}"
        [ -n "$LATEST_VERSION" ] && counts_line="${counts_line:+$counts_line | }${LATEST_VERSION}"

        # Only print counts line if we have something to show
        [ -n "$counts_line" ] && echo -e "$counts_line"

        # Display information
        display_info
    done

    echo ""
}

# Run main function
main
main_status=$?

# Restore shell signal handlers and cleanup runtime artifacts
clear_runtime_signal_traps
cleanup_runtime_environment

# Return to shell
return $main_status 2>/dev/null || exit $main_status
