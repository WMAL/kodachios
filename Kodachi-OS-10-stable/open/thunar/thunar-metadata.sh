#!/bin/bash

# Thunar Metadata Removal - confirmed, non-destructive by default
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
# Last updated: 2026-08-26
#
# Description:
# Front end for exiftool and mat2, used by the Thunar context menu.
#
# WHY THIS SCRIPT EXISTS. The three menu entries used to be, literally:
#
#     exiftool -all= -overwrite_original %F && notify-send ... "Metadata Removed"
#     exiftool -all:all= -overwrite_original %F && notify-send ... "PDF Sanitized"
#     mat2 --inplace %F && notify-send ... "MAT2 Complete"
#
# Three defects, all fixed here:
#   1. -overwrite_original and --inplace DESTROY the original irreversibly,
#      with no confirmation, and the notification claims success. This script
#      defaults to writing a CLEANED COPY and leaving the original alone.
#   2. The `&&` meant the notification only appeared on success, and on FAILURE
#      the user saw NOTHING at all: silent no-op. Every outcome is now reported.
#   3. The tools were assumed present. A missing exiftool or mat2 produced the
#      same silence. It is now a named error.
#
# Usage: thunar-metadata.sh -m exif|pdf|mat2 <file> [<file> ...]

set -u

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

ICON="kodachi"
MODE="exif"

while getopts "m:" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        *) echo "Usage: $0 -m exif|pdf|mat2 <file> [<file> ...]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

have_zenity() { command -v zenity >/dev/null 2>&1; }

die() {
    have_zenity && { zenity --error --title="Kodachi Metadata" --text="$1" --width=520 2>/dev/null || true; }
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[ "$#" -gt 0 ] || die "No file was given."

case "$MODE" in
    exif|pdf)
        TOOL="exiftool"
        command -v exiftool >/dev/null 2>&1 || die "exiftool is not installed.\n\nInstall the libimage-exiftool-perl package."
        ;;
    mat2)
        TOOL="mat2"
        command -v mat2 >/dev/null 2>&1 || die "mat2 is not installed.\n\nInstall the mat2 package."
        ;;
    # MODE IS $OPTARG, NOT A CLOSED SET. It reaches here only when it matched
    # none of the arms above, i.e. exactly when it is an arbitrary caller-chosen
    # string, so this is the one site in this file where MODE is attacker-shaped.
    # `-m '<b>x'` would otherwise put unbalanced markup into a Pango dialog and
    # GTK would drop the label body, which loses the error report itself.
    *) die "Unknown mode: $(esc "$MODE")" ;;
esac

# Directories are not metadata targets. Say so rather than failing obscurely.
FILES=()
SKIPPED=""
for p in "$@"; do
    if [ -d "$p" ]; then
        SKIPPED="$SKIPPED\n  $(esc "$(basename -- "$p")")  (folder, skipped)"
    elif [ -f "$p" ]; then
        FILES+=("$p")
    else
        SKIPPED="$SKIPPED\n  $(esc "$p")  (not found, skipped)"
    fi
done
[ "${#FILES[@]}" -gt 0 ] || die "No regular file to process.$SKIPPED"

LIST=""
for p in "${FILES[@]}"; do LIST="$LIST
  $(esc "$(basename -- "$p")")"; done

# The choice, with the SAFE option first and selected by default.
if have_zenity; then
    CHOICE="$(zenity --list --radiolist --title="Remove Metadata" \
        --text="Strip metadata from ${#FILES[@]} file(s) using <b>$TOOL</b>:\n<tt>$LIST</tt>$SKIPPED\n\nHow should the result be written?" \
        --column="" --column="Mode" --column="What happens" \
        TRUE  "copy"    "Write a cleaned COPY, keep the original untouched (recommended)" \
        FALSE "inplace" "Overwrite the original IRREVERSIBLY, no undo" \
        --width=640 --height=280 2>/dev/null)" || exit 0
    [ -n "$CHOICE" ] || exit 0
else
    # No dialog means no consent for the destructive path.
    CHOICE="copy"
fi

if [ "$CHOICE" = "inplace" ]; then
    have_zenity || die "Refusing an in-place strip without a confirmation dialog."
    zenity --question --title="Overwrite originals?" \
        --text="<b>This cannot be undone.</b> The original file(s) are replaced:\n<tt>$LIST</tt>\n\nContinue?" \
        --ok-label="Overwrite" --cancel-label="Cancel" --width=520 2>/dev/null || exit 0
fi

OK=0
FAILED=0
REPORT=""

for f in "${FILES[@]}"; do
    NAME="$(basename -- "$f")"
    ERR="$(mktemp)"
    # Per file, never once: `set -u` is on and the report reads this below.
    REMOVED=0
    if [ "$CHOICE" = "inplace" ]; then
        case "$MODE" in
            exif) exiftool -all= -overwrite_original -- "$f" >/dev/null 2>"$ERR" ;;
            pdf)  exiftool -all:all= -overwrite_original -- "$f" >/dev/null 2>"$ERR" ;;
            mat2) mat2 --inplace -- "$f" >/dev/null 2>"$ERR" ;;
        esac
        RC=$?
        OUTNAME="$NAME (in place)"
    else
        DIR="$(dirname -- "$f")"
        BASE="${NAME%.*}"
        EXT="${NAME##*.}"
        [ "$EXT" = "$NAME" ] && OUT="$DIR/${BASE}.cleaned" || OUT="$DIR/${BASE}.cleaned.${EXT}"
        # Never silently clobber an existing .cleaned file.
        N=1
        while [ -e "$OUT" ]; do
            [ "$EXT" = "$NAME" ] && OUT="$DIR/${BASE}.cleaned-${N}" || OUT="$DIR/${BASE}.cleaned-${N}.${EXT}"
            N=$((N + 1))
        done
        cp -- "$f" "$OUT" 2>"$ERR"
        RC=$?
        if [ "$RC" -eq 0 ]; then
            case "$MODE" in
                exif) exiftool -all= -overwrite_original -- "$OUT" >/dev/null 2>"$ERR" ;;
                pdf)  exiftool -all:all= -overwrite_original -- "$OUT" >/dev/null 2>"$ERR" ;;
                mat2) mat2 --inplace -- "$OUT" >/dev/null 2>"$ERR" ;;
            esac
            RC=$?
            # A FAILED STRIPPER MUST NOT LEAVE A FILE NAMED `.cleaned`. The copy
            # still holds every byte of metadata, and on a privacy distribution
            # an artifact named for a scrub that did not happen is worse than no
            # artifact at all: the user shares it believing it is scrubbed. The
            # dialog already says FAILED, and the file on disk must agree.
            if [ "$RC" -ne 0 ]; then
                unlink "$OUT" 2>/dev/null && REMOVED=1
            fi
        fi
        OUTNAME="$(basename -- "$OUT")"
    fi

    if [ "$RC" -eq 0 ]; then
        OK=$((OK + 1))
        REPORT="$REPORT
  OK      $(esc "$NAME")  ->  $(esc "$OUTNAME")"
    else
        FAILED=$((FAILED + 1))
        NOTE=""
        [ "$REMOVED" -eq 1 ] && NOTE="  [the incomplete copy was removed]"
        REPORT="$REPORT
  FAILED  $(esc "$NAME")  ($(esc "$(head -c 160 "$ERR" 2>/dev/null | tr '\n' ' ')"))$NOTE"
    fi
    unlink "$ERR" 2>/dev/null || true
done

# Every outcome is reported, including total failure. The old `&&` form showed
# nothing at all when the command failed.
if [ "$FAILED" -eq 0 ]; then
    notify-send -i "$ICON" "Metadata Removed" "$OK file(s) cleaned with $TOOL" 2>/dev/null || true
    have_zenity && zenity --info --title="Metadata Removed" \
        --text="$OK file(s) cleaned with <b>$TOOL</b>:\n<tt>$REPORT</tt>$SKIPPED" --width=620 2>/dev/null || true
else
    notify-send -i "$ICON" "Metadata Removal Incomplete" "$OK cleaned, $FAILED failed" 2>/dev/null || true
    have_zenity && zenity --warning --title="Metadata Removal Incomplete" \
        --text="<b>$OK cleaned, $FAILED failed.</b>\n<tt>$REPORT</tt>$SKIPPED" --width=620 2>/dev/null || true
    exit 1
fi

exit 0
