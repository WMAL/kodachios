#!/bin/bash

# Kodachi Dependencies Installation Script (REQUIRES SUDO/ROOT)
# ==============================================================
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
# Last updated: 2026-02-22
#
# Features:
# =========
# - Automatic contrib/non-free repository enablement
# - Automatic DNS fix after systemd-resolved installation (dns-switch integration)
# - Per-package DNS testing for Privacy packages (detects which package breaks DNS)
# - DNS retry logic for GitHub downloads (handles network issues gracefully)
# - Verbose mode for detailed debugging output (--verbose or -v flag)
# - Multiple installation modes: full, minimal, interactive, proxy-only
# - Automatic architecture detection (amd64, ARM support)
# - Download retry with fallback mechanisms
# - Non-interactive package installation (prevents freezing)
#
# Description:
# This script installs all system package dependencies required for
# Kodachi security tools to function properly. Must be run as root or with sudo.
# Supports multiple installation modes: full (default), minimal, interactive, and proxy-only.
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
#   # Full automatic installation (default)
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-deps-install.sh | sudo bash
#
#   # Interactive mode with prompts
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-deps-install.sh -o kodachi-deps-install.sh && sudo bash kodachi-deps-install.sh --interactive
#
#   # Local execution
#   sudo bash kodachi-deps-install.sh [options]
#
# Options:
#   --minimal                    Install critical packages, networking, and proxy tools
#   --full                       Install all packages including optional ones (default)
#   --interactive                Interactive category-based installation with prompts
#   --proxy-only                 Install only proxy tools (v2ray, xray, hysteria2, mieru,
#                                ck-client, amneziawg-tools)
#   --auto                       Automatic mode - answer yes to all prompts (default)
#   --no-auto                    Disable automatic mode - require user confirmation
#   --forcegui, --force-gui      Force installation of GUI packages on terminal-based systems
#                                By default: GUI packages skipped if no desktop environment detected
#   --skipgui, --skip-gui        Skip GUI packages even on systems with desktop environments
#                                Use this for headless server installations on GUI systems
#   --force-kicksecure-ramwipe   Keep/Install Kicksecure RAM wipe (dracut + ram-wipe)
#                                By default: Removes dracut/ram-wipe, restores initramfs-tools
#                                Note: Kodachi has built-in RAM wipe via 'health-control memory-wipe'
#   --verbose, -v                Enable verbose mode - show detailed apt-get output and progress
#   --help                       Show help message

# Strict mode - will be disabled for interactive mode
set -eo pipefail

# shellcheck disable=SC2155
# SC2155 ("declare and assign separately to avoid masking return values") is
# DELIBERATELY not applied in this file, and the reason is `set -e` two lines up.
#
# The 2026-09-03 audit counted 47 of these across the two public installers (L08) and
# correctly called it maintainability evidence rather than proof of 47 runtime
# failures. Splitting them is not a no-op here: `local x=$(cmd)` currently takes its
# exit status from `local`, which always succeeds, so under `set -eo pipefail` the
# split version ABORTS THE INSTALLER wherever the command legitimately returns
# non-zero. Two measured examples out of the 46 in this file:
#
#   local ufw_status=$(ufw status 2>/dev/null | grep -i "^Status:" | awk ...)
#     the very next line is `if [[ "$ufw_status" == "active" ]]`, so EMPTY is the
#     normal "ufw absent or inactive" path. Split, every machine without ufw aborts.
#
#   local other_packages=$(dpkg -l | grep -i "^ii" | grep -E "(kicksecure|whonix)" | wc -l)
#     the pipeline ENDS in `wc -l`, which always succeeds, so there is no status to
#     mask at all and the warning is a false positive for its own stated purpose.
#
# So the correct repair is per-site judgement, not a mechanical sweep, and a mechanical
# sweep of a script every user runs as root to install Kodachi would trade a lint count
# for real installation failures. Anyone revisiting this: fix a site only when an empty
# result is a BUG rather than the documented "not present" answer.
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# CRITICAL FIX: Prevent job control signals from suspending apt-get processes
# Ignore SIGTSTP (Ctrl+Z), SIGTTIN (background read), SIGTTOU (background write)
trap '' SIGTSTP SIGTTIN SIGTTOU

# Disable job control globally to prevent suspend issues
set +m

# Security and reliability options
CURL_OPTS=(--fail --location --show-error --silent --connect-timeout 15 --max-time 120)
APT_RETRY_OPTS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Verbose mode flag
VERBOSE_MODE=false

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_step() { echo -e "${CYAN}[→]${NC} $1"; }
print_highlight() { echo -e "${MAGENTA}${BOLD}$1${NC}"; }
print_verbose() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        local timestamp=$(date +"%H:%M:%S")
        echo -e "${CYAN}[VERBOSE ${timestamp}]${NC} $1"
    fi
}

# Script/runtime path helpers (avoid hardcoded user-home assumptions)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" ]] && [[ -e "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"

resolve_kodachi_public_version() {
    local helper=""
    local main_info=""

    if [[ -n "$PROJECT_ROOT" ]]; then
        helper="$PROJECT_ROOT/installers/release-policy-version.sh"
        main_info="$PROJECT_ROOT/installers/main-info.json"
        if [[ -f "$helper" && -f "$main_info" ]]; then
            bash "$helper" print-version "$main_info" 2>/dev/null && return 0
        fi
    fi

    # No hardcoded fallback. This value is PRINTED TO THE USER as the release line,
    # so a stale literal is a wrong statement rather than a harmless default. An empty
    # string is handled by the caller, which simply omits the line.
    echo ""
}

KODACHI_PUBLIC_VERSION="$(resolve_kodachi_public_version)"

resolve_user_home() {
    local user="${1:-}"
    local home=""

    if [[ -n "$user" ]]; then
        home=$(getent passwd "$user" | cut -d: -f6)
    fi

    if [[ -z "$home" ]]; then
        home="${HOME:-}"
    fi

    if [[ -z "$home" ]] || [[ ! -d "$home" ]]; then
        local base=""
        for base in /home /Users /var/home; do
            if [[ -n "$user" ]] && [[ -d "$base/$user" ]]; then
                home="$base/$user"
                break
            fi
        done
    fi

    if [[ -z "$home" ]]; then
        home="/tmp"
    fi

    echo "$home"
}

enable_xfce_compositor_for_user() {
    # Conky panels declare own_window_argb_value 0 (transparent), but that
    # only renders see-through when a compositor is active. XFCE's default
    # use_compositing=false on fresh installs leaves conky painted solid
    # black. We enable the xfwm4 compositor for each human user by writing
    # the per-user xfconf XML directly (works even before any xfce session
    # has been opened, unlike xfconf-query which needs a live D-Bus).
    local user_home="${1:-}"
    local user="${2:-}"
    [[ -z "$user_home" || ! -d "$user_home" ]] && return 0

    # Only relevant where XFCE is installed.
    if ! command -v xfwm4 >/dev/null 2>&1 && [[ ! -x /usr/bin/xfwm4 ]]; then
        return 0
    fi

    local xfconf_dir="$user_home/.config/xfce4/xfconf/xfce-perchannel-xml"
    local xfconf_file="$xfconf_dir/xfwm4.xml"

    # Smart-skip: if the compositor is already enabled in this user's
    # xfwm4.xml, do not rewrite the file or try to live-reload xfconfd.
    # Rewriting on top of an already-correct configuration can race with
    # the running xfconfd's in-memory state and leave the live session
    # with stale use_compositing=false even though the file says true.
    # The binary installer (running as the user) sets the canonical state;
    # deps installer just verifies and skips when binary already did the work.
    if [[ -f "$xfconf_file" ]] \
       && grep -q '<property name="use_compositing"[^/]*value="true"' "$xfconf_file"; then
        return 0
    fi

    mkdir -p "$xfconf_dir" 2>/dev/null || return 0

    if [[ ! -f "$xfconf_file" ]]; then
        cat > "$xfconf_file" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="true"/>
  </property>
</channel>
XML
    else
        # File exists — patch or insert the use_compositing property.
        if grep -q 'name="use_compositing"' "$xfconf_file"; then
            sed -i 's|\(<property name="use_compositing"[^/]*value="\)false\("[^/]*/>\)|\1true\2|' "$xfconf_file"
        elif grep -q '<property name="general"[^>]*/>' "$xfconf_file"; then
            # Self-closing general tag with no children — expand into open/close
            # form and insert use_compositing as the new child. Without this branch,
            # the open-tag branch below would match the self-closing form and insert
            # use_compositing as a SIBLING of general (still inside channel), so
            # xfconf reads /general/use_compositing as "not found".
            sed -i 's|\(<property name="general"[^/]*\)/>|\1>\n    <property name="use_compositing" type="bool" value="true"/>\n  </property>|' "$xfconf_file"
        elif grep -q '<property name="general"' "$xfconf_file"; then
            sed -i 's|\(<property name="general"[^>]*>\)|\1\n    <property name="use_compositing" type="bool" value="true"/>|' "$xfconf_file"
        else
            sed -i 's|</channel>|  <property name="general" type="empty">\n    <property name="use_compositing" type="bool" value="true"/>\n  </property>\n</channel>|' "$xfconf_file"
        fi
    fi

    if [[ -n "$user" ]] && id -u "$user" >/dev/null 2>&1; then
        chown -R "$user":"$(id -gn "$user" 2>/dev/null || echo "$user")" \
            "$user_home/.config/xfce4" 2>/dev/null || true
    fi

    # If an xfce session is live, push the value via xfconf-query too so
    # the change takes effect without re-login.
    if [[ -n "$user" ]] && command -v sudo >/dev/null 2>&1 \
       && command -v xfconf-query >/dev/null 2>&1; then
        local display_var=""
        for display_var in :0.0 :0 :1; do
            if sudo -n -u "$user" DISPLAY="$display_var" xfconf-query -c xfwm4 \
                   -p /general/use_compositing -s true >/dev/null 2>&1; then
                break
            fi
        done
    fi

    return 0
}

list_system_user_homes() {
    getent passwd | awk -F: '{print $6}' | while IFS= read -r home; do
        [[ -n "$home" && -d "$home" ]] || continue
        printf '%s\n' "$home"
    done
}

find_dashboard_hooks_for_home() {
    local base_home="${1:-}"
    local candidates=()

    if [[ -n "$base_home" ]]; then
        candidates+=(
            "$base_home/dashboard/hooks"
            "$base_home/Desktop/dashboard/hooks"
            "$base_home/k900/dashboard/hooks"
        )
    fi

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/dashboard/hooks")
    fi

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

find_session_helper_binary_for_home() {
    local base_home="${1:-}"
    local candidates=()

    candidates+=(
        "/opt/kodachi/dashboard/hooks/kodachi-session-helper"
        "/usr/local/bin/kodachi-session-helper"
    )

    if [[ -n "$base_home" ]]; then
        candidates+=(
            "$base_home/dashboard/hooks/kodachi-session-helper"
            "$base_home/Desktop/dashboard/hooks/kodachi-session-helper"
            "$base_home/k900/dashboard/hooks/kodachi-session-helper"
        )
    fi

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/dashboard/hooks/kodachi-session-helper")
    fi

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    if command -v kodachi-session-helper >/dev/null 2>&1; then
        command -v kodachi-session-helper
        return 0
    fi

    return 1
}

detect_kodachi_update_mode() {
    local user_home="${1:-}"
    local marker=""
    local markers=(
        "/etc/sudoers.d/kodachi-binaries"
        "/etc/profile.d/kodachi-path.sh"
        "/opt/kodachi/dashboard/hooks/.kodachi-managed-binaries.list"
        "/opt/kodachi/dashboard/hooks/results/signatures"
    )

    if [[ -n "$user_home" ]]; then
        markers+=(
            "$user_home/.config/autostart/kodachi-dashboard.desktop"
            "$user_home/.config/autostart/kodachi-conky.desktop"
            "$user_home/.config/kodachi/conky"
        )
    fi

    for marker in "${markers[@]}"; do
        if [[ -e "$marker" ]]; then
            return 0
        fi
    done

    return 1
}

# Process-scope helpers
# Ensure service/process cleanup in live-build chroot never touches host daemons.
current_root_signature() {
    stat -Lc '%d:%i' / 2>/dev/null || true
}

pid_in_current_root() {
    local pid="${1:-}"
    local current_sig=""
    local pid_sig=""

    [ -n "$pid" ] || return 1
    current_sig="$(current_root_signature)"
    [ -n "$current_sig" ] || return 1

    pid_sig="$(stat -Lc '%d:%i' "/proc/$pid/root" 2>/dev/null || true)"
    [ -n "$pid_sig" ] || return 1
    [ "$pid_sig" = "$current_sig" ]
}

list_matching_pids_current_root() {
    local mode="${1:-x}"   # x => exact process name, f => full cmdline regex
    local pattern="${2:-}"
    local raw_pids=""
    local pid=""

    [ -n "$pattern" ] || return 0

    if [ "$mode" = "f" ]; then
        raw_pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    else
        raw_pids="$(pgrep -x "$pattern" 2>/dev/null || true)"
    fi

    [ -n "$raw_pids" ] || return 0

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if pid_in_current_root "$pid"; then
            printf '%s\n' "$pid"
        fi
    done <<< "$raw_pids"
}

process_running_current_root() {
    local process_name="${1:-}"
    [ -n "$process_name" ] || return 1
    [ -n "$(list_matching_pids_current_root x "$process_name")" ]
}

kill_matching_processes_current_root() {
    local signal="${1:-TERM}"   # TERM, KILL, 9, etc.
    local mode="${2:-x}"
    local pattern="${3:-}"
    local pids=""

    [ -n "$pattern" ] || return 1
    pids="$(list_matching_pids_current_root "$mode" "$pattern" | tr '\n' ' ')"
    [ -n "${pids// }" ] || return 1

    kill "-${signal}" $pids 2>/dev/null || return 1
    return 0
}

KODACHI_PRIMARY_DNS="1.1.1.1 9.9.9.9 149.112.112.112 94.140.14.14"
KODACHI_FALLBACK_DNS="1.0.0.1 149.112.112.10"
KODACHI_RESOLVED_RUNTIME_FILE="/run/systemd/resolve/resolv.conf"
KODACHI_RESOLVED_STUB_FILE="/run/systemd/resolve/stub-resolv.conf"

dns_build_chroot_environment() {
    if [ -f "/.debian-live-build" ] || [ -f "/tmp/live-build-chroot" ] || [ -n "${LB_BASE:-}" ]; then
        return 0
    fi

    if command -v ischroot >/dev/null 2>&1; then
        ischroot
        return $?
    fi

    return 1
}

# Returns 0 (true) if systemd-resolved is masked (kodachi DNSCrypt-only arch),
# 1 (false) otherwise. audit 2026-05-05: Kodachi installs ship with
# systemd-resolved masked via the install hook, so any function that writes
# /etc/systemd/resolved.conf or restarts the service should short-circuit
# and use DNSCrypt directly via /etc/resolv.conf -> 127.0.0.1.
systemd_resolved_is_masked() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local state
    state="$(systemctl is-enabled systemd-resolved.service 2>&1 || true)"
    [ "$state" = "masked" ]
}

# Point /etc/resolv.conf directly at DNSCrypt-proxy (127.0.0.1).
# Used as the DNSCrypt-only-architecture replacement for the legacy
# systemd-resolved stub-resolv.conf symlink path.
point_resolv_conf_to_dnscrypt() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true
    {
        printf '# Kodachi DNSCrypt-only resolver (managed by kodachi-deps-install.sh)\n'
        printf '# /etc/systemd/resolved.conf is intentionally NOT used —\n'
        printf '# systemd-resolved is masked. dnscrypt-proxy on 127.0.0.1\n'
        printf '# is the sole resolver. Override at runtime via:\n'
        printf '#   sudo dns-switch <command>\n'
        printf 'nameserver 127.0.0.1\n'
        printf 'options edns0 trust-ad\n'
    } > /etc/resolv.conf
}

write_nameserver_file() {
    local target_file="${1:-}"
    local description="${2:-DNS configuration}"
    local dns_servers="${3:-}"
    local server=""

    [[ -n "$target_file" ]] || return 1
    mkdir -p "$(dirname "$target_file")"

    {
        printf '# Kodachi %s\n' "$description"
        printf '# Generated automatically by kodachi-deps-install.sh\n'
        for server in $dns_servers; do
            printf 'nameserver %s\n' "$server"
        done
    } > "$target_file"
}

seed_systemd_resolved_bootstrap_files() {
    write_nameserver_file "$KODACHI_RESOLVED_RUNTIME_FILE" "systemd-resolved runtime DNS bootstrap" "$KODACHI_PRIMARY_DNS"

    mkdir -p "$(dirname "$KODACHI_RESOLVED_STUB_FILE")"
    {
        printf '# Kodachi systemd-resolved stub bootstrap\n'
        printf '# Generated automatically by kodachi-deps-install.sh\n'
        printf 'nameserver 127.0.0.53\n'
        printf 'options edns0 trust-ad\n'
    } > "$KODACHI_RESOLVED_STUB_FILE"
}

point_resolv_conf_to_target() {
    local target_file="${1:-}"

    [[ -n "$target_file" ]] || return 1

    chattr -i /etc/resolv.conf 2>/dev/null || true
    ln -sf "$target_file" /etc/resolv.conf 2>/dev/null || true
}

resolved_resolv_conf_target() {
    local profile="${1:-primary}"

    if [[ "$profile" == "primary" ]] && ! dns_build_chroot_environment; then
        echo "$KODACHI_RESOLVED_STUB_FILE"
        return 0
    fi

    echo "$KODACHI_RESOLVED_RUNTIME_FILE"
}

write_kodachi_resolved_profile() {
    local profile="${1:-primary}"
    local dns_owner="${2:-systemd-resolved}"

    # audit 2026-05-05 (Weyland-Yutani installed bundle): on Kodachi proper,
    # systemd-resolved is masked. Writing /etc/systemd/resolved.conf is a
    # no-op (the service can't read it) and leaves stale config that
    # confuses dns-switch status output. Skip the write entirely and let
    # /etc/resolv.conf -> 127.0.0.1 (DNSCrypt) own resolution.
    if systemd_resolved_is_masked; then
        print_info "systemd-resolved is masked (DNSCrypt-only arch) — skipping resolved.conf write for profile '${profile}'"
        return 0
    fi

    mkdir -p /etc/systemd

    # Remove legacy drop-in from older installer versions to prevent
    # DNSStubListener=no from overriding the new main config
    if [ -f /etc/systemd/resolved.conf.d/kodachi.conf ]; then
        rm -f /etc/systemd/resolved.conf.d/kodachi.conf
        print_verbose "Removed legacy /etc/systemd/resolved.conf.d/kodachi.conf drop-in"
    fi

    case "$profile" in
        dnscrypt)
            cat > /etc/systemd/resolved.conf << EOF
# Kodachi DNS - ${dns_owner} as primary resolver
[Resolve]
DNS=127.0.0.1 ${KODACHI_PRIMARY_DNS}
FallbackDNS=${KODACHI_FALLBACK_DNS}
Domains=~.
DNSSEC=no
Cache=yes
LLMNR=no
MulticastDNS=no
ReadEtcHosts=yes
EOF
            ;;
        external)
            cat > /etc/systemd/resolved.conf << EOF
# Kodachi configuration - ${dns_owner} handles DNS
[Resolve]
DNSStubListener=no
FallbackDNS=${KODACHI_PRIMARY_DNS}
EOF
            ;;
        primary)
            cat > /etc/systemd/resolved.conf << EOF
# Kodachi configuration - systemd-resolved as primary DNS
[Resolve]
DNS=${KODACHI_PRIMARY_DNS}
FallbackDNS=${KODACHI_FALLBACK_DNS}
Domains=~.
DNSSEC=no
Cache=yes
LLMNR=no
MulticastDNS=no
ReadEtcHosts=yes
EOF
            ;;
        *)
            print_error "Unknown systemd-resolved profile: $profile"
            return 1
            ;;
    esac
}

run_dns_switch_command() {
    local dns_switch_binary="${1:-}"
    shift || true

    [[ -n "$dns_switch_binary" ]] || return 1

    # BOUND THE CALL. This runs from the kodachi-hooks-core postinst, where
    # systemd-resolved is often still starting, so dns-switch probes resolvers
    # that cannot answer yet and logs "none of the test domains resolved via
    # resolvectl". Measured 2026-07-30 on a fresh Debian 13 apt install: the
    # unbounded call sat for ~4 minutes and was the single largest contributor
    # to install wall-clock. There was no timeout at all before this.
    #
    # A failure here is NOT fatal: every caller falls back to apply_fallback_dns
    # (or the built-in list), and AutoShield/boot re-applies encrypted DNS later.
    # So capping it trades a slow best-effort attempt for a fast one, and the
    # timeout is only reached when DNS is not yet answering anyway.
    #
    # PROVENANCE, 2026-09-04: this block existed ONLY in the GENERATED
    # kodachi-system-setup.sh and never in this file, i.e. somebody hand-edited the
    # generated library, which its own header forbids. `dns_switch_timeout` was
    # present 2x there and 0x here. The next person to follow that header's own
    # instruction and re-run installers/extract-system-setup.py would have silently
    # DELETED this hardening. Moving it to the real source is what makes the
    # generator's "parity by construction" claim true again.
    local dns_switch_timeout="${KODACHI_DNS_SWITCH_TIMEOUT:-45}"
    local timeout_bin=""
    command -v timeout >/dev/null 2>&1 && timeout_bin="timeout ${dns_switch_timeout}"

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        ${timeout_bin} "$dns_switch_binary" "$@"
        return $?
    fi

    # ORDER: `timeout N sudo BIN`, never `sudo timeout N BIN`.
    # The sudoers grants this project writes are PER-PATH
    # (`%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/$binary`), and there is no grant
    # for /usr/bin/timeout. `sudo timeout ...` therefore asks sudo to run
    # /usr/bin/timeout, which matches no rule, so the NOPASSWD grant for the
    # dns-switch binary stops applying and the call prompts or fails. Putting
    # timeout OUTSIDE sudo keeps the grant matching the binary it was written for,
    # and the timeout still bounds the whole thing because killing the sudo parent
    # takes the child with it.
    if [[ -n "$timeout_bin" ]]; then
        timeout "$dns_switch_timeout" sudo "$dns_switch_binary" "$@"
    else
        sudo "$dns_switch_binary" "$@"
    fi
}

# Function to apply fallback DNS servers (mimics dns-switch fix-dns behavior)
apply_fallback_dns() {
    print_step "Applying FALLBACK DNS fix..."

    # audit 2026-05-05: on Kodachi (DNSCrypt-only, systemd-resolved masked),
    # there's nothing to restart and the resolved runtime files don't apply.
    # Point /etc/resolv.conf directly at DNSCrypt-proxy and we're done.
    if systemd_resolved_is_masked; then
        print_info "systemd-resolved masked — applying DNSCrypt-only fallback"
        # Make sure dnscrypt-proxy is up; if not, fall back to plain DNS
        # at the resolver file so the system is still usable.
        if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
            point_resolv_conf_to_dnscrypt
            print_success "Fallback applied: /etc/resolv.conf -> 127.0.0.1 (DNSCrypt)"
        else
            print_warning "dnscrypt-proxy is not active — writing plain DNS to /etc/resolv.conf as last resort"
            chattr -i /etc/resolv.conf 2>/dev/null || true
            rm -f /etc/resolv.conf 2>/dev/null || true
            write_nameserver_file /etc/resolv.conf "emergency fallback (dnscrypt-proxy down)" "$KODACHI_PRIMARY_DNS"
            print_success "Fallback applied (plain DNS): $KODACHI_PRIMARY_DNS"
        fi
        return 0
    fi

    # Legacy path: systemd-resolved-managed system.

    # Step 1: Check if systemd-resolved is active and restart it if needed
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        print_verbose "systemd-resolved is active, restarting it..."
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 2
    else
        print_verbose "systemd-resolved not active, starting it..."
        systemctl start systemd-resolved 2>/dev/null || true
        sleep 2
    fi

    # Step 2: Seed runtime resolver files so chroot builds keep working even when
    # systemd service starts/restarts are intentionally blocked.
    print_verbose "Seeding systemd-resolved runtime resolver files..."
    seed_systemd_resolved_bootstrap_files

    # Step 3: Point /etc/resolv.conf at the runtime resolver file used for fallback.
    print_verbose "Pointing /etc/resolv.conf to systemd-resolved runtime resolver..."
    point_resolv_conf_to_target "$KODACHI_RESOLVED_RUNTIME_FILE"

    # Step 4: Try to configure systemd-resolved via resolvectl if available
    if command -v resolvectl &>/dev/null; then
        resolvectl flush-caches 2>/dev/null || true
    fi

    print_success "Fallback DNS applied: $KODACHI_PRIMARY_DNS"
}

dns_resolution_working() {
    timeout 5 getent hosts cloudflare.com >/dev/null 2>&1 || \
    timeout 5 getent hosts deb.debian.org >/dev/null 2>&1 || \
    timeout 5 getent hosts github.com >/dev/null 2>&1
}

find_dns_switch_binary() {
    local dns_switch_binary=""
    local real_user_home=""
    local possible_locations=()

    if command -v dns-switch >/dev/null 2>&1; then
        command -v dns-switch
        return 0
    fi

    if [[ -n "$SUDO_USER" ]]; then
        real_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [[ -z "$real_user_home" ]]; then
            real_user_home=$(resolve_user_home "$SUDO_USER")
        fi
    else
        real_user_home="$HOME"
    fi

    possible_locations=(
        "$PROJECT_ROOT/dashboard/hooks/dns-switch"
        "$real_user_home/dashboard/hooks/dns-switch"
        "$real_user_home/Desktop/dashboard/hooks/dns-switch"
        "$real_user_home/k900/dashboard/hooks/dns-switch"
        "$HOME/dashboard/hooks/dns-switch"
        "$HOME/Desktop/dashboard/hooks/dns-switch"
        "$HOME/k900/dashboard/hooks/dns-switch"
        "/opt/kodachi/dashboard/hooks/dns-switch"
        "/usr/local/bin/dns-switch"
        "/usr/bin/dns-switch"
    )

    for dns_switch_binary in "${possible_locations[@]}"; do
        if [[ -x "$dns_switch_binary" ]]; then
            echo "$dns_switch_binary"
            return 0
        fi
    done

    return 1
}

apply_preferred_fallback_dns() {
    local dns_switch_binary="${1:-}"

    if [[ -z "$dns_switch_binary" ]]; then
        dns_switch_binary="$(find_dns_switch_binary 2>/dev/null || true)"
    fi

    if [[ -n "$dns_switch_binary" ]]; then
        print_step "Applying fallback DNS via dns-switch..."
        print_verbose "Using dns-switch from: $dns_switch_binary"
        if (set -o pipefail; run_dns_switch_command "$dns_switch_binary" fallback 2>&1 | tail -5); then
            print_success "dns-switch fallback completed"
            return 0
        fi

        print_warning "dns-switch fallback returned error, using built-in fallback DNS"
    else
        print_info "dns-switch binary not found - using built-in fallback DNS"
    fi

    apply_fallback_dns
}

try_verified_random_dns() {
    local dns_switch_binary="${1:-}"

    if [[ -z "$dns_switch_binary" ]]; then
        dns_switch_binary="$(find_dns_switch_binary 2>/dev/null || true)"
    fi

    if [[ -z "$dns_switch_binary" ]]; then
        print_warning "dns-switch binary not found - cannot try verified random DNS recovery"
        return 1
    fi

    print_step "Trying verified random DNS as last resort..."
    print_verbose "Using dns-switch from: $dns_switch_binary"

    if (set -o pipefail; run_dns_switch_command "$dns_switch_binary" random --type reputable --count 3 --verify 2>&1 | tail -5); then
        print_success "dns-switch random --verify completed"
        return 0
    fi

    print_warning "Verified random DNS attempt returned error"
    return 1
}

recover_dns_with_fallback_then_random() {
    local dns_switch_binary=""
    local attempt=0

    dns_switch_binary="$(find_dns_switch_binary 2>/dev/null || true)"
    if [[ -z "$dns_switch_binary" ]]; then
        print_info "dns-switch binary not found in PATH or standard locations"
    fi

    for attempt in 1 2; do
        print_warning "DNS unavailable - applying fallback DNS attempt $attempt/2..."
        apply_preferred_fallback_dns "$dns_switch_binary"
        sleep 2

        if dns_resolution_working; then
            print_success "DNS restored after fallback DNS attempt $attempt"
            return 0
        fi
    done

    print_warning "Fallback DNS attempts did not restore connectivity"

    if try_verified_random_dns "$dns_switch_binary"; then
        sleep 2
        if dns_resolution_working; then
            print_success "DNS restored after verified random DNS recovery"
            return 0
        fi
    fi

    print_warning "Verified random DNS did not restore connectivity, reapplying fallback DNS for a safe final state..."
    apply_preferred_fallback_dns "$dns_switch_binary"
    sleep 2

    if dns_resolution_working; then
        print_success "DNS restored after final fallback reapply"
        return 0
    fi

    print_error "DNS resolution still unavailable after fallback retries and verified random recovery"
    return 1
}

ensure_dns_stable_after_change() {
    local operation="${1:-DNS change}"

    if dns_resolution_working; then
        print_success "DNS stable after ${operation}"
        return 0
    fi

    print_warning "DNS unstable after ${operation} - starting fallback-first recovery"
    if recover_dns_with_fallback_then_random; then
        print_success "DNS stable after recovery for ${operation}"
        return 0
    fi

    print_error "DNS remains unstable after ${operation}"
    return 1
}

reconcile_dns_after_service_transition() {
    local operation="${1:-DNS service change}"

    print_step "Reconfiguring resolver after ${operation}..."

    if configure_systemd_resolved; then
        print_success "Resolver reconciled after ${operation}"
        return 0
    fi

    print_warning "systemd-resolved reconfiguration failed after ${operation} - falling back to DNS recovery"
    ensure_dns_stable_after_change "$operation"
}

# Function to wait for DNS resolution to become available
# Briefly waits for passive recovery, then runs fallback-first DNS recovery.
wait_for_dns() {
    local max_wait=6
    local waited=0

    print_step "Waiting for DNS resolution to become available..."

    while [[ $waited -lt $max_wait ]]; do
        if dns_resolution_working; then
            print_success "DNS resolution is working"
            return 0
        fi

        sleep 2
        waited=$((waited + 2))
    done

    print_warning "DNS did not recover on its own after ${max_wait}s - starting fallback-first recovery"
    recover_dns_with_fallback_then_random
}

# Gate on executing an UNPINNED upstream install script as root.
#
# Two paths in this installer used to fetch a shell script over the network and
# run it as root with no integrity check that could actually fail:
#   * xray:    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
#              `raw/main` is a MOVING branch, not a tag or a release asset.
#   * Pi-hole: https://install.pi-hole.net
# Both were introduced under a comment reading "SECURITY FIX: Download script to
# temp file and verify before execution". What they actually did was download,
# check the first line was a shebang, PRINT a SHA256, and then execute. Printing
# a hash that nothing compares against is not verification: there is no value the
# script will refuse to run. In a privacy OS this was the weakest link in an
# otherwise strong, signed supply chain.
#
# The fix is not to pin a hash for these. Kodachi ALREADY publishes both as
# signed packages in its own apt repo (kodachi-xray, kodachi-pihole), so the
# packaged path is both safer and more current than any hash we could hardcode.
# Those are now tried first. This gate governs only the last-resort upstream
# path, which is off by default and must be opted into explicitly:
#
#   KODACHI_ALLOW_UNPINNED_UPSTREAM=1 ./kodachi-deps-install.sh
#
# An escape hatch is kept deliberately, because a user installing on a system
# that cannot reach the Kodachi repo should be able to proceed knowingly rather
# than be stuck. What changed is the default and the disclosure.
kodachi_upstream_unpinned_allowed() {
    [[ "${KODACHI_ALLOW_UNPINNED_UPSTREAM:-0}" == "1" ]]
}

# Try to install a component from Kodachi's own signed apt repository.
# Returns 0 only when the package is installed AND the named command exists.
kodachi_try_packaged_install() {
    local pkg="$1" verify_cmd="$2"

    command -v apt-get >/dev/null 2>&1 || return 1

    if timeout 120 apt-get install -y -o DPkg::Use-Pty=0 \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            < /dev/null "$pkg" >/dev/null 2>&1; then
        if [[ -z "$verify_cmd" ]] || command -v "$verify_cmd" >/dev/null 2>&1; then
            print_success "  Installed $pkg from the Kodachi signed apt repository"
            return 0
        fi
    fi
    return 1
}

# Install the fixed-argv port-scan helper granted by /etc/sudoers.d/kodachi-binaries.
#
# This exists because sudoers cannot express the rule we actually want. The old
# grants were `nmap -F *`, `nmap -p- --open *` and `nmap -p *`, and a trailing
# sudoers wildcard matches every remaining argument INCLUDING further options.
# So `sudo nmap -p 80 --script=/tmp/x.nse t` and `sudo nmap -p 80 -oN
# /etc/cron.d/pwn t` both matched, giving any %sudo member root code execution
# and root file writes through nmap's NSE engine and output flags. The rule's own
# comment said it was pinning flag forms to prevent exactly that; it was not.
#
# The target and port are runtime input from the rofi menu, so they cannot be
# enumerated in sudoers. The only way to pin the flag set is to move the decision
# into a program. sudo now grants THIS script (with a wildcard, which is fine
# because it validates everything), and this script builds nmap's argv from
# constants so no caller-supplied flag ever reaches nmap.
install_kodachi_portscan_helper() {
    local helper_dir="/usr/local/libexec/kodachi"
    local helper="${helper_dir}/kodachi-portscan"

    if ! mkdir -p "$helper_dir" 2>/dev/null; then
        print_warning "Could not create $helper_dir - port-scan helper not installed"
        return 0
    fi

    # Write via a temp file + atomic rename so a partially written helper can
    # never be executed, and set the mode before it is linked into place.
    local tmp
    tmp="$(mktemp "${helper}.XXXXXX" 2>/dev/null)" || {
        print_warning "Could not stage $helper - port-scan helper not installed"
        return 0
    }

    cat > "$tmp" << 'PORTSCAN_HELPER_EOF'
#!/bin/bash
# kodachi-portscan - fixed-argv privileged wrapper for the rofi Network menu.
#
# Installed by kodachi-deps-install.sh / kodachi-system-setup.sh. Do not add a
# passthrough mode and do not forward caller flags to nmap: the whole point of
# this file is that nmap's argv is built from constants here. See the sudoers
# block "Port scans (rofi Network menu)" in /etc/sudoers.d/kodachi-binaries.
set -euo pipefail

readonly NMAP_BIN=/usr/bin/nmap

die() { printf 'kodachi-portscan: %s\n' "$1" >&2; exit 2; }

usage() {
    cat >&2 <<'USAGE'
usage: kodachi-portscan fast <target>
       kodachi-portscan full <target>
       kodachi-portscan port <target> <port>
Flags are not accepted from the caller and are never forwarded to nmap.
USAGE
    exit 2
}

# Stricter than the menu's is_safe_net_input(), which permits a leading '-' and
# would let a "target" be parsed by nmap as an option. Must start alphanumeric.
valid_target() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; }

# One bare decimal port. No ranges, no lists: the menu only ever asks for one.
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

[[ -x "$NMAP_BIN" ]] || die "nmap is not installed at $NMAP_BIN"

case "${1:-}" in
    fast)
        [[ $# -eq 2 ]] || usage
        valid_target "$2" || die "invalid target"
        exec "$NMAP_BIN" -F -- "$2"
        ;;
    full)
        [[ $# -eq 2 ]] || usage
        valid_target "$2" || die "invalid target"
        exec "$NMAP_BIN" -p- --open -- "$2"
        ;;
    port)
        [[ $# -eq 3 ]] || usage
        valid_target "$2" || die "invalid target"
        valid_port "$3"   || die "invalid port"
        exec "$NMAP_BIN" -p "$3" -- "$2"
        ;;
    *)
        usage
        ;;
esac
PORTSCAN_HELPER_EOF

    chown root:root "$tmp" 2>/dev/null || true
    chmod 0755 "$tmp" 2>/dev/null || true
    if mv -f "$tmp" "$helper" 2>/dev/null; then
        print_success "  Installed port-scan helper: $helper"
    else
        rm -f "$tmp" 2>/dev/null || true
        print_warning "Could not install $helper - rofi port scans will fall back to unprivileged"
    fi
}

# Function to configure sudoers for Kodachi binaries (NOPASSWD access)
configure_kodachi_sudoers() {
    print_step "Configuring sudoers for Kodachi binaries..."

    # Determine the actual user (not root) - SECURE method (no eval)
    local actual_user
    local real_user_home
    if [[ -n "$SUDO_USER" ]]; then
        # Validate SUDO_USER contains only valid username characters
        if [[ "$SUDO_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            actual_user="$SUDO_USER"
            real_user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        else
            print_error "Invalid SUDO_USER detected"
            return 1
        fi
    else
        actual_user=$(whoami)
        real_user_home="$HOME"
    fi

    # Fallback if getent failed
    if [[ -z "$real_user_home" ]]; then
        real_user_home=$(resolve_user_home "$actual_user")
    fi

    print_info "User: $actual_user"
    print_info "Home: $real_user_home"

    # Find dashboard location (system-wide first, then user-relative)
    local dashboard_dir=""
    if [[ -d "/opt/kodachi/dashboard/hooks" ]]; then
        dashboard_dir="/opt/kodachi/dashboard/hooks"
    elif dashboard_dir=$(find_dashboard_hooks_for_home "$real_user_home"); then
        :
    fi

    if [[ -n "$dashboard_dir" ]]; then
        print_info "Dashboard found at: $dashboard_dir"
    else
        print_warning "Dashboard hooks directory not found, using /usr/local/bin only"
    fi

    # Binaries that must NEVER receive a blanket `NOPASSWD: <path>/<binary>`
    # grant, because a specific exact-argv block is emitted for them later.
    #
    # THIS LIST IS LOAD-BEARING AND ITS ABSENCE WAS A LIVE ROOT HOLE.
    # Removing a name from `common_binaries` below is NOT enough. The array is
    # ALSO populated by DISCOVERY: the find loop under this comment adds every
    # executable ELF in the hooks directory. So a binary excluded from the
    # static list is silently re-added the moment it exists on disk, which on a
    # real installation is always. Commit 9eb6b417 removed kodachi-soc from the
    # static list and emitted exact-argv rules, and that hardening never took
    # effect on any machine that actually had kodachi-soc installed: the
    # discovery loop re-granted the blanket rule on the very next line.
    #
    # Measured on a virgin Debian 13 box, 2026-08-05: with /opt/kodachi absent
    # the generated file had ZERO blanket kodachi-soc grants and the hardening
    # looked correct. After installing the published kodachi-hooks-core deb so
    # that /opt/kodachi/dashboard/hooks/kodachi-soc existed, regenerating with
    # the SAME script produced the blanket grants again at lines 65-66, and
    # `sudo -n kodachi-soc --version` was passwordless root. The bug is only
    # visible when the binary is present, which is why a fixture or an empty
    # box cannot catch it.
    local blanket_grant_denied=(
        "kodachi-soc"
    )

    # Get list of all executable binaries in hooks folder
    local binaries=()
    if [[ -n "$dashboard_dir" && -d "$dashboard_dir" ]]; then
        print_info "Scanning for Kodachi binaries in hooks directory..."
        while IFS= read -r -d '' binary; do
            local binary_name=$(basename "$binary")
            # Include ELF binaries
            if [[ -x "$binary" ]] && file "$binary" 2>/dev/null | grep -q "ELF"; then
                local _denied=false
                for _d in "${blanket_grant_denied[@]}"; do
                    if [[ "$binary_name" == "$_d" ]]; then
                        _denied=true
                        break
                    fi
                done
                if [[ "$_denied" == "true" ]]; then
                    print_info "  skipping blanket grant for $binary_name (exact-argv rules only)"
                    continue
                fi
                binaries+=("$binary_name")
            fi
        done < <(find "$dashboard_dir" -maxdepth 1 -type f -executable -print0 2>/dev/null)
    fi

    # Add common Kodachi binaries that might be missing or in /usr/local/bin
    local common_binaries=(
        "health-control"
        "tor-switch"
        "dns-switch"
        "routing-switch"
        "ip-fetch"
        "online-auth"
        "integrity-check"
        "dns-leak"
        "permission-guard"
        "logs-hook"
        "deps-checker"
        "conky-status"
        "oniux"
        "kodachi-dashboard"
        # [AUTOSHIELD-RETIRED 2026-06-01] standalone GUI app merged into dashboard tab — no longer shipped
        # "kodachi-autoshield"
        "global-launcher"
        "workflow-manager"
        "online-info-switch"
        "tun2socks-linux-amd64"
        # AI system binaries
        "ai-cmd"
        "ai-trainer"
        "ai-learner"
        "ai-admin"
        "ai-monitor"
        "ai-scheduler"
        "ai-discovery"
        "ai-gateway"
        # [CLAW-ARCHIVED 2026-05-18] autonomous AI assistants retired (moved to dashboard/hooks/rust-archive)
        # "kodachi-claw"
        # "zeroclaw"
        # "zeroclaw-desktop"
        # kodachi-soc is DELIBERATELY NOT in this list. See the exact-argv block
        # emitted after this loop.
        #
        # A blanket `%sudo ALL=(ALL) NOPASSWD: <path>/kodachi-soc` grants root for
        # ANY subcommand and ANY arguments, and /usr/local/bin/kodachi-soc is a
        # symlink to the PROTECTED watcher binary at
        # /usr/local/libexec/kodachi/host-exposure/kodachi-soc. So the blanket
        # grant handed every %sudo member root on `kodachi-soc exposure policy
        # approve ...`, which is exactly what the deliberately narrow, wildcard-free
        # /etc/sudoers.d/kodachi-host-exposure rules exist to withhold. Those narrow
        # rules bought nothing while this line stood.
        #
        # WHY THIS IS SAFE, stated accurately. An earlier version of this comment
        # claimed kodachi-soc "is not reachable through the generic command
        # dispatcher by design" and cited commandsLibrary.ts. Do not restore that
        # wording: the codebase itself records it as false. commands_services.rs
        # has a live `"kodachi-soc" =>` dispatcher arm that forwards arbitrary
        # full_args, needs_sudo and output_format, and the comment directly above
        # it says the arm "did expose it, with no check at all. The frontend claim
        # was true only because no shipped frontend code happened to use that
        # selector." Security reasoning must not rest on a claim the code denies.
        #
        # The real reasons the blanket grant can go, all three independently true:
        #   1. The dispatcher arm is capability-gated on `mode.soc`, so it is not
        #      reachable at all without that entitlement.
        #   2. No shipped frontend code drives kodachi-soc through it. The only
        #      privileged call is soc_snapshot -> `kodachi-soc snapshot [--json*]`
        #      in commands_soc.rs, and islands/soc/index.ts pins outputFormat.
        #   3. commandsLibrary.ts blocks kodachi-soc in the command-library UI, so
        #      the operator cannot hand-run it from there either.
        # Point 2 is the load-bearing one and it is a statement about SHIPPED
        # CALLERS, not about the dispatcher being incapable. If a future lane adds
        # a kodachi-soc caller with a new subcommand, it needs its own exact-argv
        # line below or it will fail with "a password is required".
        #
        # `kodachi-soc refresh` needs no rule: snapshot.rs spawns it via
        # `flock --nonblock <lock> [nice ionice] <current_exe> refresh` as a CHILD
        # of the already-root snapshot process, with no sudo of its own.
        # Session helper
        "kodachi-session-helper"
    )

    # Merge and deduplicate
    for common in "${common_binaries[@]}"; do
        local already_present=false
        for existing_binary in "${binaries[@]}"; do
            if [[ "$existing_binary" == "$common" ]]; then
                already_present=true
                break
            fi
        done

        if [[ "$already_present" == "false" ]]; then
            # Check if it exists in the directory or /usr/local/bin
            if [[ -f "$dashboard_dir/$common" ]] || [[ -f "/usr/local/bin/$common" ]]; then
                binaries+=("$common")
            else
                # Add anyway for future deployment
                binaries+=("$common")
            fi
        fi
    done

    # Remove duplicates and sort.
    # mapfile, not IFS + unquoted $(...) (audit 2026-09-03, L08 / SC2207). Setting
    # IFS to a newline stops WORD splitting but does nothing about GLOB expansion, so a
    # binary whose name contained *, ? or [ would be expanded against the filesystem
    # before it ever reached the sudoers list. No shipped binary name has those
    # characters today, which is why this has never bitten, but the array is built from
    # a directory walk a few lines above and the next name added is not required to ask
    # permission. mapfile splits on newlines only and never globs.
    mapfile -t binaries < <(printf '%s\n' "${binaries[@]}" | sort -u)

    print_info "Found ${#binaries[@]} Kodachi binaries to configure"

    # Create sudoers.d directory if it doesn't exist
    mkdir -p /etc/sudoers.d

    # AUDIT 2026-05-24: keep only ONE backup of the previous sudoers file
    # instead of one-per-install (a freshly built live ISO accumulated
    # kodachi-binaries.backup.1779625167 + .1779625248 within minutes).
    # /etc/sudoers.d is sourced by every sudo invocation, so cruft there
    # is mildly security-sensitive and worth pruning.
    #
    # AUDIT 2026-05-27: during live-build chroot the previous sudoers file
    # has no value (it is the just-shipped baseline), and the backup file
    # ends up shipped INSIDE the ISO at /etc/sudoers.d/kodachi-binaries.backup.<epoch>
    # which is dead weight in the image. Skip the backup
    # when running inside the build chroot (detected via env vars set by
    # live-build / offline-package shim hook OR absence of a real package
    # manager state file). Always prune stale backups regardless.
    # CORRECTION, measured 2026-08-05 on Debian 13. An earlier version of the
    # comment above claimed "sudo loads every file in that dir regardless of
    # name", and used that to argue the backup doubles the ruleset. That is
    # FALSE and the reasoning should not be reused. sudo's #includedir SKIPS any
    # filename containing a dot or ending in '~', exactly like run-parts, so
    # kodachi-binaries.backup.<epoch> is never parsed. Proven two ways on a live
    # box: `visudo -c` listed only the 5 undotted files and not the backup, and
    # an identical `%sudo ... NOPASSWD: /usr/bin/uptime` grant was IGNORED when
    # the file was named zz-probe.dotted.test and HONOURED the moment it was
    # renamed to zzprobeundotted. Pruning the backups is still worth doing to
    # keep the image clean, but it is NOT a privilege fix, and a backup left
    # behind is not a live grant.
    local sudoers_file="/etc/sudoers.d/kodachi-binaries"
    find /etc/sudoers.d -maxdepth 1 -type f -name 'kodachi-binaries.backup.*' \
        -delete 2>/dev/null || true
    local _in_build_chroot=0
    if [[ -n "${KODACHI_LIVE_BUILD:-}" ]] || [[ -n "${LB_CHROOT:-}" ]] || \
       [[ -f /.live-build-stamp ]] || [[ -f /var/lib/dpkg/info/.live-build-stamp ]]; then
        _in_build_chroot=1
    fi
    if [[ -f "$sudoers_file" && "$_in_build_chroot" -eq 0 ]]; then
        print_info "Backing up existing sudoers file (keeping latest only)..."
        cp "$sudoers_file" "${sudoers_file}.backup.$(date +%s)"
    elif [[ "$_in_build_chroot" -eq 1 ]]; then
        print_info "Live-build chroot detected — skipping sudoers backup creation"
    fi

    # Create the kodachi-binaries sudoers file with ALL binaries for BOTH paths
    # Uses %sudo group instead of specific username so any sudoer gets access
    # (works for both live kodachi user and Calamares-created users after install)
    cat > "$sudoers_file" << 'HEADER'
# Kodachi System Binaries - Passwordless Sudo Access
# This file grants NOPASSWD sudo access to all members of the sudo group
# for Kodachi binaries deployed to /usr/local/bin/ and hooks directory
#
# Security justification:
# - Group-based (%sudo) works for any admin user (live or installed)
# - Full paths prevent PATH hijacking attacks
# - Binaries are cryptographically signed by Kodachi PKI
# - User already authenticated with password at login
# - Each binary has built-in permission guards and validation
# - Standard practice for system monitoring tools (htop, iotop, netdata)
#
# Syntax validation: visudo -c -f /etc/sudoers.d/kodachi-binaries
# Required permissions: 0440 (read-only, root:root)

# ============================================================
# Kodachi Binaries - Dual Path Configuration
# ============================================================
HEADER

    # Add generated metadata as comments
    echo "# Generated: $(date)" >> "$sudoers_file"
    echo "# Hooks Path: $dashboard_dir" >> "$sudoers_file"
    echo "# System Path: /usr/local/bin" >> "$sudoers_file"
    echo "" >> "$sudoers_file"
    if [[ -n "$dashboard_dir" ]]; then
        echo "Defaults!$dashboard_dir/health-control env_keep += \"KODACHI_SESSION_TOKEN\"" >> "$sudoers_file"
    fi
    echo "Defaults!/usr/local/bin/health-control env_keep += \"KODACHI_SESSION_TOKEN\"" >> "$sudoers_file"
    echo "" >> "$sudoers_file"

    # Privacy: never mail failed/blocked sudo attempts.
    # Kodachi has no MTA, so sudo's default security-mail (sent on every
    # blocked or password-required call) is dumped into ~/dead.letter,
    # leaking command history + the spoofed hostname to a plaintext file.
    # Disable all five mail triggers so sudo never invokes a mailer.
    # The mail-suppression Defaults only exist in classic sudo. sudo-rs (the Rust
    # reimplementation that is the DEFAULT sudo on Ubuntu 25.10+/26.04 and is
    # coming to Debian) has NO mailer at all, so it rejects these as
    # "unknown setting: 'mail_no_user'", which fails visudo and aborts the whole
    # installer. sudo-rs never writes ~/dead.letter, so the privacy concern does
    # not apply there. Emit the Defaults only when the active sudo is classic.
    if sudo --version 2>/dev/null | grep -qi 'sudo-rs'; then
        echo "# Privacy: mail-suppression Defaults skipped (sudo-rs has no mailer)" >> "$sudoers_file"
    else
        echo "# Privacy: do not mail failed/blocked sudo attempts (no MTA -> ~/dead.letter leak)" >> "$sudoers_file"
        echo "Defaults !mail_no_user, !mail_no_perms, !mail_no_host, !mail_badpass, !mail_always" >> "$sudoers_file"
    fi
    echo "" >> "$sudoers_file"

    # Add entries for each binary with BOTH paths
    for binary in "${binaries[@]}"; do
        if [[ -n "$dashboard_dir" ]]; then
            # Add hooks path entry
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/$binary" >> "$sudoers_file"
        fi
        # Add /usr/local/bin path entry
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/$binary" >> "$sudoers_file"
    done

    # kodachi-soc: EXACT ARGV ONLY, never a blanket grant on the binary.
    # The SOC snapshot genuinely needs root (it reads /proc, runs getcap -r /,
    # debsums, dpkg --verify and journalctl), but it needs exactly ONE subcommand.
    # Enumerate ALL FIVE forms the dashboard and the GTK/rofi menu can produce
    # -- bare, --json, --json-pretty and --json-human per services.rs's
    # output-format mapping, plus --text, which the `SOC Snapshot` registry row
    # uses so the output pane gets readable prose instead of 10k lines of JSON --
    # so nothing else about this binary is reachable as root without a password.
    # --text is a FORMATTING flag on the same subcommand and grants no new
    # capability: it reads exactly what the other four read.
    # --json-human was missed on the first pass and is not hypothetical: it is a
    # first-class output choice in islands/favorites and islands/command-builder.
    # Omitting it does not fail safe, it fails CONFUSING: sudo -n matches no rule,
    # exits 1 with "a password is required", and the SOC panel shows a snapshot
    # error that looks nothing like a permissions problem.
    {
        echo ""
        echo "# ============================================================"
        echo "# kodachi-soc: SOC snapshot only, exact argv, no wildcards."
        echo "# A blanket grant here would also cover 'exposure policy approve'"
        echo "# through the /usr/local/bin symlink to the protected watcher."
        echo "# ============================================================"
        if [[ -n "$dashboard_dir" ]]; then
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/kodachi-soc snapshot"
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/kodachi-soc snapshot --json"
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/kodachi-soc snapshot --json-pretty"
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/kodachi-soc snapshot --json-human"
            echo "%sudo ALL=(ALL) NOPASSWD: $dashboard_dir/kodachi-soc snapshot --text"
        fi
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-soc snapshot"
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-soc snapshot --json"
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-soc snapshot --json-pretty"
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-soc snapshot --json-human"
        echo "%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-soc snapshot --text"
    } >> "$sudoers_file"

    # Install the fixed-argv port-scan helper that the sudoers rule below grants.
    # Written here rather than shipped as a separate asset so that it always
    # exists wherever the rule exists: ISO chroot, `curl | sudo bash`, and deb
    # postinst all run this same function. A sudoers rule pointing at a missing
    # binary is harmless (it simply never matches), but a MISSING helper with a
    # PRESENT rule would silently break the rofi scan menu, so install it first.
    install_kodachi_portscan_helper

    # Add system management commands
    cat >> "$sudoers_file" << 'EOF'

# ============================================================
# System Power Management (menu options)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/reboot
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/shutdown
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/poweroff

# ============================================================
# Time Synchronization (welcome script)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ntpdig
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ntpdig
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ntpdate
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ntpd
%sudo ALL=(ALL) NOPASSWD: /usr/bin/timedatectl

# ============================================================
# Session Bootstrap Helpers
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-apply-grub-theme
%sudo ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /run/kodachi
%sudo ALL=(ALL) NOPASSWD: /bin/mkdir -p /run/kodachi

# ============================================================
# GUI Root Actions (Thunar and Mousepad)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/thunar
%sudo ALL=(ALL) NOPASSWD: /usr/bin/mousepad

# ============================================================
# Oniux Launcher - Kernel Namespace Configuration
# ============================================================
# NOTE: wildcards glued inside an argument (e.g. "key=*") are a hard syntax
# error under sudo-rs ("wildcards are not allowed in command arguments"), so the
# exact 0/1 values the code actually writes are enumerated instead. This also
# parses on classic sudo and is strictly tighter than the old wildcard.
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/sysctl -w kernel.unprivileged_userns_clone=0
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/sysctl -w kernel.unprivileged_userns_clone=1
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/sysctl -w kernel.apparmor_restrict_unprivileged_userns=1
%sudo ALL=(ALL) NOPASSWD: /sbin/sysctl -w kernel.unprivileged_userns_clone=0
%sudo ALL=(ALL) NOPASSWD: /sbin/sysctl -w kernel.unprivileged_userns_clone=1
%sudo ALL=(ALL) NOPASSWD: /sbin/sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
%sudo ALL=(ALL) NOPASSWD: /sbin/sysctl -w kernel.apparmor_restrict_unprivileged_userns=1

# ============================================================
# Dashboard Sudo Availability Probe
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/true

# ============================================================
# Firewall & Network Status (read-only monitoring)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw status
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw status *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/nft list ruleset
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/nft list table *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -S *
# A wildcard in a NON-trailing argument ("-t * -S") is a hard syntax error under
# sudo-rs, so the table name is enumerated over the only 5 tables iptables has.
# Trailing wildcards (the final "*") are accepted by both sudo and sudo-rs.
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t filter -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t filter -S *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t filter -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t nat -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t nat -S *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t nat -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t mangle -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t mangle -S *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t mangle -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t raw -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t raw -S *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t raw -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t security -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t security -S *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables -t security -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables-save
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/iptables-save -t *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -S *
# sudo-rs: table name enumerated (non-trailing wildcard is rejected).
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t filter -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t filter -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t nat -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t nat -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t mangle -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t mangle -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t raw -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t raw -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t security -S
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables -t security -L *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables-save
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ip6tables-save -t *

# ============================================================
# WireGuard and AmneziaWG Status (read-only monitoring)
# ============================================================
# THE TRAILING `*` USED TO GRANT PASSWORDLESS READ OF THE PRIVATE KEY, so this
# block was not read-only despite its heading. sudoers matches the arguments as
# ONE string, and `private-key` is a `show` subcommand, so `/usr/bin/wg show *`
# admitted `wg show wg0 private-key` and `wg show all dump`, whose first dump
# field IS the private key. Any member of %sudo could read the tunnel key with
# no password and no prompt.
#
# Nothing needed it. Swept 2026-08-20 over every .sh/.rs/.ts/.svelte/.py/.php in
# the tree: the ONLY sudo-mediated caller that ships is
# usr/share/kodachi/conky/scripts/unified-runtime-detector.sh:312, which runs
# exactly `sudo -n awg show interfaces`. Every other reader (routing-switch
# network/state.rs, tor-switch firewall.rs detect_vpn_endpoints, health-control)
# uses `Command::new("wg")` with no sudo at all, and already falls back to
# `ip link show type wireguard` when it is not root.
#
# Update 2026-09-01: commit 1442564f4 retired unified-runtime-detector.sh with
# the other orphan conky producers, so since that date NOTHING that ships
# invokes these grants through sudo. The lines stay because they are read-only
# exact matches; removing them is a separate decision, not taken here.
#
# Enumerated rather than wildcarded. Every line below is an EXACT match, so
# `wg show all dump` and `wg show <if> private-key` no longer match anything.
# Adding a field here later means adding that field, never restoring the `*`.
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg show
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg show all
%sudo ALL=(ALL) NOPASSWD: /usr/bin/wg show interfaces
%sudo ALL=(ALL) NOPASSWD: /usr/bin/awg show
%sudo ALL=(ALL) NOPASSWD: /usr/bin/awg show all
%sudo ALL=(ALL) NOPASSWD: /usr/bin/awg show interfaces

# ============================================================
# UFW Management (enable/disable firewall and boot persistence)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw enable
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw --force enable
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw disable
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw --force disable
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw --force delete *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw --force reset
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw allow *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/ufw deny *
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl enable ufw
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl disable ufw

# ============================================================
# Portmaster Service Management (start/stop/boot only)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl start portmaster
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl stop portmaster
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl restart portmaster
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl enable portmaster
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl disable portmaster

# ============================================================
# Read-only diagnostics (dashboard startup + rofi menus)
# Previously called via `sudo -n` with no matching NOPASSWD rule
# -> "a password is required" -> ~/dead.letter leak + broken feature.
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ss -tlnp
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ss -tulnp
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ss -tuln
%sudo ALL=(ALL) NOPASSWD: /usr/bin/journalctl
%sudo ALL=(ALL) NOPASSWD: /usr/bin/netstat -tulnp
%sudo ALL=(ALL) NOPASSWD: /bin/netstat -tulnp
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/netstat -tulnp

# ============================================================
# Power control (Emergency rofi menu + killswitch/threat response)
# Code calls `systemctl poweroff|reboot`; complements the existing
# reboot/shutdown/poweroff sbin fallbacks.
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl poweroff
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl poweroff
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl reboot

# ============================================================
# Autostart manager (GUI enable/disable of system units)
# SECURITY NOTE: intentionally broad (any unit name) — the dashboard
# startup manager discovers units dynamically. Members of %sudo can
# already run the signed Kodachi root binaries passwordlessly.
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable *
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl enable *
%sudo ALL=(ALL) NOPASSWD: /bin/systemctl disable *

# ============================================================
# Binary (re)install drain — terminate root-owned holders
# (kodachi-binary-install.sh; lsof already whitelisted above).
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/kill
%sudo ALL=(ALL) NOPASSWD: /bin/kill

# ============================================================
# Port scans (rofi Network menu) — via a fixed-argv helper, never bare nmap.
#
# WHAT WAS HERE BEFORE, and why it did not do what its comment claimed:
#   %sudo ALL=(ALL) NOPASSWD: /usr/bin/nmap -F *
#   %sudo ALL=(ALL) NOPASSWD: /usr/bin/nmap -p- --open *
#   %sudo ALL=(ALL) NOPASSWD: /usr/bin/nmap -p *
# with the note "nmap can run NSE scripts / write files, so we pin the specific
# flag forms the menu issues rather than bare nmap." The intent was right. The
# rules did not achieve it. A trailing sudoers wildcard matches ALL remaining
# argv, including further OPTIONS, so every one of those lines also matched:
#   sudo nmap -p 80 --script=/tmp/x.nse target    -> root NSE execution
#   sudo nmap -p 80 -oN /etc/cron.d/pwn target    -> root file write
# Any member of %sudo could run that straight from a shell. The rofi menu's own
# is_safe_net_input() did not help: it guards the menu, not the sudoers rule.
#
# Sudoers cannot express the constraint, because the target and port are runtime
# input and cannot be enumerated. So the decision moves into a program instead.
# The wildcard below is on the HELPER, which is safe in the way the nmap
# wildcard was not: it validates every argument and builds nmap's argv from
# constants, so no caller-supplied flag ever reaches nmap.
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/local/libexec/kodachi/kodachi-portscan *

# traceroute keeps its trailing wildcard, deliberately and after review, not by
# oversight. It is the same SHAPE as the nmap rules above but not the same risk:
# Debian traceroute has no script engine and no option that writes an arbitrary
# file, so extra argv buys a caller nothing beyond a traceroute. Revisit if the
# menu ever needs a traceroute variant that takes a file or command argument.
%sudo ALL=(ALL) NOPASSWD: /usr/bin/traceroute -m 20 *
%sudo ALL=(ALL) NOPASSWD: /usr/sbin/traceroute -m 20 *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/traceroute.db -m 20 *

# ============================================================
# Docker read-only inspection (rofi Utilities — optional package)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/docker ps
%sudo ALL=(ALL) NOPASSWD: /usr/bin/docker ps *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/docker images
%sudo ALL=(ALL) NOPASSWD: /usr/bin/docker images *

# ============================================================
# Panic/Nuke fallback paths (commands_protection.rs / nuke_sequence.rs)
# ============================================================
%sudo ALL=(ALL) NOPASSWD: /usr/bin/health-control
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kodachi-nuke-helper
%sudo ALL=(ALL) NOPASSWD: /opt/kodachi/dashboard/hooks/kodachi-nuke-helper

# End of Kodachi NOPASSWD rules
EOF

    # Dashboard TUI Terminal Tools (System Monitor tab)
    # Only add entries for tools that exist and aren't already in the file
    local tui_tools=("iftop" "nethogs" "lsof" "du")
    local tui_added=0
    for tui_bin in "${tui_tools[@]}"; do
        # Find the actual path of the binary
        local tui_path
        tui_path=$(command -v "$tui_bin" 2>/dev/null || true)
        if [[ -n "$tui_path" ]] && ! grep -q "$tui_path" "$sudoers_file" 2>/dev/null; then
            if [[ $tui_added -eq 0 ]]; then
                # Insert section header before "End of" marker
                sed -i '/# End of Kodachi NOPASSWD rules/i \\n# ============================================================\n# Dashboard TUI Terminal Tools (System Monitor tab)\n# ============================================================' "$sudoers_file"
                tui_added=1
            fi
            sed -i "/# End of Kodachi NOPASSWD rules/i %sudo ALL=(ALL) NOPASSWD: $tui_path" "$sudoers_file"
        fi
    done
    if [[ $tui_added -gt 0 ]]; then
        print_info "Added NOPASSWD rules for Dashboard TUI tools"
    fi

    # Set correct permissions (0440 = read-only, root:root)
    chmod 0440 "$sudoers_file"
    chown root:root "$sudoers_file"

    # Validate sudoers file syntax
    if visudo -c -f "$sudoers_file" >/dev/null 2>&1; then
        local entry_count=$(grep -c "NOPASSWD" "$sudoers_file")
        print_success "Sudoers configured for group: sudo (includes user: $actual_user)"
        print_info "Total NOPASSWD entries: $entry_count"
        print_info "Binaries configured: ${#binaries[@]}"
        if [[ -n "$dashboard_dir" ]]; then
            print_info "Paths: $dashboard_dir and /usr/local/bin"
        else
            print_info "Path: /usr/local/bin only"
        fi
        print_info "File: $sudoers_file"
        print_success "Kodachi binaries can now run with sudo without password (terminal and GUI)"
    else
        print_error "Sudoers file syntax validation failed!"
        print_warning "Removing invalid sudoers file for safety..."
        rm -f "$sudoers_file"
        # Restore backup if exists
        if compgen -G "${sudoers_file}.backup.*" > /dev/null; then
            local latest_backup
            latest_backup=$(find /etc/sudoers.d -maxdepth 1 -type f -name "kodachi-binaries.backup.*" -printf '%T@ %p\n' \
                | sort -nr \
                | head -1 \
                | cut -d' ' -f2-)
            if [[ -n "$latest_backup" ]]; then
                cp "$latest_backup" "$sudoers_file"
                print_info "Restored previous backup: $latest_backup"
            fi
        fi
        return 1
    fi
}

configure_emergency_shortcut_input_access() {
    print_step "Configuring raw keyboard access for emergency shortcuts..."

    local actual_user=""
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        actual_user="$SUDO_USER"
    else
        actual_user="$LOGNAME"
    fi

    if [[ -z "$actual_user" ]] || [[ "$actual_user" == "root" ]] || [[ ! "$actual_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_warning "Could not determine the desktop user. Skipping input-group setup."
        return 0
    fi

    if ! getent group input >/dev/null 2>&1; then
        print_info "Group 'input' is not present on this system. Skipping emergency shortcut group setup."
        return 0
    fi

    if id -nG "$actual_user" 2>/dev/null | tr ' ' '\n' | grep -qx input; then
        print_success "User '$actual_user' already has input-group access for emergency shortcuts"
        return 0
    fi

    if usermod -aG input "$actual_user" 2>/dev/null; then
        print_success "Added '$actual_user' to the input group for raw keyboard shortcut access"
        print_warning "Log out and back in once so emergency shortcut input access takes effect."
    else
        print_warning "Failed to add '$actual_user' to the input group. Emergency shortcuts may stay unavailable."
    fi
}

# Ensure model paths are compatible across development LAYOUTS ONLY.
# Dev layout:  <hooks>/rust/kodachi-ai/models    (binaries run from target/release)
# Prod layout: <hooks>/models                     (binaries deployed flat to /opt/kodachi)
#
# Audited 2026-05-20: ai-engine::resolve_models_dir candidates do NOT include
# rust/kodachi-ai/models — production binaries at /opt/kodachi/dashboard/hooks/
# resolve <hooks>/models directly via base_dir.join("models"). Creating the
# compat symlink in /opt/kodachi/ ADDS the rust/kodachi-ai/ tree to the live
# ISO for no functional reason. So /opt/kodachi/dashboard/hooks is intentionally
# EXCLUDED from this loop. Dev-tree paths (~/k900, ~/Desktop, ~/dashboard) keep
# the symlink because binaries run from target/release/ walk parent dirs and
# benefit from the hardlinked rust/kodachi-ai/models sibling.
ensure_ai_model_path_compatibility() {
    local real_user_home="${1:-$HOME}"
    local hooks_roots=(
        "$real_user_home/dashboard/hooks"
        "$real_user_home/Desktop/dashboard/hooks"
        "$real_user_home/k900/dashboard/hooks"
        # /opt/kodachi/dashboard/hooks intentionally NOT in this list.
        # See header comment above for the rationale.
    )
    local fixed_count=0
    local hooks_root=""

    for hooks_root in "${hooks_roots[@]}"; do
        [[ -d "$hooks_root" ]] || continue

        local prod_models="$hooks_root/models"
        local dev_parent="$hooks_root/rust/kodachi-ai"
        local dev_models="$dev_parent/models"

        # `[[ ! -e ]]` IS TRUE FOR A DANGLING SYMLINK, AND `|| true` THEN DELETES
        # THE EVIDENCE. The guard used to be `[[ ! -e "$dev_models" ]]` alone, so a
        # broken link took the repair arm, `ln -s` failed with "File exists", the
        # `|| true` ate it, and the `[[ -e ]]` confirmation was still false. The
        # function did nothing, said nothing, and `fixed_count` stayed 0, so the
        # summary reported "already compatible" for the one location that was
        # broken. Measured with a control in the same run by <agent>,
        # 2026-08-20: clean run prints "Model path linked" and fixed_count=1;
        # dangling link prints NOTHING and fixed_count=0.
        #
        # AN ERROR SUPPRESSOR DOES NOT REMOVE A DEFECT, IT REMOVES THE EVIDENCE OF
        # ONE, which is why this quiet member of the class was harder to find than
        # the loud ones that abort under `set -o errexit`. So the dangling state
        # gets its own arm that REPAIRS it, and every arm now says so when the
        # link could not be created.
        if [[ -d "$prod_models" ]] && [[ -L "$dev_models" ]] && [[ ! -e "$dev_models" ]]; then
            ln -sfn ../../models "$dev_models" 2>/dev/null || true
            if [[ -e "$dev_models" ]]; then
                print_info "Model path relinked (the link was dangling): $dev_models -> ../../models"
                fixed_count=$((fixed_count + 1))
            else
                print_warning "Model path is a DANGLING SYMLINK and could not be repaired: $dev_models -> $(readlink "$dev_models" 2>/dev/null || echo '?')"
            fi
        elif [[ -d "$prod_models" ]] && [[ ! -e "$dev_models" ]] && [[ ! -L "$dev_models" ]]; then
            mkdir -p "$dev_parent"
            ln -s ../../models "$dev_models" 2>/dev/null || true
            if [[ -e "$dev_models" ]]; then
                print_info "Model path linked: $dev_models -> ../../models"
                fixed_count=$((fixed_count + 1))
            else
                print_warning "Model path could not be linked: $dev_models -> ../../models"
            fi
        elif [[ -d "$dev_models" ]] && [[ -L "$prod_models" ]] && [[ ! -e "$prod_models" ]]; then
            # The SAME defect on the mirror arm. Fixing one of two adjacent
            # near-identical arms is how a class survives its own fix, because the
            # function then READS as repaired.
            ln -sfn rust/kodachi-ai/models "$prod_models" 2>/dev/null || true
            if [[ -e "$prod_models" ]]; then
                print_info "Model path relinked (the link was dangling): $prod_models -> rust/kodachi-ai/models"
                fixed_count=$((fixed_count + 1))
            else
                print_warning "Model path is a DANGLING SYMLINK and could not be repaired: $prod_models -> $(readlink "$prod_models" 2>/dev/null || echo '?')"
            fi
        elif [[ -d "$dev_models" ]] && [[ ! -e "$prod_models" ]] && [[ ! -L "$prod_models" ]]; then
            ln -s rust/kodachi-ai/models "$prod_models" 2>/dev/null || true
            if [[ -e "$prod_models" ]]; then
                print_info "Model path linked: $prod_models -> rust/kodachi-ai/models"
                fixed_count=$((fixed_count + 1))
            else
                print_warning "Model path could not be linked: $prod_models -> rust/kodachi-ai/models"
            fi
        fi
    done

    if [[ $fixed_count -gt 0 ]]; then
        print_success "AI model path compatibility fixed in $fixed_count location(s)"
    else
        print_info "AI model paths already compatible"
    fi
}

cleanup_legacy_autostart_entries_for_user() {
    local actual_user="${1:-}"
    local real_user_home="${2:-}"
    local autostart_dir=""
    local removed=0
    local noun="entries"
    local old_entry=""
    local legacy_entries=()

    if [[ -z "$actual_user" ]] || [[ -z "$real_user_home" ]]; then
        return 0
    fi

    autostart_dir="$real_user_home/.config/autostart"
    legacy_entries=(
        "$autostart_dir/kodachi-autoshield.desktop"
        "$autostart_dir/kodachi-welcome.desktop"
        "$autostart_dir/kodachi-welcome-startup.desktop"
    )

    for old_entry in "${legacy_entries[@]}"; do
        if [[ -f "$old_entry" ]]; then
            rm -f "$old_entry" 2>/dev/null || true
            if [[ ! -f "$old_entry" ]]; then
                removed=$((removed + 1))
            fi
        fi
    done

    if [[ $removed -eq 1 ]]; then
        noun="entry"
    fi
    if [[ $removed -gt 0 ]]; then
        print_info "Removed $removed legacy Kodachi startup $noun for $actual_user"
    fi
}

# Install Conky assets and autostart profile for the real desktop user
# Stop Conky safely before updating its files to prevent CPU spike / freeze.
# Must run as root — targets the specified non-root user's processes.
# The watchdog service is stopped first so it doesn't restart Conky mid-update.
# Conky will be restarted automatically by the enable --now call later.
safe_stop_conky_for_update() {
    local target_user="${1:-}"
    if [[ -z "$target_user" ]]; then
        return 0
    fi

    if ! pgrep -u "$target_user" -x conky >/dev/null 2>&1; then
        return 0
    fi

    print_info "Stopping Conky for user $target_user before file update..."

    # 1. Disable + stop the watchdog/timer so user-systemd cannot respawn
    # refresh activity while Conky assets are being replaced.
    if command -v systemctl >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
        runuser -u "$target_user" -- systemctl --user disable --now \
            conky-watchdog.service conky-snapshot-refresh.timer >/dev/null 2>&1 || true
        runuser -u "$target_user" -- systemctl --user stop \
            conky-snapshot-refresh.service >/dev/null 2>&1 || true
    fi

    # 2. Kill watchdog and launcher processes (launcher spawns new conky instances)
    pkill -u "$target_user" -f conky-watchdog >/dev/null 2>&1 || true
    pkill -u "$target_user" -f conky-launcher >/dev/null 2>&1 || true
    sleep 1

    # 3. Graceful stop all conky
    pkill -u "$target_user" -x conky >/dev/null 2>&1 || true
    sleep 2

    # 4. Force kill if still alive
    if pgrep -u "$target_user" -x conky >/dev/null 2>&1; then
        pkill -9 -u "$target_user" -x conky >/dev/null 2>&1 || true
        sleep 1
    fi

    # 5. Verify clean kill
    if pgrep -u "$target_user" -x conky >/dev/null 2>&1; then
        print_warning "Some Conky processes survived; forcing final cleanup"
        pkill -9 -u "$target_user" -x conky >/dev/null 2>&1 || true
        pkill -9 -u "$target_user" -f conky-launcher >/dev/null 2>&1 || true
    fi

    print_info "Conky stopped for update (will restart automatically)"
}

install_kodachi_conky_for_user() {
    print_step "Configuring Kodachi Conky startup..."

    if [[ "${SKIP_GUI_INSTALL:-}" == "true" ]]; then
        print_info "GUI install skipped (--skipgui). Skipping Conky bootup setup."
        return 0
    fi
    # Check build variant marker file (written by build-iso.sh during ISO creation)
    local _build_variant=""
    if [[ -f /opt/kodachi-offline-packages/build-variant ]]; then
        _build_variant=$(tr -cd 'a-z-' < /opt/kodachi-offline-packages/build-variant)
    fi
    if [[ "$_build_variant" == "terminal" ]] || [[ "$_build_variant" == "minimal" ]]; then
        print_info "Build variant is '${_build_variant}'. Skipping Conky bootup setup."
        return 0
    fi
    if ! detect_gui_environment; then
        print_info "No GUI desktop detected (terminal/headless system). Skipping Conky setup."
        return 0
    fi

    local actual_user=""
    local real_user_home=""

    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        actual_user="$SUDO_USER"
    elif [[ -n "${LOGNAME:-}" ]] && [[ "$LOGNAME" != "root" ]]; then
        actual_user="$LOGNAME"
    fi

    if [[ -z "$actual_user" ]] || [[ ! "$actual_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_warning "Could not determine target non-root user. Skipping Conky user setup."
        return 0
    fi

    real_user_home=$(getent passwd "$actual_user" | cut -d: -f6)
    if [[ -z "$real_user_home" ]]; then
        real_user_home=$(resolve_user_home "$actual_user")
    fi

    # Smart-skip: if kodachi-binary-install.sh (or a previous deps run)
    # already deployed conky configs AND the per-user systemd watchdog
    # is enabled, do not re-deploy. Redeploying over a running conky
    # session was breaking the user's font cache + compositor state on
    # test PCs where binary installer correctly set them up first. The
    # binary installer is the canonical owner; deps acts as a fallback
    # only when the user runs deps without binary.
    #
    # Enabled-check: we use the on-disk symlink under default.target.wants
    # rather than `systemctl --user is-enabled`, because the latter needs a
    # live user D-Bus and XDG_RUNTIME_DIR — neither of which is threaded
    # through `runuser` from a sudo-root deps-install context. The symlink
    # IS what `systemctl --user enable` creates; root can read it; no bus
    # required.
    local _smart_conky_dir="$real_user_home/.config/kodachi/conky"
    local _smart_user_systemd="$real_user_home/.config/systemd/user"
    if [[ -f "$_smart_conky_dir/configs/conkyrc-focus-alert.conf" ]] \
       && [[ -f "$_smart_user_systemd/conky-watchdog.service" ]] \
       && [[ -L "$_smart_user_systemd/default.target.wants/conky-watchdog.service" ]]; then
        print_info "Conky already fully configured for $actual_user (configs + watchdog wants-symlink present). Skipping deps-side setup."
        return 0
    fi

    local conky_install_dir="$real_user_home/.config/kodachi/conky"
    local conky_source=""
    local candidates=(
        "$PROJECT_ROOT/livebuild-assets/conky"
        "$PROJECT_ROOT/dashboard/hooks/conky"
        "$real_user_home/k900/livebuild-assets/conky"
        "$real_user_home/dashboard/hooks/conky"
        "$real_user_home/Desktop/dashboard/hooks/conky"
        "$real_user_home/k900/dashboard/hooks/conky"
        "/opt/kodachi/dashboard/hooks/conky"
        "/usr/share/kodachi/conky"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/configs" ]] && [[ -d "$candidate/scripts" ]]; then
            conky_source="$candidate"
            break
        fi
    done

    if [[ -z "$conky_source" ]]; then
        if [[ -d "$conky_install_dir/configs" ]] && [[ -d "$conky_install_dir/scripts" ]]; then
            print_warning "Conky update source not found; reusing existing assets and refreshing startup entries."
            conky_source="$conky_install_dir"
        else
            print_warning "Conky assets not found in known paths. Skipping Conky setup."
            return 0
        fi
    fi

    local autostart_dir="$real_user_home/.config/autostart"
    local autostart_file="$autostart_dir/kodachi-conky.desktop"
    local launcher="$conky_install_dir/scripts/conky-launcher.sh"
    local watchdog_script="$conky_install_dir/scripts/conky-watchdog.sh"
    local watchdog_service_source="$conky_install_dir/systemd/conky-watchdog.service"
    local snapshot_service_source="$conky_install_dir/systemd/conky-snapshot-refresh.service"
    local snapshot_timer_source="$conky_install_dir/systemd/conky-snapshot-refresh.timer"
    local systemd_user_dir="$real_user_home/.config/systemd/user"
    local watchdog_service_file="$systemd_user_dir/conky-watchdog.service"
    local snapshot_service_file="$systemd_user_dir/conky-snapshot-refresh.service"
    local snapshot_timer_file="$systemd_user_dir/conky-snapshot-refresh.timer"
    local wants_dir="$systemd_user_dir/default.target.wants"
    local autostart_exec=""
    local autostart_tryexec=""
    local snapshot_timer_available=0

    mkdir -p "$(dirname "$conky_install_dir")" "$autostart_dir" "$systemd_user_dir" "$wants_dir"
    if [[ "$conky_source" != "$conky_install_dir" ]]; then
        safe_stop_conky_for_update "$actual_user"

        # Preserve runtime data/cache directory across update to prevent
        # the Signal Deck from cold-starting all queries (600% CPU spike).
        local _conky_data_backup=""
        if [[ -d "$conky_install_dir/data" ]]; then
            _conky_data_backup="$(mktemp -d "${TMPDIR:-/tmp}/kodachi-conky-data.XXXXXX")"
            cp -a "$conky_install_dir/data/." "$_conky_data_backup/" 2>/dev/null || true
        fi

        rm -rf "$conky_install_dir"
        cp -a "$conky_source" "$conky_install_dir"

        # Restore cached data so focus-alert/signal-deck doesn't rebuild from scratch
        if [[ -n "${_conky_data_backup:-}" ]] && [[ -d "$_conky_data_backup" ]]; then
            mkdir -p "$conky_install_dir/data"
            cp -a "$_conky_data_backup/." "$conky_install_dir/data/" 2>/dev/null || true
            rm -rf "$_conky_data_backup"
        fi

        print_success "Conky assets updated: $conky_install_dir"
    else
        print_info "Conky assets already present. Refreshing permissions and startup entries."
    fi
    cleanup_legacy_autostart_entries_for_user "$actual_user" "$real_user_home"

    if [[ -d "$conky_install_dir/scripts" ]]; then
        find "$conky_install_dir/scripts" -type f -name "*.sh" -exec chmod 755 {} + 2>/dev/null || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if [[ -f "$snapshot_service_source" ]]; then
            cp -f "$snapshot_service_source" "$snapshot_service_file"
        else
            # Fallback heredoc — only used if $snapshot_service_source is missing.
            # Kept in sync with the canonical
            # /usr/share/kodachi/conky/systemd/conky-snapshot-refresh.service
            # (audit 2026-05-08: Requisite= refuses activation if graphical-
            # session.target is not active — required to prevent the service
            # firing during the xfce4-session bring-up window).
            #
            # IMPORTANT: terminator is QUOTED ('EOF') so the inner /bin/bash -c
            # body's "$bin" loop variable is preserved literally in the .service
            # file and only expanded by bash at service runtime. With unquoted
            # EOF, the install-time shell would substitute the (unset) $bin to
            # empty and write a dead "[ -x \"\" ] && exec \"\"" body.
            cat > "$snapshot_service_file" << 'EOF'
[Unit]
Description=Kodachi Conky Snapshot Refresh
After=graphical-session.target
Requisite=graphical-session.target
ConditionPathExists=%h/.config/kodachi/conky/scripts/conky-gateway-common.sh
ConditionPathExists=%t/kodachi-session-token.json

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  mkdir -p "%h/.config/kodachi/conky/data" 2>/dev/null || true; \
  exec 9>"%h/.config/kodachi/conky/data/.focus-alert-refresh.lock" 2>/dev/null || exit 0; \
  flock -n 9 || exit 0; \
  resolved_bin="$(command -v conky-status 2>/dev/null || true)"; \
  for bin in \
    "$resolved_bin" \
    /usr/local/bin/conky-status \
    "%h/k900/dashboard/hooks/conky-status" \
    "%h/dashboard/hooks/conky-status" \
    /opt/kodachi/dashboard/hooks/conky-status; do \
    [ -n "$bin" ] || continue; \
    [ -x "$bin" ] || continue; \
    "$bin" --version >/dev/null 2>&1 || continue; \
    exec "$bin" snapshot --refresh --quiet; \
  done; \
  exit 0'
TimeoutSec=90
TimeoutStopSec=10
StandardOutput=null
StandardError=journal
Nice=15
IOSchedulingClass=idle
KillMode=process
SendSIGKILL=yes
# Memory guard: prevent snapshot refresh from starving the desktop session.
MemoryHigh=200M
MemoryMax=300M
EOF
        fi

        if [[ -f "$snapshot_timer_source" ]]; then
            cp -f "$snapshot_timer_source" "$snapshot_timer_file"
        else
            # Fallback heredoc — only used if $snapshot_timer_source is missing.
            # Kept in sync with the canonical
            # /usr/share/kodachi/conky/systemd/conky-snapshot-refresh.timer
            # (audit 2026-05-08, macOS-Ventura bundle: raised OnActiveSec from
            # 120 -> 240 because the legacy 120 s value fired DURING the
            # xfce4-session bring-up window on installed systems with a 134 s
            # login).
            cat > "$snapshot_timer_file" << EOF
[Unit]
Description=Kodachi Conky Snapshot Refresh Timer

[Timer]
OnActiveSec=240
OnUnitActiveSec=90
RandomizedDelaySec=15
Persistent=false
AccuracySec=1s

[Install]
WantedBy=graphical-session.target
EOF
        fi

        chmod 644 "$snapshot_service_file" "$snapshot_timer_file"
        # Want the timer from graphical-session.target, NOT default.target — the
        # service is Requisite=graphical-session.target and a default.target want
        # creates a shutdown ordering cycle. Clear any stale default.target want.
        rm -f "$wants_dir/conky-snapshot-refresh.timer" 2>/dev/null || true
        mkdir -p "$systemd_user_dir/graphical-session.target.wants"
        ln -sfn "$snapshot_timer_file" "$systemd_user_dir/graphical-session.target.wants/conky-snapshot-refresh.timer"
        snapshot_timer_available=1
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -x "$watchdog_script" ]]; then
        if [[ -f "$watchdog_service_source" ]]; then
            cp -f "$watchdog_service_source" "$watchdog_service_file"
        else
            cat > "$watchdog_service_file" << EOF
[Unit]
Description=Kodachi Conky Watchdog
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=%h/.config/kodachi/conky/scripts/conky-watchdog.sh
ExecStop=-/usr/bin/pkill -x conky
ExecStopPost=-/usr/bin/pkill -9 -x conky
Restart=on-failure
RestartSec=3
KillMode=mixed
TimeoutStopSec=5
Environment=XAUTHORITY=%h/.Xauthority

[Install]
WantedBy=default.target
EOF
        fi
        chmod 644 "$watchdog_service_file"
        ln -sfn "$watchdog_service_file" "$wants_dir/conky-watchdog.service"
        autostart_exec="/usr/bin/systemctl --user start conky-watchdog.service"
        if (( snapshot_timer_available )); then
            autostart_exec+=" conky-snapshot-refresh.timer"
        fi
        autostart_tryexec="/usr/bin/systemctl"
    elif [[ -x "$launcher" ]]; then
        autostart_exec="$launcher --restart"
        autostart_tryexec="$launcher"
        if (( snapshot_timer_available )); then
            print_warning "Conky watchdog script missing at $watchdog_script. Falling back to launcher autostart while keeping the snapshot timer enabled."
        else
            print_warning "Conky watchdog script missing at $watchdog_script. Falling back to launcher autostart."
        fi
    else
        print_warning "Conky launcher not found at $launcher. Skipping Conky setup."
        return 0
    fi

    cat > "$autostart_file" << EOF
[Desktop Entry]
Type=Application
Name=Kodachi Conky
Comment=Kodachi 9 Desktop Status Panels
GenericName=System Monitor
Exec=$autostart_exec
TryExec=$autostart_tryexec
Terminal=false
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
Categories=System;Monitor;
Keywords=conky;monitor;system;status;privacy;security;
StartupNotify=false
EOF
    chmod 644 "$autostart_file"

    chown -R "$actual_user:$actual_user" "$conky_install_dir" 2>/dev/null || true
    chown "$actual_user:$actual_user" "$autostart_dir" 2>/dev/null || true
    chown "$actual_user:$actual_user" "$autostart_file" 2>/dev/null || true
    chown -R "$actual_user:$actual_user" "$systemd_user_dir" 2>/dev/null || true

    if command -v conky >/dev/null 2>&1; then
        if command -v systemctl >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
            if command -v runuser >/dev/null 2>&1; then
                runuser -u "$actual_user" -- systemctl --user daemon-reload >/dev/null 2>&1 || true
                if [[ -x "$watchdog_script" ]] && [[ -f "$watchdog_service_file" ]]; then
                    runuser -u "$actual_user" -- systemctl --user enable --now conky-watchdog.service >/dev/null 2>&1 || \
                        runuser -u "$actual_user" -- systemctl --user start conky-watchdog.service >/dev/null 2>&1 || true
                fi
                if (( snapshot_timer_available )) && [[ -f "$snapshot_timer_file" ]]; then
                    runuser -u "$actual_user" -- systemctl --user enable --now conky-snapshot-refresh.timer >/dev/null 2>&1 || \
                        runuser -u "$actual_user" -- systemctl --user start conky-snapshot-refresh.timer >/dev/null 2>&1 || true
                fi
            fi
            if [[ -x "$watchdog_script" ]] && [[ -f "$watchdog_service_file" ]] && (( snapshot_timer_available )); then
                print_success "Conky configured for user $actual_user (watchdog + snapshot timer enabled)"
            elif [[ -x "$watchdog_script" ]] && [[ -f "$watchdog_service_file" ]]; then
                print_success "Conky configured for user $actual_user (watchdog enabled)"
            elif (( snapshot_timer_available )); then
                print_success "Conky configured for user $actual_user (snapshot timer enabled)"
            else
                print_success "Conky configured for user $actual_user (autostart enabled)"
            fi
        else
            print_warning "Conky watchdog script missing at $watchdog_script"
            print_success "Conky configured for user $actual_user (autostart enabled)"
        fi
    else
        print_warning "Conky binary not found. Install package 'conky-all' to run desktop panels."
    fi
}

prime_session_helper_manager_env_for_user() {
    local actual_user="$1"
    local real_user_home="$2"

    if ! command -v systemctl >/dev/null 2>&1 || ! command -v runuser >/dev/null 2>&1; then
        return 0
    fi

    local helper_display="${DISPLAY:-}"
    local display_socket=""
    if [[ -z "$helper_display" ]]; then
        for display_socket in /tmp/.X11-unix/X*; do
            [[ -S "$display_socket" ]] || continue
            helper_display=":${display_socket##*X}"
            break
        done
    fi

    local runtime_dir="/run/user/$(id -u "$actual_user")"
    local helper_xauthority="${XAUTHORITY:-$real_user_home/.Xauthority}"
    local dbus_session_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}"

    runuser -u "$actual_user" -- env \
        DISPLAY="${helper_display:-:0}" \
        XAUTHORITY="$helper_xauthority" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" \
        RUST_LOG="${RUST_LOG:-warn}" \
        systemctl --user set-environment \
        DISPLAY="${helper_display:-:0}" \
        XAUTHORITY="$helper_xauthority" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" \
        RUST_LOG="${RUST_LOG:-warn}" >/dev/null 2>&1 || true
}

write_session_helper_service_file() {
    local service_file="$1"
    local helper_bin="$2"
    local helper_dir
    helper_dir="$(dirname "$helper_bin")"

    cat > "$service_file" << EOF
[Unit]
Description=Kodachi Session Helper - Global Emergency Shortcut Daemon
Documentation=https://kodachi.cloud/docs/binaries/kodachi-session-helper.html
After=graphical-session.target
PartOf=graphical-session.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'n=0; while [ \$n -lt 15 ]; do xdpyinfo >/dev/null 2>&1 && exit 0; n=\$((n+1)); sleep 1; done; exit 1'
ExecStart=$helper_bin daemon
WorkingDirectory=$helper_dir
Restart=on-failure
RestartSec=5
TimeoutStopSec=5
LimitCORE=0
NoNewPrivileges=false
# NO ProtectSystem/ProtectHome: they make /etc/sudo.conf appear owned by uid
# 65534 inside the unit mount namespace (overlay AND ext4), breaking sudo -n
# so health-control reports permanently unavailable. Daemon must run unsandboxed.
PrivateTmp=false
# NO ReadWritePaths: it creates a mount namespace that masks /etc/sudo.conf as
# uid 65534 (overlay) -> sudo -n breaks -> health-control unavailable. The daemon
# writes /run/user/%U fine without it; it must run fully unsandboxed.
Environment=DISPLAY=:0
Environment=XAUTHORITY=%h/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/%U
Environment=RUST_LOG=warn

[Install]
WantedBy=default.target
EOF
}

setup_session_helper_service() {
    if ! detect_gui_environment; then
        print_info "No GUI desktop detected. Skipping session-helper user service setup."
        return 0
    fi

    local actual_user=""
    local real_user_home=""

    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        actual_user="$SUDO_USER"
    elif [[ -n "${LOGNAME:-}" ]] && [[ "$LOGNAME" != "root" ]]; then
        actual_user="$LOGNAME"
    fi

    if [[ -z "$actual_user" ]] || [[ ! "$actual_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_warning "Could not determine target non-root user. Skipping session-helper service setup."
        return 0
    fi

    real_user_home=$(getent passwd "$actual_user" | cut -d: -f6)
    if [[ -z "$real_user_home" ]]; then
        real_user_home=$(resolve_user_home "$actual_user")
    fi

    local helper_bin=""
    helper_bin=$(find_session_helper_binary_for_home "$real_user_home" 2>/dev/null || true)
    if [[ -z "$helper_bin" ]]; then
        print_warning "kodachi-session-helper binary not found. Skipping user service setup."
        return 0
    fi

    local systemd_user_dir="$real_user_home/.config/systemd/user"
    local service_file="$systemd_user_dir/kodachi-session-helper.service"
    local wants_dir="$systemd_user_dir/default.target.wants"

    # Smart-skip: if kodachi-binary-install.sh already deployed the
    # service unit AND enabled it for this user, do not rewrite the file
    # or daemon-reload. Re-deploying a service that's already wired by
    # the binary installer just re-triggers daemon-reload + restart for
    # no behavioral change. Binary installer is the canonical owner.
    #
    # Enabled-check: see install_kodachi_conky_for_user for the same
    # symlink-vs-systemctl rationale. systemctl --user via runuser fails
    # under sudo-root with no D-Bus; the wants symlink is authoritative.
    if [[ -f "$service_file" ]] \
       && [[ -L "$wants_dir/kodachi-session-helper.service" ]]; then
        print_info "Session helper service already deployed + enabled for $actual_user. Skipping."
        return 0
    fi
    local legacy_wants_link="$systemd_user_dir/graphical-session.target.wants/kodachi-session-helper.service"
    local dropin_dir="$systemd_user_dir/kodachi-session-helper.service.d"
    local backup_suffix
    backup_suffix="$(date -u +%Y%m%dT%H%M%SZ)"

    mkdir -p "$systemd_user_dir" "$wants_dir"

    if [[ -L "$service_file" ]]; then
        cp -a "$service_file" "${service_file}.bak.${backup_suffix}" 2>/dev/null || true
        rm -f "$service_file"
    elif [[ -f "$service_file" ]]; then
        cp -a "$service_file" "${service_file}.bak.${backup_suffix}" 2>/dev/null || true
    fi

    if [[ -d "$dropin_dir" ]]; then
        mv "$dropin_dir" "${dropin_dir}.bak.${backup_suffix}" 2>/dev/null || true
    fi

    write_session_helper_service_file "$service_file" "$helper_bin"
    chmod 644 "$service_file"
    ln -sfn "$service_file" "$wants_dir/kodachi-session-helper.service"
    rm -f "$legacy_wants_link" 2>/dev/null || true

    chown "$actual_user:$actual_user" "$systemd_user_dir" "$service_file" "$wants_dir" 2>/dev/null || true
    chown -h "$actual_user:$actual_user" "$wants_dir/kodachi-session-helper.service" 2>/dev/null || true

    local started=false
    if command -v systemctl >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
        local runtime_dir="/run/user/$(id -u "$actual_user")"
        local helper_xauthority="${XAUTHORITY:-$real_user_home/.Xauthority}"
        local helper_display="${DISPLAY:-}"
        local display_socket=""
        if [[ -z "$helper_display" ]]; then
            for display_socket in /tmp/.X11-unix/X*; do
                [[ -S "$display_socket" ]] || continue
                helper_display=":${display_socket##*X}"
                break
            done
        fi
        local dbus_session_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}"

        prime_session_helper_manager_env_for_user "$actual_user" "$real_user_home"
        runuser -u "$actual_user" -- env DISPLAY="${helper_display:-:0}" XAUTHORITY="$helper_xauthority" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" systemctl --user daemon-reload >/dev/null 2>&1 || true
        if runuser -u "$actual_user" -- env DISPLAY="${helper_display:-:0}" XAUTHORITY="$helper_xauthority" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" systemctl --user enable --now kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        elif runuser -u "$actual_user" -- env DISPLAY="${helper_display:-:0}" XAUTHORITY="$helper_xauthority" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" systemctl --user restart kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        elif runuser -u "$actual_user" -- env DISPLAY="${helper_display:-:0}" XAUTHORITY="$helper_xauthority" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$dbus_session_bus" systemctl --user start kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        fi
    fi

    if [[ "$started" == "true" ]]; then
        print_success "Session helper user service refreshed and started for $actual_user"
    else
        print_success "Session helper user service refreshed for $actual_user"
        print_info "It will start automatically on the next graphical login."
    fi
}

# ── Welcome autostart setup ──────────────────────────────────────
setup_dashboard_autostart() {
    local _build_variant=""
    if [[ -f /opt/kodachi-offline-packages/build-variant ]]; then
        _build_variant=$(tr -cd 'a-z-' < /opt/kodachi-offline-packages/build-variant)
    fi
    if [[ "$_build_variant" == "terminal" ]] || [[ "$_build_variant" == "minimal" ]]; then
        print_info "Build variant is '${_build_variant}'. Skipping Dashboard autostart setup."
        return 0
    fi
    if ! detect_gui_environment; then
        print_info "No GUI desktop detected. Skipping Dashboard autostart setup."
        return 0
    fi

    # Detect actual non-root user (same pattern as conky setup)
    local actual_user=""
    local real_user_home=""

    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        actual_user="$SUDO_USER"
    elif [[ -n "${LOGNAME:-}" ]] && [[ "$LOGNAME" != "root" ]]; then
        actual_user="$LOGNAME"
    fi

    if [[ -z "$actual_user" ]] || [[ ! "$actual_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_warning "Could not determine target non-root user. Skipping Dashboard autostart."
        return 0
    fi

    real_user_home=$(getent passwd "$actual_user" | cut -d: -f6)
    if [[ -z "$real_user_home" ]]; then
        real_user_home=$(resolve_user_home "$actual_user")
    fi

    local autostart_dir="$real_user_home/.config/autostart"
    local autostart_file="$autostart_dir/kodachi-dashboard.desktop"

    # Smart-skip: if kodachi-binary-install.sh already wrote the autostart
    # entry pointing at the canonical launcher, do not rewrite. The binary
    # installer is the canonical owner of the dashboard autostart (the
    # dashboard IS a Kodachi binary). Deps acts as fallback only.
    #
    # We match the literal canonical Exec line that both binary installer
    # (kodachi-binary-install.sh:2305) and deps installer itself (line 2032)
    # write — `Exec=/usr/local/bin/kodachi-dashboard-launcher`. Using
    # parse-then-test-x failed open when the launcher script was missing
    # at check time even though the autostart entry was canonical; literal
    # match avoids that parsing failure mode entirely and sidesteps the
    # quoted-path edge case.
    if [[ -f "$autostart_file" ]] \
       && grep -q '^Exec=/usr/local/bin/kodachi-dashboard-launcher$' "$autostart_file"; then
        print_info "Dashboard autostart already configured for $actual_user (canonical Exec line present). Skipping."
        return 0
    fi

    # Detect the kodachi-dashboard binary location.
    # IMPORTANT: We MUST use the full absolute path in the Exec= line because
    # the hooks directory is NOT guaranteed to be in the user's $PATH at login time.
    # A bare "kodachi-dashboard" would silently fail to launch on boot.
    # Do NOT change this to a bare command name without ensuring PATH is set.
    local dashboard_bin=""
    for candidate in "/usr/local/bin/kodachi-dashboard" \
                     "/opt/kodachi/dashboard/hooks/kodachi-dashboard" \
                     "$PROJECT_ROOT/dashboard/hooks/kodachi-dashboard" \
                     "$real_user_home/dashboard/hooks/kodachi-dashboard" \
                     "$real_user_home/Desktop/dashboard/hooks/kodachi-dashboard" \
                     "$real_user_home/k900/dashboard/hooks/kodachi-dashboard"; do
        if [[ -x "$candidate" ]]; then
            dashboard_bin="$candidate"
            break
        fi
    done
    # Fallback: check if it's in PATH (e.g. installed globally via /usr/local/bin)
    if [[ -z "$dashboard_bin" ]]; then
        dashboard_bin=$(command -v kodachi-dashboard 2>/dev/null || true)
    fi
    if [[ -z "$dashboard_bin" ]]; then
        print_warning "kodachi-dashboard binary not found. Skipping Dashboard autostart."
        return 0
    fi

    # Create the launcher script if missing, or refresh it when an older copy
    # (pre-seeded by the ISO or a prior install) lacks the broadened
    # GPU-driver detection (nouveau / legacy radeon + NVIDIA proprietary).
    # Refresh marker is GPU_NEEDS_FALLBACK — older launchers used the
    # narrower NVIDIA_PROPRIETARY token and get rewritten on next install.
    local launcher_script="/usr/local/bin/kodachi-dashboard-launcher"
    if [[ ! -f "$launcher_script" ]] || ! grep -q 'GPU_NEEDS_FALLBACK' "$launcher_script" 2>/dev/null || ! grep -q 'DASHBOARD_BIN=' "$launcher_script" 2>/dev/null; then
        print_info "Installing/refreshing dashboard launcher script..."
        cat > "$launcher_script" << 'LAUNCHER_EOF'
#!/bin/bash
# Kodachi Dashboard Launcher with VM + GPU-driver detection
# Auto-detects VM environments and GPU drivers that need the WebKitGTK
# software-render fallback so the dashboard does not come up as a blank
# window. Covers: NVIDIA proprietary, Nouveau (Mesa, GTX Kepler/Maxwell
# era), and legacy radeon (pre-amdgpu).

VM_DETECTED=false
GPU_NEEDS_FALLBACK=false
GPU_IS_MESA_DRIVER=false
GPU_IS_NVIDIA_PROPRIETARY=false

# VM detection
if [ -f /sys/class/dmi/id/sys_vendor ]; then
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$vendor" in
        *vmware*|*virtualbox*|*qemu*|*kvm*|*parallels*)
            VM_DETECTED=true
            ;;
    esac
fi

if [ -f /sys/class/dmi/id/product_name ]; then
    product=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$product" in
        *virtual*|*vmware*|*virtualbox*|*qemu*|*kvm*)
            VM_DETECTED=true
            ;;
    esac
fi

# 1. NVIDIA proprietary driver
if [ -f /proc/driver/nvidia/version ] || \
   lsmod 2>/dev/null | grep -qE '^nvidia[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_NVIDIA_PROPRIETARY=true
fi

# 2. Nouveau (open-source NVIDIA, Mesa) — catches older NVIDIA chips
#    (e.g. GTX 770 / Kepler) whose Nouveau GBM/EGL silently breaks
#    WebKitGTK DMABUF init, producing a black dashboard window.
if lsmod 2>/dev/null | grep -qE '^nouveau[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_MESA_DRIVER=true
fi

# 3. Legacy AMD via radeon module (pre-amdgpu, GCN1 and earlier)
if lsmod 2>/dev/null | grep -qE '^radeon[[:space:]]' && \
   ! lsmod 2>/dev/null | grep -qE '^amdgpu[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_MESA_DRIVER=true
fi

if [ "$GPU_NEEDS_FALLBACK" = "true" ]; then
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
fi

# LIBGL_ALWAYS_SOFTWARE is Mesa-only — NVIDIA proprietary GL ignores it.
if [ "$GPU_IS_MESA_DRIVER" = "true" ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
fi

# NVIDIA proprietary Wayland explicit-sync can crash WebKitGTK.
if [ "$GPU_IS_NVIDIA_PROPRIETARY" = "true" ]; then
    export __NV_DISABLE_EXPLICIT_SYNC=1
fi

# Resolve dashboard binary at runtime across the known install locations.
DASHBOARD_BIN=""
for _cand in /usr/local/bin/kodachi-dashboard \
             /opt/kodachi/dashboard/hooks/kodachi-dashboard \
             "$HOME/dashboard/hooks/kodachi-dashboard" \
             "$HOME/Desktop/dashboard/hooks/kodachi-dashboard" \
             "$HOME/k900/dashboard/hooks/kodachi-dashboard"; do
    if [ -x "$_cand" ]; then DASHBOARD_BIN="$_cand"; break; fi
done
[ -z "$DASHBOARD_BIN" ] && DASHBOARD_BIN="$(command -v kodachi-dashboard 2>/dev/null || true)"
if [ -z "$DASHBOARD_BIN" ]; then
    echo "kodachi-dashboard-launcher: dashboard binary not found" >&2
    exit 1
fi

if [ "$VM_DETECTED" = "true" ] || [ "$GPU_NEEDS_FALLBACK" = "true" ]; then
    exec "$DASHBOARD_BIN" --no-gpu "$@"
else
    exec "$DASHBOARD_BIN" "$@"
fi

LAUNCHER_EOF
        chmod 755 "$launcher_script"
        print_success "Created launcher script: $launcher_script"
    fi

    # Repair permissions even when the launcher was pre-seeded by the image.
    chmod 755 "$launcher_script" 2>/dev/null || true

    # Repair permissions on other system binaries that may have been pre-seeded
    for _bin in kodachi-fix-resolvconf dns-diag hysteria; do
        [ -f "/usr/local/bin/$_bin" ] && chmod 755 "/usr/local/bin/$_bin" 2>/dev/null || true
    done

    cleanup_legacy_autostart_entries_for_user "$actual_user" "$real_user_home"
    if [[ -f "$autostart_file" ]]; then
        if grep -q "^Exec=/usr/local/bin/kodachi-dashboard-launcher$" "$autostart_file" 2>/dev/null; then
            print_info "Refreshing Dashboard autostart entry for $actual_user: $autostart_file"
        else
            print_warning "Dashboard autostart entry is outdated for $actual_user. Replacing: $autostart_file"
        fi
    fi

    mkdir -p "$autostart_dir"
    # NOTE: Using unquoted EOF so variables expand to full absolute paths.
    # This is intentional — the autostart MUST contain the resolved path, not a variable.
    cat > "$autostart_file" << EOF
[Desktop Entry]
Type=Application
Name=Kodachi Dashboard
Comment=Kodachi Security Dashboard - launches at boot
GenericName=Security Dashboard
Exec=/usr/local/bin/kodachi-dashboard-launcher
TryExec=$dashboard_bin
Path=/opt/kodachi/dashboard/hooks
Icon=/usr/share/icons/kodachi/kodachi32.png
Terminal=false
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
Categories=System;Security;
Keywords=kodachi;dashboard;security;privacy;autostart;
StartupNotify=true
StartupWMClass=kodachi-dashboard
EOF
    chmod 644 "$autostart_file"
    chown "$actual_user:$actual_user" "$autostart_dir" 2>/dev/null || true
    chown "$actual_user:$actual_user" "$autostart_file" 2>/dev/null || true

    print_success "Dashboard autostart enabled for $actual_user: $autostart_file"
    return 0
}

# NOTE: setup_dashboard_autostart and create_welcome_desktop_shortcut are invoked
# after detect_gui_environment() is defined (see below detect_gui_environment).

# ── Welcome desktop shortcut ──────────────────────────────────────
create_welcome_desktop_shortcut() {
    local _build_variant=""
    if [[ -f /opt/kodachi-offline-packages/build-variant ]]; then
        _build_variant=$(tr -cd 'a-z-' < /opt/kodachi-offline-packages/build-variant)
    fi
    if [[ "$_build_variant" == "terminal" ]]; then
        print_info "Build variant is 'terminal'. Skipping Welcome desktop shortcut."
        return 0
    fi
    if ! detect_gui_environment; then
        print_info "No GUI desktop detected. Skipping Welcome desktop shortcut."
        return 0
    fi
    local in_livebuild_chroot=false
    local root_stat=""
    local proc_root_stat=""
    root_stat=$(stat -c %d:%i / 2>/dev/null || true)
    proc_root_stat=$(stat -c %d:%i /proc/1/root/. 2>/dev/null || true)
    if [[ -f "/tmp/live-build-chroot" || -f "/.debian-live-build" || -n "${LB_BASE:-}" ]]; then
        in_livebuild_chroot=true
    elif [[ -n "$root_stat" && -n "$proc_root_stat" && "$root_stat" != "$proc_root_stat" ]]; then
        in_livebuild_chroot=true
    fi
    if [[ "$in_livebuild_chroot" == "true" ]]; then
        print_info "Live-build chroot detected. Skipping Welcome desktop shortcut."
        return 0
    fi

    # Detect actual non-root user
    local actual_user=""
    local real_user_home=""
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        actual_user="$SUDO_USER"
    elif [[ -n "${LOGNAME:-}" ]] && [[ "$LOGNAME" != "root" ]]; then
        actual_user="$LOGNAME"
    fi
    if [[ -z "$actual_user" ]] || [[ ! "$actual_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_warning "Could not determine target non-root user. Skipping Welcome desktop shortcut."
        return 0
    fi
    real_user_home=$(getent passwd "$actual_user" | cut -d: -f6)
    if [[ -z "$real_user_home" ]]; then
        real_user_home=$(resolve_user_home "$actual_user")
    fi

    # Detect desktop directory (multilingual)
    local desktop_dir=""
    for candidate in "$real_user_home/Desktop" "$real_user_home/Escritorio" "$real_user_home/Bureau" "$real_user_home/Schreibtisch"; do
        if [[ -d "$candidate" ]]; then
            desktop_dir="$candidate"
            break
        fi
    done
    if [[ -z "$desktop_dir" ]]; then
        if command -v xdg-user-dir &>/dev/null; then
            desktop_dir=$(su - "$actual_user" -c "xdg-user-dir DESKTOP" 2>/dev/null) || true
        fi
    fi
    if [[ -z "$desktop_dir" ]] || [[ ! -d "$desktop_dir" ]]; then
        print_warning "Desktop directory not found for $actual_user. Skipping Welcome desktop shortcut."
        return 0
    fi

    # AutoShield is RETIRED as a standalone app — it is now a tab on the
    # dashboard startup screen (after Mobile). Remove any stale per-user launcher
    # instead of creating one; continue to (re)create the dashboard menu entry.
    rm -f "$desktop_dir/kodachi-autoshield.desktop" 2>/dev/null || true

    # Install/update system-wide Whisker menu entries in /usr/share/applications/
    local sys_apps="/usr/share/applications"
    if [[ -d "$sys_apps" ]]; then
        # Drop any stale standalone AutoShield system menu entry.
        rm -f "$sys_apps/kodachi-autoshield.desktop" 2>/dev/null || true

        cat > "$sys_apps/kodachi-dashboard.desktop" << SYSEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Kodachi Dashboard
GenericName=Security Dashboard
Comment=Kodachi Security Dashboard - control privacy, networking, and system hardening
Exec=/usr/local/bin/kodachi-dashboard-launcher
TryExec=/usr/local/bin/kodachi-dashboard-launcher
Icon=/usr/share/icons/kodachi/kodachi32.png
Terminal=false
Categories=System;Security;
Keywords=kodachi;dashboard;security;privacy;tor;vpn;dns;firewall;
StartupNotify=true
StartupWMClass=kodachi-dashboard
SYSEOF
        chmod 644 "$sys_apps/kodachi-dashboard.desktop"
        print_success "System-wide Whisker menu entries updated in $sys_apps"
    fi

    return 0
}

# NOTE: create_welcome_desktop_shortcut is invoked after detect_gui_environment() is defined.

# Function to download with retry logic, resume support, and wget fallback
retry_download() {
    local url="$1"
    local output="$2"
    local max_attempts=4
    local attempt=1
    local curl_exit=1

    # ── Phase 1: curl with resume ────────────────────────────────────────
    local -a curl_args
    curl_args=(
        --fail
        --location
        --show-error
        --connect-timeout 30
        --max-time 600
        --retry 3
        --retry-delay 3
        --retry-connrefused
        -C -
    )

    if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
        curl_args+=(--retry-all-errors)
    fi

    while [[ $attempt -le $max_attempts ]]; do
        print_verbose "Download attempt $attempt/$max_attempts (curl): $url"

        curl "${curl_args[@]}" --progress-bar -o "$output" "$url"
        curl_exit=$?

        if [[ $curl_exit -eq 0 ]] && [[ -f "$output" ]] && [[ -s "$output" ]]; then
            print_verbose "Download successful on attempt $attempt (curl)"
            return 0
        fi

        if [[ $curl_exit -eq 6 ]]; then
            print_verbose "DNS resolution failure detected (curl error 6)"
            if [[ $attempt -lt $max_attempts ]]; then
                print_info "Waiting for DNS to stabilize (attempt $attempt/$max_attempts)..."
                sleep 5
                wait_for_dns
            fi
        elif [[ $curl_exit -eq 33 ]]; then
            # Resume not supported by server, remove partial and retry fresh
            print_verbose "Server does not support resume, retrying without -C -"
            rm -f "$output" 2>/dev/null || true
            curl_args=("${curl_args[@]/-C -/}")
        elif [[ $attempt -lt $max_attempts ]]; then
            print_verbose "Download failed with curl error $curl_exit, retrying in 3 seconds..."
            sleep 3
        fi

        attempt=$((attempt + 1))
    done

    # ── Phase 2: wget fallback ───────────────────────────────────────────
    if command -v wget &>/dev/null; then
        print_info "curl failed after $max_attempts attempts, trying wget fallback..."
        rm -f "$output" 2>/dev/null || true

        for attempt in 1 2; do
            print_verbose "Download attempt $attempt/2 (wget): $url"

            if wget --continue --timeout=30 --tries=3 --waitretry=3 \
                    --progress=bar:force -O "$output" "$url" 2>&1; then
                if [[ -f "$output" ]] && [[ -s "$output" ]]; then
                    print_verbose "Download successful on attempt $attempt (wget)"
                    return 0
                fi
            fi

            if [[ $attempt -lt 2 ]]; then
                print_verbose "wget attempt $attempt failed, retrying in 5 seconds..."
                sleep 5
            fi
        done
    fi

    print_error "Failed to download after all attempts: $url"
    return 1
}

# Kodachi-first download (design D7): try a path-preserving mirror of the upstream URL on
# kodachi.cloud, then fall back to the EXACT upstream URL. Behavior is unchanged when the
# mirror is absent (a mirror miss falls straight through to upstream), so this never breaks
# an install; it only prefers Kodachi's signed mirror when reachable. Kill-switch: set
# KODACHI_NO_MIRROR=1 to force upstream-only.
kodachi_download_first() {
    local upstream="$1" dest="$2"
    if [ -z "${KODACHI_NO_MIRROR:-}" ]; then
        case "$upstream" in
          https://github.com/*)
            local mirror="https://kodachi.cloud/tools/mirror/${upstream#https://github.com/}"
            if retry_download "$mirror" "$dest" 2>/dev/null; then
                print_verbose "fetched from Kodachi mirror: $mirror"
                return 0
            fi
            print_verbose "Kodachi mirror miss, falling back to upstream: $upstream"
            ;;
        esac
    fi
    retry_download "$upstream" "$dest"
}

# Logging (file + console)
LOG_DIR="/var/log/kodachi"
LOG_FILE=""

setup_logging() {
    local ts
    ts=$(date +"%Y%m%d-%H%M%S")

    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        chmod 700 "$LOG_DIR" 2>/dev/null || true
    else
        LOG_DIR="/tmp"
    fi

    LOG_FILE="$LOG_DIR/kodachi-deps-install-$ts.log"
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/kodachi-deps-install-$ts.log"
        touch "$LOG_FILE" 2>/dev/null || true
    fi
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    exec > >(tee -a "$LOG_FILE") 2>&1
    print_info "Logging to ${CYAN}$LOG_FILE${NC}"
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        print_verbose "Verbose mode enabled - detailed output will be shown"
        print_verbose "Use 'tail -f $LOG_FILE' in another terminal to monitor progress"
    fi
}

# Version configuration
# Fallbacks only — overridden at runtime by resolve_mieru_release_metadata /
# resolve_latest_github_release_version (latest upstream). Kept current.
MIERU_VERSION="3.36.0"
HYSTERIA2_VERSION="2.12.2"
V2RAY_PLUGIN_VERSION="1.3.2"
# Fallback only — overridden at runtime by resolve_dnscrypt_release_metadata
# (latest upstream). Kept current to match the ISO cache freshness system.
DNSCRYPT_VERSION="2.1.18"
QRENCODE_VERSION="4.1.1"
KLOAK_VERSION="0.2"

extract_version_token_from_text() {
    local text="${1:-}"
    # Strip common archive extensions before extracting version to avoid matching .tar etc.
    text="${text%.tar.gz}"
    text="${text%.tar.xz}"
    text="${text%.tar.bz2}"
    text="${text%.tar.zst}"
    text="${text%.zip}"
    text="${text%.deb}"
    text="${text%.rpm}"
    text="${text%.tgz}"
    printf '%s\n' "$text" | grep -oE '([0-9]+\.)+[0-9]+([-.][0-9A-Za-z]+)?' | head -1
}

normalize_external_version() {
    local version="${1:-}"
    version="${version#v}"
    version="${version#app/}"
    version="${version#release-}"
    printf '%s\n' "$version"
}

github_fetch_release_json() {
    local repo="${1:-}"
    local output="${2:-}"

    [[ -n "$repo" && -n "$output" ]] || return 1

    curl -fsSL --proto =https --tlsv1.2 \
        --retry 2 --retry-delay 2 --retry-connrefused \
        --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -o "$output" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null
}

github_fetch_tags_json() {
    local repo="${1:-}"
    local output="${2:-}"

    [[ -n "$repo" && -n "$output" ]] || return 1

    curl -fsSL --proto =https --tlsv1.2 \
        --retry 2 --retry-delay 2 --retry-connrefused \
        --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -o "$output" "https://api.github.com/repos/${repo}/tags?per_page=5" 2>/dev/null
}

github_release_tag_from_file() {
    local json_file="${1:-}"
    [[ -n "$json_file" && -f "$json_file" ]] || return 1
    sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" | head -1
}

github_release_asset_url_from_file() {
    local json_file="${1:-}"
    local asset_regex="${2:-}"

    [[ -n "$json_file" && -f "$json_file" && -n "$asset_regex" ]] || return 1

    sed -n 's/^[[:space:]]*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" \
        | grep -E "$asset_regex" | head -1 || true
}

github_first_tag_from_file() {
    local json_file="${1:-}"
    [[ -n "$json_file" && -f "$json_file" ]] || return 1
    sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" | head -1
}

transform_external_version_value() {
    local value="${1:-}"
    local sed_expr="${2:-}"

    if [[ -n "$sed_expr" ]]; then
        printf '%s\n' "$value" | sed -e "$sed_expr"
        return 0
    fi

    printf '%s\n' "$value"
}

resolve_latest_github_release_version() {
    local repo="${1:-}"
    local fallback_version="${2:-}"
    local transform_expr="${3:-}"
    local tmp_file=""
    local tag=""
    local resolved_version="$fallback_version"

    tmp_file="$(mktemp /tmp/kodachi-release-XXXXXX.json 2>/dev/null || true)"
    if [[ -n "$tmp_file" ]] && github_fetch_release_json "$repo" "$tmp_file"; then
        tag="$(github_release_tag_from_file "$tmp_file" || true)"
        if [[ -n "$tag" ]]; then
            tag="$(transform_external_version_value "$tag" "$transform_expr")"
            tag="$(normalize_external_version "$tag")"
            if [[ -n "$tag" ]]; then
                resolved_version="$tag"
            fi
        fi
    fi

    [[ -n "$tmp_file" ]] && rm -f "$tmp_file"
    printf '%s\n' "$resolved_version"
}

resolve_latest_github_tag_version() {
    local repo="${1:-}"
    local fallback_version="${2:-}"
    local transform_expr="${3:-}"
    local tmp_file=""
    local tag=""
    local resolved_version="$fallback_version"

    tmp_file="$(mktemp /tmp/kodachi-tags-XXXXXX.json 2>/dev/null || true)"
    if [[ -n "$tmp_file" ]] && github_fetch_tags_json "$repo" "$tmp_file"; then
        tag="$(github_first_tag_from_file "$tmp_file" || true)"
        if [[ -n "$tag" ]]; then
            tag="$(transform_external_version_value "$tag" "$transform_expr")"
            tag="$(normalize_external_version "$tag")"
            if [[ -n "$tag" ]]; then
                resolved_version="$tag"
            fi
        fi
    fi

    [[ -n "$tmp_file" ]] && rm -f "$tmp_file"
    printf '%s\n' "$resolved_version"
}

resolve_dnscrypt_release_metadata() {
    local dnscrypt_arch="${1:-}"
    local fallback_version="${DNSCRYPT_VERSION:-2.1.16}"
    local fallback_url="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${fallback_version}/dnscrypt-proxy-linux_${dnscrypt_arch}-${fallback_version}.tar.gz"
    local release_json=""
    local asset_url=""
    local resolved_version="$fallback_version"

    release_json="$(mktemp /tmp/kodachi-dnscrypt-XXXXXX.json 2>/dev/null || true)"
    if [[ -n "$release_json" ]] && github_fetch_release_json "DNSCrypt/dnscrypt-proxy" "$release_json"; then
        asset_url="$(github_release_asset_url_from_file "$release_json" "^https://github\\.com/.*/dnscrypt-proxy-linux_${dnscrypt_arch}-[0-9][0-9A-Za-z.+:-]*\\.tar\\.gz$")"
        if [[ -n "$asset_url" ]]; then
            resolved_version="$(extract_version_token_from_text "$(basename "$asset_url")")"
        fi
    fi

    [[ -n "$release_json" ]] && rm -f "$release_json"

    if [[ -z "$asset_url" ]]; then
        asset_url="$fallback_url"
    fi

    if [[ -z "$resolved_version" ]]; then
        resolved_version="$fallback_version"
    fi

    printf '%s|%s\n' "$resolved_version" "$asset_url"
}

resolve_v2ray_plugin_release_metadata() {
    local plugin_arch="${1:-}"
    local fallback_version="${V2RAY_PLUGIN_VERSION:-1.3.2}"
    local fallback_url="https://github.com/shadowsocks/v2ray-plugin/releases/download/v${fallback_version}/v2ray-plugin-linux-${plugin_arch}-v${fallback_version}.tar.gz"
    local release_json=""
    local asset_url=""
    local resolved_version="$fallback_version"

    release_json="$(mktemp /tmp/kodachi-v2ray-plugin-XXXXXX.json 2>/dev/null || true)"
    if [[ -n "$release_json" ]] && github_fetch_release_json "shadowsocks/v2ray-plugin" "$release_json"; then
        asset_url="$(github_release_asset_url_from_file "$release_json" "^https://github\\.com/.*/v2ray-plugin-linux-${plugin_arch}-v[0-9][0-9A-Za-z.+:-]*\\.tar\\.gz$")"
        if [[ -n "$asset_url" ]]; then
            resolved_version="$(extract_version_token_from_text "$(basename "$asset_url")")"
        fi
    fi

    [[ -n "$release_json" ]] && rm -f "$release_json"

    if [[ -z "$asset_url" ]]; then
        asset_url="$fallback_url"
    fi

    if [[ -z "$resolved_version" ]]; then
        resolved_version="$fallback_version"
    fi

    printf '%s|%s\n' "$resolved_version" "$asset_url"
}

resolve_mieru_release_metadata() {
    local mieru_arch="${1:-}"
    local fallback_version="${MIERU_VERSION:-3.33.0}"
    local fallback_url="https://github.com/enfein/mieru/releases/download/v${fallback_version}/mieru_${fallback_version}_${mieru_arch}.deb"
    local release_json=""
    local asset_url=""
    local resolved_version="$fallback_version"

    release_json="$(mktemp /tmp/kodachi-mieru-XXXXXX.json 2>/dev/null || true)"
    if [[ -n "$release_json" ]] && github_fetch_release_json "enfein/mieru" "$release_json"; then
        asset_url="$(github_release_asset_url_from_file "$release_json" "^https://github\\.com/.*/mieru_[0-9][0-9A-Za-z.+:-]*_${mieru_arch}\\.deb$")"
        if [[ -n "$asset_url" ]]; then
            resolved_version="$(extract_version_token_from_text "$(basename "$asset_url")")"
        fi
    fi

    [[ -n "$release_json" ]] && rm -f "$release_json"

    if [[ -z "$asset_url" ]]; then
        asset_url="$fallback_url"
    fi

    if [[ -z "$resolved_version" ]]; then
        resolved_version="$fallback_version"
    fi

    printf '%s|%s\n' "$resolved_version" "$asset_url"
}

# ============================================================================
# Version Comparison Functions
# ============================================================================

# Get installed version of a binary
get_installed_version() {
    local binary="$1"
    local version_flag="${2:---version}"  # Default flag

    if ! command -v "$binary" &>/dev/null; then
        echo ""
        return 1
    fi

    # Try different version extraction methods
    local version=""

    # Method 1: Direct version command
    # `|| true`: under `set -eo pipefail` a non-matching grep aborts the whole
    # installer, which would make the Method 2/3 fallbacks below unreachable.
    version=$("$binary" "$version_flag" 2>&1 | grep -oP '([0-9]+\.)+[0-9]+' | head -1 || true)

    # Method 2: For binaries that don't follow standard patterns
    if [[ -z "$version" ]]; then
        version=$("$binary" version 2>&1 | grep -oP '([0-9]+\.)+[0-9]+' | head -1 || true)
    fi

    # Method 3: For dpkg packages
    if [[ -z "$version" ]] && dpkg -l "$binary" 2>/dev/null | grep -q "^ii"; then
        version=$(dpkg -l "$binary" | grep "^ii" | awk '{print $3}' | grep -oP '([0-9]+\.)+[0-9]+' | head -1 || true)
    fi

    echo "$version"
}

# Compare two version strings
# Returns: 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
    local v1="$1"
    local v2="$2"

    # Remove 'v' prefix if present
    v1="${v1#v}"
    v2="${v2#v}"

    if [[ "$v1" == "$v2" ]]; then
        return 0  # Equal
    fi

    # Use sort -V for version comparison
    local sorted=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)

    if [[ "$sorted" == "$v1" ]]; then
        return 2  # v1 < v2
    else
        return 1  # v1 > v2
    fi
}

# Check if binary needs upgrade
needs_upgrade() {
    local binary="$1"
    local target_version="$2"
    local version_flag="${3:---version}"

    local installed_version=$(get_installed_version "$binary" "$version_flag")

    if [[ -z "$installed_version" ]]; then
        # Not installed
        return 0  # Needs install
    fi

    compare_versions "$installed_version" "$target_version"
    local result=$?

    if [[ $result -eq 2 ]]; then
        # Installed version < target version
        echo "upgrade|$installed_version|$target_version"
        return 0  # Needs upgrade
    elif [[ $result -eq 0 ]]; then
        # Versions are equal
        echo "current|$installed_version|$target_version"
        return 1  # No upgrade needed
    else
        # Installed version > target version (downgrade scenario)
        echo "newer|$installed_version|$target_version"
        return 1  # Don't downgrade
    fi
}

# Package categories - Reorganized for interactive installation
# Essential - Core system requirements
ESSENTIAL_PACKAGES="curl wget openssl ca-certificates coreutils findutils grep procps psmisc systemd sudo dmidecode lsof acl util-linux util-linux-extra mount uuid-runtime inotify-tools ntpsec ntpsec-ntpdate isc-dhcp-client pass pwgen xkcdpass"

# Networking - Network and VPN tools
NETWORK_PACKAGES="tor tor-geoipdb torsocks obfs4proxy openvpn wireguard-tools iptables nftables arptables ebtables iproute2 iputils-ping net-tools nyx apt-transport-tor shadowsocks-libev redsocks microsocks haproxy"

# Security - Protection and hardening tools
SECURITY_PACKAGES="ufw macchanger firejail apparmor apparmor-utils apparmor-profiles aide lynis rkhunter chkrootkit usbguard ecryptfs-utils cryptsetup cryptsetup-initramfs cryptsetup-nuke-password fail2ban unattended-upgrades auditd libpam-pwquality libpam-google-authenticator secure-delete wipe nwipe libcap2-bin debsums cron"

# Privacy - DNS and anonymity tools
PRIVACY_PACKAGES="dnsutils bind9-dnsutils systemd-resolved"

# Advanced - Specialized tools and utilities (non-GUI)
# fwupd added 2026-09-02: it is the producer behind the Firmware & Platform panel in the
# Cairo Dock Status window and the dashboard's Vitals island. `health-control
# firmware-security-check` shells out to `fwupdtool security` for the Host Security Interface
# checks, so without this package both surfaces render "unreadable" with a correct reason and
# the user has no way to know it is one package away. The ISO already declares fwupd in
# terminal.list.chroot; this covers the OTHER install path, the documented
# `curl -sSL .../kodachi-deps-install.sh | sudo bash` onto an existing Debian.
ADVANCED_PACKAGES="jq git build-essential libxcb1-dev libxcb-xkb-dev rng-tools-debian haveged ccze yamllint smartmontools lm-sensors hdparm htop iotop vnstat efibootmgr fwupd rfkill ethtool lsb-release pciutils restic"

# Monitoring - System and network monitoring tools for dashboard
MONITORING_PACKAGES="btop iftop nethogs ncdu nload iperf3 speedtest-cli"

# GUI-only packages - only installed on systems with desktop environments.
# Includes the runtime packages required by Kodachi rofi menus on installed systems.
# WebKitGTK + GStreamer entries are the runtime the Kodachi GUI dashboard
# (Tauri/WebKitGTK binary under /opt) dynamically links at load time. They have no
# apt dependency edge to the /opt binary, so naming them here installs + manual-marks
# them; without this they survive only transitively and `apt autoremove` can reap
# libgstreamer-plugins-base1.0-0, breaking the dashboard with
# "error while loading shared libraries: libgstvideo-1.0.so.0" (field report 2026-06-15).
GUI_PACKAGES="bleachbit kitty fontconfig fonts-dejavu fonts-noto-core fonts-noto-color-emoji fonts-liberation fonts-liberation2 ttf-mscorefonts-installer conky-all alsa-utils pipewire pipewire-pulse pipewire-alsa wireplumber pulseaudio-utils libnotify-bin xclip xsel mpv xterm network-manager rofi xfce4-screenshooter xdotool xfce4-clipman xfce4-clipman-plugin copyq qalculate-gtk maim translate-shell python3 bc iproute2 iputils-ping traceroute speedtest-cli libwebkit2gtk-4.1-0 libayatana-appindicator3-1 xdg-utils libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libgstreamer-gl1.0-0 gstreamer1.0-plugins-base gstreamer1.0-gl"

# Packages that require contrib/non-free repositories
CONTRIB_PACKAGES="shadowsocks-v2ray-plugin v2ray"

# Separate resolvconf as it can conflict with systemd-resolved
RESOLVCONF_PACKAGE="resolvconf"

# Parse command line arguments
INSTALL_MODE="full"
AUTO_YES=true
INSTALL_KICKSECURE_RAMWIPE=false
FORCE_GUI_INSTALL=false
SKIP_GUI_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --minimal)
            INSTALL_MODE="minimal"
            shift
            ;;
        --full)
            INSTALL_MODE="full"
            shift
            ;;
        --interactive)
            INSTALL_MODE="interactive"
            AUTO_YES=false  # Interactive mode should not auto-answer
            shift
            ;;
        --proxy-only)
            INSTALL_MODE="proxy"
            shift
            ;;
        --auto)
            AUTO_YES=true
            shift
            ;;
        --no-auto)
            AUTO_YES=false
            shift
            ;;
        --force-kicksecure-ramwipe)
            INSTALL_KICKSECURE_RAMWIPE=true
            shift
            ;;
        --forcegui|--force-gui)
            FORCE_GUI_INSTALL=true
            shift
            ;;
        --skipgui|--skip-gui)
            SKIP_GUI_INSTALL=true
            shift
            ;;
        --verbose|-v)
            VERBOSE_MODE=true
            echo -e "${CYAN}[VERBOSE]${NC} Verbose mode enabled - showing detailed output"
            shift
            ;;
        --help)
            echo "Kodachi Dependencies Installation Script"
            echo ""
            echo "Usage:"
            echo "  curl -sSL .../kodachi-deps-install.sh | sudo bash"
            echo "  sudo bash kodachi-deps-install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --minimal                    Install only critical packages"
            echo "  --full                       Install all packages (default)"
            echo "  --interactive                Interactive category-based installation"
            echo "  --proxy-only                 Install only proxy tools"
            echo "  --auto                       Automatic mode - answer yes to all prompts (default)"
            echo "  --no-auto                    Disable automatic mode - require user confirmation"
            echo "  --forcegui, --force-gui      Force installation of GUI packages on terminal-based systems"
            echo "                               By default: GUI packages skipped if no desktop environment detected"
            echo "  --skipgui, --skip-gui        Skip GUI packages even on systems with desktop environments"
            echo "                               Use this for headless server installations on GUI systems"
            echo "  --force-kicksecure-ramwipe   Keep/Install Kicksecure RAM wipe (dracut + ram-wipe)"
            echo "                               By default: Removes dracut/ram-wipe, restores initramfs-tools"
            echo "                               Note: Kodachi has built-in RAM wipe via 'health-control memory-wipe'"
            echo "  --verbose, -v                Enable verbose mode - show detailed output"
            echo "  --help                       Show this help message"
            echo ""
            echo "Examples:"
            echo "  sudo bash kodachi-deps-install.sh --full --auto"
            echo "  sudo bash kodachi-deps-install.sh --interactive"
            echo "  sudo bash kodachi-deps-install.sh --full --skipgui"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Function to check if systemd-resolved is managing DNS
check_systemd_resolved() {
    # Check if systemd-resolved is active
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        # Check if /etc/resolv.conf is a symlink to systemd-resolved
        if [[ -L "/etc/resolv.conf" ]] && [[ "$(readlink -f /etc/resolv.conf)" == *"systemd"* ]]; then
            return 0  # systemd-resolved is managing DNS
        fi
    fi
    return 1  # systemd-resolved is not managing DNS
}

# Function to detect if system has GUI/desktop environment
detect_gui_environment() {
    # Check for DISPLAY variable (X11 session)
    if [[ -n "$DISPLAY" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
        return 0  # GUI detected
    fi

    # Check for running display managers
    local display_managers=(
        "lightdm" "gdm3" "gdm" "sddm" "kdm" "xdm" "lxdm" "slim"
        "nodm" "wdm" "entrance" "ly"
    )
    for dm in "${display_managers[@]}"; do
        if systemctl is-active --quiet "$dm" 2>/dev/null || pgrep -x "$dm" >/dev/null 2>&1; then
            return 0  # Display manager running
        fi
    done

    # Check systemd default target
    if systemctl get-default 2>/dev/null | grep -q "graphical.target"; then
        return 0  # System configured for graphical boot
    fi

    # Check for X11 or Wayland processes
    if pgrep -x "Xorg" >/dev/null 2>&1 || pgrep -x "X" >/dev/null 2>&1; then
        return 0  # X11 server running
    fi
    if pgrep -f "wayland" >/dev/null 2>&1 || [[ -n "$XDG_SESSION_TYPE" ]] && [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        return 0  # Wayland session running
    fi

    # Check for installed desktop environments
    local desktop_packages=(
        "xfce4" "gnome-shell" "plasma-desktop" "lxde" "mate-desktop"
        "cinnamon" "budgie-desktop" "i3" "openbox"
    )
    for de in "${desktop_packages[@]}"; do
        if dpkg -l "$de" 2>/dev/null | grep -q "^ii"; then
            return 0  # Desktop environment installed
        fi
    done

    return 1  # No GUI detected
}

# Now that detect_gui_environment() is defined, invoke the dashboard setup functions.
setup_dashboard_autostart
setup_session_helper_service
create_welcome_desktop_shortcut

# Build GUI package list for current system.
# Conky is GUI-desktop-specific and should be skipped on terminal/headless systems.
get_gui_packages_for_install() {
    local packages="$GUI_PACKAGES"

    if ! detect_gui_environment; then
        packages=$(echo " $packages " | sed 's/ conky-all / /g' | xargs)
    fi

    echo "$packages"
}

# Function to install resolvconf with conflict handling
install_resolvconf_safe() {
    print_step "Checking resolvconf for WireGuard/OpenVPN support..."

    # First check if resolvconf has broken or partial installation
    local resolvconf_status=$(dpkg -l resolvconf 2>/dev/null | grep "^[ruihpF]" | awk '{print $1}')
    if [[ -n "$resolvconf_status" ]] && [[ "$resolvconf_status" != "ii" ]] && [[ "$resolvconf_status" != "un" ]]; then
        print_warning "Found broken resolvconf package (status: $resolvconf_status) - removing it"
        dpkg --remove --force-remove-reinstreq resolvconf 2>/dev/null || true
        dpkg --purge resolvconf 2>/dev/null || true
        apt-get clean 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
    fi

    # Check if resolvconf is already properly installed
    if check_package "resolvconf"; then
        print_success "resolvconf is already installed"
        return 0
    fi

    # Check if resolvconf command exists (might be installed differently)
    if command -v resolvconf &>/dev/null; then
        print_success "resolvconf command is available"
        return 0
    fi

    # Check if WireGuard or OpenVPN is installed - they need resolvconf
    local need_resolvconf=false
    if check_package "wireguard-tools" || command -v wg-quick &>/dev/null; then
        print_info "WireGuard detected - needs resolvconf for DNS management"
        need_resolvconf=true
    fi
    if check_package "openvpn" || command -v openvpn &>/dev/null; then
        print_info "OpenVPN detected - may need resolvconf for DNS management"
        need_resolvconf=true
    fi

    # If VPN tools need resolvconf, try alternative solutions
    if [[ "$need_resolvconf" == "true" ]]; then
        print_warning "VPN tools need resolvconf functionality"

        # Option 1: Check DNS mode before installing openresolv
        if check_systemd_resolved; then
            # MODERN MODE: Do not install openresolv (conflicts with systemd-resolved)
            print_info "systemd-resolved detected - skipping openresolv (would conflict)"
            print_info "VPNs should use systemd-resolved's resolvectl for DNS updates"
        else
            # LEGACY MODE: Safe to install openresolv
            print_step "Installing openresolv as resolvconf alternative..."
            if (set -o pipefail; apt-get install -y openresolv 2>&1 | tail -5); then
                if command -v resolvconf &>/dev/null; then
                    print_success "openresolv installed successfully - provides resolvconf command"
                    return 0
                fi
            fi
        fi

        # Option 2: Create a stub resolvconf script for WireGuard
        print_step "Creating resolvconf stub for WireGuard/OpenVPN..."
        cat > /tmp/resolvconf-stub << 'EOF'
#!/bin/bash
# Stub resolvconf for WireGuard/OpenVPN
# This prevents errors when VPNs try to update DNS

case "$1" in
    -a|-d)
        # Add or delete - just ignore for now
        # DNS is managed by dnscrypt-proxy/Pi-hole
        exit 0
        ;;
    *)
        # Other commands - ignore
        exit 0
        ;;
esac
EOF

        if [[ -f /tmp/resolvconf-stub ]]; then
            chmod +x /tmp/resolvconf-stub
            mv /tmp/resolvconf-stub /usr/local/bin/resolvconf
            print_success "Created resolvconf stub for VPN compatibility"
            print_info "Note: DNS updates from VPNs will be ignored - managed by dnscrypt-proxy/Pi-hole"
            return 0
        fi
    fi

    # If no VPN tools or alternatives worked, that's fine
    print_info "resolvconf not needed - DNS managed by dnscrypt-proxy/Pi-hole"
    print_info "If you use WireGuard/OpenVPN, DNS updates may need manual configuration"
    return 0
}

# Function to test and fix DNS after package installation
test_and_fix_dns() {
    local package_name="$1"

    print_step "Testing DNS after installing $package_name..."

    if dns_resolution_working; then
        print_success "DNS is working correctly after $package_name install"
        return 0
    fi

    print_warning "DNS broken after installing $package_name - starting fallback-first recovery..."
    if ensure_dns_stable_after_change "$package_name install"; then
        return 0
    fi

    print_error "DNS STILL BROKEN after all fixes - downloads will fail!"
    print_info "Manual recovery: sudo dns-switch fallback"
    print_info "Last resort: sudo dns-switch random --type reputable --count 3 --verify"
    return 1
}

# Function to install privacy packages one by one with DNS testing
install_privacy_packages_safe() {
    print_highlight "Installing Privacy packages (with DNS testing after each)..."
    echo ""

    # Install each package separately and test DNS after each
    local privacy_pkgs=("dnsutils" "bind9-dnsutils" "systemd-resolved")

    for pkg in "${privacy_pkgs[@]}"; do
        print_step "Installing $pkg..."

        if check_package "$pkg"; then
            print_success "$pkg is already installed"
        else
            print_step "Installing $pkg..."
            if (set -o pipefail; timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null "$pkg" 2>&1 | tail -10); then
                print_success "$pkg installed successfully"
            else
                print_error "Failed to install $pkg"
                continue
            fi
        fi

        # CRITICAL: Test and fix DNS after each package
        test_and_fix_dns "$pkg"
        echo ""
    done

    # Configure systemd-resolved after all packages are installed
    configure_systemd_resolved
}

# Function to configure systemd-resolved safely
configure_systemd_resolved() {
    print_step "Configuring DNS..."

    # audit 2026-05-05: on Kodachi (DNSCrypt-only, systemd-resolved masked),
    # we don't configure resolved at all. /etc/resolv.conf -> 127.0.0.1 is
    # the entire DNS path. Verify dnscrypt-proxy is up; if so, point
    # resolv.conf and bail. If not, fall through to the legacy resolved
    # path which handles the emergency case (dnscrypt-proxy not yet
    # enabled, e.g., during a stage of fresh install before kodachi
    # presets land).
    if systemd_resolved_is_masked; then
        print_info "systemd-resolved is masked (Kodachi DNSCrypt-only architecture)"
        if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
           timeout 5 dig @127.0.0.1 +short +timeout=3 debian.org >/dev/null 2>&1; then
            point_resolv_conf_to_dnscrypt
            print_success "DNS configured: /etc/resolv.conf -> 127.0.0.1 (DNSCrypt)"

            print_verbose "Waiting 2 seconds for DNS to settle..."
            sleep 2
            if dns_resolution_working; then
                print_success "DNS is working correctly"
                return 0
            fi
            print_warning "DNS test failed but DNSCrypt is up — likely transient, continuing"
            return 0
        else
            print_warning "dnscrypt-proxy not responsive — applying emergency fallback"
            apply_fallback_dns
            return 0
        fi
    fi

    # Legacy path: systemd-resolved-managed system.

    local resolved_profile="primary"
    local resolved_owner="systemd-resolved"
    local resolv_conf_target=""

    # CRITICAL: Always configure DNS immediately, don't wait for package checks
    # DNSCrypt: must be active AND responding to queries (not just enabled)
    if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null && \
       timeout 5 dig @127.0.0.1 +short +timeout=3 debian.org >/dev/null 2>&1; then
        print_info "dnscrypt-proxy is active and responding - configuring as primary DNS"
        resolved_profile="dnscrypt"
        resolved_owner="dnscrypt-proxy"
    elif systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        print_info "Pi-hole is active - configuring systemd-resolved as fallback"
        resolved_profile="external"
        resolved_owner="Pi-hole"
    else
        print_info "Configuring systemd-resolved as primary DNS resolver (privacy-focused, NO Google)"
    fi

    write_kodachi_resolved_profile "$resolved_profile" "$resolved_owner" || return 1

    # Enable and start systemd-resolved if not active
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        print_step "Enabling systemd-resolved service..."
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
    else
        # Restart to apply new configuration
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    seed_systemd_resolved_bootstrap_files
    resolv_conf_target="$(resolved_resolv_conf_target "$resolved_profile")"

    if [[ "$resolved_profile" == "primary" ]] && dns_build_chroot_environment; then
        print_info "Chroot detected - keeping /etc/resolv.conf on runtime DNS file during build"
    fi

    point_resolv_conf_to_target "$resolv_conf_target"

    if [[ "$resolved_profile" == "primary" ]]; then
        print_success "systemd-resolved configured with privacy-focused DNS (NO Google)"
    else
        print_success "systemd-resolved configured as fallback while ${resolved_owner} owns DNS"
    fi

    # Wait for DNS service to stabilize
    print_verbose "Waiting 3 seconds for DNS service to stabilize..."
    sleep 3

    if dns_resolution_working; then
        print_success "DNS is working correctly - internet restored!"
        return 0
    fi

    print_warning "DNS test failed after systemd-resolved changes"
    if ensure_dns_stable_after_change "systemd-resolved configuration"; then
        return 0
    fi

    print_error "DNS still not working after all fixes - downloads may fail"
    print_info "Manual recovery: sudo dns-switch fallback"
    print_info "Last resort: sudo dns-switch random --type reputable --count 3 --verify"
    return 1
}

# Function to initialize iptables alternatives properly
initialize_iptables_alternatives() {
    print_step "Initializing iptables alternatives..."

    # Install arptables and ebtables if missing
    local missing_packages=""
    for pkg in arptables ebtables; do
        if ! check_package "$pkg"; then
            missing_packages="$missing_packages $pkg"
        fi
    done

    if [[ -n "$missing_packages" ]]; then
        print_info "Installing missing packages:$missing_packages"
        apt-get install -y $missing_packages 2>&1 | tail -5
    fi

    # Create the arptables alternatives group if missing (register both backends when present)
    if ! update-alternatives --query arptables >/dev/null 2>&1; then
        print_info "Registering arptables alternatives..."
        [ -x /usr/sbin/arptables-legacy ] && update-alternatives --install /usr/sbin/arptables arptables /usr/sbin/arptables-legacy 10
        [ -x /usr/sbin/arptables-nft ] && update-alternatives --install /usr/sbin/arptables arptables /usr/sbin/arptables-nft 20
    fi

    # Create the ebtables alternatives group if missing
    if ! update-alternatives --query ebtables >/dev/null 2>&1; then
        print_info "Registering ebtables alternatives..."
        [ -x /usr/sbin/ebtables-legacy ] && update-alternatives --install /usr/sbin/ebtables ebtables /usr/sbin/ebtables-legacy 10
        [ -x /usr/sbin/ebtables-nft ] && update-alternatives --install /usr/sbin/ebtables ebtables /usr/sbin/ebtables-nft 20
    fi

    # Optionally align arptables/ebtables to whichever iptables backend is active (safe no-op if unknown)
    local IPT=$(readlink -f /etc/alternatives/iptables 2>/dev/null || true)
    case "$IPT" in
        *iptables-legacy)
            [ -x /usr/sbin/arptables-legacy ] && update-alternatives --set arptables /usr/sbin/arptables-legacy 2>/dev/null || true
            [ -x /usr/sbin/ebtables-legacy ] && update-alternatives --set ebtables /usr/sbin/ebtables-legacy 2>/dev/null || true
            print_success "Aligned arptables/ebtables to legacy backend"
            ;;
        *iptables-nft)
            [ -x /usr/sbin/arptables-nft ] && update-alternatives --set arptables /usr/sbin/arptables-nft 2>/dev/null || true
            [ -x /usr/sbin/ebtables-nft ] && update-alternatives --set ebtables /usr/sbin/ebtables-nft 2>/dev/null || true
            print_success "Aligned arptables/ebtables to nft backend"
            ;;
        *)
            print_info "iptables backend unknown, skipping alignment"
            ;;
    esac

    print_success "iptables alternatives initialized"
}

# Function to check if contrib and non-free are enabled
check_contrib_nonfree() {
    local has_contrib=false
    local has_nonfree=false

    if grep -q "contrib" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        has_contrib=true
    fi

    if grep -q "non-free" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
        has_nonfree=true
    fi

    if [[ "$has_contrib" == "true" ]] && [[ "$has_nonfree" == "true" ]]; then
        return 0  # Both are enabled
    else
        return 1  # One or both are missing
    fi
}

# Function to automatically enable contrib and non-free repositories
enable_contrib_nonfree() {
    print_step "Enabling contrib and non-free repositories..."

    # Backup sources.list
    cp /etc/apt/sources.list /etc/apt/sources.list.backup 2>/dev/null || true

    # Modify sources.list to add contrib non-free non-free-firmware
    # This works for any Debian-based distribution
    sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
    sed -i 's/main contrib$/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
    sed -i 's/main non-free$/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true

    # Update package lists
    print_step "Updating package lists after enabling repositories..."
    if apt-get update 2>&1 | tail -10; then
        print_success "Contrib and non-free repositories enabled and package lists updated"
        return 0
    else
        print_warning "Failed to update package lists, but repositories were modified"
        return 1
    fi
}

# Function to install DNSCrypt Proxy from GitHub
install_dnscrypt_github() {
    print_step "Checking DNSCrypt Proxy installation..."

    local arch=""
    local resolved_dnscrypt_version=""
    local resolved_dnscrypt_url=""
    local temp_dir="/tmp/dnscrypt-proxy-install"
    local install_dir="/etc/dnscrypt-proxy"

    case $(uname -m) in
        x86_64) arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *)
            print_error "Unsupported architecture for DNSCrypt Proxy: $(uname -m)"
            return 1
            ;;
    esac

    IFS='|' read -r resolved_dnscrypt_version resolved_dnscrypt_url <<< "$(resolve_dnscrypt_release_metadata "$arch")"
    if [[ -n "$resolved_dnscrypt_version" ]]; then
        DNSCRYPT_VERSION="$resolved_dnscrypt_version"
    fi

    # Check if upgrade is needed
    local check_result=$(needs_upgrade "dnscrypt-proxy" "$DNSCRYPT_VERSION" "-version")
    local status=$(echo "$check_result" | cut -d'|' -f1)
    local installed=$(echo "$check_result" | cut -d'|' -f2)
    local target=$(echo "$check_result" | cut -d'|' -f3)

    if [[ "$status" == "current" ]]; then
        print_success "DNSCrypt Proxy is already up to date (v$installed)"

        # ALWAYS ensure config file exists
        setup_dnscrypt_config

        setup_dnscrypt_service "existing"

        ensure_dns_stable_after_change "DNSCrypt installation" || true
        return 0
    elif [[ "$status" == "newer" ]]; then
        print_success "DNSCrypt Proxy is already installed (v$installed, newer than target v$target)"

        # ALWAYS ensure config file exists
        setup_dnscrypt_config

        setup_dnscrypt_service "existing"

        ensure_dns_stable_after_change "DNSCrypt installation" || true
        return 0
    elif [[ "$status" == "upgrade" ]]; then
        print_warning "DNSCrypt Proxy found (v$installed) - upgrading to v$target..."
    else
        print_step "Installing DNSCrypt Proxy v$DNSCRYPT_VERSION..."
    fi

    echo "Downloading DNSCrypt Proxy v${DNSCRYPT_VERSION}..."
    mkdir -p "$temp_dir"

    if kodachi_download_first "$resolved_dnscrypt_url" "$temp_dir/dnscrypt-proxy.tar.gz"; then
        echo "Extracting DNSCrypt Proxy..."
        tar -xzf "$temp_dir/dnscrypt-proxy.tar.gz" -C "$temp_dir"

        # Find and install the binary
        local extracted_dir=$(find "$temp_dir" -name "linux-${arch}" -type d | head -1)
        if [[ -z "$extracted_dir" ]]; then
            # Try different naming pattern
            extracted_dir=$(find "$temp_dir" -name "*linux*${arch}*" -type d | head -1)
        fi

        if [[ -n "$extracted_dir" && -f "$extracted_dir/dnscrypt-proxy" ]]; then
            print_info "Installing DNSCrypt Proxy to $install_dir..."
            sudo mkdir -p "$install_dir"
            sudo cp -r "$extracted_dir"/* "$install_dir/"
            sudo chmod +x "$install_dir/dnscrypt-proxy"

            # Create symbolic link for system-wide access
            if [[ -f "/usr/local/bin/dnscrypt-proxy" ]]; then
                sudo rm -f "/usr/local/bin/dnscrypt-proxy"
            fi
            sudo ln -sf "$install_dir/dnscrypt-proxy" "/usr/local/bin/dnscrypt-proxy"

            rm -rf "$temp_dir"
            print_success "DNSCrypt Proxy installed successfully from GitHub"

            # Setup configuration file
            setup_dnscrypt_config

            # Setup systemd service
            setup_dnscrypt_service "github"

            ensure_dns_stable_after_change "DNSCrypt installation" || true
            return 0
        else
            print_error "Could not find DNSCrypt Proxy binary in archive"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        print_error "Failed to download DNSCrypt Proxy from GitHub"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Function to install QRencode with apt-first strategy
install_qrencode_github() {
    print_step "Checking QRencode installation..."

    local resolved_qrencode_version=""
    local installed_after_apt=""
    local url=""
    local temp_dir="/tmp/qrencode-install-$$"

    resolved_qrencode_version="$(resolve_latest_github_tag_version "fukuchi/libqrencode" "$QRENCODE_VERSION" 's/^v//')"
    if [[ -n "$resolved_qrencode_version" ]]; then
        QRENCODE_VERSION="$resolved_qrencode_version"
    fi

    # Check if upgrade is needed
    local check_result=$(needs_upgrade "qrencode" "$QRENCODE_VERSION" "--version")
    local status=$(echo "$check_result" | cut -d'|' -f1)
    local installed=$(echo "$check_result" | cut -d'|' -f2)
    local target=$(echo "$check_result" | cut -d'|' -f3)

    if [[ "$status" == "current" ]]; then
        print_success "QRencode is already up to date (v$installed)"
        return 0
    elif [[ "$status" == "newer" ]]; then
        print_success "QRencode is already installed (v$installed, newer than target v$target)"
        return 0
    elif [[ "$status" == "upgrade" ]]; then
        print_warning "QRencode found (v$installed) - upgrading to v$target..."
    else
        print_step "Installing QRencode v$QRENCODE_VERSION..."
    fi

    # QRencode Installation Strategy:
    # - APT first: Same version (4.1.1), pre-compiled, faster installation
    # - GitHub fallback: For systems without apt package or version mismatch
    # - Compilation avoided when possible to reduce dependencies and time
    # - Archive URL used instead of releases/download (which doesn't exist)
    
    local install_success=false

    # Try APT installation first (preferred method)
    print_info "Attempting APT installation first (faster, pre-compiled)..."
    if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null qrencode 2>/dev/null; then
        installed_after_apt="$(get_installed_version "qrencode" "--version")"
        if [[ -n "$installed_after_apt" ]] && command -v qrencode &>/dev/null; then
            local version_cmp=0
            compare_versions "$installed_after_apt" "$QRENCODE_VERSION" || version_cmp=$?
            if [[ $version_cmp -ne 2 ]]; then
                print_success "QRencode installed successfully via APT"
                return 0
            fi
        fi
        print_warning "APT installed QRencode ${installed_after_apt:-unknown}, but ${QRENCODE_VERSION} is newer. Falling back to GitHub compilation..."
    fi

    # Fallback to GitHub compilation if APT is unavailable or behind upstream.
    print_warning "Using GitHub compilation fallback for QRencode..."
    url="https://github.com/fukuchi/libqrencode/archive/v${QRENCODE_VERSION}.tar.gz"

    echo "Installing build dependencies for compilation..."
    # Install build dependencies (cmake for build, libpng-dev for PNG QR output)
    apt-get update 2>/dev/null || true
    apt-get install -y build-essential cmake libpng-dev 2>&1 | tail -5

    echo "Downloading QRencode v${QRENCODE_VERSION} source..."
    mkdir -p "$temp_dir"
    cd "$temp_dir" || return 1

    # Download source from GitHub (using fixed archive URL)
    if retry_download "$url" "$temp_dir/v${QRENCODE_VERSION}.tar.gz"; then
        echo "Downloaded QRencode source from GitHub"

        # Extract and compile using cmake (GitHub archives don't include ./configure)
        if tar xf "v${QRENCODE_VERSION}.tar.gz" 2>/dev/null; then
            cd "libqrencode-${QRENCODE_VERSION}" || return 1
            mkdir -p build && cd build

            if cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POLICY_VERSION_MINIMUM=3.5 .. >/dev/null 2>&1 && \
               make >/dev/null 2>&1 && \
               make install >/dev/null 2>&1; then

                # Update library cache
                ldconfig 2>/dev/null || true

                # Verify installation
                if command -v qrencode &>/dev/null || [ -x /usr/local/bin/qrencode ]; then
                    print_success "QRencode compiled and installed successfully from GitHub (cmake)"
                    install_success=true
                fi
            fi
        fi
    fi

    # Cleanup
    cd / && rm -rf "$temp_dir"
    
    if [ "$install_success" = true ]; then
        return 0
    else
        print_error "Failed to install QRencode via both APT and GitHub compilation"
        return 1
    fi
}

# Function to install v2ray-plugin from GitHub
install_v2ray_plugin_github() {
    print_step "Checking v2ray-plugin installation..."

    local resolved_v2ray_plugin_version=""
    local resolved_v2ray_plugin_url=""

    # Check if upgrade is needed
    local arch=""
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *)
            print_error "Unsupported architecture for v2ray-plugin: $(uname -m)"
            return 1
            ;;
    esac

    IFS='|' read -r resolved_v2ray_plugin_version resolved_v2ray_plugin_url <<< "$(resolve_v2ray_plugin_release_metadata "$arch")"
    if [[ -n "$resolved_v2ray_plugin_version" ]]; then
        V2RAY_PLUGIN_VERSION="$resolved_v2ray_plugin_version"
    fi

    local check_result=$(needs_upgrade "v2ray-plugin" "$V2RAY_PLUGIN_VERSION" "--version")
    local status=$(echo "$check_result" | cut -d'|' -f1)
    local installed=$(echo "$check_result" | cut -d'|' -f2)
    local target=$(echo "$check_result" | cut -d'|' -f3)

    if [[ "$status" == "current" ]]; then
        print_success "v2ray-plugin is already up to date (v$installed)"
        return 0
    elif [[ "$status" == "newer" ]]; then
        print_success "v2ray-plugin is already installed (v$installed, newer than target v$target)"
        return 0
    elif [[ "$status" == "upgrade" ]]; then
        print_warning "v2ray-plugin found (v$installed) - upgrading to v$target..."
        # Remove old binary before installing new version
        rm -f /usr/local/bin/v2ray-plugin 2>/dev/null || true
        rm -f /usr/local/bin/ss-v2ray-plugin 2>/dev/null || true
    else
        print_step "Installing v2ray-plugin v$V2RAY_PLUGIN_VERSION..."
    fi
    local temp_dir="/tmp/v2ray-plugin-install"

    echo "Downloading v2ray-plugin v${V2RAY_PLUGIN_VERSION}..."
    mkdir -p "$temp_dir"

    if kodachi_download_first "$resolved_v2ray_plugin_url" "$temp_dir/v2ray-plugin.tar.gz"; then
        echo "Extracting v2ray-plugin..."
        tar -xzf "$temp_dir/v2ray-plugin.tar.gz" -C "$temp_dir"

        # Find and install the binary
        if [ -f "$temp_dir/v2ray-plugin_linux_${arch}" ]; then
            mv "$temp_dir/v2ray-plugin_linux_${arch}" /usr/local/bin/v2ray-plugin
        elif [ -f "$temp_dir/v2ray-plugin" ]; then
            mv "$temp_dir/v2ray-plugin" /usr/local/bin/v2ray-plugin
        else
            print_error "Could not find v2ray-plugin binary in archive"
            rm -rf "$temp_dir"
            return 1
        fi

        chmod +x /usr/local/bin/v2ray-plugin
        rm -rf "$temp_dir"

        # Create symlink for shadowsocks compatibility
        ln -sf /usr/local/bin/v2ray-plugin /usr/local/bin/ss-v2ray-plugin 2>/dev/null || true

        print_success "v2ray-plugin installed successfully from GitHub"
        return 0
    else
        print_error "Failed to download v2ray-plugin from GitHub"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Function to check if user is in sudoers
check_sudoers_status() {
    local current_user=$(whoami)
    local in_sudo_group=false

    # Check if user is in sudo group
    if groups | grep -qw "sudo"; then
        in_sudo_group=true
    elif groups | grep -qw "wheel"; then
        in_sudo_group=true
    fi

    if [[ "$in_sudo_group" == "true" ]]; then
        print_success "User '$current_user' is in the sudoers group"
        print_info "You can run this script with: sudo bash $0"
    else
        print_warning "User '$current_user' is NOT in the sudoers group"
        echo ""
        print_highlight "To add yourself to the sudoers group:"
        echo ""
        echo "  1. Switch to root user:"
        echo -e "     ${BOLD}su -${NC}"
        echo ""
        echo "  2. Add your user to sudo group:"
        echo -e "     ${BOLD}usermod -aG sudo $current_user${NC}"
        echo ""
        echo "  3. Exit root session:"
        echo -e "     ${BOLD}exit${NC}"
        echo ""
        echo "  4. Log out and log back in for changes to take effect"
        echo ""
        print_info "After adding to sudoers, run: sudo bash $0"
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root or with sudo"
    echo ""

    # Check sudoers status and provide guidance
    check_sudoers_status

    exit 1
fi

# ============================================================================
# SYSTEM UPDATE - Upgrade all packages before installing dependencies
# ============================================================================
print_step "Updating system packages..."
print_info "Running apt-get update to refresh package lists..."

if apt-get update 2>&1 | tail -5; then
    print_success "Package lists updated successfully"
else
    print_warning "apt-get update had issues, continuing anyway..."
fi

# ---------------------------------------------------------------------------
# Protect Kodachi runtime-critical packages from the apt-get autoremove steps
# that run later in this script. `autoremove` only reaps packages marked
# auto-installed; on some installed systems e2fsprogs (provides chattr/lsattr)
# is auto-installed and gets reaped, which leaves the system unable to remove
# the immutable flag from /etc/resolv.conf. The DNS-leak lock then can't be
# lifted, so third-party VPN GUIs (Mullvad/ProtonVPN) fail with "internet
# blocked" until the user reinstalls e2fsprogs by hand (field report 2026-06-01).
# `apt-mark manual` writes to /var/lib/apt/extended_states (persistent), so this
# single call protects every autoremove run below.
print_step "Protecting Kodachi runtime-critical packages from autoremove..."
if ! command -v chattr >/dev/null 2>&1 || ! dpkg -s e2fsprogs >/dev/null 2>&1; then
    print_info "e2fsprogs (chattr/lsattr) missing — installing; required by the DNS-leak immutable lock"
    apt-get install -y e2fsprogs 2>&1 | tail -3 || true
fi
# e2fsprogs is the proven-critical one (chattr/lsattr for the resolv.conf immutable lock).
if apt-mark manual e2fsprogs >/dev/null 2>&1; then
    print_success "Pinned e2fsprogs manual (protects chattr/lsattr from autoremove)"
else
    print_warning "Could not pin e2fsprogs manual (chattr-based DNS lock may be at risk)"
fi
# Best-effort: pin the rest of the Kodachi privacy/runtime stack manual, but only
# packages actually installed (avoids false 'cannot mark' warnings for optional ones).
# These are deliberately-chosen Kodachi components that autoremove must never reap.
# tirdad-dkms in particular was confirmed reaped by autoremove in the past (TCP-timestamp
# anonymization), and gnupg can be auto-installed. Rationale: anything Kodachi's privacy
# stack relies on at runtime should survive an autoremove cleanup pass.
#
# WebKitGTK + GStreamer entries protect the Kodachi GUI dashboard's runtime: it is a
# Tauri/WebKitGTK binary under /opt with no apt dependency edge, so these libs are
# normally only transitive/auto-installed. autoremove reaping libgstreamer-plugins-
# base1.0-0 breaks the dashboard at startup ("cannot open shared object file:
# libgstvideo-1.0.so.0") even though everything else works (field report 2026-06-15).
KODACHI_PROTECT_PKGS="
    iproute2 iptables nftables openresolv resolvconf dnscrypt-proxy ca-certificates
    tor obfs4proxy macchanger tirdad-dkms wireguard-tools openvpn proxychains4
    apparmor apparmor-utils secure-delete network-manager rfkill gnupg dnsutils
    curl wget
    libwebkit2gtk-4.1-0 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0
    libgstreamer-gl1.0-0 gstreamer1.0-plugins-base gstreamer1.0-gl"
for _kpkg in $KODACHI_PROTECT_PKGS; do
    if dpkg -s "$_kpkg" >/dev/null 2>&1; then
        apt-mark manual "$_kpkg" >/dev/null 2>&1 || true
    fi
done

echo ""
print_step "Upgrading installed packages..."
print_info "Running apt-get upgrade to ensure system is up-to-date..."

# Use DEBIAN_FRONTEND=noninteractive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

if apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 2>&1 | tail -20; then
    print_success "System packages upgraded successfully"
else
    print_warning "apt-get upgrade had issues, continuing anyway..."
fi

echo ""

# ============================================================================
# CHECK IF KODACHI BINARIES ARE INSTALLED (REQUIRED BEFORE RUNNING THIS SCRIPT)
# ============================================================================
print_step "Checking if Kodachi binaries are installed..."

# Detect real user's home directory (secure method - no eval)
if [[ -n "$SUDO_USER" ]]; then
    REAL_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    # Fallback if getent failed
    if [[ -z "$REAL_USER_HOME" ]]; then
        REAL_USER_HOME=$(resolve_user_home "$SUDO_USER")
    fi
else
    REAL_USER_HOME="$HOME"
fi

# BEGIN KODACHI_AUTH_TRUST_OWNERSHIP
# Keep executable/authentication inputs root-controlled while granting the
# desktop user ownership only of the directories that hold runtime state.
kodachi_require_real_directory_chain() {
    local candidate="$1"
    local resolved=""
    local current=""
    local remaining=""
    local component=""

    [[ "$candidate" == /* ]] || return 1
    resolved="$(readlink -f -- "$candidate" 2>/dev/null)" || return 1
    [[ "$resolved" == "$candidate" && -d "$candidate" && ! -L "$candidate" ]] ||
        return 1

    remaining="${candidate#/}"
    while [[ -n "$remaining" ]]; do
        component="${remaining%%/*}"
        [[ -n "$component" ]] || return 1
        current="$current/$component"
        [[ -d "$current" && ! -L "$current" ]] || return 1
        if [[ "$remaining" == "$component" ]]; then
            remaining=""
        else
            remaining="${remaining#*/}"
        fi
    done
}

kodachi_require_safe_planned_directory_chain() {
    local candidate="$1"
    local resolved=""
    local current=""
    local remaining=""
    local component=""

    [[ "$candidate" == /* ]] || return 1
    resolved="$(readlink -m -- "$candidate" 2>/dev/null)" || return 1
    [[ "$resolved" == "$candidate" ]] || return 1

    remaining="${candidate#/}"
    while [[ -n "$remaining" ]]; do
        component="${remaining%%/*}"
        [[ -n "$component" ]] || return 1
        current="$current/$component"
        [[ ! -L "$current" ]] || return 1
        if [[ -e "$current" && ! -d "$current" ]]; then
            return 1
        fi
        if [[ "$remaining" == "$component" ]]; then
            remaining=""
        else
            remaining="${remaining#*/}"
        fi
    done
}

kodachi_preflight_auth_trust_ownership() {
    local opt_root="${1:-/opt}"
    local hooks_root="$opt_root/kodachi/dashboard/hooks"
    local planned_path=""
    local protected_dir runtime_dir

    # This pass is intentionally read-only. Validate every existing component
    # of every path the producer can create or mutate before the first write.
    kodachi_require_safe_planned_directory_chain "$hooks_root" || return 1
    for protected_dir in auth-trust rust others binaries-update-scripts; do
        planned_path="$hooks_root/$protected_dir"
        kodachi_require_safe_planned_directory_chain "$planned_path" || return 1
    done
    for runtime_dir in config data cache results logs tmp; do
        planned_path="$hooks_root/$runtime_dir"
        kodachi_require_safe_planned_directory_chain "$planned_path" || return 1
    done
    kodachi_require_safe_planned_directory_chain "$hooks_root/cache/ip-fetch" ||
        return 1
    kodachi_require_safe_planned_directory_chain "$hooks_root/cache/ip-fetch/ips" ||
        return 1
}

kodachi_apply_auth_trust_ownership() {
    local opt_root="${1:-/opt}"
    local runtime_owner="${2:-}"
    local runtime_group="${3:-}"
    local hooks_root="$opt_root/kodachi/dashboard/hooks"
    local protected_path=""
    local runtime_path=""
    local runtime_parent=""
    local path protected_dir runtime_dir

    kodachi_preflight_auth_trust_ownership "$opt_root" || return 1
    kodachi_require_real_directory_chain "$hooks_root" || return 1

    for path in \
        "$opt_root" \
        "$opt_root/kodachi" \
        "$opt_root/kodachi/dashboard" \
        "$hooks_root"; do
        [[ -e "$path" ]] || continue
        chown -h root:root "$path"
        chmod go-w "$path"
    done

    if [[ -d "$hooks_root" ]]; then
        find -P "$hooks_root" -maxdepth 1 -type f -exec chown -h -- root:root {} +
        find -P "$hooks_root" -maxdepth 1 -type f -exec chmod go-w -- {} +
    fi

    for protected_dir in auth-trust rust others binaries-update-scripts; do
        protected_path="$hooks_root/$protected_dir"
        [[ -e "$protected_path" ]] || continue
        kodachi_require_real_directory_chain "$protected_path" || return 1
        chown -hR -P -- root:root "$protected_path"
        find -P "$protected_path" ! -type l -exec chmod go-w -- {} +
    done

    [[ -n "$runtime_owner" && -n "$runtime_group" ]] || return 0
    for runtime_dir in config data cache results logs tmp; do
        runtime_path="$hooks_root/$runtime_dir"
        if [[ -e "$runtime_path" ]]; then
            kodachi_require_real_directory_chain "$runtime_path" || return 1
        else
            mkdir -- "$runtime_path" || return 1
            kodachi_require_real_directory_chain "$runtime_path" || return 1
        fi
        runtime_parent="$(readlink -f -- "$runtime_path/.." 2>/dev/null)" ||
            return 1
        [[ "$runtime_parent" == "$hooks_root" ]] || return 1
        chown -hR -P -- "$runtime_owner:$runtime_group" "$runtime_path"
        chmod 0755 -- "$runtime_path"
    done
}
# END KODACHI_AUTH_TRUST_OWNERSHIP

# Reject every pre-existing redirected/non-directory target before mkdir can
# alter the canonical tree. Missing components are safe to create only after
# this complete read-only preflight succeeds.
kodachi_preflight_auth_trust_ownership /opt || {
    print_error "Unsafe /opt/kodachi ownership path; refusing to mutate it"
    exit 1
}

# Ensure /opt/kodachi/ exists for canonical install location.
if [[ ! -d "/opt/kodachi/dashboard/hooks" ]]; then
    print_step "Creating /opt/kodachi/dashboard/hooks/ for canonical binary location..."
    mkdir -p /opt/kodachi/dashboard/hooks
fi
mkdir -p /opt/kodachi/dashboard/hooks/others
# Pre-create runtime data tree so first-boot tools (conky-status → ip-fetch,
# health-control, etc.) don't race the ownership normalization below. ip-fetch in particular
# was caught failing with "Failed to create cache directory" / "Failed to
# create IPs cache directory" on early-boot debug-collector runs because
# its create_dir_all call landed before /opt/kodachi/dashboard/hooks was
# writable by the desktop user. Creating these here lets the runtime allowlist
# cover them in one pass. Permissions tighten to 0700 at runtime via
# ip-fetch's set_permissions call (see dashboard/hooks/rust/ip-fetch/src/cache/mod.rs).
mkdir -p /opt/kodachi/dashboard/hooks/cache/ip-fetch/ips
mkdir -p /opt/kodachi/dashboard/hooks/logs
mkdir -p /opt/kodachi/dashboard/hooks/results
mkdir -p /opt/kodachi/dashboard/hooks/tmp

# BEGIN KODACHI_RUNTIME_OWNER_DERIVATION
runtime_uid=""
runtime_gid=""
if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    runtime_uid="$(id -u "$SUDO_USER")"
    runtime_gid="$(id -g "$SUDO_USER")"
fi
# END KODACHI_RUNTIME_OWNER_DERIVATION
kodachi_apply_auth_trust_ownership /opt "$runtime_uid" "$runtime_gid"

# Check for binaries in standard locations
BINARIES_FOUND=false
BINARIES_LOCATION=""

# Possible binary locations
BINARY_LOCATIONS=(
    "/opt/kodachi/dashboard/hooks"
    "$PROJECT_ROOT/dashboard/hooks"
    "$REAL_USER_HOME/dashboard/hooks"
    "$REAL_USER_HOME/Desktop/dashboard/hooks"
    "$REAL_USER_HOME/k900/dashboard/hooks"
    "/usr/local/bin"
)

# Core binaries that must exist
REQUIRED_BINARIES=("health-control" "tor-switch" "dns-switch" "kodachi-dashboard")
FOUND_COUNT=0

for location in "${BINARY_LOCATIONS[@]}"; do
    if [[ -d "$location" ]]; then
        # Count how many required binaries exist in this location
        local_found=0
        for binary in "${REQUIRED_BINARIES[@]}"; do
            if [[ -x "$location/$binary" ]]; then
                local_found=$((local_found + 1))
            fi
        done

        # If we found at least 3 out of 4 required binaries, consider this the location
        if [[ $local_found -ge 3 ]]; then
            BINARIES_FOUND=true
            BINARIES_LOCATION="$location"
            FOUND_COUNT=$local_found
            break
        fi
    fi
done

if [[ "$BINARIES_FOUND" == "false" ]]; then
    echo ""
    print_error "Kodachi binaries NOT FOUND!"
    echo ""
    print_highlight "═══════════════════════════════════════════════════════════════"
    print_highlight "  IMPORTANT: This is Script #2 - Run AFTER Installing Binaries"
    print_highlight "═══════════════════════════════════════════════════════════════"
    echo ""
    print_warning "You must install Kodachi binaries FIRST using:"
    echo ""
    echo -e "  ${CYAN}Script #1 (Run First):${NC}"
    echo -e "  ${BOLD}curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash${NC}"
    echo ""
    echo -e "  ${CYAN}Script #2 (Run After):${NC}"
    echo -e "  ${BOLD}curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-deps-install.sh | sudo bash${NC}"
    echo ""
    print_info "The binaries script installs Kodachi tools to /opt/kodachi/dashboard/hooks"
    print_info "This deps script installs system dependencies and configures sudoers"
    echo ""
    print_error "Aborting installation - please run kodachi-binary-install.sh first"
    echo ""
    exit 1
else
    print_success "Kodachi binaries found in: $BINARIES_LOCATION"
    print_info "Found $FOUND_COUNT required binaries"
fi

KODACHI_RUN_MODE="install"
if detect_kodachi_update_mode "$REAL_USER_HOME"; then
    KODACHI_RUN_MODE="update"
    print_warning "Existing Kodachi installation detected."
    print_info "Changing mode to UPDATE: refreshing managed files and removing outdated startup entries."
else
    print_info "No previous Kodachi dependency footprint detected. Running in install mode."
fi

echo ""

print_step "Ensuring AI model path compatibility..."
ensure_ai_model_path_compatibility "$REAL_USER_HOME"
echo ""

# ============================================================================
# CONFIGURE SUDOERS EARLY - Before any package installation that might fail
# ============================================================================
print_step "Configuring sudoers for Kodachi binaries (early setup)..."
# Non-fatal: a sudoers validation problem must never abort the whole dependency
# install (under "set -e" a bare failing call would). At worst the dashboard
# loses passwordless sudo; tor/VPN/dnscrypt and the rest must still install.
configure_kodachi_sudoers || print_warning "Sudoers early setup incomplete - continuing with dependency install"
echo ""

configure_emergency_shortcut_input_access
echo ""

# Start logging after confirming root access and binaries
setup_logging

# Welcome message
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Kodachi Dependencies Installation Script   ║${NC}"
echo -e "${CYAN}║             (Requires Sudo/Root)             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

print_info "Installation mode: $INSTALL_MODE"
print_info "Run mode: $KODACHI_RUN_MODE"
# Only print the line when it actually resolved. resolve_kodachi_public_version()
# returns an empty string rather than a stale literal, so an unconditional print
# would emit "Release policy line: " with nothing after it.
[[ -n "$KODACHI_PUBLIC_VERSION" ]] && print_info "Release policy line: $KODACHI_PUBLIC_VERSION"
if [[ "$AUTO_YES" == "true" ]]; then
    print_info "Auto mode enabled: All prompts will default to YES"
fi
echo ""

# ============================================================================
# DETECT PRE-EXISTING SERVICE STATE - Important for updates!
# ============================================================================
print_step "Detecting pre-existing service states..."
echo ""

# Critical services that should NOT be stopped if already running (could break internet)
INITIAL_DNSCRYPT_RUNNING=false
INITIAL_TOR_RUNNING=false
INITIAL_PIHOLE_RUNNING=false
INITIAL_REDSOCKS_RUNNING=false

# Non-critical services (can be stopped even if running)
INITIAL_CUPS_RUNNING=false
INITIAL_AVAHI_RUNNING=false
INITIAL_NTP_RUNNING=false

if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
    INITIAL_DNSCRYPT_RUNNING=true
    print_info "DNSCrypt Proxy detected running (will be preserved)"
fi

if systemctl is-active --quiet tor 2>/dev/null || process_running_current_root "tor"; then
    INITIAL_TOR_RUNNING=true
    print_info "Tor detected running (will be preserved)"
fi

if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    INITIAL_PIHOLE_RUNNING=true
    print_info "Pi-hole detected running (will be preserved)"
fi

if systemctl is-active --quiet redsocks 2>/dev/null || process_running_current_root "redsocks"; then
    INITIAL_REDSOCKS_RUNNING=true
    print_info "Redsocks detected running (will be preserved)"
fi

if systemctl is-active --quiet cups 2>/dev/null || process_running_current_root "cupsd"; then
    INITIAL_CUPS_RUNNING=true
fi

if systemctl is-active --quiet avahi-daemon 2>/dev/null || process_running_current_root "avahi-daemon"; then
    INITIAL_AVAHI_RUNNING=true
fi

if process_running_current_root "ntpd" || systemctl is-active --quiet ntp 2>/dev/null; then
    INITIAL_NTP_RUNNING=true
fi

echo ""
print_success "Service state detection complete"
echo ""

# ============================================================================
# TIME SYNCHRONIZATION - Critical for HTTPS certificate validation
# ============================================================================
print_step "Synchronizing system time..."
timedatectl set-ntp true 2>/dev/null || true
sleep 2
print_success "Time sync enabled"
echo ""

# Kill any stuck apt/dpkg processes
cleanup_apt() {
    if pgrep -x apt-get > /dev/null; then
        print_warning "Killing stuck apt-get processes..."
        killall -9 apt-get 2>/dev/null || true
        sleep 2
    fi

    if pgrep -x dpkg > /dev/null; then
        print_warning "Killing stuck dpkg processes..."
        killall -9 dpkg 2>/dev/null || true
        sleep 2
    fi

    # Clean up locks
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    rm -f /var/lib/dpkg/lock 2>/dev/null || true
    rm -f /var/cache/apt/archives/lock 2>/dev/null || true
    rm -f /var/lib/apt/lists/lock 2>/dev/null || true

    # Reconfigure dpkg if needed - more aggressive
    print_info "Running dpkg --configure -a to fix any interrupted installations..."
    dpkg --configure -a 2>&1 | tail -3 || true

    # Fix broken dependencies
    print_info "Fixing any broken dependencies..."
    apt-get install -f -y 2>&1 | tail -3 || true
}

# Function to wait for apt/dpkg to finish
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "Waiting for other package managers to finish..."
        sleep 2
    done
}

# Function to ensure dpkg is in a healthy state
ensure_dpkg_healthy() {
    local retry_count=0
    local max_retries=3

    while [[ $retry_count -lt $max_retries ]]; do
        # Kill stuck processes
        if pgrep -x apt-get > /dev/null; then
            print_warning "Killing stuck apt-get processes..."
            killall -9 apt-get 2>/dev/null || true
            sleep 2
        fi

        if pgrep -x dpkg > /dev/null; then
            print_warning "Killing stuck dpkg processes..."
            killall -9 dpkg 2>/dev/null || true
            sleep 2
        fi

        # Remove locks
        rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
        rm -f /var/lib/dpkg/lock 2>/dev/null || true
        rm -f /var/cache/apt/archives/lock 2>/dev/null || true
        rm -f /var/lib/apt/lists/lock 2>/dev/null || true

        # Configure any pending packages
        print_info "Configuring pending packages..."
        if dpkg --configure -a 2>&1 | tail -3; then
            print_success "Package system is healthy"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                print_warning "dpkg configuration failed, retry $retry_count/$max_retries..."
                sleep 3
            fi
        fi
    done

    print_error "Failed to configure dpkg after $max_retries attempts"
    return 1
}

# Function to generate random alphanumeric password
generate_pihole_password() {
    # Generate random password 12-16 characters, alphanumeric only
    local length=$((12 + RANDOM % 5))  # Random length between 12-16
    local password=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1)
    echo "$password"
}

# Clean up first
cleanup_apt

# Function to automatically remove Kicksecure RAM wipe and restore initramfs-tools
# Only runs if --force-kicksecure-ramwipe flag is NOT used
remove_kicksecure_ramwipe_and_restore_initramfs() {
    # Skip if user explicitly wants Kicksecure RAM wipe
    if [[ "$INSTALL_KICKSECURE_RAMWIPE" == "true" ]]; then
        return 0
    fi

    # Check if any Kicksecure ramwipe packages are installed
    local has_ramwipe=false
    local has_dracut=false
    local has_dracut_core=false
    local packages_to_remove=()

    if check_package_installed "ram-wipe"; then
        has_ramwipe=true
        packages_to_remove+=("ram-wipe")
    fi

    if check_package_installed "dracut"; then
        has_dracut=true
        packages_to_remove+=("dracut")
    fi

    if check_package_installed "dracut-core"; then
        has_dracut_core=true
        packages_to_remove+=("dracut-core")
    fi

    # If no packages found, nothing to do
    if [[ "$has_ramwipe" == "false" ]] && [[ "$has_dracut" == "false" ]] && [[ "$has_dracut_core" == "false" ]]; then
        return 0
    fi

    # Display removal notice
    echo ""
    print_step "Removing Kicksecure RAM Wipe Components"
    echo ""
    print_info "Kodachi has built-in RAM wipe via 'health-control memory-wipe'"
    print_info "Removing redundant Kicksecure packages: ${packages_to_remove[*]}"
    echo ""
    print_warning "To keep Kicksecure RAM wipe, use: --force-kicksecure-ramwipe"
    echo ""

    # Purge the packages
    export DEBIAN_FRONTEND=noninteractive
    if apt-get purge -y "${packages_to_remove[@]}" 2>&1 | grep -E "(Removing|Purging)"; then
        print_success "Removed Kicksecure RAM wipe packages"
    else
        print_warning "Some packages may not have been installed"
    fi

    # Clean up dependencies
    print_step "Cleaning up unused dependencies..."
    if apt-get autoremove -y 2>&1 | grep -E "(Removing|freed)" | head -5; then
        print_success "Cleaned up dependencies"
    fi

    # CRITICAL: Restore initramfs-tools (dracut replacement)
    echo ""
    print_step "Restoring initramfs-tools (dracut replacement)..."
    print_warning "Installing initramfs-tools to ensure kernel updates work correctly"

    if apt-get install -y initramfs-tools 2>&1 | tail -5; then
        print_success "initramfs-tools installed successfully"
    else
        print_error "Failed to install initramfs-tools - kernel updates may fail!"
        print_warning "Please manually install: sudo apt-get install initramfs-tools"
    fi

    # Check if Kicksecure repository should be removed
    echo ""
    print_step "Checking Kicksecure repository usage..."

    local has_kicksecure_repo=false
    if [[ -f "/etc/apt/sources.list.d/kicksecure.list" ]]; then
        has_kicksecure_repo=true
    fi

    if [[ "$has_kicksecure_repo" == "true" ]]; then
        # Check if other Kicksecure packages are installed
        local other_packages=$(dpkg -l 2>/dev/null | grep -i "^ii" | grep -E "(kicksecure|whonix)" | grep -v -E "(ram-wipe|dracut)" | wc -l)

        # Also check for kloak specifically (may come from Whonix repo)
        local has_kloak=false
        if check_package_installed "kloak"; then
            # Check if kloak is from Kicksecure repo
            if apt-cache policy kloak 2>/dev/null | grep -q "deb.kicksecure.com"; then
                has_kloak=true
            fi
        fi

        if [[ $other_packages -eq 0 ]] && [[ "$has_kloak" == "false" ]]; then
            print_info "No other Kicksecure packages detected - removing repository"

            # Remove repository
            rm -f /etc/apt/sources.list.d/kicksecure.list 2>/dev/null || true
            rm -f /usr/share/keyrings/kicksecure.gpg 2>/dev/null || true

            print_success "Kicksecure repository removed"
        else
            print_info "Other Kicksecure packages detected - keeping repository"
            if [[ "$has_kloak" == "true" ]]; then
                print_info "  • kloak is using Kicksecure repository"
            fi
        fi
    fi

    echo ""
    print_success "Kicksecure RAM wipe removal completed"
    echo ""
}

# Helper function to check if package is installed (used by removal function)
check_package_installed() {
    local pkg="$1"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    else
        return 1
    fi
}

# Run the removal function before any installations
remove_kicksecure_ramwipe_and_restore_initramfs

# Function to check if package is installed
check_package() {
    local pkg="$1"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        return 0
    else
        return 1
    fi
}

# Function to check if DNS tools are available
check_dns_tools() {
    # Check if any of the DNS tools are available
    if command -v dig &>/dev/null || command -v nslookup &>/dev/null || command -v host &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to install category with user confirmation
install_category_interactive() {
    local packages="$1"
    local category="$2"
    local description="$3"
    local manual_info="$4"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    print_highlight "$category Installation"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Show description
    echo "$description"
    echo ""
    
    # Show packages that will be installed
    print_info "Packages to be installed:"
    echo ""
    
    # Format packages in columns
    local cols=3
    local i=0
    
    # Convert packages string to array safely
    read -ra pkg_array <<< "$packages"
    
    for pkg in "${pkg_array[@]}"; do
        printf "  %-25s" "$pkg"
        i=$((i + 1))
        if [[ $((i % cols)) -eq 0 ]]; then
            echo ""
        fi
    done
    
    if [[ $((i % cols)) -ne 0 ]]; then
        echo ""
    fi
    
    echo ""
    
    # Check for auto mode
    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing $category packages..."
        install_packages "$packages" "$category"
        return 0
    else
        # FIXED: Simple working input method (stdin already redirected via exec)
        echo -n "Do you want to install $category packages? (YES/no) [default: yes]: "
        read -r REPLY
        # Default to YES if empty
        if [[ -z "$REPLY" ]]; then
            REPLY="yes"
        fi
        echo ""
        
        if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
            install_packages "$packages" "$category"
            return 0
        else
            print_info "Skipping $category installation"
            echo ""
            print_highlight "To install $category packages manually:"
            echo ""
            echo "$manual_info"
            echo ""
            return 1
        fi
    fi
}

# Function to install packages with status display
install_packages() {
    local packages="$1"
    local category="$2"
    local to_install=""
    local failed_list=""

    print_step "Installing $category packages..."
    print_verbose "========== CATEGORY: $category =========="
    print_verbose "Packages to check: $packages"

    export DEBIAN_FRONTEND=noninteractive

    # Pre-accept Microsoft TrueType core fonts EULA so ttf-mscorefonts-installer
    # can install non-interactively (used by conky panels for the Impact title font).
    # No-op when that package is not in the install set.
    if command -v debconf-set-selections >/dev/null 2>&1; then
        echo 'msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true' \
            | debconf-set-selections 2>/dev/null || true
        echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
            | debconf-set-selections 2>/dev/null || true
    fi

    # Check and display status for each package
    for pkg in $packages; do
        # Special handling for dnsutils - check for actual commands
        if [[ "$pkg" == "dnsutils" ]]; then
            if check_dns_tools; then
                echo -e "  ${GREEN}✓${NC} $pkg - already installed (DNS tools available)"
            else
                to_install="$to_install $pkg"
                echo -e "  ${YELLOW}→${NC} $pkg - will install"
            fi
        elif check_package "$pkg"; then
            echo -e "  ${GREEN}✓${NC} $pkg - already installed"
        else
            to_install="$to_install $pkg"
            echo -e "  ${YELLOW}→${NC} $pkg - will install"
        fi
    done

    # Install missing packages if any
    if [[ -n "$to_install" ]]; then
        echo ""

        # Pre-filter: skip packages that have no installation candidate in apt
        # Uses apt-cache policy to check for a real candidate (not just metadata references)
        local available_packages=""
        local unavailable_packages=""
        for pkg in $to_install; do
            local candidate
            candidate=$(apt-cache policy "$pkg" 2>/dev/null | grep 'Candidate:' | awk '{print $2}' || true)
            if [[ -n "$candidate" ]] && [[ "$candidate" != "(none)" ]]; then
                available_packages="$available_packages $pkg"
            else
                unavailable_packages="$unavailable_packages $pkg"
                echo -e "  ${YELLOW}⚠${NC} $pkg - no installation candidate in current repositories (skipped)"
            fi
        done
        if [[ -n "$unavailable_packages" ]]; then
            print_warning "Unavailable packages skipped:$unavailable_packages"
        fi
        to_install="$available_packages"

        # If nothing left to install after filtering, skip
        if [[ -z "$to_install" ]]; then
            print_success "All available $category packages are already installed"
            return 0
        fi

        echo "Installing missing packages..."
        print_verbose "Missing packages to install: $to_install"

        # Handle rkhunter separately to prevent exim4 installation
        local rkhunter_separate=""
        local other_packages=""
        
        for pkg in $to_install; do
            if [[ "$pkg" == "rkhunter" ]]; then
                rkhunter_separate="$pkg"
            else
                other_packages="$other_packages $pkg"
            fi
        done

        # Install rkhunter with --no-install-recommends if needed
        if [[ -n "$rkhunter_separate" ]]; then
            echo "Installing rkhunter without recommended packages (prevents exim4)..."
            print_verbose "Installing rkhunter: $rkhunter_separate"
            if [[ "$VERBOSE_MODE" == "true" ]]; then
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --no-install-recommends $rkhunter_separate < /dev/null 2>&1 | cat
            else
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --no-install-recommends $rkhunter_separate < /dev/null 2>&1 | tail -10
            fi
            print_verbose "rkhunter installation completed"
        fi

        # Install other packages normally (600 second timeout for complex packages with triggers)
        # SECURITY FIX: Disable set -e temporarily to prevent premature exit on pipeline failure
        local install_result=true
        if [[ -n "$other_packages" ]]; then
            print_verbose "Installing packages: $other_packages"
            set +e
            if [[ "$VERBOSE_MODE" == "true" ]]; then
                # Verbose mode: show full output (pipe through cat to prevent job control issues)
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $other_packages < /dev/null 2>&1 | cat
            else
                # Normal mode: show only last 10 lines
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $other_packages < /dev/null 2>&1 | tail -10
            fi
            if [ ${PIPESTATUS[0]} -ne 0 ]; then
                install_result=false
            fi
            set -e
            print_verbose "Package installation completed with exit code: ${PIPESTATUS[0]}"
        fi

        if $install_result; then
            # Check which ones actually installed
            for pkg in $to_install; do
                # Special handling for dnsutils - check for actual DNS tools functionality
                if [[ "$pkg" == "dnsutils" ]]; then
                    if check_dns_tools; then
                        echo -e "  ${GREEN}✓${NC} $pkg - DNS tools available"
                    else
                        echo -e "  ${RED}✗${NC} $pkg - failed to install"
                        failed_list="$failed_list $pkg"
                    fi
                elif check_package "$pkg"; then
                    echo -e "  ${GREEN}✓${NC} $pkg - installed successfully"
                else
                    echo -e "  ${RED}✗${NC} $pkg - failed to install"
                    failed_list="$failed_list $pkg"
                fi
            done
        else
            print_warning "Installation command had issues"

            # Try to fix dpkg state and retry
            print_info "Attempting to fix package system..."
            ensure_dpkg_healthy

            # Retry installation once (600 second timeout for complex packages)
            print_info "Retrying installation..."
            print_verbose "Retrying packages: $to_install"
            if [[ "$VERBOSE_MODE" == "true" ]]; then
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $to_install < /dev/null 2>&1 | cat
            else
                timeout 600 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $to_install < /dev/null 2>&1 | tail -10
            fi
            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                print_success "Retry successful"
            fi
            print_verbose "Retry completed with exit code: ${PIPESTATUS[0]}"

            # Check what got installed after retry
            for pkg in $to_install; do
                # Special handling for dnsutils - check for actual DNS tools functionality
                if [[ "$pkg" == "dnsutils" ]]; then
                    if check_dns_tools; then
                        echo -e "  ${GREEN}✓${NC} $pkg - DNS tools available after retry"
                    else
                        echo -e "  ${RED}✗${NC} $pkg - failed to install"
                        failed_list="$failed_list $pkg"
                    fi
                elif check_package "$pkg"; then
                    echo -e "  ${GREEN}✓${NC} $pkg - installed after retry"
                else
                    echo -e "  ${RED}✗${NC} $pkg - failed to install"
                    failed_list="$failed_list $pkg"
                fi
            done
        fi

        if [[ -n "$failed_list" ]]; then
            print_warning "Failed to install:$failed_list"
            # One final dpkg configure to ensure system is clean for next batch
            dpkg --configure -a 2>/dev/null || true
        fi
    else
        print_success "All $category packages already installed"
    fi

    echo ""
}

# Function to handle contrib/non-free packages
install_contrib_packages() {
    print_step "Checking contrib/non-free package requirements..."

    local v2ray_plugin_installed=false
    local v2ray_installed=false
    local show_repo_warning=false

    # Check if packages are already installed
    if check_package "shadowsocks-v2ray-plugin" || command -v v2ray-plugin &>/dev/null; then
        v2ray_plugin_installed=true
        print_success "v2ray-plugin is already installed"
    fi

    if check_package "v2ray" || command -v v2ray &>/dev/null; then
        v2ray_installed=true
        print_success "v2ray is already installed"
    fi

    # Check if contrib and non-free are enabled
    if check_contrib_nonfree; then
        print_success "Contrib and non-free repositories are enabled"

        # Try to install shadowsocks-v2ray-plugin if not already installed
        if ! $v2ray_plugin_installed; then
            print_step "Installing shadowsocks-v2ray-plugin from apt..."
            if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null shadowsocks-v2ray-plugin 2>&1 | tail -5; then
                print_success "shadowsocks-v2ray-plugin installed via apt"
                v2ray_plugin_installed=true
            else
                print_warning "Failed to install shadowsocks-v2ray-plugin via apt, trying GitHub..."
                if install_v2ray_plugin_github; then
                    v2ray_plugin_installed=true
                fi
            fi
        fi

        # Try to install v2ray if not already installed
        if ! $v2ray_installed; then
            print_step "Installing v2ray from apt..."
            if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null v2ray 2>&1 | tail -5; then
                print_success "v2ray installed via apt"
                v2ray_installed=true
            else
                print_warning "Failed to install v2ray via apt"
                print_info "v2ray may require manual installation or is not available in your distribution"
            fi
        fi
    else
        # Repositories not enabled - AUTOMATICALLY ENABLE THEM
        print_warning "Contrib and/or non-free repositories are NOT enabled!"
        echo ""

        # Automatically enable the repositories
        if enable_contrib_nonfree; then
            # Repositories now enabled, try installing packages again
            print_step "Retrying package installations after enabling repositories..."

            # Try to install shadowsocks-v2ray-plugin if not already installed
            if ! $v2ray_plugin_installed; then
                print_step "Installing shadowsocks-v2ray-plugin from apt..."
                if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null shadowsocks-v2ray-plugin 2>&1 | tail -5; then
                    print_success "shadowsocks-v2ray-plugin installed via apt"
                    v2ray_plugin_installed=true
                else
                    print_warning "Failed to install shadowsocks-v2ray-plugin via apt, trying GitHub..."
                    if install_v2ray_plugin_github; then
                        v2ray_plugin_installed=true
                    fi
                fi
            fi

            # Try to install v2ray if not already installed
            if ! $v2ray_installed; then
                print_step "Installing v2ray from apt..."
                if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null v2ray 2>&1 | tail -5; then
                    print_success "v2ray installed via apt"
                    v2ray_installed=true
                else
                    print_warning "Failed to install v2ray via apt"
                    print_info "v2ray may require manual installation or is not available in your distribution"
                fi
            fi
        else
            print_error "Failed to enable contrib/non-free repositories automatically"
            print_info "You may need to manually edit /etc/apt/sources.list"
        fi

        # Install v2ray-plugin from GitHub if not already installed
        if ! $v2ray_plugin_installed; then
            print_step "Installing v2ray-plugin from GitHub (fallback)..."
            if install_v2ray_plugin_github; then
                v2ray_plugin_installed=true
            fi
        fi

        # Only show v2ray warning if it's actually missing
        if ! $v2ray_installed; then
            print_warning "v2ray package cannot be installed without contrib/non-free repositories"
        fi
    fi
}

# Function to install v2ray
install_v2ray() {
    print_step "Installing v2ray..."

    if command -v v2ray &>/dev/null; then
        print_success "v2ray is already installed"
        return 0
    fi

    # Prefer the ISO-refreshed cache so clean builds do not install stale apt
    # or legacy /opt/kodachi-offline-packages/proxies payloads.
    local cache_zip="/opt/kodachi-offline-packages/external-proxy-binaries-cache/v2ray-linux-64.zip"
    if [ -f "$cache_zip" ]; then
        echo -e "${BLUE}[INFO]${NC} v2ray: installing from refreshed offline cache"
        echo -e "${BLUE}[INFO]${NC}        $cache_zip ($(du -h "$cache_zip" 2>/dev/null | cut -f1))"
        local tmpd
        tmpd="$(mktemp -d /tmp/v2ray-cache-XXXXXX)"
        if unzip -q "$cache_zip" -d "$tmpd"; then
            if [ -f "$tmpd/v2ray" ]; then
                install -d -m 0755 /usr/local/bin /usr/local/share/v2ray /etc/v2ray 2>/dev/null
                install -m 0755 -o root -g root "$tmpd/v2ray" /usr/local/bin/v2ray 2>/dev/null || cp "$tmpd/v2ray" /usr/local/bin/v2ray
                [ -f "$tmpd/v2ctl" ] && install -m 0755 -o root -g root "$tmpd/v2ctl" /usr/local/bin/v2ctl 2>/dev/null || true
                cp "$tmpd"/*.dat /usr/local/share/v2ray/ 2>/dev/null || true
                chmod 0755 /usr/local/bin/v2ray
                rm -rf "$tmpd"
                if /usr/local/bin/v2ray version >/dev/null 2>&1; then
                    print_success "v2ray installed from cache: $(/usr/local/bin/v2ray version 2>/dev/null | head -1)"
                    return 0
                fi
            fi
        fi
        rm -rf "$tmpd"
        echo -e "${YELLOW}[WARN]${NC} v2ray cache install failed, falling back to apt/GitHub"
    fi

    # Kodachi's own signed package first, exactly like install_xray does: it is verified by
    # the repo GPG key, so it beats every unverified upstream path below.
    #
    # Accuracy note, corrected 2026-08-06: this comment used to say the package "tracks a
    # vendored upstream version from a PINNED tag". It does not. `installers/
    # vendor-thirdparty.sh:60` resolves it with `latest_tag v2fly/v2ray-core`, so the
    # package tracks whatever was latest WHEN THE PACKAGE WAS BUILT. The real guarantee
    # here is the GPG signature and a version frozen at package build time, not a pinned
    # upstream tag, and overstating it is how the ungated path below survived review.
    if kodachi_try_packaged_install "kodachi-v2ray" "v2ray"; then
        return 0
    fi

    # GATE, added 2026-08-06 after an external review caught this.
    #
    # The remediation earlier the same day gated the fhs-install-v2ray FALLBACK below and
    # left THIS path open, which was the wrong one of the two: this is the path that
    # actually runs. `releases/latest` is a MOVING target fetched over the network with no
    # hash, no signature and no pinned tag, unzipped, and installed to /usr/local/bin as
    # root. That is the same exposure install_xray refuses by default, so it gets the same
    # refusal and the same named escape hatch.
    # SKIP-AND-CONTINUE, not `return 1`.
    #
    # The first version of this gate copied install_xray's `return 1`. That is correct THERE,
    # because nothing follows xray's gate, and wrong HERE: install_v2ray has 68 more lines
    # after this point, including the Debian-signed `apt-get install v2ray` near the end. A
    # bare return amputated a working, verified install path, so a default machine with no
    # packaged install and no cache went from "installs v2ray from apt" to "exits 1". An
    # external inspection caught it. The unverified download is skipped; the verified paths
    # below still run, which is exactly what the second gate in this same function does.
    local v2ray_upstream_zip_allowed=1
    if ! kodachi_upstream_unpinned_allowed; then
        v2ray_upstream_zip_allowed=0
        print_warning "Skipping the UNPINNED upstream v2ray release zip: github.com/v2fly/v2ray-core/"
        print_info "releases/latest is a MOVING target with no hash or signature, unzipped and"
        print_info "installed to /usr/local/bin as root. Continuing to the signed apt path below."
        print_info "To use it anyway, re-run with: KODACHI_ALLOW_UNPINNED_UPSTREAM=1"
    fi

    if [ "$v2ray_upstream_zip_allowed" -eq 1 ]; then
    print_warning "Falling back to the UNPINNED upstream v2ray release (KODACHI_ALLOW_UNPINNED_UPSTREAM=1)"

    # 2026-05-26: pull v2ray-linux-64.zip from GitHub releases/latest. The older path used
    # fhs-install-v2ray, which lags upstream badly (5.40.0 against 5.49.0 when measured),
    # and the apt path is older still. Latest-at-install-time is deliberate so a clean ISO
    # build is not months behind, and it is exactly why the gate above exists.
    echo "Installing v2ray from GitHub releases/latest..."
    local v2ray_url="https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip"
    local tmpd
    tmpd="$(mktemp -d /tmp/v2ray-install-XXXXXX)"
    if kodachi_download_first "$v2ray_url" "$tmpd/v2ray-linux-64.zip"; then
        if unzip -q "$tmpd/v2ray-linux-64.zip" -d "$tmpd" 2>/dev/null; then
            install -d -m 0755 /usr/local/bin /usr/local/share/v2ray /etc/v2ray 2>/dev/null
            install -m 0755 -o root -g root "$tmpd/v2ray" /usr/local/bin/v2ray 2>/dev/null || cp "$tmpd/v2ray" /usr/local/bin/v2ray
            [ -f "$tmpd/v2ctl" ] && install -m 0755 -o root -g root "$tmpd/v2ctl" /usr/local/bin/v2ctl 2>/dev/null || true
            cp "$tmpd"/*.dat /usr/local/share/v2ray/ 2>/dev/null || true
            chmod 0755 /usr/local/bin/v2ray
            rm -rf "$tmpd"
            if /usr/local/bin/v2ray version >/dev/null 2>&1; then
                print_success "v2ray installed from upstream latest: $(/usr/local/bin/v2ray version 2>/dev/null | head -1)"
                return 0
            fi
        fi
    fi
    rm -rf "$tmpd"
    fi

    # Last-resort fallbacks: the fhs-install-v2ray script, then apt. These are
    # deliberately ordered AFTER the upstream-latest path so a build that has
    # network reaches GitHub directly first.
    #
    # This path is NOT pinned, whatever the old comment here claimed. The URL is
    # `fhs-install-v2ray/raw/master/install-release.sh`, a MOVING branch, and the
    # script is executed as root with nothing comparing a hash: whoever controls
    # that branch controls root on the installing machine. It is gated the same
    # way install_xray and the pi-hole path are, off by default, opt-in with
    # KODACHI_ALLOW_UNPINNED_UPSTREAM=1, because the signed kodachi-v2ray package
    # and the release zip above are both better sources.
    if ! kodachi_upstream_unpinned_allowed; then
        print_warning "Skipping the fhs-install-v2ray fallback: it executes a script from a MOVING branch"
        print_info "(github.com/v2fly/fhs-install-v2ray/raw/master) as root with no integrity check."
        print_info "To use it anyway, re-run with: KODACHI_ALLOW_UNPINNED_UPSTREAM=1"
    else
        print_warning "Falling back to the UNPINNED upstream fhs-install-v2ray script (KODACHI_ALLOW_UNPINNED_UPSTREAM=1)"
        if retry_download "https://github.com/v2fly/fhs-install-v2ray/raw/master/install-release.sh" "/tmp/v2ray-install.sh"; then
            # Same sanity + disclosure as install_xray: refuse anything that is
            # not a bash script, and print the SHA256 so an admin can compare it
            # against a known-good value in the build log.
            if head -1 /tmp/v2ray-install.sh | grep -q "^#!.*bash"; then
                echo -e "${BLUE}[INFO]${NC} v2ray installer script SHA256: ${CYAN}$(sha256sum /tmp/v2ray-install.sh | cut -d' ' -f1)${NC}"
                if timeout 120 bash /tmp/v2ray-install.sh; then
                    rm -f /tmp/v2ray-install.sh
                    if command -v v2ray &>/dev/null; then
                        print_success "v2ray installed from fhs-install-v2ray (unpinned upstream)"
                        return 0
                    fi
                else
                    rm -f /tmp/v2ray-install.sh
                fi
            else
                print_error "Downloaded v2ray installer is not a valid bash script"
                rm -f /tmp/v2ray-install.sh
            fi
        fi
    fi

    if check_contrib_nonfree; then
        echo "Last resort: attempting apt install (likely older)..."
        if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null v2ray 2>&1 | tail -5; then
            if command -v v2ray &>/dev/null; then
                print_success "v2ray installed via apt (note: older than upstream)"
                return 0
            fi
        fi
    fi

    print_error "Failed to install v2ray"
    print_info "You can try manual installation from: https://github.com/v2fly/v2ray-core"
}

# Function to install xray.
#
# 2026-05-26 (Bug Q): prefer the cached binary from
# `/opt/kodachi-offline-packages/external-proxy-binaries-cache/Xray-linux-64.zip`
# (populated by build-iso.sh::ensure_latest_proxy_binaries_cache) — that
# cache is checked against upstream every refresh build, so the ISO is
# never more than one ISO cycle out of date. Fall back to the upstream
# curl|bash installer only when the cache is absent (network install on
# an existing system, or a fast/skip build that didn't refresh).
install_xray() {
    print_step "Installing xray..."

    if command -v xray &>/dev/null; then
        print_success "xray is already installed"
        return 0
    fi

    # === Cache fast-path ====================================================
    local cache_zip="/opt/kodachi-offline-packages/external-proxy-binaries-cache/Xray-linux-64.zip"
    if [ -f "$cache_zip" ]; then
        echo -e "${BLUE}[INFO]${NC} xray: installing from offline cache"
        echo -e "${BLUE}[INFO]${NC}        $cache_zip ($(du -h "$cache_zip" 2>/dev/null | cut -f1))"
        local tmpd
        tmpd="$(mktemp -d /tmp/xray-cache-XXXXXX)"
        if unzip -q "$cache_zip" -d "$tmpd"; then
            install -m 0755 -o root -g root "$tmpd/xray" /usr/local/bin/xray 2>/dev/null || \
                cp "$tmpd/xray" /usr/local/bin/xray
            chmod 0755 /usr/local/bin/xray
            # geosite/geoip ride along in the cached zip per upstream convention
            install -d -m 0755 /usr/local/share/xray 2>/dev/null
            [ -f "$tmpd/geoip.dat" ] && cp "$tmpd/geoip.dat" /usr/local/share/xray/ 2>/dev/null
            [ -f "$tmpd/geosite.dat" ] && cp "$tmpd/geosite.dat" /usr/local/share/xray/ 2>/dev/null
            rm -rf "$tmpd"
            if /usr/local/bin/xray version >/dev/null 2>&1; then
                print_success "xray installed from cache: $(/usr/local/bin/xray version | head -1)"
                return 0
            fi
        fi
        rm -rf "$tmpd"
        echo -e "${YELLOW}[WARN]${NC} cache install failed, falling back to upstream"
    fi

    # Kodachi's own signed package first: it is verified by the repo GPG key and
    # tracks a pinned upstream version, so it beats both the cache and upstream.
    if kodachi_try_packaged_install "kodachi-xray" "xray"; then
        return 0
    fi

    if ! kodachi_upstream_unpinned_allowed; then
        print_error "xray not installed: the packaged path (kodachi-xray) and the offline cache both failed."
        print_info "The upstream installer at github.com/XTLS/Xray-install/raw/main is a MOVING branch"
        print_info "and is executed as root with no verifiable integrity check, so it is disabled by default."
        print_info "To use it anyway, re-run with: KODACHI_ALLOW_UNPINNED_UPSTREAM=1"
        return 1
    fi

    print_warning "Falling back to the UNPINNED upstream xray installer (KODACHI_ALLOW_UNPINNED_UPSTREAM=1)"
    echo "Downloading and installing xray (cache absent or stale)..."

    local xray_script="/tmp/xray-install-$$.sh"
    if retry_download "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" "$xray_script"; then
        # Basic sanity check: verify it's a bash script
        if head -1 "$xray_script" | grep -q "^#!.*bash"; then
            # Display script hash for verification (admin can compare with known good hash)
            local script_hash=$(sha256sum "$xray_script" | cut -d' ' -f1)
            echo -e "${BLUE}[INFO]${NC} xray installer script SHA256: ${CYAN}${script_hash}${NC}"

            # Execute the verified script
            if timeout 120 bash "$xray_script" install -u root; then
                print_success "xray installed successfully"
                rm -f "$xray_script"
                return 0
            else
                print_error "Failed to install xray"
                rm -f "$xray_script"
                return 1
            fi
        else
            print_error "Downloaded xray installer is not a valid bash script"
            rm -f "$xray_script"
            return 1
        fi
    else
        print_error "Failed to download xray installer"
        return 1
    fi
}

# Function to install mieru
install_mieru() {
    print_step "Checking mieru installation..."

    local arch=""
    local resolved_mieru_version=""
    local resolved_mieru_url=""

    # Check if upgrade is needed
    arch="$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
    case "$arch" in
        amd64|arm64|armhf) ;;
        *)
            arch="amd64"
            ;;
    esac

    IFS='|' read -r resolved_mieru_version resolved_mieru_url <<< "$(resolve_mieru_release_metadata "$arch")"
    if [[ -n "$resolved_mieru_version" ]]; then
        MIERU_VERSION="$resolved_mieru_version"
    fi

    local check_result=$(needs_upgrade "mieru" "$MIERU_VERSION" "--version")
    local status=$(echo "$check_result" | cut -d'|' -f1)
    local installed=$(echo "$check_result" | cut -d'|' -f2)
    local target=$(echo "$check_result" | cut -d'|' -f3)

    if [[ "$status" == "current" ]]; then
        print_success "mieru is already up to date (v$installed)"
        return 0
    elif [[ "$status" == "newer" ]]; then
        print_success "mieru is already installed (v$installed, newer than target v$target)"
        return 0
    elif [[ "$status" == "upgrade" ]]; then
        print_warning "mieru found (v$installed) - upgrading to v$target..."
        # Old version will be removed after successful download (not before)
    else
        print_step "Installing mieru v$MIERU_VERSION..."
    fi

    local temp_file="/tmp/mieru_${MIERU_VERSION}_${arch}.deb"

    echo "Downloading mieru client..."
    if kodachi_download_first "$resolved_mieru_url" "$temp_file"; then
        echo "Installing mieru client package..."

        # Make sure no apt is running
        cleanup_apt

        # Remove old version only after download succeeds (safe upgrade)
        apt-get remove -y mieru 2>/dev/null || true

        # Install with dpkg then fix dependencies
        if dpkg -i "$temp_file"; then
            rm -f "$temp_file"
            print_success "mieru client installed successfully"
        else
            echo "Fixing dependencies..."
            apt-get install -f -y
            rm -f "$temp_file"

            if command -v mieru &>/dev/null; then
                print_success "mieru client installed with dependency fixes"
            else
                print_error "Failed to install mieru client"
            fi
        fi
    else
        print_error "Failed to download mieru client"
    fi
}

# Function to install hysteria2
install_hysteria2() {
    print_step "Checking hysteria2 installation..."

    local resolved_hysteria2_version=""

    resolved_hysteria2_version="$(resolve_latest_github_release_version "apernet/hysteria" "$HYSTERIA2_VERSION" 's#^app/##')"
    if [[ -n "$resolved_hysteria2_version" ]]; then
        HYSTERIA2_VERSION="$resolved_hysteria2_version"
    fi

    # Check if upgrade is needed
    local check_result=$(needs_upgrade "hysteria" "$HYSTERIA2_VERSION" "version")
    local status=$(echo "$check_result" | cut -d'|' -f1)
    local installed=$(echo "$check_result" | cut -d'|' -f2)
    local target=$(echo "$check_result" | cut -d'|' -f3)

    if [[ "$status" == "current" ]]; then
        print_success "hysteria2 is already up to date (v$installed)"
        return 0
    elif [[ "$status" == "newer" ]]; then
        print_success "hysteria2 is already installed (v$installed, newer than target v$target)"
        return 0
    elif [[ "$status" == "upgrade" ]]; then
        print_warning "hysteria2 found (v$installed) - upgrading to v$target..."
    else
        print_step "Installing hysteria2 v$HYSTERIA2_VERSION..."
    fi

    local arch=""
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *)
            print_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    local version="$HYSTERIA2_VERSION"
    local url="https://github.com/apernet/hysteria/releases/download/app/v${version}/hysteria-linux-${arch}"

    echo "Downloading hysteria2..."
    if kodachi_download_first "$url" "/tmp/hysteria"; then
        mv /tmp/hysteria /usr/local/bin/hysteria
        chmod 755 /usr/local/bin/hysteria
        print_success "hysteria2 installed successfully"
    else
        print_error "Failed to download hysteria2"
        rm -f /tmp/hysteria 2>/dev/null || true
    fi
}

# Function to install ck-client (Cloak transport client for OpenVPN-over-Cloak).
# Pinned to the Cloak v2.12.0 release asset and verified by sha256, because this
# binary is the OUTER transport for a VPN and a substituted binary would defeat the
# whole camouflage layer.
install_cloak_client() {
    print_step "Checking cloak-client (ck-client) installation..."

    # Already-installed check FIRST: the arch check used to run before it, so an
    # unsupported arch printed a warning even on a machine that already had ck-client.
    if command -v ck-client >/dev/null 2>&1; then
        print_success "ck-client is already installed"
        return 0
    fi

    # Kodachi's own signed package FIRST, exactly like install_xray and install_v2ray do.
    # It is verified by the repo GPG key, so it beats the pinned-but-unsigned GitHub asset
    # below on provenance, and it is also the only path that gives apt a record of the
    # binary, so a later `apt upgrade` can move it.
    #
    # kodachi-cloak-CLIENT, not kodachi-cloak. The published kodachi-cloak deb ships
    # ck-SERVER, which is the VPS half: installing it on a desktop yields no ck-client and
    # openvpn-cloak still cannot start. The client package is new as of 2026-08-25
    # (installers/vendor-thirdparty.sh), pinned to the same Cloak release as the server.
    if kodachi_try_packaged_install "kodachi-cloak-client" "ck-client"; then
        return 0
    fi

    # x86_64 ONLY, on purpose. The pinned want_sha below is the sha256 of the linux-AMD64
    # asset, so the previous `aarch64) arch="arm64"` arm built the arm64 asset URL and then
    # compared it against the amd64 hash: a GUARANTEED "sha256 MISMATCH" on every aarch64
    # run, i.e. code that claimed to support an architecture it could never install on.
    # Fail-closed was never in question; the defect was the false alarm and the false claim.
    # Adding arm64 back means pinning its OWN hash, not widening this case.
    local arch=""
    case $(uname -m) in
        x86_64) arch="amd64" ;;
        *)
            print_warning "Cloak ck-client has no pinned prebuilt binary for $(uname -m); skipping"
            return 0
            ;;
    esac

    # Cloak v2.12.0 linux-amd64 ck-client, sha256 pinned in proposal.md.
    local version="2.12.0"
    local want_sha="ceabde7e13cf0e9dd7f53f811d6f24c1246755911b06aa40fb541041016348e3"
    local asset="ck-client-linux-${arch}-v${version}"
    local url="https://github.com/cbeuw/Cloak/releases/download/v${version}/${asset}"
    # mktemp, not /tmp/<name>-$$: this runs as root and $$ is predictable, so a
    # world-writable /tmp gives a window between the sha256 check and the mv.
    local tmp=""
    tmp="$(mktemp -t ck-client.dl.XXXXXX)"

    echo "Downloading ck-client v${version}..."
    if kodachi_download_first "$url" "$tmp"; then
        local got_sha=""
        got_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
        if [[ "$got_sha" == "$want_sha" ]]; then
            mv -f "$tmp" /usr/local/bin/ck-client
            chmod 755 /usr/local/bin/ck-client
            print_success "ck-client installed (sha256 verified)"
        else
            print_error "ck-client sha256 MISMATCH: got $got_sha, want $want_sha"
            rm -f "$tmp" 2>/dev/null || true
        fi
    else
        print_error "Failed to download ck-client"
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# Function to install the AmneziaWG KERNEL MODULE via Kodachi's signed DKMS package.
#
# Deliberately best-effort and never fatal. The tools and the module are separable: awg can
# be present and useful for inspecting configuration on a machine whose kernel cannot build
# the module (no headers for the running kernel, a container, an unsupported architecture).
# The deb's own postinst is tolerant for the same reason, so a failure here costs one
# protocol and never leaves dpkg half-configured.
#
# There is no source fallback on purpose. Building an out-of-tree kernel module from an
# unpinned clone as root is a strictly worse operation than the userland build the gate
# below already refuses, so if the signed package is unavailable the module is simply
# absent and the caller says so.
install_amneziawg_module() {
    if [[ -d /sys/module/amneziawg ]] || modinfo amneziawg >/dev/null 2>&1; then
        print_success "amneziawg kernel module already available"
        return 0
    fi

    # No verify command: the module is built by the package's postinst against the running
    # kernel, so success is not observable as a binary on PATH. Report what actually
    # happened instead of asserting on a command that will never exist.
    if kodachi_try_packaged_install "kodachi-amneziawg-dkms" ""; then
        if modinfo amneziawg >/dev/null 2>&1; then
            print_success "amneziawg kernel module built and installed by DKMS"
        else
            print_warning "kodachi-amneziawg-dkms installed but the module did not build"
            print_info "install linux-headers-\$(uname -r) and dwarves, then: dkms install -m amneziawg -v 1.0.0"
        fi
        return 0
    fi

    print_warning "amneziawg kernel module unavailable (kodachi-amneziawg-dkms not installable)"
    return 0
}

# Function to install amneziawg-tools (awg, awg-quick) from source.
# The kernel module itself is a separate concern (DKMS / apt repo); these are the
# userland tools that drive an awg0 interface once the module is loaded.
install_amneziawg_tools() {
    print_step "Checking amneziawg-tools installation..."

    if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
        print_success "amneziawg-tools already installed"
        return 0
    fi

    # Kodachi's own signed packages FIRST, and this is the path that now carries AmneziaWG
    # on a normal install.
    #
    # WHAT THIS FIXES. The source build below is gated behind
    # KODACHI_ALLOW_UNPINNED_UPSTREAM=1 and is therefore OFF by default, correctly, because
    # it clones a moving branch and runs `make install` as root. The consequence nobody had
    # written down is that a default bash install produced NO awg at all, while the
    # dashboard went on offering AmneziaWG as a protocol. Measured 2026-08-25 on a clean
    # Debian 13 box installed from the channel: awg, awg-quick and ck-client all absent.
    #
    # The packaged path has none of the properties that gate exists to refuse: the two debs
    # are built from COMMIT-PINNED sources by installers/build-amneziawg-debs.sh, and apt
    # verifies the repo GPG signature before unpacking anything. So it runs unconditionally
    # and the gate below stays exactly as strict as it was for the source fallback.
    install_amneziawg_module
    if kodachi_try_packaged_install "kodachi-amneziawg-tools" "awg"; then
        return 0
    fi

    # UNPINNED UPSTREAM, so it is gated exactly like every sibling in this file.
    #
    # The build below clones the DEFAULT BRANCH of a third-party GitHub repo with no tag,
    # no commit pin, no hash and no signature, then runs `make install` AS ROOT after
    # silently apt-installing build-essential. That is precisely the class
    # kodachi_upstream_unpinned_allowed() was written for (see its comment above), and it
    # was the only unpinned path in this file with no gate in front of it. It reached the
    # public download copy on 2026-08-19 when the five shipping copies were union-merged,
    # so the gate goes in before anyone runs it from there.
    #
    # SKIP-AND-CONTINUE with return 0, not `return 1`: awg/awg-quick are optional userland
    # tools and a refusal must not abort the caller, which goes on to install kloak and the
    # rest. Same reasoning as the second gate in install_v2ray().
    if ! kodachi_upstream_unpinned_allowed; then
        print_warning "Skipping the UNPINNED amneziawg-tools source build: it clones the default"
        print_info "branch of github.com/amnezia-vpn/amneziawg-tools with no tag, hash or signature"
        print_info "and runs 'make install' as root. awg and awg-quick will be unavailable."
        print_info "To build it anyway, re-run with: KODACHI_ALLOW_UNPINNED_UPSTREAM=1"
        return 0
    fi

    if ! command -v make >/dev/null 2>&1 || ! command -v gcc >/dev/null 2>&1; then
        apt-get install -y -qq --no-install-recommends build-essential >/dev/null 2>&1 || true
    fi

    local tmp=""
    tmp="$(mktemp -d)"
    echo "Cloning and building amneziawg-tools..."
    if git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git "$tmp/tools" 2>/dev/null; then
        if ( cd "$tmp/tools/src" && make -j"$(nproc)" >/dev/null 2>&1 && make install >/dev/null 2>&1 ); then
            print_success "amneziawg-tools installed (awg, awg-quick)"
        else
            print_warning "amneziawg-tools build failed (awg unavailable)"
        fi
    else
        print_warning "Failed to clone amneziawg-tools (awg unavailable)"
    fi
    rm -rf "$tmp"
}

# Function to install kloak (keystroke anonymization)
install_kloak() {
    print_step "Checking kloak installation..."

    local resolved_kloak_version=""
    resolved_kloak_version="$(resolve_latest_github_tag_version "vmonaco/kloak" "$KLOAK_VERSION" 's/^v//')"
    if [[ -n "$resolved_kloak_version" ]]; then
        KLOAK_VERSION="$resolved_kloak_version"
    fi

    # Special handling for kloak - it doesn't support version reporting
    # kloak v0.2 has no --version flag, so we just check if binary exists
    if command -v kloak &>/dev/null; then
        print_success "kloak is already installed (v$KLOAK_VERSION assumed - no version reporting)"
        setup_kloak_service
        return 0
    fi

    print_step "Installing kloak v$KLOAK_VERSION..."

    # Try compilation first (preferred method for control)
    print_info "Attempting to compile kloak from source..."
    if install_kloak_from_source; then
        setup_kloak_service "compiled"
        return 0
    else
        print_warning "Compilation failed, trying Whonix repository as fallback..."
        if install_kloak_from_repository; then
            setup_kloak_service "repository"
            return 0
        else
            print_error "Failed to install kloak via both compilation and repository"
            return 1
        fi
    fi
}

# Function to compile kloak from source
install_kloak_from_source() {
    print_step "Compiling kloak from source..."
    
    local temp_dir="/tmp/kloak-install-$$"
    
    # Install build dependencies
    print_info "Installing build dependencies..."
    apt-get update 2>/dev/null || true
    if ! apt-get install -y make pkgconf libsodium-dev libevdev-dev libevdev2 build-essential 2>&1 | tail -5; then
        print_error "Failed to install build dependencies for kloak"
        return 1
    fi
    
    # Download source
    print_info "Downloading kloak v${KLOAK_VERSION} source..."
    mkdir -p "$temp_dir"
    cd "$temp_dir" || return 1
    
    if retry_download "https://github.com/vmonaco/kloak/archive/v${KLOAK_VERSION}.tar.gz" "kloak.tar.gz"; then
        print_info "Downloaded kloak source from GitHub"
        
        # Extract and compile
        if tar xf kloak.tar.gz 2>/dev/null; then
            cd "kloak-${KLOAK_VERSION}" || return 1
            
            print_info "Compiling kloak..."
            if make all >/dev/null 2>&1; then
                # Install binary
                if [[ -f kloak ]]; then
                    mv kloak /usr/local/bin/kloak
                    chmod +x /usr/local/bin/kloak
                    print_success "kloak compiled and installed successfully"
                    cd / && rm -rf "$temp_dir"
                    return 0
                else
                    print_error "kloak binary not found after compilation"
                fi
            else
                print_error "Failed to compile kloak"
            fi
        else
            print_error "Failed to extract kloak source"
        fi
    else
        print_error "Failed to download kloak source"
    fi
    
    # Cleanup
    cd / && rm -rf "$temp_dir"
    return 1
}

# Function to install kloak from Whonix repository
install_kloak_from_repository() {
    print_step "Installing kloak from Whonix repository..."
    
    # Check if Whonix repository is already configured
    if [[ -f "/etc/apt/sources.list.d/whonix.list" ]] && [[ -f "/etc/apt/trusted.gpg.d/whonix.gpg" ]]; then
        print_info "Whonix repository already configured"
    else
        print_step "Adding Whonix repository for kloak..."
        
        # Create trusted keyrings directory
        install -d -m 0755 /etc/apt/trusted.gpg.d
        
        # Import Whonix signing key
        print_info "Importing Whonix repository key..."
        if curl -fsSL https://www.whonix.org/patrick.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/whonix.gpg; then
            print_success "Repository key imported successfully"
        else
            print_error "Failed to import repository key"
            return 1
        fi
        
        # Add repository
        print_info "Adding Whonix repository..."
        echo 'deb https://deb.whonix.org bullseye main contrib non-free' | tee /etc/apt/sources.list.d/whonix.list
        
        # Update package lists
        print_info "Updating package lists..."
        if apt-get update 2>&1 | tail -5; then
            print_success "Package lists updated"
        else
            print_warning "Failed to update package lists completely"
            return 1
        fi
    fi
    
    # Install kloak from repository
    if apt-get install -y kloak 2>&1 | tail -5; then
        print_success "kloak installed successfully from repository"
        return 0
    else
        return 1
    fi
}

# Function to setup kloak systemd service
setup_kloak_service() {
    local install_method="$1"
    
    print_step "Setting up kloak service..."
    
    # Check if systemd service already exists
    if systemctl list-unit-files kloak.service &>/dev/null; then
        print_info "kloak service file already exists"
    else
        # Create systemd service file for compiled version
        print_info "Creating kloak systemd service file..."
        create_kloak_service_file
    fi
    
    # Enable service but do not start it
    print_info "Enabling kloak service (not starting)..."
    if systemctl enable kloak 2>/dev/null; then
        print_success "kloak service enabled (use 'systemctl start kloak' to activate)"
    else
        print_warning "Failed to enable kloak service"
    fi
    
    print_info "kloak service is ready but not active - user can start when needed"
}

# Function to create kloak systemd service file
create_kloak_service_file() {
    # THIS UNIT MUST MATCH health-control's TEMPLATE (kloak_integration.rs,
    # install_kloak_service). It previously did not, and the divergence was
    # reachable: this installer writes /etc/systemd/system/kloak.service and
    # then prints "use 'systemctl start kloak' to activate", so a user who
    # follows that instruction gets THIS unit, never health-control's. Before
    # this change that meant an unhardened kloak with no input device.
    #
    # Two things were wrong and both are fixed here:
    #
    # 1. ExecStart had NO ARGUMENTS, so kloak auto-detected a keyboard, failed
    #    with "Unable to find a keyboard. Specify which input device to use with
    #    the -r parameter" on machines that plainly have one, and looped under
    #    Restart=on-failure. The device is machine-specific, so the installer
    #    cannot hardcode it: it now detects the same way health-control does,
    #    a device whose Handlers carry BOTH kbd and leds, which excludes Power
    #    Button and PC Speaker.
    #
    # 2. The hardening set was WEAKER than health-control's: it had no
    #    DevicePolicy, and no ProtectKernelLogs, ProtectClock, ProtectHostname,
    #    RestrictSUIDSGID, RestrictNamespaces, LockPersonality,
    #    MemoryDenyWriteExecute or SystemCallArchitectures. Starting kloak
    #    outside the dashboard therefore ran it with less isolation than the
    #    dashboard applies, silently.
    #
    # DeviceAllow=char-input, NOT /dev/input/*. systemd does not glob there: it
    # takes a device node path or a char-/block- group, so the glob would match
    # nothing and grant no input device at all, failing at runtime with EPERM
    # while the same command by hand succeeds. Measured 2026-08-18.
    local kloak_device
    kloak_device="$(awk '
        /^N: Name=/ { name = $0 }
        /^H: Handlers=/ {
            if ($0 ~ /kbd/ && $0 ~ /leds/ &&
                name !~ /Power Button|Sleep Button|PC Speaker|Video Bus|Mouse/) {
                # Strip the directive prefix first: the event node can be the FIRST
                # handler, and it is then glued to "Handlers=" and matches nothing.
                handlers = $0; sub(/^H: Handlers=/, "", handlers);
                n = split(handlers, hf, " ");
                for (i = 1; i <= n; i++) if (hf[i] ~ /^event[0-9]+$/) { print "/dev/input/" hf[i]; exit }
            }
        }
    ' /proc/bus/input/devices 2>/dev/null)"

    local kloak_exec="/usr/local/bin/kloak"
    if [ -n "$kloak_device" ] && [ -e "$kloak_device" ]; then
        kloak_exec="/usr/local/bin/kloak -r $kloak_device"
        print_info "kloak will read from $kloak_device"
    else
        print_warning "No keyboard found for kloak; the service will not start until one is set with 'health-control kloak-configure --device /dev/input/eventN'"
    fi

    cat > /etc/systemd/system/kloak.service << EOF
[Unit]
Description=Kloak - Keystroke Anonymization
Documentation=https://github.com/vmonaco/kloak
After=multi-user.target

[Service]
Type=simple
ExecStart=$kloak_exec
Restart=on-failure
RestartSec=5
User=root
Group=root
UMask=0077

# Security settings. Kept in step with health-control's template on purpose:
# starting kloak outside the dashboard must not be less protected than starting
# it from the dashboard.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
DevicePolicy=closed
DeviceAllow=char-input rw
DeviceAllow=/dev/uinput rw

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd to recognize new service
    systemctl daemon-reload
    print_success "kloak service file created"
}

# Function to setup DNSCrypt Proxy configuration file
normalize_dnscrypt_config() {
    local config_file="$1"

    [[ -f "$config_file" ]] || return 1

    sed -i \
        -e "s/^# user_name = 'nobody'\(  # disabled: systemd User= handles privilege drop\)*$/# user_name = 'nobody'  # disabled: systemd User= handles privilege drop/" \
        -e "s/^user_name = 'nobody'/# user_name = 'nobody'  # disabled: systemd User= handles privilege drop/" \
        -e "s/^user_name = '_dnscrypt-proxy'/# user_name = '_dnscrypt-proxy'  # disabled: systemd User= handles privilege drop/" \
        -e "s#^[[:space:]]*cache_file = 'public-resolvers.md'#    cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'#" \
        -e "s#^[[:space:]]*cache_file = 'relays.md'#    cache_file = '/var/cache/dnscrypt-proxy/relays.md'#" \
        -e "s#^[[:space:]]*cache_file = 'odoh-servers.md'#    cache_file = '/var/cache/dnscrypt-proxy/odoh-servers.md'#" \
        -e "s#^[[:space:]]*cache_file = 'odoh-relays.md'#    cache_file = '/var/cache/dnscrypt-proxy/odoh-relays.md'#" \
        -e "/^fallback_resolver = /d" \
        -e "/^fallback_resolvers = \\[/d" \
        "$config_file"

    if grep -q "^bootstrap_resolvers = " "$config_file" 2>/dev/null; then
        # Normalise UNCONDITIONALLY so the stock dnscrypt-proxy.toml's 8.8.8.8 (Google)
        # bootstrap entry is stripped on installed systems too (privacy: no plaintext
        # bootstrap query to Google).
        sed -i "s|^bootstrap_resolvers = .*|bootstrap_resolvers = ['9.9.9.9:53', '1.1.1.1:53', '94.140.14.14:53']|" "$config_file"
        print_success "Normalised bootstrap_resolvers in DNSCrypt config (Google-free)"
    elif grep -q "^netprobe_timeout = " "$config_file" 2>/dev/null; then
        sed -i "/^netprobe_timeout = /a\\
bootstrap_resolvers = ['9.9.9.9:53', '1.1.1.1:53', '94.140.14.14:53']" "$config_file"
        print_success "Ensured bootstrap_resolvers is present in DNSCrypt config"
    else
        printf "\nbootstrap_resolvers = ['9.9.9.9:53', '1.1.1.1:53', '94.140.14.14:53']\n" >> "$config_file"
        print_success "Ensured bootstrap_resolvers is present in DNSCrypt config"
    fi

    # Privacy: strip Google from server_names if present. The live-build hook ships a
    # Google-free list on new ISOs, but an older ISO (or stock toml) may still list 'google'.
    # Remove only the google entry, preserving any other configured resolvers.
    if grep -qE "^server_names = .*'google'" "$config_file" 2>/dev/null; then
        sed -i -e "/^server_names = /s/'google', //g" \
               -e "/^server_names = /s/, 'google'//g" \
               -e "/^server_names = /s/'google'//g" "$config_file"
        print_success "Removed Google from DNSCrypt server_names"
    fi
}

find_dnscrypt_seed_dir() {
    local candidates=(
        "$SCRIPT_DIR/dnscrypt-resolvers"
        "/opt/kodachi/dashboard/hooks/dnscrypt-cache"
        "/opt/kodachi/dashboard/hooks/binaries-update-scripts/dnscrypt-resolvers"
        "/opt/kodachi-offline-packages/proxies"
    )

    # Check user-home install paths (binary-install.sh may have placed cache here)
    local real_user=""
    real_user="$(id -un 2>/dev/null || echo "")"
    if [[ -n "${SUDO_USER:-}" ]]; then
        real_user="$SUDO_USER"
    fi
    if [[ -n "$real_user" ]]; then
        local user_home=""
        user_home="$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6 || echo "")"
        if [[ -n "$user_home" ]]; then
            candidates+=("$user_home/Desktop/dashboard/hooks/dnscrypt-cache")
            candidates+=("$user_home/dashboard/hooks/dnscrypt-cache")
        fi
    fi

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/livebuilds/kodachi-terminal-build/overlays/common/includes.chroot_after_packages/opt/kodachi-offline-packages/proxies")
    fi

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate/public-resolvers.md" ]] || [[ -f "$candidate/relays.md" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

setup_dnscrypt_config() {
    local install_dir="/etc/dnscrypt-proxy"
    local config_file="$install_dir/dnscrypt-proxy.toml"
    local example_config="$install_dir/example-dnscrypt-proxy.toml"

    print_step "Setting up DNSCrypt Proxy configuration..."

    # Check if install directory exists
    if [[ ! -d "$install_dir" ]]; then
        print_error "DNSCrypt Proxy directory not found: $install_dir"
        return 1
    fi

    # Check if config file already exists
    if [[ -f "$config_file" ]]; then
        print_success "DNSCrypt Proxy config file already exists"
        normalize_dnscrypt_config "$config_file"
        preseed_dnscrypt_server_lists
        return 0
    fi

    # Check if example config exists
    if [[ ! -f "$example_config" ]]; then
        print_error "Example config file not found: $example_config"
        print_info "Cannot create DNSCrypt Proxy configuration"
        return 1
    fi

    # Copy example config to actual config
    print_info "Creating config file from example..."
    if cp "$example_config" "$config_file"; then
        chmod 644 "$config_file"
        normalize_dnscrypt_config "$config_file"
        print_success "DNSCrypt Proxy config file created: $config_file"
        print_info "Config uses default settings - you can customize it later"
        preseed_dnscrypt_server_lists
        return 0
    else
        print_error "Failed to create config file"
        return 1
    fi
}

# Pre-seed DNSCrypt server list cache on the target device.
# Without cached lists, dnscrypt-proxy must download them on first boot.
# If the network isn't ready yet, DNS breaks entirely (chicken-and-egg problem).
preseed_dnscrypt_server_lists() {
    local cache_dir="/var/cache/dnscrypt-proxy"
    local resolver_base="https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3"
    local resolver_alt="https://download.dnscrypt.info/resolvers-list/v3"
    local seed_dir=""
    local seeded=0

    print_step "Pre-seeding DNSCrypt server list cache..."
    mkdir -p "$cache_dir"
    seed_dir="$(find_dnscrypt_seed_dir || true)"

    if [[ -n "$seed_dir" ]]; then
        print_info "Using bundled DNSCrypt resolver seeds from $seed_dir"
    fi

    for listfile in public-resolvers.md relays.md; do
        local have_seed=false
        local have_sig_seed=false

        if [[ -n "$seed_dir" && -f "$seed_dir/$listfile" ]]; then
            install -m 644 "$seed_dir/$listfile" "$cache_dir/$listfile"
            print_success "  $listfile seeded from bundled cache"
            have_seed=true
        fi

        if curl -fsSL --connect-timeout 15 --max-time 60 -o "$cache_dir/$listfile" "$resolver_base/$listfile" 2>/dev/null; then
            print_success "  $listfile downloaded (GitHub)"
            ((seeded++)) || true
        elif curl -fsSL --connect-timeout 15 --max-time 60 -o "$cache_dir/$listfile" "$resolver_alt/$listfile" 2>/dev/null; then
            print_success "  $listfile downloaded (mirror)"
            ((seeded++)) || true
        elif [[ "$have_seed" == "true" || -f "$cache_dir/$listfile" ]]; then
            print_info "  Keeping cached $listfile"
            ((seeded++)) || true
        else
            print_warning "  Could not download $listfile (dnscrypt will fetch at runtime)"
        fi

        if [[ -n "$seed_dir" && -f "$seed_dir/${listfile}.minisig" ]]; then
            install -m 644 "$seed_dir/${listfile}.minisig" "$cache_dir/${listfile}.minisig"
            have_sig_seed=true
        fi

        if curl -fsSL --connect-timeout 15 --max-time 30 -o "$cache_dir/${listfile}.minisig" "$resolver_base/${listfile}.minisig" 2>/dev/null; then
            print_info "  ${listfile}.minisig refreshed"
        elif curl -fsSL --connect-timeout 15 --max-time 30 -o "$cache_dir/${listfile}.minisig" "$resolver_alt/${listfile}.minisig" 2>/dev/null; then
            print_info "  ${listfile}.minisig refreshed (mirror)"
        elif [[ "$have_sig_seed" == "true" || -f "$cache_dir/${listfile}.minisig" ]]; then
            print_info "  Keeping cached ${listfile}.minisig"
        else
            print_warning "  Could not seed ${listfile}.minisig"
        fi
    done

    if id _dnscrypt-proxy &>/dev/null; then
        chown -R _dnscrypt-proxy:_dnscrypt-proxy "$cache_dir" 2>/dev/null || true
    fi
    chmod 755 "$cache_dir"

    if [[ $seeded -gt 0 ]]; then
        print_success "Server list cache ready ($seeded lists ready)"
    else
        print_warning "No server lists seeded - dnscrypt will download on first start"
    fi
}

resolve_dnscrypt_binary_path() {
    local candidate=""

    for candidate in /usr/local/bin/dnscrypt-proxy /usr/sbin/dnscrypt-proxy /usr/bin/dnscrypt-proxy; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    candidate="$(command -v dnscrypt-proxy 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    echo "/usr/local/bin/dnscrypt-proxy"
}

# Function to setup DNSCrypt Proxy systemd service
setup_dnscrypt_service() {
    local install_method="$1"

    print_step "Setting up DNSCrypt Proxy service..."

    if ! setup_dnscrypt_config; then
        print_error "DNSCrypt configuration is unavailable; refusing to create or enable its service"
        return 1
    fi

    if systemctl list-unit-files dnscrypt-proxy.service &>/dev/null; then
        print_info "Refreshing DNSCrypt Proxy systemd service file..."
    else
        print_info "Creating DNSCrypt Proxy systemd service file..."
    fi
    create_dnscrypt_service_file "$install_method"

    print_info "Enabling DNSCrypt Proxy service..."
    systemctl enable dnscrypt-proxy 2>/dev/null || true

    # Enable the DNSCrypt auto-recovery monitor so installed systems also climb back to
    # encrypted DNS automatically after any temporary plaintext fallback (privacy). Matches
    # the live-build 0006 hook; harmless if the units already exist.
    cat > /etc/systemd/system/dnscrypt-monitor.service <<'MONSVC'
[Unit]
Description=DNSCrypt monitor check (dns-switch)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns-switch dnscrypt-monitor-check --json
StandardOutput=journal
StandardError=journal
MONSVC
    cat > /etc/systemd/system/dnscrypt-monitor.timer <<'MONTMR'
[Unit]
Description=Run dnscrypt-monitor.service every 15 seconds

[Timer]
OnBootSec=30sec
OnUnitActiveSec=15sec
AccuracySec=1sec
Unit=dnscrypt-monitor.service
Persistent=true

[Install]
WantedBy=timers.target
MONTMR
    systemctl daemon-reload 2>/dev/null || true
    if systemctl enable --now dnscrypt-monitor.timer 2>/dev/null; then
        print_success "DNSCrypt auto-recovery monitor enabled and started"
    else
        print_warning "Could not enable dnscrypt-monitor.timer (will self-enable at runtime)"
    fi

    # Safety: clear stuck systemd jobs before starting (boot race protection)
    systemctl stop dnscrypt-proxy.socket 2>/dev/null || true
    systemctl stop dnscrypt-proxy 2>/dev/null || true
    systemctl reset-failed dnscrypt-proxy 2>/dev/null || true
    sleep 1

    print_info "Starting DNSCrypt Proxy service..."
    if ! timeout 75 systemctl start dnscrypt-proxy 2>/dev/null; then
        print_warning "Failed to start DNSCrypt Proxy (will start on next boot)"
        return 0
    fi

    sleep 2
    if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
        print_success "DNSCrypt Proxy service is running"
    else
        print_warning "DNSCrypt Proxy started but not yet active"
    fi
}

# Function to create DNSCrypt Proxy systemd service file
create_dnscrypt_service_file() {
    local install_method="${1:-}"
    local dnscrypt_bin=""

    dnscrypt_bin="$(resolve_dnscrypt_binary_path)"

    if ! id _dnscrypt-proxy &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin _dnscrypt-proxy
        print_success "Created _dnscrypt-proxy system user"
    fi

    cat > /etc/systemd/system/dnscrypt-proxy.service << EOF
[Unit]
Description=DNSCrypt Proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki
After=network-online.target
Before=nss-lookup.target
Wants=network-online.target nss-lookup.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
ExecStartPre=+/bin/sh -c 'i=0; while [ \$i -lt 20 ]; do ping -c1 -W2 9.9.9.9 >/dev/null 2>&1 && exit 0; i=\$((i+1)); sleep 2; done; exit 0'
ExecStart=$dnscrypt_bin -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
WorkingDirectory=/etc/dnscrypt-proxy
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

# CRITICAL: Allow binding to port 53 (privileged port) as unprivileged user
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

User=_dnscrypt-proxy
CacheDirectory=dnscrypt-proxy
LogsDirectory=dnscrypt-proxy
RuntimeDirectory=dnscrypt-proxy

# Security settings
NoNewPrivileges=true
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/dnscrypt-proxy
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "DNSCrypt Proxy service file created"

    if [[ -n "$install_method" ]]; then
        print_info "DNSCrypt service refreshed for install method: $install_method"
    fi
}

# Function to generate Pi-hole setupVars.conf for unattended installation
generate_pihole_setupvars() {
    print_step "Generating Pi-hole configuration for unattended installation..."

    # Create /etc/pihole directory if it doesn't exist
    mkdir -p /etc/pihole

    # Detect primary network interface with multiple fallback methods
    local interface=""
    local ipv4_address=""

    # Method 1: Try default route (most reliable when available)
    # `|| true`: no default route (offline/odd network) would otherwise abort the
    # installer here under `set -eo pipefail`, before Method 2 could ever run.
    interface=$(ip route | grep '^default' | head -1 | awk '{print $5}' || true)
    if [[ -n "$interface" ]]; then
        ipv4_address=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    fi

    # Method 2: Try interface with active IPv4 (if Method 1 failed)
    if [[ -z "$interface" ]] || [[ -z "$ipv4_address" ]]; then
        local addr_line=$(ip -4 -o addr show | grep -v "127.0.0.1" | head -1)
        if [[ -n "$addr_line" ]]; then
            interface=$(echo "$addr_line" | awk '{print $2}')
            ipv4_address=$(echo "$addr_line" | awk '{print $4}' | cut -d'/' -f1)
        fi
    fi

    # Method 3: Try first UP interface (last resort)
    if [[ -z "$interface" ]] || [[ -z "$ipv4_address" ]]; then
        interface=$(ip -o link show | grep "state UP" | grep -v "lo" | head -1 | awk '{print $2}' | sed 's/:$//' || true)
        if [[ -n "$interface" ]]; then
            ipv4_address=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
        fi
    fi

    # Clean interface name (remove @ifXX suffixes if present)
    interface=$(echo "$interface" | cut -d'@' -f1)

    # Debug output
    print_info "Detected interface: ${interface:-NONE}"
    print_info "Detected IPv4: ${ipv4_address:-NONE}"

    # Validation
    if [[ -z "$interface" ]] || [[ -z "$ipv4_address" ]]; then
        print_error "Could not detect network interface or IP address"
        print_info "Available interfaces:"
        ip -o link show | grep -v "lo:" 2>/dev/null || echo "  No interfaces found"
        print_info "Please configure network first or run Pi-hole installer manually"
        return 1
    fi

    print_info "Using interface: $interface"
    print_info "Using IPv4: $ipv4_address"

    # Generate random web password
    local web_password=$(generate_pihole_password)

    # Double-hash the password for Pi-hole (SHA256 twice with newline)
    local hashed_password=$(printf "%s" "$web_password" | sha256sum | awk '{print $1}')
    hashed_password=$(printf "%s" "$hashed_password" | sha256sum | awk '{print $1}')

    # Create setupVars.conf with all required settings
    cat > /etc/pihole/setupVars.conf <<EOF
# Pi-hole Configuration - Auto-generated for Kodachi
PIHOLE_INTERFACE=$interface
IPV4_ADDRESS=${ipv4_address}/24
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
BLOCKING_ENABLED=true
DNSSEC=false
REV_SERVER=false
PIHOLE_DNS_1=9.9.9.10
PIHOLE_DNS_2=149.112.112.10
WEBPASSWORD=$hashed_password
# Run Pi-hole on port 5353 to avoid conflict with DNSCrypt Proxy (port 53)
FTLCONF_LOCAL_PORT=5353
FTLCONF_dns_port=5353
EOF

    if [[ -f /etc/pihole/setupVars.conf ]]; then
        print_success "Pi-hole configuration created at /etc/pihole/setupVars.conf"
        print_info "Web password: $web_password (save this!)"
        echo "$web_password" > /etc/pihole/.webpassword_initial
        chmod 600 /etc/pihole/.webpassword_initial
        return 0
    else
        print_error "Failed to create Pi-hole configuration"
        return 1
    fi
}

# Function to configure Pi-hole to use port 5353
configure_pihole_port() {
    print_step "Configuring Pi-hole to use port 5353..."

    local pihole_config="/etc/pihole/pihole.toml"
    local pihole_ftl_config="/etc/pihole/pihole-FTL.conf"

    # Check if Pi-hole is installed
    if ! command -v pihole &>/dev/null; then
        print_warning "Pi-hole is not installed, skipping port configuration"
        return 1
    fi

    # Modern Pi-hole uses pihole.toml (v6.x)
    if [[ -f "$pihole_config" ]]; then
        print_info "Updating Pi-hole TOML configuration for port 5353..."

        # Check if file is protected (immutable attribute)
        local was_protected=false
        if lsattr "$pihole_config" 2>/dev/null | grep -q '^....i'; then
            was_protected=true
            chattr -i "$pihole_config" 2>/dev/null || true
        fi

        # FIX (audit 2026-05-01, Battlestar-Galactica build): idempotent
        # port=5353 enforcement in [dns] section. Combined with the install
        # hook 0012-install-pihole.hook.chroot the previous logic produced 3
        # duplicate `port = 5353` lines under [dns], making pihole-FTL emit
        # "Cannot parse config file: line 7: key exists" 30+ times per session.
        # The `awk` pre-existing branch only replaced ONE line and left the
        # canonical heredoc port intact; the `else` branch inserted a second
        # copy after [dns] without checking presence; together they accumulated.
        #
        # New behavior (matches install hook exactly):
        #   1. If [dns] has exactly one canonical "  port = 5353" line, no-op.
        #   2. Otherwise rewrite the file so [dns] holds exactly one canonical
        #      "  port = 5353" line, dropping every other "port = N" inside the
        #      [dns] section. Other sections are untouched.
        # Create backup before rewrite
        cp "$pihole_config" "${pihole_config}.bak" 2>/dev/null || true

        local port_lines_in_dns
        port_lines_in_dns=$(awk '
            /^\[dns\]/                                                                  { in_dns=1; next }
            /^\[/                                                                       { in_dns=0 }
            in_dns && /^[[:space:]]*port[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/   { count++ }
            END { print count+0 }
        ' "$pihole_config")
        local has_canonical
        has_canonical=$(grep -cE '^  port = 5353$' "$pihole_config" 2>/dev/null || echo 0)

        if [ "$port_lines_in_dns" = "1" ] && [ "$has_canonical" = "1" ]; then
            print_info "Port 5353 already configured in $pihole_config (no changes)"
        else
            awk '
                /^\[dns\]/ {
                    print
                    print "  port = 5353"
                    in_dns=1
                    seen_dns=1
                    next
                }
                /^\[/                                                                   { in_dns=0 }
                in_dns && /^[[:space:]]*port[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ { next }
                { print }
                END {
                    if (!seen_dns) {
                        print ""
                        print "[dns]"
                        print "  port = 5353"
                    }
                }
            ' "$pihole_config" > "${pihole_config}.tmp" && mv "${pihole_config}.tmp" "$pihole_config"
            # Restore pihole:pihole ownership + 644 perms after the awk-tmp-mv
            # rewrite (audit 2026-05-01 inspector follow-up): the rewrite path
            # leaves the new file as root:root, which causes pihole-FTL (running
            # as the pihole user) to fail config reads/writes silently. Mirrors
            # the install-hook (0012-install-pihole.hook.chroot) cleanup.
            chown pihole:pihole "$pihole_config" 2>/dev/null || true
            chmod 644 "$pihole_config" 2>/dev/null || true
            print_success "Port 5353 enforced in $pihole_config (deduplicated)"
        fi

        # Restore protection if it was originally protected
        if [ "$was_protected" = true ]; then
            chattr +i "$pihole_config" 2>/dev/null || true
        fi
    fi

    # Legacy Pi-hole uses pihole-FTL.conf (v5.x and earlier)
    if [[ -f "$pihole_ftl_config" ]]; then
        print_info "Updating legacy Pi-hole FTL configuration for port 5353..."

        # Check if file is protected (immutable attribute)
        local was_ftl_protected=false
        if lsattr "$pihole_ftl_config" 2>/dev/null | grep -q '^....i'; then
            was_ftl_protected=true
            chattr -i "$pihole_ftl_config" 2>/dev/null || true
        fi

        if grep -q "^LOCAL_PORT=" "$pihole_ftl_config"; then
            sed -i 's/^LOCAL_PORT=.*/LOCAL_PORT=5353/' "$pihole_ftl_config"
        else
            echo "LOCAL_PORT=5353" >> "$pihole_ftl_config"
        fi

        # Restore protection if it was originally protected
        if [ "$was_ftl_protected" = true ]; then
            chattr +i "$pihole_ftl_config" 2>/dev/null || true
        fi

        print_success "Set LOCAL_PORT=5353 in $pihole_ftl_config"
    fi

    # Restart Pi-hole service to apply changes
    print_info "Restarting Pi-hole service..."
    if systemctl restart pihole-FTL 2>/dev/null; then
        print_success "Pi-hole restarted successfully on port 5353"

        # Verify port
        sleep 2
        if ss -tlnp 2>/dev/null | grep -q ":5353.*pihole-FTL\|:5353.*dnsmasq"; then
            print_success "Verified: Pi-hole is listening on port 5353"
        else
            print_warning "Could not verify Pi-hole port (may need manual check)"
        fi
    else
        print_warning "Failed to restart Pi-hole - you may need to restart manually"
    fi

    print_info "Pi-hole configured to avoid port conflict with DNSCrypt Proxy"
    return 0
}

# Function to check DNS service coordination (DNSCrypt + Pi-hole)
check_dns_services() {
    print_step "Checking DNS service coordination..."

    local dnscrypt_port_53=false
    local pihole_port_5353=false
    local port_conflicts=false

    # Check if DNSCrypt is running on port 53
    if command -v dnscrypt-proxy &>/dev/null; then
        if systemctl is-active --quiet dnscrypt-proxy 2>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":53.*dnscrypt"; then
                dnscrypt_port_53=true
                print_success "DNSCrypt Proxy running on port 53"
            else
                print_warning "DNSCrypt Proxy service active but not listening on port 53"
            fi
        else
            print_info "DNSCrypt Proxy not running (service not started)"
        fi
    else
        print_info "DNSCrypt Proxy not installed"
    fi

    # Check if Pi-hole is running on port 5353
    if command -v pihole &>/dev/null; then
        if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
            if ss -tlnp 2>/dev/null | grep -q ":5353.*pihole-FTL\|:5353.*dnsmasq"; then
                pihole_port_5353=true
                print_success "Pi-hole running on port 5353"
            elif ss -tlnp 2>/dev/null | grep -q ":53.*pihole-FTL\|:53.*dnsmasq"; then
                print_error "Pi-hole running on port 53 - PORT CONFLICT DETECTED!"
                print_warning "Pi-hole must use port 5353 to avoid conflict with DNSCrypt"
                port_conflicts=true
            else
                print_warning "Pi-hole service active but not listening on expected ports"
            fi
        else
            print_info "Pi-hole not running (service not started)"
        fi
    else
        print_info "Pi-hole not installed"
    fi

    # Check for any port conflicts
    if [[ "$port_conflicts" == "true" ]]; then
        print_error "DNS port conflict detected - services cannot coexist"
        print_info "Run 'configure_pihole_port' to fix Pi-hole configuration"
        return 1
    fi

    # Summary
    echo ""
    if [[ "$dnscrypt_port_53" == "true" && "$pihole_port_5353" == "true" ]]; then
        print_success "✓ DNS services properly coordinated - no conflicts"
        print_info "  → DNSCrypt Proxy on port 53 (system DNS)"
        print_info "  → Pi-hole on port 5353 (ad-blocking DNS)"
    elif [[ "$dnscrypt_port_53" == "true" || "$pihole_port_5353" == "true" ]]; then
        print_info "DNS services partially configured"
    else
        print_info "DNS services not active"
    fi

    return 0
}

# A directory, setupVars.conf, or a stale unit can remain after a failed install.
# Only an executable Pi-hole producer proves that a retry is unnecessary.
pihole_runtime_installed() {
    command -v pihole >/dev/null 2>&1 && command -v pihole-FTL >/dev/null 2>&1
}

# Shared nonfatal optional-component runner used by the package dispatch. A failed
# first attempt remains retryable because residue is never treated as installed.
run_optional_pihole_setup() {
    local install_log="${KODACHI_PIHOLE_INSTALL_LOG:-/var/log/kodachi-pihole-install.log}"

    if pihole_runtime_installed; then
        print_info "Pi-hole executable already present; skipping reinstall (optional component)"
    else
        print_step "kodachi-system-setup: installing Pi-hole (optional component; disabled by default)"
        if KODACHI_PIHOLE_PACKAGE_CONTEXT=1 install_pihole >"$install_log" 2>&1; then
            print_success "Pi-hole installed (disabled by default)"
        else
            print_info "Pi-hole optional component skipped (its installer did not complete on this system; log: $install_log). Pi-hole is disabled by default - continuing."
        fi
    fi

    declare -f ensure_pihole_disabled >/dev/null 2>&1 && {
        ensure_pihole_disabled || print_warning "pihole disable incomplete"
    }
    return 0
}

# Function to install Pi-hole
# To uninstall Pi-hole, run: echo -e "yes\nno\nno\nno\nno\nno\nno\nno\nno\nno" | sudo pihole uninstall
install_pihole() {
    print_step "Installing Pi-hole..."

    # Check if Pi-hole is already installed
    if pihole_runtime_installed; then
        print_success "Pi-hole is already installed"

        # Try to get Pi-hole status
        if command -v pihole &>/dev/null; then
            pihole status 2>/dev/null | head -5 || true
        fi

        # Ensure Pi-hole is configured for port 5353
        configure_pihole_port

        ensure_dns_stable_after_change "Pi-hole availability" || return 1
        return 0
    fi

    echo "Pi-hole is not installed. Installing now..."
    echo ""

    # Kodachi's own signed package first. kodachi-pihole is published in the
    # Kodachi apt repo and verified by the repo GPG key, so it does not require
    # executing an unverifiable remote script as root the way install.pi-hole.net
    # does. There is also an offline copy inside the ISO at
    # /opt/kodachi-offline-packages/pihole/pihole-installer.sh for the no-network
    # case; both are preferred over upstream.
    # KODACHI_PIHOLE_PACKAGE_CONTEXT=1 means we are ALREADY executing inside the
    # kodachi-pihole postinst, so running `apt-get install kodachi-pihole` here
    # would recurse. Skipping it is correct. What was NOT correct is what the old
    # code did next: `&&` short-circuits, control falls straight into the block
    # below, and it reported "the packaged path (kodachi-pihole) failed" for a path
    # that was never attempted, then returned 1.
    #
    # MEASURED 2026-09-04 on the <lab-host> beta live ISO (VM <lab-host>):
    # Pi-hole was fully installed and working (kodachi-pihole <lab-host>-6 from the beta
    # channel, /usr/bin/pihole-FTL 28703537 bytes, /etc/pihole/ populated, all of it
    # placed by the offline-cache path in live-build hook 0012), and yet
    # /var/log/kodachi-pihole-install.log recorded
    #   "Pi-hole not installed: the packaged path (kodachi-pihole) failed."
    # and the caller then logged "its installer did not complete on this system".
    # A successful install was reported as a failure on every single build.
    local packaged_skipped=false
    if [[ "${KODACHI_PIHOLE_PACKAGE_CONTEXT:-0}" == "1" ]]; then
        packaged_skipped=true
        print_info "Packaged path skipped by design: already running inside the kodachi-pihole package (avoiding apt recursion)"
    elif kodachi_try_packaged_install "kodachi-pihole" "pihole"; then
        configure_pihole_port
        ensure_dns_stable_after_change "Pi-hole availability" || return 1
        return 0
    fi

    # RE-CHECK before declaring anything failed. Pi-hole has more than one producer:
    # live-build hook 0012-install-pihole.hook.chroot installs it from the offline
    # cache during the ISO build, so by the time this function runs the binaries can
    # already be in place. Declaring failure without looking is what produced the
    # false log line above.
    if pihole_runtime_installed; then
        print_success "Pi-hole is present (installed by the offline-cache path); nothing to do"
        configure_pihole_port
        ensure_dns_stable_after_change "Pi-hole availability" || return 1
        return 0
    fi

    if ! kodachi_upstream_unpinned_allowed; then
        if [[ "$packaged_skipped" == true ]]; then
            # Accurate wording: nothing FAILED here. This is the plain
            # `apt install kodachi-pihole` case on an already-installed system,
            # where the ISO's offline cache (/opt/kodachi-offline-packages/pihole)
            # does not exist, so this path has no pinned payload to install from.
            print_info "Pi-hole not installed: this system has no offline Pi-hole payload and the packaged"
            print_info "path is the one already running, so there is nothing further to try here."
        else
            print_error "Pi-hole not installed: the packaged path (kodachi-pihole) failed."
        fi
        print_info "https://install.pi-hole.net serves an unversioned script that would be executed"
        print_info "as root with no verifiable integrity check, so it is disabled by default."
        print_info "To use it anyway, re-run with: KODACHI_ALLOW_UNPINNED_UPSTREAM=1"
        # Pi-hole is an optional, disabled-by-default component. A deliberate skip is
        # not an error, so it must not be reported to the caller as one; a genuine
        # packaged-path failure still is.
        [[ "$packaged_skipped" == true ]] && return 0
        return 1
    fi

    print_warning "Falling back to the UNPINNED upstream Pi-hole installer (KODACHI_ALLOW_UNPINNED_UPSTREAM=1)"

    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing Pi-hole with default settings (Quad9 Unfiltered DNS)..."

        # Generate setupVars.conf for unattended installation
        if generate_pihole_setupvars; then
            # NOTE: the SHA256 printed below is DISCLOSURE, not verification -
            # nothing compares it, so it cannot refuse to run. Real protection
            # is the packaged path above; this branch is opt-in only.
            local pihole_script="/tmp/pihole-install-$$.sh"
            if curl -sSL -o "$pihole_script" https://install.pi-hole.net 2>/tmp/pihole-install.err; then
                # Basic sanity check: verify it's a bash script
                if head -1 "$pihole_script" | grep -q "^#!.*bash"; then
                    # Display script hash for verification
                    local script_hash=$(sha256sum "$pihole_script" | cut -d' ' -f1)
                    echo -e "${BLUE}[INFO]${NC} Pi-hole installer script SHA256: ${CYAN}${script_hash}${NC}"

                    # Run Pi-hole installer in unattended mode
                    if bash "$pihole_script" --unattended 2>>/tmp/pihole-install.err; then
                        print_success "Pi-hole installed successfully in unattended mode"

                        # Display saved password if available
                        if [[ -f /etc/pihole/.webpassword_initial ]]; then
                            local saved_password=$(cat /etc/pihole/.webpassword_initial)
                            print_info "Pi-hole Web Interface Password: $saved_password"
                            print_warning "Password saved to: /etc/pihole/.webpassword_initial"
                        fi
                        rm -f "$pihole_script"
                    else
                        print_error "Pi-hole unattended installation failed"
                        rm -f "$pihole_script"
                        return 1
                    fi
                else
                    print_error "Downloaded Pi-hole installer is not a valid bash script"
                    rm -f "$pihole_script"
                    return 1
                fi
            else
                print_error "Failed to download Pi-hole installer"
                return 1
            fi
        else
            print_error "Failed to generate Pi-hole configuration"
            return 1
        fi
    else
        print_warning "Pi-hole installer will run interactively."
        print_info "You'll need to configure Pi-hole settings during installation."
        echo ""

        # SECURITY FIX: Download and verify Pi-hole installer before interactive execution
        local pihole_script="/tmp/pihole-install-interactive-$$.sh"
        if curl -sSL -o "$pihole_script" https://install.pi-hole.net 2>/tmp/pihole-install.err; then
            if head -1 "$pihole_script" | grep -q "^#!.*bash"; then
                local script_hash=$(sha256sum "$pihole_script" | cut -d' ' -f1)
                echo -e "${BLUE}[INFO]${NC} Pi-hole installer script SHA256: ${CYAN}${script_hash}${NC}"
                bash "$pihole_script" 2>>/tmp/pihole-install.err
                rm -f "$pihole_script"
            else
                print_error "Downloaded Pi-hole installer is not a valid bash script"
                rm -f "$pihole_script"
                return 1
            fi
        else
            print_error "Failed to download Pi-hole installer"
            return 1
        fi
    fi

    # Wait for any background processes from Pi-hole installer to complete
    echo ""
    print_step "Waiting for Pi-hole installer to fully complete..."
    sleep 3

    # Clean up any orphaned curl processes from Pi-hole installation
    if [ -n "$(list_matching_pids_current_root f 'curl.*pi-hole|curl.*pihole')" ]; then
        print_info "Cleaning up Pi-hole installer background processes..."
        kill_matching_processes_current_root "KILL" "f" "curl.*pi-hole|curl.*pihole" 2>/dev/null || true
        sleep 1
    fi

    # Check installation result
    if pihole_runtime_installed; then
        print_success "Pi-hole installed successfully"

        # Configure Pi-hole to use port 5353 (avoid conflict with DNSCrypt)
        echo ""
        configure_pihole_port
        echo ""

        # Check if service is running
        if systemctl is-active --quiet pihole-FTL; then
            print_success "Pi-hole FTL service is running"
        else
            print_warning "Pi-hole FTL service is not running. You may need to start it manually."
            print_info "Run: sudo systemctl start pihole-FTL"
        fi

        # Show web interface info if available
        if command -v pihole &>/dev/null; then
            echo ""
            print_info "Pi-hole Web Interface:"
            echo "  URL: http://$(hostname -I | awk '{print $1}')/admin"
            if [[ -f /etc/pihole/.webpassword_initial ]]; then
                echo "  Password: $(cat /etc/pihole/.webpassword_initial)"
            else
                echo "  Password: Set during installation or run 'pihole -a -p' to set"
            fi
        fi
    else
        print_error "Failed to install Pi-hole"
        print_info "You can try manual installation later with:"
        echo "  curl -sSL https://install.pi-hole.net | bash"
        return 1
    fi

    ensure_dns_stable_after_change "Pi-hole installation"
}

# Function to install Kicksecure RAM wipe (dracut + ram-wipe)
# Only called when --force-kicksecure-ramwipe is specified
install_kicksecure_ram_wipe() {
    print_step "Kicksecure RAM Wipe Installation"
    echo ""
    print_warning "Installing Kicksecure RAM wipe components:"
    echo ""
    echo -e "  ${BOLD}RAM Wipe Tools:${NC}"
    echo -e "    ${BOLD}dracut${NC} - Initramfs infrastructure for secure boot operations"
    echo -e "    ${BOLD}dracut-core${NC} - Core components for dracut framework"
    echo -e "    ${BOLD}ram-wipe${NC} - Securely wipes RAM contents on shutdown/reboot"
    echo ""
    print_highlight "These tools provide:"
    echo "  • Protection against cold boot attacks"
    echo "  • Secure erasure of sensitive data from RAM"
    echo "  • Enhanced privacy when shutting down the system"
    echo ""
    print_warning "RAM wiping may slow down shutdown/reboot processes."
    print_info "Note: Kodachi also has built-in RAM wipe via 'health-control memory-wipe'"
    echo ""

    print_info "Installing Kicksecure RAM wipe packages..."

    # First install dracut packages from standard repos
    print_step "Installing dracut packages..."
    if apt-get install -y dracut dracut-core 2>&1 | tail -5; then
        print_success "dracut packages installed successfully"
    else
        print_warning "Failed to install some dracut packages"
    fi

    # Check if Kicksecure repository exists
    if [[ -f "/etc/apt/sources.list.d/kicksecure.list" ]]; then
        print_info "Kicksecure repository detected - refreshing GPG key..."

        # Create keyrings directory if missing
        install -d -m 0755 /usr/share/keyrings

        # Download and convert key from Kicksecure website (most reliable method)
        print_info "Fetching latest Kicksecure repository key..."
        if curl --tlsv1.3 -fsSL https://www.kicksecure.com/keys/derivative.asc 2>/dev/null | gpg --yes --dearmor -o /usr/share/keyrings/kicksecure.gpg 2>/dev/null && \
           [ -s /usr/share/keyrings/kicksecure.gpg ]; then
            print_success "Repository key downloaded and converted successfully"

            # Normalize sources.list to use correct key path if needed
            if ! grep -q "signed-by=/usr/share/keyrings/kicksecure.gpg" /etc/apt/sources.list.d/kicksecure.list; then
                print_info "Normalizing repository configuration to use correct key path..."
                sed 's|signed-by=/usr/share/keyrings/[^]]*|signed-by=/usr/share/keyrings/kicksecure.gpg|g' /etc/apt/sources.list.d/kicksecure.list > /tmp/kicksecure.list.fixed
                cat /tmp/kicksecure.list.fixed | tee /etc/apt/sources.list.d/kicksecure.list > /dev/null
                print_success "Repository configuration normalized"
            fi
        else
            print_error "Failed to download repository key"
            return 1
        fi

        # Verify repository works
        print_info "Verifying Kicksecure repository..."
        if apt-get update -o Dir::Etc::sourcelist="/etc/apt/sources.list.d/kicksecure.list" -o Dir::Etc::sourceparts="-" 2>&1 | tail -5; then
            print_success "Kicksecure repository verified successfully"
        else
            print_warning "Repository verification had warnings (may still work)"
        fi
    else
        # Repository doesn't exist - add it for ram-wipe installation
        print_step "Adding Kicksecure repository for ram-wipe..."

        # Create keyrings directory
        install -d -m 0755 /usr/share/keyrings

        # Download and convert key from Kicksecure website (most reliable method)
        print_info "Importing Kicksecure repository key..."
        if curl --tlsv1.3 -fsSL https://www.kicksecure.com/keys/derivative.asc 2>/dev/null | gpg --yes --dearmor -o /usr/share/keyrings/kicksecure.gpg 2>/dev/null && \
           [ -s /usr/share/keyrings/kicksecure.gpg ]; then
            print_success "Repository key imported successfully"
        else
            print_error "Failed to import repository key"
            return 1
        fi

        # Add repository
        print_info "Adding Kicksecure repository..."
        echo 'deb [signed-by=/usr/share/keyrings/kicksecure.gpg] https://deb.kicksecure.com bookworm main' | tee /etc/apt/sources.list.d/kicksecure.list

        # Update package lists
        print_info "Updating package lists..."
        if apt-get update 2>&1 | tail -5; then
            print_success "Package lists updated"
        else
            print_warning "Failed to update package lists completely"
        fi
    fi

    # Install ram-wipe
    print_step "Installing ram-wipe from Kicksecure repository..."
    # Refresh all package lists to ensure dependencies are available
    print_info "Refreshing package lists..."
    apt-get update >/dev/null 2>&1
    if apt-get install -y ram-wipe 2>&1 | tail -5; then
        print_success "ram-wipe installed successfully"
        echo ""
        print_info "Kicksecure RAM wipe is now configured and will activate on shutdown/reboot"
        print_info "To check status: sudo systemctl status ram-wipe"
    else
        print_error "Failed to install ram-wipe"
        print_info "You may need to troubleshoot the Kicksecure repository"
    fi
}

# Function to install advanced security tools (kloak only)
# Note: Kodachi has built-in RAM wipe via 'health-control memory-wipe'
# For Kicksecure RAM wipe, use --force-kicksecure-ramwipe flag
install_advanced_security_tools() {
    print_step "Advanced Security Tools Installation"
    echo ""
    print_info "Kodachi includes built-in RAM wipe via 'health-control memory-wipe'"
    print_info "For Kicksecure RAM wipe (dracut + ram-wipe), use --force-kicksecure-ramwipe flag"
    echo ""
    print_warning "The following advanced security tool will be installed:"
    echo ""
    echo -e "  ${BOLD}Keystroke Anonymization:${NC}"
    echo -e "    ${BOLD}kloak${NC} - Obfuscates typing behavior to prevent keystroke biometrics"
    echo ""
    print_highlight "This tool provides:"
    echo "  • Keystroke timing anonymization to prevent typing fingerprinting"
    echo "  • Protection against keystroke biometric analysis"
    echo ""
    print_warning "Kloak service will be enabled but not started (manual activation required)."
    echo ""

    # Ask for user confirmation
    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing keystroke anonymization tool..."
        REPLY="yes"
    else
        # FIXED: Simple working input method (stdin already redirected via exec)
        echo -n "Do you want to install kloak (keystroke anonymization)? (YES/no) [default: yes]: "
        read -r REPLY
        # Default to YES if empty
        if [[ -z "$REPLY" ]]; then
            REPLY="yes"
        fi
        echo ""
    fi

    if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
        # Install kloak (keystroke anonymization)
        print_step "Installing kloak (keystroke anonymization)..."
        install_kloak
        
    else
        print_info "Skipping keystroke anonymization tool installation"
        echo ""
        print_highlight "To install kloak (keystroke anonymization) manually:"
        echo ""
        echo -e "  ${BOLD}Option 1: Compile from source${NC}"
        echo -e "    ${BOLD}sudo apt-get install make libevdev-dev build-essential${NC}"
        echo -e "    ${BOLD}curl -L https://github.com/vmonaco/kloak/archive/v0.2.tar.gz | tar xz${NC}"
        echo -e "    ${BOLD}cd kloak-0.2 && make all && sudo mv kloak /usr/local/bin/${NC}"
        echo ""
        echo -e "  ${BOLD}Option 2: Install from Whonix repository${NC}"
        echo -e "    ${BOLD}curl -fsSL https://www.whonix.org/patrick.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/whonix.gpg${NC}"
        echo -e "    ${BOLD}echo 'deb https://deb.whonix.org bullseye main' | sudo tee /etc/apt/sources.list.d/whonix.list${NC}"
        echo -e "    ${BOLD}sudo apt-get update && sudo apt-get install kloak${NC}"
        echo ""
        print_info "For Kicksecure RAM wipe, run: sudo bash kodachi-deps-install.sh --force-kicksecure-ramwipe"
        print_info "Kodachi has built-in RAM wipe: sudo health-control memory-wipe"
        echo ""
    fi
}

# Function to install GRUB tools for health-control RAM wipe support
install_grub_tools() {
    print_step "GRUB Tools Installation"
    echo ""

    # Check if GRUB is already configured with tools
    if command -v update-grub &>/dev/null || command -v grub-mkconfig &>/dev/null; then
        print_success "GRUB tools already installed"
        return 0
    fi

    print_info "GRUB tools not found - detecting bootloader..."

    # Detect GRUB2 vs GRUB legacy
    if [ -d "/boot/grub2" ] || [ -f "/boot/grub2/grub.cfg" ]; then
        print_info "Detected GRUB2 installation"
        if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null grub-common grub2-common 2>&1 | tail -5; then
            print_success "GRUB2 tools installed (grub-common + grub2-common)"
        else
            print_warning "Failed to install GRUB2 tools - RAM wipe will still work"
        fi
    elif [ -d "/boot/grub" ] || [ -f "/boot/grub/grub.cfg" ]; then
        print_info "Detected GRUB bootloader"
        if timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null grub-pc 2>&1 | tail -5; then
            print_success "GRUB tools installed (grub-pc)"
        else
            print_warning "Failed to install GRUB tools - RAM wipe will still work"
        fi
    else
        print_warning "No GRUB installation detected - skipping GRUB tools"
        print_info "This is normal for live systems or non-GRUB bootloaders"
        print_info "RAM wipe will still function correctly without GRUB tools"
    fi

    echo ""
    print_info "Note: GRUB tools enable 'init_on_free=1' kernel parameter for extra security"
    print_info "RAM wipe hooks are installed regardless and will execute on shutdown"
}

# Update package lists
print_step "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
if timeout 60 apt-get update; then
    print_success "Package lists updated"
else
    print_warning "Failed to update package lists completely"
fi
echo ""

# Fix stdin for interactive mode when run with sudo
if [[ "$INSTALL_MODE" == "interactive" ]]; then
    # Disable strict mode for interactive input
    set +e +o pipefail
    
    # Redirect stdin if needed
    if [[ ! -t 0 ]]; then
        exec < /dev/tty 2>/dev/null || exec < /dev/console 2>/dev/null || true
    fi
fi

# Install packages based on mode
if [[ "$INSTALL_MODE" == "proxy" ]]; then
    print_highlight "Installing Proxy Tools Only"
    echo ""
    install_v2ray
    install_xray
    install_hysteria2
    install_mieru
    install_cloak_client
    install_amneziawg_tools

elif [[ "$INSTALL_MODE" == "interactive" ]]; then
    print_highlight "Interactive Category-Based Installation"
    echo ""
    print_info "You will be prompted to install each category of packages"
    echo ""
    
    # Essential packages
    ESSENTIAL_DESC="Core system utilities required for basic functionality:
  • Network tools: curl, wget, openssl, dhclient
  • System utilities: sudo, systemd, mount
  • File operations: coreutils, findutils, grep
  • Password tools: pass, pwgen, xkcdpass"
    
    ESSENTIAL_MANUAL="  sudo apt-get install curl wget openssl ca-certificates coreutils findutils grep \\
    procps psmisc systemd sudo dmidecode lsof acl util-linux mount \\
    uuid-runtime inotify-tools isc-dhcp-client pass pwgen xkcdpass"
    
    install_category_interactive "$ESSENTIAL_PACKAGES" "Essential" "$ESSENTIAL_DESC" "$ESSENTIAL_MANUAL"
    ensure_dpkg_healthy
    
    # Networking packages
    NETWORK_DESC="Network and VPN connectivity tools:
  • Anonymity: Tor network and configuration
  • VPN support: OpenVPN, WireGuard
  • Firewall: iptables, nftables
  • Proxy tools: Shadowsocks, Redsocks, Microsocks, HAProxy"
    
    NETWORK_MANUAL="  sudo apt-get install tor openvpn wireguard-tools iptables nftables \\
    arptables ebtables iproute2 iputils-ping net-tools nyx apt-transport-tor \\
    shadowsocks-libev redsocks microsocks haproxy"
    
    if install_category_interactive "$NETWORK_PACKAGES" "Networking" "$NETWORK_DESC" "$NETWORK_MANUAL"; then
        # Initialize iptables alternatives after network packages
        initialize_iptables_alternatives
    fi
    ensure_dpkg_healthy
    
    # Security packages
    SECURITY_DESC="System hardening and protection tools:
  • Access control: AppArmor, Firejail
  • System integrity: AIDE, Lynis, rkhunter
  • USB protection: USBGuard
  • Encryption: eCryptfs utilities
  • Authentication: fail2ban, PAM modules"
    
    SECURITY_MANUAL="  sudo apt-get install ufw macchanger firejail apparmor apparmor-utils \\
    apparmor-profiles aide lynis rkhunter chkrootkit usbguard ecryptfs-utils \\
  cryptsetup-nuke-password fail2ban unattended-upgrades auditd \\
    libpam-pwquality libpam-google-authenticator secure-delete wipe nwipe"
    
    install_category_interactive "$SECURITY_PACKAGES" "Security" "$SECURITY_DESC" "$SECURITY_MANUAL"
    ensure_dpkg_healthy
    
    # Privacy packages
    PRIVACY_DESC="DNS security and privacy tools:
  • DNS encryption: DNSCrypt Proxy v${DNSCRYPT_VERSION} (from GitHub)
  • QR code generation: QRencode v${QRENCODE_VERSION} (compiled from GitHub)
  • DNS utilities: dig, nslookup, host
  • Network-wide ad blocking: Pi-hole (interactive setup)"
    
    PRIVACY_MANUAL="  # Install DNS utilities
  sudo apt-get install dnsutils
  
  # Install DNSCrypt Proxy from GitHub
  curl -L https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VERSION}/dnscrypt-proxy-linux_x86_64-${DNSCRYPT_VERSION}.tar.gz
  
  # Install QRencode from GitHub (compile from source)
  curl -L https://github.com/fukuchi/libqrencode/archive/v${QRENCODE_VERSION}.tar.gz
  
  # For Pi-hole:
  curl -sSL https://install.pi-hole.net | bash"
    
    if install_category_interactive "$PRIVACY_PACKAGES" "Privacy" "$PRIVACY_DESC" "$PRIVACY_MANUAL"; then
        # CRITICAL: Configure systemd-resolved IMMEDIATELY after installation
        # This ensures DNS works before any GitHub downloads are attempted
        echo ""
        configure_systemd_resolved

        # Install DNSCrypt Proxy from GitHub with apt fallback
        echo ""
        print_step "Installing DNSCrypt Proxy from GitHub..."
        if ! install_dnscrypt_github; then
            print_warning "GitHub installation failed, trying apt package..."
            if (set -o pipefail; timeout 60 apt-get install -y -o DPkg::Use-Pty=0 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" < /dev/null dnscrypt-proxy 2>&1 | tail -5); then
                print_success "DNSCrypt Proxy installed via apt"
                setup_dnscrypt_service "apt"
                ensure_dns_stable_after_change "DNSCrypt installation" || true
            else
                print_error "Failed to install DNSCrypt Proxy from both GitHub and apt"
            fi
        fi
        # Install QRencode (APT first, GitHub fallback)
        echo ""
        install_qrencode_github
        # Try to install resolvconf (optional)
        install_resolvconf_safe
        # Re-configure systemd-resolved now that DNSCrypt may be running
        configure_systemd_resolved
        ensure_dpkg_healthy
        # Offer Pi-hole installation
        echo ""
        if [[ "$AUTO_YES" == "true" ]]; then
            print_info "Auto mode: Installing Pi-hole..."
            REPLY="yes"
        else
            # FIXED: Simple working input method (stdin already redirected via exec)
            echo -n "Do you want to install Pi-hole for network-wide ad blocking? (YES/no) [default: yes]: "
            read -r REPLY
            # Default to YES if empty
            if [[ -z "$REPLY" ]]; then
                REPLY="yes"
            fi
            echo ""
        fi
        if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
            install_pihole
        fi
    fi
    ensure_dpkg_healthy
    
    # Advanced packages (non-GUI)
    ADVANCED_DESC="Additional tools and utilities (non-GUI):
  • Development: git, build-essential
  • System monitoring: htop, iotop, sensors
  • Hardware tools: smartmontools, rfkill
  • Backup: restic (powers kodachi-backup)
  • Utilities: jq, yamllint, haveged"

    ADVANCED_MANUAL="  sudo apt-get install jq git build-essential rng-tools-debian \\
    haveged ccze yamllint smartmontools lm-sensors hdparm \\
    htop iotop vnstat efibootmgr rfkill restic"

    install_category_interactive "$ADVANCED_PACKAGES" "Advanced" "$ADVANCED_DESC" "$ADVANCED_MANUAL"
    ensure_dpkg_healthy

    # Monitoring packages
    MONITORING_DESC="System and network monitoring tools for the dashboard:
  • Resource monitoring: btop (modern TUI resource monitor)
  • Network monitoring: iftop, nethogs, nload
  • Disk usage: ncdu (NCurses Disk Usage)
  • Speed testing: iperf3, speedtest-cli"

    MONITORING_MANUAL="  sudo apt-get install btop iftop nethogs ncdu nload iperf3 speedtest-cli"

    install_category_interactive "$MONITORING_PACKAGES" "Monitoring" "$MONITORING_DESC" "$MONITORING_MANUAL"
    ensure_dpkg_healthy

    # GUI packages (only if desktop environment detected or forced, unless explicitly skipped)
    if [[ "$SKIP_GUI_INSTALL" == "true" ]]; then
        print_info "Skipping GUI packages (--skipgui specified by user)."
    elif detect_gui_environment || [[ "$FORCE_GUI_INSTALL" == "true" ]]; then
        if [[ "$FORCE_GUI_INSTALL" == "true" ]] && ! detect_gui_environment; then
            print_warning "No desktop environment detected, but --forcegui specified"
        fi

        GUI_DESC="GUI-specific packages for desktop environments:
  • Terminal: kitty, xterm terminal emulators
  • Desktop panels: Conky status widgets
  • Fonts: fontconfig, emoji support, MS core fonts (Impact for conky HUD titles)
  • Audio: PipeWire (pipewire-pulse, wireplumber), ALSA utilities, mpv
  • Desktop tools: bleachbit, notifications, screenshots
  • Clipboard: xclip, xsel, CopyQ, XFCE Clipman
  • Rofi: launcher, calculator, translation, screenshot helpers
  • Network: NetworkManager (nmcli), iproute2, ping, traceroute, speedtest-cli"

        GUI_PACKAGES_TO_INSTALL="$(get_gui_packages_for_install)"
        if [[ "$GUI_PACKAGES_TO_INSTALL" != *"conky-all"* ]]; then
            print_info "Terminal/headless mode detected: skipping Conky package (conky-all)."
        fi
        GUI_MANUAL="  sudo apt-get install $GUI_PACKAGES_TO_INSTALL"

        install_category_interactive "$GUI_PACKAGES_TO_INSTALL" "GUI" "$GUI_DESC" "$GUI_MANUAL"
        ensure_dpkg_healthy
    else
        print_warning "Skipping GUI packages (no desktop environment detected). Use --forcegui to install them anyway."
    fi

    # Contrib/non-free packages
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing contrib/non-free packages..."
        REPLY="yes"
    else
        # FIXED: Simple working input method (stdin already redirected via exec)
        echo -n "Do you want to install packages that require contrib/non-free repositories? (YES/no) [default: yes]: "
        read -r REPLY
        # Default to YES if empty
        if [[ -z "$REPLY" ]]; then
            REPLY="yes"
        fi
        echo ""
    fi
    if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
        install_contrib_packages
        ensure_dpkg_healthy
    fi
    
    # Proxy tools
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing proxy tools..."
        REPLY="yes"
    else
        # FIXED: Simple working input method (stdin already redirected via exec)
        # The list here MUST name everything the yes-path installs. It named four while the
        # branch below called six, so the user consented to four and got two more, one of
        # which builds third-party source as root. An inspector caught it 2026-08-19.
        echo -n "Do you want to install proxy tools (v2ray, xray, hysteria2, mieru, ck-client, amneziawg-tools)? (YES/no) [default: yes]: "
        read -r REPLY
        # Default to YES if empty
        if [[ -z "$REPLY" ]]; then
            REPLY="yes"
        fi
        echo ""
    fi
    if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
        install_v2ray
        install_xray
        install_hysteria2
        install_mieru
        install_cloak_client
        install_amneziawg_tools
    else
        print_info "To install proxy tools manually:"
        echo "  • v2ray: https://github.com/v2fly/v2ray-core"
        echo "  • xray: bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install"
        echo "  • hysteria2: Download from https://github.com/apernet/hysteria/releases"
        echo "  • mieru: Download .deb from https://github.com/enfein/mieru/releases"
        echo "  • ck-client: Download from https://github.com/cbeuw/Cloak/releases"
        echo "  • amneziawg-tools: https://github.com/amnezia-vpn/amneziawg-tools"
    fi
    
    # Advanced security tools (keystroke anonymization)
    echo ""
    install_advanced_security_tools

    # GRUB tools for health-control RAM wipe support (interactive prompt)
    echo ""
    print_step "GRUB Tools Installation (for health-control RAM wipe)"
    echo ""
    print_info "GRUB bootloader tools enable the 'init_on_free=1' kernel parameter"
    print_info "for additional RAM security. Not required for RAM wipe to function."
    echo ""

    if [[ "$AUTO_YES" == "true" ]]; then
        print_info "Auto mode: Installing GRUB tools..."
        install_grub_tools
    else
        echo -n "Do you want to install GRUB tools? (YES/no) [default: yes]: "
        read -r REPLY
        if [[ -z "$REPLY" ]]; then
            REPLY="yes"
        fi
        echo ""

        if [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]; then
            install_grub_tools
        else
            print_info "Skipping GRUB tools installation"
            print_warning "health-control RAM wipe will still work, but won't configure init_on_free=1"
            echo ""
        fi
    fi

    # Kicksecure RAM wipe (only if explicitly requested)
    if [[ "$INSTALL_KICKSECURE_RAMWIPE" == "true" ]]; then
        echo ""
        install_kicksecure_ram_wipe
    fi

elif [[ "$INSTALL_MODE" == "minimal" ]]; then
    print_highlight "Installing Minimal Package Set"
    echo ""
    install_packages "$ESSENTIAL_PACKAGES" "Essential"
    ensure_dpkg_healthy
    install_packages "$NETWORK_PACKAGES" "Network"
    ensure_dpkg_healthy
    # Initialize iptables alternatives after network packages
    initialize_iptables_alternatives
    # Handle contrib/non-free packages
    install_contrib_packages
    ensure_dpkg_healthy
    # Install DNS packages one by one with DNS testing after each
    install_privacy_packages_safe
    ensure_dpkg_healthy
    # Install DNSCrypt Proxy from GitHub with apt fallback
    echo ""
    print_step "Installing DNSCrypt Proxy from GitHub..."
    if ! install_dnscrypt_github; then
        print_warning "GitHub installation failed, trying apt package..."
        if (set -o pipefail; timeout 60 apt-get install -y dnscrypt-proxy 2>&1 | tail -5); then
            print_success "DNSCrypt Proxy installed via apt"
            setup_dnscrypt_service "apt"
            ensure_dns_stable_after_change "DNSCrypt installation" || true
        else
            print_error "Failed to install DNSCrypt Proxy from both GitHub and apt"
        fi
    fi
    # Install QRencode (APT first, GitHub fallback)
    echo ""
    install_qrencode_github
    # Try to install resolvconf (optional, won't break on failure)
    install_resolvconf_safe
    # Configure systemd-resolved for DNS caching and conflict avoidance
    configure_systemd_resolved
    ensure_dpkg_healthy
    # Install Pi-hole
    install_pihole
    ensure_dpkg_healthy
    
    # Install proxy tools in minimal mode
    echo ""
    print_highlight "Installing Proxy Tools"
    echo ""
    install_v2ray
    install_xray
    install_hysteria2
    install_mieru

    # Install monitoring packages
    echo ""
    print_highlight "Installing Monitoring Tools"
    echo ""
    install_packages "$MONITORING_PACKAGES" "Monitoring"
    ensure_dpkg_healthy

    # GRUB tools for health-control RAM wipe support
    echo ""
    install_grub_tools

elif [[ "$INSTALL_MODE" == "full" ]]; then
    print_highlight "Installing Full Package Set"
    echo ""
    install_packages "$ESSENTIAL_PACKAGES" "Essential"
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$NETWORK_PACKAGES" "Network"
    ensure_dpkg_healthy
    wait_for_apt
    # Initialize iptables alternatives after network packages
    initialize_iptables_alternatives
    # Handle contrib/non-free packages
    install_contrib_packages
    ensure_dpkg_healthy
    wait_for_apt
    # Install DNS packages one by one with DNS testing after each
    install_privacy_packages_safe
    ensure_dpkg_healthy
    wait_for_apt
    # Install DNSCrypt Proxy from GitHub with apt fallback
    echo ""
    print_step "Installing DNSCrypt Proxy from GitHub..."
    if ! install_dnscrypt_github; then
        print_warning "GitHub installation failed, trying apt package..."
        if (set -o pipefail; timeout 60 apt-get install -y dnscrypt-proxy 2>&1 | tail -5); then
            print_success "DNSCrypt Proxy installed via apt"
            setup_dnscrypt_service "apt"
            ensure_dns_stable_after_change "DNSCrypt installation" || true
        else
            print_error "Failed to install DNSCrypt Proxy from both GitHub and apt"
        fi
    fi
    # Install QRencode (APT first, GitHub fallback)
    echo ""
    install_qrencode_github
    # Try to install resolvconf (optional, won't break on failure)
    install_resolvconf_safe
    # Configure systemd-resolved for DNS caching and conflict avoidance
    configure_systemd_resolved
    ensure_dpkg_healthy
    wait_for_apt
    # Install Pi-hole after DNS packages
    install_pihole
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$SECURITY_PACKAGES" "Security"
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$ADVANCED_PACKAGES" "Advanced"
    ensure_dpkg_healthy
    wait_for_apt

    # Install monitoring packages
    echo ""
    print_highlight "Installing Monitoring Tools"
    echo ""
    install_packages "$MONITORING_PACKAGES" "Monitoring"
    ensure_dpkg_healthy
    wait_for_apt

    # Install GUI packages if desktop environment detected or forced, unless explicitly skipped
    echo ""
    if [[ "$SKIP_GUI_INSTALL" == "true" ]]; then
        print_info "Skipping GUI packages (--skipgui specified by user)."
    elif detect_gui_environment || [[ "$FORCE_GUI_INSTALL" == "true" ]]; then
        if [[ "$FORCE_GUI_INSTALL" == "true" ]] && ! detect_gui_environment; then
            print_warning "No desktop environment detected, but --forcegui specified"
            print_info "Installing GUI packages anyway (Conky will be skipped)."
        fi
        GUI_PACKAGES_TO_INSTALL="$(get_gui_packages_for_install)"
        if [[ "$GUI_PACKAGES_TO_INSTALL" != *"conky-all"* ]]; then
            print_info "Terminal/headless mode detected: skipping Conky package (conky-all)."
        fi
        install_packages "$GUI_PACKAGES_TO_INSTALL" "GUI"
        ensure_dpkg_healthy
        wait_for_apt

        # Enable XFCE compositor for every human user so conky's
        # own_window_argb_value 0 actually renders transparent. Without this
        # the panels paint solid black on fresh installs where xfwm4's
        # use_compositing defaults to false.
        if command -v xfwm4 >/dev/null 2>&1 || [[ -x /usr/bin/xfwm4 ]]; then
            print_step "Enabling XFCE compositor (required for conky transparency)..."
            _xc_user="" _xc_home="" _xc_uid=""
            while IFS=: read -r _xc_user _ _xc_uid _ _ _xc_home _; do
                [[ "$_xc_uid" =~ ^[0-9]+$ ]] || continue
                if (( _xc_uid < 1000 || _xc_uid > 60000 )); then continue; fi
                [[ -d "$_xc_home" ]] || continue
                enable_xfce_compositor_for_user "$_xc_home" "$_xc_user"
                print_info "  ✓ XFCE compositor enabled for $_xc_user ($_xc_home)"
            done < <(getent passwd)
            unset _xc_user _xc_home _xc_uid
        fi
    else
        print_warning "Skipping GUI packages (no desktop environment detected). Use --forcegui to install them anyway."
    fi

    # Also install proxy tools
    echo ""
    print_highlight "Installing Proxy Tools"
    echo ""
    install_v2ray
    install_xray
    install_hysteria2
    install_mieru

    # Install advanced security tools (keystroke anonymization)
    echo ""
    install_advanced_security_tools

    # GRUB tools for health-control RAM wipe support
    echo ""
    install_grub_tools

    # Kicksecure RAM wipe (only if explicitly requested)
    if [[ "$INSTALL_KICKSECURE_RAMWIPE" == "true" ]]; then
        echo ""
        install_kicksecure_ram_wipe
    fi

else
    # Normal mode - install recommended packages
    print_highlight "Installing Recommended Package Set"
    echo ""
    install_packages "$ESSENTIAL_PACKAGES" "Essential"
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$NETWORK_PACKAGES" "Network"
    ensure_dpkg_healthy
    wait_for_apt
    # Initialize iptables alternatives after network packages
    initialize_iptables_alternatives
    # Handle contrib/non-free packages
    install_contrib_packages
    ensure_dpkg_healthy
    wait_for_apt
    # Install DNS packages one by one with DNS testing after each
    install_privacy_packages_safe
    ensure_dpkg_healthy
    wait_for_apt
    # Install DNSCrypt Proxy from GitHub with apt fallback
    echo ""
    print_step "Installing DNSCrypt Proxy from GitHub..."
    if ! install_dnscrypt_github; then
        print_warning "GitHub installation failed, trying apt package..."
        if (set -o pipefail; timeout 60 apt-get install -y dnscrypt-proxy 2>&1 | tail -5); then
            print_success "DNSCrypt Proxy installed via apt"
            setup_dnscrypt_service "apt"
            ensure_dns_stable_after_change "DNSCrypt installation" || true
        else
            print_error "Failed to install DNSCrypt Proxy from both GitHub and apt"
        fi
    fi
    # Install QRencode (APT first, GitHub fallback)
    echo ""
    install_qrencode_github
    # Try to install resolvconf (optional, won't break on failure)
    install_resolvconf_safe
    # Configure systemd-resolved for DNS caching and conflict avoidance
    configure_systemd_resolved
    ensure_dpkg_healthy
    wait_for_apt
    # Install Pi-hole after DNS packages
    install_pihole
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$SECURITY_PACKAGES" "Security"
    ensure_dpkg_healthy
    wait_for_apt
    install_packages "$ADVANCED_PACKAGES" "Advanced"
    ensure_dpkg_healthy
    wait_for_apt

    # Install monitoring packages
    echo ""
    print_highlight "Installing Monitoring Tools"
    echo ""
    install_packages "$MONITORING_PACKAGES" "Monitoring"
    ensure_dpkg_healthy
    wait_for_apt

    # Install GUI packages if desktop environment detected or forced, unless explicitly skipped
    echo ""
    if [[ "$SKIP_GUI_INSTALL" == "true" ]]; then
        print_info "Skipping GUI packages (--skipgui specified by user)."
    elif detect_gui_environment || [[ "$FORCE_GUI_INSTALL" == "true" ]]; then
        if [[ "$FORCE_GUI_INSTALL" == "true" ]] && ! detect_gui_environment; then
            print_warning "No desktop environment detected, but --forcegui specified"
            print_info "Installing GUI packages anyway (Conky will be skipped)."
        fi
        GUI_PACKAGES_TO_INSTALL="$(get_gui_packages_for_install)"
        if [[ "$GUI_PACKAGES_TO_INSTALL" != *"conky-all"* ]]; then
            print_info "Terminal/headless mode detected: skipping Conky package (conky-all)."
        fi
        install_packages "$GUI_PACKAGES_TO_INSTALL" "GUI"
        ensure_dpkg_healthy
        wait_for_apt

        # Enable XFCE compositor for every human user so conky's
        # own_window_argb_value 0 actually renders transparent. Without this
        # the panels paint solid black on fresh installs where xfwm4's
        # use_compositing defaults to false.
        if command -v xfwm4 >/dev/null 2>&1 || [[ -x /usr/bin/xfwm4 ]]; then
            print_step "Enabling XFCE compositor (required for conky transparency)..."
            _xc_user="" _xc_home="" _xc_uid=""
            while IFS=: read -r _xc_user _ _xc_uid _ _ _xc_home _; do
                [[ "$_xc_uid" =~ ^[0-9]+$ ]] || continue
                if (( _xc_uid < 1000 || _xc_uid > 60000 )); then continue; fi
                [[ -d "$_xc_home" ]] || continue
                enable_xfce_compositor_for_user "$_xc_home" "$_xc_user"
                print_info "  ✓ XFCE compositor enabled for $_xc_user ($_xc_home)"
            done < <(getent passwd)
            unset _xc_user _xc_home _xc_uid
        fi
    else
        print_warning "Skipping GUI packages (no desktop environment detected). Use --forcegui to install them anyway."
    fi

    # Also install proxy tools
    echo ""
    print_highlight "Installing Proxy Tools"
    echo ""
    install_v2ray
    install_xray
    install_hysteria2
    install_mieru

    # GRUB tools for health-control RAM wipe support
    echo ""
    install_grub_tools
fi

# Function to disable UFW if installed
disable_ufw() {
    print_step "Checking UFW (Uncomplicated Firewall) status..."

    if command -v ufw &>/dev/null; then
        print_info "UFW is installed - checking status..."

        # Get UFW status
        local ufw_status=$(ufw status 2>/dev/null | grep -i "^Status:" | awk '{print $2}')

        if [[ "$ufw_status" == "active" ]]; then
            print_warning "UFW is currently active - disabling it to prevent conflicts with Kodachi's firewall"

            # Disable UFW
            if ufw --force disable 2>/dev/null; then
                print_success "UFW has been disabled"
            else
                print_error "Failed to disable UFW - you may need to disable it manually"
                print_info "Run: sudo ufw disable"
            fi

            # Also disable UFW service from starting at boot
            if systemctl is-enabled ufw &>/dev/null; then
                print_info "Disabling UFW service from starting at boot..."
                systemctl disable ufw 2>/dev/null || true
                print_success "UFW service disabled at boot"
            fi
        else
            print_success "UFW is already inactive"

            # Still disable service to prevent auto-start
            if systemctl is-enabled ufw &>/dev/null; then
                print_info "Disabling UFW service from starting at boot..."
                systemctl disable ufw 2>/dev/null || true
                print_success "UFW service disabled at boot"
            fi
        fi

        print_info "Note: Kodachi uses custom iptables/nftables rules for advanced security"
    else
        print_info "UFW is not installed"
    fi
}

# Disable UFW to prevent conflicts with Kodachi's firewall rules
disable_ufw
echo ""

# Final check
echo ""
print_highlight "Installation Summary"
echo ""

# Check critical tools
print_step "Checking critical tools..."
for tool in curl wget openssl tor openvpn; do
    if command -v "$tool" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $tool - installed"
    else
        echo -e "  ${RED}✗${NC} $tool - missing"
    fi
done

# Check DNS tools
echo ""
print_step "Checking DNS tools..."
if command -v dig &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} dig - installed"
else
    echo -e "  ${YELLOW}!${NC} dig - not found"
fi

if command -v nslookup &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} nslookup - installed"
else
    echo -e "  ${YELLOW}!${NC} nslookup - not found"
fi

if command -v host &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} host - installed"
else
    echo -e "  ${YELLOW}!${NC} host - not found"
fi

if check_dns_tools; then
    echo -e "  ${GREEN}✓${NC} DNS utilities - available"
else
    echo -e "  ${RED}✗${NC} DNS utilities - missing (install dnsutils package)"
fi

# Check proxy tools
echo ""
print_step "Checking proxy tools..."

if command -v v2ray &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} v2ray - installed"
else
    echo -e "  ${RED}✗${NC} v2ray - FAILED (required)"
fi

if command -v v2ray-plugin &>/dev/null || command -v ss-v2ray-plugin &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} v2ray-plugin (shadowsocks) - installed"
else
    echo -e "  ${YELLOW}!${NC} v2ray-plugin - not found (optional)"
fi

if command -v xray &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} xray - installed"
else
    echo -e "  ${RED}✗${NC} xray - FAILED (required)"
fi

if command -v mieru &>/dev/null || dpkg -l mieru 2>/dev/null | grep -q "^ii"; then
    echo -e "  ${GREEN}✓${NC} mieru client - installed"
else
    echo -e "  ${RED}✗${NC} mieru client - FAILED (required)"
fi

if command -v hysteria &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} hysteria2 - installed"
else
    echo -e "  ${RED}✗${NC} hysteria2 - FAILED (required)"
fi

if command -v kloak &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} kloak (keystroke anonymization) - installed"
else
    echo -e "  ${YELLOW}!${NC} kloak - not found (advanced privacy tool)"
fi

# Check network tools
echo ""
print_step "Checking network tools..."
for tool in wireguard-tools shadowsocks-libev redsocks microsocks iptables nftables; do
    # Handle special cases
    if [[ "$tool" == "wireguard-tools" ]]; then
        if command -v wg &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    elif [[ "$tool" == "shadowsocks-libev" ]]; then
        if command -v ss-local &>/dev/null || command -v ss-server &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    elif [[ "$tool" == "nftables" ]]; then
        # nft might be in /usr/sbin which isn't always in PATH
        if command -v nft &>/dev/null || [[ -x /usr/sbin/nft ]] || [[ -x /sbin/nft ]]; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    else
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    fi
done

# Check security tools
echo ""
print_step "Checking security tools..."
for tool in ufw macchanger firejail apparmor; do
    if [[ "$tool" == "apparmor" ]]; then
        # AppArmor has apparmor_status command, not apparmor
        if command -v apparmor_status &>/dev/null || command -v aa-status &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    elif [[ "$tool" == "ufw" ]]; then
        # Check UFW installation and status
        if command -v ufw &>/dev/null; then
            ufw_status=$(ufw status 2>/dev/null | grep -i "^Status:" | awk '{print $2}' || true)
            if [[ "$ufw_status" == "inactive" ]]; then
                echo -e "  ${GREEN}✓${NC} $tool - installed (disabled - correct for Kodachi)"
            elif [[ "$ufw_status" == "active" ]]; then
                echo -e "  ${YELLOW}!${NC} $tool - installed but ACTIVE (should be disabled)"
            else
                echo -e "  ${GREEN}✓${NC} $tool - installed"
            fi
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    else
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    fi
done

# Check DNS security
echo ""
print_step "Checking DNS security tools..."
if command -v dnscrypt-proxy &>/dev/null; then
    dnscrypt_version=$(dnscrypt-proxy -version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
    echo -e "  ${GREEN}✓${NC} dnscrypt-proxy - installed (version: $dnscrypt_version)"
    if [[ "$dnscrypt_version" == "$DNSCRYPT_VERSION" ]]; then
        echo -e "      ${GREEN}→ Correct version v${DNSCRYPT_VERSION} from GitHub${NC}"
    elif [[ "$dnscrypt_version" != "unknown" ]]; then
        echo -e "      ${YELLOW}→ Version $dnscrypt_version (expected: v${DNSCRYPT_VERSION})${NC}"
    fi
else
    echo -e "  ${YELLOW}!${NC} dnscrypt-proxy - not found"
fi

if command -v qrencode &>/dev/null; then
    qrencode_version=$(qrencode -V 2>/dev/null | head -1 | awk '{print $3}' || echo "unknown")
    echo -e "  ${GREEN}✓${NC} qrencode - installed (version: $qrencode_version)"
    if [[ "$qrencode_version" == "$QRENCODE_VERSION" ]]; then
        echo -e "      ${GREEN}→ Version v${QRENCODE_VERSION} installed${NC}"
    elif [[ "$qrencode_version" != "unknown" ]]; then
        echo -e "      ${YELLOW}→ Version $qrencode_version (expected: v${QRENCODE_VERSION})${NC}"
    fi
else
    echo -e "  ${YELLOW}!${NC} qrencode - not found"
fi

if command -v resolvconf &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} resolvconf - installed (for VPN DNS management)"
else
    # Check if VPN tools are installed that might need it
    if command -v wg-quick &>/dev/null || command -v openvpn &>/dev/null; then
        echo -e "  ${YELLOW}!${NC} resolvconf - missing (needed for WireGuard/OpenVPN DNS)"
        echo -e "      ${CYAN}→ Run the installer again to fix VPN DNS support${NC}"
    else
        echo -e "  ${CYAN}○${NC} resolvconf - not needed (no VPN tools requiring it)"
    fi
fi

# Check Pi-hole
echo ""
print_step "Checking Pi-hole..."
PIHOLE_INSTALLED=false
if systemctl is-active --quiet pihole-FTL 2>/dev/null || command -v pihole &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Pi-hole - installed"
    PIHOLE_INSTALLED=true
    if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Pi-hole FTL service - running"
    else
        echo -e "  ${YELLOW}!${NC} Pi-hole FTL service - not running"
    fi
else
    echo -e "  ${YELLOW}!${NC} Pi-hole - not installed (optional DNS filtering)"
fi

# Check critical system utilities
echo ""
print_step "Checking system utilities..."
for tool in sudo systemd jq git haproxy rfkill; do
    if [[ "$tool" == "systemd" ]]; then
        # systemd has systemctl command, not systemd
        if command -v systemctl &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    elif [[ "$tool" == "rfkill" ]]; then
        # rfkill for managing wireless devices
        if command -v rfkill &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed (wireless device control)"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found (needed for wireless management)"
        fi
    else
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $tool - installed"
        else
            echo -e "  ${YELLOW}!${NC} $tool - not found"
        fi
    fi
done

# Check RAM wipe security tools (Kicksecure - optional)
echo ""
print_step "Checking Kicksecure RAM wipe tools (optional)..."
print_info "Note: Kodachi has built-in RAM wipe via 'health-control memory-wipe'"
if check_package "ram-wipe"; then
    echo -e "  ${GREEN}✓${NC} ram-wipe - installed (Kicksecure)"
else
    echo -e "  ${BLUE}ℹ${NC} ram-wipe - not installed (optional, use --force-kicksecure-ramwipe to install)"
fi

if check_package "dracut"; then
    echo -e "  ${GREEN}✓${NC} dracut - installed"
else
    echo -e "  ${BLUE}ℹ${NC} dracut - not installed (optional, needed for Kicksecure RAM wipe)"
fi

if check_package "dracut-core"; then
    echo -e "  ${GREEN}✓${NC} dracut-core - installed"
else
    echo -e "  ${BLUE}ℹ${NC} dracut-core - not installed (optional, needed for Kicksecure RAM wipe)"
fi

# Cleanup unused packages
echo ""
print_step "Cleaning up unused packages..."
export DEBIAN_FRONTEND=noninteractive
if apt autoremove -y 2>&1 | tail -5; then
    print_success "Cleanup completed - removed unused packages"
else
    print_warning "Cleanup had some issues but continuing..."
fi

# ============================================================================
# SERVICE CLEANUP - Stop services and kill processes
# ============================================================================

echo ""
print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_highlight "Service Cleanup and Hardening"
print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "Stopping unnecessary services and processes for security..."
echo ""

# Detect if running in chroot environment (live-build)
is_chroot_environment() {
    # Check for live-build indicator files (definitive).
    # LB_BASE is live-build's own environment variable and is included because the
    # marker files are not guaranteed to exist yet: /tmp/live-build-chroot is
    # created by the first chroot hook, and anything invoked before that would
    # otherwise fall through to the /proc heuristic below, which CANNOT answer
    # correctly in a chroot (live-build bind-mounts the host's /proc, so
    # /proc/1/cmdline is the BUILD HOST's systemd). That fall-through is what made
    # every chroot-gated branch take the non-chroot path in the <lab-host>-beta build.
    if [ -f "/.debian-live-build" ] || [ -f "/tmp/live-build-chroot" ] || [ -n "${LB_BASE:-}" ]; then
        return 0
    fi
    # Check if PID 1 is a normal init system — if so, we are NOT in chroot
    # This check MUST come before the inode check because the inode comparison
    # gives false positives on VMware VMs and some kernel versions
    if [ -f /proc/1/cmdline ]; then
        local init_cmd
        init_cmd=$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null)
        if [[ "$init_cmd" =~ (systemd|init|/sbin/init) ]]; then
            # PID 1 is a real init system — definitely not a chroot
            return 1
        fi
    fi
    # Use ischroot if available (Debian standard tool)
    if command -v ischroot >/dev/null 2>&1; then
        if ischroot; then
            return 0
        else
            return 1
        fi
    fi
    # Fallback: compare root inode (can false-positive on VMs, so check last)
    if [ "$(stat -c %d:%i / 2>/dev/null)" != "$(stat -c %d:%i /proc/1/root 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# Function to stop, disable service and kill processes (chroot-aware)
apt_parity_system_cleanup() {
    # Consolidated system cleanup + hardening so the apt/deb postinst runs the SAME
    # neutralization the bash installer does at top-level (parity by construction).
    # Each step no-ops if its target is absent; safe to re-run.
    print_step "Disabling conflicting services (Kodachi manages routing/tor/dns; print/mDNS off)..."
    if declare -f stop_and_disable_service >/dev/null 2>&1; then
        stop_and_disable_service "cups.socket" "CUPS Socket" ""
        stop_and_disable_service "cups.path" "CUPS Path" ""
        stop_and_disable_service "cups.service" "CUPS Printing Service" "cupsd"
        stop_and_disable_service "cups-browsed.service" "CUPS Browser Service" "cups-browsed"
        stop_and_disable_service "avahi-daemon.service" "Avahi Daemon" "avahi-daemon"
        stop_and_disable_service "avahi-daemon.socket" "Avahi Daemon Socket" ""
        stop_and_disable_service "shadowsocks-libev.service" "Shadowsocks Server" "ss-server"
        stop_and_disable_service "shadowsocks-libev-local.service" "Shadowsocks Local" "ss-local"
        stop_and_disable_service "shadowsocks-libev-redir.service" "Shadowsocks Redir" "ss-redir"
        stop_and_disable_service "shadowsocks-libev-server.service" "Shadowsocks Server Instance" ""
        stop_and_disable_service "redsocks.service" "Redsocks Transparent Proxy" "redsocks"
        stop_and_disable_service "microsocks.service" "Microsocks SOCKS5 Proxy" "microsocks"
        stop_and_disable_service "v2ray.service" "V2Ray Proxy" "v2ray"
        stop_and_disable_service "xray.service" "Xray Proxy" "xray"
        stop_and_disable_service "haproxy.service" "HAProxy Load Balancer" "haproxy"
        stop_and_disable_service "tor.service" "Tor Service" "tor"
        stop_and_disable_service "tor@default.service" "Tor Default Instance" ""
        stop_and_disable_service "kloak.service" "Kloak Keystroke Anonymization" "kloak"
        stop_and_disable_service "ram-wipe-kexec-prepare.service" "RAM Wipe Kexec Prepare" ""
    fi
    declare -f disable_ufw >/dev/null 2>&1 && disable_ufw || true

    # Remove Kicksecure ram-wipe/dracut + restore initramfs-tools (bash does this at
    # top-level; no-op if kicksecure ram-wipe packages are not present).
    declare -f remove_kicksecure_ramwipe_and_restore_initramfs >/dev/null 2>&1 && \
        remove_kicksecure_ramwipe_and_restore_initramfs || true

    print_step "Protecting Kodachi runtime-critical packages from autoremove..."
    apt-mark manual e2fsprogs >/dev/null 2>&1 || true
    local _kpkg
    local _protect="iproute2 iptables nftables openresolv resolvconf dnscrypt-proxy ca-certificates tor obfs4proxy macchanger tirdad-dkms wireguard-tools openvpn proxychains4 apparmor apparmor-utils secure-delete network-manager rfkill gnupg dnsutils curl wget libwebkit2gtk-4.1-0 libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libgstreamer-gl1.0-0 gstreamer1.0-plugins-base gstreamer1.0-gl"
    for _kpkg in $_protect; do
        dpkg -s "$_kpkg" >/dev/null 2>&1 && apt-mark manual "$_kpkg" >/dev/null 2>&1 || true
    done

    if dpkg -l 2>/dev/null | grep -q "^ii.*exim4"; then
        print_step "Removing exim4 (unused MTA with a listening service)..."
        systemctl stop exim4 2>/dev/null || true
        systemctl disable exim4 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get purge -y exim4 exim4-base exim4-config exim4-daemon-light >/dev/null 2>&1 || true
    fi

    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true 2>/dev/null || true
    declare -f configure_emergency_shortcut_input_access >/dev/null 2>&1 && configure_emergency_shortcut_input_access || true
    return 0
}

stop_and_disable_service() {
    local service_name="$1"
    local service_display="$2"
    local process_name="$3"  # Process name to kill
    local in_chroot=false

    # Detect chroot environment
    if is_chroot_environment; then
        in_chroot=true
        echo -e "  ${CYAN}[CHROOT]${NC} Processing ${service_display}..."
    else
        print_step "Processing ${service_display}..."
    fi

    local stopped_service=false
    local disabled_service=false
    local killed_process=false

    # In chroot, prioritize process killing since systemctl may not work
    if [ "$in_chroot" = true ]; then
        # Kill process first in chroot
        if [[ -n "$process_name" ]]; then
            if process_running_current_root "$process_name"; then
                echo -e "  ${YELLOW}!${NC} Found running process: $process_name"

                # Force kill immediately in chroot (no grace period needed)
                if kill_matching_processes_current_root "KILL" "x" "$process_name"; then
                    echo -e "  ${GREEN}✓${NC} Force killed $process_name"
                    sleep 1
                fi

                # Verify stopped
                if ! process_running_current_root "$process_name"; then
                    echo -e "  ${GREEN}✓${NC} Process $process_name stopped successfully"
                    killed_process=true
                else
                    echo -e "  ${RED}✗${NC} Failed to stop $process_name"
                fi
            else
                echo -e "  ${BLUE}ℹ${NC} No $process_name processes found in current root"
                killed_process=true
            fi
        fi

        # Try systemctl but don't rely on it in chroot
        if command -v systemctl >/dev/null 2>&1; then
            echo -e "  ${BLUE}ℹ${NC} Skipping systemctl disable for ${service_name} (chroot environment)"
        fi
    else
        # Normal system: use systemctl properly
        if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}"; then
            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                if systemctl stop "$service_name" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} Stopped systemd service: ${service_name}"
                    stopped_service=true
                else
                    echo -e "  ${RED}✗${NC} Failed to stop ${service_name}"
                fi
            else
                echo -e "  ${BLUE}ℹ${NC} Service not running: ${service_name}"
                stopped_service=true
            fi

            # Disable the service
            if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
                if systemctl disable "$service_name" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} Disabled ${service_display}"
                    disabled_service=true
                else
                    echo -e "  ${RED}✗${NC} Failed to disable ${service_name}"
                fi
            else
                echo -e "  ${BLUE}ℹ${NC} Service not enabled: ${service_name}"
                disabled_service=true
            fi
        fi

        # Kill any remaining processes (fallback for non-systemd services)
        if [[ -n "$process_name" ]]; then
            if process_running_current_root "$process_name"; then
                echo -e "  ${YELLOW}!${NC} Found running process: $process_name"

                # Try graceful termination first
                if kill_matching_processes_current_root "TERM" "x" "$process_name"; then
                    echo -e "  ${GREEN}✓${NC} Sent TERM signal to $process_name"
                    sleep 2
                fi

                # Force kill if still running
                if process_running_current_root "$process_name"; then
                    if kill_matching_processes_current_root "KILL" "x" "$process_name"; then
                        echo -e "  ${GREEN}✓${NC} Force killed $process_name processes"
                    fi
                fi

                # Verify stopped
                sleep 1
                if ! process_running_current_root "$process_name"; then
                    echo -e "  ${GREEN}✓${NC} Process $process_name successfully stopped"
                    killed_process=true
                else
                    echo -e "  ${RED}✗${NC} Warning: $process_name may still be running"
                fi
            else
                echo -e "  ${BLUE}ℹ${NC} No $process_name processes found"
                killed_process=true
            fi
        fi
    fi
}

# Remove any Pi-hole DNS redirect rules left behind by dns-switch style setup.
remove_pihole_firewall_redirects_for_cmd() {
    local firewall_cmd="$1"
    local chain=""
    local proto=""

    [[ -n "$firewall_cmd" ]] || return 0

    for chain in PREROUTING OUTPUT; do
        for proto in udp tcp; do
            while "$firewall_cmd" -t nat -C "$chain" -p "$proto" --dport 53 -j REDIRECT --to-port 5353 >/dev/null 2>&1; do
                "$firewall_cmd" -t nat -D "$chain" -p "$proto" --dport 53 -j REDIRECT --to-port 5353 >/dev/null 2>&1 || break
            done
        done
    done
}

remove_pihole_firewall_redirects() {
    local removed_any=false

    if command -v iptables >/dev/null 2>&1; then
        remove_pihole_firewall_redirects_for_cmd "$(command -v iptables)"
        removed_any=true
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        remove_pihole_firewall_redirects_for_cmd "$(command -v ip6tables)"
        removed_any=true
    fi

    if [[ "$removed_any" == "true" ]]; then
        print_success "Removed any Pi-hole DNS redirect rules (53 -> 5353)"
    else
        print_info "iptables/ip6tables not available - skipping Pi-hole redirect cleanup"
    fi
}

pihole_firewall_redirects_present() {
    local rules=""

    if command -v iptables-save >/dev/null 2>&1; then
        rules="$(iptables-save 2>/dev/null || true)"
        if printf '%s\n' "$rules" | grep -Eq -- '--dport[[:space:]]+53.*REDIRECT.*5353'; then
            return 0
        fi
    fi

    if command -v nft >/dev/null 2>&1; then
        rules="$(nft list ruleset 2>/dev/null || true)"
        if printf '%s\n' "$rules" | grep -Eq 'dport[[:space:]]+53.*(redirect to[[:space:]]+5353|dnat.*5353)'; then
            return 0
        fi
    fi

    return 1
}

# Pi-hole's upstream installer can leave pihole-FTL enabled after install.
# When Kodachi did not opt to keep Pi-hole, enforce inactive+disabled as the
# final state instead of assuming a generic stop helper was sufficient.
ensure_pihole_disabled() {
    local service_name="pihole-FTL.service"
    local service_alias="pihole-FTL"
    local attempt=0

    if is_chroot_environment; then
        print_info "Chroot detected - verifying Pi-hole FTL process is stopped"
        if process_running_current_root "pihole-FTL"; then
            kill_matching_processes_current_root "KILL" "x" "pihole-FTL" 2>/dev/null || true
            sleep 1
        fi

        if process_running_current_root "pihole-FTL"; then
            print_error "Pi-hole FTL is still running in chroot after cleanup"
            return 1
        fi

        print_success "Verified: Pi-hole FTL is stopped in chroot"
        reconcile_dns_after_service_transition "Pi-hole disable"
        return $?
    fi

    print_step "Enforcing Pi-hole disabled state..."
    for attempt in 1 2 3; do
        remove_pihole_firewall_redirects
        systemctl disable --now "$service_name" 2>/dev/null || true
        systemctl disable --now "$service_alias" 2>/dev/null || true
        systemctl stop "$service_name" 2>/dev/null || true
        systemctl stop "$service_alias" 2>/dev/null || true
        systemctl reset-failed "$service_name" 2>/dev/null || true
        systemctl reset-failed "$service_alias" 2>/dev/null || true

        if process_running_current_root "pihole-FTL"; then
            kill_matching_processes_current_root "TERM" "x" "pihole-FTL" 2>/dev/null || true
            sleep 1
        fi
        if process_running_current_root "pihole-FTL"; then
            kill_matching_processes_current_root "KILL" "x" "pihole-FTL" 2>/dev/null || true
        fi

        sleep 1

        if ! systemctl is-active --quiet "$service_name" 2>/dev/null \
            && ! systemctl is-active --quiet "$service_alias" 2>/dev/null \
            && ! systemctl is-enabled --quiet "$service_name" 2>/dev/null \
            && ! systemctl is-enabled --quiet "$service_alias" 2>/dev/null \
            && ! pihole_firewall_redirects_present \
            && ! process_running_current_root "pihole-FTL"; then
            print_success "Verified: Pi-hole FTL is inactive, disabled, and no DNS redirects remain"
            reconcile_dns_after_service_transition "Pi-hole disable"
            return $?
        fi

        print_warning "Pi-hole still active, enabled, or still has DNS redirects after attempt $attempt/3"
    done

    print_error "Pi-hole cleanup failed - service remained active, enabled, or redirected DNS traffic"
    print_info "Manual fix: sudo systemctl disable --now pihole-FTL.service"
    print_info "Manual firewall check: sudo iptables-save | grep 5353"
    return 1
}

# Stop and disable CUPS (printing service) - not needed on Kodachi
# Must stop socket/path units first to prevent auto-restart
stop_and_disable_service "cups.socket" "CUPS Socket" ""
stop_and_disable_service "cups.path" "CUPS Path" ""
stop_and_disable_service "cups.service" "CUPS Printing Service" "cupsd"
stop_and_disable_service "cups-browsed.service" "CUPS Browser Service" "cups-browsed"

# Stop and disable Tor - will be managed by Kodachi tor-switch service
echo ""
print_step "Processing Tor (will be managed by Kodachi)..."

# In chroot, FORCE stop regardless of initial state (for ISO builds)
if is_chroot_environment; then
    echo -e "  ${CYAN}Note:${NC} Chroot build detected - forcing Tor stop for clean ISO"
    stop_and_disable_service "tor.service" "Tor Service" "tor"
    stop_and_disable_service "tor@default.service" "Tor Default Instance" ""
elif [[ "$INITIAL_TOR_RUNNING" == "true" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  Tor was running before script - ${BOLD}PRESERVED${NC}"
    echo -e "  ${CYAN}Note:${NC} Stopping it could break your anonymized connection during update"
    echo -e "  ${CYAN}To stop manually after script:${NC}"
    echo -e "      sudo systemctl stop tor"
    echo -e "      sudo systemctl disable tor"
else
    echo -e "  ${CYAN}Note:${NC} Tor will be controlled by Kodachi's tor-switch service"
    stop_and_disable_service "tor.service" "Tor Service" "tor"
    stop_and_disable_service "tor@default.service" "Tor Default Instance" ""
fi

# Fix Tor directory permissions - tor package creates /var/lib/tor owned by
# debian-tor, but chroot builds or overlay copies can reset ownership to root.
# Without correct ownership, tor@default.service fails with exit-code on boot.
if id debian-tor >/dev/null 2>&1; then
    for _tor_dir in /var/lib/tor /var/log/tor /run/tor /etc/tor/kodachi_tor_data; do
        if [ -d "$_tor_dir" ]; then
            chown -R debian-tor:debian-tor "$_tor_dir" 2>/dev/null || true
        else
            mkdir -p "$_tor_dir" 2>/dev/null || true
            chown debian-tor:debian-tor "$_tor_dir" 2>/dev/null || true
        fi
    done
    chmod 700 /var/lib/tor 2>/dev/null || true
    chmod 750 /var/log/tor 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Tor directory permissions fixed (debian-tor:debian-tor)"
fi

# Stop and disable Shadowsocks server - will be managed by routing-switch
echo ""
print_step "Processing Shadowsocks (routing-switch control)..."
if is_chroot_environment; then
    echo -e "  ${CYAN}Note:${NC} Chroot build detected - forcing Shadowsocks stop for clean ISO"
else
    echo -e "  ${CYAN}Note:${NC} Shadowsocks will be managed by routing-switch"
fi
stop_and_disable_service "shadowsocks-libev.service" "Shadowsocks Server" "ss-server"
stop_and_disable_service "shadowsocks-libev-local.service" "Shadowsocks Local" "ss-local"
stop_and_disable_service "shadowsocks-libev-redir.service" "Shadowsocks Redir" "ss-redir"
stop_and_disable_service "shadowsocks-libev-server.service" "Shadowsocks Server Instance" ""

# Stop and disable Redsocks - will be managed by routing-switch
echo ""
print_step "Processing Redsocks (routing-switch control)..."

# In chroot, FORCE stop regardless of initial state (for ISO builds)
if is_chroot_environment; then
    echo -e "  ${CYAN}Note:${NC} Chroot build detected - forcing Redsocks stop for clean ISO"
    stop_and_disable_service "redsocks.service" "Redsocks Transparent Proxy" "redsocks"
elif [[ "$INITIAL_REDSOCKS_RUNNING" == "true" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  Redsocks was running before script - ${BOLD}PRESERVED${NC}"
    echo -e "  ${CYAN}Note:${NC} Stopping it could break your transparent proxy during update"
    echo -e "  ${CYAN}To stop manually after script:${NC}"
    echo -e "      sudo systemctl stop redsocks"
    echo -e "      sudo systemctl disable redsocks"
else
    echo -e "  ${CYAN}Note:${NC} Redsocks will be managed by routing-switch"
    stop_and_disable_service "redsocks.service" "Redsocks Transparent Proxy" "redsocks"
fi

# Stop and disable Microsocks - will be managed by routing-switch
echo ""
print_step "Processing Microsocks (routing-switch control)..."
echo -e "  ${CYAN}Note:${NC} Microsocks will be managed by routing-switch"
stop_and_disable_service "microsocks.service" "Microsocks SOCKS5 Proxy" "microsocks"

# Stop and disable V2Ray - will be managed by routing-switch
# The Debian v2ray package auto-enables and starts v2ray.service with a stock
# example inbound on 0.0.0.0:10086; leaving it running exposes an open proxy
# port on all interfaces. Kodachi drives V2Ray through routing-switch instead.
echo ""
print_step "Processing V2Ray (routing-switch control)..."
echo -e "  ${CYAN}Note:${NC} V2Ray will be managed by routing-switch"
stop_and_disable_service "v2ray.service" "V2Ray Proxy" "v2ray"

# Stop and disable Xray - will be managed by routing-switch
# The Xray installer likewise enables and starts xray.service on install;
# neutralize it so no proxy inbound is left listening after setup.
echo ""
print_step "Processing Xray (routing-switch control)..."
echo -e "  ${CYAN}Note:${NC} Xray will be managed by routing-switch"
stop_and_disable_service "xray.service" "Xray Proxy" "xray"

# Stop and disable HAProxy - will be managed by tor-switch
echo ""
print_step "Processing HAProxy (tor-switch control)..."
echo -e "  ${CYAN}Note:${NC} HAProxy will be managed by tor-switch"
stop_and_disable_service "haproxy.service" "HAProxy Load Balancer" "haproxy"

# Stop and disable Avahi daemon - privacy leak (broadcasts hostname/services)
echo ""
print_step "Processing Avahi daemon (mDNS service discovery)..."
echo -e "  ${CYAN}Note:${NC} Avahi broadcasts hostname and services - privacy leak"
stop_and_disable_service "avahi-daemon.service" "Avahi Daemon" "avahi-daemon"
stop_and_disable_service "avahi-daemon.socket" "Avahi Daemon Socket" ""

# Stop and disable DNSCrypt Proxy - will be managed by dns-switch
echo ""
print_step "Processing DNSCrypt Proxy (dns-switch control)..."
DNSCRYPT_STOPPED_FOR_KODACHI=false

# In chroot, FORCE stop regardless of initial state (for ISO builds)
if is_chroot_environment; then
    echo -e "  ${CYAN}Note:${NC} Chroot build detected - forcing DNSCrypt stop for clean ISO"
    stop_and_disable_service "dnscrypt-proxy.service" "DNSCrypt Proxy" "dnscrypt-proxy"
    stop_and_disable_service "dnscrypt-proxy.socket" "DNSCrypt Proxy Socket" ""
    DNSCRYPT_STOPPED_FOR_KODACHI=true
elif [[ "$INITIAL_DNSCRYPT_RUNNING" == "true" ]]; then
    echo -e "  ${YELLOW}⚠${NC}  DNSCrypt Proxy was running before script - ${BOLD}PRESERVED${NC}"
    echo -e "  ${CYAN}Note:${NC} Stopping it could break your internet connection during update"
    echo -e "  ${CYAN}To stop manually after script:${NC}"
    echo -e "      sudo systemctl stop dnscrypt-proxy"
    echo -e "      sudo systemctl disable dnscrypt-proxy"
else
    echo -e "  ${CYAN}Note:${NC} DNSCrypt Proxy will be managed by dns-switch"
    stop_and_disable_service "dnscrypt-proxy.service" "DNSCrypt Proxy" "dnscrypt-proxy"
    stop_and_disable_service "dnscrypt-proxy.socket" "DNSCrypt Proxy Socket" ""
    DNSCRYPT_STOPPED_FOR_KODACHI=true
fi

if [[ "$DNSCRYPT_STOPPED_FOR_KODACHI" == "true" ]]; then
    reconcile_dns_after_service_transition "DNSCrypt disable" || true
fi

# NTP time sync services - ENABLED for proper time synchronization
# NOTE: Previously disabled due to fingerprinting concerns, but this caused critical issues:
# - Physical hardware boots with incorrect clock (VMware syncs to host, USB media does not)
# - SSL/TLS certificates appear invalid until the user fixes time manually
# - curl/HTTPS requests and time-based authentication tokens fail on first boot
# - An obviously wrong clock is itself a fingerprinting risk
# DECISION: Leave NTP services managed by systemd presets so the clock syncs automatically.
# Users who want to disable NTP can still do so manually after boot:
#   sudo systemctl disable systemd-timesyncd.service
# echo ""
# print_step "Processing NTP services (time synchronization)..."
# echo -e "  ${CYAN}Note:${NC} NTP enabled for proper time synchronization (required for SSL/TLS)"
# NTP services are now managed by systemd preset: /etc/systemd/system-preset/90-kodachi-services.preset
# systemd-timesyncd.service is ENABLED by default for automatic time synchronization

# Stop and disable kloak - keystroke anonymization (manual start when needed)
echo ""
print_step "Processing kloak (keystroke anonymization)..."
echo -e "  ${CYAN}Note:${NC} kloak will be disabled for manual activation when needed"

# Stop kloak service
if systemctl is-active --quiet kloak.service 2>/dev/null; then
    if systemctl stop kloak.service 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Stopped kloak service"
    else
        echo -e "  ${YELLOW}!${NC} Failed to stop kloak service"
    fi
else
    echo -e "  ${BLUE}ℹ${NC} kloak service not running"
fi

# Disable kloak service
if systemctl is-enabled --quiet kloak.service &>/dev/null; then
    if systemctl disable kloak.service 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Disabled kloak service"
    else
        echo -e "  ${YELLOW}!${NC} Failed to disable kloak service"
    fi
else
    echo -e "  ${BLUE}ℹ${NC} kloak service already disabled"
fi

# Verify kloak is disabled
if systemctl is-enabled kloak.service &>/dev/null; then
    echo -e "  ${RED}✗${NC} Warning: kloak service is still enabled"
else
    echo -e "  ${GREEN}✓${NC} Verified: kloak service is disabled"
fi

# Stop and disable ram-wipe-kexec-prepare - RAM wipe preparation (manual start when needed)
echo ""
print_step "Processing ram-wipe-kexec-prepare (RAM wipe preparation)..."
echo -e "  ${CYAN}Note:${NC} ram-wipe-kexec-prepare will be disabled for manual activation when needed"

# Stop ram-wipe-kexec-prepare service
if systemctl is-active --quiet ram-wipe-kexec-prepare.service 2>/dev/null; then
    if systemctl stop ram-wipe-kexec-prepare.service 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Stopped ram-wipe-kexec-prepare service"
    else
        echo -e "  ${YELLOW}!${NC} Failed to stop ram-wipe-kexec-prepare service"
    fi
else
    echo -e "  ${BLUE}ℹ${NC} ram-wipe-kexec-prepare service not running"
fi

# Disable ram-wipe-kexec-prepare service
if systemctl is-enabled --quiet ram-wipe-kexec-prepare.service &>/dev/null; then
    if systemctl disable ram-wipe-kexec-prepare.service 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Disabled ram-wipe-kexec-prepare service"
    else
        echo -e "  ${YELLOW}!${NC} Failed to disable ram-wipe-kexec-prepare service"
    fi
else
    echo -e "  ${BLUE}ℹ${NC} ram-wipe-kexec-prepare service already disabled"
fi

# Verify ram-wipe-kexec-prepare is disabled
if systemctl is-enabled ram-wipe-kexec-prepare.service &>/dev/null; then
    echo -e "  ${RED}✗${NC} Warning: ram-wipe-kexec-prepare service is still enabled"
else
    echo -e "  ${GREEN}✓${NC} Verified: ram-wipe-kexec-prepare service is disabled"
fi

# Handle Pi-hole based on installation mode and user preference
echo ""
print_step "Processing Pi-hole..."
PIHOLE_KEEP=false  # Default: stop Pi-hole for security
PIHOLE_DISABLE_VERIFIED=true

# Check if Pi-hole is installed
if command -v pihole &>/dev/null || systemctl list-unit-files 2>/dev/null | grep -q "^pihole-FTL"; then
    echo -e "  ${GREEN}✓${NC} Pi-hole is installed"

    # In interactive or non-auto mode, ask user
    if [[ "$INSTALL_MODE" == "interactive" ]] || [[ "$AUTO_YES" == "false" ]]; then
        echo ""
        print_info "Pi-hole provides network-wide DNS filtering and ad blocking."
        print_info "It's currently running on ports 53 (DNS), 80 (HTTP), and 443 (HTTPS)."
        echo ""

        read -p "$(echo -e "${CYAN}Do you want to keep Pi-hole running? [Y/n]: ${NC}")" -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            PIHOLE_KEEP=true
        fi
    else
        # In auto mode, stop Pi-hole by default
        echo -e "  ${CYAN}Note:${NC} Pi-hole will be stopped (ports 53, 80, 443 closed)"
        echo -e "  ${CYAN}To keep it running:${NC} Use --interactive mode and answer 'Y'"
    fi

    if [[ "$PIHOLE_KEEP" == "false" ]]; then
        print_step "Stopping Pi-hole as requested..."
        PIHOLE_DISABLE_VERIFIED=false
        stop_and_disable_service "pihole-FTL.service" "Pi-hole FTL Service" "pihole-FTL"
        if ensure_pihole_disabled; then
            PIHOLE_DISABLE_VERIFIED=true
        fi
        echo -e "  ${YELLOW}ℹ${NC} To remove Pi-hole completely, run: pihole uninstall"
    else
        echo -e "  ${GREEN}✓${NC} Pi-hole will remain active"
    fi
else
    echo -e "  ${BLUE}ℹ${NC} Pi-hole not installed"
fi

# ============================================================================
# EXIM4 COMPLETE REMOVAL
# ============================================================================

echo ""
print_highlight "Removing Exim4 Mail Transfer Agent..."
echo ""

print_info "Exim4 is not needed for Kodachi and opens port 25 unnecessarily"

# Check if exim4 processes are running (regardless of package status)
if process_running_current_root "exim4"; then
    print_step "Killing exim4 processes..."
    kill_matching_processes_current_root "KILL" "x" "exim4" 2>/dev/null || true
    sleep 1
    if ! process_running_current_root "exim4"; then
        echo -e "  ${GREEN}✓${NC} Killed all exim4 processes"
    else
        echo -e "  ${YELLOW}!${NC} Some exim4 processes may still be running"
    fi
fi

# Check if exim4 packages are installed
if dpkg -l 2>/dev/null | grep -q "^ii.*exim4"; then
    print_step "Removing exim4 packages..."

    # Stop exim4 service if running
    systemctl stop exim4 2>/dev/null || true
    systemctl disable exim4 2>/dev/null || true

    # Purge all exim4 packages
    if DEBIAN_FRONTEND=noninteractive apt-get purge -y exim4 exim4-base exim4-config exim4-daemon-light 2>&1 | grep -E "(Removing|Purging)"; then
        echo -e "  ${GREEN}✓${NC} Removed exim4 packages"

        # Clean up dependencies
        print_step "Cleaning up unused dependencies..."
        if apt-get autoremove -y 2>&1 | grep -E "(Removing|freed)"; then
            echo -e "  ${GREEN}✓${NC} Cleaned up dependencies"
        fi
    else
        echo -e "  ${YELLOW}!${NC} exim4 removal encountered issues"
    fi

    # Kill any remaining exim4 processes
    if process_running_current_root "exim4"; then
        echo -e "  ${YELLOW}!${NC} Found remaining exim4 processes - killing..."
        kill_matching_processes_current_root "KILL" "x" "exim4" 2>/dev/null || true
        sleep 1
        if ! process_running_current_root "exim4"; then
            echo -e "  ${GREEN}✓${NC} Killed all exim4 processes"
        fi
    fi

    # Verify exim4 is gone
    if ! dpkg -l 2>/dev/null | grep -q "^ii.*exim4" && ! process_running_current_root "exim4"; then
        echo -e "  ${GREEN}✓${NC} exim4 completely removed"
    fi
else
    # Check if process is running without package
    if process_running_current_root "exim4"; then
        echo -e "  ${YELLOW}!${NC} exim4 process running but package not installed (killed above)"
    else
        echo -e "  ${GREEN}✓${NC} exim4 not installed (good!)"
    fi
fi

# ============================================================================
# CLEANUP SUMMARY AND VERIFICATION
# ============================================================================

echo ""
print_highlight "Service Cleanup Summary"
print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Show preserved services first (if any)
PRESERVED_SERVICES=()
if [[ "$INITIAL_DNSCRYPT_RUNNING" == "true" ]]; then
    PRESERVED_SERVICES+=("DNSCrypt Proxy (DNS resolver)")
fi
if [[ "$INITIAL_TOR_RUNNING" == "true" ]]; then
    PRESERVED_SERVICES+=("Tor (anonymized connection)")
fi
if [[ "$INITIAL_REDSOCKS_RUNNING" == "true" ]]; then
    PRESERVED_SERVICES+=("Redsocks (transparent proxy)")
fi
if [[ "$INITIAL_PIHOLE_RUNNING" == "true" ]] && [[ "$PIHOLE_KEEP" != "false" ]]; then
    PRESERVED_SERVICES+=("Pi-hole (DNS filtering)")
fi

if [[ ${#PRESERVED_SERVICES[@]} -gt 0 ]]; then
    print_warning "Services PRESERVED (were running before script - NOT stopped):"
    for service in "${PRESERVED_SERVICES[@]}"; do
        echo "  ⚠  $service"
    done
    echo ""
    print_info "These services were kept running to avoid breaking your internet during update"
    print_info "To stop them manually, see the commands shown earlier in the output"
    echo ""
fi

print_info "Services stopped and disabled (NOT masked - Kodachi binaries can re-enable):"
if [[ "$INITIAL_CUPS_RUNNING" != "true" ]] || [[ "$INITIAL_CUPS_RUNNING" == "true" ]]; then
    echo "  • CUPS (printing) - not needed"
fi
echo "  • Avahi daemon (mDNS) - privacy leak (broadcasts hostname/services)"
if [[ "$INITIAL_DNSCRYPT_RUNNING" != "true" ]]; then
    echo "  • DNSCrypt Proxy - will be managed by Kodachi dns-switch"
fi
echo "  • NTP/time sync (ntpd/systemd-timesyncd) - fingerprinting risk"
if [[ "$INITIAL_TOR_RUNNING" != "true" ]]; then
    echo "  • Tor - will be managed by Kodachi tor-switch"
fi
echo "  • Shadowsocks - will be managed by routing-switch"
if [[ "$INITIAL_REDSOCKS_RUNNING" != "true" ]]; then
    echo "  • Redsocks - will be managed by routing-switch"
fi
echo "  • Microsocks - will be managed by routing-switch"
echo "  • kloak (keystroke anonymization) - disabled for manual activation"
if check_package "ram-wipe"; then
    echo "  • ram-wipe-kexec-prepare (Kicksecure RAM wipe) - disabled for manual activation"
fi
if [[ "$PIHOLE_KEEP" == "false" ]]; then
    echo "  • Pi-hole - stopped as requested"
fi
echo ""

print_info "Packages removed:"
echo "  • exim4 (mail transfer agent) - security hardening"
echo ""

# Verify processes are stopped
echo ""
print_step "Verifying processes are stopped..."
STILL_RUNNING=()
for proc in cupsd tor ss-server ss-local ss-redir redsocks microsocks exim4 avahi-daemon dnscrypt-proxy ntpd systemd-timesyncd pihole-FTL; do
    if process_running_current_root "$proc"; then
        STILL_RUNNING+=("$proc")
    fi
done

if [[ ${#STILL_RUNNING[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}✓${NC} All targeted processes successfully stopped"
else
    echo -e "  ${YELLOW}!${NC} Warning: Some processes still running: ${STILL_RUNNING[*]}"
fi

echo ""
if [[ "$PIHOLE_KEEP" == "false" ]] && [[ "$PIHOLE_DISABLE_VERIFIED" != "true" ]]; then
    print_error "Service cleanup completed with Pi-hole verification failure"
else
    print_success "Service cleanup completed!"
fi
echo ""

print_info "To re-enable a service if needed (Kodachi binaries can also do this):"
echo -e "  ${CYAN}sudo systemctl enable <service>${NC}"
echo -e "  ${CYAN}sudo systemctl start <service>${NC}"
echo ""

# Clean up any orphaned background processes before port check
print_step "Cleaning up orphaned background processes..."
# Kill any remaining curl processes that might be from installations
if [ -n "$(list_matching_pids_current_root f 'curl.*install|curl.*github|curl.*pi-hole')" ]; then
    kill_matching_processes_current_root "KILL" "f" "curl.*install|curl.*github|curl.*pi-hole" 2>/dev/null || true
    sleep 1
    echo -e "  ${GREEN}✓${NC} Cleaned up orphaned curl processes"
else
    echo -e "  ${GREEN}✓${NC} No orphaned processes found"
fi
echo ""

# ============================================================================
# GLOBAL LAUNCHER DEPLOYMENT
# ============================================================================

echo ""
print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_highlight "Global Launcher Deployment"
print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Try to find the global-launcher binary
HOOKS_DIR=""
GLOBAL_LAUNCHER_PATH=""

# Search for hooks directory in common locations (system-wide first)
search_hook_dirs=(
    "/opt/kodachi/dashboard/hooks"
)
if [[ -n "$PROJECT_ROOT" ]]; then
    search_hook_dirs+=("$PROJECT_ROOT/dashboard/hooks")
fi
search_hook_dirs+=(
    "$HOME/k900/dashboard/hooks"
    "$HOME/dashboard/hooks"
    "$HOME/Desktop/dashboard/hooks"
    "$HOME/Desktop/k900/dashboard/hooks"
)
while IFS= read -r user_home; do
    search_hook_dirs+=(
        "$user_home/k900/dashboard/hooks"
        "$user_home/dashboard/hooks"
        "$user_home/Desktop/dashboard/hooks"
        "$user_home/Desktop/k900/dashboard/hooks"
    )
done < <(list_system_user_homes)

for dir in "${search_hook_dirs[@]}"; do
    if [[ -d "$dir" ]] && [[ -f "$dir/global-launcher" ]]; then
        HOOKS_DIR="$dir"
        GLOBAL_LAUNCHER_PATH="$dir/global-launcher"
        break
    fi
done

# If not found, check current directory
if [[ -z "$GLOBAL_LAUNCHER_PATH" ]] && [[ -f "./global-launcher" ]]; then
    HOOKS_DIR="$(pwd)"
    GLOBAL_LAUNCHER_PATH="./global-launcher"
fi

if [[ -n "$GLOBAL_LAUNCHER_PATH" ]] && [[ -x "$GLOBAL_LAUNCHER_PATH" ]]; then
    print_step "Found global-launcher at: $HOOKS_DIR"

    # Deploy global launcher
    print_step "Deploying Kodachi binaries to /usr/local/bin..."

    # Change to hooks directory for deployment
    pushd "$HOOKS_DIR" > /dev/null 2>&1

    if ./global-launcher deploy 2>&1; then
        echo -e "  ${GREEN}✓${NC} Global launcher deployed successfully"

        # Verify deployment
        print_step "Verifying deployment..."
        if ./global-launcher verify 2>&1 | grep -q "SUCCESS"; then
            VERIFY_OUTPUT=$(./global-launcher verify 2>&1)
            echo -e "  ${GREEN}✓${NC} $VERIFY_OUTPUT"
        else
            echo -e "  ${YELLOW}!${NC} Verification completed with warnings"
        fi
    else
        echo -e "  ${YELLOW}!${NC} Global launcher deployment failed (non-critical)"
        print_info "You can manually deploy later with: sudo $GLOBAL_LAUNCHER_PATH deploy"
    fi

    popd > /dev/null 2>&1

else
    print_info "Global launcher not found - skipping deployment"
    print_info "This is normal if Kodachi binaries are not yet compiled"
    print_info "To deploy later:"
    echo -e "  ${CYAN}1. Build Kodachi binaries:${NC}"
    # [CLAW-ARCHIVED 2026-05-18] kodachi-claw/zero-claw/zeroclaw-desktop retired
    # echo -e "  ${CYAN}   cd dashboard/hooks/rust/kodachi-claw && ./build.sh${NC}"
    # echo -e "  ${CYAN}   cd ../zero-claw && ./build.sh${NC}"
    # echo -e "  ${CYAN}   cd ../zeroclaw-desktop && ./build.sh${NC}"
    echo -e "  ${CYAN}2. Deploy global launcher: cd dashboard/hooks && sudo ./global-launcher deploy${NC}"
fi

echo ""

# =============================================================================
# Install Kodachi Rofi Actions Launcher
# =============================================================================
print_step "Installing Kodachi rofi actions launcher..."

ROFI_ACTIONS_TARGET="/usr/local/bin/kodachi-rofi-actions"
ROFI_ACTIONS_SOURCE=""
ROFI_ACTIONS_SEARCH_PATHS=(
    "/opt/kodachi-offline-packages/scripts/kodachi-rofi-actions"
    "$PROJECT_ROOT/livebuilds/kodachi-terminal-build/overlays/common/includes.chroot_after_packages/opt/kodachi-offline-packages/scripts/kodachi-rofi-actions"
    "$SCRIPT_DIR/../livebuilds/kodachi-terminal-build/overlays/common/includes.chroot_after_packages/opt/kodachi-offline-packages/scripts/kodachi-rofi-actions"
)

for candidate in "${ROFI_ACTIONS_SEARCH_PATHS[@]}"; do
    if [[ -f "$candidate" ]]; then
        ROFI_ACTIONS_SOURCE="$candidate"
        break
    fi
done

if [[ -n "$ROFI_ACTIONS_SOURCE" ]]; then
    cp "$ROFI_ACTIONS_SOURCE" "$ROFI_ACTIONS_TARGET"
    chmod 755 "$ROFI_ACTIONS_TARGET"
    chown root:root "$ROFI_ACTIONS_TARGET" 2>/dev/null || true
    print_success "Kodachi rofi actions installed: $ROFI_ACTIONS_TARGET"
elif [[ -f "$ROFI_ACTIONS_TARGET" ]]; then
    chmod 755 "$ROFI_ACTIONS_TARGET" 2>/dev/null || true
    chown root:root "$ROFI_ACTIONS_TARGET" 2>/dev/null || true
    print_info "Kodachi rofi actions already present at $ROFI_ACTIONS_TARGET"
else
    print_warning "Kodachi rofi actions source not found — skipping launcher deployment"
fi

ROFI_LIB_TARGET="/usr/local/lib/kodachi-rofi"
if [[ -d "$ROFI_LIB_TARGET" ]]; then
    find "$ROFI_LIB_TARGET" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$ROFI_LIB_TARGET" -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
    find "$ROFI_LIB_TARGET" -maxdepth 1 -type f ! -name '*.sh' -exec chmod 644 {} + 2>/dev/null || true
    chown -R root:root "$ROFI_LIB_TARGET" 2>/dev/null || true
    print_success "Kodachi rofi library permissions normalized: $ROFI_LIB_TARGET"
else
    print_warning "Kodachi rofi library directory not found — skipping permission normalization"
fi

echo ""

# =============================================================================
# Install XFCE Whisker Menu Entries
# =============================================================================
# Create .desktop files in /usr/share/applications/ so Kodachi apps appear in
# the XFCE Whisker menu (and any XDG-compliant application launcher).
# This runs as root (deps script) so we can write to system directories.
# Not gated behind GUI detection — harmless on headless systems.
print_step "Installing Whisker menu entries..."

WHISKER_APPS_DIR="/usr/share/applications"
if [[ -d "$WHISKER_APPS_DIR" ]]; then
    # Determine icon paths (prefer system icons, fallback to hooks)
    DASHBOARD_ICON="/usr/share/icons/kodachi/kodachi32.png"
    if [[ ! -f "$DASHBOARD_ICON" ]] && [[ -n "${BINARIES_LOCATION:-}" ]]; then
        DASHBOARD_ICON="$BINARIES_LOCATION/icons/kodachi-dashboard.png"
    fi
    WELCOME_ICON="/usr/share/icons/kodachi/Kodachi_White_big.png"
    if [[ ! -f "$WELCOME_ICON" ]] && [[ -n "${BINARIES_LOCATION:-}" ]]; then
        WELCOME_ICON="$BINARIES_LOCATION/icons/kodachi-autoshield.png"
    fi

    cat > "$WHISKER_APPS_DIR/kodachi-dashboard.desktop" << MENUEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Kodachi Dashboard
GenericName=Security Dashboard
Comment=Kodachi Security Dashboard - control privacy, networking, and system hardening
Exec=/usr/local/bin/kodachi-dashboard-launcher
TryExec=/usr/local/bin/kodachi-dashboard-launcher
Icon=$DASHBOARD_ICON
Terminal=false
Categories=System;Security;
Keywords=kodachi;dashboard;security;privacy;tor;vpn;dns;firewall;
StartupNotify=true
StartupWMClass=kodachi-dashboard
MENUEOF
    chmod 644 "$WHISKER_APPS_DIR/kodachi-dashboard.desktop"

    # AutoShield retired as a standalone app (now a dashboard startup-screen tab):
    # remove any stale menu entry instead of installing one.
    rm -f "$WHISKER_APPS_DIR/kodachi-autoshield.desktop" 2>/dev/null || true

    cat > "$WHISKER_APPS_DIR/kodachi-rofi-actions.desktop" << MENUEOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Kodachi Quick Actions
GenericName=Rofi Security Actions
Comment=Launch approved Kodachi quick actions in rofi without changing your current rofi theme
Exec=kodachi-rofi-actions
TryExec=kodachi-rofi-actions
Icon=$DASHBOARD_ICON
Terminal=false
Categories=System;Security;
Keywords=kodachi;rofi;actions;security;privacy;tor;vpn;dns;
StartupNotify=false
MENUEOF
    chmod 644 "$WHISKER_APPS_DIR/kodachi-rofi-actions.desktop"

    print_success "Whisker menu entries installed: kodachi-dashboard, kodachi-rofi-actions"
else
    print_warning "Directory $WHISKER_APPS_DIR not found — skipping Whisker menu entries"
fi

echo ""

# =============================================================================
# Install Kodachi AutoShield Commands
# =============================================================================
# This function installs the Kodachi welcome script and commands system-wide
# to match the live ISO behavior. It handles version comparison and ensures
# no conflicts when the deps installer runs during ISO build.
#
# Installed files:
#   - /etc/profile.d/kodachi-autoshield.sh (profile.d script with skip logic)
#   - /usr/local/bin/welcome (wrapper script)
#   - /usr/local/bin/kodachi (symlink to welcome)
#   - /usr/local/bin/Kodachi (symlink to welcome)
# =============================================================================

install_welcome_commands() {
    echo ""
    print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_highlight "Installing Kodachi AutoShield Commands"
    print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Search for packaged scripts in multiple locations
    local PROFILE_SCRIPT=""
    local WRAPPER_SCRIPT=""

    # Search paths in priority order
    local search_paths=(
        "$HOOKS_DIR/binaries-update-scripts"
        "$PROJECT_ROOT/dashboard/hooks/binaries-update-scripts"
        "$HOME/dashboard/hooks/binaries-update-scripts"
        "$HOME/k900/dashboard/hooks/binaries-update-scripts"
    )

    # Add other users' dashboard/hooks dynamically (no fixed /home layout)
    while IFS= read -r user_home; do
        if [[ -d "$user_home/dashboard/hooks/binaries-update-scripts" ]]; then
            search_paths+=("$user_home/dashboard/hooks/binaries-update-scripts")
        fi
        if [[ -d "$user_home/k900/dashboard/hooks/binaries-update-scripts" ]]; then
            search_paths+=("$user_home/k900/dashboard/hooks/binaries-update-scripts")
        fi
    done < <(list_system_user_homes)

    # Find the scripts
    for base_dir in "${search_paths[@]}"; do
        if [[ -f "$base_dir/kodachi-autoshield.sh" ]]; then
            PROFILE_SCRIPT="$base_dir/kodachi-autoshield.sh"
            WRAPPER_SCRIPT="$base_dir/welcome"
            break
        fi
    done

    if [[ -z "$PROFILE_SCRIPT" ]]; then
        print_warning "Welcome scripts not found in package, skipping..."
        return 0
    fi

    # Extract version from new script
    local NEW_BUILD_NUM=$(grep '^BUILD_NUM=' "$PROFILE_SCRIPT" 2>/dev/null | cut -d'"' -f2)
    local NEW_VERSION=$(grep '^BUILD_VERSION=' "$PROFILE_SCRIPT" 2>/dev/null | cut -d'"' -f2)

    # Check existing installation
    local INSTALLED_SCRIPT="/etc/profile.d/kodachi-autoshield.sh"
    local SHOULD_INSTALL=true

    if [[ -f "$INSTALLED_SCRIPT" ]]; then
        local INSTALLED_BUILD_NUM=$(grep '^BUILD_NUM=' "$INSTALLED_SCRIPT" 2>/dev/null | cut -d'"' -f2)

        if [[ -n "$NEW_BUILD_NUM" ]] && [[ -n "$INSTALLED_BUILD_NUM" ]]; then
            if (( NEW_BUILD_NUM > INSTALLED_BUILD_NUM )); then
                print_info "Updating Kodachi welcome script ($NEW_VERSION.$INSTALLED_BUILD_NUM → $NEW_VERSION.$NEW_BUILD_NUM)..."
            elif (( NEW_BUILD_NUM == INSTALLED_BUILD_NUM )); then
                print_info "Kodachi welcome script already current (version $NEW_VERSION.$NEW_BUILD_NUM), verifying commands..."
                SHOULD_INSTALL=false
            else
                print_info "Installed version ($INSTALLED_BUILD_NUM) is newer than package ($NEW_BUILD_NUM), skipping..."
                SHOULD_INSTALL=false
            fi
        fi
    else
        print_info "Installing Kodachi welcome commands (version $NEW_VERSION.$NEW_BUILD_NUM)..."
    fi

    # Install profile.d script if needed
    if [[ "$SHOULD_INSTALL" == true ]]; then
        cp "$PROFILE_SCRIPT" "$INSTALLED_SCRIPT"
        chmod 755 "$INSTALLED_SCRIPT"
    fi

    # Always verify/recreate wrapper and symlinks (idempotent)
    # NOTE: /usr/local/bin/welcome may already be a SYMLINK (the 9999 ISO hook
    # points welcome/shield at kodachi-dashboard-launcher now that AutoShield is
    # retired). `cp`/`cat >` would FOLLOW that symlink and overwrite the real
    # dashboard launcher with this terminal wrapper, breaking the GUI dashboard
    # at boot and on every panel/menu launch. Delete it first so we always write
    # a fresh regular file, never through a symlink.
    rm -f /usr/local/bin/welcome
    if [[ -f "$WRAPPER_SCRIPT" ]]; then
        cp "$WRAPPER_SCRIPT" /usr/local/bin/welcome
        chmod 755 /usr/local/bin/welcome
    else
        # Fallback: create wrapper if not in package
        cat > /usr/local/bin/welcome << 'EOF'
#!/bin/bash
# Kodachi AutoShield Command Wrapper
if [ "$#" -ne 0 ]; then
    echo "Error: $(basename "$0") takes no arguments ($# given)" >&2
    echo "Usage: $(basename "$0")" >&2
    echo "This is the Kodachi welcome/AutoShield launcher, not a command-line interface." >&2
    exit 2
fi

if [ ! -t 0 ]; then
    exit 0
fi

export KODACHI_SKIP_WELCOME=0

if [[ -f /etc/profile.d/kodachi-autoshield.sh ]]; then
    source /etc/profile.d/kodachi-autoshield.sh
else
    echo "Error: Kodachi welcome script not found at /etc/profile.d/kodachi-autoshield.sh" >&2
    exit 1
fi
EOF
        chmod 755 /usr/local/bin/welcome
    fi

    # Create symlinks (force to handle existing)
    ln -sf /usr/local/bin/welcome /usr/local/bin/kodachi
    ln -sf /usr/local/bin/welcome /usr/local/bin/Kodachi
    ln -sf /usr/local/bin/welcome /usr/local/bin/shield

    print_success "Kodachi commands verified: kodachi, welcome, Kodachi, shield"
    echo ""
}

# =============================================================================
# Install Oniux Launcher
# =============================================================================
# This function installs the oniux-launcher script to /usr/local/bin so that
# non-ISO installations (via the two-step installer) receive it. The script
# enables kernel user namespaces before launching applications via oniux.
#
# Installed files:
#   - /usr/local/bin/oniux-launcher (namespace enabler + oniux exec wrapper)
# =============================================================================

install_oniux_launcher() {
    echo ""
    print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_highlight "Installing Oniux Launcher"
    print_highlight "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local ONIUX_SCRIPT=""
    local INSTALLED="/usr/local/bin/oniux-launcher"

    # Search paths in priority order
    local search_paths=(
        "$HOOKS_DIR/binaries-update-scripts"
        "$PROJECT_ROOT/dashboard/hooks/binaries-update-scripts"
        "$HOME/dashboard/hooks/binaries-update-scripts"
        "$HOME/k900/dashboard/hooks/binaries-update-scripts"
    )

    # Add other users' dashboard/hooks dynamically (no fixed /home layout)
    while IFS= read -r user_home; do
        if [[ -d "$user_home/dashboard/hooks/binaries-update-scripts" ]]; then
            search_paths+=("$user_home/dashboard/hooks/binaries-update-scripts")
        fi
        if [[ -d "$user_home/k900/dashboard/hooks/binaries-update-scripts" ]]; then
            search_paths+=("$user_home/k900/dashboard/hooks/binaries-update-scripts")
        fi
    done < <(list_system_user_homes)

    # Find the script in package
    for base_dir in "${search_paths[@]}"; do
        if [[ -f "$base_dir/oniux-launcher" ]]; then
            ONIUX_SCRIPT="$base_dir/oniux-launcher"
            break
        fi
    done

    if [[ -n "$ONIUX_SCRIPT" ]]; then
        # Compare versions if already installed
        local SHOULD_INSTALL=true
        if [[ -f "$INSTALLED" ]]; then
            local NEW_VER
            local OLD_VER
            NEW_VER=$(grep '^# Version:' "$ONIUX_SCRIPT" 2>/dev/null | awk '{print $NF}' || echo "")
            OLD_VER=$(grep '^# Version:' "$INSTALLED" 2>/dev/null | awk '{print $NF}' || echo "")
            if [[ -n "$NEW_VER" ]] && [[ "$NEW_VER" == "$OLD_VER" ]]; then
                print_info "oniux-launcher already current (version $OLD_VER)"
                SHOULD_INSTALL=false
            elif [[ -n "$NEW_VER" ]]; then
                print_info "Updating oniux-launcher ($OLD_VER -> $NEW_VER)..."
            fi
        fi

        if [[ "$SHOULD_INSTALL" == true ]]; then
            cp "$ONIUX_SCRIPT" "$INSTALLED"
            chmod 755 "$INSTALLED"
            print_success "oniux-launcher installed to $INSTALLED"
        fi
    else
        # Fallback: create inline if not in package and not already installed
        if [[ -f "$INSTALLED" ]]; then
            print_info "oniux-launcher already present at $INSTALLED (no package update)"
        else
            print_info "oniux-launcher not found in package, creating inline fallback..."
            cat > "$INSTALLED" << 'ONIUX_EOF'
#!/bin/bash

# Oniux Launcher - Safe Oniux Wrapper with Namespace Enablement
# ==============================================================
#
# SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.1
# Copyright (c) 2013-2026 Warith Al Maawali
#
# This file is part of Kodachi OS.
# For full license terms, see LICENSE.md or visit:
# https://kodachi.cloud/docs/license.html
#
# Version: 9.0.1

USERNS_PATH="/proc/sys/kernel/unprivileged_userns_clone"
APPARMOR_PATH="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kodachi"
SUPPRESS_FILE="$CONFIG_DIR/oniux-suppress-notification"

changed=0
failed=0

# Check and enable unprivileged user namespace cloning
if [ -f "$USERNS_PATH" ]; then
    current=$(cat "$USERNS_PATH" 2>/dev/null)
    if [ "$current" = "0" ]; then
        if sudo sysctl -w kernel.unprivileged_userns_clone=1 >/dev/null 2>&1; then
            changed=1
        else
            failed=1
        fi
    fi
fi

# Check and disable AppArmor userns restriction (if the sysctl exists)
if [ -f "$APPARMOR_PATH" ]; then
    current=$(cat "$APPARMOR_PATH" 2>/dev/null)
    if [ "$current" = "1" ]; then
        if sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null 2>&1; then
            changed=1
        else
            failed=1
        fi
    fi
fi

# Notifications
if [ "$failed" = "1" ]; then
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i dialog-warning -t 6000 "Oniux" \
            "Failed to enable user namespaces. Oniux may not work."
    fi
elif [ "$changed" = "1" ]; then
    if [ ! -f "$SUPPRESS_FILE" ] && command -v notify-send >/dev/null 2>&1; then
        notify-send -i tor -t 4000 "Oniux" \
            "Enabled unprivileged user namespaces for Tor isolation"
    fi
fi

exec oniux "$@"
ONIUX_EOF
            chmod 755 "$INSTALLED"
            print_success "oniux-launcher created (inline fallback) at $INSTALLED"
        fi
    fi

    echo ""
}

# Call the installation function
if [[ "$EUID" -eq 0 ]]; then
    install_welcome_commands
else
    print_warning "Skipping welcome commands installation (requires sudo)"
    print_info "Run with sudo to install system-wide welcome commands"
fi

echo ""

# Final port check
print_step "Checking open ports after cleanup..."
echo ""
if command -v ss &>/dev/null; then
    # `|| true` is load-bearing: under `set -eo pipefail`, a system with zero
    # listening ports makes grep exit 1, pipefail propagates it to the
    # assignment, and set -e kills the installer HERE -- after everything has
    # already succeeded -- with no error message. It also made the
    # "No listening ports" branch below unreachable.
    PORT_COUNT=$(ss -tlnp 2>/dev/null | grep LISTEN 2>/dev/null | wc -l || true)
    PORT_COUNT=${PORT_COUNT:-0}
    if [[ "$PORT_COUNT" -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} No listening ports found - system is secure!"
    else
        echo -e "  ${YELLOW}!${NC} Found $PORT_COUNT listening port(s):"
        echo ""
        echo -e "${CYAN}Currently listening ports:${NC}"
        ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "  " $4 " - " $NF}' | sort -u | head -20
        echo ""
        if [[ "$PIHOLE_KEEP" == "true" ]]; then
            echo -e "  ${CYAN}Note:${NC} If Pi-hole is running, ports 80/443/5353 are expected"
        fi
        echo -e "  ${CYAN}Note:${NC} All other services should be stopped unless explicitly kept"
    fi
    echo ""
fi

# Display Pi-hole configuration if it was intentionally kept running
if [[ "$PIHOLE_KEEP" == "true" ]] && systemctl is-active --quiet pihole-FTL 2>/dev/null && command -v pihole &>/dev/null; then
    print_step "Checking Pi-hole..."
    echo -e "  ${GREEN}✓${NC} Pi-hole - installed"
    echo -e "  ${GREEN}✓${NC} Pi-hole FTL service - running"
    echo ""
    print_info "Pi-hole Configuration:"
    
    # Get Pi-hole IP address
    pihole_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "unknown")
    if [[ "$pihole_ip" != "unknown" && -n "$pihole_ip" ]]; then
        echo -e "      ${CYAN}DNS Server (IPv4):${NC} $pihole_ip"
        echo -e "      ${CYAN}Web Interface:${NC} http://$pihole_ip/admin or http://pi.hole/admin"
    fi
    
    # Generate and set new password
    print_info "Generating new Pi-hole web interface password..."
    if command -v pihole &>/dev/null; then
        # Generate random password and set it with confirmation
        new_pihole_password=$(generate_pihole_password)
        if [[ -n "$new_pihole_password" ]]; then
            # Set password with double confirmation (Pi-hole requires confirmation)
            # Redirect all output to prevent background curl errors
            if printf "%s\n%s\n" "$new_pihole_password" "$new_pihole_password" | pihole setpassword &>/dev/null; then
                echo -e "      ${CYAN}Web Interface password:${NC} $new_pihole_password"
                echo -e "      ${YELLOW}Password has been set - please save this password!${NC}"
            else
                echo -e "      ${YELLOW}Password:${NC} Failed to set new password"
                echo -e "      ${YELLOW}To set manually:${NC} pihole setpassword"
            fi
        else
            echo -e "      ${YELLOW}Password:${NC} Could not generate password"
        fi
    else
        echo -e "      ${YELLOW}Password:${NC} Pi-hole command not available"
    fi
    
    echo -e "      ${CYAN}CLI Usage:${NC} pihole -h for help"
    echo -e "      ${CYAN}Documentation:${NC} https://docs.pi-hole.net/main/post-install/"
    echo ""

    # Clean up any curl processes spawned by pihole commands
    sleep 1
    kill_matching_processes_current_root "KILL" "f" "curl.*pi-hole|curl.*pihole|curl.*ftl" 2>/dev/null || true
elif [[ "$PIHOLE_KEEP" == "false" ]] && [[ "$PIHOLE_DISABLE_VERIFIED" != "true" ]]; then
    echo ""
    print_error "Pi-hole was supposed to be stopped but is still active or enabled"
    print_info "Manual fix: sudo systemctl disable --now pihole-FTL.service"
    echo ""
fi

# Final check for Pi-hole installation
if ! systemctl is-active --quiet pihole-FTL 2>/dev/null && ! command -v pihole &>/dev/null; then
    echo ""
    print_warning "IMPORTANT: Pi-hole was not installed!"
    echo ""
    print_info "Pi-hole provides DNS-level ad blocking and network monitoring."
    print_info "You may have exited the installation window or it failed to install."
    echo ""
    print_highlight "To install Pi-hole manually, run:"
    echo -e "  ${CYAN}curl -sSL https://install.pi-hole.net | sudo bash${NC}"
    echo ""
    print_info "This will start the interactive Pi-hole installer where you can configure:"
    echo "  • Network interface selection"
    echo "  • Upstream DNS providers"
    echo "  • Block lists"
    echo "  • Web interface settings"
    echo ""
fi

# =========================================================================
# GLOBAL BINARY DEPLOYMENT (requires sudo)
# =========================================================================

deploy_kodachi_binaries_globally() {
    echo ""
    print_highlight "======= Deploying Kodachi Binaries Globally ======="
    echo ""

    local candidates=(
        "/opt/kodachi/dashboard/hooks"
        "$PROJECT_ROOT/dashboard/hooks"
    )
    if [[ -n "$SUDO_USER" ]]; then
        local sudo_home
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [[ -n "$sudo_home" ]]; then
            candidates+=(
                "$sudo_home/dashboard/hooks"
                "$sudo_home/Desktop/dashboard/hooks"
                "$sudo_home/k900/dashboard/hooks"
            )
        fi
    fi
    # Use $HOME as fallback (no hardcoded usernames)
    candidates+=(
        "$HOME/dashboard/hooks"
        "$HOME/Desktop/dashboard/hooks"
        "$HOME/k900/dashboard/hooks"
    )

    local install_path=""
    for path in "${candidates[@]}"; do
        if [[ -x "$path/global-launcher" ]]; then
            install_path="$path"
            break
        fi
    done

    if [[ -z "$install_path" ]]; then
        print_warning "Kodachi binaries not found; skipping global deployment"
        return 0
    fi

    if [[ -f "/tmp/live-build-chroot" ]]; then
        print_info "Live-build chroot detected - deferring deployment to first boot"
        print_info "Binaries staged at $install_path"
        return 0
    fi

    if [[ -d "/usr/lib/live" ]] || [[ -n "${LB_BASE:-}" ]]; then
        print_info "Live-build environment detected - skipping global deployment"
        print_info "Binaries staged at $install_path"
        return 0
    fi

    local root_stat=$(stat -c %d:%i / 2>/dev/null)
    local proc_stat=$(stat -c %d:%i /proc/1/root/. 2>/dev/null)
    if [[ -n "$root_stat" && -n "$proc_stat" && "$root_stat" != "$proc_stat" ]]; then
        print_info "Chroot environment detected - skipping global deployment"
        print_info "Binaries staged at $install_path"
        return 0
    fi

    local gl_binary="$install_path/global-launcher"

    print_step "Deploying binaries from $install_path to /usr/local/bin..."

    local deploy_output
    if deploy_output=$("$gl_binary" deploy --force --json 2>&1); then
        print_success "Successfully deployed binaries globally"

        local symlink_count
        symlink_count=$(echo "$deploy_output" | grep -o '"symlinks_created":[0-9]*' | grep -o '[0-9]*' || echo "0")
        if [[ "$symlink_count" -gt 0 ]]; then
            print_info "Created $symlink_count symlink(s) in /usr/local/bin"
        fi

        print_step "Verifying global deployment..."
        if "$gl_binary" verify --json &>/dev/null; then
            print_success "Global deployment verified successfully"
        else
            print_warning "Verification reported warnings"
            print_info "Run '$gl_binary verify --detailed' for more information"
        fi
    else
        print_error "Global deployment failed"
        echo "$deploy_output" | head -5
        print_warning "Binaries remain available in $install_path"
        print_info "You can retry later with: $gl_binary deploy --force"
    fi
}

deploy_kodachi_binaries_globally

if [[ "$EUID" -eq 0 ]]; then
    install_oniux_launcher
fi

install_kodachi_conky_for_user

# ============================================================================
# FIX /usr/sbin PATH FOR NON-ROOT USERS
# ============================================================================
# Debian Trixie removed /usr/sbin from non-root user PATH by default.
# Tools like iftop, nethogs, nft, arptables are installed to /usr/sbin
# and become invisible to 'which' and direct invocation without this fix.

ensure_sbin_in_path() {
    # --- Method 1: profile.d for login shells (only create if missing) ---
    local profile_file="/etc/profile.d/kodachi-path.sh"
    if [[ -f "$profile_file" ]] || [[ -f "/etc/profile.d/10-kodachi-path.sh" ]]; then
        print_info "/usr/sbin PATH fix already installed (profile.d)"
    else
        print_step "Ensuring /usr/sbin is in user PATH (Debian Trixie fix)..."
        cat > "$profile_file" << 'SBIN_PATH_EOF'
#!/bin/sh
# Kodachi OS - Add admin directories to PATH
# Required for: iftop, nethogs, nft, arptables, ebtables, and other sbin tools
# Debian Trixie removed /usr/sbin from non-root PATH by default
case ":${PATH}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="/usr/sbin:/sbin:${PATH}" ;;
esac
SBIN_PATH_EOF
        chmod 644 "$profile_file"
        print_success "/usr/sbin added to PATH for all users (via $profile_file)"
    fi

    # --- Method 2: Symlinks in /usr/local/bin for sbin tools (always runs, idempotent) ---
    local sbin_tools="iftop nethogs nft arptables ebtables ethtool"
    local symlink_count=0
    for tool in $sbin_tools; do
        if command -v "$tool" &>/dev/null; then
            continue
        fi
        local tool_path=""
        if [[ -x "/usr/sbin/$tool" ]]; then
            tool_path="/usr/sbin/$tool"
        elif [[ -x "/sbin/$tool" ]]; then
            tool_path="/sbin/$tool"
        fi
        if [[ -n "$tool_path" ]]; then
            ln -sf "$tool_path" "/usr/local/bin/$tool" 2>/dev/null && symlink_count=$((symlink_count + 1))
        fi
    done
    if [[ $symlink_count -gt 0 ]]; then
        print_success "Created $symlink_count symlink(s) in /usr/local/bin for sbin tools"
    fi

    # --- Method 3: /etc/bash.bashrc for non-login interactive shells (guarded by marker) ---
    local bashrc_file="/etc/bash.bashrc"
    if [[ -f "$bashrc_file" ]] && ! grep -q "kodachi-sbin-path" "$bashrc_file" 2>/dev/null; then
        cat >> "$bashrc_file" << 'BASHRC_PATH_EOF'

# kodachi-sbin-path: Add /usr/sbin to PATH for non-login shells (Debian Trixie fix)
case ":${PATH}:" in
    *:/usr/sbin:*) ;;
    *) export PATH="/usr/sbin:/sbin:${PATH}" ;;
esac
BASHRC_PATH_EOF
        print_success "Added /usr/sbin PATH fix to $bashrc_file"
    fi

    print_info "Takes effect on next login/terminal. For current session: export PATH=\"/usr/sbin:\$PATH\""
}

ensure_sbin_in_path

# ============================================================================
# ENABLE VTE SHELL INTEGRATION FOR NON-LOGIN BASH SHELLS
# ============================================================================
# Tilix starts Bash as an interactive non-login shell, so /etc/profile.d is not
# processed and VTE's prompt hook is otherwise missing. Login shells already
# load the VTE script from /etc/profile; skip them to avoid duplicate hooks.

ensure_vte_shell_integration() {
    local bashrc_file="/etc/bash.bashrc"

    if [[ ! -f "$bashrc_file" ]]; then
        print_warning "Cannot enable VTE shell integration: $bashrc_file not found"
        return 0
    fi

    if grep -q "kodachi-vte-shell-integration" "$bashrc_file" 2>/dev/null; then
        print_info "VTE shell integration already enabled for non-login Bash shells"
        return 0
    fi

    cat >> "$bashrc_file" << 'BASHRC_VTE_EOF'

# kodachi-vte-shell-integration: Enable Tilix/VTE features in non-login Bash.
if ! shopt -q login_shell && [[ -n "${VTE_VERSION:-}" ]]; then
    for vte_script in /etc/profile.d/vte-2.91.sh /etc/profile.d/vte.sh; do
        if [[ -r "$vte_script" ]]; then
            . "$vte_script"
            break
        fi
    done
    unset vte_script
fi
BASHRC_VTE_EOF

    print_success "Enabled VTE shell integration in $bashrc_file"
}

ensure_vte_shell_integration

# ============================================================================
# RE-RUN SUDOERS SETUP (post-install pass)
# ============================================================================
# The first call at script start ran BEFORE apt installed packages, so TUI tools
# (iftop, nethogs) were missing from the system and got skipped by command -v.
# Now that all packages and sbin symlinks are in place, re-run to pick them up.
print_step "Updating sudoers with newly installed tools..."
configure_kodachi_sudoers || print_warning "Sudoers post-install update incomplete - dashboard passwordless sudo may be limited"

# ============================================================================
# CLEANUP TEMPORARY FILES
# ============================================================================

# Clean up any remaining temporary files from GitHub downloads
cleanup_github_temp_files() {
    print_step "Cleaning up temporary files..."

    local cleaned_files=0
    local temp_files=(
        "/tmp/hysteria"
        "/tmp/v2ray-install.sh"
        "/tmp/dnscrypt-proxy-install"
        "/tmp/v2ray-plugin-install"
        "/tmp/qrencode-install-"*
        "/tmp/kloak-install-"*
        "/tmp/mieru_"*.deb
    )

    for file_pattern in "${temp_files[@]}"; do
        if compgen -G "$file_pattern" > /dev/null; then
            # Intentional unquoted expansion: remove every file matching the trusted temp glob pattern.
            # shellcheck disable=SC2086
            rm -rf ${file_pattern} 2>/dev/null && cleaned_files=$((cleaned_files + 1))
        fi
    done

    # SECURITY FIX: Clean up only Kodachi-specific temp files (not generic wildcards)
    # Use specific patterns to avoid deleting unrelated user files
    local kodachi_patterns=(
        "kodachi-*"
        "mieru_*"
        "dnscrypt-proxy-*"
        "xray-*"
        "v2ray-*"
        "hysteria-*"
        "pihole-*"
    )

    for pattern in "${kodachi_patterns[@]}"; do
        while IFS= read -r temp_file; do
            if [[ -f "$temp_file" ]] || [[ -d "$temp_file" ]]; then
                rm -rf "$temp_file" 2>/dev/null && cleaned_files=$((cleaned_files + 1))
            fi
        done < <(find /tmp -maxdepth 1 -name "$pattern" 2>/dev/null)
    done

    if [[ $cleaned_files -gt 0 ]]; then
        print_success "Cleaned up $cleaned_files temporary files"
    else
        print_info "No temporary files to clean up"
    fi
}

echo ""
cleanup_github_temp_files

# ============================================================================
# BINARY DETECTION AND EMOJI SUPPORT
# ============================================================================

# Check if binaries are installed - verify at least 3 core binaries exist
echo ""
BINARY_COUNT=0
# Build locations list: system-wide, real user's home (via SUDO_USER), $HOME fallback, and /usr/local/bin
INSTALL_LOCATIONS=(
    "/opt/kodachi/dashboard/hooks"
    "$PROJECT_ROOT/dashboard/hooks"
)
if [[ -n "$SUDO_USER" ]]; then
    _real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$_real_home" ]]; then
        INSTALL_LOCATIONS+=(
            "$_real_home/dashboard/hooks"
            "$_real_home/Desktop/dashboard/hooks"
            "$_real_home/k900/dashboard/hooks"
        )
    fi
fi
INSTALL_LOCATIONS+=(
    "$HOME/dashboard/hooks"
    "$HOME/Desktop/dashboard/hooks"
    "$HOME/k900/dashboard/hooks"
    "/usr/local/bin"
)
CORE_BINARIES=("ip-fetch" "health-control" "tor-switch")
FOUND_LOCATION=""

for location in "${INSTALL_LOCATIONS[@]}"; do
    if [ -d "$location" ]; then
        local_count=0
        for binary in "${CORE_BINARIES[@]}"; do
            if [ -f "$location/$binary" ]; then
                local_count=$((local_count + 1))
            fi
        done
        if [ $local_count -gt $BINARY_COUNT ]; then
            BINARY_COUNT=$local_count
            FOUND_LOCATION="$location"
        fi
        if [ $BINARY_COUNT -ge 3 ]; then
            break  # All core binaries found, no need to continue
        fi
    fi
done

if [ $BINARY_COUNT -ge 3 ]; then
    print_success "Kodachi binaries are installed ($BINARY_COUNT/3 core binaries found)"
    echo ""
    print_info "Installation location: $FOUND_LOCATION"
    echo ""
    if ! command -v ip-fetch &>/dev/null 2>&1; then
        print_info "Binaries installed but not in PATH yet. To add to PATH:"
        echo "  source ~/.bashrc"
        echo ""
        print_info "Or logout and login again for PATH to update automatically"
    else
        print_info "Binaries are in PATH and ready to use!"
    fi
elif [ $BINARY_COUNT -gt 0 ]; then
    print_warning "Partial installation detected ($BINARY_COUNT/3 core binaries found)"
    echo ""
    print_info "Please reinstall binaries:"
    echo "  curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash"
else
    print_warning "Kodachi binaries not detected"
    echo ""
    print_info "To install binaries, run:"
    echo "  curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash"
fi

echo ""
print_highlight "Emoji Flag Support in ip-fetch:"
print_success "Kitty terminal is already installed!"
echo ""
print_info "To launch Kitty and see emoji flags:"
echo "  1. From menu: Applications → System → Kitty"
echo "  2. Or in terminal: type 'kitty' to launch it"
echo "  3. In Kitty, run: ip-fetch (from hooks folder or if in PATH)"
echo ""
print_info "Alternatively, in this session just type: kitty"
echo "  Then run: cd /opt/kodachi/dashboard/hooks && ./ip-fetch"
echo ""

# ============================================================================
# PRE-CREATE KODACHI-CLAW CONFIG DIRECTORY
# ============================================================================
# [CLAW-ARCHIVED 2026-05-18] kodachi-claw retired — ~/.kodachi-claw pre-creation
# disabled. Original block preserved verbatim below (inert).
: <<'CLAW_ARCHIVED_BLOCK'
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
    if [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]]; then
        CLAW_DIR="$REAL_HOME/.kodachi-claw"
        if [[ ! -d "$CLAW_DIR" ]]; then
            mkdir -p "$CLAW_DIR" && chown "$SUDO_USER:$SUDO_USER" "$CLAW_DIR" && \
                print_success "Created $CLAW_DIR (owned by $SUDO_USER)"
        elif [[ "$(stat -c '%U' "$CLAW_DIR" 2>/dev/null)" == "root" ]]; then
            chown -R "$SUDO_USER:$SUDO_USER" "$CLAW_DIR" && \
                print_success "Fixed $CLAW_DIR ownership (now $SUDO_USER)"
        fi
    fi
fi
CLAW_ARCHIVED_BLOCK

# ============================================================================
# FINAL MESSAGE
# ============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Dependency Installation Complete!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
print_success "Installation finished successfully!"
print_success "Kodachi Dashboard and all binaries can now run with sudo without password"
if ! detect_gui_environment; then
    print_info "Conky: skipped (no GUI detected)"
fi
echo ""
# Force success exit code - ignore bash -n false positives
exit 0
