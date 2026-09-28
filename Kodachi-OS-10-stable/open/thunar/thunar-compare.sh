#!/bin/bash

# Thunar Compare - diff exactly two selected files
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
# Compares exactly two selected files. Uses meld when it is installed, and
# falls back to a unified diff in a zenity viewer otherwise.
#
# The wrong-number-of-files case is NAMED rather than silent. A bare
# `diff -u %F | zenity --text-info` menu entry would show an empty window when
# one file is selected, which is the silent-failure shape this menu already had
# too much of.
#
# Usage: thunar-compare.sh <file-a> <file-b>

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

have_zenity() { command -v zenity >/dev/null 2>&1; }

die() {
    have_zenity && { zenity --error --title="Compare Files" --text="$1" --width=520 2>/dev/null || true; }
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 2 ] || die "Select exactly TWO files to compare.\n\nYou selected $#."
A="$1"; B="$2"
[ -f "$A" ] || die "Not a regular file:\n$(esc "$A")"
[ -f "$B" ] || die "Not a regular file:\n$(esc "$B")"

if cmp -s -- "$A" "$B"; then
    have_zenity && zenity --info --title="Compare Files" \
        --text="The two files are <b>byte-identical</b>.\n\n$(esc "$(basename -- "$A")")\n$(esc "$(basename -- "$B")")" --width=520 2>/dev/null
    exit 0
fi

# WHY TWO MATCHERS. `pgrep -x` matches /proc/<pid>/comm, and comm is NOT
# basename(argv[0]): /usr/bin/meld is a Python program, so its comm is whatever
# the interpreter or setproctitle leaves there, measured below rather than
# assumed. The -f form matches the full command line and covers the case comm
# does not. -f cannot self-match here: pgrep never returns its own pid, and the
# pattern appears inside this script file, never in the argv of the shell
# running it, which is the trap that matters for -f.
#
# MEASURED on <lab-host> with a real Python program at a meld-shaped path:
# comm reads `meld`, not `python3`, because the kernel sets comm from the SCRIPT
# name for a `#!` program, so -x does work here. The launched pid appeared in
# both matchers and disappeared from both after kill, which is the two-direction
# result. It is kept anyway, because comm is 15 bytes and truncates.
#
# THE LIMIT, STATED RATHER THAN IMPLIED: this is an EXISTENCE test, so an
# UNRELATED meld window the user already had open will silence a genuine failure
# of this launch. That is the same stale-instance caveat thunar-root.sh carries,
# and separating them needs a window oracle (wmctrl, absent on this PC, .198 and
# .173). It is still strictly better than the previous behaviour, which was
# silent in every case. The measurement above found this the hard way: four
# orphaned meld processes of my own were running and made the negative arm
# non-empty.
meld_instances() {
    { pgrep -u "$(id -u)" -x -i -- meld
      pgrep -u "$(id -u)" -f -- '/usr/bin/meld'
    } 2>/dev/null | sort -u | tr '\n' ' '
}

if command -v meld >/dev/null 2>&1; then
    # Do not throw meld's stderr away. A launcher that discards it reports
    # success for a viewer that never opened, which is the silent-failure shape
    # this whole menu was audited for.
    ERR="$(mktemp)" || ERR=""
    if [ -n "$ERR" ]; then
        meld -- "$A" "$B" >/dev/null 2>"$ERR" &
        CHILD=$!
        sleep 1.5
        if ! kill -0 "$CHILD" 2>/dev/null; then
            wait "$CHILD" 2>/dev/null
            RC=$?
            if [ "$RC" -ne 0 ]; then
                MSG="$(head -c 400 "$ERR" 2>/dev/null)"
                unlink "$ERR" 2>/dev/null || true
                die "meld exited immediately (status $RC).\n\n$(esc "${MSG:-No error output was produced.}")"
            fi
            # RC IS NOT AN ORACLE HERE, and the file already knew that two lines
            # up without acting on it. meld is a GApplication single-instance
            # program: handing the files to an already-open window exits 0, and a
            # meld that prints a fatal to stderr and dies ALSO exits 0. The
            # captured stderr was consulted only on the RC!=0 branch and then
            # discarded, so the second world was silent, which is the whole
            # failure shape this menu was audited for.
            #
            # Stderr ALONE cannot be the test either: a real hand-off may emit
            # benign GTK noise, and `-s` trips on one byte. So stderr only
            # promotes to an error when NO meld is running to have received the
            # hand-off, which is the same discriminator thunar-root.sh uses.
            if [ -s "$ERR" ] && [ -z "$(meld_instances)" ]; then
                MSG="$(head -c 400 "$ERR" 2>/dev/null)"
                unlink "$ERR" 2>/dev/null || true
                die "meld reported success but exited at once without opening, and no meld window is running.\n\n$(esc "${MSG:-No error output was produced.}")"
            fi
        fi
        unlink "$ERR" 2>/dev/null || true
    else
        meld -- "$A" "$B" >/dev/null 2>&1 &
    fi
    exit 0
fi

# `diff` exits 1 when the files differ, which is the expected case here, so its
# status is deliberately not treated as an error.
OUT="$(diff -u -- "$A" "$B" 2>&1)" || true
if [ -z "$OUT" ]; then
    OUT="The files differ, but diff produced no textual output. They are probably binary.

$(cmp -- "$A" "$B" 2>&1)"
fi

have_zenity || { printf '%s\n' "$OUT"; exit 0; }
printf '%s\n' "$OUT" | zenity --text-info \
    --title="Compare: $(basename -- "$A") vs $(basename -- "$B")" \
    --width=850 --height=560 --font="monospace 9" 2>/dev/null || printf '%s\n' "$OUT"
exit 0
