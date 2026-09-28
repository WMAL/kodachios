#!/usr/bin/env bash

# conky-watchdog.sh
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
# Description:
# Health watchdog for Kodachi Conky panels.
# Verifies panel process count and requests a controlled launcher restart
# when panel count is outside configured bounds for consecutive checks.

set -euo pipefail

LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/kodachi-conky-watchdog.lock"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kodachi"
LOG_FILE="$LOG_DIR/conky-watchdog.log"
CHECK_INTERVAL="${CONKY_WATCHDOG_INTERVAL:-5}"
EXPECTED_PANELS="${CONKY_EXPECTED_PANELS:-5}"
MIN_PANELS="${CONKY_MIN_PANELS:-3}"
MAX_PANELS="${CONKY_MAX_PANELS:-6}"
RESTART_AFTER_MISSES="${CONKY_RESTART_AFTER_MISSES:-2}"
RESTART_COOLDOWN="${CONKY_RESTART_COOLDOWN:-20}"
LOG_MAX_BYTES="${CONKY_WATCHDOG_LOG_MAX_BYTES:-1048576}"

# --- C1: panel PLACEMENT verification ------------------------------------
# A panel can be born at the wrong position (observed on the live ISO: the
# SYSTEM panel at X=521 Y=0 instead of X=3131 Y=25, overprinting the
# focus-alert HUD, leaving ~12 lines of both illegible). The race that causes
# it is intermittent and its mechanism is still unknown, but the reason a USER
# ever sees it is separate and fully understood: NOTHING corrected it. This
# watchdog checked only the panel COUNT, and no other script repositions a
# panel after launch, so one bad placement persisted for the whole session.
#
# Y is the diagnostic number. Every panel config uses gap_y >= 10 (measured
# across all seven conkyrc files: 18, 30, 30, 30, 330, 10, 30) and none uses
# 0, so a mapped panel sitting at Y < MIN_PANEL_Y cannot be a legitimate
# placement for ANY panel. That is what makes this predicate safe to act on.
MIN_PANEL_Y="${CONKY_MIN_PANEL_Y:-5}"
# Ignore windows still being created: conky maps a tiny placeholder first
# (4x4 and 7x7 observed mid-launch) and those legitimately sit at odd spots.
MIN_PANEL_WIDTH="${CONKY_MIN_PANEL_WIDTH:-50}"
MISPLACED_AFTER_MISSES="${CONKY_MISPLACED_AFTER_MISSES:-2}"
# Escape hatch, and the sabotage arm for testing this feature.
PLACEMENT_CHECK="${CONKY_PLACEMENT_CHECK:-1}"

mkdir -p "$LOG_DIR"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local size=0
    if [[ -f "$LOG_FILE" ]]; then
        size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        [[ "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]] || LOG_MAX_BYTES=1048576
        (( LOG_MAX_BYTES < 1024 )) && LOG_MAX_BYTES=1024
        if (( size >= LOG_MAX_BYTES )); then
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        fi
    fi
    echo "[$(timestamp)] $*" >> "$LOG_FILE"
}

# Prevent duplicate watchdog processes when autostart/systemd trigger together.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another conky-watchdog instance is already running; exiting"
        exit 0
    fi
fi

launcher=""
for candidate in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/kodachi/conky/scripts/conky-launcher.sh" \
    "$HOME/.config/kodachi/conky/scripts/conky-launcher.sh" \
    "$HOME/k900/livebuild-assets/conky/scripts/conky-launcher.sh"; do
    if [[ -x "$candidate" ]]; then
        launcher="$candidate"
        break
    fi
done

if [[ -z "$launcher" ]]; then
    log "ERROR: conky-launcher.sh not found"
    exit 1
fi

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

# Flag to signal clean shutdown, prevents restart loop during logout/poweroff.
SHUTTING_DOWN=0

count_kodachi_conky() {
    # Count only THIS user's panels. A global pgrep also counts conky panels
    # owned by other logged-in users (e.g. a second desktop session), which can
    # push the total above MAX_PANELS and trigger an endless restart loop
    # (panels flicker: disappear and reappear every cooldown). Scope by UID.
    #
    # AND COUNT ONLY REAL conky PROCESSES, NOT COMMAND LINES THAT MENTION ONE.
    # The old body was a single `pgrep -af "conky .*kodachi.*conkyrc-.*\.conf"`,
    # i.e. an argv substring match. Measured on the operator's PC on 2026-09-05:
    # an agent's shell running a command whose TEXT contained that pattern (a
    # `pgrep -af "conky .*conkyrc"` probe, a `bash -c` wrapper quoting a conky
    # invocation) was counted as a panel. Five real panels plus two such shells
    # read 7, above MAX_PANELS, and this watchdog restarted the operator's whole
    # desktop HUD five times in fifteen minutes with the panels perfectly healthy.
    # Any process of this uid whose argv merely mentions a conky config could do
    # it: a text editor open on a conf, a grep, a log viewer.
    #
    # `pgrep -x conky` matches the process NAME (comm), which only an executable
    # called conky carries; the cmdline is then read from /proc to keep the
    # Kodachi-runtime filter, so a user's own unrelated conky is still excluded.
    local pid cmdline n=0
    for pid in $(pgrep -u "$(id -u)" -x conky 2>/dev/null); do
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cmdline" =~ kodachi.*conkyrc-.*\.conf ]] && n=$((n + 1))
    done
    echo "$n"
}

# Count panels sitting at an impossible Y coordinate (see MIN_PANEL_Y above).
# Reads absolute geometry from xwininfo rather than xdotool: conky panels do
# NOT come back from `xdotool search --classname conky` (measured, 0 results
# while 5 panels were on screen), but they are present in the root tree as
# ("Conky" "Conky"). Never fails the script under `set -e`.
# ---------------------------------------------------------------------------
# PER-PANEL PRESENCE, because a COUNT cannot see WHICH panel died.
#
# THE DEFECT THIS EXISTS FOR. The healthy band is MIN_PANELS=3..MAX_PANELS=6 for
# EXPECTED_PANELS=5, so losing one panel leaves 4, which is inside the band, and
# the watchdog whose entire job is to put panels back calls that healthy and does
# nothing for the rest of the session. Measured by <agent> on the <lab-host>
# live ISO: killed the gauges panel, count went 5 -> 4, and at t+3s, t+15s and
# t+35s it was still 4 with NO new line in the watchdog log for 90 minutes. Two
# dead panels would also be tolerated.
#
# WHY THE BAND IS NOT JUST WIDENED TO 5, and this is the trap: the band is
# deliberate. The comment in count_kodachi_conky above, commit f18dd39d
# (2026-07-15) and RULE 16 in the Conky playbook all record restart LOOPS caused
# by the count reading HIGH, and the tolerance underneath is what damps a
# transient. Raising MIN_PANELS to 5 would make every momentary respawn gap a
# restart. So the fix is to stop asking "how many" and start asking "which".
#
# THE EXPECTED SET IS READ FROM THE LAUNCHER, NEVER HARDCODED HERE. Two lists of
# panel names in two files is a drift bug waiting to happen, and this codebase has
# already paid for that shape more than once today. conky-launcher.sh carries the
# canonical `panels=( ... )` array; this parses that array. If it cannot be read
# for any reason the function returns EMPTY and every caller falls back to the
# existing count-based band, so an unreadable launcher degrades to today's
# behaviour rather than to a restart loop.
expected_panel_configs() {
    local launcher="$1"
    [[ -n "$launcher" && -r "$launcher" ]] || return 0
    awk '
        /^[[:space:]]*local[[:space:]]+panels=\(/ { inarr = 1; next }
        inarr && /^[[:space:]]*\)/                { exit }
        inarr {
            line = $0
            gsub(/[",]/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^conkyrc-.*\.conf$/) print line
        }
    ' "$launcher" 2>/dev/null
}

# The config basenames that currently have a LIVE conky, one per line.
# Same uid scoping and same real-process rule as count_kodachi_conky: a shell
# whose argv merely mentions a conf is not a panel (RULE 16).
live_panel_configs() {
    local pid cmdline base
    for pid in $(pgrep -u "$(id -u)" -x conky 2>/dev/null); do
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cmdline" =~ kodachi.*conkyrc-.*\.conf ]] || continue
        base=$(printf '%s\n' "$cmdline" | grep -oE 'conkyrc-[A-Za-z0-9_-]+\.conf' | head -1)
        [[ -n "$base" ]] && printf '%s\n' "$base"
    done | sort -u
}

# Names the panels that are expected but not live. Empty when the expected set
# cannot be determined, which is what keeps this fail-safe.
missing_panel_configs() {
    local launcher="$1" expected live
    expected="$(expected_panel_configs "$launcher")"
    [[ -n "$expected" ]] || return 0
    live="$(live_panel_configs)"
    comm -23 <(printf '%s\n' "$expected" | sort -u) <(printf '%s\n' "$live") 2>/dev/null
}

count_misplaced_panels() {
    if [[ "$PLACEMENT_CHECK" != "1" ]]; then
        echo 0
        return 0
    fi
    command -v xwininfo >/dev/null 2>&1 || { echo 0; return 0; }

    # THIS FUNCTION MUST PRINT EXACTLY ONE INTEGER ON ONE LINE. Its caller feeds
    # the value straight into `(( misplaced > 0 ))`, and bash arithmetic cannot
    # parse a two-line value.
    #
    # Measured on the <lab-host> beta live ISO, 2026-09-04 10:07:49, VM .224:
    #   conky-watchdog.sh: line 249: ((: 0
    #   0: syntax error in expression (error token is "0")
    # The old body ended the pipeline with `|| echo 0` while awk's own
    # `END { print c + 0 }` had ALREADY printed 0. `set -o pipefail` is in force
    # (line 21), and `grep` exits 1 whenever no Conky window is currently mapped,
    # which promotes the whole pipeline to non-zero, so BOTH producers fired and
    # the value became "0\n0". Reproduced byte-identically before fixing.
    # Consequence was not cosmetic: `(( ))` returns non-zero on a syntax error, so
    # the placement branch fell through to `misplaced_streak=0` and the placement
    # watchdog stopped working for exactly the window where a panel is unmapped.
    #
    # Fix has two halves, both needed:
    #   1. awk is the ONLY producer of the number. grep's no-match status is
    #      neutralised INSIDE the pipeline so pipefail cannot see it.
    #   2. The result is normalised to a single non-negative integer before it is
    #      printed, so no future pipeline change can hand the caller a value that
    #      `(( ))` chokes on.
    local raw
    raw=$( (xwininfo -root -tree 2>/dev/null || true) \
        | { grep '("Conky"' || true; } \
        | awk -v miny="$MIN_PANEL_Y" -v minw="$MIN_PANEL_WIDTH" '
            {
                geom = $(NF-1); pos = $NF
                split(geom, g, "x"); w = g[1] + 0
                n = split(pos, p, "+")
                if (n >= 3 && w >= minw && (p[3] + 0) < miny) c++
            }
            END { print c + 0 }' 2>/dev/null ) || raw=""

    raw="${raw%%$'\n'*}"
    [[ "$raw" =~ ^[0-9]+$ ]] || raw=0
    printf '%s\n' "$raw"
}

# Check if the X display is still alive. Returns 1 if display is gone (shutdown/logout).
display_alive() {
    command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && return 0
    # Fallback: check if X11 socket exists
    local display_num="${DISPLAY#:}"
    display_num="${display_num%%.*}"
    [[ -S "/tmp/.X11-unix/X${display_num}" ]] && return 0
    return 1
}

restart_conky() {
    log "Restarting conky panels"
    "$launcher" --restart >> "$LOG_FILE" 2>&1 || log "ERROR: conky restart failed"
}

# On SIGTERM/SIGINT (systemd stop, logout, shutdown): kill conky children and exit.
#
# Two paths based on whether X is alive:
#   - X alive (user-triggered `systemctl --user stop` from health-control
#     conky-disable, dashboard, tray): SIGTERM first so conky can detach
#     from the X server cleanly. Abrupt SIGKILL while X is up leaves
#     dangling Window/Damage/Picture resources, which has been observed to
#     cascade into xfce4-panel exiting (status 0, looks like a clean quit
#     because the panel just sees its X connection go bad). Poll for up to
#     2s with 100ms granularity, then SIGKILL any stragglers, well within
#     the unit's TimeoutStopSec=5.
#   - X dying (logout/poweroff): SIGKILL immediately. conky's own SIGTERM
#     handler tries to draw to a dead display and segfaults; the historical
#     1-second wait here once allowed hundreds of segfaults to flood the
#     kernel log and stall session-2.scope for 90+ seconds.
cleanup_and_exit() {
    SHUTTING_DOWN=1
    if display_alive; then
        log "Watchdog received shutdown signal (X alive); SIGTERM conky panels first"
        pkill -x conky >/dev/null 2>&1 || true

        # Poll for clean exit (up to 2s in 100ms steps).
        local _waited=0
        while (( _waited < 20 )); do
            if ! pgrep -x conky >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
            _waited=$((_waited + 1))
        done

        # SIGKILL stragglers that ignored SIGTERM.
        if pgrep -x conky >/dev/null 2>&1; then
            log "Conky still alive after 2s SIGTERM; escalating to SIGKILL"
            pkill -9 -x conky >/dev/null 2>&1 || true
        fi
    else
        log "Watchdog received shutdown signal (X dying); SIGKILL conky immediately"
        pkill -9 -x conky >/dev/null 2>&1 || true
    fi
    pkill -9 -f conky-launcher >/dev/null 2>&1 || true
    log "Watchdog stopped (clean shutdown)"
    exit 0
}

trap cleanup_and_exit SIGTERM SIGINT SIGHUP
trap 'log "Watchdog stopped"' EXIT
log "Watchdog started (launcher=$launcher, display=$DISPLAY, expected_panels=$EXPECTED_PANELS, min_panels=$MIN_PANELS, max_panels=$MAX_PANELS, interval=${CHECK_INTERVAL}s)"

missing_streak=0
misplaced_streak=0
last_restart_ts=0

current_count="$(count_kodachi_conky)"
initial_missing="$(missing_panel_configs "$launcher" | tr '\n' ' ')"
initial_missing="${initial_missing% }"
if (( current_count < MIN_PANELS )) || (( current_count > MAX_PANELS )); then
    log "Initial conky count=${current_count} outside range ${MIN_PANELS}-${MAX_PANELS}; requesting restart"
    restart_conky
    last_restart_ts=$(date +%s)
elif [[ -n "$initial_missing" ]]; then
    log "Initial count=${current_count} is inside ${MIN_PANELS}-${MAX_PANELS} but these panels are NOT running: ${initial_missing}; requesting restart"
    restart_conky
    last_restart_ts=$(date +%s)
fi

while true; do
    # Abort immediately if shutdown was signalled
    if (( SHUTTING_DOWN )); then
        break
    fi

    # If X display is gone (logout/shutdown), stop instead of restart-looping
    if ! display_alive; then
        log "X display $DISPLAY is no longer available; stopping watchdog"
        pkill -x conky >/dev/null 2>&1 || true
        break
    fi

    current_count="$(count_kodachi_conky)"

    # A count inside the band is NOT proof every panel is alive. Ask which.
    # The repair is still the launcher's existing whole-set relaunch, because the
    # launcher computes per-panel geometry and has no single-panel entry point, and
    # a bare `conky -c` would place the panel wrong, which is the defect commit
    # 1b8c9019a and the misplaced_streak machinery exist for. So this changes
    # DETECTION, not the repair path: the repair is the same tested one that a
    # count-based trigger already uses.
    missing_named="$(missing_panel_configs "$launcher" | tr '\n' ' ')"
    missing_named="${missing_named% }"
    if (( current_count >= MIN_PANELS )) && (( current_count <= MAX_PANELS )) && [[ -n "$missing_named" ]]; then
        missing_streak=$((missing_streak + 1))
        log "Count ${current_count} is inside ${MIN_PANELS}-${MAX_PANELS} but these panels are NOT running: ${missing_named} (streak=${missing_streak}/${RESTART_AFTER_MISSES})"
        if (( missing_streak >= RESTART_AFTER_MISSES )); then
            restart_conky
            last_restart_ts=$(date +%s)
            missing_streak=0
        fi
        sleep "$CHECK_INTERVAL"
        continue
    fi
    if (( current_count < MIN_PANELS )) || (( current_count > MAX_PANELS )); then
        missing_streak=$((missing_streak + 1))
        log "Detected ${current_count} conky process(es); healthy range ${MIN_PANELS}-${MAX_PANELS} (streak=${missing_streak}/${RESTART_AFTER_MISSES})"

        if (( missing_streak >= RESTART_AFTER_MISSES )); then
            now_ts=$(date +%s)
            if (( now_ts - last_restart_ts >= RESTART_COOLDOWN )); then
                restart_conky
                last_restart_ts=$now_ts
                missing_streak=0
                sleep 2
            else
                log "Restart suppressed by cooldown (${RESTART_COOLDOWN}s)"
            fi
        fi
    else
        missing_streak=0

        # Placement check runs only when the panel COUNT is healthy, so a
        # restart is never attributed to the wrong cause and the two checks
        # cannot fight each other over the same cooldown.
        misplaced="$(count_misplaced_panels)"
        if (( misplaced > 0 )); then
            misplaced_streak=$((misplaced_streak + 1))
            log "Detected ${misplaced} conky panel(s) at Y<${MIN_PANEL_Y}; placement is invalid for every configured panel (streak=${misplaced_streak}/${MISPLACED_AFTER_MISSES})"
            if (( misplaced_streak >= MISPLACED_AFTER_MISSES )); then
                now_ts=$(date +%s)
                if (( now_ts - last_restart_ts >= RESTART_COOLDOWN )); then
                    log "Restarting to correct panel placement"
                    restart_conky
                    last_restart_ts=$now_ts
                    misplaced_streak=0
                    sleep 2
                else
                    log "Placement restart suppressed by cooldown (${RESTART_COOLDOWN}s)"
                fi
            fi
        else
            misplaced_streak=0
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
