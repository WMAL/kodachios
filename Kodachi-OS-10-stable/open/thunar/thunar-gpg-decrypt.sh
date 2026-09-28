#!/bin/bash

# Thunar GPG Decrypt - Decrypt GPG encrypted files
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
# Decrypts GPG encrypted files from Thunar file manager context menu.
#
# Usage: thunar-gpg-decrypt.sh -f <filepath>

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
        --text="Selected path is a directory:\n$(esc "$FILEPATH")\n\nGPG Decrypt works on files only." 2>/dev/null || \
        echo "Error: Directory is not supported"
    exit 1
fi

if [ ! -f "$FILEPATH" ]; then
    zenity --error --text="File not found: $(esc "$FILEPATH")" 2>/dev/null || echo "Error: File not found"
    exit 1
fi

# Icon - use system icon name
ICON="kodachi"

FILENAME="$(basename "$FILEPATH")"

# Determine output filename
if [[ "$FILEPATH" == *.gpg ]]; then
    OUTPUT="${FILEPATH%.gpg}"
elif [[ "$FILEPATH" == *.asc ]]; then
    OUTPUT="${FILEPATH%.asc}"
elif [[ "$FILEPATH" == *.pgp ]]; then
    OUTPUT="${FILEPATH%.pgp}"
else
    OUTPUT="${FILEPATH}.decrypted"
fi

# Check if output already exists
if [ -f "$OUTPUT" ]; then
    zenity --question --title="File Exists" \
        --text="Decrypted file already exists:\n$(esc "$(basename "$OUTPUT")")\n\nOverwrite?" || exit 0
fi

# Get passphrase
PASS=$(zenity --password --title="GPG Decryption" \
    --text="Enter passphrase to decrypt:\n$(esc "$FILENAME")" 2>/dev/null)

if [ -z "$PASS" ]; then
    exit 0  # User cancelled
fi

# Perform decryption
ERROR_OUTPUT=$(mktemp)
if echo "$PASS" | gpg --batch --yes --passphrase-fd 0 \
    -o "$OUTPUT" -d "$FILEPATH" 2>"$ERROR_OUTPUT"; then

    rm -f "$ERROR_OUTPUT"
    notify-send -i "$ICON" "GPG Decrypt" "File decrypted successfully:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true

    # Ask if user wants to delete encrypted file
    if zenity --question --title="Delete Encrypted File?" \
        --text="Decryption successful!\n\nDelete the encrypted file?\n$(esc "$FILENAME")" 2>/dev/null; then
        rm -f "$FILEPATH"
        notify-send -i "$ICON" "GPG Decrypt" "Encrypted file deleted" 2>/dev/null || true
    fi
else
    ERROR=$(cat "$ERROR_OUTPUT")
    rm -f "$ERROR_OUTPUT"
    rm -f "$OUTPUT" 2>/dev/null || true  # Remove partial output

    if echo "$ERROR" | grep -q "Bad session key\|decryption failed"; then
        zenity --error --text="Decryption failed!\n\nWrong passphrase." 2>/dev/null
    else
        zenity --error --text="Decryption failed!\n\n$(esc "$ERROR")" 2>/dev/null
    fi
    exit 1
fi

exit 0
