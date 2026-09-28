#!/bin/bash

# Thunar Secure Wipe - guarded, confirmed secure deletion
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
# Front end for `wipe` and `sfill`, used by the Thunar and xfdesktop context
# menus.
#
# WHY THIS SCRIPT EXISTS. The menu entry used to be, literally:
#
#     sudo wipe -f -r %F
#
# with no confirmation of any kind. On a background or desktop right-click
# there is no selection, so Thunar substitutes the CURRENT FOLDER for %F. One
# click on the desktop therefore started an unrecoverable multi-pass overwrite
# of ~/Desktop, and on the home surface of the whole home directory, under
# passwordless sudo. The action carried <directories/> plus every file-type
# flag, so it was present on every surface in the menu.
#
# Three guards, in order:
#   1. A protected-path refusal that NO confirmation can override.
#   2. A summary naming every path, its type, its file count and its size.
#   3. For a recursive directory wipe, typing the directory's own name.
#
# A missing zenity is treated as "cannot confirm", which means NO. It is never
# read as consent.
#
# Usage: thunar-wipe.sh [-m wipe|freespace] <path> [<path> ...]

set -u

ICON="kodachi"
MODE="wipe"

while getopts "m:" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        *) echo "Usage: $0 [-m wipe|freespace] <path> [<path> ...]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

have_zenity() { command -v zenity >/dev/null 2>&1; }

# EVERY zenity --text below is Pango markup. A filename is attacker-chosen data
# inside that markup, so a file named `</tt><b>SAFE` can rewrite the wording of
# a DESTRUCTIVE confirmation. Escape the five XML entities before interpolating.
# BACKSLASH FIRST, then ampersand. zenity runs g_strcompress on --text BEFORE
# Pango parses it, which is how every literal \n in these scripts becomes a
# newline. That same pass decompresses a \n arriving from a FILENAME, so a
# folder named `x\n\nType the name to confirm:\ny` could forge line breaks and
# wording inside a destructive confirmation. Doubling the backslash first makes
# g_strcompress emit one literal backslash and consume nothing after it.
# Ampersand before the other entities, or it double-escapes what they add.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                           -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                           -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

die() {
    if have_zenity; then
        zenity --error --title="Kodachi Secure Wipe" --text="$1" --width=520 2>/dev/null || true
    fi
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

confirm() {
    have_zenity || { echo "Refusing: zenity unavailable, a destructive action cannot be confirmed" >&2; return 1; }
    zenity --question --title="$1" --text="$2" \
        --ok-label="$3" --cancel-label="Cancel" --width=520 2>/dev/null
}

# ---------------------------------------------------------------------------
# GUARD 1. Paths that are never wipeable, whatever the user clicks. This is a
# refusal and not a scarier dialog: there is no answer that reaches past it.
# ---------------------------------------------------------------------------
is_protected() {
    local p="$1" real home d v
    real="$(readlink -f -- "$p" 2>/dev/null || printf '%s' "$p")"
    home="$(readlink -f -- "$HOME" 2>/dev/null || printf '%s' "$HOME")"

    # The home directory itself, and every ancestor of it.
    [ "$real" = "$home" ] && return 0
    case "$home/" in "$real"/*) return 0 ;; esac

    # Root and the system trees.
    case "$real" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 0 ;;
        # THE PREFIX LIST MUST COVER EVERY TREE THE EXACT LIST NAMES, or the
        # protection is decorative: /opt was refused while /opt/kodachi was
        # wipeable, /var while /var/log was, /root while /root/.ssh was. The two
        # lists are the same set now, with the deliberate exceptions below.
        /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib32/*|/lib64/*|/libx32/*|/opt/*|\
        /proc/*|/root/*|/run/*|/sbin/*|/srv/*|/sys/*|/usr/*|/var/*) return 0 ;;
        # DELIBERATELY NOT PROTECTED: /media/*, /mnt/* and /tmp/*. Wiping a file
        # on a USB stick is the most legitimate use this action has on a privacy
        # distribution, and refusing it would push the user back to a raw shell.
        # The mount ROOTS stay protected by the exact list above and by the
        # mountpoint test below.
    esac

    # The XDG well-knowns. Wiping the Desktop is exactly the accident this
    # script exists to prevent.
    for d in DESKTOP DOCUMENTS DOWNLOAD MUSIC PICTURES PUBLICSHARE TEMPLATES VIDEOS; do
        v="$(xdg-user-dir "$d" 2>/dev/null || true)"
        [ -n "$v" ] && [ "$real" = "$(readlink -f -- "$v" 2>/dev/null || printf '%s' "$v")" ] && return 0
    done
    for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
        [ "$real" = "$home/$d" ] && return 0
    done

    # A mount point is somebody's entire disk.
    if [ -d "$real" ] && command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q -- "$real" && return 0
    fi

    return 1
}

describe() {
    local p="$1" n size
    if [ -d "$p" ]; then
        n="$(find "$p" -type f 2>/dev/null | wc -l)"
        size="$(du -sh -- "$p" 2>/dev/null | cut -f1)"
        printf 'folder, %s file(s), %s' "${n:-?}" "${size:-?}"
    else
        size="$(du -h -- "$p" 2>/dev/null | cut -f1)"
        printf 'file, %s' "${size:-?}"
    fi
}

[ "$#" -gt 0 ] || die "No path was given.\n\nNothing has been wiped."

# ---------------------------------------------------------------------------
# ORDER IS LOAD-BEARING: POLICY BEFORE CAPABILITY.
# GUARD 1 and the tool-presence check run BEFORE the `sudo -n` probe below.
# Hoisting the sudo probe above them (which an earlier revision of this file did)
# meant right-clicking /etc on a host where sudo refuses reported a CAPABILITY
# failure whose remedy text named `sudo wipe -f -r <path>`, i.e. it handed the
# user a how-to for exactly the destruction GUARD 1 exists to refuse. A refusal
# on policy must never be reachable through a message about privileges.
# ---------------------------------------------------------------------------
if [ "$MODE" != "freespace" ]; then
    for p in "$@"; do
        [ -e "$p" ] || die "Path not found:\n$(esc "$p")\n\nNothing has been wiped."
        if is_protected "$p"; then
            die "REFUSED. This is a protected location:\n\n<b>$(esc "$p")</b>\n\nKodachi will not secure-wipe your home directory, a standard user folder such as Desktop or Documents, a system directory, or a mount point.\n\nNothing has been wiped. Select the individual files you want to destroy instead."
        fi
    done
    command -v wipe >/dev/null 2>&1 || die "wipe is not installed.\n\nIt is provided by the wipe package."
fi

# ---------------------------------------------------------------------------
# FREE SPACE mode. Overwrites unallocated space on the filesystem holding the
# given path. It cannot destroy existing user data, so one plain confirmation
# is enough and the protected-path guard does not apply.
# ---------------------------------------------------------------------------
# TWO THINGS THE OLD `sudo -n true` PROBE GOT WRONG (2026-08-26, from
# <agent>'s fleet-wide sweep of this exact call shape).
#
# 1. IT ASKED ABOUT THE WRONG COMMAND. `sudo -n true` answers a question about
#    `true`. The product ships four sudoers.d files, 139 NOPASSWD rules, and
#    every one names an EXACT command path; `true` is granted in none of them,
#    and neither is `wipe` or `sfill`. So on an installed system it refused for
#    a reason unrelated to this action, and on a live ISO, where live-config
#    adds a blanket `(ALL) NOPASSWD: ALL`, it said yes to everything. A granted
#    and an ungranted command read IDENTICALLY on every machine anyone tests
#    on, which is why no VM run can catch this. `sudo -n -l -- <cmd>` asks
#    about THIS command, needs no tty, and does not run it.
#
# 2. IT DEMANDED ROOT FOR WORK THAT NEVER NEEDED IT. Wiping a file you own, in
#    a directory you can write, requires no privilege at all. The old probe
#    refused the whole action before ever looking at the selection, so the
#    commonest case, shredding your own download, failed on a system with no
#    blanket rule. Root is now requested only when the selection actually
#    needs it, and refusal is reported before anything is confirmed.
# PROBE THE ARGV THAT WILL ACTUALLY RUN. A bare `NOPASSWD: /usr/bin/wipe` rule
# permits any arguments, so a full-argv probe passes under it as well; but an
# administrator who writes the NARROWER `NOPASSWD: /usr/bin/wipe -f -r *` rule is
# invisible to a probe of the bare path, and this script would tell them no rule
# exists while sudo would have run it. The most defensible sudoers rule must not
# be the one this probe misreads.
sudo_permits() { sudo -n -l -- "$@" >/dev/null 2>&1; }

# True when ANY target is not ours to destroy unaided: not owned by us, or
# sitting in a directory we cannot write (unlink needs the DIRECTORY's write
# bit, not the file's). Fails toward asking for root, never away from it.
#
# THE TOP-LEVEL TEST IS NOT ENOUGH FOR A DIRECTORY, and getting that wrong is
# destructive rather than merely inconvenient. A directory you own, in a
# directory you can write, passes both tests above while CONTAINING files owned
# by somebody else. `wipe -f -r` then destroys everything it is permitted to
# destroy, fails on the rest, and the script reports "Wipe failed" AFTER partial
# and unrecoverable destruction. So a directory is asked about its contents, and
# `-print -quit` stops the walk at the first foreign entry rather than statting
# a whole tree.
#
# `find -uid` takes a NUMBER. `-user "$(id -u)"` would look up a USER NAMED "1000",
# find no such user, and error out, which under this `||` shape would read as
# "no foreign files".
MY_UID="$(id -u)"
needs_root() {
    for p in "$@"; do
        [ -O "$p" ] || return 0
        [ -w "$(dirname -- "$p")" ] || return 0
        if [ -d "$p" ] && [ ! -L "$p" ]; then
            [ -z "$(find "$p" ! -uid "$MY_UID" -print -quit 2>/dev/null)" ] || return 0
        fi
    done
    return 1
}

PRIV=""
if [ "$MODE" = "freespace" ]; then
    FSTARGET="$1"
    [ -d "$FSTARGET" ] || FSTARGET="$(dirname -- "$1")"
    SFILL_BIN="$(command -v sfill 2>/dev/null)"
    [ -n "$SFILL_BIN" ] || die "sfill is not installed.\n\nIt is provided by the secure-delete package."
    if [ -w "$FSTARGET" ]; then
        PRIV=""
    elif sudo_permits "$SFILL_BIN" -l -l -v "$FSTARGET"; then
        PRIV="sudo -n"
    else
        die "Administrator rights for <tt>$(esc "$SFILL_BIN")</tt> are not granted, and <tt>$(esc "$FSTARGET")</tt> is not writable by you.\n\nsudo refused it without a password and no rule permits it for your account.\n\nRun this from a terminal instead:\n  sudo sfill -l -l -v <path>"
    fi
else
    WIPE_BIN="$(command -v wipe 2>/dev/null)"
    [ -n "$WIPE_BIN" ] || die "wipe is not installed.\n\nIt is provided by the wipe package."
    if needs_root "$@"; then
        if sudo_permits "$WIPE_BIN" -f -r -- "$@"; then
            PRIV="sudo -n"
        else
            # DELIBERATELY NAMES NO COMMAND. The freespace hint above is safe to
            # print because sfill cannot destroy existing files; a `wipe -f -r`
            # recipe can, and printing one turns a privilege error into an
            # instruction to bypass every guard in this script.
            die "Some of the selected items are not yours, and administrator rights for <tt>$(esc "$WIPE_BIN")</tt> are not granted.\n\nsudo refused it without a password and no rule permits it for your account.\n\nNothing has been wiped. Ask an administrator to grant it in /etc/sudoers.d/, or run the secure-delete tools yourself with administrator rights."
        fi
    fi
fi

if [ "$MODE" = "freespace" ]; then
    TARGET="$FSTARGET"
    FS="$(df -h --output=target,size,avail -- "$TARGET" 2>/dev/null | tail -1)"
    confirm "Wipe Free Space" \
        "Overwrite the FREE space of the filesystem holding:\n<b>$(esc "$TARGET")</b>\n\n<tt>$(esc "$FS")</tt>\n\nThis destroys the remains of files you deleted earlier. Your existing files are NOT touched.\n\nIt can take a long time and will temporarily fill the disk." \
        "Wipe free space" || exit 0
    if command -v xfce4-terminal >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        xfce4-terminal --title="Kodachi Wipe Free Space" -x $PRIV "$SFILL_BIN" -l -l -v "$TARGET" &
    elif command -v xterm >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        xterm -T "Kodachi Wipe Free Space" -e $PRIV "$SFILL_BIN" -l -l -v "$TARGET" &
    else
        die "No terminal emulator is available to show sfill progress."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# WIPE mode.
# ---------------------------------------------------------------------------
SUMMARY=""
# EVERY directory, not the last one seen. A single `DIR_TARGET` variable kept
# only the final folder of the selection, so typing ONE folder name authorised
# the recursive destruction of ALL of them.
DIRS=()
COUNT=0

# Existence and GUARD 1 were already enforced above, before the sudo probe. This
# loop only builds the summary and the folder list.
for p in "$@"; do
    if [ -d "$p" ]; then
        DIRS+=("$p")
    fi
    SUMMARY="$SUMMARY
  $(esc "$p")
      $(esc "$(describe "$p")")"
    COUNT=$((COUNT + 1))
done

confirm "Kodachi Secure Wipe" \
    "<b>This is unrecoverable.</b> The data is overwritten in place. It is not moved to the trash and it cannot be undone.\n\nAbout to wipe $COUNT item(s):\n<tt>$SUMMARY</tt>\n\nContinue?" \
    "Wipe permanently" || exit 0

# GUARD 3. A recursive folder wipe asks for the folder's own name in writing,
# ONCE PER FOLDER. Selecting three folders and typing one name is not consent
# for the other two.
if [ "${#DIRS[@]}" -gt 0 ]; then
    have_zenity || die "Refusing a recursive wipe: zenity is unavailable, so the name confirmation cannot be shown."
    IDX=0
    for d in "${DIRS[@]}"; do
        IDX=$((IDX + 1))
        BASE="$(basename -- "$d")"
        TYPED="$(zenity --entry --title="Confirm recursive wipe ($IDX of ${#DIRS[@]})" \
            --text="This wipes a FOLDER AND EVERYTHING INSIDE IT, recursively and unrecoverably:\n\n<b>$(esc "$d")</b>\n\nType the folder's name to confirm:\n<tt>$(esc "$BASE")</tt>" \
            --width=520 2>/dev/null)" || exit 0
        [ "$TYPED" = "$BASE" ] || die "The name did not match.\n\nTyped: $(esc "$TYPED")\nExpected: $(esc "$BASE")\n\nNothing has been wiped."
    done
fi


ERR="$(mktemp)" || die "Could not create a temporary file."
# shellcheck disable=SC2086
if $PRIV "$WIPE_BIN" -f -r -- "$@" >/dev/null 2>"$ERR"; then
    unlink "$ERR" 2>/dev/null || true
    notify-send -i "$ICON" "Kodachi Secure Wipe" "$COUNT item(s) wiped permanently" 2>/dev/null || true
else
    MSG="$(cat "$ERR" 2>/dev/null)"
    unlink "$ERR" 2>/dev/null || true
    die "Wipe failed.\n\n$(esc "$MSG")"
fi

exit 0
