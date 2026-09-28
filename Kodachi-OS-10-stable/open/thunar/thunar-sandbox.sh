#!/bin/bash

# Thunar Firejail Sandbox - confine a shell or a file manager to one folder
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
# Opens a terminal, or a file manager, confined by Firejail to a single folder
# with no network. It is for opening something you do not trust: an extracted
# archive, a downloaded bundle, somebody else's USB stick.
#
# WHAT THIS IS NOT. Kodachi already ships
# /usr/local/libexec/kodachi/kodachi-firejail-launcher, and this script
# deliberately does not call it. That adapter takes an application IDENTITY and
# never a path, and that invariant is the whole security property it provides.
# Handing it a user-selected directory would widen its contract. This script is
# the narrower, separate thing: a fixed argv confining a shell to one directory
# that the user chose in their own file manager.
#
# Usage: thunar-sandbox.sh [-m terminal|files] [-n] <folder>
#        -n  allow network access (default is --net=none)

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
MODE="terminal"
NET="--net=none"
NETLABEL="no network"

while getopts "m:n" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        n) NET=""; NETLABEL="network ALLOWED" ;;
        *) echo "Usage: $0 [-m terminal|files] [-n] <folder>" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

have_zenity() { command -v zenity >/dev/null 2>&1; }

die() {
    have_zenity && { zenity --error --title="Firejail Sandbox" --text="$1" --width=520 2>/dev/null || true; }
    notify-send -i "$ICON" "Sandbox failed" "$(printf '%s' "$1" | head -1)" 2>/dev/null || true
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

TARGET="${1:-}"
[ -n "$TARGET" ] || die "No folder was given."
[ -e "$TARGET" ] || die "Path not found:\n$(esc "$TARGET")"
# A file is sandboxed by confining its containing folder, which is what a user
# clicking a suspicious download means.
[ -d "$TARGET" ] || TARGET="$(dirname -- "$TARGET")"
TARGET="$(readlink -f -- "$TARGET" 2>/dev/null || printf '%s' "$TARGET")"
[ -d "$TARGET" ] || die "Not a folder:\n$(esc "$TARGET")"

command -v firejail >/dev/null 2>&1 || die "firejail is not installed."

# STOP THE SANDBOX LITTERING THE FOLDER THE USER POINTED IT AT.
#
# `--private=<dir>` makes <dir> the sandbox HOME, so anything the confined program
# writes to its home lands in the user's own folder. Measured on <lab-host>
# with XDG_* UNSET, which is the real desktop condition, a single sandbox run left:
#     .bashrc  .cache/  .config/  .inputrc  .local/  .Xauthority
# and the reporter saw the same six on the <lab-host> live ISO: a right-click action
# that silently litters, with a credential file among the litter.
#
# WHAT EACH FLAG ACTUALLY REMOVES, measured one at a time rather than assumed:
#   --keep-shell-rc      .bashrc and .inputrc     (firejail's own skel copy)
#   --keep-config-pulse  .config/                 (firejail's PulseAudio init)
#   --private-tmp plus the XDG redirects below
#                        .cache/ and .local/      (written by the confined program,
#                                                  which falls back to $HOME/... when
#                                                  XDG_* is unset, and $HOME is the
#                                                  user's folder)
#
# .Xauthority IS NOT REMOVABLE HERE AND I AM NOT PRETENDING OTHERWISE. firejail
# creates it unconditionally for a private home, even with DISPLAY unset. The only
# thing that suppresses it is `--x11=none`, which takes X away from the sandbox and
# would break both modes outright. So this is six files down to one, and the one
# that remains is structural.
#
# MY FIRST MEASUREMENT OF THIS WAS WRONG IN THE REASSURING DIRECTION: the probe
# payload used the INHERITED XDG_* from an ssh session, so it wrote outside the jail
# and every arm looked clean. Only unsetting them reproduced .cache and .local. A
# positive control (listing the paths inside the jail afterwards) is what showed the
# writes were really happening.
#
# The XDG targets sit under the jail's own /tmp, which --private-tmp makes a tmpfs,
# so they vanish with the sandbox. `--private=$TARGET` is kept exactly as it was:
# the `firejail --list` detection below matches on that token and would stop working
# if the confinement shape changed.
FJ_TIDY="--keep-shell-rc --keep-config-pulse --private-tmp"
FJ_TIDY="$FJ_TIDY --env=XDG_CACHE_HOME=/tmp/kodachi-sandbox/cache"
FJ_TIDY="$FJ_TIDY --env=XDG_CONFIG_HOME=/tmp/kodachi-sandbox/config"
FJ_TIDY="$FJ_TIDY --env=XDG_DATA_HOME=/tmp/kodachi-sandbox/data"

# --private=<dir> makes <dir> the sandbox's HOME. Refusing the real home keeps
# the action honest: confining $HOME to $HOME sandboxes nothing and would read
# to the user as protection they do not have.
HOME_REAL="$(readlink -f -- "$HOME" 2>/dev/null || printf '%s' "$HOME")"
[ "$TARGET" = "$HOME_REAL" ] && die "REFUSED. Sandboxing your home directory to itself gives no isolation at all.\n\nSelect the specific folder you want to confine."

# LAUNCH AND THEN CHECK WHETHER A SANDBOX ACTUALLY EXISTS.
#
# THE CHILD'S EXIT STATUS IS NOT AN ORACLE HERE, measured on this host
# 2026-08-26. Both of the two ways this action failed exited ZERO:
#
#   * `thunar --new-instance` (the argv this script used to ship) is not a
#     Thunar option at all. `thunar --help` lists -B, -w, --daemon, -q, -V,
#     --display and nothing else. Thunar prints "Unknown option
#     --new-instance" on stderr and EXITS 0, and thunar-uca discards that
#     stderr, so the user clicked and got a "File manager confined to X"
#     notification with no window anywhere. That is the operator's report.
#   * plain `thunar` inside the sandbox reaches the session bus, hands the
#     request to the Thunar daemon OUTSIDE the sandbox and exits 0. The
#     sandbox is torn down, and any window that does appear is unconfined,
#     which is worse than nothing because the notification claims isolation.
#
# The terminal mode legitimately has a dead child too: xfce4-terminal hands
# off to its own server, so the sandbox belongs to a process this script
# never sees. So the thing to test is not the child, it is whether firejail
# is holding a sandbox on this exact directory.
# `firejail --list` emits `PID:user:name:cmdline`. Two things about matching it
# are load-bearing and neither is obvious:
#
# ANCHOR ON THE FIELD BOUNDARY. A plain substring test for `--private=$TARGET`
# is satisfied by any sandbox whose private directory merely BEGINS with the
# target path, so a live sandbox on `.../Downloads2` answers yes for a query
# about `.../Downloads`. Measured, on a real firejail process. The token must be
# followed by a space or by end-of-line, because that is where firejail's own
# argument ends.
#
# AND ASK FOR A **NEW** SANDBOX, NOT FOR **ANY** SANDBOX. An existence test is
# satisfied by a sandbox left over from a previous click on the same folder, so
# a launch that fails outright still reports "confined" as long as the earlier
# one is still open. Both of those produce exactly the outcome this script
# exists to prevent: the notification claims isolation and no window appears.
sandbox_pids() {
    firejail --list 2>/dev/null | awk -v tok="--private=$TARGET" '
        {
            n = index($0, tok)
            if (n > 0) {
                nxt = substr($0, n + length(tok), 1)
                if (nxt == "" || nxt == " ") {
                    c = index($0, ":")
                    if (c > 0) print substr($0, 1, c - 1)
                }
            }
        }'
}

launch_checked() {
    ERR="$(mktemp)" || die "Could not create a temporary file."
    # Pad with spaces so the `*" $p "*` test below cannot match a pid that is
    # merely a substring of another pid (127 inside 1270).
    BEFORE=" $(sandbox_pids | tr '\n' ' ') "
    "$@" >/dev/null 2>"$ERR" &
    CHILD=$!

    # POLL TO A DEADLINE INSTEAD OF SLEEPING A FIXED INTERVAL. The sandbox
    # appeared in `--list` within 0.5s when measured here, so the success path
    # normally leaves this loop on its second pass; a fixed sleep would have
    # spent the whole budget every single time, and on a slower machine would
    # have killed a sandbox that was merely late and shown a frightening dialog
    # about it. 6 seconds is the ceiling, not the cost.
    NEWPID=""
    i=0
    while [ "$i" -lt 24 ]; do
        for p in $(sandbox_pids); do
            case "$BEFORE" in
                *" $p "*) ;;
                *) NEWPID="$p"; break ;;
            esac
        done
        [ -n "$NEWPID" ] && break
        i=$((i + 1))
        sleep 0.25
    done

    if [ -z "$NEWPID" ]; then
        kill "$CHILD" 2>/dev/null || true
        MSG="$(head -c 400 "$ERR" 2>/dev/null)"
        unlink "$ERR" 2>/dev/null || true
        die "The sandbox did not start, so nothing was confined.\n\nfirejail opened no new sandbox on <tt>$(esc "$TARGET")</tt>.\n\n$(esc "${MSG:-No error output was produced.}")"
    fi
    unlink "$ERR" 2>/dev/null || true
    return 0
}

case "$MODE" in
    terminal)
        TERM_BIN=""
        for t in xfce4-terminal xterm; do command -v "$t" >/dev/null 2>&1 && { TERM_BIN="$t"; break; }; done
        [ -n "$TERM_BIN" ] || die "No terminal emulator is installed."
        if [ "$TERM_BIN" = "xfce4-terminal" ]; then
            # shellcheck disable=SC2086
            launch_checked xfce4-terminal --title="Firejail sandbox: $(basename -- "$TARGET") ($NETLABEL)" \
                -x firejail --quiet $FJ_TIDY $NET --private="$TARGET" /bin/bash
        else
            # shellcheck disable=SC2086
            launch_checked xterm -T "Firejail sandbox: $(basename -- "$TARGET")" \
                -e firejail --quiet $FJ_TIDY $NET --private="$TARGET" /bin/bash
        fi
        notify-send -i "$ICON" "Firejail Sandbox" "Shell confined to $(esc "$(basename -- "$TARGET")") ($NETLABEL)" 2>/dev/null || true
        ;;
    files)
        command -v thunar >/dev/null 2>&1 || die "thunar is not installed."
        # DO NOT PASS THE OUTSIDE PATH. `--private=<dir>` bind-mounts <dir> onto
        # the user's HOME inside the sandbox, so the folder's own path does not
        # exist in there and Thunar opened on a location that is not present.
        # Measured: `firejail --private=$HOME/.cache /bin/sh -c 'ls -d
        # $HOME/.cache'` reports No such file or directory. With no argument
        # Thunar opens $HOME, which IS the confined folder.
        #
        # `--dbus-user=none` IS WHAT MAKES THIS WORK AT ALL, and it took three
        # measured variants on this host 2026-08-26 to establish it:
        #
        #   thunar --new-instance   no such option, exits 0, NO WINDOW
        #   thunar                  hands off over the session bus to the
        #                           outside daemon, sandbox torn down, NO WINDOW
        #   --dbus-user=none        sandbox stays up and owns the window
        #
        # Discriminator, both directions: the confined window reports
        # _NET_WM_PID=7, a pid that only exists inside firejail's PID
        # namespace, while an ordinary Thunar window on the same desktop
        # reports the real host pid of the daemon. `--dbus-user=filter` was
        # tried and is NOT usable: Thunar cannot claim its own bus name
        # through the proxy and dies with GDBus ServiceUnknown.
        #
        # The cost is one warning, "Failed to initialize Xfconf: Could not
        # connect: Permission denied". Xfconf is the settings daemon, so the
        # confined Thunar uses built-in defaults instead of the user's saved
        # view preferences. That is the correct trade for an action whose only
        # purpose is isolation.
        # shellcheck disable=SC2086
        launch_checked firejail --quiet $FJ_TIDY $NET --dbus-user=none --private="$TARGET" thunar
        notify-send -i "$ICON" "Firejail Sandbox" "File manager confined to $(esc "$(basename -- "$TARGET")") ($NETLABEL)" 2>/dev/null || true
        ;;
    # MODE IS $OPTARG, NOT A CLOSED SET, and this arm is reached precisely when
    # it matched no known mode, i.e. when it is an arbitrary caller-chosen
    # string. See the identical site in thunar-metadata.sh.
    *) die "Unknown mode: $(esc "$MODE")" ;;
esac

exit 0
