#!/bin/bash

# Thunar GPG Sign - Create detached GPG signatures
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
# Creates detached GPG signatures for files from Thunar
# file manager context menu.
#
# Usage: thunar-gpg-sign.sh -f <filepath>

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
SIGN_TARGET="$FILEPATH"
OUTPUT="${FILEPATH}.sig"

if [ -d "$FILEPATH" ]; then
    INPUT_KIND="directory"
    PARENT_DIR="$(dirname "$FILEPATH")"
    BASE_DIR="$(basename "$FILEPATH")"
    SIGN_TARGET="${PARENT_DIR}/${BASE_DIR}.tar"
    OUTPUT="${SIGN_TARGET}.sig"
fi

# Check if user has GPG secret keys
# `grep -c` PRINTS "0" and EXITS 1 when nothing matches. The original
# `|| echo "0"` therefore appended a SECOND zero and made KEY_COUNT the two-line
# string "0\n0", so both integer guards below died with "integer expression
# expected" and FAILED OPEN: the "No GPG Keys" dialog the user needs was never
# shown and the multi-key chooser never appeared. Measured on the <lab-host> live ISO
# by <agent> and reproduced under bash 5.2.37.
#
# IT MUST BE `|| true`, NOT NOTHING. `set -e` is in force at the top of this file,
# so a bare `grep -c` makes the assignment itself fail on a no-match and the script
# EXITS SILENTLY right here, with no dialog at all, which is worse than the bug
# being fixed. Measured on <lab-host>: rc=1, zero bytes written by zenity.
# `|| true` keeps grep's own "0" on stdout, drops the spurious second value, and
# neutralises the exit status.
KEY_COUNT=$(gpg --list-secret-keys 2>/dev/null | grep -c "^sec" || true)

if [ "$KEY_COUNT" -eq 0 ]; then
    zenity --error --title="No GPG Keys" \
        --text="No GPG secret keys found!\n\nYou need to generate a GPG key first.\n\nRun: gpg --gen-key" 2>/dev/null
    exit 1
fi

# If multiple keys, let user choose
if [ "$KEY_COUNT" -gt 1 ]; then
    # Get list of keys
    KEYS=$(gpg --list-secret-keys --keyid-format SHORT 2>/dev/null | \
        grep -E "^sec|^uid" | \
        paste - - | \
        sed 's/sec.*\/\([A-F0-9]*\).*/\1/' | \
        sed 's/.*\] //' | \
        awk '{print $1 " " $0}')

    SELECTED_KEY=$(zenity --list --title="Select GPG Key" \
        --text="Multiple keys found. Select key to sign with:" \
        --column="Key ID" --column="Details" \
        $KEYS 2>/dev/null)

    if [ -z "$SELECTED_KEY" ]; then
        exit 0  # User cancelled
    fi
    KEY_OPTION="-u $SELECTED_KEY"
else
    KEY_OPTION=""
fi

# Prepare folder archive when signing directories
if [ "$INPUT_KIND" = "directory" ]; then
    if [ -f "$SIGN_TARGET" ]; then
        zenity --question --title="Archive Exists" \
            --text="Archive already exists:\n$(esc "$(basename "$SIGN_TARGET")")\n\nOverwrite with current folder contents?" || exit 0
    fi

    # Remember whether the archive was ours to clean up. If the user already had
    # one and chose to overwrite it, it is THEIRS and we must not delete it on a
    # later failure; if we created it, a failed signature must not leave a mystery
    # .tar sitting in the folder the user right-clicked. Same residue class as the
    # `.cleaned` files f77fceced fixed in thunar-metadata.sh.
    ARCHIVE_PREEXISTED=0
    [ -f "$SIGN_TARGET" ] && ARCHIVE_PREEXISTED=1
    ARCHIVE_CREATED=0
    ARCHIVE_ERROR="$(mktemp)"
    if ! tar -C "$PARENT_DIR" -cf "$SIGN_TARGET" "$BASE_DIR" 2>"$ARCHIVE_ERROR"; then
        ERROR="$(cat "$ARCHIVE_ERROR" 2>/dev/null)"
        rm -f "$ARCHIVE_ERROR"
        zenity --error --text="Failed to create archive for signing!\n\n$(esc "$ERROR")" 2>/dev/null || echo "Error: Archive creation failed"
        # A half-written tar from a failed run is residue too. An `if` rather than an
        # && chain: `set -e` is in force and a chain whose first test is false
        # returns non-zero.
        if [ "$ARCHIVE_PREEXISTED" -eq 0 ] && [ -f "$SIGN_TARGET" ]; then
            rm -f -- "$SIGN_TARGET"
        fi
        exit 1
    fi
    ARCHIVE_CREATED=1
    rm -f "$ARCHIVE_ERROR"
fi

# Check if signature already exists
if [ -f "$OUTPUT" ]; then
    zenity --question --title="Signature Exists" \
        --text="Signature file already exists:\n$(esc "$(basename "$OUTPUT")")\n\nOverwrite?" || exit 0
fi

# Perform signing
ERROR_OUTPUT=$(mktemp)
if gpg $KEY_OPTION --detach-sign -o "$OUTPUT" "$SIGN_TARGET" 2>"$ERROR_OUTPUT"; then
    rm -f "$ERROR_OUTPUT"
    notify-send -i "$ICON" "GPG Sign" "Signature created:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true

    if [ "$INPUT_KIND" = "directory" ]; then
        zenity --info --title="GPG Sign" \
            --text="Folder signature created successfully!\n\nFolder: $(esc "$FILENAME")\nArchive: $(esc "$(basename "$SIGN_TARGET")")\nSignature: $(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
    else
        zenity --info --title="GPG Sign" \
            --text="Signature created successfully!\n\nFile: $(esc "$FILENAME")\nSignature: $(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
    fi
else
    ERROR=$(cat "$ERROR_OUTPUT")
    rm -f "$ERROR_OUTPUT"
    zenity --error --text="Signing failed!\n\n$(esc "$ERROR")" 2>/dev/null
    # MEASURED on the <lab-host> live ISO: a Sign on a folder left `<folder>.tar` in the
    # user's directory with no signature, no message and no cleanup, because the
    # archive is built before gpg runs. Only remove what THIS run created.
    if [ "${ARCHIVE_CREATED:-0}" -eq 1 ] && [ "${ARCHIVE_PREEXISTED:-0}" -eq 0 ] && [ -f "$SIGN_TARGET" ]; then
        rm -f -- "$SIGN_TARGET"
    fi
    exit 1
fi

exit 0
