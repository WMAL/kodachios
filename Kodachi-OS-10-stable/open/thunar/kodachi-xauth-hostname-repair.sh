#!/bin/bash

# Kodachi X authority hostname repair
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
# Re-files the existing X magic cookie under the CURRENT hostname, so a root or
# other-user GUI launched after a hostname change can still authorise to the
# running X server. Idempotent, additive, and safe to run as often as you like.
#
# WHY THIS EXISTS. Kodachi renames the machine for privacy AFTER X has already
# written the MIT-MAGIC-COOKIE, so the cookie is filed under a hostname that no
# longer exists:
#
#     kernel cmdline    hostname=kodachi
#     hostname now      OPPO-Find-X6        (Kodachi hostname spoofing)
#     ~/.Xauthority     kodachi/unix:0  MIT-MAGIC-COOKIE-1  <cookie>
#
# An X client resolves its cookie by the CURRENT hostname. It looks for
# `OPPO-Find-X6/unix:0`, the file holds `kodachi/unix:0`, so it presents NO
# authorization at all and the server answers "Authorization required, but no
# authorization protocol specified". The desktop user does not notice, because
# `xhost` separately carries SI:localuser:<user>, which lets them in with no
# cookie. Root is not in that list, so every root GUI dies with
# "cannot open display".
#
# MEASURED 2026-09-07 on <lab-host>, live ISO <lab-host>, four arms, one run,
# same binary, same display, and the SAME COOKIE VALUE in every arm. The X
# access-control grant for root was removed for the test and restored after, or
# the run would have been vacuous (it was, the first time: with
# SI:localuser:root present every arm connects, including the negative control):
#
#     A  root, entry named kodachi/unix:0        (what ships)   REFUSED
#     B  root, entry named OPPO-Find-X6/unix:0   (repaired)     CONNECTS
#     C  control, desktop user                                  CONNECTS
#     D  negative control, root, nonexistent cookie file        REFUSED
#
# Only the entry NAME differed between A and B. Independently reported by
# <agent> from <lab-host>, reproduced here on a different box.
#
# THERE IS NO HOSTNAME-INDEPENDENT ENTRY TO WRITE INSTEAD, which is why this is a
# repair and not a one-time change of the cookie's name. Measured in the same
# run, all five forms carrying the identical cookie value:
#
#     kodachi/unix:0        (ships)   REFUSED
#     <current>/unix:0                CONNECTS
#     unix:0                          CONNECTS, but xauth STORES it as
#                                     <current>/unix:0, so it is not portable,
#                                     it is the same thing written differently
#     FamilyWild #ffff#..#:0          not stored by xauth, REFUSED
#     localhost/unix:0                REFUSED
#
# So the cookie has to be re-filed whenever the hostname moves, and Kodachi can
# re-randomise the hostname at any time from the dock, not only at boot. Run this
# at session start AND immediately before escalating a GUI to another user.
#
# SECURITY NOTE, because "add an X cookie" reads alarming. This grants nothing
# new. It copies the value ALREADY IN THE CALLER'S OWN COOKIE FILE to a second
# name in that same file. Anyone who can read the file already holds the cookie,
# and the file's permissions are not touched. It is strictly a repair of a name
# that the hostname change invalidated.
#
# Usage: kodachi-xauth-hostname-repair.sh [--quiet]

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

command -v xauth >/dev/null 2>&1 || { say "xauth is not installed, nothing to repair."; exit 0; }
command -v hostname >/dev/null 2>&1 || { say "hostname is not available, nothing to repair."; exit 0; }

XAUTH_FILE="${XAUTHORITY:-$HOME/.Xauthority}"
[ -f "$XAUTH_FILE" ] || { say "No X authority file at $XAUTH_FILE, nothing to repair."; exit 0; }
[ -w "$XAUTH_FILE" ] || { say "X authority file is not writable by this user, nothing to repair."; exit 0; }

CURRENT_HOST="$(hostname 2>/dev/null)"
[ -n "$CURRENT_HOST" ] || { say "Could not read the current hostname, refusing to guess."; exit 0; }

# `xauth list` prints:  <name>  <protocol>  <hex cookie>
# Only /unix: displays are re-filed. A TCP entry names a real remote host and
# re-filing it under this machine's name would be wrong, not merely useless.
ADDED=0
SEEN=0
while read -r ENTRY PROTO COOKIE; do
    [ -n "${ENTRY:-}" ] && [ -n "${PROTO:-}" ] && [ -n "${COOKIE:-}" ] || continue
    case "$ENTRY" in
        */unix:*) ;;
        *) continue ;;
    esac
    SEEN=$((SEEN + 1))
    ENTRY_HOST="${ENTRY%%/*}"
    DISPLAY_PART="${ENTRY#*/}"          # unix:0
    [ "$ENTRY_HOST" = "$CURRENT_HOST" ] && continue
    TARGET="${CURRENT_HOST}/${DISPLAY_PART}"
    # Already repaired on an earlier run? Then this is a no-op, which is the
    # point: this script is expected to run on every session and every launch.
    if xauth -f "$XAUTH_FILE" list 2>/dev/null | awk '{print $1}' | grep -qxF "$TARGET"; then
        continue
    fi
    if xauth -f "$XAUTH_FILE" add "$TARGET" "$PROTO" "$COOKIE" >/dev/null 2>&1; then
        ADDED=$((ADDED + 1))
        say "Re-filed $ENTRY as $TARGET"
    else
        say "Could not re-file $ENTRY as $TARGET"
    fi
done <<EOF
$(xauth -f "$XAUTH_FILE" list 2>/dev/null)
EOF

if [ "$SEEN" -eq 0 ]; then
    say "No local (/unix:) entries found in $XAUTH_FILE, nothing to repair."
else
    say "Checked $SEEN local entry/entries, added $ADDED for hostname $CURRENT_HOST."
fi
exit 0
