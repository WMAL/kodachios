#!/bin/bash

# Thunar OpenSSL - Encrypt/decrypt files with AES-256-CBC
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
# Encrypts/decrypts files using OpenSSL AES-256-CBC.
# Auto-detects mode based on .enc extension.
#
# Usage: thunar-openssl.sh -f <filepath>

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
IS_DIRECTORY=0
if [ -d "$FILEPATH" ]; then
    IS_DIRECTORY=1
fi

# Auto-detect mode based on extension
if [[ "$FILEPATH" == *.enc ]]; then
    MODE="decrypt"
    OUTPUT="${FILEPATH%.enc}"
else
    # Let user choose mode (directory supports encryption only)
    if [ "$IS_DIRECTORY" -eq 1 ]; then
        MODE="encrypt"
    else
        MODE=$(zenity --list --title="OpenSSL Encryption" \
            --text="Select operation for:\n$(esc "$FILENAME")" \
            --column="Action" --column="Description" \
            "Encrypt" "Encrypt file with AES-256" \
            "Decrypt" "Decrypt encrypted file" \
            --width=350 --height=200 2>/dev/null)

        if [ -z "$MODE" ]; then
            exit 0  # User cancelled
        fi

        MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "$MODE" = "encrypt" ]; then
        if [ "$IS_DIRECTORY" -eq 1 ]; then
            OUTPUT="${FILEPATH}.tar.enc"
        else
            OUTPUT="${FILEPATH}.enc"
        fi
    else
        if [ "$IS_DIRECTORY" -eq 1 ]; then
            zenity --error --text="Decrypt is not supported directly on folders.\nSelect an encrypted .enc file instead." 2>/dev/null || \
                echo "Error: Cannot decrypt a directory path"
            exit 1
        fi
        OUTPUT="${FILEPATH}.decrypted"
    fi
fi

# Check if output already exists
if [ -f "$OUTPUT" ]; then
    zenity --question --title="File Exists" \
        --text="Output file already exists:\n$(esc "$(basename "$OUTPUT")")\n\nOverwrite?" || exit 0
fi

# Get passphrase
# `|| PASS=""` is load-bearing: `set -e` is in force, and a cancelled zenity
# exits 1, so a bare assignment would abort here and the cancel branch below
# would never run.
# MODE IS ESCAPED HERE, AND THIS IS THE THIRD BINDING OF THAT NAME IN THIS LANE.
# `thunar-openssl.sh` has no `-m` flag: `getopts "f:"` is the whole option set. MODE
# is bound three ways in THIS file, at :72 and :77 from string literals and at :79
# from `zenity --list` output, lowercased at :90, with no `*)` validation arm
# anywhere. So the closed-set argument that holds for the literals does NOT come
# from this file's own code for the third one, it comes from trusting what zenity
# hands back.
#
# `--title=` IS NOT PANGO AND `--text=` IS, which is why `${MODE^}` on the line
# below is left alone while this one is escaped. That asymmetry looks like an
# oversight and is the actual contract.
#
# THE CLASS HISTORY, because it is the reason this comment exists. I proved MODE
# was a closed set in this file, put the NAME on a safe list, and shipped the
# defect in two other scripts that bind it from $OPTARG. I then fixed those two
# and shipped it a third time HERE, in the file where I had originally done the
# proving, because that pass keyed on `$OPTARG` rather than on "reaches Pango".
# Found by <agent>'s independent paren-balanced census with a taint trace,
# after two of my own detectors had declared the class closed. A safe-list entry is
# (file, line, binding), and clearing a class needs a census of the SINK, not of
# the producing idiom you happened to fix last.
PASS=$(zenity --password --title="OpenSSL ${MODE^}" \
    --text="Enter passphrase to $(esc "$MODE"):\n$(esc "$FILENAME")" 2>/dev/null) || PASS=""

if [ -z "$PASS" ]; then
    exit 0  # User cancelled
fi

# For encryption, confirm passphrase
if [ "$MODE" = "encrypt" ]; then
    PASS2=$(zenity --password --title="OpenSSL Encrypt" \
        --text="Confirm passphrase:" 2>/dev/null) || PASS2=""

    if [ "$PASS" != "$PASS2" ]; then
        zenity --error --text="Passphrases do not match" 2>/dev/null
        exit 1
    fi

    # Passphrase strength warning
    if [ ${#PASS} -lt 8 ]; then
        zenity --warning --text="Warning: Passphrase is shorter than 8 characters.\nThis provides weak security." 2>/dev/null || true
    fi
fi

# Perform operation
ERROR_OUTPUT=$(mktemp)

# The passphrase goes through a 0600 file, never through argv.
#
# `-pass pass:<secret>` places the passphrase in this process's command line,
# which every local process can read from /proc/<pid>/cmdline. Measured on the
# live ISO 2026-08-26 against a 250 MB input, with a positive control proving
# the ps probe was not blind: the openssl passphrase was FOUND in `ps -eo args`
# while the passphrase of thunar-gpg-encrypt.sh, which already uses a 0600
# --passphrase-file, was absent in the same window. This matches that script.
PASS_FILE=$(mktemp)
chmod 600 "$PASS_FILE"
printf '%s' "$PASS" > "$PASS_FILE"
cleanup_pass_file() {
    [ -n "${PASS_FILE:-}" ] || return 0
    shred -u "$PASS_FILE" 2>/dev/null || unlink "$PASS_FILE" 2>/dev/null || true
    PASS_FILE=""
}
trap cleanup_pass_file EXIT INT TERM

if [ "$MODE" = "encrypt" ]; then
    if [ "$IS_DIRECTORY" -eq 1 ]; then
        PARENT_DIR="$(dirname "$FILEPATH")"
        BASE_DIR="$(basename "$FILEPATH")"
        if tar -C "$PARENT_DIR" -cf - "$BASE_DIR" | \
            openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -out "$OUTPUT" -pass file:"$PASS_FILE" 2>"$ERROR_OUTPUT"; then
            ENCRYPT_OK=1
        else
            ENCRYPT_OK=0
        fi
    else
        if openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
            -in "$FILEPATH" -out "$OUTPUT" -pass file:"$PASS_FILE" 2>"$ERROR_OUTPUT"; then
            ENCRYPT_OK=1
        else
            ENCRYPT_OK=0
        fi
    fi

    if [ "$ENCRYPT_OK" -eq 1 ]; then
        rm -f "$ERROR_OUTPUT"
        if [ "$IS_DIRECTORY" -eq 1 ]; then
            notify-send -i "$ICON" "OpenSSL Encrypt" "Folder encrypted:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
        else
            notify-send -i "$ICON" "OpenSSL Encrypt" "File encrypted:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true
        fi

        # Ask if user wants to delete original
        if [ "$IS_DIRECTORY" -eq 1 ]; then
            if zenity --question --title="Delete Original Folder?" \
                --text="Encryption successful!\n\nDelete the original unencrypted folder?\n$(esc "$FILENAME")" 2>/dev/null; then
                rm -rf "$FILEPATH"
                notify-send -i "$ICON" "OpenSSL Encrypt" "Original folder deleted" 2>/dev/null || true
            fi
        else
            if zenity --question --title="Delete Original File?" \
                --text="Encryption successful!\n\nDelete the original unencrypted file?\n$(esc "$FILENAME")" 2>/dev/null; then
                rm -f "$FILEPATH"
                notify-send -i "$ICON" "OpenSSL Encrypt" "Original file deleted" 2>/dev/null || true
            fi
        fi
    else
        ERROR=$(cat "$ERROR_OUTPUT")
        rm -f "$ERROR_OUTPUT"
        zenity --error --text="Encryption failed!\n\n$(esc "$ERROR")" 2>/dev/null
        exit 1
    fi
else
    # Decrypt
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$FILEPATH" -out "$OUTPUT" -pass file:"$PASS_FILE" 2>"$ERROR_OUTPUT"; then

        rm -f "$ERROR_OUTPUT"
        notify-send -i "$ICON" "OpenSSL Decrypt" "File decrypted:\n$(esc "$(basename "$OUTPUT")")" 2>/dev/null || true

        # Ask if user wants to delete encrypted file
        if zenity --question --title="Delete Encrypted File?" \
            --text="Decryption successful!\n\nDelete the encrypted file?\n$(esc "$FILENAME")" 2>/dev/null; then
            rm -f "$FILEPATH"
            notify-send -i "$ICON" "OpenSSL Decrypt" "Encrypted file deleted" 2>/dev/null || true
        fi
    else
        ERROR=$(cat "$ERROR_OUTPUT")
        rm -f "$ERROR_OUTPUT"
        rm -f "$OUTPUT" 2>/dev/null || true  # Remove partial output

        if echo "$ERROR" | grep -qi "bad decrypt\|wrong"; then
            zenity --error --text="Decryption failed!\n\nWrong passphrase or corrupted file." 2>/dev/null
        else
            zenity --error --text="Decryption failed!\n\n$(esc "$ERROR")" 2>/dev/null
        fi
        exit 1
    fi
fi

exit 0
