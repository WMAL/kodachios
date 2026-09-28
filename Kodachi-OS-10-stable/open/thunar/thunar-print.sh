#!/bin/bash

# Thunar Print - send the selected file(s) to the printer, and SAY SO WHEN IT CANNOT
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
# Replaces the `thunar-print` command the "Print file/s" menu entry used to
# name. THAT COMMAND DOES NOT EXIST: it is not a Debian package (`apt-cache
# show thunar-print` -> "E: No packages found", while the same query resolves
# `thunar` normally), and no file in this project provides it. The entry was
# harmless only because it was ALSO unreachable, carrying 57 file globs with
# `<directories/>` as its only type flag, and Thunar requires both a glob match
# and a matching type flag. Repairing the flags without repairing the command
# would have turned an invisible entry into a visible one that does nothing,
# because thunar-uca discards a child's stderr.
#
# Two print paths, because CUPS cannot render every type in that glob list:
#   - office and rich-text documents go through LibreOffice, which is installed
#     on the desktop edition, because cups-filters has no filter for them and
#     `lp` would spool the raw zip or RTF markup as garbage.
#   - PDF, PostScript, images and plain text go straight to `lp`, which
#     cups-filters handles natively.
#
# Every failure is reported. The three that actually happen on this
# distribution are: no `lp` at all (the terminal edition ships no CUPS), the
# cups daemon masked (the minimal boot profile masks it on purpose, for
# privacy), and no printer configured yet.
#
# Usage: thunar-print.sh <file> [<file> ...]

set -u

esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

ICON="kodachi"
TITLE="Print"

err() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="$TITLE" --text="$1" --width=560 2>/dev/null
    fi
    printf '%s\n' "$1" >&2
}

info() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="$TITLE" --text="$1" --width=560 2>/dev/null
    fi
    printf '%s\n' "$1"
}

[ "$#" -gt 0 ] || { echo "Usage: $0 <file> [<file> ...]" >&2; exit 1; }

# ---------------------------------------------------------------- print stack
if ! command -v lp >/dev/null 2>&1; then
    err "No printing support is installed.\n\nKodachi's terminal edition ships without CUPS on purpose. Install the client to print:\n\n<tt>sudo apt install cups cups-client cups-filters</tt>"
    exit 1
fi

# `lpstat -r` is the cheap daemon probe. It prints "scheduler is running" or
# says it is not; on a masked unit it fails outright. Either way the message
# below names the real remedy instead of leaving a dialog-less no-op.
SCHED="$(lpstat -r 2>&1)"
case "$SCHED" in
    *"is running"*) : ;;
    *)
        # SAY WHAT THE UNIT ACTUALLY IS, DO NOT ASSERT WHAT THE IMAGE INTENDED.
        # This used to state flatly that "Kodachi's minimal boot profile masks it
        # deliberately". Measured on the <lab-host> live ISO by <agent>:
        #     systemctl is-enabled cups  ->  disabled     NOT masked
        #     systemctl is-active  cups  ->  inactive
        # Only a COMMENT in gui-xfce.list.chroot claims cups is masked; nothing in
        # the image actually masks it. So the dialog was making a privacy claim
        # about this build that is not true of it, and `unmask` is a no-op on a
        # merely disabled unit. The remedy still worked, which is why nobody
        # noticed. Read the state and word both the claim and the remedy from it.
        CUPS_STATE="$(systemctl is-enabled cups 2>/dev/null || true)"
        [ -n "$CUPS_STATE" ] || CUPS_STATE="unknown"
        case "$CUPS_STATE" in
            masked)
                WHY="Kodachi masks it deliberately, because a print daemon listens on the network and advertises this machine."
                REMEDY="sudo systemctl unmask cups\nsudo systemctl start cups"
                ;;
            disabled|unknown)
                WHY="Kodachi ships it installed but not enabled, because a print daemon listens on the network and advertises this machine."
                REMEDY="sudo systemctl start cups"
                ;;
            *)
                WHY="It is installed and reported as <tt>$(esc "$CUPS_STATE")</tt>, but the scheduler is not answering."
                REMEDY="sudo systemctl start cups"
                ;;
        esac
        err "The printing service is not running.\n\n$WHY\n\nTo enable it for this session:\n\n<tt>$REMEDY</tt>\n\nUnit state: <tt>$(esc "$CUPS_STATE")</tt>\nReported: <tt>$(esc "$SCHED")</tt>"
        exit 1
        ;;
esac

# ------------------------------------------------------------------- printer
PRINTER=""
DEF="$(lpstat -d 2>/dev/null)"
case "$DEF" in
    *": "*) PRINTER="${DEF##*: }" ;;
esac

if [ -z "$PRINTER" ]; then
    # No default. If exactly one queue exists, use it and say which; otherwise
    # ask, rather than spooling to a queue the user did not choose.
    QUEUES="$(lpstat -a 2>/dev/null | awk '{print $1}')"
    NQ="$(printf '%s\n' "$QUEUES" | grep -c '[^[:space:]]')"
    if [ "$NQ" -eq 0 ]; then
        err "No printer is configured.\n\nAdd one first, then try again. CUPS's own interface is at <tt>http://localhost:631</tt> while the service is running."
        exit 1
    elif [ "$NQ" -eq 1 ]; then
        PRINTER="$(printf '%s\n' "$QUEUES" | grep -m1 '[^[:space:]]')"
    else
        if command -v zenity >/dev/null 2>&1; then
            PRINTER="$(printf '%s\n' "$QUEUES" | zenity --list --title="$TITLE" \
                --text="No default printer is set. Choose one:" \
                --column="Printer" --height=320 --width=420 2>/dev/null)"
        fi
        [ -n "$PRINTER" ] || exit 0
    fi
fi

# ------------------------------------------------------------------ classify
# Extensions cups-filters cannot render. These go through LibreOffice.
office_type() {
    case "${1,,}" in
        *.doc|*.docm|*.docx|*.dot|*.dotm|*.dotx|*.odb|*.odf|*.odg|*.odm|*.odp|\
        *.ods|*.odt|*.otg|*.oth|*.otp|*.ots|*.ott|*.fodg|*.fodp|*.fods|*.fodt|\
        *.pot|*.potm|*.potx|*.ppt|*.pptm|*.pptx|*.rtf|*.xls|*.xlsb|*.xlsm|\
        *.xlsx|*.xltm|*.xltx) return 0 ;;
    esac
    return 1
}

OK=0
FAILED=""
SKIPPED=""

for f in "$@"; do
    if [ -d "$f" ]; then
        SKIPPED="${SKIPPED}
  $(esc "$(basename -- "$f")") (a folder)"
        continue
    fi
    if [ ! -r "$f" ]; then
        FAILED="${FAILED}
  $(esc "$(basename -- "$f")") (not readable)"
        continue
    fi

    # A HYPHEN-LEADING FILENAME WOULD BE PARSED AS AN OPTION, and the guard used
    # here is an absolute path rather than a `--` marker, because an absolute path
    # is uniform across BOTH branches below while `--` is not.
    #
    # CORRECTION, 2026-08-26: an earlier version of this comment asserted as a
    # measured fact that `lp` rejects `--`. That is FALSE and was refuted with
    # controls: `lp -- <file>` passes option parsing and reaches the destination
    # check, and lp's own usage line reads `lp [options] [--] [file(s)]`. What IS
    # measured is that the guard is needed at all: `lp -weird.txt` dies with
    # `unknown option "e"`. libreoffice's `--` handling was NEVER MEASURED by
    # anyone here, so the absolute path is what keeps both branches correct
    # without resting on an unproven claim about either one.
    ABS="$(readlink -f -- "$f" 2>/dev/null || printf '%s' "$f")"
    case "$ABS" in /*) : ;; *) ABS="./$ABS" ;; esac

    OUT=""
    RC=0
    if office_type "$f"; then
        if command -v libreoffice >/dev/null 2>&1; then
            OUT="$(libreoffice --headless --norestore --pt "$PRINTER" "$ABS" 2>&1)" || RC=$?
        else
            FAILED="${FAILED}
  $(esc "$(basename -- "$f")") (needs LibreOffice to render this format)"
            continue
        fi
    else
        OUT="$(lp -d "$PRINTER" "$ABS" 2>&1)" || RC=$?
    fi

    if [ "$RC" -eq 0 ]; then
        OK=$((OK + 1))
    else
        FAILED="${FAILED}
  $(esc "$(basename -- "$f")"): $(esc "${OUT:-exit $RC}")"
    fi
done

# -------------------------------------------------------------------- report
TOTAL=$#
if [ -z "$FAILED" ] && [ -z "$SKIPPED" ]; then
    notify-send -i "$ICON" "Sent to $PRINTER" "$OK of $TOTAL file(s) queued" 2>/dev/null || true
    exit 0
fi

MSG="Printer: <tt>$(esc "$PRINTER")</tt>\n\nQueued: $OK of $TOTAL"
[ -n "$SKIPPED" ] && MSG="$MSG\n\nSkipped:$SKIPPED"
[ -n "$FAILED" ]  && MSG="$MSG\n\nFailed:$FAILED"

if [ -n "$FAILED" ]; then
    err "$MSG"
    exit 1
fi
info "$MSG"
exit 0
