#!/bin/bash

# Thunar Read-Only Viewers - hash, hex, entropy, metadata, file type
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
# Version: <lab-host>
# Last updated: 2026-09-07
#
# Description:
# Front end for b2sum, xxd, ent, exiftool and file, used by the Thunar context
# menu. Runs the tool and renders its output in a zenity text window.
#
# WHY THIS SCRIPT EXISTS. The five menu entries used to be, literally:
#
#     b2sum %f    | zenity --text-info --title="BLAKE2 Checksum" ...
#     xxd %f      | head -200 | zenity --text-info --title="Hex View ..." ...
#     ent %f      | zenity --text-info --title="Entropy Analysis: %n" ...
#     exiftool %f | zenity --text-info --title="Metadata: %n" ...
#     file %F     | zenity --text-info --title="File Type Analysis" ...
#
# NOT ONE OF THEM COULD EVER WORK, and all five failed in SILENCE. thunar-uca
# does not run <command> through a shell: it parses the template with
# g_shell_parse_argv() and spawns the resulting argv through
# xfce_spawn_on_screen_with_child_watch(), so `|` is an ORDINARY WORD, not a
# pipe. Measured 2026-09-07, GLib.shell_parse_argv on the shipped strings:
# entry 13 parses to 8 argv elements with a literal '|' at index 2, entry 25 to
# 12 with literals at [2, 5], entries 26/27/28 to 8 with one at [2]. A
# non-piped sibling (action 10) parses to a clean 5 with no '|', so the
# instrument was reading correctly. The tool therefore received `|`, `zenity`
# and every switch as FILENAMES:
#
#     b2sum: unrecognized option '--text-info'
#     file:  unrecognized option '--text-info'
#     ent:   invalid option -- '-'      and it EXITS 0 while doing nothing,
#                                       so no exit-code gate could catch it
#
# thunar-uca discards the child's stderr, so the user clicked the entry and got
# absolute silence: `pgrep -a zenity` and an xdotool title search both returned
# nothing after all five. Proven on hardware by <agent> on the <lab-host>
# live ISO (<lab-host>) and confirmed independently on the dev host.
#
# This is the same failure class 8e1358e87 fixed for "Print file/s" and
# thunar-metadata.sh fixed for the three metadata strippers: a menu entry that
# cannot work and cannot tell you so. Everything here reports every outcome,
# including a missing tool, which used to produce the same silence.
#
# Usage: thunar-view.sh -m blake2|hex|entropy|metadata|filetype <file> [<file> ...]

set -u

# EVERY zenity --info/--error/--warning/--question TEXT IS PANGO MARKUP, so any
# filename, command output or path interpolated into one is attacker-chosen data
# inside the wording of a dialog. An ordinary name like `Tom & Jerry.pdf` is
# enough: Pango raises "Entity did not end with a semicolon" and the dialog fails
# to render, in a menu where thunar-uca already discards the child's stderr, so
# the failure report is exactly what disappears. esc() is applied to the VARIABLE
# and never to the whole message, because the surrounding literals carry
# intentional <b> and <tt> markup that must survive.
#
# NOTE the deliberate asymmetry with the report BODY below: `--text-info` renders
# its file as PLAIN TEXT in a GtkTextView, not as markup, so tool output must NOT
# be escaped there or every `<` in an exiftool tag or an xxd dump would show up as
# `&lt;`. Escape what goes into a --error/--question, never what goes into
# --text-info.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

MODE="blake2"

while getopts "m:" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        *) echo "Usage: $0 -m blake2|hex|entropy|metadata|filetype <file> [<file> ...]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

have_zenity() { command -v zenity >/dev/null 2>&1; }

die() {
    have_zenity && { zenity --error --title="Kodachi File Viewer" --text="$1" --width=520 2>/dev/null || true; }
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[ "$#" -gt 0 ] || die "No file was given."

# Per-mode tool, window geometry and title. HEX_LIMIT preserves the `head -200`
# the original pipeline intended, which is why the title says so.
HEX_LIMIT=200
case "$MODE" in
    blake2)   TOOL="b2sum";    PKG="coreutils";              W=600; H=200; FONT=""; TITLE="BLAKE2 Checksum" ;;
    hex)      TOOL="xxd";      PKG="xxd";                    W=750; H=500; FONT="monospace 9"; TITLE="Hex View (first $HEX_LIMIT lines only)" ;;
    entropy)  TOOL="ent";      PKG="ent";                    W=500; H=350; FONT=""; TITLE="Entropy Analysis" ;;
    metadata) TOOL="exiftool"; PKG="libimage-exiftool-perl"; W=600; H=500; FONT=""; TITLE="Metadata" ;;
    filetype) TOOL="file";     PKG="file";                   W=600; H=300; FONT=""; TITLE="File Type Analysis" ;;
    # MODE IS $OPTARG, NOT A CLOSED SET. It reaches here only when it matched
    # none of the arms above, i.e. exactly when it is an arbitrary caller-chosen
    # string, so this is the one site in this file where MODE is attacker-shaped.
    # `-m '<b>x'` would otherwise put unbalanced markup into a Pango dialog and
    # GTK would drop the label body, which loses the error report itself.
    *) die "Unknown mode: $(esc "$MODE")" ;;
esac

# A MISSING TOOL WAS ONE OF THE ORIGINAL SILENT FAILURES. Name it.
command -v "$TOOL" >/dev/null 2>&1 \
    || die "<b>$(esc "$TOOL")</b> is not installed.\n\nInstall the $(esc "$PKG") package."

# Directories are not viewable targets. Say so rather than failing obscurely.
FILES=()
# TWO COPIES OF THE SKIP LIST, because it has two consumers with opposite needs.
# die() renders Pango markup, so names must be escaped there or a folder called
# "Tom & Jerry" breaks the dialog. The report goes to `--text-info`, which renders
# PLAIN TEXT (the rule at the top of this file), so the same escaped string there
# showed the user "Tom &amp; Jerry". One variable cannot serve both, and esc() also
# doubles backslashes, so escaping the whole list would eat the \n separators the
# dialog needs. Build both in the same loop and hand each consumer its own.
SKIPPED_PLAIN=""
SKIPPED_PANGO=""
for p in "$@"; do
    if [ -d "$p" ]; then
        nm="$(basename -- "$p")"
        SKIPPED_PLAIN="$SKIPPED_PLAIN\n  $nm  (folder, skipped)"
        SKIPPED_PANGO="$SKIPPED_PANGO\n  $(esc "$nm")  (folder, skipped)"
    elif [ -f "$p" ]; then
        FILES+=("$p")
    else
        SKIPPED_PLAIN="$SKIPPED_PLAIN\n  $p  (not found, skipped)"
        SKIPPED_PANGO="$SKIPPED_PANGO\n  $(esc "$p")  (not found, skipped)"
    fi
done
[ "${#FILES[@]}" -gt 0 ] || die "No regular file to inspect.$SKIPPED_PANGO"

# mktemp, never a predictable name. A fixed /tmp path in a world-writable
# directory is the symlink-swap hole this project has already fixed twice.
REPORT="$(mktemp -t kodachi-thunar-view.XXXXXXXXXX)" || die "Could not create a temporary file."
[ -n "$REPORT" ] && [ -f "$REPORT" ] || die "Could not create a temporary file."
cleanup() { [ -n "${REPORT:-}" ] && [ -f "$REPORT" ] && command rm -f -- "$REPORT"; }
trap cleanup EXIT INT TERM HUP

# The window title carries the file name for the three modes whose original
# entry used %n. %n is thunar-uca's basename token; it is recomputed here with
# basename instead of being passed through the XML, because this helper accepts
# a SELECTION and %n only ever names the first file. For one file the two are
# identical, and for several this one is correct where %n would be misleading.
if [ "${#FILES[@]}" -eq 1 ]; then
    case "$MODE" in
        hex|entropy|metadata) TITLE="$TITLE: $(basename -- "${FILES[0]}")" ;;
    esac
else
    TITLE="$TITLE (${#FILES[@]} files)"
fi

RC_WORST=0
run_tool() {  # $1 = file
    case "$MODE" in
        blake2)   b2sum -- "$1" ;;
        hex)      xxd -- "$1" | head -n "$HEX_LIMIT" ;;
        entropy)  ent -- "$1" ;;
        metadata) exiftool -- "$1" ;;
        filetype) file -- "$1" ;;
    esac
}

if [ "$MODE" = "filetype" ]; then
    # `file` on a whole selection in one pass is the useful behaviour and is why
    # this entry alone uses %F. Keep it one invocation, one dialog.
    if ! file -- "${FILES[@]}" >>"$REPORT" 2>>"$REPORT"; then
        RC_WORST=1
    fi
else
    for f in "${FILES[@]}"; do
        [ "${#FILES[@]}" -gt 1 ] && printf '===== %s =====\n' "$(basename -- "$f")" >>"$REPORT"
        # STDERR IS CAPTURED INTO THE REPORT ON PURPOSE. thunar-uca throws the
        # child's stderr away, so a tool that fails with a message the user needs
        # (an unreadable file, an unsupported format) would otherwise be silent
        # all over again, which is the whole defect this script exists to fix.
        if ! run_tool "$f" >>"$REPORT" 2>>"$REPORT"; then
            RC_WORST=1
        fi
        [ "${#FILES[@]}" -gt 1 ] && printf '\n' >>"$REPORT"
    done
fi

if [ ! -s "$REPORT" ]; then
    printf 'The tool produced no output.\n\nMode: %s\nTool: %s\n' "$MODE" "$TOOL" >>"$REPORT"
fi
if [ -n "$SKIPPED_PLAIN" ]; then
    printf '\n----- skipped -----%b\n' "$SKIPPED_PLAIN" >>"$REPORT"
fi

if have_zenity; then
    if [ -n "$FONT" ]; then
        zenity --text-info --title="$TITLE" --filename="$REPORT" \
               --width="$W" --height="$H" --font="$FONT" 2>/dev/null || true
    else
        zenity --text-info --title="$TITLE" --filename="$REPORT" \
               --width="$W" --height="$H" 2>/dev/null || true
    fi
else
    # No display, no dialog: still emit the report rather than vanishing.
    cat -- "$REPORT"
fi

exit "$RC_WORST"
