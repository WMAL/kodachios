#!/bin/bash

# Thunar VirusTotal Hash Lookup - with an honest disclosure step
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
# Looks a file's SHA-256 up on VirusTotal, used by the Thunar context menu.
#
# WHY THIS SCRIPT EXISTS. The menu entry used to be, literally:
#
#     HASH=$(sha256sum %f | cut -d' ' -f1) && xdg-open "https://www.virustotal.com/gui/file/$HASH"
#       && notify-send ... "Hash: $HASH (file NOT uploaded)"
#
# Three defects on a privacy distribution, all fixed here:
#   1. It opened a browser to a Google-owned service with NO confirmation. On
#      Kodachi that browser is usually torrified, but the REQUEST still happens
#      and it still tells VirusTotal that somebody is asking about this exact
#      file. The disclosure appeared in a notification AFTER the request was
#      already in flight.
#   2. "file NOT uploaded" is true and incomplete. The HASH is uploaded, and a
#      hash of a file you hold is an identifier of that file. The wording now
#      says so before anything leaves the machine.
#   3. On a folder, sha256sum fails, the `&&` chain stops and the user sees
#      NOTHING. Folders are now named as unsupported.
#
# Usage: thunar-virustotal.sh <file>

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
FILEPATH="${1:-}"

have_zenity() { command -v zenity >/dev/null 2>&1; }

die() {
    have_zenity && { zenity --error --title="VirusTotal Lookup" --text="$1" --width=520 2>/dev/null || true; }
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[ -n "$FILEPATH" ] || die "No file was given."
[ -e "$FILEPATH" ] || die "File not found:\n$(esc "$FILEPATH")"
[ -d "$FILEPATH" ] && die "This is a folder:\n<b>$(esc "$(basename -- "$FILEPATH")")</b>\n\nVirusTotal looks up the hash of a single file. Select a file instead."
[ -f "$FILEPATH" ] || die "Not a regular file:\n$(esc "$FILEPATH")"
[ -r "$FILEPATH" ] || die "File is not readable:\n$(esc "$FILEPATH")"

NAME="$(basename -- "$FILEPATH")"
# THE FILE'S SIZE, NOT ITS ALLOCATED BLOCKS. `du -h` rounds up to the filesystem
# block, so a 14-byte file was displayed as "(4.0K)" right next to its SHA-256.
# For a dialog whose entire argument is "this hash identifies the exact file you
# hold", printing a number that is not the file's size undercuts the one claim it
# is making. Measured by <agent> on the <lab-host> live ISO.
# numfmt is coreutils and is present wherever du is, but fall back to raw bytes
# rather than to nothing if it ever is not.
SIZE_BYTES="$(stat -c %s -- "$FILEPATH" 2>/dev/null)"
if [ -n "$SIZE_BYTES" ]; then
    SIZE="$(numfmt --to=iec --suffix=B "$SIZE_BYTES" 2>/dev/null || printf '%s bytes' "$SIZE_BYTES")"
else
    SIZE="unknown size"
fi

# Hashed through stdin: a name with a backslash or a newline makes coreutils
# prefix the record with `\\`, which `cut` would hand back as a 65th character
# (Desktop audit 2026-09-05, VirusTotal Copy emitted 65 characters).
HASH="$(sha256sum < "$FILEPATH" 2>/dev/null | cut -d' ' -f1)"
[ -n "$HASH" ] || die "Could not compute the SHA-256 of:\n$(esc "$NAME")"

URL="https://www.virustotal.com/gui/file/$HASH"

# The disclosure comes BEFORE anything leaves the machine, and it offers the
# option of taking the hash without making any request at all.
if have_zenity; then
    CHOICE="$(zenity --list --radiolist --title="VirusTotal Lookup" \
        --text="<b>$(esc "$NAME")</b>  ($SIZE)\nSHA-256:\n<tt>$HASH</tt>\n\n<b>This contacts a third party.</b> The file itself is not uploaded, but the hash is, and a hash identifies the exact file you hold. VirusTotal is owned by Google and logs the lookup with your connection details.\n\nWhat would you like to do?" \
        --column="" --column="Action" --column="What happens" \
        TRUE  "copy"   "Copy the hash to the clipboard, contact nobody (recommended)" \
        FALSE "lookup" "Open VirusTotal in the browser and send the hash" \
        --width=680 --height=300 2>/dev/null)" || exit 0
    [ -n "$CHOICE" ] || exit 0
else
    # No dialog means no informed consent, so no network request.
    printf '%s  %s\n' "$HASH" "$NAME"
    exit 0
fi

if [ "$CHOICE" = "copy" ]; then
    COPIED=no
    if command -v xclip >/dev/null 2>&1; then
        printf '%s' "$HASH" | xclip -selection clipboard 2>/dev/null && COPIED=yes
    elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$HASH" | xsel --clipboard --input 2>/dev/null && COPIED=yes
    fi
    if [ "$COPIED" = yes ]; then
        notify-send -i "$ICON" "SHA-256 copied" "$(esc "$NAME") (nothing was sent)" 2>/dev/null || true
    else
        zenity --info --title="SHA-256" \
            --text="No clipboard tool is installed, so here is the hash:\n<tt>$HASH</tt>\n\nNothing was sent." --width=560 2>/dev/null || true
    fi
    exit 0
fi

command -v xdg-open >/dev/null 2>&1 || die "xdg-open is not available, cannot open the browser.\n\nThe hash is:\n$HASH"
if xdg-open "$URL" >/dev/null 2>&1; then
    notify-send -i "$ICON" "VirusTotal" "Hash sent for $(esc "$NAME"). The file itself was not uploaded." 2>/dev/null || true
else
    die "Could not open the browser.\n\nThe URL is:\n$(esc "$URL")"
fi

exit 0
