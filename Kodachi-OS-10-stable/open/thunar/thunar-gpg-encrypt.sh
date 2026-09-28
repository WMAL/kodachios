#!/bin/bash

# Thunar GPG Encrypt - Encrypt files with GPG AES256
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
# Encrypts files using GPG symmetric encryption with AES256
# from Thunar file manager context menu.
#
# Usage: thunar-gpg-encrypt.sh -f <filepath>

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

if [ ! -e "$FILEPATH" ]; then
    zenity --error --text="File or directory not found: $(esc "$FILEPATH")" 2>/dev/null || echo "Error: Path not found"
    exit 1
fi

# Icon - use system icon name
ICON="kodachi"

FILENAME="$(basename "$FILEPATH")"
INPUT_KIND="file"
OUTPUT="${FILEPATH}.gpg"
ARCHIVE_LABEL=""

if [ -d "$FILEPATH" ]; then
    INPUT_KIND="directory"
    PARENT_DIR="$(dirname "$FILEPATH")"
    BASE_DIR="$(basename "$FILEPATH")"
    OUTPUT="${PARENT_DIR}/${BASE_DIR}.tar.gpg"
    ARCHIVE_LABEL="${BASE_DIR}.tar"
fi

# Check if output already exists
if [ -f "$OUTPUT" ]; then
    zenity --question --title="File Exists" \
        --text="Encrypted file already exists:\n$(esc "$(basename "$OUTPUT")")\n\nOverwrite?" || exit 0
fi

# Get passphrase
PASS=$(zenity --password --title="GPG Encryption" \
    --text="Enter passphrase to encrypt:\n$(esc "$FILENAME")" 2>/dev/null)

if [ -z "$PASS" ]; then
    exit 0  # User cancelled
fi

# Confirm passphrase
PASS2=$(zenity --password --title="GPG Encryption" \
    --text="Confirm passphrase:" 2>/dev/null)

if [ "$PASS" != "$PASS2" ]; then
    zenity --error --text="Passphrases do not match" 2>/dev/null
    exit 1
fi

# Check passphrase strength (optional warning)
if [ ${#PASS} -lt 8 ]; then
    zenity --warning --text="Warning: Passphrase is shorter than 8 characters.\nThis provides weak security." 2>/dev/null || true
fi

# Perform encryption
PASS_FILE="$(mktemp)"
ERROR_OUTPUT="$(mktemp)"
chmod 600 "$PASS_FILE"
printf '%s' "$PASS" > "$PASS_FILE"

if [ "$INPUT_KIND" = "directory" ]; then
    if tar -C "$PARENT_DIR" -cf - "$BASE_DIR" | \
        gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
        --symmetric --cipher-algo AES256 --compress-algo none \
        -o "$OUTPUT" 2>"$ERROR_OUTPUT"; then
        ENCRYPT_OK=1
    else
        ENCRYPT_OK=0
    fi
else
    if gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
        --symmetric --cipher-algo AES256 --compress-algo none \
        -o "$OUTPUT" "$FILEPATH" 2>"$ERROR_OUTPUT"; then
        ENCRYPT_OK=1
    else
        ENCRYPT_OK=0
    fi
fi

rm -f "$PASS_FILE"

if [ "$ENCRYPT_OK" -eq 1 ]; then
    if [ "$INPUT_KIND" = "directory" ]; then
        notify-send -i "$ICON" "GPG Encrypt" "Folder encrypted:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
        SUCCESS_TEXT="Folder encrypted successfully!\n\nFolder: $(esc "$FILENAME")\nOutput: $(esc "$(basename "$OUTPUT")")\n(Contains tar archive: $(esc "$ARCHIVE_LABEL"))"
    else
        notify-send -i "$ICON" "GPG Encrypt" "File encrypted:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
        SUCCESS_TEXT="File encrypted successfully!\n\nFile: $(esc "$FILENAME")\nOutput: $(esc "$(basename "$OUTPUT")")"
    fi

    zenity --info --title="GPG Encrypt" --text="$SUCCESS_TEXT" 2>/dev/null || true

    # Ask if user wants to delete original
    if [ "$INPUT_KIND" = "directory" ]; then
        if zenity --question --title="Delete Original Folder?" \
            --text="Encryption successful!\n\nDelete the original unencrypted folder?\n$(esc "$FILENAME")" 2>/dev/null; then
            rm -rf "$FILEPATH"
            notify-send -i "$ICON" "GPG Encrypt" "Original folder deleted" 2>/dev/null || true
        fi
    else
        if zenity --question --title="Delete Original File?" \
            --text="Encryption successful!\n\nDelete the original unencrypted file?\n$(esc "$FILENAME")" 2>/dev/null; then
            rm -f "$FILEPATH"
            notify-send -i "$ICON" "GPG Encrypt" "Original file deleted" 2>/dev/null || true
        fi
    fi
    rm -f "$ERROR_OUTPUT"
else
    ERROR="$(cat "$ERROR_OUTPUT" 2>/dev/null)"
    rm -f "$ERROR_OUTPUT"
    zenity --error --text="Encryption failed!\n\n$(esc "$ERROR")" 2>/dev/null || echo "Error: Encryption failed"
    exit 1
fi

exit 0
