#!/bin/bash

# Thunar Verify Checksum - compare a file against a published hash
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
# The missing half of the checksum menu. Kodachi could COMPUTE md5, sha256 and
# sha512, but there was no way to CHECK a downloaded file against the hash a
# project publishes, which is the operation a privacy user actually performs.
#
# The algorithm is inferred from the length of the expected hash, so the user
# pastes what the website gave them and nothing else. Leading and trailing
# whitespace and an optional "  filename" suffix are tolerated, because that is
# what a copied line from a SHA256SUMS file looks like.
#
# Usage: thunar-verify-checksum.sh <file>

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
    have_zenity && { zenity --error --title="Verify Checksum" --text="$1" --width=520 2>/dev/null || true; }
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[ -n "$FILEPATH" ] || die "No file was given."
[ -e "$FILEPATH" ] || die "File not found:\n$(esc "$FILEPATH")"
[ -d "$FILEPATH" ] && die "This is a folder:\n<b>$(esc "$(basename -- "$FILEPATH")")</b>\n\nA checksum verifies a single file."
[ -r "$FILEPATH" ] || die "File is not readable:\n$(esc "$FILEPATH")"

NAME="$(basename -- "$FILEPATH")"
have_zenity || die "zenity is required to ask for the expected checksum."

EXPECTED="$(zenity --entry --title="Verify Checksum" \
    --text="Paste the checksum published for:\n<b>$(esc "$NAME")</b>\n\nmd5, sha1, sha256 or sha512. The algorithm is detected from its length." \
    --width=620 2>/dev/null)" || exit 0
[ -n "$EXPECTED" ] || exit 0

# Tolerate a pasted checksum LINE in either GNU form, and surrounding
# whitespace. ORDER IS LOAD-BEARING: take the first whitespace-delimited field
# FIRST. Stripping all whitespace before cutting at `*` glued the plain form
# `<hash>  <filename>` into `<hash><filename>`, which then died on the length
# check, so only the binary form `<hash> *<filename>` ever worked.
EXPECTED="$(printf '%s' "$EXPECTED" | tr -d '\r' | awk 'NF {print $1; exit}')"
EXPECTED="${EXPECTED%%\**}"
EXPECTED="$(printf '%s' "$EXPECTED" | tr -d '[:space:]' | tr 'A-F' 'a-f')"

case "${#EXPECTED}" in
    32)  ALG="md5";    CMD="md5sum" ;;
    40)  ALG="sha1";   CMD="sha1sum" ;;
    64)  ALG="sha256"; CMD="sha256sum" ;;
    128) ALG="sha512"; CMD="sha512sum" ;;
    *)   die "That is ${#EXPECTED} characters, which is not a checksum length.\n\nExpected 32 (md5), 40 (sha1), 64 (sha256) or 128 (sha512).\n\nGot:\n<tt>$(esc "$EXPECTED")</tt>" ;;
esac

case "$EXPECTED" in
    *[!0-9a-f]*) die "The value contains characters that are not hexadecimal:\n<tt>$(esc "$EXPECTED")</tt>" ;;
esac

# THE DIGEST IS TAKEN FROM STDIN, NOT FROM THE NAMED FILE. On a name carrying a
# backslash or a newline GNU coreutils prints the record with a leading `\\`
# (escape marker), so `cut -d' ' -f1` handed back `\\<hash>`, one character too
# long, and an unchanged file was reported MISMATCH under every algorithm
# (Desktop audit 2026-09-05: 8 of 8 such names, 4 of 4 plain names correct).
# Hashing the bytes through stdin prints `<hash>  -` whatever the name is.
ACTUAL="$("$CMD" < "$FILEPATH" 2>/dev/null | cut -d' ' -f1)"
[ -n "$ACTUAL" ] || die "Could not compute the $ALG of:\n$(esc "$NAME")"

if [ "$ACTUAL" = "$EXPECTED" ]; then
    notify-send -i "$ICON" "Checksum MATCH" "$(esc "$NAME") verified ($ALG)" 2>/dev/null || true
    zenity --info --title="Checksum MATCH" \
        --text="<b>MATCH.</b> The file is byte-identical to the one the checksum was published for.\n\nFile:      <b>$(esc "$NAME")</b>\nAlgorithm: $ALG\n<tt>$ACTUAL</tt>" \
        --width=620 2>/dev/null || true
    exit 0
else
    notify-send -i "$ICON" "Checksum MISMATCH" "$(esc "$NAME") does NOT match ($ALG)" 2>/dev/null || true
    zenity --error --title="Checksum MISMATCH" \
        --text="<b>MISMATCH. Do not trust this file.</b>\n\nFile:      <b>$(esc "$NAME")</b>\nAlgorithm: $ALG\n\nExpected:\n<tt>$(esc "$EXPECTED")</tt>\n\nActual:\n<tt>$ACTUAL</tt>\n\nThe download is corrupt, incomplete, or has been tampered with." \
        --width=640 2>/dev/null || true
    exit 1
fi
