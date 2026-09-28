#!/bin/bash

# Thunar GPG Verify - Verify GPG signatures
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
# Verifies GPG signatures (detached .sig files or signed files)
# from Thunar file manager context menu.
#
# Usage: thunar-gpg-verify.sh -f <filepath>

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
        --text="Selected path is a directory:\n$(esc "$FILEPATH")\n\nGPG Verify works on files only." 2>/dev/null || \
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

# Determine if this is a signature file or data file
if [[ "$FILEPATH" == *.sig ]] || [[ "$FILEPATH" == *.sign ]] || [[ "$FILEPATH" == *.asc ]]; then
    SIGFILE="$FILEPATH"
    # Try to find the data file. `.sign` is here because the menu now offers
    # this action on it; without this branch a `.sign` fell through to the
    # data-file path and hunted for `<name>.sign.sig`, which never exists.
    # `.sign` is tested BEFORE `.sig`, or the shorter suffix strips first and
    # leaves a stray "n".
    if [[ "$FILEPATH" == *.sign ]]; then
        DATAFILE="${FILEPATH%.sign}"
    elif [[ "$FILEPATH" == *.sig ]]; then
        DATAFILE="${FILEPATH%.sig}"
    else
        DATAFILE="${FILEPATH%.asc}"
    fi

    if [ ! -f "$DATAFILE" ]; then
        # Ask user to select the data file
        DATAFILE=$(zenity --file-selection --title="Select the signed file" \
            --text="Select the file that was signed:" 2>/dev/null)
        if [ -z "$DATAFILE" ]; then
            exit 0
        fi
    fi
else
    # This is the data file, look for signature
    DATAFILE="$FILEPATH"

    # Check for common signature extensions
    if [ -f "${FILEPATH}.sig" ]; then
        SIGFILE="${FILEPATH}.sig"
    elif [ -f "${FILEPATH}.asc" ]; then
        SIGFILE="${FILEPATH}.asc"
    else
        # Ask user to select signature file
        SIGFILE=$(zenity --file-selection --title="Select signature file" \
            --text="Select the signature file (.sig or .asc):" \
            --file-filter="Signatures|*.sig *.sign *.asc" 2>/dev/null)
        if [ -z "$SIGFILE" ]; then
            exit 0
        fi
    fi
fi

# Verify the signature
RESULT_FILE=$(mktemp)
if gpg --verify "$SIGFILE" "$DATAFILE" 2>"$RESULT_FILE"; then
    RESULT=$(cat "$RESULT_FILE")
    rm -f "$RESULT_FILE"

    notify-send -i "$ICON" "GPG Verify" "GOOD SIGNATURE ✓" 2>/dev/null || true

    zenity --info --title="GPG Signature Verification" \
        --text="✓ GOOD SIGNATURE\n\nFile: $(esc "$(basename "$DATAFILE")")\nSignature: $(esc "$FILENAME")\n\n$(esc "$RESULT")" \
        --width=500 2>/dev/null || true
else
    RESULT=$(cat "$RESULT_FILE")
    rm -f "$RESULT_FILE"

    notify-send -i "$ICON" "GPG Verify" "BAD SIGNATURE ✗" 2>/dev/null || true

    zenity --warning --title="GPG Signature Verification" \
        --text="✗ BAD SIGNATURE or verification failed\n\nFile: $(esc "$(basename "$DATAFILE")")\nSignature: $(esc "$FILENAME")\n\n$(esc "$RESULT")" \
        --width=500 2>/dev/null || true
    exit 1
fi

exit 0
