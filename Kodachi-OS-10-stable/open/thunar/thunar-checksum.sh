#!/bin/bash

# Thunar Checksum Handler - File checksum calculations for Thunar
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
# Last updated: 2026-02-05
#
# Description:
# Provides checksum calculation actions for Thunar file manager.
# Supports md5, sha256, sha512, and disk space calculations.
#
# Usage: thunar-checksum.sh -a <action> -n <filepath>
# Actions: md5, sha256, sha512, space
#
# Links:
# - Website: https://www.digi77.com
# - Website: https://www.kodachi.cloud
# - GitHub: https://github.com/WMAL
# - Discord: https://discord.gg/KEFErEx
# - LinkedIn: https://www.linkedin.com/in/warith1977
# - X (Twitter): https://x.com/warith2020

set -e

# EVERY zenity --info/--error/--warning/--question TEXT IS PANGO MARKUP, so any
# filename, command output or path interpolated into one is attacker-chosen data
# inside the wording of a dialog. An ordinary name like `Tom & Jerry.pdf` is
# enough: Pango raises "Entity did not end with a semicolon" and the dialog fails
# to render, in a menu where thunar-uca already discards the child's stderr, so
# the failure report is exactly what disappears. esc() is applied to the VARIABLE
# and never to the whole message, because the surrounding literals carry
# intentional <b> and <tt> markup that must survive.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

# Parse arguments
while getopts "a:n:" opt; do
    case $opt in
        a) ACTION="$OPTARG" ;;
        n) FILEPATH="$OPTARG" ;;
        *) echo "Usage: $0 -a <action> -n <filepath>"; exit 1 ;;
    esac
done

# Validate inputs
if [ -z "$ACTION" ] || [ -z "$FILEPATH" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -a <action> -n <filepath>"
    exit 1
fi

if [ ! -e "$FILEPATH" ]; then
    zenity --error --text="File or directory not found: $(esc "$FILEPATH")" 2>/dev/null || \
        echo "Error: File or directory not found: $FILEPATH"
    exit 1
fi

# Dynamic paths - detect user's desktop.
# Kept as the FALLBACK only: the checksum is written next to the file it
# describes, and the Desktop is used only when that directory is not writable.
DESKTOP="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
if [ ! -d "$DESKTOP" ]; then
    DESKTOP="$HOME"
fi

# Pick the output path for a checksum of $FILEPATH under algorithm $1.
#
# WHY THIS REPLACED "$DESKTOP/<alg>sum.txt". That name was FIXED, so the second
# file you checksummed silently overwrote the first and you had no way to tell
# which file the number on your Desktop belonged to. It also sat on the Desktop
# rather than beside the file, which is useless for `sha256sum -c`, the only
# thing a checksum file is for.
checksum_output_path() {
    local alg="$1" dir base out n
    dir="$(dirname -- "$FILEPATH")"
    base="$(basename -- "$FILEPATH")"
    [ -w "$dir" ] || dir="$DESKTOP"
    out="$dir/$base.$alg"
    n=1
    while [ -e "$out" ]; do
        out="$dir/$base.$alg.$n"
        n=$((n + 1))
    done
    printf '%s' "$out"
}

# Write the ONE record `<sum>sum -c` accepts for this file, into $2, using $1sum.
#
# WHY THE RECORD IS TAKEN FROM THE TOOL AND NOT REBUILT FROM "$FILENAME". GNU
# coreutils escapes a backslash or a newline in the file name as `\\` / `\n`
# and marks the line with a leading `\`; a record rebuilt by printf from the raw
# name is one `sum -c` rejects ("no properly formatted checksum lines found",
# measured by the Desktop audit of 2026-09-05: 6 of 6 such names failed against
# 3 of 3 plain names passing). The tool is run FROM the source directory on the
# bare name so the record names the file the way `sum -c` will look for it, and
# when the sidecar cannot live beside the file (unwritable directory) the record
# names the ABSOLUTE source path instead, so checking it from the Desktop finds
# the file (the old record carried the bare name and failed with "No such file").
write_checksum_record() {
    local alg="$1" out="$2" dir base record
    dir="$(dirname -- "$FILEPATH")"
    base="$(basename -- "$FILEPATH")"
    if [ "$(dirname -- "$out")" = "$dir" ]; then
        record="$(cd -- "$dir" && "${alg}sum" -- "$base")" || return 1
    else
        record="$("${alg}sum" -- "$FILEPATH")" || return 1
    fi
    printf '%s\n' "$record" > "$out"
}

# Icon - use system icon name (looked up via icon theme)
ICON="kodachi"

# Get filename for display
FILENAME="$(basename "$FILEPATH")"

case "$ACTION" in
    md5|md5sucmcheck)
        RESULT=$(md5sum -- "$FILEPATH")
        OUTPUT_FILE="$(checksum_output_path md5)"
        # The record is the tool's own line (GNU-escaped name, bare when the
        # sidecar sits beside the file, absolute on the Desktop fallback).
        write_checksum_record md5 "$OUTPUT_FILE" || {
            zenity --error --title="MD5 Checksum" --text="Could not write the checksum record:\n<tt>$(esc "$OUTPUT_FILE")</tt>" --width=520 2>/dev/null || true
            exit 1
        }

        # Try to open in editor
        if command -v mousepad >/dev/null 2>&1; then
            mousepad "$OUTPUT_FILE" &
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$OUTPUT_FILE" &
        fi

        notify-send -i "$ICON" "MD5 Checksum" "Result saved to $(esc "$(basename "$OUTPUT_FILE")")\n$(esc "$RESULT")" 2>/dev/null || true
        ;;

    sha256|sha2sucmcheck)
        RESULT=$(sha256sum -- "$FILEPATH")
        OUTPUT_FILE="$(checksum_output_path sha256)"
        # The record is the tool's own line (GNU-escaped name, bare when the
        # sidecar sits beside the file, absolute on the Desktop fallback).
        write_checksum_record sha256 "$OUTPUT_FILE" || {
            zenity --error --title="SHA256 Checksum" --text="Could not write the checksum record:\n<tt>$(esc "$OUTPUT_FILE")</tt>" --width=520 2>/dev/null || true
            exit 1
        }

        if command -v mousepad >/dev/null 2>&1; then
            mousepad "$OUTPUT_FILE" &
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$OUTPUT_FILE" &
        fi

        notify-send -i "$ICON" "SHA256 Checksum" "Result saved to $(esc "$(basename "$OUTPUT_FILE")")" 2>/dev/null || true
        ;;

    sha512|sha5sucmcheck)
        RESULT=$(sha512sum -- "$FILEPATH")
        OUTPUT_FILE="$(checksum_output_path sha512)"
        # The record is the tool's own line (GNU-escaped name, bare when the
        # sidecar sits beside the file, absolute on the Desktop fallback).
        write_checksum_record sha512 "$OUTPUT_FILE" || {
            zenity --error --title="SHA512 Checksum" --text="Could not write the checksum record:\n<tt>$(esc "$OUTPUT_FILE")</tt>" --width=520 2>/dev/null || true
            exit 1
        }

        if command -v mousepad >/dev/null 2>&1; then
            mousepad "$OUTPUT_FILE" &
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$OUTPUT_FILE" &
        fi

        notify-send -i "$ICON" "SHA512 Checksum" "Result saved to $(esc "$(basename "$OUTPUT_FILE")")" 2>/dev/null || true
        ;;

    space|spacecheck)
        # Use ncdu for disk space analysis
        if command -v ncdu >/dev/null 2>&1; then
            if command -v xfce4-terminal >/dev/null 2>&1; then
                xfce4-terminal --title="Disk usage: $FILENAME" -x ncdu -- "$FILEPATH" &
            elif command -v gnome-terminal >/dev/null 2>&1; then
                gnome-terminal -- ncdu -- "$FILEPATH" &
            elif command -v xterm >/dev/null 2>&1; then
                xterm -T "Disk usage: $FILENAME" -e ncdu -- "$FILEPATH" &
            else
                zenity --error --text="No terminal emulator found"
                exit 1
            fi
        else
            # Fallback to du
            SIZE=$(du -sh "$FILEPATH" 2>/dev/null | cut -f1)
            zenity --info --title="Disk Usage" --text="Size of $(esc "$FILENAME"): $(esc "$SIZE")"
        fi
        ;;

    *)
        zenity --error --text="Unknown action: $(esc "$ACTION")\nSupported: md5, sha256, sha512, space" 2>/dev/null || \
            echo "Error: Unknown action: $ACTION"
        exit 1
        ;;
esac

exit 0
