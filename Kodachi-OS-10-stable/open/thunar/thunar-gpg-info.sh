#!/bin/bash

# Thunar GPG Info - Display GPG file information
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
# Displays information about GPG encrypted/signed files from
# Thunar file manager context menu.
#
# Usage: thunar-gpg-info.sh -f <filepath>

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
while getopts "f:" opt; do
    case $opt in
        f) FILEPATH="$OPTARG" ;;
        *) echo "Usage: $0 -f <filepath>"; exit 1 ;;
    esac
done

# Validate input
if [ -z "$FILEPATH" ]; then
    zenity --error --text="No file specified" 2>/dev/null || echo "Error: No file specified"
    exit 1
fi

if [ -d "$FILEPATH" ]; then
    zenity --error --title="Unsupported Selection" \
        --text="Selected path is a directory:\n$(esc "$FILEPATH")\n\nGPG Info works on files only." 2>/dev/null || \
        echo "Error: Directory is not supported"
    exit 1
fi

if [ ! -f "$FILEPATH" ]; then
    zenity --error --text="File not found: $(esc "$FILEPATH")" 2>/dev/null || echo "Error: File not found"
    exit 1
fi

FILENAME="$(basename "$FILEPATH")"

# Get file information.
#
# --list-only is LOAD-BEARING and is not cosmetic. Plain `gpg --list-packets`
# on symmetrically encrypted data tries to DECRYPT it, so it blocks forever
# waiting for a passphrase that an Info action must never ask for. Measured on
# the live ISO 2026-08-26 with gnupg 2.4.7: --list-packets and
# --batch --list-packets both hit the timeout (rc=124) on a .gpg file, while
# --list-only --list-packets returned rc=0 with 2 packets immediately.
#
# The `|| GPG_EXIT=$?` is also load-bearing. `set -e` is in force above, so a
# bare `INFO=$(...)` that fails ABORTS THE SCRIPT, and the `GPG_EXIT=$?` line
# plus the whole error branch at the bottom of this file were unreachable: a
# file that is not GPG data produced total silence instead of the warning.
GPG_EXIT=0
INFO=$(timeout 15 gpg --list-only --list-packets "$FILEPATH" 2>&1) || GPG_EXIT=$?
if [ "$GPG_EXIT" -eq 124 ]; then
    INFO="gpg did not return within 15 seconds."
fi

# Get additional info if possible
FILE_SIZE=$(stat -c%s "$FILEPATH" 2>/dev/null || echo "unknown")
FILE_TYPE=$(file -b "$FILEPATH" 2>/dev/null || echo "unknown")

# Format output
OUTPUT="File: $FILENAME
Size: $FILE_SIZE bytes
Type: $FILE_TYPE

=== GPG Packet Information ===

$INFO"

# Display in text viewer
if [ $GPG_EXIT -eq 0 ]; then
    echo "$OUTPUT" | zenity --text-info \
        --title="GPG File Info: $FILENAME" \
        --width=700 --height=500 \
        --font="monospace" 2>/dev/null || \
    echo "$OUTPUT"
else
    zenity --warning --title="GPG Info" \
        --text="Could not read GPG packet information.\n\nThis may not be a valid GPG file.\n\nFile type: $(esc "$FILE_TYPE")" 2>/dev/null || \
    echo "Error: Could not read GPG info"
fi

exit 0
