#!/usr/bin/env bash

# system-meta.sh
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
FIELD="${1:-files}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/conky-gateway-common.sh" 2>/dev/null || true
BIN=$(conky_gateway_find_binary 2>/dev/null || true)

sanitize_value() {
    # PURE BASH ON PURPOSE. This used to be `$(echo "$value" | sed ...)`, which is a subshell
    # plus a sed on EVERY call, and this function is called from get_key, get_build_meta_value,
    # compose_version_with_build and first_non_na, so it is the hottest thing in the conky path.
    #
    # Measured on an installed <lab-host> desktop, 2026-09-24, 40 s window: the machine ran 4,969
    # forks (124/s) while idle, and this script's six subcommands were the top spawners at
    # roughly 31/s between them. `sed s/[[:space:]]\+/ /g` was the single most frequent child
    # command sampled. Each call cost a fork for the command substitution plus a fork for sed;
    # bash parameter expansion costs neither.
    #
    # Proven byte-identical to the sed version over 12 adversarial inputs (leading, trailing and
    # interior runs, tabs, CR, LF, vertical tab, form feed, empty, already-clean), with a
    # positive control confirming a broken implementation is detected.
    local value="${1:-}"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="${value//$'\v'/ }"
    value="${value//$'\f'/ }"
    while [[ "$value" == *"  "* ]]; do value="${value//  / }"; done
    value="${value# }"
    value="${value% }"
    # `printf`, NEVER `echo`. MEASURED by <agent> against the pre-rewrite version: a value
    # of `-n`, `-e`, `-E` or `-ne` is swallowed by bash's builtin echo as an OPTION, so those four
    # inputs printed "N/A" before this function was rewritten and printed an EMPTY LINE afterwards.
    # An empty line in a conky ${exec} is a blank field on the operator's desktop, which is exactly
    # the class of silent wrong output this function exists to prevent.
    #
    # AND ONE ACCEPTED DIFFERENCE FROM THE OLD `sed` VERSION, stated rather than hidden: under a
    # UTF-8 locale sed's [[:space:]] also collapsed U+2003, U+3000, U+1680, U+2028 and U+2009 to a
    # space, and these bash substitutions do not, so 9 of 24 measured inputs differ there. They are
    # left alone deliberately: adding multibyte literals to the replacement list behaves differently
    # depending on whether conky runs this under a UTF-8 or a C locale, and that is not a change to
    # make during a release freeze. The earlier claim that this rewrite was byte-identical was wrong
    # in both of these ways.
    if [[ -z "$value" ]]; then
        printf '%s\n' "N/A"
    else
        printf '%s\n' "$value"
    fi
}

compose_version_with_build() {
    local version=""
    local build=""

    version="$(sanitize_value "${1:-}")"
    build="$(sanitize_value "${2:-}")"
    version="${version#v}"

    if [[ "$version" == "N/A" ]]; then
        echo "N/A"
        return 0
    fi

    # Conky is space-constrained: use the COMPACT dotted form "X.Y.Z.N".
    # Already-dotted (3+ segment) values pass through unchanged.
    if [[ "$version" =~ ^[0-9]+(\.[0-9]+){3,}$ ]]; then
        echo "$version"
        return 0
    fi

    if [[ "$build" =~ ^[0-9]+$ ]] && [[ "$version" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
        printf '%s.%s\n' "$version" "$build"
        return 0
    fi

    echo "$version"
}

get_key() {
    local key="$1"
    local default_value="${2:-N/A}"
    if [[ -z "${BIN:-}" ]]; then
        sanitize_value "$default_value"
        return 0
    fi
    sanitize_value "$(conky_gateway_get_or_default "$key" "$default_value" 2 "$BIN")"
}

first_non_na() {
    local value
    for value in "$@"; do
        value="$(sanitize_value "$value")"
        if [[ "$value" != "N/A" ]]; then
            echo "$value"
            return 0
        fi
    done
    echo "N/A"
}

BUILD_META_FILE_CACHE="${BUILD_META_FILE_CACHE:-}"

resolve_build_meta_file() {
    if [[ -n "${BUILD_META_FILE_CACHE:-}" ]] && [[ -f "$BUILD_META_FILE_CACHE" ]]; then
        printf '%s\n' "$BUILD_META_FILE_CACHE"
        return 0
    fi

    local candidates=()
    local candidate=""

    if [[ -n "${KODACHI_BUILD_META_FILE:-}" ]]; then
        candidates+=("$KODACHI_BUILD_META_FILE")
    fi

    candidates+=(
        "/opt/kodachi/dashboard/hooks/config/build-meta.json"
        "$HOME/k900/dashboard/hooks/config/build-meta.json"
        "$HOME/dashboard/hooks/config/build-meta.json"
        "$HOME/Desktop/dashboard/hooks/config/build-meta.json"
        "/usr/share/kodachi/config/build-meta.json"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            BUILD_META_FILE_CACHE="$candidate"
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

build_meta_lookup() {
    local edition="${1:-}"
    local field="${2:-}"
    local meta_file=""

    [[ -n "$edition" && -n "$field" ]] || return 1
    meta_file="$(resolve_build_meta_file)" || return 1

    python3 - "$meta_file" "$edition" "$field" <<'PY'
import json
import sys
from pathlib import Path

meta_path, edition, field = sys.argv[1:4]

try:
    data = json.loads(Path(meta_path).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

editions = data.get("editions") or {}
entry = editions.get(edition) or {}

def clean(value):
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    text = str(value).strip()
    if not text or text.lower() == "null":
        return ""
    return text

root_version = clean(data.get("version"))
root_build = clean(data.get("build_number"))
root_nightly = clean(data.get("nightly_version"))
entry_build = clean(entry.get("build_number")) or (root_build if edition == "binary_pack" else "")
entry_nightly = clean(entry.get("nightly_version")) or (root_nightly if edition == "binary_pack" else "")

if field == "version":
    value = clean(entry.get("version")) or root_version
elif field == "build_number":
    value = entry_build
elif field == "nightly_version":
    # Conky uses the COMPACT dotted form "<stamp>.<build>" (e.g. 9.8.2.318).
    # entry_nightly already holds "<version>.<build>" from build-meta.json.
    value = entry_nightly
    if not value and root_version and entry_build:
        value = f"{root_version}.{entry_build}"
else:
    value = clean(entry.get(field))

if value:
    print(value)
PY
}

get_build_meta_value() {
    local edition="${1:-}"
    local field="${2:-}"
    sanitize_value "$(build_meta_lookup "$edition" "$field" 2>/dev/null || true)"
}

compose_version_from_keys() {
    local version_key="${1:-}"
    local build_key="${2:-}"

    compose_version_with_build \
        "$(get_key "$version_key" "N/A")" \
        "$(get_key "$build_key" "N/A")"
}

# AN ISO EDITION THIS MACHINE DOES NOT CARRY HAS NO LOCAL VERSION (2026-09-26).
#
# build-meta.json carries a figure for all three tracks, but an ISO build stamps only its OWN
# track (`iso_stamped_track`). The other ISO edition keeps whatever was frozen into the binary
# pack, which is older every time the other edition is rebuilt. Measured on the <lab-host> stable
# desktop image: the panel showed Terminal local <lab-host> against remote <lab-host> and lit the
# update dot, on a freshly built image, for an edition the machine does not even have. The
# frozen 19 came from `pack_date` 2026-09-25T16:12:46Z, since when terminal went 19 -> 20 -> 21
# -> 22.
#
# Reporting N/A is the honest answer AND fixes the dot for free: version-check.sh already maps
# an N/A on either side to status "N/A", which renders the neutral colour instead of the update
# colour. binary_pack is always applicable, because those binaries are installed on every edition.
# THE MARKER HAS THREE STATES AND `or ""` COLLAPSED TWO OF THEM (2026-09-26).
#
#   a track name  this image IS that ISO edition    -> only that edition is applicable
#   empty string  the binary pack on no Kodachi ISO -> NEITHER ISO edition is applicable
#   key absent    a build-meta.json older than it   -> unknown, keep showing it
#
# pack-kodachi.sh writes the empty form and the ISO hook overwrites it with its track, so a
# binary-pack-only install (the pack on plain Debian, no Kodachi ISO) is now distinguishable
# from an install too old to say. It used to read as "unknown" and got both ISO editions
# compared against the server, dot and all, on a machine carrying neither.
edition_applicable() {
    local want="${1:-}" meta_file="" track=""
    case "$want" in binary_pack|binary) return 0 ;; esac
    # build_meta_lookup() only reads editions[<edition>][<field>], so it cannot fetch a
    # top-level key. Read iso_stamped_track directly from the same resolved file.
    meta_file="$(resolve_build_meta_file 2>/dev/null)" || return 0
    # ABSENT prints the sentinel __ABSENT__, PRESENT-AND-EMPTY prints an empty line. An
    # unreadable or unparseable file exits non-zero, which the rc check separates from
    # both: a broken file must never be read as "no ISO edition on this machine".
    track="$(python3 - "$meta_file" 2>/dev/null <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("__ABSENT__" if "iso_stamped_track" not in data else (data.get("iso_stamped_track") or "").strip())
PY
    )" || return 0
    case "$track" in
        __ABSENT__) return 0 ;;                 # unknown, keep the old behaviour
        "")         return 1 ;;                 # binary pack only: no ISO edition here
        *)          [ "$track" = "$want" ] ;;
    esac
}

case "$FIELD" in
    files|timezone|resolution|boot|mode|hostname|kernel)
        get_key "system-meta.$FIELD" "N/A"
        ;;
    # Clock sync (On/Off/On*/Off*/?). Tor will not build circuits on a skewed
    # clock, so a privacy HUD should say whether the clock is trusted. A trailing
    # "*" is a reading carried from the previous cycle (detection phase tripped,
    # at most two cycles, then "?"). Added 2026-09-05.
    ntp)
        get_key "system-meta.ntp" "?"
        ;;
    ntp-conky)
        case "$(get_key "system-meta.ntp" "?")" in
            On)     printf '%s\n' '${color1}On' ;;
            Off)    printf '%s\n' '${color6}Off' ;;
            "On*")  printf '%s\n' '${color1}On${color6}*' ;;
            "Off*") printf '%s\n' '${color6}Off*' ;;
            *)      printf '%s\n' '${color3}?' ;;
        esac
        ;;
    binary_cur)
        first_non_na \
            "$(get_build_meta_value "binary_pack" "nightly_version")" \
            "$(compose_version_from_keys "system-meta.binary-cur" "system-meta.binary-nb")" \
            "$(compose_version_from_keys "data.versions.binary.cur" "data.versions.binary.nb")" \
            "$(get_build_meta_value "binary_pack" "version")" \
            "$(get_key "system-meta.binary-cur" "N/A")" \
            "$(get_key "data.versions.binary.cur" "N/A")" \
            "$(get_key "data.health.binary_version" "N/A")" \
            "$(compose_version_from_keys "data.versions.binary.on" "data.versions.binary.nb")" \
            "$(get_key "data.versions.binary.on" "N/A")"
        ;;
    binary_on)
        first_non_na \
            "$(compose_version_with_build "$(get_key "data.online_info.releases.binary_pack.nightly_version" "N/A")" "")" \
            "$(compose_version_from_keys "system-meta.binary-on" "system-meta.binary-nb")" \
            "$(compose_version_from_keys "data.versions.binary.on" "data.versions.binary.nb")" \
            "$(get_key "system-meta.binary-on" "N/A")" \
            "$(get_key "data.versions.binary.on" "N/A")"
        ;;
    binary_nb)
        first_non_na \
            "$(get_build_meta_value "binary_pack" "build_number")" \
            "$(get_key "system-meta.binary-nb" "N/A")" \
            "$(get_key "data.versions.binary.nb" "N/A")"
        ;;
    terminal_cur)
        edition_applicable "terminal" || { echo "N/A"; exit 0; }
        first_non_na \
            "$(get_build_meta_value "terminal" "nightly_version")" \
            "$(compose_version_from_keys "system-meta.terminal-cur" "system-meta.terminal-nb")" \
            "$(compose_version_from_keys "data.versions.terminal.cur" "data.versions.terminal.nb")" \
            "$(get_build_meta_value "terminal" "version")" \
            "$(get_key "system-meta.terminal-cur" "N/A")" \
            "$(get_key "data.versions.terminal.cur" "N/A")" \
            "$(get_key "data.health.binary_version" "N/A")" \
            "$(compose_version_from_keys "data.versions.terminal.on" "data.versions.terminal.nb")" \
            "$(get_key "data.versions.terminal.on" "N/A")"
        ;;
    terminal_on)
        first_non_na \
            "$(compose_version_with_build "$(get_key "data.online_info.releases.terminal.nightly_version" "N/A")" "")" \
            "$(compose_version_from_keys "system-meta.terminal-on" "system-meta.terminal-nb")" \
            "$(compose_version_from_keys "data.versions.terminal.on" "data.versions.terminal.nb")" \
            "$(get_key "system-meta.terminal-on" "N/A")" \
            "$(get_key "data.versions.terminal.on" "N/A")"
        ;;
    terminal_nb)
        first_non_na \
            "$(get_build_meta_value "terminal" "build_number")" \
            "$(get_key "system-meta.terminal-nb" "N/A")" \
            "$(get_key "data.versions.terminal.nb" "N/A")"
        ;;
    desktop_cur)
        edition_applicable "desktop" || { echo "N/A"; exit 0; }
        first_non_na \
            "$(get_build_meta_value "desktop" "nightly_version")" \
            "$(compose_version_from_keys "system-meta.desktop-cur" "system-meta.desktop-nb")" \
            "$(compose_version_from_keys "data.versions.desktop.cur" "data.versions.desktop.nb")" \
            "$(get_build_meta_value "desktop" "version")" \
            "$(get_key "system-meta.desktop-cur" "N/A")" \
            "$(get_key "data.versions.desktop.cur" "N/A")" \
            "$(get_key "data.health.binary_version" "N/A")" \
            "$(compose_version_from_keys "data.versions.desktop.on" "data.versions.desktop.nb")" \
            "$(get_key "data.versions.desktop.on" "N/A")"
        ;;
    desktop_on)
        first_non_na \
            "$(compose_version_with_build "$(get_key "data.online_info.releases.desktop.nightly_version" "N/A")" "")" \
            "$(compose_version_from_keys "system-meta.desktop-on" "system-meta.desktop-nb")" \
            "$(compose_version_from_keys "data.versions.desktop.on" "data.versions.desktop.nb")" \
            "$(get_key "system-meta.desktop-on" "N/A")" \
            "$(get_key "data.versions.desktop.on" "N/A")"
        ;;
    desktop_nb)
        first_non_na \
            "$(get_build_meta_value "desktop" "build_number")" \
            "$(get_key "system-meta.desktop-nb" "N/A")" \
            "$(get_key "data.versions.desktop.nb" "N/A")"
        ;;
    binary_applicable|terminal_applicable|desktop_applicable)
        # Exposed so version-check.sh can tell "this machine does not carry that edition"
        # apart from "I could not determine the version". Both print N/A, but only the
        # second should make an aggregate status unknown.
        case "$FIELD" in
            binary_applicable)   edition_applicable "binary_pack" && echo yes || echo no ;;
            terminal_applicable) edition_applicable "terminal"    && echo yes || echo no ;;
            desktop_applicable)  edition_applicable "desktop"     && echo yes || echo no ;;
        esac
        ;;
    *)
        echo "N/A"
        ;;
esac
