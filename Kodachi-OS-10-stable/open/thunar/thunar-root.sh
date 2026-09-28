#!/bin/bash

# Thunar Open/Edit as Root - with the X credentials the child actually needs
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
# Back end for the "Open as Root" and "Edit as Root" context-menu entries.
#
# WHY THIS SCRIPT EXISTS. The menu entries used to be, literally:
#
#     sudo -n thunar %F
#     sudo -n mousepad %F
#
# and BOTH DID NOTHING AT ALL. Measured on the live ISO 2026-08-26:
#
#     sudo -n /usr/bin/env | grep -E '^(DISPLAY|XAUTHORITY)='
#     -> neither variable is present
#
# sudo's env_reset strips DISPLAY and XAUTHORITY, so the GUI child has no
# display to open, dies immediately, and its stderr goes nowhere because
# thunar-uca does not show it. The user clicks and observes nothing: no window,
# no error, no notification.
#
# WHY `env` IS NO LONGER THE PRIMARY FORM (2026-08-26, <agent>'s class
# sweep). Passing the variables as arguments to `env` does get them past
# env_reset, but sudo matches its rules on argv[0], which is then `env`. The four
# shipped sudoers.d files grant `/usr/bin/thunar` and `/usr/bin/mousepad`
# (kodachi-binaries:128-129) and grant `/usr/bin/env` NOWHERE, so the env form is
# MUTUALLY EXCLUSIVE with the only rule that authorises this action. It works on
# a live ISO purely because live-config adds a blanket `(ALL) NOPASSWD: ALL` that
# the product does not ship, which is why no VM run can show the defect.
#
# The primary form now calls the granted binary directly and relies on
#     Defaults!/usr/bin/thunar   env_keep += "DISPLAY XAUTHORITY"
#     Defaults!/usr/bin/mousepad env_keep += "DISPLAY XAUTHORITY"
# which grant no new command and use the idiom already at kodachi-binaries:22-23.
# The `env` form is kept as a FALLBACK for a machine whose sudoers predates those
# two lines, and is attempted only when sudoers actually permits `env`.
#
# Usage: thunar-root.sh -m thunar|mousepad <path> [<path> ...]

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
APP="thunar"

while getopts "m:" opt; do
    case "$opt" in
        m) APP="$OPTARG" ;;
        *) echo "Usage: $0 -m thunar|mousepad <path> [<path> ...]" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

have_zenity() { command -v zenity >/dev/null 2>&1; }

# The dialog has to name the entry the user actually clicked. This was hardcoded
# to "Open as Root", so a failure of "Kodachi Edit as Root" opened a window titled
# "Open as Root" and pointed the user at the wrong menu entry. Observed on the
# <lab-host> live ISO. APP is validated against a closed set below, so the label can
# only ever be one of these two.
entry_label() {
    case "$APP" in
        mousepad) printf 'Edit as Root' ;;
        *)        printf 'Open as Root' ;;
    esac
}

die() {
    have_zenity && { zenity --error --title="$(entry_label)" --text="$1" --width=520 2>/dev/null || true; }
    notify-send -i "$ICON" "$(entry_label) failed" "$(printf '%s' "$1" | head -1)" 2>/dev/null || true
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

case "$APP" in
    thunar|mousepad) ;;
    *) die "Unsupported application: $(esc "$APP")" ;;
esac
command -v "$APP" >/dev/null 2>&1 || die "$(esc "$APP") is not installed."
[ "$#" -gt 0 ] || die "No path was given."

: "${DISPLAY:=}"
[ -n "$DISPLAY" ] || die "No X display is available, so a graphical root session cannot be started."

XAUTH="${XAUTHORITY:-$HOME/.Xauthority}"
[ -f "$XAUTH" ] || XAUTH=""

# RE-FILE THE COOKIE UNDER THE CURRENT HOSTNAME BEFORE ESCALATING.
#
# Handing root the right FILE is not enough: Kodachi renames the machine for
# privacy AFTER X has written the cookie, so the entry inside is named for the
# OLD hostname and an X client, which resolves its cookie by the CURRENT
# hostname, presents no authorization at all. The desktop user never notices
# because xhost separately carries SI:localuser:<user>; root is not in that
# list, so this is exactly the "cannot open display" that killed both Open as
# Root and Edit as Root on the <lab-host> live ISO.
#
# MEASURED 2026-09-07 on <lab-host>, four arms, same binary, same display,
# SAME cookie value, with the X grant for root removed for the test and restored
# after (with it in place every arm connects and the run is vacuous, which is
# how the first attempt went):
#     root, entry named kodachi/unix:0      (what ships)  REFUSED
#     root, entry named <current>/unix:0    (repaired)    CONNECTS
#     desktop user                          (control)     CONNECTS
#     root, nonexistent cookie file  (negative control)   REFUSED
#
# Done HERE and not only at session start because the hostname can be
# re-randomised at any time from the dock, so a boot-time repair goes stale. The
# helper is idempotent and additive (proven: three runs, entry count unchanged),
# and it grants nothing new, it copies a value already in the caller's own file.
# Reported by <agent> from <lab-host>, reproduced independently.
if [ -n "$XAUTH" ] && command -v kodachi-xauth-hostname-repair.sh >/dev/null 2>&1; then
    XAUTHORITY="$XAUTH" kodachi-xauth-hostname-repair.sh --quiet >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# ASK SUDOERS ABOUT THE COMMAND WE ARE ACTUALLY GOING TO RUN.
# `sudo -n true` was the old probe and it answers a question about `true`. On an
# installed system whose sudoers names exact commands, `true` is granted nowhere
# either, so it produced the right refusal for the wrong reason; on any machine
# with a blanket rule both answer yes and the probe proves nothing at all.
# `sudo -n -l <cmd>` asks whether THIS command is permitted, needs no tty, and
# does not run it. Verified in both directions on this host: a granted path and a
# nonexistent one return different exit codes.
# ---------------------------------------------------------------------------
sudo_permits() { sudo -n -l -- "$@" >/dev/null 2>&1; }

APP_BIN="$(command -v "$APP" 2>/dev/null)"
[ -n "$APP_BIN" ] || die "$(esc "$APP") is not installed."

# PROBE THE ARGV WE ARE ABOUT TO RUN, NOT JUST THE BINARY. A bare
# `NOPASSWD: /usr/bin/thunar` rule permits any arguments, so a full-argv probe
# succeeds under it too; but an administrator who writes the NARROWER and more
# defensible `NOPASSWD: /usr/bin/thunar /home/*` rule is invisible to a probe of
# the bare path, which then reports "no rule permits it" for a command sudo would
# happily run. The safest sudoers rule must not be the one this script misreads.
if ! sudo_permits "$APP_BIN" "$@"; then
    die "Administrator rights for <tt>$(esc "$APP_BIN")</tt> are not granted.\n\nsudo refused it without a password and no rule permits it for your account with these arguments.\n\nNothing was opened. An administrator can grant it in /etc/sudoers.d/."
fi

# ---------------------------------------------------------------------------
# THE ORACLE. AN EXIT CODE IS NOT ONE, AND THIS IS THE SECOND TIME THAT COST
# THIS MENU A SILENT FAILURE.
#
# A GUI launcher has three outcomes and only two of them are distinguishable by
# status: it stays up (good), it dies non-zero (bad), or IT DIES WITH STATUS 0.
# That third case is genuinely ambiguous. Thunar and mousepad are single-instance
# programs: asked to open a path while another instance of the same UID already
# runs, they hand the request over and exit 0 immediately, which is a SUCCESS.
# A misconfigured one that cannot reach the display can also print to stderr and
# exit 0, which is a FAILURE, and it is exactly the "nothing loads" the operator
# reported. Inverting the test would turn every legitimate second click into a
# false alarm, so the death case needs a real question instead: AFTER the child
# is gone, is there an instance of this program running as root?
#
# `pgrep -x` MATCHES `comm`, NOT THE PATH, AND comm IS NOT basename($APP_BIN).
# Measured on this host: /usr/bin/thunar runs with comm `Thunar`, so
# `pgrep -x thunar` returns EMPTY for a live Thunar while `pgrep -x -i thunar`
# finds it. A basename-derived matcher would have reported failure in EVERY
# world, including the working one, which is the "instrument that reads the same
# in two worlds" shape wearing the opposite sign. Hence `-i`, and hence the
# positive control in the test harness that asserts this matcher can see a real
# process at all.
# ---------------------------------------------------------------------------
APP_NAME="$(basename -- "$APP_BIN")"
root_instances() { pgrep -u 0 -x -i -- "$APP_NAME" 2>/dev/null | tr '\n' ' '; }

announce() {
    notify-send -i "$ICON" "Open as Root" "$(esc "$APP_NAME") opened as root" 2>/dev/null || true
}

ERR="$(mktemp)"
# `XAUTHORITY` IS EXPORTED INTO THE PRIMARY CALL, not merely computed. It was
# resolved above (falling back to $HOME/.Xauthority when the variable is unset)
# and then went unused on this path, so on a session where XAUTHORITY is unset
# but the file exists, root got DISPLAY and no cookie and died with "cannot open
# display". The `Defaults!<app> env_keep += "DISPLAY XAUTHORITY"` lines this
# payload ships are what carry it across sudo's env_reset.
if [ -n "$XAUTH" ]; then
    XAUTHORITY="$XAUTH" sudo -n "$APP_BIN" "$@" >/dev/null 2>"$ERR" &
else
    sudo -n "$APP_BIN" "$@" >/dev/null 2>"$ERR" &
fi
CHILD=$!

# Give it a moment to fail. A GUI that cannot open the display dies at once,
# and that is precisely the failure the old menu entry hid.
sleep 1.5
if ! kill -0 "$CHILD" 2>/dev/null; then
    wait "$CHILD" 2>/dev/null
    RC=$?
    # THE STALE-INSTANCE RESIDUAL, AND WHY THE F2 REMEDY IS THE WRONG ONE HERE.
    # root_instances() is EXISTENCE-based with no BEFORE-sample, which is the
    # defect fixed on the sandbox path in F2. It is NOT fixable the same way.
    # MEASURED on <lab-host>, 2026-08-26: a genuine root hand-off leaves the
    # root instance at the SAME pid it had before the click (3840108 before and
    # after), because the new process talks to the live instance and exits. So a
    # "must be a NEW pid" guard would make every legitimate second click fail,
    # which is the false alarm this script already refused once by not inverting
    # the exit-status test.
    # The discriminator that does work is stderr, which is captured above and was
    # being discarded on this branch. MEASURED in both directions on the same
    # host: a true hand-off wrote 0 bytes (user-level and root), and a launch that
    # could not reach the display wrote 321 bytes. So the added condition cannot
    # break a hand-off and it strictly narrows the quiet-success branch.
    # STATED PLAINLY, because this does not close the hole: the display failure I
    # measured exited rc=1, which the code below already catches. I did NOT
    # reproduce a failure that is rc=0 AND talking, so the world this guard
    # defends against is unreproduced on this hardware rather than proven. A
    # failure that is simultaneously rc=0, silent, and accompanied by a
    # pre-existing root instance remains indistinguishable from a hand-off by
    # process inspection alone; separating those needs a window oracle, and per
    # Kodachi-Dock-Playbook 25.2 wmctrl is installed on none of this PC, .198 or
    # .173, so it is not measurable today.
    if [ "$RC" -eq 0 ] && [ ! -s "$ERR" ] && [ -n "$(root_instances)" ]; then
        # Died at once, status 0, said nothing, and a root instance of this
        # program is running: the single-instance hand-off. Quiet success, and no
        # second dialog.
        unlink "$ERR" 2>/dev/null || true
        announce
        exit 0
    fi
    MSG="$(head -c 400 "$ERR" 2>/dev/null)"
    unlink "$ERR" 2>/dev/null || true
    # FALLBACK, for a machine whose /etc/sudoers.d predates the two
    # `Defaults!<app> env_keep += "DISPLAY XAUTHORITY"` lines this payload
    # ships. There the primary form starts and dies with "cannot open
    # display", so retry through `env` ONLY when sudoers actually permits
    # `env`. On the shipped product it does not, and this branch is skipped
    # rather than producing a second silent failure.
    if sudo_permits /usr/bin/env; then
        ERR2="$(mktemp)"
        if [ -n "$XAUTH" ]; then
            sudo -n /usr/bin/env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTH" "$APP_BIN" "$@" >/dev/null 2>"$ERR2" &
        else
            sudo -n /usr/bin/env DISPLAY="$DISPLAY" "$APP_BIN" "$@" >/dev/null 2>"$ERR2" &
        fi
        CHILD2=$!
        sleep 1.5
        if kill -0 "$CHILD2" 2>/dev/null; then
            unlink "$ERR2" 2>/dev/null || true
            announce
            exit 0
        fi
        wait "$CHILD2" 2>/dev/null
        RC2=$?
        # Same stale-instance narrowing as the primary branch above.
        if [ "$RC2" -eq 0 ] && [ ! -s "$ERR2" ] && [ -n "$(root_instances)" ]; then
            unlink "$ERR2" 2>/dev/null || true
            announce
            exit 0
        fi
        # DO NOT CLOBBER THE PRIMARY DIAGNOSTIC WITH AN EMPTY FALLBACK. This
        # assignment used to be unconditional, which destroyed the only useful
        # message in the exact case the fallback exists to serve: the primary
        # form writes "cannot open display", the `env` retry then dies rc2=0 and
        # SILENT, MSG becomes "", and the dialog below reports "No error output
        # was produced." That is worse than saying nothing, because it asserts
        # the program was quiet when it was not, and it defeats the whole point
        # of the rc=0 wording work below. The fallback's own message is better
        # when it HAS one, so prefer it only then.
        MSG2="$(head -c 400 "$ERR2" 2>/dev/null)"
        [ -n "$MSG2" ] && MSG="$MSG2"
        unlink "$ERR2" 2>/dev/null || true
    fi
    HINT=""
    [ -z "$XAUTH" ] && HINT="\n\nNo X authority file was found (XAUTHORITY is unset and $(esc "$HOME")/.Xauthority does not exist), so root was given DISPLAY but no cookie. That is the most likely cause."
    # SAY ONLY WHAT WAS CHECKED. The rc=0 branch is reached when the quiet-success
    # test above failed, and that test has TWO conjuncts, so rc=0 splits into two
    # different worlds that need two different sentences:
    #
    #   no root instance   -> it really did fail, and nothing would have said so.
    #   a root instance IS running, but the launch talked -> AMBIGUOUS. It is
    #     either the single-instance hand-off emitting a benign warning (root
    #     GUIs routinely do: a11y bus unreachable, canberra-gtk-module, theme
    #     parse noise, and `-s` trips on ONE byte), or a real failure alongside a
    #     STALE root instance from an earlier click. Process inspection cannot
    #     separate those: the hand-off reuses the SAME pid, so a before/after
    #     sample is identical in both worlds, and the window oracle that could
    #     separate them needs wmctrl, absent on this PC, .198 and .173.
    #
    # The previous wording asserted "no <app> is running as root" on BOTH, which
    # is a claim this branch never evaluated. It is re-sampled here rather than
    # inferred. Ambiguity is reported as ambiguity, and the launch is still not
    # announced as a success, so the stale-instance defect stays closed.
    # THE rc=0 SPLIT IS THREE-WAY, NOT TWO-WAY, AND THE THIRD WORLD IS THE ONE
    # THAT MADE THE PREVIOUS WORDING WRONG AGAIN. Reaching here with rc=0 means
    # the quiet-success test at the top failed, and it has TWO conjuncts, so:
    #
    #   ERR was non-empty            -> MSG is set, an instance may or may not exist
    #   ERR was empty but NO instance-> MSG is EMPTY, and an instance may have
    #                                   appeared since (the sample below is taken
    #                                   later, and the `env` fallback may itself
    #                                   have started one)
    #
    # So "an instance is running" does NOT imply "it wrote to its error output".
    # The first branch asserted exactly that, on a test that never re-checked
    # stderr, and would have printed "writing to its error output" immediately
    # followed by "No error output was produced." Gate it on MSG, and give the
    # silent-with-an-instance world its own honest sentence rather than letting
    # it fall through to the "no instance is running" branch, which is a claim
    # this sample directly contradicts.
    INST="$(root_instances)"
    if [ "$RC" -eq 0 ] && [ -n "$INST" ] && [ -n "$MSG" ]; then
        die "$(esc "$APP") exited immediately as root, reporting success but also writing to its error output.\n\nA $(esc "$APP_NAME") IS already running as root (pid $(esc "$INST")), so this may have been handed to that window instead of opening a new one. Check whether it is showing what you selected.\n\n$(esc "$MSG")$HINT"
    fi
    if [ "$RC" -eq 0 ] && [ -n "$INST" ]; then
        die "$(esc "$APP") exited immediately as root, reporting success and producing no error output.\n\nA $(esc "$APP_NAME") IS running as root (pid $(esc "$INST")), so this was most likely handed to that window instead of opening a new one. Check whether it is showing what you selected.\n\nIf that window is not showing what you selected, it is a leftover from an earlier click and this launch did nothing.$HINT"
    fi
    if [ "$RC" -eq 0 ]; then
        die "$(esc "$APP") exited immediately as root without starting, and no $(esc "$APP_NAME") is running as root.\n\nIt reported success, so nothing would have told you it failed.\n\n$(esc "${MSG:-No error output was produced.}")$HINT"
    fi
    die "$(esc "$APP") exited immediately as root (status $RC).\n\n$(esc "${MSG:-No error output was produced.}")$HINT"
fi
unlink "$ERR" 2>/dev/null || true
# THE SUCCESS PATHS ALL SPEAK. Previously only the fallback notified, so the
# common case was the silent one and the rare case was the loud one.
announce
exit 0
