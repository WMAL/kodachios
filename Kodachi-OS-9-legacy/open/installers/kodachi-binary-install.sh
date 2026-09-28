#!/bin/bash

# Kodachi Binary Installation Script
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
# Last updated: 2026-02-22
#
# Description:
# This script downloads and installs Kodachi security tool binaries
# Installs Kodachi security binaries to /opt/kodachi/dashboard/hooks/
# by default. May request sudo once to create the /opt/kodachi/ directory.
# Supports alternative installation paths including Desktop and custom directories.
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
#   # Default installation to /opt/kodachi/dashboard/hooks
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash
#
#   # Install to Desktop
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash -s -- --desktop
#
#   # Install to custom path
#   curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-binary-install.sh | bash -s -- --path /custom/path
#
# Options:
#   --desktop       Install to ~/Desktop/dashboard/hooks
#   --path PATH     Install to custom path (must be writable)
#   --version VER   Specify version (default: 9.0.1)
#   --skip-path     Don't add to PATH in .bashrc
#   --help          Show help message

set -euo pipefail

# Refuse root execution to keep this user-space only
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "[ERROR] Do not run as root. Use regular user." >&2
    exit 1
fi

# Color codes for output (only if TTY is present)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    MAGENTA=""
    BOLD=""
    NC=""
fi

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_step() { echo -e "${CYAN}[→]${NC} $1"; }
print_highlight() { echo -e "${MAGENTA}${BOLD}$1${NC}"; }

# Stop Conky safely before updating its files to prevent CPU spike / freeze.
# The watchdog service is disabled+stopped so Restart=always cannot respawn it.
# The launcher is also killed to prevent in-flight conky spawns.
# Conky will be restarted automatically by install_conky_watchdog() later.
safe_stop_conky() {
    if ! pgrep -x conky >/dev/null 2>&1; then
        return 0
    fi

    print_info "Stopping Conky before file update..."

    # 1. Disable + stop the watchdog/timer so user-systemd cannot respawn
    # refresh activity while Conky assets are being replaced.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now conky-watchdog.service conky-snapshot-refresh.timer >/dev/null 2>&1 || true
        systemctl --user stop conky-snapshot-refresh.service >/dev/null 2>&1 || true
    fi

    # 2. Kill watchdog and launcher processes (launcher spawns new conky instances)
    pkill -f conky-watchdog >/dev/null 2>&1 || true
    pkill -f conky-launcher >/dev/null 2>&1 || true
    sleep 1

    # 3. Graceful stop all conky
    pkill -x conky >/dev/null 2>&1 || true
    sleep 2

    # 4. Force kill if still alive
    if pgrep -x conky >/dev/null 2>&1; then
        pkill -9 -x conky >/dev/null 2>&1 || true
        sleep 1
    fi

    # 5. Verify clean kill
    if pgrep -x conky >/dev/null 2>&1; then
        print_warning "Some Conky processes survived; forcing final cleanup"
        pkill -9 -x conky >/dev/null 2>&1 || true
        pkill -9 -f conky-launcher >/dev/null 2>&1 || true
    fi

    print_info "Conky stopped for update (will restart automatically)"
}

# Configuration
CDN_BASE="https://www.kodachi.cloud/apps/os/install"
PACK_BASE="https://www.kodachi.cloud/downloads/installers/binaries"
PACK_BASE_FALLBACK="$PACK_BASE"  # canonical single location (apps/os/install pack retired)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" ]] && [[ -e "$SCRIPT_SOURCE" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"
CONKY_PACKAGE_LOCAL_SOURCE="$PROJECT_ROOT/livebuild-assets/conky"
CONKY_CONFIG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
CONKY_INSTALL_DIR="$CONKY_CONFIG_BASE/kodachi/conky"
CONKY_AUTOSTART_FILE="$CONKY_CONFIG_BASE/autostart/kodachi-conky.desktop"
CONKY_SETUP_DONE=false
PERMISSION_GUARD_SKIPPED=false
SKIPPED_COUNT=0
INSTALL_IS_UPDATE=false
MANAGED_BINARIES_FILE=""
INSTALL_METADATA_FILE=""
USER_SPECIFIED_VERSION=false
LATEST_KODACHI_VERSION=""
LATEST_KODACHI_BUILD_NUMBER=""
LATEST_KODACHI_LAST_BUILD_DATE=""
LATEST_KODACHI_CHECKSUM=""
LATEST_KODACHI_METADATA_SOURCE=""
PACKAGE_SHA256=""

compare_kodachi_versions() {
    local v1="${1#v}"
    local v2="${2#v}"
    local first_sorted=""

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    first_sorted="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)"
    if [[ "$first_sorted" == "$v1" ]]; then
        return 2
    fi

    return 1
}

version_is_older_kodachi() {
    compare_kodachi_versions "$1" "$2"
    [[ $? -eq 2 ]]
}

read_binary_pack_metadata_from_main_info() {
    local source_file="$1"
    python3 - "$source_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

binary_pack = data.get("binary_pack") or {}
version = str(binary_pack.get("main_version") or "").strip()
if not version:
    raise SystemExit(1)

build_number = str(binary_pack.get("build_number") or "").strip()
last_build_date = str(binary_pack.get("last_build_date") or "").strip()
checksum_sha256 = str(binary_pack.get("checksum_sha256") or "").strip()

print("|".join([version, build_number, last_build_date, checksum_sha256]))
PY
}

resolve_default_binary_pack_metadata() {
    local candidate=""
    local json_file=""
    local tmp_file=""
    local metadata=""
    local candidates=(
        "$SCRIPT_DIR/../main-info.json"
        "$SCRIPT_DIR/main-info.json"
    )

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/installers/main-info.json")
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            metadata="$(read_binary_pack_metadata_from_main_info "$candidate" 2>/dev/null || true)"
            if [[ -n "$metadata" ]]; then
                printf '%s|%s\n' "$metadata" "$candidate"
                return 0
            fi
        fi
    done

    if command -v curl >/dev/null 2>&1; then
        tmp_file="$(mktemp)"
        for json_file in \
            "https://www.kodachi.cloud/apps/os/main-info.json" \
            "https://kodachi.cloud/apps/os/main-info.json"; do
            if curl -fsSL "$json_file" -o "$tmp_file" 2>/dev/null; then
                metadata="$(read_binary_pack_metadata_from_main_info "$tmp_file" 2>/dev/null || true)"
                if [[ -n "$metadata" ]]; then
                    rm -f "$tmp_file"
                    printf '%s|%s\n' "$metadata" "$json_file"
                    return 0
                fi
            fi
        done
        rm -f "$tmp_file"
    fi

    printf '9.0.1||||built-in-fallback\n'
}

read_installed_binary_pack_metadata() {
    local metadata_file="$1"
    local key=""
    local value=""
    local version=""
    local build_number=""
    local last_build_date=""
    local checksum_sha256=""
    local installed_at=""

    [[ -f "$metadata_file" ]] || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            version) version="$value" ;;
            build_number) build_number="$value" ;;
            last_build_date) last_build_date="$value" ;;
            checksum_sha256) checksum_sha256="$value" ;;
            installed_at) installed_at="$value" ;;
        esac
    done < "$metadata_file"

    printf '%s|%s|%s|%s|%s\n' "$version" "$build_number" "$last_build_date" "$checksum_sha256" "$installed_at"
}

write_installed_binary_pack_metadata() {
    local metadata_file="$1"
    local version="$2"
    local build_number="$3"
    local last_build_date="$4"
    local checksum_sha256="$5"

    cat > "$metadata_file" <<EOF
version=$version
build_number=$build_number
last_build_date=$last_build_date
checksum_sha256=$checksum_sha256
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

report_binary_pack_freshness() {
    local installed_metadata=""
    local installed_version=""
    local installed_build_number=""
    local installed_last_build_date=""
    local installed_checksum=""
    local installed_at=""

    if [[ -n "$LATEST_KODACHI_VERSION" ]]; then
        if [[ -n "$LATEST_KODACHI_BUILD_NUMBER" || -n "$LATEST_KODACHI_LAST_BUILD_DATE" ]]; then
            print_info "Latest published binary pack: v${LATEST_KODACHI_VERSION} (build ${LATEST_KODACHI_BUILD_NUMBER:-unknown}, published ${LATEST_KODACHI_LAST_BUILD_DATE:-unknown})"
        else
            print_info "Latest published binary pack: v${LATEST_KODACHI_VERSION}"
        fi
    fi

    if [[ "$USER_SPECIFIED_VERSION" == "true" ]] && [[ -n "$LATEST_KODACHI_VERSION" ]] && [[ "$KODACHI_VERSION" != "$LATEST_KODACHI_VERSION" ]]; then
        if version_is_older_kodachi "$KODACHI_VERSION" "$LATEST_KODACHI_VERSION"; then
            print_warning "Requested version v${KODACHI_VERSION} is older than the latest published pack v${LATEST_KODACHI_VERSION} (${LATEST_KODACHI_LAST_BUILD_DATE:-date unknown})"
        else
            print_info "Requested version override: v${KODACHI_VERSION}"
        fi
    fi

    if [[ -z "$INSTALL_METADATA_FILE" || ! -f "$INSTALL_METADATA_FILE" ]]; then
        return 0
    fi

    installed_metadata="$(read_installed_binary_pack_metadata "$INSTALL_METADATA_FILE" 2>/dev/null || true)"
    if [[ -z "$installed_metadata" ]]; then
        return 0
    fi

    IFS='|' read -r installed_version installed_build_number installed_last_build_date installed_checksum installed_at <<< "$installed_metadata"
    if [[ -z "$installed_version" ]]; then
        return 0
    fi

    if [[ -n "$LATEST_KODACHI_CHECKSUM" && -n "$installed_checksum" ]]; then
        if [[ "$installed_checksum" == "$LATEST_KODACHI_CHECKSUM" ]]; then
            print_success "Existing installation already matches the latest published binary pack"
        else
            print_warning "Existing installation is older than the latest published binary pack (installed v${installed_version} from ${installed_last_build_date:-unknown}, latest v${LATEST_KODACHI_VERSION} from ${LATEST_KODACHI_LAST_BUILD_DATE:-unknown})"
        fi
        return 0
    fi

    if [[ -n "$LATEST_KODACHI_VERSION" ]] && version_is_older_kodachi "$installed_version" "$LATEST_KODACHI_VERSION"; then
        print_warning "Existing installation version v${installed_version} is older than latest v${LATEST_KODACHI_VERSION}"
    fi
}

DEFAULT_BINARY_PACK_METADATA="$(resolve_default_binary_pack_metadata)"
IFS='|' read -r KODACHI_VERSION LATEST_KODACHI_BUILD_NUMBER LATEST_KODACHI_LAST_BUILD_DATE LATEST_KODACHI_CHECKSUM LATEST_KODACHI_METADATA_SOURCE <<< "$DEFAULT_BINARY_PACK_METADATA"
LATEST_KODACHI_VERSION="$KODACHI_VERSION"

get_desktop_dir() {
    local desktop_dir="$HOME/Desktop"
    if command -v xdg-user-dir >/dev/null 2>&1; then
        local xdg_desktop
        xdg_desktop=$(xdg-user-dir DESKTOP 2>/dev/null || true)
        if [[ -n "$xdg_desktop" ]]; then
            desktop_dir="$xdg_desktop"
        fi
    fi
    echo "$desktop_dir"
}

get_fallback_hooks_dir() {
    local candidates=()

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/dashboard/hooks")
    fi
    candidates+=(
        "$HOME/dashboard/hooks"
        "$HOME/k900/dashboard/hooks"
        "$HOME/Desktop/dashboard/hooks"
    )

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # Last resort: keep old default under home but without assuming repo layout.
    echo "$HOME/dashboard/hooks"
}

detect_existing_installation_mode() {
    local marker=""
    local markers=(
        "$INSTALL_PATH/kodachi-dashboard"
        "$INSTALL_PATH/health-control"
        "$INSTALL_PATH/config"
        "$INSTALL_PATH/results/signatures"
        "$INSTALL_PATH/.kodachi-managed-binaries.list"
    )

    for marker in "${markers[@]}"; do
        if [[ -e "$marker" ]]; then
            INSTALL_IS_UPDATE=true
            return 0
        fi
    done

    INSTALL_IS_UPDATE=false
    return 1
}

# Detect whether this system has a GUI desktop environment (XFCE/GNOME/etc.)
detect_gui_environment() {
    # Active GUI session
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        return 0
    fi

    # Session type hint from login manager
    if [[ "${XDG_SESSION_TYPE:-}" == "x11" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        return 0
    fi

    # Installed desktop session files (XFCE, GNOME, KDE, etc.)
    if compgen -G "/usr/share/xsessions/*.desktop" >/dev/null 2>&1 || \
       compgen -G "/usr/share/wayland-sessions/*.desktop" >/dev/null 2>&1; then
        return 0
    fi

    # Common desktop environment packages (Debian/Ubuntu family)
    if command -v dpkg >/dev/null 2>&1; then
        local desktop_packages=(
            "xfce4" "xfce4-session" "gnome-shell" "plasma-desktop"
            "mate-desktop" "lxde" "lxqt-core" "cinnamon"
        )
        local pkg=""
        for pkg in "${desktop_packages[@]}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                return 0
            fi
        done
    fi

    return 1
}

# Parse command line arguments
INSTALL_PATH=""
SKIP_PATH_UPDATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --path)
            INSTALL_PATH="$2"
            shift 2
            ;;
        --desktop)
            INSTALL_PATH="$(get_desktop_dir)/dashboard/hooks"
            shift
            ;;
        --version)
            KODACHI_VERSION="$2"
            USER_SPECIFIED_VERSION=true
            shift 2
            ;;
        --skip-path)
            SKIP_PATH_UPDATE=true
            shift
            ;;
        --help)
            echo "Kodachi Binary Installation Script"
            echo ""
            echo "Usage:"
            echo "  curl -sSL $CDN_BASE/kodachi-binary-install.sh | bash"
            echo ""
            echo "Options:"
            echo "  --desktop       Install to ~/Desktop/dashboard/hooks"
            echo "  --path PATH     Install to custom path"
            echo "  --version VER   Specify version (default: $KODACHI_VERSION)"
            echo "  --skip-path     Don't add to PATH in .bashrc"
            echo "  --help          Show this help message"
            echo ""
            echo "After installation, run the dependency installer:"
            echo "  curl -sSL $CDN_BASE/kodachi-deps-install.sh | sudo bash"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Welcome message (shown before path detection so user has context)
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Kodachi Binary Installation Script       ║${NC}"
echo -e "${CYAN}║        Default: /opt/kodachi/                ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Set default install path if not specified
if [[ -z "$INSTALL_PATH" ]]; then
    INSTALL_PATH="/opt/kodachi/dashboard/hooks"

    # Keep the install tree writable during package staging. The final
    # production hardening step protects the hooks ancestors and signed
    # binaries without recursively changing ownership of runtime state.
    if [[ ! -d "/opt/kodachi" ]]; then
        print_info "Creating /opt/kodachi/ (requires sudo)..."
        if sudo install -d -o "$EUID" -g "$(/usr/bin/id -g)" -m 0755 \
            "/opt/kodachi" "/opt/kodachi/dashboard" "/opt/kodachi/dashboard/hooks"; then
            print_success "Created /opt/kodachi/ staging tree for $(whoami)"
        else
            print_warning "Could not create /opt/kodachi/ — falling back to home directory"
            INSTALL_PATH="$(get_fallback_hooks_dir)"
        fi
    elif [[ ! -w "/opt/kodachi/dashboard/hooks" ]]; then
        # A completed install is root-owned. Re-open only the three staging
        # ancestors, never the complete /opt/kodachi subtree.
        print_info "Preparing /opt/kodachi/ staging ownership (requires sudo)..."
        if sudo install -d -o "$EUID" -g "$(/usr/bin/id -g)" -m 0755 \
            "/opt/kodachi" "/opt/kodachi/dashboard" "/opt/kodachi/dashboard/hooks"; then
            print_success "Prepared /opt/kodachi/ staging tree"
        else
            print_warning "Cannot write to /opt/kodachi/ — falling back to home directory"
            INSTALL_PATH="$(get_fallback_hooks_dir)"
        fi
    fi
fi

MANAGED_BINARIES_FILE="$INSTALL_PATH/.kodachi-managed-binaries.list"
INSTALL_METADATA_FILE="$INSTALL_PATH/.kodachi-binary-pack.metadata"
if detect_existing_installation_mode; then
    print_warning "Existing Kodachi installation detected at: $INSTALL_PATH"
    print_info "Changing mode to UPDATE: replacing managed binaries and refreshing startup entries."
else
    print_info "No previous Kodachi installation detected. Running in install mode."
fi

report_binary_pack_freshness

print_info "Installing Kodachi binaries to: $INSTALL_PATH"
echo ""

# Check for curl prerequisite
if ! command -v curl &>/dev/null; then
    print_error "curl is required but not found"
    print_info "This script requires curl to download packages"
    print_info "Install it with: sudo apt-get install curl"
    exit 1
fi

# ============================================================================
# TIME SYNCHRONIZATION - Critical for HTTPS certificate validation
# ============================================================================
print_step "Checking system time synchronization..."
if command -v timedatectl >/dev/null 2>&1; then
    ntp_status=$(timedatectl status 2>/dev/null | awk -F': ' '/System clock synchronized/ {print tolower($2)}' || true)
    if [[ "$ntp_status" == "yes" ]]; then
        print_success "System clock already synchronized"
    else
        print_warning "System clock not yet synchronized; run 'sudo timedatectl set-ntp true' after installing dependencies"
    fi
else
    print_warning "timedatectl not found; skipping automatic time sync check"
fi
echo ""

# Check if we can write to the installation path
if [[ -e "$INSTALL_PATH" ]] && [[ ! -w "$INSTALL_PATH" ]]; then
    print_error "Cannot write to $INSTALL_PATH"
    print_info "Please choose a different path or fix permissions"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to download with retry, resume support, and stall detection
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries=5
    local retry=0
    local backoff=2
    local curl_progress="--silent"

    # Show progress bar if running in a terminal
    if [ -t 1 ]; then
        curl_progress="--progress-bar"
    fi

    while [[ $retry -lt $max_retries ]]; do
        local exit_code=0
        curl --fail --location --show-error \
               $curl_progress \
               --connect-timeout 15 \
               --speed-limit 50000 --speed-time 30 \
               -C - \
               "$url" -o "$output" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            return 0
        fi

        retry=$((retry + 1))

        # Exit code 33 = range request not supported, restart without resume
        if [[ $exit_code -eq 33 ]]; then
            rm -f "$output"
        fi

        if [[ $retry -lt $max_retries ]]; then
            print_warning "Download failed (attempt $retry/$max_retries), retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff + retry + 1))
        fi
    done

    return 1
}

# Wrapper for pack/sig/key/checksum downloads: try PACK_BASE first, fall back to
# PACK_BASE_FALLBACK (the old apps/os/install location) if the primary fails.
# Preserves all retry/resume behaviour of download_with_retry.
download_pack_file() {
    local url_path="$1"   # filename only, e.g. "kodachi-binaries-v9.0.1.tar.gz"
    local output="$2"

    local primary_url="${PACK_BASE}/${url_path}"
    local fallback_url="${PACK_BASE_FALLBACK}/${url_path}"

    if download_with_retry "$primary_url" "$output"; then
        return 0
    fi

    print_warning "Primary download failed ($primary_url), trying fallback location..."
    rm -f "$output"
    if download_with_retry "$fallback_url" "$output"; then
        print_warning "Used fallback download location for: $url_path"
        return 0
    fi

    return 1
}

# Function to verify signature
verify_signature() {
    local binary_path="$1"
    local signature_dir="$2"
    local binary_name=""
    local sig_file=""
    local pub_key=""

    binary_name="$(basename -- "$binary_path")"
    sig_file="$signature_dir/${binary_name}_v${KODACHI_VERSION}.sig"
    pub_key="$signature_dir/../config/signkeys/public_key_v${KODACHI_VERSION}.pem"

    if [[ ! -f "$sig_file" || -L "$sig_file" ]]; then
        return 1
    fi
    if [[ ! -f "$pub_key" || -L "$pub_key" ]]; then
        return 1
    fi

    if /usr/bin/openssl dgst -sha256 -verify "$pub_key" \
        -signature "$sig_file" "$binary_path" &>/dev/null; then
        return 0
    fi
    return 1
}

# BEGIN KODACHI AUTH TRUST INSTALL FUNCTIONS
atomic_install_root_file() {
    local source_file="$1"
    local destination_file="$2"
    local file_mode="$3"
    local destination_dir=""
    local destination_name=""
    local temporary_file=""

    destination_dir="$(dirname -- "$destination_file")"
    destination_name="$(basename -- "$destination_file")"
    temporary_file="$destination_dir/.${destination_name}.new.$$"

    if ! sudo install -o root -g root -m "$file_mode" \
        "$source_file" "$temporary_file"; then
        print_error "Cannot stage protected file: $destination_file"
        return 1
    fi
    if ! sudo mv -Tf -- "$temporary_file" "$destination_file"; then
        sudo rm -f -- "$temporary_file" 2>/dev/null || true
        print_error "Cannot atomically activate protected file: $destination_file"
        return 1
    fi
}

cleanup_production_auth_stage() {
    local stage_dir="$1"

    [[ -n "$stage_dir" ]] || return 0
    case "$stage_dir" in
        "$INSTALL_PATH"/.auth-trust-stage.*) ;;
        *)
            print_error "Refusing to clean unexpected auth-trust stage: $stage_dir"
            return 1
            ;;
    esac

    if [[ -e "$stage_dir" || -L "$stage_dir" ]]; then
        sudo /usr/bin/find "$stage_dir" -xdev -depth -delete || return 1
    fi
}

create_production_auth_stage() {
    local dashboard_dir=""
    local kodachi_root=""
    local stage_dir=""
    local stage_owner=""
    local stage_mode=""

    dashboard_dir="$(dirname -- "$INSTALL_PATH")"
    kodachi_root="$(dirname -- "$dashboard_dir")"
    stage_dir="$INSTALL_PATH/.auth-trust-stage.$$.$RANDOM"

    sudo install -d -o root -g root -m 0755 \
        "$kodachi_root" "$dashboard_dir" "$INSTALL_PATH" || return 1
    [[ ! -e "$stage_dir" && ! -L "$stage_dir" ]] || return 1
    sudo install -d -o root -g root -m 0700 "$stage_dir" || return 1

    if ! stage_owner="$(stat -c '%u:%g' -- "$stage_dir")"; then
        cleanup_production_auth_stage "$stage_dir" || true
        return 1
    fi
    if ! stage_mode="$(stat -c '%a' -- "$stage_dir")"; then
        cleanup_production_auth_stage "$stage_dir" || true
        return 1
    fi
    if [[ "$stage_owner" != "0:0" || "$stage_mode" != "700" ]]; then
        print_error "Auth-trust staging directory is not protected"
        cleanup_production_auth_stage "$stage_dir" || true
        return 1
    fi

    AUTH_TRUST_STAGE_DIR="$stage_dir"
}

stage_root_snapshot() {
    local source_file="$1"
    local staged_file="$2"

    if [[ ! -f "$source_file" || -L "$source_file" ]]; then
        return 1
    fi
    sudo install -o root -g root -m 0600 \
        "$source_file" "$staged_file" || return 1
}

stage_package_public_key() {
    local staged_key="$AUTH_TRUST_STAGE_DIR/package-public.pem"

    stage_root_snapshot "$PUBLIC_KEY_FILE" "$staged_key" || {
        print_error "Cannot stage verified package public key"
        return 1
    }
    STAGED_PACKAGE_PUBLIC_KEY="$staged_key"
}

stage_normal_binary_trust() {
    local binary_name=""
    local binary_source=""
    local signature_source=""
    local staged_binary=""
    local staged_signature=""

    STAGED_NORMAL_BINARY_FILES=()
    STAGED_NORMAL_SIGNATURE_FILES=()
    STAGED_NORMAL_SIGNATURE_NAMES=()

    if [[ ! "$KODACHI_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
        print_error "Unsafe release version for protected trust: $KODACHI_VERSION"
        return 1
    fi

    for binary_name in "${FINAL_HARDEN_BINARY_NAMES[@]}"; do
        if [[ ! "$binary_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
            print_error "Unsafe deployed binary name: $binary_name"
            return 1
        fi

        binary_source="$EXTRACT_DIR/binaries/$binary_name"
        signature_source="$EXTRACT_DIR/signatures/${binary_name}_v${KODACHI_VERSION}.sig"
        staged_binary="$AUTH_TRUST_STAGE_DIR/normal-${binary_name}.binary"
        staged_signature="$AUTH_TRUST_STAGE_DIR/normal-${binary_name}.sig"

        stage_root_snapshot "$binary_source" "$staged_binary" || {
            print_error "Cannot stage verified binary: $binary_name"
            return 1
        }
        stage_root_snapshot "$signature_source" "$staged_signature" || {
            print_error "Cannot stage exact detached signature: $binary_name"
            return 1
        }
        if ! sudo /usr/bin/openssl dgst -sha256 -verify "$STAGED_PACKAGE_PUBLIC_KEY" \
            -signature "$staged_signature" "$staged_binary" >/dev/null 2>&1; then
            print_error "Staged package snapshot verification failed: $binary_name"
            return 1
        fi

        STAGED_NORMAL_BINARY_FILES+=("$staged_binary")
        STAGED_NORMAL_SIGNATURE_FILES+=("$staged_signature")
        STAGED_NORMAL_SIGNATURE_NAMES+=("${binary_name}_v${KODACHI_VERSION}.sig")
    done
}

stage_existing_binary_trust() {
    local binary_name="$1"
    local destination_file="$INSTALL_PATH/$binary_name"
    local signature_source=""
    local signature_name=""
    local signature_version=""
    local key_source=""
    local staged_binary="$AUTH_TRUST_STAGE_DIR/legacy-${binary_name}.binary"
    local staged_key="$AUTH_TRUST_STAGE_DIR/legacy-${binary_name}.pem"
    local staged_signature="$AUTH_TRUST_STAGE_DIR/legacy-${binary_name}.sig"

    if [[ ! -f "$destination_file" || -L "$destination_file" ]]; then
        print_error "Cannot stage missing or linked legacy binary: $destination_file"
        return 1
    fi
    [[ -d "$INSTALL_PATH/results/signatures" ]] || return 1

    while IFS= read -r -d '' signature_source; do
        signature_name="$(basename -- "$signature_source")"
        signature_version="${signature_name#${binary_name}_v}"
        signature_version="${signature_version%.sig}"
        [[ "$signature_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || continue
        key_source="$INSTALL_PATH/config/signkeys/public_key_v${signature_version}.pem"

        stage_root_snapshot "$destination_file" "$staged_binary" || continue
        stage_root_snapshot "$key_source" "$staged_key" || continue
        stage_root_snapshot "$signature_source" "$staged_signature" || continue
        sudo /usr/bin/cmp -s -- "$STAGED_PACKAGE_PUBLIC_KEY" "$staged_key" || continue
        if sudo /usr/bin/openssl dgst -sha256 -verify "$staged_key" \
            -signature "$staged_signature" "$staged_binary" >/dev/null 2>&1; then
            STAGED_PRESERVE_BINARY_FILES+=("$staged_binary")
            STAGED_PRESERVE_KEY_FILES+=("$staged_key")
            STAGED_PRESERVE_SIGNATURE_FILES+=("$staged_signature")
            STAGED_PRESERVE_KEY_NAMES+=("public_key_v${signature_version}.pem")
            STAGED_PRESERVE_SIGNATURE_NAMES+=("$signature_name")
            return 0
        fi
    done < <(
        find "$INSTALL_PATH/results/signatures" -maxdepth 1 -type f \
            -name "${binary_name}_v*.sig" -print0 | sort -zV
    )

    print_error "No matching trusted legacy snapshot verified: $destination_file"
    return 1
}

install_production_auth_trust() {
    local binary_name=""
    local staged_binary=""
    local staged_signature=""
    local signature_name=""
    local install_owner_uid=""
    local install_owner_gid=""
    local dashboard_dir=""
    local kodachi_root=""
    local auth_trust_dir="$INSTALL_PATH/auth-trust"
    local auth_signkeys_dir="$auth_trust_dir/signkeys"
    local auth_signatures_dir="$auth_trust_dir/signatures"
    local runtime_dir=""
    local public_key_name="public_key_v${KODACHI_VERSION}.pem"
    local staged_index=0

    install_owner_uid="$EUID"
    install_owner_gid="$(/usr/bin/id -g)"
    if [[ ! "$install_owner_uid" =~ ^[0-9]+$ ]] \
        || [[ ! "$install_owner_gid" =~ ^[0-9]+$ ]] \
        || [[ "$install_owner_uid" -eq 0 ]]; then
        print_error "Cannot resolve a safe non-root runtime owner"
        return 1
    fi

    dashboard_dir="$(dirname -- "$INSTALL_PATH")"
    kodachi_root="$(dirname -- "$dashboard_dir")"

    for runtime_dir in data cache results logs tmp; do
        sudo install -d -o "$install_owner_uid" -g "$install_owner_gid" \
            -m 0755 "$INSTALL_PATH/$runtime_dir" || return 1
        sudo chown -R "$install_owner_uid:$install_owner_gid" \
            "$INSTALL_PATH/$runtime_dir" || return 1
        sudo chmod u+rwx "$INSTALL_PATH/$runtime_dir" || return 1
    done

    sudo install -d -o root -g root -m 0755 \
        "$kodachi_root" "$dashboard_dir" "$INSTALL_PATH" \
        "$auth_trust_dir" "$auth_signkeys_dir" "$auth_signatures_dir" || return 1

    if [[ "${#STAGED_NORMAL_BINARY_FILES[@]}" -gt 0 ]]; then
        atomic_install_root_file \
            "$STAGED_PACKAGE_PUBLIC_KEY" \
            "$auth_signkeys_dir/$public_key_name" 0644 || return 1
    fi

    for binary_name in "${FINAL_HARDEN_BINARY_NAMES[@]}"; do
        staged_binary="${STAGED_NORMAL_BINARY_FILES[$staged_index]}"
        staged_signature="${STAGED_NORMAL_SIGNATURE_FILES[$staged_index]}"
        signature_name="${STAGED_NORMAL_SIGNATURE_NAMES[$staged_index]}"
        atomic_install_root_file \
            "$staged_binary" "$INSTALL_PATH/$binary_name" 0755 || return 1
        atomic_install_root_file \
            "$staged_signature" "$auth_signatures_dir/$signature_name" 0644 || return 1
        if ! /usr/bin/openssl dgst -sha256 \
            -verify "$auth_signkeys_dir/$public_key_name" \
            -signature "$auth_signatures_dir/$signature_name" \
            "$INSTALL_PATH/$binary_name" >/dev/null 2>&1; then
            print_error "Published package trust verification failed: $binary_name"
            return 1
        fi
        staged_index=$((staged_index + 1))
    done

    # The signed host-exposure policy rides in the same signatures/ dir as the binary
    # signatures, and results/signatures receives ALL of that dir (see the cp -r at the
    # end of this script), while this store received only the per-binary pairs. So every
    # fresh ISO shipped results/signatures with 60 entries and auth-trust/signatures with
    # 58, and vm-hooks-trust-gate.sh V3 (bidirectional store parity for the stamp) failed
    # on host-exposure-defaults.json_v<stamp>.sig before any deploy had touched the box.
    # Measured on the <lab-host> live ISO at <lab-host> by <agent> on
    # 2026-09-05, reported for the ISO/signer owner and adopted here on 2026-09-06.
    # build-apt-channels.sh already copies the whole results store into auth-trust for
    # the apt trees, so this only brings the ISO path to the same layout. The policy is
    # a reviewed artifact, not an execution anchor: online-auth composes auth-trust
    # paths per binary name and never enumerates the store, so an extra pair is inert
    # to it, and both integrity-check (results/) and this installer's own policy
    # verification (EXTRACT_DIR/signatures) keep reading where they always did.
    local policy_signature=""
    local policy_signature_name=""
    while IFS= read -r -d '' policy_signature; do
        policy_signature_name="$(basename "$policy_signature")"
        atomic_install_root_file \
            "$policy_signature" "$auth_signatures_dir/$policy_signature_name" 0644 || return 1
    done < <(find "$EXTRACT_DIR/signatures" -maxdepth 1 -type f \
        \( -name 'host-exposure-defaults.json_v*.sig' -o -name 'host-exposure-defaults.json_v*.sig.info' \) \
        -print0 2>/dev/null)

    print_success "Protected production binaries and auth-trust artifacts installed"
}

harden_existing_root_binary_preserving_bytes() {
    local binary_name="$1"
    local staged_binary="$2"
    local staged_key="$3"
    local staged_signature="$4"
    local protected_key_name="$5"
    local protected_signature_name="$6"
    local destination_file="$INSTALL_PATH/$binary_name"
    local auth_trust_dir="$INSTALL_PATH/auth-trust"
    local protected_key="$auth_trust_dir/signkeys/$protected_key_name"
    local protected_signature="$auth_trust_dir/signatures/$protected_signature_name"
    local staged_sha256=""
    local published_sha256=""

    staged_sha256="$(sudo /usr/bin/sha256sum -- "$staged_binary" | awk '{print $1}')" \
        || return 1
    atomic_install_root_file "$staged_binary" "$destination_file" 0755 || return 1
    atomic_install_root_file "$staged_key" "$protected_key" 0644 || return 1
    atomic_install_root_file \
        "$staged_signature" "$protected_signature" 0644 || return 1
    published_sha256="$(/usr/bin/sha256sum -- "$destination_file" | awk '{print $1}')" \
        || return 1

    if [[ "$staged_sha256" != "$published_sha256" ]]; then
        print_error "Published legacy binary differs from verified snapshot: $binary_name"
        return 1
    fi
    if ! /usr/bin/openssl dgst -sha256 -verify "$protected_key" \
        -signature "$protected_signature" "$destination_file" >/dev/null 2>&1; then
        print_error "Published legacy trust verification failed: $binary_name"
        return 1
    fi
}

publish_staged_production_auth_trust() {
    local preserved_binary_name=""
    local preserved_index=0

    if [[ "${#FINAL_HARDEN_BINARY_NAMES[@]}" -gt 0 ]]; then
        install_production_auth_trust || return 1
    else
        sudo install -d -o root -g root -m 0755 \
            "$INSTALL_PATH/auth-trust" \
            "$INSTALL_PATH/auth-trust/signkeys" \
            "$INSTALL_PATH/auth-trust/signatures" || return 1
    fi

    for preserved_binary_name in "${PRESERVE_HARDEN_BINARY_NAMES[@]}"; do
        harden_existing_root_binary_preserving_bytes \
            "$preserved_binary_name" \
            "${STAGED_PRESERVE_BINARY_FILES[$preserved_index]}" \
            "${STAGED_PRESERVE_KEY_FILES[$preserved_index]}" \
            "${STAGED_PRESERVE_SIGNATURE_FILES[$preserved_index]}" \
            "${STAGED_PRESERVE_KEY_NAMES[$preserved_index]}" \
            "${STAGED_PRESERVE_SIGNATURE_NAMES[$preserved_index]}" || return 1
        preserved_index=$((preserved_index + 1))
    done
}

finalize_production_auth_trust() {
    local production_path="$1"
    local preserved_binary_name=""
    local result=0
    local cleanup_result=0

    if [[ "$INSTALL_PATH" != "$production_path" ]]; then
        return 0
    fi
    if [[ "${#FINAL_HARDEN_BINARY_NAMES[@]}" -eq 0 \
        && "${#PRESERVE_HARDEN_BINARY_NAMES[@]}" -eq 0 ]]; then
        return 0
    fi

    AUTH_TRUST_STAGE_DIR=""
    STAGED_PACKAGE_PUBLIC_KEY=""
    STAGED_NORMAL_BINARY_FILES=()
    STAGED_NORMAL_SIGNATURE_FILES=()
    STAGED_NORMAL_SIGNATURE_NAMES=()
    STAGED_PRESERVE_BINARY_FILES=()
    STAGED_PRESERVE_KEY_FILES=()
    STAGED_PRESERVE_SIGNATURE_FILES=()
    STAGED_PRESERVE_KEY_NAMES=()
    STAGED_PRESERVE_SIGNATURE_NAMES=()

    create_production_auth_stage || return 1
    stage_package_public_key || result=1
    if [[ "$result" -eq 0 ]]; then
        stage_normal_binary_trust || result=1
    fi
    for preserved_binary_name in "${PRESERVE_HARDEN_BINARY_NAMES[@]}"; do
        if [[ "$result" -eq 0 ]]; then
            stage_existing_binary_trust "$preserved_binary_name" || result=1
        fi
    done
    if [[ "$result" -eq 0 ]]; then
        publish_staged_production_auth_trust || result=1
    fi

    cleanup_production_auth_stage "$AUTH_TRUST_STAGE_DIR" || cleanup_result=1
    AUTH_TRUST_STAGE_DIR=""
    if [[ "$result" -ne 0 || "$cleanup_result" -ne 0 ]]; then
        return 1
    fi
}
# END KODACHI AUTH TRUST INSTALL FUNCTIONS

host_exposure_rollout_enabled() {
    case "${KODACHI_HOST_EXPOSURE_WATCHER_ENABLED:-0}" in
        1)
            return 0
            ;;
        0|"")
            return 1
            ;;
        *)
            print_error "KODACHI_HOST_EXPOSURE_WATCHER_ENABLED must be exactly 0 or 1"
            return 2
            ;;
    esac
}

install_host_exposure_protected_runtime() {
    local source_binary="$EXTRACT_DIR/binaries/kodachi-soc"
    if [[ ! -f "$source_binary" ]]; then
        return 0
    fi

    local source_policy="$EXTRACT_DIR/config/host-exposure-defaults.json"
    local source_unit="$EXTRACT_DIR/config/systemd/kodachi-soc-watcher.service"
    local source_signature=""
    local source_signature_info=""
    local protected_exec_dir="/usr/local/libexec/kodachi/host-exposure"
    local protected_state_dir="/var/lib/kodachi-soc"
    local protected_signature_dir="$protected_state_dir/signatures"
    local protected_config_dir="$protected_state_dir/config"
    local protected_unit="/etc/systemd/system/kodachi-soc-watcher.service"
    local protected_sudoers="/etc/sudoers.d/kodachi-host-exposure"
    local protected_sysctl="/etc/sysctl.d/90-kodachi-host-exposure.conf"
    local component=""
    local owner=""
    local mode=""
    local rollout_status=0

    source_signature="$(find "$EXTRACT_DIR/signatures" -maxdepth 1 -type f -name 'host-exposure-defaults.json_v*.sig' -print -quit 2>/dev/null || true)"
    source_signature_info="$(find "$EXTRACT_DIR/signatures" -maxdepth 1 -type f -name 'host-exposure-defaults.json_v*.sig.info' -print -quit 2>/dev/null || true)"

    # If the package ships NONE of the host-exposure watcher assets, this build
    # simply predates / omits the optional privileged watcher: skip it cleanly
    # rather than aborting the whole binary install. (The refusal below still
    # fires when the assets are PARTIALLY present, i.e. incomplete or tampered.)
    if [[ ! -f "$source_policy" && ! -f "$source_unit" && -z "$source_signature" && -z "$source_signature_info" ]]; then
        print_info "Host-exposure watcher assets not present in this package; skipping (optional component)"
        return 0
    fi

    if [[ ! -f "$source_policy" || ! -f "$source_unit" || -z "$source_signature" || -z "$source_signature_info" ]]; then
        print_error "Host-exposure protected runtime assets are incomplete"
        print_error "Refusing to install a privileged watcher without its policy, signature, and service unit"
        return 1
    fi
    if ! verify_signature "$source_policy" "$EXTRACT_DIR/signatures"; then
        print_error "Host-exposure default policy signature verification failed"
        return 1
    fi

    for component in /etc /etc/sudoers.d /etc/sysctl.d /usr/local /usr/local/bin /usr/local/libexec /usr/local/libexec/kodachi "$protected_exec_dir" /var/lib "$protected_state_dir"; do
        if [[ -L "$component" ]]; then
            print_error "Protected host-exposure path must not contain a symlink: $component"
            return 1
        fi
        if [[ -e "$component" ]]; then
            owner="$(sudo stat -c '%u' -- "$component" 2>/dev/null || true)"
            mode="$(sudo stat -c '%a' -- "$component" 2>/dev/null || true)"
            if [[ "$owner" != "0" || ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 022)) -ne 0 ]]; then
                print_error "Protected host-exposure path is not root-owned and non-writable by group/other: $component"
                return 1
            fi
        fi
    done

    print_step "Installing protected host-exposure watcher runtime..."
    sudo install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/libexec/kodachi "$protected_exec_dir"
    sudo install -d -o root -g root -m 0711 "$protected_state_dir"
    sudo install -d -o root -g root -m 0755 "$protected_config_dir" "$protected_signature_dir"

    local binary_tmp="$protected_exec_dir/.kodachi-soc.new.$$"
    local policy_tmp="$protected_config_dir/.host-exposure-defaults.json.new.$$"
    local unit_tmp="/etc/systemd/system/.kodachi-soc-watcher.service.new.$$"
    local sudoers_tmp="/etc/sudoers.d/.kodachi-host-exposure.new.$$"
    local sysctl_tmp="/etc/sysctl.d/.90-kodachi-host-exposure.conf.new.$$"

    sudo install -o root -g root -m 0755 "$source_binary" "$binary_tmp"
    sudo install -o root -g root -m 0644 "$source_policy" "$policy_tmp"
    sudo install -o root -g root -m 0644 "$source_unit" "$unit_tmp"
    sudo mv -Tf "$binary_tmp" "$protected_exec_dir/kodachi-soc"
    sudo mv -Tf "$policy_tmp" "$protected_config_dir/host-exposure-defaults.json"
    sudo mv -Tf "$unit_tmp" "$protected_unit"
    printf '%s\n' \
        '%sudo ALL=(root) NOPASSWD: /usr/local/libexec/kodachi/host-exposure/kodachi-soc exposure acknowledge --finding-id * --json' \
        '%sudo ALL=(root) NOPASSWD: /usr/local/libexec/kodachi/host-exposure/kodachi-soc exposure history --limit 32 --json' \
        '%sudo ALL=(root) NOPASSWD: /usr/local/libexec/kodachi/host-exposure/kodachi-soc exposure history --before-sequence * --before-finding-id * --limit 32 --json' \
        '%sudo ALL=(root) NOPASSWD: /usr/local/libexec/kodachi/host-exposure/kodachi-soc exposure watcher --enable --json' \
        '%sudo ALL=(root) NOPASSWD: /usr/local/libexec/kodachi/host-exposure/kodachi-soc exposure watcher --disable --json' \
        | sudo tee "$sudoers_tmp" >/dev/null
    sudo chown root:root "$sudoers_tmp"
    sudo chmod 0440 "$sudoers_tmp"
    if command -v visudo >/dev/null 2>&1 && ! sudo visudo -c -f "$sudoers_tmp" >/dev/null; then
        print_error "Host-exposure acknowledgement sudoers rule failed validation"
        return 1
    fi
    sudo mv -Tf "$sudoers_tmp" "$protected_sudoers"
    printf '%s\n' 'kernel.io_uring_disabled = 2' | sudo tee "$sysctl_tmp" >/dev/null
    sudo chown root:root "$sysctl_tmp"
    sudo chmod 0644 "$sysctl_tmp"
    sudo mv -Tf "$sysctl_tmp" "$protected_sysctl"

    local release_signature=""
    local release_signature_name=""
    local release_signature_tmp=""
    local signature_count=0
    local signature_bytes=0
    local current_signature_bytes=0
    while IFS= read -r -d '' release_signature; do
        release_signature_name="$(basename "$release_signature")"
        if [[ ! "$release_signature_name" =~ ^[A-Za-z0-9._-]+_v[0-9.]+\.sig(\.info)?$ ]]; then
            print_error "Unexpected signature filename in verified pack: $release_signature_name"
            return 1
        fi
        current_signature_bytes="$(stat -c '%s' -- "$release_signature" 2>/dev/null || true)"
        if [[ ! "$current_signature_bytes" =~ ^[0-9]+$ ]]; then
            print_error "Cannot measure protected signature: $release_signature_name"
            return 1
        fi
        signature_count=$((signature_count + 1))
        signature_bytes=$((signature_bytes + current_signature_bytes))
        if [[ $signature_count -gt 512 || $signature_bytes -gt 8388608 ]]; then
            print_error "Protected signature set exceeds the 512-file or 8 MiB ceiling"
            return 1
        fi
        release_signature_tmp="$protected_signature_dir/.${release_signature_name}.new.$$"
        sudo install -o root -g root -m 0644 "$release_signature" "$release_signature_tmp"
        sudo mv -Tf "$release_signature_tmp" "$protected_signature_dir/$release_signature_name"
    done < <(find "$EXTRACT_DIR/signatures" -maxdepth 1 -type f \( -name '*.sig' -o -name '*.sig.info' \) -print0)
    if [[ $signature_count -eq 0 ]]; then
        print_error "Verified package contains no protected release signatures"
        return 1
    fi

    local command_link_tmp="/usr/local/bin/.kodachi-soc.new.$$"
    sudo ln -s "$protected_exec_dir/kodachi-soc" "$command_link_tmp"
    sudo mv -Tf "$command_link_tmp" /usr/local/bin/kodachi-soc

    for component in "$protected_exec_dir" "$protected_exec_dir/kodachi-soc" "$protected_state_dir" "$protected_config_dir" "$protected_signature_dir" "$protected_unit" "$protected_sudoers" "$protected_sysctl"; do
        if [[ -L "$component" ]]; then
            print_error "Protected host-exposure installation produced a symlink unexpectedly: $component"
            return 1
        fi
        owner="$(sudo stat -c '%u' -- "$component" 2>/dev/null || true)"
        mode="$(sudo stat -c '%a' -- "$component" 2>/dev/null || true)"
        if [[ "$owner" != "0" || ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 022)) -ne 0 ]]; then
            print_error "Protected host-exposure installation failed ownership or mode validation: $component"
            return 1
        fi
    done
    if [[ "$(readlink /usr/local/bin/kodachi-soc 2>/dev/null || true)" != "$protected_exec_dir/kodachi-soc" ]]; then
        print_error "Protected host-exposure command link does not target the protected executable"
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if ! sudo sysctl -q -p "$protected_sysctl"; then
            print_warning "Required io_uring hardening could not be applied; watcher coverage will remain unsupported"
        elif [[ "$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || true)" != "2" ]]; then
            print_warning "Required io_uring hardening is not active; watcher coverage will remain unsupported"
        fi
        sudo systemctl daemon-reload
        if host_exposure_rollout_enabled; then
            sudo systemctl enable kodachi-soc-watcher.service
            sudo systemctl restart kodachi-soc-watcher.service
            if ! sudo systemctl is-active --quiet kodachi-soc-watcher.service; then
                print_error "Host-exposure watcher service did not become active"
                return 1
            fi
            print_success "Protected host-exposure watcher installed and active"
        else
            rollout_status=$?
            if [[ $rollout_status -ne 1 ]]; then
                return 1
            fi
            if ! sudo systemctl disable --now kodachi-soc-watcher.service >/dev/null; then
                print_error "Default-disabled host-exposure watcher could not be stopped and disabled"
                return 1
            fi
            if sudo systemctl is-active --quiet kodachi-soc-watcher.service; then
                print_error "Default-disabled host-exposure watcher remained active"
                return 1
            fi
            print_warning "Protected host-exposure watcher installed but disabled pending release approval"
            print_info "Authorized test rollout requires KODACHI_HOST_EXPOSURE_WATCHER_ENABLED=1"
        fi
    else
        print_warning "systemd is not active; protected host-exposure watcher is installed but not started"
    fi
}

install_host_exposure_notifier_service() {
    local notifier_binary="$INSTALL_PATH/kodachi-soc-notifier"
    if [[ ! -x "$notifier_binary" ]]; then
        return 0
    fi

    local source_unit="$EXTRACT_DIR/config/systemd/kodachi-soc-notifier.service"
    if [[ ! -f "$source_unit" ]]; then
        print_error "Host-exposure notifier service is missing from the verified package"
        return 1
    fi
    if [[ "$INSTALL_PATH" != "/opt/kodachi/dashboard/hooks" ]]; then
        print_warning "Host-exposure notifier auto-start is available only for the canonical /opt installation"
        print_warning "The watcher remains active, but this custom-path install has no session notifier service"
        return 0
    fi

    local user_systemd_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$user_systemd_dir"
    install -m 0644 "$source_unit" "$user_systemd_dir/kodachi-soc-notifier.service"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null; then
        if systemctl --user enable --now kodachi-soc-notifier.service 2>/dev/null; then
            print_success "Host-exposure session notifier installed and active"
        else
            print_warning "Host-exposure notifier is installed but could not start in this session"
        fi
    else
        print_warning "No user systemd manager is active; the host-exposure notifier will start with the next user systemd manager"
    fi
}

# Function to detect and stop permission-guard daemon
stop_permission_guard_if_running() {
    # Try to find permission-guard binary location
    local pg_binary=""
    if command -v permission-guard &>/dev/null; then
        pg_binary="permission-guard"
    elif [[ -f "$INSTALL_PATH/permission-guard" ]]; then
        pg_binary="$INSTALL_PATH/permission-guard"
    fi

    if [[ -z "$pg_binary" ]]; then
        # No binary found, skip check
        return 0
    fi

    # Check if daemon is actually running (handle multiple scenarios)
    daemon_running=false

    # Method 1: Try with sudo first (for root-owned daemons, non-interactive)
    if sudo -n $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":true'; then
        daemon_running=true
    # Method 2: Try without sudo (for user-owned daemons)
    elif $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":true'; then
        daemon_running=true
    # Method 3: Check for EPERM error (daemon running but no permission to check)
    elif $pg_binary --daemon-status --json 2>/dev/null | grep -q 'EPERM.*Operation not permitted'; then
        daemon_running=true
    # Method 4: Fallback to direct process check
    elif pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
        daemon_running=true
    fi

    if [[ "$daemon_running" == "true" ]]; then
        print_warning "Detected running permission-guard daemon"
        print_step "Attempting to stop permission-guard daemon..."

        # Try to stop without sudo first
        if "$pg_binary" --stop-daemon &>/dev/null; then
            sleep 2  # Wait for daemon to fully stop

            # Verify it actually stopped (check with both sudo and non-sudo)
            if sudo -n $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":false'; then
                print_success "Successfully stopped permission-guard daemon"
                print_info "The daemon will automatically start again when you log in"
                return 0
            elif $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":false'; then
                print_success "Successfully stopped permission-guard daemon"
                print_info "The daemon will automatically start again when you log in"
                return 0
            elif ! pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
                # Process check shows it stopped
                print_success "Successfully stopped permission-guard daemon"
                print_info "The daemon will automatically start again when you log in"
                return 0
            else
                print_error "Stop command succeeded but daemon is still running"
                print_info "This may require sudo privileges to stop"
                # Fall through to sudo instructions below
            fi
        fi

        # Non-sudo stop failed — try with interactive sudo (prompts for password)
        print_step "Requires sudo privileges to stop daemon..."
        if sudo "$pg_binary" --stop-daemon &>/dev/null; then
            sleep 2  # Wait for daemon to fully stop

            # Verify it actually stopped (same 3-method check)
            if sudo -n $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":false'; then
                print_success "Successfully stopped permission-guard daemon (via sudo)"
                print_info "The daemon will automatically start again when you log in"
                return 0
            elif $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":false'; then
                print_success "Successfully stopped permission-guard daemon (via sudo)"
                print_info "The daemon will automatically start again when you log in"
                return 0
            elif ! pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
                print_success "Successfully stopped permission-guard daemon (via sudo)"
                print_info "The daemon will automatically start again when you log in"
                return 0
            else
                print_error "Sudo stop command succeeded but daemon is still running"
            fi
        fi

        # If we reach here, both non-sudo and sudo stop failed
        print_error "Cannot stop permission-guard daemon"
        echo ""

        # Non-interactive fallback (e.g., curl ... | bash with no TTY)
        if [[ ! -t 0 ]] && ! [[ -c /dev/tty ]]; then
            print_warning "Non-interactive mode: skipping permission-guard binary update"
            PERMISSION_GUARD_SKIPPED=true
            return 0
        fi

        local pg_attempts=0
        local pg_max_attempts=3

        while true; do
            echo ""
            print_highlight "ACTION REQUIRED: permission-guard daemon is still running"
            echo ""
            echo "  To stop it, open another terminal and run:"
            echo -e "    ${BOLD}sudo permission-guard --stop-daemon${NC}"
            echo -e "    ${BOLD}sudo $INSTALL_PATH/permission-guard --stop-daemon${NC}"
            echo ""

            if [[ $pg_attempts -ge $pg_max_attempts ]]; then
                # After max attempts, only offer skip or abort
                echo -e "  ${YELLOW}[1]${NC} Continue anyway - skip permission-guard binary"
                echo -e "  ${YELLOW}[2]${NC} Abort installation"
                echo ""
                echo -n "  Choose [1-2]: "
                local fallback_choice=""
                read -r fallback_choice < /dev/tty 2>/dev/null || fallback_choice="1"
                case "$fallback_choice" in
                    2)
                        print_error "Installation aborted by user"
                        exit 1
                        ;;
                    *)
                        print_warning "Skipping permission-guard binary update"
                        PERMISSION_GUARD_SKIPPED=true
                        return 0
                        ;;
                esac
            fi

            echo -e "  ${YELLOW}[1]${NC} I stopped it - verify and continue"
            echo -e "  ${YELLOW}[2]${NC} Continue anyway - skip permission-guard binary"
            echo -e "  ${YELLOW}[3]${NC} Abort installation"
            echo ""
            echo -n "  Choose [1-3]: "
            local pg_choice=""
            read -r pg_choice < /dev/tty 2>/dev/null || pg_choice="2"

            case "$pg_choice" in
                1)
                    pg_attempts=$((pg_attempts + 1))
                    print_step "Re-checking permission-guard status (attempt $pg_attempts/$pg_max_attempts)..."
                    sleep 1

                    # Re-verify using all 4 detection methods
                    local still_running=false
                    if sudo -n $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":true'; then
                        still_running=true
                    elif $pg_binary --daemon-status --json 2>/dev/null | grep -q '"running":true'; then
                        still_running=true
                    elif $pg_binary --daemon-status --json 2>/dev/null | grep -q 'EPERM.*Operation not permitted'; then
                        # Can't check via daemon-status (no sudo), fall back to pgrep
                        if pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
                            still_running=true
                        fi
                    elif pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
                        still_running=true
                    fi

                    if [[ "$still_running" == "false" ]]; then
                        print_success "permission-guard daemon is no longer running"
                        return 0
                    fi

                    print_error "permission-guard daemon is still running"
                    ;;
                2)
                    print_warning "Skipping permission-guard binary update"
                    PERMISSION_GUARD_SKIPPED=true
                    return 0
                    ;;
                3)
                    print_error "Installation aborted by user"
                    exit 1
                    ;;
                *)
                    print_warning "Invalid choice, please try again"
                    ;;
            esac
        done
    fi
}

# Collect running PIDs that are holding target binaries we are about to replace
collect_install_path_pids() {
    local pids=()
    local pid=""
    local exe=""
    local binary_file=""
    local binary_name=""
    local target=""
    local have_sudo=false
    local have_timeout=false
    local self_pid="$$"
    local parent_pid="${PPID:-0}"
    local targets=()
    local -A target_map=()
    local lsof_pids=""

    if sudo -n true 2>/dev/null; then
        have_sudo=true
    fi
    if command -v timeout &>/dev/null; then
        have_timeout=true
    fi

    for binary_file in "$EXTRACT_DIR/binaries/"*; do
        [[ -f "$binary_file" ]] || continue
        binary_name="$(basename "$binary_file")"
        # Skip permission-guard when user chose to keep it running
        if [[ "$PERMISSION_GUARD_SKIPPED" == "true" ]] && [[ "$binary_name" == "permission-guard" ]]; then
            continue
        fi
        target="$INSTALL_PATH/$binary_name"
        [[ -e "$target" ]] || continue
        targets+=("$target")
        target_map["$target"]=1
    done

    if [[ "${#targets[@]}" -eq 0 ]]; then
        return 0
    fi

    # Method 1: Open file handles for all target binaries (single call)
    if command -v lsof &>/dev/null; then
        if [[ "$have_timeout" == true ]]; then
            lsof_pids="$(timeout --signal=TERM 8s lsof -t -- "${targets[@]}" 2>/dev/null || true)"
        else
            lsof_pids="$(lsof -t -- "${targets[@]}" 2>/dev/null || true)"
        fi
        while IFS= read -r pid; do
            [[ -n "$pid" ]] && pids+=("$pid")
        done < <(printf '%s\n' "$lsof_pids" | sort -u || true)

        # Also inspect root-owned holders if non-interactive sudo is available
        if [[ "$have_sudo" == true ]]; then
            if [[ "$have_timeout" == true ]]; then
                # timeout must wrap sudo (not the reverse): `sudo -n timeout ...`
                # runs `timeout` under sudo, which is NOT whitelisted -> password
                # required -> ~/dead.letter. Putting timeout OUTSIDE sudo runs the
                # whitelisted lsof under sudo with the timeout still applied.
                lsof_pids="$(timeout --signal=TERM 8s sudo -n lsof -t -- "${targets[@]}" 2>/dev/null || true)"
            else
                lsof_pids="$(sudo -n lsof -t -- "${targets[@]}" 2>/dev/null || true)"
            fi
            while IFS= read -r pid; do
                [[ -n "$pid" ]] && pids+=("$pid")
            done < <(printf '%s\n' "$lsof_pids" | sort -u || true)
        fi
    fi

    # Method 2: Executable path points to one of target binaries (single /proc pass)
    for proc in /proc/[0-9]*; do
        pid="${proc##*/}"
        exe="$(readlink -f "$proc/exe" 2>/dev/null || true)"
        if [[ -n "$exe" ]] && [[ -n "${target_map[$exe]:-}" ]]; then
            pids+=("$pid")
        fi
    done

    # Print unique numeric PIDs excluding current shell and parent shell
    printf '%s\n' "${pids[@]}" \
        | awk '/^[0-9]+$/' \
        | awk -v self="$self_pid" -v parent="$parent_pid" '$1 != self && $1 != parent' \
        | sort -u
}

# Kill all processes using hooks path to prevent ETXTBSY during binary replacement
drain_install_path_processes() {
    print_step "Stopping processes using hooks binaries..."

    local pids=()
    local pid=""
    local survivors=()
    local count=0
    local have_sudo=false

    if sudo -n true 2>/dev/null; then
        have_sudo=true
    fi

    while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
    done < <(collect_install_path_pids)

    count="${#pids[@]}"
    if [[ "$count" -eq 0 ]]; then
        print_success "No active processes are holding hooks binaries"
        return 0
    fi

    print_warning "Found $count active process(es) holding target binaries; terminating..."

    # Graceful stop first
    kill -TERM "${pids[@]}" 2>/dev/null || true
    if [[ "$have_sudo" == true ]]; then
        sudo -n kill -TERM "${pids[@]}" 2>/dev/null || true
    fi
    sleep 1

    # Force kill remaining PIDs
    kill -KILL "${pids[@]}" 2>/dev/null || true
    if [[ "$have_sudo" == true ]]; then
        sudo -n kill -KILL "${pids[@]}" 2>/dev/null || true
    fi
    sleep 0.5

    # Re-check to ensure drain succeeded
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && survivors+=("$pid")
    done < <(collect_install_path_pids)

    if [[ "${#survivors[@]}" -gt 0 ]]; then
        print_warning "Some processes still hold old binaries: ${survivors[*]}"
        print_warning "Proceeding with atomic replacement; those processes may need restart."
        return 0
    fi

    print_success "Hooks path is clear; no process is holding binaries"
}

# Remove managed binaries before copy and prune stale managed files from older releases.
remove_old_hook_binaries() {
    print_step "Removing old managed binaries before copy..."

    local binary_file=""
    local binary_name=""
    local target=""
    local removed=0
    local stale_removed=0
    local -A new_binary_map=()
    local -A removal_targets=()

    # Always replace binaries shipped by the current package.
    for binary_file in "$EXTRACT_DIR/binaries/"*; do
        [[ -f "$binary_file" ]] || continue
        binary_name="$(basename "$binary_file")"
        new_binary_map["$binary_name"]=1
        target="$INSTALL_PATH/$binary_name"
        if [[ -f "$target" ]]; then
            removal_targets["$target"]=1
        fi
    done

    # Prune stale managed binaries from previous versions (manifest-driven).
    if [[ -f "$MANAGED_BINARIES_FILE" ]]; then
        while IFS= read -r binary_name || [[ -n "$binary_name" ]]; do
            [[ -n "$binary_name" ]] || continue
            [[ "$binary_name" == \#* ]] && continue
            [[ -n "${new_binary_map[$binary_name]:-}" ]] && continue
            target="$INSTALL_PATH/$binary_name"
            if [[ -f "$target" ]]; then
                removal_targets["$target"]=1
            fi
        done < "$MANAGED_BINARIES_FILE"
    fi

    # Backward compatibility: if no manifest existed, infer managed binaries from old signature files.
    if [[ -d "$INSTALL_PATH/results/signatures" ]]; then
        for target in "$INSTALL_PATH"/*; do
            [[ -f "$target" && -x "$target" ]] || continue
            binary_name="$(basename "$target")"
            [[ -n "${new_binary_map[$binary_name]:-}" ]] && continue
            if compgen -G "$INSTALL_PATH/results/signatures/${binary_name}*.sig" >/dev/null; then
                removal_targets["$target"]=1
            fi
        done
    fi

    for target in "${!removal_targets[@]}"; do
        binary_name="$(basename "$target")"
        if [[ "$PERMISSION_GUARD_SKIPPED" == "true" ]] && [[ "$binary_name" == "permission-guard" ]]; then
            continue
        fi

        if [[ -z "${new_binary_map[$binary_name]:-}" ]]; then
            stale_removed=$((stale_removed + 1))
        fi

        rm -f "$target" 2>/dev/null || true
        if [[ -f "$target" ]] && sudo -n true 2>/dev/null; then
            sudo -n rm -f "$target" 2>/dev/null || true
        fi
        if [[ ! -f "$target" ]]; then
            removed=$((removed + 1))
        fi
    done

    if [[ $stale_removed -gt 0 ]]; then
        print_info "Pruned $stale_removed stale managed binary file(s)"
    fi
    print_success "Removed $removed managed binary file(s) from hooks"
}

write_managed_binary_manifest() {
    local manifest_tmp="${MANAGED_BINARIES_FILE}.tmp.$$"
    local binary_name=""
    local -a manifest_names=("$@")

    if [[ -z "$MANAGED_BINARIES_FILE" ]]; then
        return 0
    fi

    {
        echo "# Kodachi managed binaries manifest"
        echo "# Updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        for binary_name in "${manifest_names[@]}"; do
            [[ -n "$binary_name" ]] && printf '%s\n' "$binary_name"
        done | sort -u
    } > "$manifest_tmp"

    mv -f "$manifest_tmp" "$MANAGED_BINARIES_FILE"
    chmod 644 "$MANAGED_BINARIES_FILE" 2>/dev/null || true
    print_info "Managed binary manifest updated: $MANAGED_BINARIES_FILE"
}

# Ensure hooks folder is safe for binary replacement
prepare_hooks_for_binary_replace() {
    # Lightweight re-check: pg may have restarted during download
    if [[ "$PERMISSION_GUARD_SKIPPED" != "true" ]]; then
        local pg_restarted=false
        if pgrep -f "permission-guard.*daemon" >/dev/null 2>&1; then
            pg_restarted=true
        fi
        if [[ "$pg_restarted" == "true" ]]; then
            print_warning "permission-guard daemon appears to have restarted during download"
            stop_permission_guard_if_running
        fi
    fi
    # Then drain all running processes using hooks path
    drain_install_path_processes
    # Finally remove old target binaries before writing new files
    remove_old_hook_binaries
}

# Early permission-guard check BEFORE downloading (avoid wasting download time)
stop_permission_guard_if_running

echo ""
print_highlight "======= Downloading Kodachi Binaries ======="
echo ""

# Step 1: Download package (with completeness retry)
# The pack is large (~255 MB). A slow/interrupted connection can leave a TRUNCATED
# file. We verify the published sha256 HERE, before the signature step, so an
# incomplete transfer is reported as a DOWNLOAD problem (and retried) instead of
# surfacing later as an alarming "signature verification FAILED / may be
# compromised" message that wrongly implies tampering.
print_step "Downloading Kodachi binaries package..."
PACKAGE_NAME="kodachi-binaries-v${KODACHI_VERSION}"
PACKAGE_FILE="$TEMP_DIR/${PACKAGE_NAME}.tar.gz"
CHECKSUM_FILE="$TEMP_DIR/${PACKAGE_NAME}.tar.gz.sha256"

# fetch the expected checksum first (best-effort; used to detect truncation)
download_pack_file "${PACKAGE_NAME}.tar.gz.sha256" "$CHECKSUM_FILE" || true

dl_attempt=0; dl_max=3; dl_ok=false
while [[ $dl_attempt -lt $dl_max ]]; do
    dl_attempt=$((dl_attempt + 1))
    if ! download_pack_file "${PACKAGE_NAME}.tar.gz" "$PACKAGE_FILE"; then
        print_warning "Download attempt ${dl_attempt}/${dl_max} could not connect; retrying..."
        sleep 3; continue
    fi
    if [[ -s "$CHECKSUM_FILE" ]]; then
        if ( cd "$TEMP_DIR" && sha256sum -c "$(basename "$CHECKSUM_FILE")" &>/dev/null ); then
            dl_ok=true; break
        fi
        got_size=$(du -h "$PACKAGE_FILE" 2>/dev/null | cut -f1)
        print_warning "Download incomplete or corrupted (got ${got_size}, checksum mismatch); retrying ${dl_attempt}/${dl_max}..."
        sleep 3; continue
    fi
    # no checksum available to compare against; accept the transfer as-is
    dl_ok=true; break
done

if [[ "$dl_ok" != true ]]; then
    print_error "Could not obtain a complete package after ${dl_max} attempts."
    print_error "This is a DOWNLOAD problem (incomplete transfer), NOT a security issue."
    print_error "Check your connection (the package is ~255 MB) and re-run the installer."
    exit 1
fi
file_size=$(du -h "$PACKAGE_FILE" | cut -f1)
print_success "Package downloaded + integrity verified ($file_size)"

# Step 2: Download and verify package signature
print_step "Downloading package signature..."
SIGNATURE_FILE="$TEMP_DIR/${PACKAGE_NAME}.tar.gz.sig"
PUBLIC_KEY_FILE="$TEMP_DIR/public_key_v${KODACHI_VERSION}.pem"

PACKAGE_VERIFIED=false
if download_pack_file "${PACKAGE_NAME}.tar.gz.sig" "$SIGNATURE_FILE"; then
    if download_pack_file "public_key_v${KODACHI_VERSION}.pem" "$PUBLIC_KEY_FILE"; then
        print_step "Verifying package signature..."
        if openssl dgst -sha256 -verify "$PUBLIC_KEY_FILE" -signature "$SIGNATURE_FILE" "$PACKAGE_FILE" >/dev/null 2>&1; then
            print_success "Package signature verified successfully"
            PACKAGE_VERIFIED=true
        else
            print_error "Package signature verification FAILED!"
            print_error "The downloaded package may be compromised or corrupted."
            print_error "Installation aborted for security reasons."
            exit 1
        fi
    else
        print_error "Public key not found - cannot verify package authenticity"
        print_error "Installation aborted for security reasons."
        exit 1
    fi
else
    print_error "Package signature not found - cannot verify package authenticity"
    print_error "Installation aborted for security reasons."
    exit 1
fi

# Step 3: Verify checksum
print_step "Verifying package checksum..."
CHECKSUM_FILE="$TEMP_DIR/${PACKAGE_NAME}.tar.gz.sha256"

if download_pack_file "${PACKAGE_NAME}.tar.gz.sha256" "$CHECKSUM_FILE"; then
    cd "$TEMP_DIR"
    if sha256sum -c "$CHECKSUM_FILE" &>/dev/null; then
        print_success "Package checksum verified"
        PACKAGE_SHA256="$(sha256sum "$PACKAGE_FILE" | awk '{print $1}')"
        if [[ -n "$LATEST_KODACHI_CHECKSUM" ]] && [[ "$KODACHI_VERSION" == "$LATEST_KODACHI_VERSION" ]]; then
            if [[ "$PACKAGE_SHA256" == "$LATEST_KODACHI_CHECKSUM" ]]; then
                print_success "Package matches the latest published binary pack checksum"
            else
                print_warning "Published main-info checksum and downloaded package checksum do not match"
            fi
        fi
    else
        print_error "Package checksum verification FAILED!"
        print_error "The downloaded package is corrupted or has been tampered with."
        print_error "Installation aborted for security reasons."
        exit 1
    fi
else
    print_error "Checksum file not found - cannot verify package integrity"
    print_error "Installation aborted for security reasons."
    exit 1
fi

# Step 4: Extract package
print_step "Checking archive for unsafe paths..."
# Prevent path traversal attacks by checking for absolute paths or parent directory references
if tar -tzf "$PACKAGE_FILE" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null 2>&1; then
    print_error "Archive contains unsafe paths (absolute paths or parent directory references)"
    print_error "This could indicate a malicious archive."
    print_error "Installation aborted for security reasons."
    exit 1
fi
print_success "Archive path check passed"

print_step "Extracting package..."
cd "$TEMP_DIR"
# Use safe extraction flags to prevent ownership/permission issues
tar -xzf "$PACKAGE_FILE" --no-same-owner --no-same-permissions --numeric-owner
EXTRACT_DIR="$TEMP_DIR/$PACKAGE_NAME"

if [[ ! -d "$EXTRACT_DIR" ]]; then
    print_error "Failed to extract package"
    exit 1
fi
print_success "Package extracted successfully"

# Step 5: Create installation directory structure
print_step "Creating installation directories..."
mkdir -p "$INSTALL_PATH"/{config/signkeys,config/profiles,icons,logs,tmp,results/signatures,backups,others,sounds,flags,licenses,binaries-update-scripts,models,data,cache/ip-fetch/ips}
print_success "Directory structure created"

# Step 5.5: Pre-copy safety drain for hooks binary replacement
prepare_hooks_for_binary_replace

# Step 5.6: Cleanup old global symlinks (if global-launcher exists)
echo ""
print_highlight "======= Cleaning Up Global Deployments ======="
echo ""

cleanup_global_symlinks() {
    # Check if global-launcher exists in installation path or is globally accessible
    local gl_binary=""
    if command -v global-launcher &>/dev/null; then
        gl_binary="global-launcher"
    elif [[ -f "$INSTALL_PATH/global-launcher" ]]; then
        gl_binary="$INSTALL_PATH/global-launcher"
    fi

    if [[ -z "$gl_binary" ]]; then
        print_info "global-launcher not found - skipping cleanup (first-time install)"
        return 0
    fi

    print_step "Found global-launcher - cleaning up old symlinks..."

    # Try cleanup with sudo (non-interactive)
    if sudo -n "$gl_binary" cleanup --yes --json &>/dev/null; then
        print_success "Successfully removed old global symlinks"
        return 0
    # Try without sudo (user-space deployment)
    elif "$gl_binary" cleanup --yes --json &>/dev/null; then
        print_success "Successfully removed old global symlinks"
        return 0
    else
        print_warning "Could not cleanup old symlinks (may require sudo)"
        print_info "This is non-fatal - installation will continue"
        print_info "You can manually cleanup later with: sudo global-launcher cleanup"
        return 0
    fi
}

cleanup_global_symlinks

# Step 6: Install binaries
print_step "Installing binaries..."

# BEGIN KODACHI VERIFIED BINARY PRODUCER
deploy_verified_package_binaries() {
    local binary_file=""
    local binary_name=""
    local tmp_target=""

    for binary_file in "$EXTRACT_DIR/binaries/"*; do
        if [[ -f "$binary_file" ]]; then
            binary_name="$(basename "$binary_file")"
            PACKAGE_BINARY_NAMES+=("$binary_name")
            TOTAL_COUNT=$((TOTAL_COUNT + 1))

            # Every source that reaches final root hardening must first pass
            # detached-signature verification, including permission-guard when
            # its currently running daemon cannot be stopped.
            if ! verify_signature "$binary_file" "$EXTRACT_DIR/signatures"; then
                FAILED_COUNT=$((FAILED_COUNT + 1))
                FAILED_BINARIES="${FAILED_BINARIES}    - ${binary_name}\n"
                echo -e "  ${RED}✗${NC} $binary_name - signature verification FAILED"
                continue
            fi

            if [[ "$PERMISSION_GUARD_SKIPPED" == "true" ]] \
                && [[ "$binary_name" == "permission-guard" ]]; then
                PRESERVE_HARDEN_BINARY_NAMES+=("$binary_name")
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                echo -e "  ${YELLOW}⊘${NC} $binary_name - daemon stop skipped; existing installed bytes will be root-hardened after package verification"
                continue
            fi

            FINAL_HARDEN_BINARY_NAMES+=("$binary_name")

            # Atomic replace avoids ETXTBSY on running binaries.
            tmp_target="$INSTALL_PATH/.${binary_name}.new.$$"
            if install -m 755 "$binary_file" "$tmp_target" \
                && mv -f "$tmp_target" "$INSTALL_PATH/$binary_name"; then
                VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
                DEPLOYED_BINARY_NAMES+=("$binary_name")
                echo -e "  ${GREEN}✓${NC} $binary_name - signature verified and installed"
            else
                rm -f "$tmp_target" 2>/dev/null || true
                INSTALL_FAILED_COUNT=$((INSTALL_FAILED_COUNT + 1))
                INSTALL_FAILED_BINARIES="${INSTALL_FAILED_BINARIES}    - ${binary_name}\n"
                echo -e "  ${RED}✗${NC} $binary_name - install failed (write/permission/busy)"
            fi
        fi
    done
}
# END KODACHI VERIFIED BINARY PRODUCER

VERIFIED_COUNT=0
FAILED_COUNT=0
INSTALL_FAILED_COUNT=0
TOTAL_COUNT=0
FAILED_BINARIES=""
INSTALL_FAILED_BINARIES=""
PACKAGE_BINARY_NAMES=()
DEPLOYED_BINARY_NAMES=()
FINAL_HARDEN_BINARY_NAMES=()
PRESERVE_HARDEN_BINARY_NAMES=()

deploy_verified_package_binaries

# Check if any signatures failed
if [[ $FAILED_COUNT -gt 0 ]]; then
    echo ""
    print_error "Binary signature verification FAILED for $FAILED_COUNT binaries!"
    print_error "The following binaries could not be verified:"
    echo -e "${RED}${FAILED_BINARIES}${NC}"
    print_error "These binaries were NOT installed for security reasons."
    print_error "Installation aborted - the package may be compromised."

    # Preserve existing installation/user data; only clean installer temp targets.
    find "$INSTALL_PATH" -maxdepth 1 -type f -name ".*.new.*" -delete 2>/dev/null || true
    print_warning "Existing installation was preserved (no user-managed files were removed)."
    exit 1
fi

print_success "Installed and verified $VERIFIED_COUNT binaries"

if [[ $INSTALL_FAILED_COUNT -gt 0 ]]; then
    echo ""
    print_error "Binary installation failed for $INSTALL_FAILED_COUNT binaries!"
    print_error "The following binaries could not be installed:"
    echo -e "${RED}${INSTALL_FAILED_BINARIES}${NC}"
    print_error "Please check permissions/process locks and re-run the installer."
    exit 1
fi

write_managed_binary_manifest "${PACKAGE_BINARY_NAMES[@]}"

# Step 7: Copy configuration files
print_step "Installing configuration files..."
if [[ -d "$EXTRACT_DIR/config" ]]; then
    cp -r "$EXTRACT_DIR/config/"* "$INSTALL_PATH/config/" 2>/dev/null || true
    print_success "Configuration files installed"
fi

# Step 8: Copy other assets
if [[ -d "$EXTRACT_DIR/signatures" ]]; then
    cp -r "$EXTRACT_DIR/signatures/"* "$INSTALL_PATH/results/signatures/" 2>/dev/null || true
fi

if ! install_host_exposure_protected_runtime; then
    print_error "Protected host-exposure installation failed"
    exit 1
fi
if ! install_host_exposure_notifier_service; then
    print_error "Host-exposure notifier installation failed"
    exit 1
fi

if [[ -d "$EXTRACT_DIR/sounds" ]]; then
    cp -a "$EXTRACT_DIR/sounds/." "$INSTALL_PATH/sounds/" 2>/dev/null || true
fi

if [[ -d "$EXTRACT_DIR/flags" ]]; then
    cp -a "$EXTRACT_DIR/flags/." "$INSTALL_PATH/flags/" 2>/dev/null || true
fi

if [[ -d "$EXTRACT_DIR/icons" ]]; then
    cp -a "$EXTRACT_DIR/icons/." "$INSTALL_PATH/icons/" 2>/dev/null || true
fi

# Backward compatibility: older packages may only contain dashboard icon
# under config/icons and no top-level icons directory.
if [[ -d "$EXTRACT_DIR/config/icons" ]]; then
    if [[ -z "$(find "$INSTALL_PATH/icons" -maxdepth 1 -type f 2>/dev/null)" ]]; then
        cp -a "$EXTRACT_DIR/config/icons/." "$INSTALL_PATH/icons/" 2>/dev/null || true
    fi
fi

# Ensure runtime icon filename exists for dashboard/tray fallback logic.
# Package may contain only generic Kodachi icon names (e.g., kodachi.png).
if [[ ! -f "$INSTALL_PATH/icons/kodachi-dashboard.png" ]]; then
    for icon_candidate in \
        "$INSTALL_PATH/config/icons/kodachi-dashboard.png" \
        "$INSTALL_PATH/icons/kodachi.png" \
        "$INSTALL_PATH/icons/kodachi32.png" \
        "$INSTALL_PATH/icons/Kodachi_Green_big.png" \
        "$INSTALL_PATH/icons/Kodachi_White_big.png" \
        "$INSTALL_PATH/icons/Kodachi_Black_big.png"
    do
        if [[ -f "$icon_candidate" ]]; then
            cp -f "$icon_candidate" "$INSTALL_PATH/icons/kodachi-dashboard.png"
            break
        fi
    done
fi

if [[ -d "$EXTRACT_DIR/licenses" ]]; then
    cp -r "$EXTRACT_DIR/licenses/"* "$INSTALL_PATH/licenses/" 2>/dev/null || true
    if [[ -f "$INSTALL_PATH/licenses/LICENSE.md" ]]; then
        print_success "LICENSE.md installed"
    fi
fi

if [[ -d "$EXTRACT_DIR/binaries-update-scripts" ]]; then
    cp -r "$EXTRACT_DIR/binaries-update-scripts/"* "$INSTALL_PATH/binaries-update-scripts/" 2>/dev/null || true
    script_count=$(find "$INSTALL_PATH/binaries-update-scripts" -type f -name "*.sh" | wc -l)
    if [[ $script_count -gt 0 ]]; then
        print_success "Update scripts installed ($script_count scripts)"
        print_info "Scripts location: $INSTALL_PATH/binaries-update-scripts/"
    fi
fi

# Expose kodachi-backup (Backup & Restore CLI) on PATH. It runs as the invoking
# user (backs up $HOME) so it deliberately gets NO sudoers entry. The dashboard
# also resolves the wrapper through this symlink (PATH fallback).
KODACHI_BACKUP_DEPLOYED="$INSTALL_PATH/binaries-update-scripts/kodachi-backup"
if [[ -f "$KODACHI_BACKUP_DEPLOYED" ]]; then
    chmod 755 "$KODACHI_BACKUP_DEPLOYED" 2>/dev/null || true
    if ln -sfn "$KODACHI_BACKUP_DEPLOYED" /usr/local/bin/kodachi-backup 2>/dev/null \
        || sudo ln -sfn "$KODACHI_BACKUP_DEPLOYED" /usr/local/bin/kodachi-backup 2>/dev/null; then
        print_success "kodachi-backup linked to /usr/local/bin/kodachi-backup"
    else
        print_warning "Could not link kodachi-backup into /usr/local/bin"
    fi
fi

if [[ -d "$EXTRACT_DIR/others" ]]; then
    cp -a "$EXTRACT_DIR/others/." "$INSTALL_PATH/others/" 2>/dev/null || true
    other_count=$(find "$INSTALL_PATH/others" -type f | wc -l)
    if [[ $other_count -gt 0 ]]; then
        print_success "Offline documents and extra artifacts installed ($other_count files)"
        print_info "Artifacts location: $INSTALL_PATH/others/"
    fi

    # Offline documentation site resilience.
    #
    # The bundled LibreWolf profile ships a static bookmark pointing at the
    # canonical path file:///opt/kodachi/dashboard/hooks/others/site/index.html
    # (a binary places.sqlite that cannot be rewritten per-install). When the
    # install fell back off the canonical /opt/kodachi location, bridge the
    # canonical path to the real one with a symlink so the bookmark still
    # resolves. The matching AppArmor profile (kodachi.librewolf) follows the
    # dereferenced path and already allows the standard fallback site dirs.
    #
    # Best-effort and non-fatal: never deletes existing data; a degraded
    # environment without write access simply keeps the printed file:// path.
    CANONICAL_HOOKS_DIR="/opt/kodachi/dashboard/hooks"
    SITE_INDEX="$INSTALL_PATH/others/site/index.html"
    if [[ -f "$SITE_INDEX" && "$INSTALL_PATH" != "$CANONICAL_HOOKS_DIR" ]]; then
        REAL_SITE_DIR="$(cd "$INSTALL_PATH/others/site" 2>/dev/null && pwd -P)"
        CANONICAL_SITE_DIR="$CANONICAL_HOOKS_DIR/others/site"
        CANONICAL_SITE_INDEX="$CANONICAL_SITE_DIR/index.html"
        site_bridged=false
        if [[ -n "$REAL_SITE_DIR" ]]; then
            if [[ -e "$CANONICAL_SITE_INDEX" ]]; then
                # A canonical install (real dir or prior symlink) already
                # resolves — leave it untouched.
                site_bridged=true
            elif [[ ! -e "$CANONICAL_SITE_DIR" || -L "$CANONICAL_SITE_DIR" ]]; then
                # Path is free or a replaceable symlink — safe to (re)link.
                if mkdir -p "$CANONICAL_HOOKS_DIR/others" 2>/dev/null \
                    && ln -sfn "$REAL_SITE_DIR" "$CANONICAL_SITE_DIR" 2>/dev/null; then
                    site_bridged=true
                elif command -v sudo >/dev/null 2>&1 \
                    && sudo mkdir -p "$CANONICAL_HOOKS_DIR/others" 2>/dev/null \
                    && sudo ln -sfn "$REAL_SITE_DIR" "$CANONICAL_SITE_DIR" 2>/dev/null; then
                    site_bridged=true
                fi
            fi
        fi
        # The confined LibreWolf AppArmor profile (kodachi.librewolf) allows the
        # canonical /opt path and the standard HOME fallbacks only. A custom
        # --path target resolves on disk via the bridge but the
        # sandboxed browser will still be denied, so report that honestly
        # instead of a misleading success.
        site_aa_covered=false
        case "$REAL_SITE_DIR" in
            "$HOME/dashboard/hooks/others/site"|\
            "$HOME/k900/dashboard/hooks/others/site"|\
            "$HOME/Desktop/dashboard/hooks/others/site")
                site_aa_covered=true
                ;;
        esac
        if [[ "$site_bridged" == true && "$site_aa_covered" == true ]]; then
            print_info "Offline site bookmark bridged: $CANONICAL_SITE_INDEX -> $REAL_SITE_DIR"
        elif [[ "$site_bridged" == true ]]; then
            print_info "Offline site bookmark bridged: $CANONICAL_SITE_INDEX -> $REAL_SITE_DIR"
            print_warning "Custom install path is outside the sandboxed-browser allowlist; the bundled LibreWolf may still block it."
            print_info "Open in an unconfined browser, or read it directly: file://$SITE_INDEX"
        else
            print_warning "Offline site installed off the canonical path; the bundled browser bookmark will not resolve."
            print_info "Open it directly: file://$SITE_INDEX"
        fi
    fi
fi

# Copy AI model files (support multiple package layouts)
MODEL_SOURCE_DIR=""
for candidate in \
    "$EXTRACT_DIR/models" \
    "$EXTRACT_DIR/kodachi-ai/models" \
    "$EXTRACT_DIR/rust/kodachi-ai/models"
do
    if [[ -d "$candidate" ]]; then
        MODEL_SOURCE_DIR="$candidate"
        break
    fi
done

if [[ -n "$MODEL_SOURCE_DIR" ]]; then
    cp -a "$MODEL_SOURCE_DIR/." "$INSTALL_PATH/models/" 2>/dev/null || true
    model_count=$(find "$INSTALL_PATH/models" -type f | wc -l)
    if [[ $model_count -gt 0 ]]; then
        print_success "AI model files installed ($model_count files)"
        print_info "Model source used: $MODEL_SOURCE_DIR"
    fi
else
    print_warning "AI model directory not found in package (expected models/ or rust/kodachi-ai/models/)"
fi

# Purge legacy compat model layouts on upgrade.
#
# Older installs created two compat dirs/symlinks here:
#   <hooks>/kodachi-ai/models          → models   (symlink, or real dir on upgrade)
#   <hooks>/rust/kodachi-ai/models     → ../../models
# Plus the empty parent dirs <hooks>/kodachi-ai/ and <hooks>/rust/kodachi-ai/.
#
# Audit (2026-05-20) confirmed no Rust binary or shell script actually depends
# on those nested paths — ai-engine's resolve_models_dir() walks parents and
# tries env overrides + canonical /opt/kodachi/dashboard/hooks/models, so the
# single <hooks>/models layout is sufficient. The compat dirs were dead code.
#
# Worse, the pre-2026-05-20 logic fell back to `cp -an` when a real dir already
# existed at the compat path, so upgrade-over-upgrade accumulated **full
# duplicate ONNX + GGUF copies** (~160 MB ONNX + up to ~2.4 GB GGUF per user).
# Now we actively reclaim that space and never re-create the compat layout.
prune_legacy_compat_model_dirs() {
    local reclaimed_bytes=0
    local target=""
    local size=""

    for target in \
        "$INSTALL_PATH/kodachi-ai/models" \
        "$INSTALL_PATH/rust/kodachi-ai/models"
    do
        if [[ -L "$target" ]]; then
            # Old-style symlink — silent remove, no space to reclaim.
            rm -f "$target" 2>/dev/null || true
        elif [[ -d "$target" ]]; then
            # Real dir with accumulated duplicate ONNX/GGUF — reclaim space.
            size=$(du -sb "$target" 2>/dev/null | awk '{print $1}')
            [[ -n "$size" ]] && reclaimed_bytes=$((reclaimed_bytes + size))
            rm -rf "$target" 2>/dev/null || true
        elif [[ -e "$target" ]]; then
            # Unexpected file at this path — remove to keep tree clean.
            rm -f "$target" 2>/dev/null || true
        fi
    done

    # Remove the now-empty compat parent dirs (rmdir refuses if non-empty,
    # so existing legitimate content under those paths is safe).
    rmdir "$INSTALL_PATH/kodachi-ai" 2>/dev/null || true
    rmdir "$INSTALL_PATH/rust/kodachi-ai" 2>/dev/null || true
    rmdir "$INSTALL_PATH/rust" 2>/dev/null || true

    if [[ $reclaimed_bytes -gt 0 ]]; then
        # Human-readable size via numfmt if available, fall back to MB rounded.
        local human=""
        if command -v numfmt >/dev/null 2>&1; then
            human=$(numfmt --to=iec --suffix=B "$reclaimed_bytes" 2>/dev/null)
        fi
        [[ -z "$human" ]] && human="$((reclaimed_bytes / 1024 / 1024)) MB"
        print_success "Reclaimed $human from legacy duplicate model dirs (kodachi-ai/models, rust/kodachi-ai/models)"
    fi
}

prune_legacy_compat_model_dirs

# Copy DNSCrypt server list cache (used by kodachi-deps-install.sh as offline fallback)
if [[ -d "$EXTRACT_DIR/dnscrypt-cache" ]]; then
    mkdir -p "$INSTALL_PATH/dnscrypt-cache"
    cp -a "$EXTRACT_DIR/dnscrypt-cache/." "$INSTALL_PATH/dnscrypt-cache/" 2>/dev/null || true
    dc_count=$(find "$INSTALL_PATH/dnscrypt-cache" -type f 2>/dev/null | wc -l)
    if [[ $dc_count -gt 0 ]]; then
        print_success "DNSCrypt server list cache installed ($dc_count files)"
    fi
fi

# Step 8.5: Install Conky assets and startup entry
cleanup_legacy_autostart_entries() {
    local autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    local removed=0
    local noun="entries"
    local old_entry=""
    local legacy_entries=(
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
        print_info "Removed $removed legacy Kodachi startup $noun"
    fi
}

find_session_helper_binary() {
    local candidates=(
        "$INSTALL_PATH/kodachi-session-helper"
        "/opt/kodachi/dashboard/hooks/kodachi-session-helper"
        "/usr/local/bin/kodachi-session-helper"
    )

    if [[ -n "$PROJECT_ROOT" ]]; then
        candidates+=("$PROJECT_ROOT/dashboard/hooks/kodachi-session-helper")
    fi

    candidates+=(
        "$HOME/dashboard/hooks/kodachi-session-helper"
        "$HOME/Desktop/dashboard/hooks/kodachi-session-helper"
        "$HOME/k900/dashboard/hooks/kodachi-session-helper"
    )

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

install_conky_assets() {
    print_step "Installing Conky assets..."

    local conky_source=""
    local candidates=()

    # Preferred source: bundled package assets
    if [[ -n "${EXTRACT_DIR:-}" ]]; then
        candidates+=("$EXTRACT_DIR/conky")
    fi

    # Local development fallbacks (script-relative first, then user-home legacy paths)
    candidates+=(
        "$CONKY_PACKAGE_LOCAL_SOURCE"
        "$HOME/k900/livebuild-assets/conky"
        "$HOME/livebuild-assets/conky"
        "/usr/share/kodachi/conky"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/configs" ]] && [[ -d "$candidate/scripts" ]]; then
            conky_source="$candidate"
            break
        fi
    done

    if [[ -z "$conky_source" ]]; then
        if [[ -d "$CONKY_INSTALL_DIR/configs" ]] && [[ -d "$CONKY_INSTALL_DIR/scripts" ]]; then
            print_warning "Conky update source not found; reusing existing assets and refreshing startup entries."
            conky_source="$CONKY_INSTALL_DIR"
        else
            print_warning "Conky source not found in package or local assets. Skipping Conky setup."
            return 1
        fi
    fi

    mkdir -p "$(dirname "$CONKY_INSTALL_DIR")"
    if [[ "$conky_source" != "$CONKY_INSTALL_DIR" ]]; then
        safe_stop_conky

        # Preserve runtime data/cache directory across update to prevent
        # the Signal Deck from cold-starting all queries (600% CPU spike).
        local _conky_data_backup=""
        if [[ -d "$CONKY_INSTALL_DIR/data" ]]; then
            _conky_data_backup="$(mktemp -d "${TMPDIR:-/tmp}/kodachi-conky-data.XXXXXX")"
            cp -a "$CONKY_INSTALL_DIR/data/." "$_conky_data_backup/" 2>/dev/null || true
        fi

        rm -rf "$CONKY_INSTALL_DIR"
        cp -a "$conky_source" "$CONKY_INSTALL_DIR"

        # Restore cached data so focus-alert/signal-deck doesn't rebuild from scratch
        if [[ -n "${_conky_data_backup:-}" ]] && [[ -d "$_conky_data_backup" ]]; then
            mkdir -p "$CONKY_INSTALL_DIR/data"
            cp -a "$_conky_data_backup/." "$CONKY_INSTALL_DIR/data/" 2>/dev/null || true
            rm -rf "$_conky_data_backup"
        fi

        print_success "Conky assets installed: $CONKY_INSTALL_DIR"
    else
        print_info "Conky assets already present. Refreshing startup entries."
    fi

    if [[ -d "$CONKY_INSTALL_DIR/scripts" ]]; then
        find "$CONKY_INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod 755 {} + 2>/dev/null || true
    fi

    return 0
}

install_conky_autostart() {
    local watchdog_script="$CONKY_INSTALL_DIR/scripts/conky-watchdog.sh"
    local launcher="$CONKY_INSTALL_DIR/scripts/conky-launcher.sh"
    local systemd_service_file="$CONKY_CONFIG_BASE/systemd/user/conky-watchdog.service"
    local snapshot_timer_file="$CONKY_CONFIG_BASE/systemd/user/conky-snapshot-refresh.timer"
    local autostart_exec=""
    local autostart_tryexec=""

    if command -v systemctl >/dev/null 2>&1 && [[ -x "$watchdog_script" ]] && [[ -f "$systemd_service_file" ]]; then
        autostart_exec="/usr/bin/systemctl --user start conky-watchdog.service"
        if [[ -f "$snapshot_timer_file" ]]; then
            autostart_exec+=" conky-snapshot-refresh.timer"
        fi
        autostart_tryexec="/usr/bin/systemctl"
    elif [[ -x "$launcher" ]]; then
        autostart_exec="$launcher --restart"
        autostart_tryexec="$launcher"
        print_warning "Conky watchdog is unavailable, falling back to launcher autostart."
    else
        print_warning "Conky launcher not found at $launcher. Skipping autostart setup."
        return 1
    fi

    cleanup_legacy_autostart_entries
    mkdir -p "$(dirname "$CONKY_AUTOSTART_FILE")"
    cat > "$CONKY_AUTOSTART_FILE" << EOF
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
    chmod 644 "$CONKY_AUTOSTART_FILE"

    print_success "Conky autostart enabled: $CONKY_AUTOSTART_FILE"
    if ! command -v conky &>/dev/null; then
        print_warning "Conky binary is not installed yet. Run kodachi-deps-install.sh to install conky-all."
    fi
    return 0
}

install_conky_watchdog() {
    local watchdog_script="$CONKY_INSTALL_DIR/scripts/conky-watchdog.sh"
    local launcher="$CONKY_INSTALL_DIR/scripts/conky-launcher.sh"
    local watchdog_service_source="$CONKY_INSTALL_DIR/systemd/conky-watchdog.service"
    local snapshot_service_source="$CONKY_INSTALL_DIR/systemd/conky-snapshot-refresh.service"
    local snapshot_timer_source="$CONKY_INSTALL_DIR/systemd/conky-snapshot-refresh.timer"
    local systemd_user_dir="$CONKY_CONFIG_BASE/systemd/user"
    local watchdog_service_file="$systemd_user_dir/conky-watchdog.service"
    local snapshot_service_file="$systemd_user_dir/conky-snapshot-refresh.service"
    local snapshot_timer_file="$systemd_user_dir/conky-snapshot-refresh.timer"
    local wants_dir="$systemd_user_dir/default.target.wants"
    local snapshot_timer_available=0

    if [[ ! -x "$watchdog_script" ]]; then
        if [[ ! -x "$launcher" ]]; then
            print_warning "Conky launcher not found at $launcher. Skipping watchdog setup."
            return 1
        fi

        print_warning "Conky watchdog script missing in assets. Creating compatibility watchdog."
        cat > "$watchdog_script" << EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="\${XDG_CACHE_HOME:-\$HOME/.cache}/kodachi"
LOG_FILE="\$LOG_DIR/conky-watchdog.log"
CHECK_INTERVAL="\${CONKY_WATCHDOG_INTERVAL:-5}"
EXPECTED_PANELS="\${CONKY_EXPECTED_PANELS:-4}"
MIN_PANELS="\${CONKY_MIN_PANELS:-3}"
MAX_PANELS="\${CONKY_MAX_PANELS:-6}"
RESTART_AFTER_MISSES="\${CONKY_RESTART_AFTER_MISSES:-2}"
RESTART_COOLDOWN="\${CONKY_RESTART_COOLDOWN:-20}"

mkdir -p "\$LOG_DIR"
export DISPLAY="\${DISPLAY:-:0}"
export XAUTHORITY="\${XAUTHORITY:-\$HOME/.Xauthority}"

count_kodachi_conky() { pgrep -af "conky .*kodachi/conky/configs/conkyrc-.*\\\\.conf" 2>/dev/null | wc -l || true; }
restart_conky() { "$launcher" --restart >> "\$LOG_FILE" 2>&1 || true; }

current_count="\$(count_kodachi_conky)"
if (( current_count < MIN_PANELS )) || (( current_count > MAX_PANELS )); then
    restart_conky
fi

missing_streak=0
last_restart_ts=0

while true; do
    current_count="\$(count_kodachi_conky)"
    if (( current_count < MIN_PANELS )) || (( current_count > MAX_PANELS )); then
        missing_streak=\$((missing_streak + 1))
        if (( missing_streak >= RESTART_AFTER_MISSES )); then
            now_ts=\$(date +%s)
            if (( now_ts - last_restart_ts >= RESTART_COOLDOWN )); then
                restart_conky
                last_restart_ts=\$now_ts
                missing_streak=0
                sleep 2
            fi
        fi
    else
        missing_streak=0
    fi
    sleep "\$CHECK_INTERVAL"
done
EOF
        chmod 755 "$watchdog_script"
    fi

    mkdir -p "$systemd_user_dir" "$wants_dir"

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
  for bin in \
    /opt/kodachi/dashboard/hooks/conky-status \
    "%h/k900/dashboard/hooks/conky-status" \
    "%h/dashboard/hooks/conky-status" \
    /usr/local/bin/conky-status; do \
    [ -x "$bin" ] && exec "$bin" snapshot --refresh --quiet --max-parallel 1 --timeout-ms 7000 2>/dev/null; \
  done; \
  exit 0'
TimeoutSec=130
TimeoutStopSec=5
StandardOutput=null
StandardError=journal
Nice=15
IOSchedulingClass=idle
KillMode=process
SendSIGKILL=no
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
OnUnitActiveSec=120
RandomizedDelaySec=30
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
MemoryHigh=256M
MemoryMax=384M
Environment=XAUTHORITY=%h/.Xauthority

[Install]
WantedBy=default.target
EOF
    fi
    chmod 644 "$watchdog_service_file"
    ln -sfn "$watchdog_service_file" "$wants_dir/conky-watchdog.service"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        systemctl --user enable --now conky-watchdog.service >/dev/null 2>&1 || \
            systemctl --user start conky-watchdog.service >/dev/null 2>&1 || true
        if (( snapshot_timer_available )); then
            systemctl --user enable --now conky-snapshot-refresh.timer >/dev/null 2>&1 || \
                systemctl --user start conky-snapshot-refresh.timer >/dev/null 2>&1 || true
        fi
    fi

    if (( snapshot_timer_available )); then
        print_success "Conky watchdog + snapshot timer configured: $watchdog_service_file"
    else
        print_success "Conky watchdog configured: $watchdog_service_file"
    fi
    return 0
}

enable_xfce_compositor_for_self() {
    # Conky's own_window_argb_value 0 only paints transparent when a
    # compositor is active. XFCE's xfwm4 ships with use_compositing=false
    # by default on stock installs, so a fresh deps+binary install path
    # ends up with solid-black conky panels. This helper enables it for
    # the running user without needing root.
    if ! command -v xfwm4 >/dev/null 2>&1 && [[ ! -x /usr/bin/xfwm4 ]]; then
        return 0
    fi

    local xfconf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/xfconf/xfce-perchannel-xml"
    local xfconf_file="$xfconf_dir/xfwm4.xml"

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

    # Live-apply via xfconf-query if an xfce session is running. The xml write
    # above is authoritative; this query only saves the user from re-logging.
    local _live_applied="false"
    if command -v xfconf-query >/dev/null 2>&1; then
        local _disp
        for _disp in "${DISPLAY:-}" :0.0 :0 :1; do
            [[ -n "$_disp" ]] || continue
            if DISPLAY="$_disp" xfconf-query -c xfwm4 -p /general/use_compositing -s true >/dev/null 2>&1; then
                _live_applied="true"
                break
            fi
        done
    fi

    if [[ "$_live_applied" == "true" ]]; then
        print_info "  ✓ XFCE compositor enabled (xfwm4 use_compositing=true, live-applied)"
    else
        print_info "  ✓ XFCE compositor enabled (xfwm4 use_compositing=true, takes effect on next login)"
    fi
    return 0
}

install_conky_fonts() {
    # The conky focus-alert + panel titles use ${font Impact:size=...}.
    # Without Impact, fontconfig falls back to Noto Sans and the HUD title
    # renders in the wrong theme. Two delivery paths in priority order:
    #
    #   1) Tarball-bundled Impact.ttf at $EXTRACT_DIR/fonts/msttcorefonts/Impact.ttf
    #      — works offline, written by pack-kodachi.sh from the same overlay
    #      file the ISO build ships.
    #   2) apt-get install -y ttf-mscorefonts-installer with the EULA
    #      preseeded via debconf — fallback for older tarballs that don't
    #      bundle the .ttf yet OR when copy fails for any reason.
    #
    # Silent skip on systems without sudo / apt is fine; the deps installer
    # covers those paths.
    local target_dir="/usr/share/fonts/truetype/msttcorefonts"
    local target_path="$target_dir/Impact.ttf"

    # Already present and resolvable? Nothing to do.
    if command -v fc-match >/dev/null 2>&1; then
        if fc-match "Impact:size=18" 2>/dev/null | grep -qi 'Impact.ttf'; then
            return 0
        fi
    elif [[ -f "$target_path" ]]; then
        return 0
    fi

    print_step "Installing Impact font (required for conky HUD titles)..."

    # Path 1: tarball-bundled .ttf.
    local bundled=""
    if [[ -n "${EXTRACT_DIR:-}" && -f "$EXTRACT_DIR/fonts/msttcorefonts/Impact.ttf" ]]; then
        bundled="$EXTRACT_DIR/fonts/msttcorefonts/Impact.ttf"
    fi

    if [[ -n "$bundled" ]] && command -v sudo >/dev/null 2>&1; then
        if sudo -n mkdir -p "$target_dir" 2>/dev/null && \
           sudo -n install -m 0644 "$bundled" "$target_path" 2>/dev/null; then
            sudo -n fc-cache -f >/dev/null 2>&1 || true
            if command -v fc-match >/dev/null 2>&1 && \
               fc-match "Impact:size=18" 2>/dev/null | grep -qi 'Impact.ttf'; then
                print_success "  ✓ Installed bundled Impact.ttf to $target_path"
                return 0
            fi
            print_warning "  Bundled Impact.ttf copied but fc-match still does not resolve to Impact; trying apt fallback"
        else
            print_warning "  Could not write $target_path (no passwordless sudo?); trying apt fallback"
        fi
    fi

    # Path 2: apt fallback (works on Debian/Ubuntu with network).
    if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
        if command -v debconf-set-selections >/dev/null 2>&1; then
            echo 'msttcorefonts msttcorefonts/accepted-mscorefonts-eula select true' \
                | sudo -n debconf-set-selections 2>/dev/null || true
            echo 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true' \
                | sudo -n debconf-set-selections 2>/dev/null || true
        fi
        if sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Use-Pty=0 \
                -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
                ttf-mscorefonts-installer >/dev/null 2>&1; then
            sudo -n fc-cache -f >/dev/null 2>&1 || true
            print_success "  ✓ Installed ttf-mscorefonts-installer (Impact + other MS core fonts)"
            return 0
        fi
        print_warning "  apt-get install ttf-mscorefonts-installer failed (offline? package unavailable?); conky HUD titles will use Noto Sans fallback"
        return 1
    fi

    print_warning "  No bundled Impact.ttf and apt unavailable; conky HUD titles will use Noto Sans fallback"
    return 1
}

setup_conky() {
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

    if install_conky_assets; then
        install_conky_fonts || true
        enable_xfce_compositor_for_self || true
        install_conky_watchdog || true
        if install_conky_autostart; then
            CONKY_SETUP_DONE=true
        fi
    fi
}

setup_conky

prime_session_helper_manager_env() {
    if ! command -v systemctl >/dev/null 2>&1; then
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

    local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local helper_xauthority="${XAUTHORITY:-$HOME/.Xauthority}"
    local dbus_session_bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime_dir/bus}"

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

    local helper_bin=""
    helper_bin=$(find_session_helper_binary 2>/dev/null || true)
    if [[ -z "$helper_bin" ]]; then
        print_warning "kodachi-session-helper binary not found. Skipping user service setup."
        return 0
    fi

    local systemd_user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local service_file="$systemd_user_dir/kodachi-session-helper.service"
    local wants_dir="$systemd_user_dir/default.target.wants"
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

    local started=false
    if command -v systemctl >/dev/null 2>&1; then
        prime_session_helper_manager_env
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        if systemctl --user enable --now kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        elif systemctl --user restart kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        elif systemctl --user start kodachi-session-helper.service >/dev/null 2>&1; then
            started=true
        fi
    fi

    if [[ "$started" == "true" ]]; then
        print_success "Session helper user service refreshed and started"
    else
        print_success "Session helper user service refreshed"
        print_info "It will start automatically on the next graphical login."
    fi
}

# ── Step 8b: Welcome autostart ──────────────────────────────────────
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

    local autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    local autostart_file="$autostart_dir/kodachi-dashboard.desktop"
    local dashboard_bin="$INSTALL_PATH/kodachi-dashboard"

    if [[ ! -f "$dashboard_bin" ]]; then
        print_warning "kodachi-dashboard binary not found at $dashboard_bin. Skipping autostart."
        return 0
    fi

    # Create the launcher script if missing, or refresh it when an older copy
    # (pre-seeded by the ISO or a prior install) lacks the broadened
    # GPU-driver detection (nouveau / legacy radeon + NVIDIA proprietary).
    # Refresh marker is GPU_NEEDS_FALLBACK — older launchers used the
    # narrower NVIDIA_PROPRIETARY token and get rewritten on next install.
    local launcher_script="/usr/local/bin/kodachi-dashboard-launcher"
    if [[ ! -f "$launcher_script" ]] || ! grep -q 'GPU_NEEDS_FALLBACK' "$launcher_script" 2>/dev/null || ! grep -q 'DASHBOARD_BIN=' "$launcher_script" 2>/dev/null || ! grep -q 'ALLOW_MULTI' "$launcher_script" 2>/dev/null; then
        print_info "Installing/refreshing dashboard launcher script..."
        local _launcher_tmp
        _launcher_tmp="$(mktemp "${TMPDIR:-/tmp}/kodachi-launcher.XXXXXX")"
        cat > "$_launcher_tmp" << 'LAUNCHER_EOF'
#!/bin/bash

# kodachi-dashboard-launcher
# ===========================================================
#
# SPDX-License-Identifier: LicenseRef-Kodachi-SAN-1.1
# Copyright (c) 2013-2026 Warith Al Maawali
#
# This file is part of Kodachi OS.
# For full license terms, see LICENSE.md or visit:
# http://kodachi.cloud/wiki/bina/license.html
#
# Commercial or organizational use requires a written license.
# Contact: warith@digi77.com

# ==========================================
# KODACHI OS - DASHBOARD LAUNCHER
# ==========================================
#
# Launches the Kodachi Dashboard with VM and GPU-driver detection.
# Auto-detects VM environments and GPU drivers that need the WebKitGTK
# software-render fallback so the dashboard does not come up as a blank
# window.
#
# Detected paths that need the fallback:
#   - NVIDIA proprietary driver (kernel module: nvidia)
#   - Nouveau (open-source NVIDIA driver; Mesa-based; Kepler/Maxwell EGL
#     and GBM are flaky enough to silently break WebKitGTK DMABUF init)
#   - Legacy AMD via the radeon kernel module (pre-amdgpu, GCN1 and older)
#
# Applied env vars:
#   - WEBKIT_DISABLE_DMABUF_RENDERER=1  (disables DMA-BUF render path)
#   - WEBKIT_DISABLE_COMPOSITING_MODE=1 (forces simpler render path)
#   - LIBGL_ALWAYS_SOFTWARE=1           (Mesa-only; forces llvmpipe;
#                                        ineffective on NVIDIA proprietary
#                                        GL stack so scoped to Mesa drivers)
#   - __NV_DISABLE_EXPLICIT_SYNC=1      (NVIDIA-proprietary-only; disables
#                                        explicit-sync path that crashes
#                                        WebKitGTK on some kernel combos)
# And on the launch line: --no-gpu (Tauri / WebKit hint)
#
# Version: 9.0.1
# Author:  Warith Al Maawali
# Website: https://kodachi.cloud
# GitHub:  https://github.com/AiGptCode/Kodachi-OS

VM_DETECTED=false
GPU_NEEDS_FALLBACK=false
GPU_IS_MESA_DRIVER=false
GPU_IS_NVIDIA_PROPRIETARY=false

# VM detection via DMI strings.
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

# GPU driver detection. Order matters only for the IS_* flags (Mesa vs
# proprietary controls which env-var subset gets applied below).

# 1. NVIDIA proprietary driver.
if [ -f /proc/driver/nvidia/version ] || \
   lsmod 2>/dev/null | grep -qE '^nvidia[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_NVIDIA_PROPRIETARY=true
fi

# 2. Nouveau (open-source NVIDIA, Mesa-based). Catches GTX 770 / Kepler
#    and other older NVIDIA chips whose Nouveau GBM/EGL silently fails the
#    WebKitGTK DMABUF init, producing a black dashboard window.
if lsmod 2>/dev/null | grep -qE '^nouveau[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_MESA_DRIVER=true
fi

# 3. Legacy AMD via radeon module (pre-amdgpu, GCN1 and earlier). Modern
#    AMD loads amdgpu, so this only matches the truly old hardware.
if lsmod 2>/dev/null | grep -qE '^radeon[[:space:]]' && \
   ! lsmod 2>/dev/null | grep -qE '^amdgpu[[:space:]]'; then
    GPU_NEEDS_FALLBACK=true
    GPU_IS_MESA_DRIVER=true
fi

# Apply env vars based on what was detected.
if [ "$GPU_NEEDS_FALLBACK" = "true" ]; then
    export WEBKIT_DISABLE_DMABUF_RENDERER=1
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
fi

# LIBGL_ALWAYS_SOFTWARE is Mesa-only. The NVIDIA proprietary GL stack
# ignores it, so scope to Mesa drivers only.
if [ "$GPU_IS_MESA_DRIVER" = "true" ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
fi

# NVIDIA proprietary on Wayland can crash WebKitGTK via explicit-sync;
# disabling it forces the older sync path that compositors handle.
if [ "$GPU_IS_NVIDIA_PROPRIETARY" = "true" ]; then
    export __NV_DISABLE_EXPLICIT_SYNC=1
fi

# Resolve the dashboard binary at runtime. global-launcher normally
# symlinks it to /usr/local/bin/kodachi-dashboard, but that symlink is
# absent if global-launcher's deploy step never ran. Fall back across the
# known install locations so the launcher never dies with "No such file".
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

# ==========================================
# SINGLE-INSTANCE GUARD
# ==========================================
#
# Alt+F4 HIDES the dashboard to the tray, it does not exit. Clicking the desktop
# icon again used to start a SECOND full instance: measured on 2026-08-31 across
# three VMs, one process and one window became two processes and two windows,
# each with its own tray registration, its own permission-guard auto-start and
# its own polling loop. On a four-core box that is a second copy of every hook
# poll for no benefit, and the user has no way to tell which window is which.
#
# Raise the existing window instead. `pgrep -x` cannot be used here: the process
# name is 17 characters and Linux truncates comm to 15, so an -x match silently
# returns nothing. Match the argv path instead, anchored so that this launcher's
# own command line ("kodachi-dashboard-launcher") cannot match itself.
#
# KODACHI_DASHBOARD_ALLOW_MULTI=1 deliberately bypasses the guard.
if [ "${KODACHI_DASHBOARD_ALLOW_MULTI:-0}" != "1" ]; then
    # Candidates come from a broad argv match, but argv is NOT trusted to decide:
    # any process whose command line merely CONTAINS this path matches, including
    # a shell running a script that mentions it. Proven while writing this guard:
    # the probe shell that tested the pattern matched itself twice. A false
    # positive here does not misreport anything, it PREVENTS THE DASHBOARD FROM
    # STARTING AT ALL, so the candidate is confirmed by its actual executable via
    # /proc/<pid>/exe, which a shell can never fake.
    _existing=""
    for _pid in $(pgrep -u "$(id -u)" -f 'kodachi-dashboard' 2>/dev/null); do
        [ "$_pid" = "$$" ] && continue
        _exe=$(readlink "/proc/$_pid/exe" 2>/dev/null) || continue
        # INST-1: a deploy that overwrites the binary while the old dashboard is
        # still running makes the kernel append ' (deleted)' to this readlink, so
        # the bare basename stops matching and the guard misses exactly the
        # instance it exists to find. That is the moment the operator clicks the
        # icon again and gets a second full instance, two trays and two poll loops.
        _exe=${_exe% (deleted)}
        [ "${_exe##*/}" = "kodachi-dashboard" ] || continue
        _existing="$_pid"
        break
    done
    if [ -n "$_existing" ]; then
        # Whether we ACTUALLY raised the window. The success message used to sit
        # outside every guard below, so it printed "raised the existing window"
        # even when there was no DISPLAY, no xdotool, no matching window, or a
        # failed map/activate. That is a false-success path: it reports the very
        # outcome it failed to achieve, and it reproduces the silent no-op this
        # guard exists to prevent, only with a reassuring message on top.
        _raised=0
        if [ -n "${DISPLAY:-}" ] && command -v xdotool >/dev/null 2>&1; then
            # --class matches the SECOND WM_CLASS value, which is the
            # capitalised "Kodachi-dashboard", and xdotool matches it
            # case-sensitively, so `--class 'kodachi-dashboard'` returns NOTHING.
            # Measured read-only on .192 by <agent> against the live
            # dashboard: xprop reports WM_CLASS = "kodachi-dashboard",
            # "Kodachi-dashboard"; --class with the lowercase value returned 0
            # ids while --classname returned the real window. Getting this wrong
            # is worse than the bug being fixed: the guard would suppress the
            # second process, fail to raise the first, and exit 0, so clicking
            # the icon would do NOTHING AT ALL. --classname matches the instance
            # name, which is the stable lowercase value.
            _win=$(xdotool search --classname 'kodachi-dashboard' 2>/dev/null | tail -1)
            if [ -n "$_win" ]; then
                if xdotool windowmap "$_win" >/dev/null 2>&1 &&
                   xdotool windowactivate "$_win" >/dev/null 2>&1; then
                    _raised=1
                fi
            fi
        fi
        if [ "$_raised" = "1" ]; then
            echo "kodachi-dashboard-launcher: already running (pid $_existing); raised the existing window instead of starting a second instance." >&2
        else
            echo "kodachi-dashboard-launcher: already running (pid $_existing), and the existing window could NOT be raised (no DISPLAY, xdotool unavailable, or no matching window). Not starting a second instance; use the tray icon, or set KODACHI_DASHBOARD_ALLOW_MULTI=1 to force one." >&2
        fi
        exit 0
    fi
fi

# Launch dashboard with appropriate flags.
if [ "$VM_DETECTED" = "true" ] || [ "$GPU_NEEDS_FALLBACK" = "true" ]; then
    exec "$DASHBOARD_BIN" --no-gpu "$@"
else
    exec "$DASHBOARD_BIN" "$@"
fi
LAUNCHER_EOF
        # best-effort install (a piped `curl | bash` non-root install cannot prompt
        # for a sudo password; the launcher is an optional convenience, the dashboard
        # binary itself is already installed, so never abort the install over it)
        if sudo cp "$_launcher_tmp" "$launcher_script" 2>/dev/null && sudo chmod 755 "$launcher_script" 2>/dev/null; then
            print_success "Created launcher script: $launcher_script"
        else
            print_warning "Could not install $launcher_script (sudo unavailable / no terminal for password); dashboard works, launcher is optional (re-run in a terminal with sudo to add it)"
        fi
        rm -f "$_launcher_tmp" 2>/dev/null || true
    fi

    # Repair permissions even when the launcher was pre-seeded by the image.
    sudo chmod 755 "$launcher_script" 2>/dev/null || true

    # Repair permissions on other system binaries that may have been pre-seeded
    for _bin in kodachi-fix-resolvconf dns-diag hysteria; do
        [ -f "/usr/local/bin/$_bin" ] && sudo chmod 755 "/usr/local/bin/$_bin" 2>/dev/null || true
    done

    cleanup_legacy_autostart_entries
    if [[ -f "$autostart_file" ]]; then
        if grep -q "^Exec=/usr/local/bin/kodachi-dashboard-launcher$" "$autostart_file" 2>/dev/null; then
            print_info "Refreshing dashboard autostart entry: $autostart_file"
        else
            print_warning "Dashboard autostart entry is outdated. Replacing: $autostart_file"
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

    print_success "Dashboard autostart enabled: $autostart_file"
    return 0
}

setup_dashboard_autostart
setup_session_helper_service

# Step 9: Create desktop shortcuts
mark_desktop_file_trusted() {
    local desktop_file="$1"
    local checksum=""
    local trust_ok=false
    local uri="file://$desktop_file"

    _run_gio_set() {
        local target="$1"
        local key="$2"
        local value="$3"
        if gio set "$target" "$key" "$value" 2>/dev/null; then
            return 0
        fi
        if command -v dbus-launch &>/dev/null; then
            if dbus-launch gio set "$target" "$key" "$value" 2>/dev/null; then
                return 0
            fi
        fi
        if command -v dbus-run-session &>/dev/null; then
            if dbus-run-session -- gio set "$target" "$key" "$value" 2>/dev/null; then
                return 0
            fi
        fi
        return 1
    }

    if command -v sha256sum &>/dev/null; then
        checksum=$(sha256sum "$desktop_file" | awk '{print $1}')
    fi

    # GNOME/Nautilus and XFCE trust metadata (best-effort)
    if command -v gio &>/dev/null; then
        _run_gio_set "$desktop_file" metadata::trusted true || \
            _run_gio_set "$desktop_file" metadata::trusted yes || \
            _run_gio_set "$uri" metadata::trusted true || \
            _run_gio_set "$uri" metadata::trusted yes || true
        if [[ -n "$checksum" ]]; then
            _run_gio_set "$desktop_file" metadata::xfce-exe-checksum "$checksum" || \
                _run_gio_set "$uri" metadata::xfce-exe-checksum "$checksum" || true
        fi
    fi

    if command -v gvfs-set-attribute &>/dev/null; then
        gvfs-set-attribute -t string "$desktop_file" metadata::trusted "true" 2>/dev/null && trust_ok=true || true
        if [[ -n "$checksum" ]]; then
            gvfs-set-attribute -t string "$desktop_file" metadata::xfce-exe-checksum "$checksum" 2>/dev/null || true
        fi
    fi

    if command -v setfattr &>/dev/null; then
        setfattr -n user.xfce.executable -v true "$desktop_file" 2>/dev/null || true
    fi

    # Verify trust marker was really applied.
    if command -v gio &>/dev/null; then
        if gio info "$desktop_file" 2>/dev/null | grep -q "metadata::trusted: true"; then
            trust_ok=true
        fi
    fi

    if [[ "$trust_ok" != true ]]; then
        print_warning "Could not persist desktop trust metadata for: $desktop_file"
        print_warning "If XFCE shows untrusted prompt, right-click -> Allow Launching once."
    fi
}

update_thunar_root_actions() {
    local thunar_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Thunar"
    local user_uca="$thunar_dir/uca.xml"

    if [[ ! -f "$user_uca" ]]; then
        return 0
    fi

    if ! grep -qE '<command>sudo[[:space:]]+thunar[[:space:]]+%[Ff]</command>|<command>sudo[[:space:]]+mousepad[[:space:]]+%[Ff]</command>' "$user_uca" 2>/dev/null; then
        return 0
    fi

    cp -f "$user_uca" "$user_uca.bak.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
    sed -E -i \
        -e 's#<command>sudo[[:space:]]+thunar[[:space:]]+%([Ff])</command>#<command>sudo -n thunar %\1</command>#' \
        -e 's#<command>sudo[[:space:]]+mousepad[[:space:]]+%([Ff])</command>#<command>sudo -n mousepad %\1</command>#' \
        "$user_uca"

    print_success "Updated Thunar root actions in $user_uca"
}

create_desktop_shortcuts() {
    print_step "Creating desktop shortcuts..."

    local DESKTOP_DIR=""   # init for set -u: on headless systems no branch below assigns it
    # Detect desktop directory (supports multiple languages)
    if [[ -d "$HOME/Desktop" ]]; then
        DESKTOP_DIR="$HOME/Desktop"
    elif [[ -d "$HOME/Escritorio" ]]; then
        DESKTOP_DIR="$HOME/Escritorio"
    elif [[ -d "$HOME/Bureau" ]]; then
        DESKTOP_DIR="$HOME/Bureau"
    elif [[ -d "$HOME/Schreibtisch" ]]; then
        DESKTOP_DIR="$HOME/Schreibtisch"
    elif command -v xdg-user-dir &>/dev/null; then
        DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
    fi

    if [[ -z "$DESKTOP_DIR" ]] || [[ ! -d "$DESKTOP_DIR" ]]; then
        print_warning "Desktop directory not found, skipping shortcuts"
        return 0
    fi

    # Determine icon path (prefer hooks/icons first, then config/icons)
    local ICON_PATH="$INSTALL_PATH/icons/kodachi-dashboard.png"
    if [[ ! -f "$ICON_PATH" ]]; then
        ICON_PATH="$INSTALL_PATH/config/icons/kodachi-dashboard.png"
    fi
    if [[ ! -f "$ICON_PATH" ]]; then
        ICON_PATH="utilities-terminal"
    fi

    # Remove legacy launcher wrapper from older installer versions
    # (Desktop shortcut now uses direct Exec + Path)
    rm -f "$INSTALL_PATH/kodachi-dashboard-launcher.sh" 2>/dev/null || true

    # 1. Kodachi Dashboard shortcut
    # Match the proven Desktop-02 test style:
    # direct binary Exec + explicit Path to hooks directory.
    cat > "$DESKTOP_DIR/kodachi-dashboard.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Kodachi Dashboard
Comment=Kodachi Security Dashboard
Exec=/usr/local/bin/kodachi-dashboard-launcher
TryExec=$INSTALL_PATH/kodachi-dashboard
Path=$INSTALL_PATH
Icon=$ICON_PATH
Terminal=false
Categories=Security;System;
StartupNotify=true
StartupWMClass=kodachi-dashboard
X-XFCE-TrustedApplication=true
EOF
    chmod +x "$DESKTOP_DIR/kodachi-dashboard.desktop"
    mark_desktop_file_trusted "$DESKTOP_DIR/kodachi-dashboard.desktop"
    # Compatibility toggle for some XFCE/Thunar setups
    if command -v xfconf-query &>/dev/null; then
        xfconf-query -c thunar -p /misc-exec-shell-scripts-by-default -n -t bool -s true 2>/dev/null || true
    fi

    # 2. Kodachi Binaries folder shortcut
    # Match the proven Folder-02 style (thunar launcher).
    cat > "$DESKTOP_DIR/kodachi-binaries.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Kodachi Binaries
Comment=Open Kodachi binaries folder
Exec=xdg-open $INSTALL_PATH
Icon=folder-open
Terminal=false
Categories=Utility;
X-XFCE-TrustedApplication=true
EOF
    chmod +x "$DESKTOP_DIR/kodachi-binaries.desktop"
    mark_desktop_file_trusted "$DESKTOP_DIR/kodachi-binaries.desktop"
    update_thunar_root_actions

    # 3. Kodachi AutoShield is RETIRED as a standalone app — it is now a tab on
    #    the dashboard startup screen (after Mobile). Remove any stale standalone
    #    launcher so no dead "AutoShield" shortcut points at the removed app.
    rm -f "$DESKTOP_DIR/kodachi-autoshield.desktop" 2>/dev/null || true

    # Ensure legacy folder symlink is removed; desktop shortcuts only.
    rm -f "$DESKTOP_DIR/kodachi-binaries" 2>/dev/null || true

    print_success "Desktop shortcuts created: kodachi-dashboard.desktop, kodachi-binaries.desktop"

    # Also install/update system-wide Whisker menu entries in /usr/share/applications/
    # NOTE: This will only succeed when running as root or during ISO build.
    # For regular user installs, the deps-install.sh (which runs as root) handles this.
    local sys_apps="/usr/share/applications"
    if [[ -d "$sys_apps" ]] && [[ -w "$sys_apps" ]]; then
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

        # AutoShield retired as a standalone app (now a dashboard startup-screen
        # tab). Remove any stale system-wide menu entry pointing at the old app.
        rm -f "$sys_apps/kodachi-autoshield.desktop" 2>/dev/null || true
        print_success "System-wide Whisker menu entries updated in $sys_apps"
    fi
}

# Create desktop shortcuts
create_desktop_shortcuts

# Step 10: Add to PATH in .bashrc with idempotent block management
if [[ "$SKIP_PATH_UPDATE" != "true" ]]; then
    print_step "Updating PATH in .bashrc..."

    # Use BEGIN/END markers for idempotent updates
    if ! grep -q "^# BEGIN KODACHI PATH$" "$HOME/.bashrc" 2>/dev/null; then
        # First time installation - add the block
        {
            echo ""
            echo "# BEGIN KODACHI PATH"
            echo "export KODACHI_HOME=\"$INSTALL_PATH\""
            echo "export PATH=\"\$KODACHI_HOME:\$PATH\""
            echo "# END KODACHI PATH"
        } >> "$HOME/.bashrc"
        print_success "Added Kodachi path block to .bashrc"
    else
        # Block exists - update the KODACHI_HOME value in place
        awk -v NEWHOME="$INSTALL_PATH" '
            BEGIN { inblk=0 }
            /^# BEGIN KODACHI PATH$/ {
                inblk=1
                print
                print "export KODACHI_HOME=\"" NEWHOME "\""
                print "export PATH=\"$KODACHI_HOME:$PATH\""
                next
            }
            /^# END KODACHI PATH$/ {
                inblk=0
                print
                next
            }
            { if (!inblk) print }
        ' "$HOME/.bashrc" > "$HOME/.bashrc.tmp" && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
        print_success "Updated Kodachi path block in .bashrc"
    fi
fi

if [[ -z "$PACKAGE_SHA256" ]]; then
    PACKAGE_SHA256="$(sha256sum "$PACKAGE_FILE" 2>/dev/null | awk '{print $1}' || true)"
fi

METADATA_BUILD_NUMBER=""
METADATA_LAST_BUILD_DATE=""
if [[ "$KODACHI_VERSION" == "$LATEST_KODACHI_VERSION" ]]; then
    METADATA_BUILD_NUMBER="$LATEST_KODACHI_BUILD_NUMBER"
    METADATA_LAST_BUILD_DATE="$LATEST_KODACHI_LAST_BUILD_DATE"
fi

write_installed_binary_pack_metadata \
    "$INSTALL_METADATA_FILE" \
    "$KODACHI_VERSION" \
    "$METADATA_BUILD_NUMBER" \
    "$METADATA_LAST_BUILD_DATE" \
    "$PACKAGE_SHA256"
print_info "Binary pack metadata recorded: $INSTALL_METADATA_FILE"

if ! finalize_production_auth_trust "/opt/kodachi/dashboard/hooks"; then
    print_error "Production auth-trust installation failed"
    exit 1
fi

# Final summary
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Script #1 Complete - Binaries Installed!  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
print_success "Kodachi binaries installed to: $INSTALL_PATH"
print_info "Binaries total: $TOTAL_COUNT"
print_info "Binaries installed: $VERIFIED_COUNT"
# [CLAW-ARCHIVED 2026-05-18] kodachi-claw/zeroclaw/zeroclaw-desktop retired (not shipped)
# if [[ -x "$INSTALL_PATH/kodachi-claw" || -x "$INSTALL_PATH/zeroclaw" ]]; then
#     print_info "Agent binaries available: kodachi-claw and zeroclaw (shipped as separate binaries)"
# fi
# if [[ -x "$INSTALL_PATH/zeroclaw-desktop" ]]; then
#     print_info "ZeroClaw Desktop GUI available: zeroclaw-desktop (Tauri companion app)"
# fi
if [[ $SKIPPED_COUNT -gt 0 ]]; then
    print_warning "Binaries skipped: $SKIPPED_COUNT"
fi
print_info "Signatures verified: $VERIFIED_COUNT"
print_info "Desktop shortcuts: kodachi-dashboard, kodachi-binaries"
if [[ -x "$INSTALL_PATH/conky-status" ]]; then
    print_info "Conky Rust gateway: $INSTALL_PATH/conky-status"
fi
if [[ "$CONKY_SETUP_DONE" == "true" ]]; then
    print_info "Conky installed to: $CONKY_INSTALL_DIR"
    print_info "Conky startup file: $CONKY_AUTOSTART_FILE"
elif ! detect_gui_environment; then
    print_info "Conky: skipped (no GUI detected)"
fi

if [[ $FAILED_COUNT -gt 0 ]]; then
    print_warning "Signatures not verified: $FAILED_COUNT"
fi

if [[ "$PERMISSION_GUARD_SKIPPED" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  permission-guard daemon is still using its old image      ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  The verified root-owned replacement is installed on disk."
    echo -e "  Stop or restart the daemon to activate it:"
    echo -e "    ${BOLD}sudo permission-guard --stop-daemon${NC}"
    echo ""
    echo -e "  The daemon will auto-restart on next login."
    echo ""
fi

echo ""
print_highlight "═══════════════════════════════════════════════════════════════"
print_highlight "  IMPORTANT: You Must Run Script #2 Next for Dashboard to Work"
print_highlight "═══════════════════════════════════════════════════════════════"
echo ""

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
        echo ""
        print_highlight "Next Step - Script #2 (REQUIRED for Dashboard):"
        echo ""
        print_warning "The Dashboard and binaries won't work until you run the dependencies script!"
        echo ""
        echo -e "  ${CYAN}Download and run the dependencies installer:${NC}"
        echo -e "   ${BOLD}curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-deps-install.sh | sudo bash${NC}"
        echo ""
        echo -e "  ${CYAN}Or if you have it locally:${NC}"
        echo -e "   ${BOLD}sudo bash kodachi-deps-install.sh${NC}"
        echo ""
        print_info "This script installs system packages, configures sudoers for dashboard, and sets up DNS/Tor."
    else
        print_warning "User '$current_user' is NOT in the sudoers group"
        echo ""
        print_highlight "IMPORTANT: You need sudo access to run Script #2"
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
        print_highlight "After adding to sudoers, run Script #2:"
        echo ""
        print_warning "Dashboard won't work until you run the dependencies script!"
        echo ""
        echo -e "  ${CYAN}Script #2 - Dependencies Installer (REQUIRED):${NC}"
        echo -e "   ${BOLD}curl -sSL https://www.kodachi.cloud/apps/os/install/kodachi-deps-install.sh | sudo bash${NC}"
    fi
}

echo ""
# Check sudoers status and provide appropriate next steps
check_sudoers_status
echo ""

# --- Emergency shortcut daemon: input group advisory ---
if command -v getent >/dev/null 2>&1 && getent group input >/dev/null 2>&1; then
    CURRENT_USER="$(id -un)"
    if ! id -nG "$CURRENT_USER" 2>/dev/null | grep -qw input; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║              INPUT GROUP ADVISORY                          ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  The kodachi-session-helper daemon requires access to"
        echo "  /dev/input/event* devices for hardware key verification."
        echo ""
        echo -e "  Your user '${BOLD}$CURRENT_USER${NC}' is NOT in the '${BOLD}input${NC}' group."
        echo ""
        echo "  To enable emergency keyboard shortcuts, run:"
        echo -e "    ${BOLD}sudo usermod -aG input $CURRENT_USER${NC}"
        echo ""
        echo "  Then log out and back in for the change to take effect."
        echo ""
        echo "  For temporary access without logout:"
        echo -e "    ${BOLD}sudo setfacl -m u:$CURRENT_USER:r /dev/input/event*${NC}"
        echo ""
    fi
fi

print_success "Binary installation complete!"
echo ""
