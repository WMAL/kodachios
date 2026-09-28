#!/bin/bash

# Thunar Copy Path - put the full path(s) on the clipboard
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
# Copies the absolute path of the selected item(s) to the clipboard, one per
# line. Thunar's own Copy puts the FILE on the clipboard, not its path, and
# every terminal-driven operation on this distribution needs the path.
#
# Usage: thunar-copy-path.sh <path> [<path> ...]

set -u

ICON="kodachi"

[ "$#" -gt 0 ] || { echo "Usage: $0 <path> [<path> ...]" >&2; exit 1; }

# EVERY zenity --text is Pango markup, and this script interpolates the SELECTED
# PATH into one. A file named `Tom & Jerry.pdf` makes Pango raise "Entity did not
# end with a semicolon", zenity exits non-zero, 2>/dev/null eats the report, and
# the user is told nothing while the clipboard stays empty.
# BACKSLASH FIRST, then ampersand. zenity runs g_strcompress on --text BEFORE
# Pango parses it, so a backslash arriving from a filename would otherwise eat
# the character after it. Ampersand before the other entities, or it
# double-escapes what they add.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

PAYLOAD=""
COUNT=0
for p in "$@"; do
    # DO NOT RESOLVE SYMLINKS. Copy Path must copy the path of the item the user
    # right-clicked. `readlink -f` returns the TARGET, so copying the path of a
    # symlink handed back somewhere the user never selected. Make it absolute
    # without following links; `realpath -s` does exactly that, and the fallback
    # only prefixes the working directory.
    if command -v realpath >/dev/null 2>&1; then
        ABS="$(realpath -s -- "$p" 2>/dev/null || printf '%s' "$p")"
    else
        case "$p" in /*) ABS="$p" ;; *) ABS="$(pwd)/$p" ;; esac
    fi
    PAYLOAD="${PAYLOAD}${ABS}
"
    COUNT=$((COUNT + 1))
done
# Trim the single trailing newline so a one-item copy pastes inline.
PAYLOAD="${PAYLOAD%$'\n'}"

# THE WRITER'S STATUS DECIDES WHAT THE USER IS TOLD. The pipelines below ran
# under `set -u` only, so a clipboard write that failed (no X display, a dead
# clipboard manager, xclip refused) still reached "Path copied" with exit 0
# while the clipboard kept its previous contents (Desktop audit 2026-09-05,
# measured with a failing writer stub). Same shape thunar-virustotal.sh already
# had right: notify only after the write succeeded, otherwise say so and exit 1
# with the path printed so it is at least on the terminal.
copy_failed() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Copy Path" \
            --text="The clipboard write failed ($1), so nothing was copied.\n\nThe path is:\n<tt>$(esc "$PAYLOAD")</tt>" --width=560 2>/dev/null
    fi
    notify-send -i "$ICON" "Path NOT copied" "$(esc "$1") failed; the clipboard is unchanged" 2>/dev/null || true
    printf '%s\n' "$PAYLOAD"
    exit 1
}

if command -v xclip >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | xclip -selection clipboard || copy_failed xclip
elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | xsel --clipboard --input || copy_failed xsel
else
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Copy Path" \
            --text="No clipboard tool is installed.\n\nInstall xclip or xsel.\n\nThe path is:\n<tt>$(esc "$PAYLOAD")</tt>" --width=560 2>/dev/null
    fi
    printf '%s\n' "$PAYLOAD"
    exit 1
fi

if [ "$COUNT" -eq 1 ]; then
    notify-send -i "$ICON" "Path copied" "$(esc "$PAYLOAD")" 2>/dev/null || true
else
    notify-send -i "$ICON" "Paths copied" "$COUNT paths on the clipboard" 2>/dev/null || true
fi
exit 0
