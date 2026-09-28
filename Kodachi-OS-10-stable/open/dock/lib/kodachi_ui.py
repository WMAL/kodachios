#!/usr/bin/env python3
# Kodachi Command Windows - Design System
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
# The Kodachi dashboard's own design tokens, expressed as GTK3 CSS, plus the
# widget shell every command window shares. A command window and a dashboard
# panel are meant to be recognisably the same product, so nothing here is
# invented: every colour, radius, spacing step and font size is lifted from
#
#     dashboard/gui/kodachi-dashboard/src/lib/styles/tokens/colors.css
#     .../tokens/typography.css   .../tokens/spacing.css   .../tokens/effects.css
#
# Three things are adapted rather than copied, each a decision rather than drift:
#
# 1. FONTS. The dashboard asks for 'Orbitron' (display) and 'Fira Code' (mono).
#    Neither is on the ISO: overlays/gui-xfce/package-lists/gui-xfce.list.chroot
#    ships fonts-liberation, fonts-dejavu, fonts-noto-core, fonts-ubuntu and
#    fonts-noto-color-emoji. Display type is therefore Ubuntu with wide tracking
#    and mono is Ubuntu Mono. Naming Orbitron here would render as a silent
#    fontconfig fallback to something nobody chose.
#
# 2. FLUID TYPE. The dashboard sizes with clamp() against the viewport. GTK has
#    no viewport, so each clamp resolves to its lower bound, which is the size
#    the tokens were tuned to stay readable at.
#
# 3. GLOW. The token set keeps glows deliberately tiny, 0 0 4px at 0.08 alpha,
#    with the comment "for VM performance". Same values here, same reason: these
#    windows open on a software-rendered VM as often as on real hardware.

import html
import os
import re
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango  # noqa: E402

# ── tokens, verbatim from the dashboard where a direct equivalent exists ──
BG_PRIMARY = "#000000"
BG_SECONDARY = "#020202"
BG_ELEVATED = "#080808"
SURFACE = "#050505"
SURFACE_HOVER = "#080808"
SURFACE_ACTIVE = "#0a0a0a"

BORDER_SUBTLE = "rgba(159, 239, 0, 0.08)"
BORDER_DEFAULT = "rgba(159, 239, 0, 0.16)"
BORDER_STRONG = "rgba(159, 239, 0, 0.28)"

TEXT_PRIMARY = "#f0f0f0"
TEXT_SECONDARY = "#bce89b"
TEXT_TERTIARY = "#a6e07a"
TEXT_QUATERNARY = "#6f8a52"
TEXT_DISABLED = "#5f7a48"
TEXT_ACCENT = "#9fef00"
TEXT_INVERSE = "#000000"

BRAND = "#84cc16"
BRAND_CYAN = "#35e6d4"
SUCCESS = "#84cc16"
WARNING = "#ffcc00"
ERROR = "#ff3333"
INFO = "#35e6d4"
STATUS_INACTIVE = "#555555"

FONT_SANS = "Ubuntu, 'Noto Sans', 'DejaVu Sans', sans-serif"
FONT_MONO = "'Ubuntu Mono', 'DejaVu Sans Mono', 'Liberation Mono', monospace"

CSS = f"""
/* ── ground ─────────────────────────────────────────────────────────── */
window.kodachi {{
    background-color: {BG_PRIMARY};
    font-family: {FONT_SANS};
    color: {TEXT_PRIMARY};
}}
.root {{ background-color: {BG_PRIMARY}; }}

/* ── header: a brand rule, a title, a subtitle ───────────────────────── */
.hdr {{
    background-image: linear-gradient(135deg, rgba(132, 204, 22, 0.12), rgba(53, 230, 212, 0.10));
    background-color: {BG_SECONDARY};
    border-bottom: 1px solid {BORDER_DEFAULT};
    padding: 18px 24px 16px 24px;
}}
.hdr-rule {{
    background-image: linear-gradient(180deg, {TEXT_ACCENT}, {BRAND_CYAN});
    border-radius: 2px;
    min-width: 3px;
}}
.hdr-title {{
    color: {TEXT_PRIMARY};
    font-family: {FONT_SANS};
    font-size: 19px;
    font-weight: 700;
    letter-spacing: 0.6px;
}}
.hdr-sub {{ color: {TEXT_QUATERNARY}; font-size: 13px; }}

/* ── the live-state strip under the header ───────────────────────────── */
.state {{
    background-color: {SURFACE};
    border: 1px solid {BORDER_SUBTLE};
    border-radius: 8px;
    padding: 10px 14px;
}}
/* NO `letter-spacing` HERE, and its absence is a MEASUREMENT fix rather
   than a styling preference. See NO_LETTER_SPACING_CLASSES below. */
.state-fact {{
    font-size: 11px;
    font-weight: 700;
}}

/* ── section captions ────────────────────────────────────────────────── */
.section {{
    color: {TEXT_ACCENT};
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 1.6px;
    padding: 20px 26px 8px 26px;
}}
.section-note {{ color: {TEXT_QUATERNARY}; font-size: 12px; padding: 0 26px 6px 26px; }}

/* ── cards hold rows ─────────────────────────────────────────────────── */
.card {{
    background-color: {SURFACE};
    border: 1px solid {BORDER_SUBTLE};
    border-radius: 12px;
    margin: 0 22px;
}}
.row {{
    padding: 11px 16px;
    border-bottom: 1px solid rgba(159, 239, 0, 0.05);
    background-color: transparent;
}}
.row:last-child {{ border-bottom-width: 0; }}
.row:hover {{ background-color: {SURFACE_HOVER}; }}
.row.sel {{ background-color: rgba(132, 204, 22, 0.10); }}

.row-name {{ color: {TEXT_PRIMARY}; font-size: 15px; }}
.row-name.dim {{ color: {TEXT_DISABLED}; }}
.row-note {{ color: {TEXT_QUATERNARY}; font-size: 12px; }}
.row-code {{ color: {TEXT_DISABLED}; font-family: {FONT_MONO}; font-size: 12px; }}

/* ── status pills ────────────────────────────────────────────────────── */
/* NO `letter-spacing` HERE either, same reason as `.state-fact` above: a
   `.pill` ellipsizes, so a mismeasured natural width clips it.
   See NO_LETTER_SPACING_CLASSES. */
.pill {{
    font-size: 11px;
    font-weight: 700;
    border-radius: 999px;
    padding: 3px 10px;
    border: 1px solid transparent;
}}
.pill.on   {{ color: {SUCCESS}; background-color: rgba(132, 204, 22, 0.12); border-color: rgba(132, 204, 22, 0.42); }}
.pill.off  {{ color: {STATUS_INACTIVE}; background-color: rgba(136, 136, 136, 0.10); border-color: rgba(136, 136, 136, 0.30); }}
.pill.warn {{ color: {WARNING}; background-color: rgba(255, 204, 0, 0.10); border-color: rgba(255, 204, 0, 0.40); }}
.pill.err  {{ color: {ERROR}; background-color: rgba(255, 51, 51, 0.10); border-color: rgba(255, 51, 51, 0.40); }}
/* `danger` is the name set_pill()'s PILL_TONES has always used and the CSS never
   defined, so a pill asked for the most alarming tone in the product came out
   with NO background and NO border at all: the one value that had to shout was
   the only one that whispered. Measured on the Connect tab, where dante's
   "Security 1/10" rendered flat while "Security 10/10" beside it was a filled
   green pill. Same declaration as `err`, so both names work. */
.pill.danger {{ color: {ERROR}; background-color: rgba(255, 51, 51, 0.10); border-color: rgba(255, 51, 51, 0.40); }}
.pill.info {{ color: {INFO}; background-color: rgba(53, 230, 212, 0.12); border-color: rgba(53, 230, 212, 0.42); }}

/* ── numeric score dots ───────────────────────────────────────────────────────── */
.score-dots {{
    min-height: 22px;
}}
.score-label,
.score-ratio {{
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.3px;
}}
.score-label {{
    color: {TEXT_SECONDARY};
}}
.score-ratio.on   {{ color: {SUCCESS}; }}
.score-ratio.info {{ color: {INFO}; }}
.score-ratio.warn {{ color: {WARNING}; }}
.score-ratio.err,
.score-ratio.danger {{ color: {ERROR}; }}
.score-ratio.off  {{ color: {STATUS_INACTIVE}; }}
.score-dot {{
    font-size: 9px;
    min-width: 7px;
    color: rgba(136, 136, 136, 0.22);
}}
.score-dot.filled.on   {{ color: {SUCCESS}; }}
.score-dot.filled.info {{ color: {INFO}; }}
.score-dot.filled.warn {{ color: {WARNING}; }}
.score-dot.filled.err,
.score-dot.filled.danger {{ color: {ERROR}; }}
.score-dot.filled.off  {{ color: {STATUS_INACTIVE}; }}

/* ── switches ────────────────────────────────────────────────────────── */
switch {{
    background-color: {BG_ELEVATED};
    border: 1px solid rgba(159, 239, 0, 0.14);
    border-radius: 999px;
    min-width: 46px;
    min-height: 24px;
}}
switch:checked {{
    background-color: rgba(132, 204, 22, 0.28);
    border-color: {BRAND};
    box-shadow: 0 0 4px rgba(0, 255, 0, 0.20);
}}
switch slider {{
    background-color: {TEXT_QUATERNARY};
    border-radius: 999px;
    min-width: 18px;
    min-height: 18px;
    margin: 2px;
}}
switch:checked slider {{ background-color: {TEXT_ACCENT}; }}
switch:disabled {{ opacity: 0.4; }}
/* ── A SWITCH WHOSE STATE COULD NOT BE READ ──────────────────────────────
   A Gtk.Switch has exactly two looks, on and off, and it defaults to off. So
   a row whose state probe was REFUSED sat there drawn identically to a row
   that is genuinely disabled, and the pill saying "sign-in needed" three
   inches away did not undo that. The operator read it exactly the way it is
   drawn, 2026-08-23: he set two Tuning controls on, reopened the Network
   window, saw both switches off and reported that his settings were not
   saved. Nothing had been unsaved; the READ was refused and the widget fell
   back to its default, which is a definite claim it had no right to make.
   Dashed and faded says "no answer", which is what actually happened. */
switch.unknown {{
    opacity: 0.5;
    border: 1px dashed {TEXT_DISABLED};
    background-color: transparent;
}}
switch.unknown slider {{ background-color: {TEXT_DISABLED}; }}

/* ── radios ──────────────────────────────────────────────────────────── */
radio {{
    background-color: {BG_ELEVATED};
    border: 1px solid rgba(159, 239, 0, 0.20);
    min-width: 16px;
    min-height: 16px;
}}
radio:checked {{
    background-color: {TEXT_ACCENT};
    border-color: {TEXT_ACCENT};
    box-shadow: 0 0 4px rgba(0, 255, 0, 0.20);
}}
check {{
    background-color: {BG_ELEVATED};
    border: 1px solid rgba(159, 239, 0, 0.20);
    border-radius: 4px;
}}
check:checked {{ background-color: {TEXT_ACCENT}; border-color: {TEXT_ACCENT}; }}

/* ── buttons ─────────────────────────────────────────────────────────── */
button {{
    background-image: none;
    text-shadow: none;
    font-size: 14px;
    border-radius: 8px;
    padding: 9px 20px;
}}
button.primary {{
    background-color: {TEXT_ACCENT};
    color: {TEXT_INVERSE};
    font-weight: 700;
    border: 1px solid {TEXT_ACCENT};
    box-shadow: 0 0 4px rgba(0, 255, 0, 0.20);
}}
button.primary:hover {{ background-color: #b6ff1a; border-color: #b6ff1a; }}
button.primary:disabled {{ background-color: {SURFACE_ACTIVE}; color: {TEXT_DISABLED};
                           border-color: {BORDER_SUBTLE}; box-shadow: none; }}
button.ghost {{
    background-color: transparent;
    color: {TEXT_TERTIARY};
    border: 1px solid {BORDER_DEFAULT};
}}
button.ghost:hover {{ border-color: {BORDER_STRONG}; color: {TEXT_ACCENT};
                      background-color: {SURFACE_HOVER}; }}
/* ── TOGGLES ARE ON/OFF CONTROLS AND MUST LOOK LIKE ONE ──────────────────
   Keep, Wrap and Follow are Gtk.ToggleButton, but this sheet carried no
   `:checked` rule of any kind for `button`, so an ON toggle painted exactly
   the same pixels as an OFF one: same transparent fill, same border, same
   colour. The operator reported them as "plain buttons", which is precisely
   what they looked like. Five controls across three files were affected
   (ResultPanel keep/wrap, the command window's wrap, the Repository Manager's
   log wrap and follow), so the fix belongs here in the shared sheet and not
   at any one of them.
   Colour is not the only channel: `state_toggle()` below also puts a filled
   or hollow marker in the label, so the state survives a colourblind reader
   and a greyscale screenshot.

   SCOPED TO A CLASS `state_toggle()` ADDS, not to `button:checked`. My first
   version used the bare `button:checked` selector, which <agent> caught:
   that matches EVERY checked button in every window that imports this sheet,
   including radio buttons and any toggle nobody routed through the helper, so a
   comment claiming a five-control blast radius sat over a selector with an
   unbounded one. Only controls that opt in through `state_toggle()` are
   restyled now, which makes the scope exactly what the comment says it is. */
button.statetoggle:checked {{
    background-color: {TEXT_ACCENT};
    color: {TEXT_INVERSE};
    border: 1px solid {TEXT_ACCENT};
    font-weight: 700;
}}
button.statetoggle:checked:hover {{ background-color: #b6ff1a;
                                    border-color: #b6ff1a;
                                    color: {TEXT_INVERSE}; }}
button.danger {{
    background-color: rgba(255, 51, 51, 0.10);
    color: {ERROR};
    border: 1px solid rgba(255, 51, 51, 0.40);
}}
button.danger:hover {{ background-color: rgba(255, 51, 51, 0.18); }}
button.chip {{
    padding: 5px 12px;
    font-size: 12px;
    border-radius: 999px;
    background-color: {BG_ELEVATED};
    color: {TEXT_TERTIARY};
    border: 1px solid {BORDER_SUBTLE};
}}
button.chip:hover {{ border-color: {BORDER_STRONG}; color: {TEXT_ACCENT}; }}

/* ── footer ──────────────────────────────────────────────────────────── */
.cmd {{
    color: {TEXT_DISABLED};
    font-family: {FONT_MONO};
    font-size: 12px;
    padding: 12px 26px 0 26px;
}}
.footer {{
    background-color: {BG_SECONDARY};
    border-top: 1px solid {BORDER_DEFAULT};
    padding: 14px 22px;
}}

/* ── search ──────────────────────────────────────────────────────────── */
entry.search {{
    background-color: {SURFACE};
    border: 1px solid {BORDER_SUBTLE};
    border-radius: 8px;
    color: {TEXT_PRIMARY};
    padding: 8px 12px;
    font-size: 14px;
}}
entry.search:focus {{ border-color: {BORDER_STRONG}; box-shadow: 0 0 4px rgba(0, 255, 0, 0.15); }}

/* ── scrollbars, slim and on-brand ───────────────────────────────────── */
scrollbar {{ background-color: transparent; border: none; }}
scrollbar slider {{
    background-color: rgba(159, 239, 0, 0.22);
    border-radius: 999px;
    min-width: 7px;
    margin: 3px;
}}
scrollbar slider:hover {{ background-color: rgba(159, 239, 0, 0.42); }}

/* ── monospace output, for the windows that print a report ───────────── */
.mono {{
    font-family: {FONT_MONO};
    font-size: 13px;
    color: {TEXT_SECONDARY};
}}
tooltip {{ background-color: {BG_ELEVATED}; color: {TEXT_PRIMARY};
           border: 1px solid {BORDER_DEFAULT}; border-radius: 8px; }}


/* ── the inline result panel ────────────────────────────────────────────
   An answer belongs in the window you asked from. Before this, every report row
   opened its OWN Gtk.Window, so five clicks meant five windows and the newest
   answer could land behind the control that produced it. */
.result {{
    background-color: {BG_SECONDARY};
    border-top: 1px solid {BORDER_DEFAULT};
}}
.result-hdr {{
    background-color: {SURFACE};
    border-bottom: 1px solid {BORDER_SUBTLE};
    padding: 8px 14px;
}}
/* NO `letter-spacing`: `result-title` ELLIPSIZES (it is in
   ELLIPSIZE_TEXT_CLASSES), so spacing clips it. This one survived my first
   pass, which drained .state-fact and .pill and then DECLARED THE CLASS
   CLOSED while a third member still carried it. Found by <agent>,
   2026-08-30. See NO_LETTER_SPACING_CLASSES. */
.result-title {{ color: {TEXT_ACCENT}; font-size: 12px; font-weight: 700; }}
.result-cmd {{ color: {TEXT_DISABLED}; font-family: {FONT_MONO}; font-size: 11px; }}
.result-body {{
    background-color: {BG_PRIMARY};
    font-family: {FONT_MONO};
    font-size: 12px;
    color: {TEXT_SECONDARY};
    padding: 10px 14px;
}}

/* ── scrollbars: OVERLAY sliders were drawing as grey blobs on the content ──
   The operator photographed two of them floating over a card with the pointer
   nowhere near ("why arrows shows like this when mouse is far"). GTK's overlay
   scrollbar draws an indicator on top of the content and our theme gave it a
   visible background, so it read as a stray widget rather than a scrollbar.
   Undershoot/overshoot and the junction get the same treatment. */
scrollbar, scrollbar.overlay-indicator {{
    background-color: transparent;
    border: none;
}}
scrollbar.overlay-indicator:not(.dragging):not(.hovering) {{ opacity: 0.20; }}
scrollbar trough {{ background-color: transparent; border: none; }}
overshoot, undershoot {{ background: none; box-shadow: none; }}
junction {{ background-color: transparent; }}

/* ── THE STEPPER ARROWS ARE ALWAYS VISIBLE, NEVER HOVER-REVEALED ────────
   Operator, screenshot a1: the stepper arrows appeared only while the pointer
   was over the bar. TWO independent mechanisms produce that, and fixing either
   one alone leaves the defect standing, which is why both are named here:

   1. THE ARROWS WERE NEVER DRAWN AT ALL. Adwaita ships all four stepper style
      properties false, and there is no widget API for them in GTK3: these
      `-GtkScrollbar-has-*-stepper` properties are the only way to ask.
   2. AN OVERLAY SCROLLBAR FADES ITSELF OUT WHOLESALE when the pointer leaves,
      arrows included. That half is NOT fixable from CSS, because the fade is a
      property of overlay mode rather than a style: `set_overlay_scrolling(False)`
      in the Python is what turns the bar into a permanent one that occupies
      real width. Both halves land together, see `_no_overlay_scroll()`.

   The `:not(.overlay-indicator)` guard on the colour rules keeps the 0.20
   opacity rule above applying only to a bar that is still in overlay mode, so
   a permanently-20%-transparent arrow can never be mistaken for "visible". */
scrollbar {{
    -GtkScrollbar-has-backward-stepper: true;
    -GtkScrollbar-has-forward-stepper: true;
}}
scrollbar button {{
    background-color: transparent;
    border: none;
    min-width: 13px;
    min-height: 13px;
    padding: 1px;
    color: rgba(159, 239, 0, 0.78);
}}
scrollbar button:hover {{ color: {TEXT_ACCENT}; background-color: {SURFACE}; }}
scrollbar button:disabled {{ color: rgba(159, 239, 0, 0.30); }}

/* ── the Kodachi mark in the window header ─────────────────────────────── */
.hdr-logo {{ margin-right: 4px; }}
/* ── tab strip, for a window that groups several surfaces ────────────────
   Used by Window(tabbed=True). A plain button row driving a Gtk.Stack, not a
   Gtk.Notebook: the Notebook's own tab rendering is themed by GTK and cannot be
   pushed all the way to these tokens, and every other control here is hand
   built for exactly that reason. */
.tabbar {{
    background-color: {SURFACE};
    border-bottom: 1px solid {BORDER_DEFAULT};
    padding: 8px 18px 0 18px;
}}
.tab {{
    background-color: transparent;
    background-image: none;
    color: {TEXT_QUATERNARY};
    border: 1px solid transparent;
    border-radius: 8px 8px 0 0;
    padding: 7px 15px;
    font-size: 12px;
    font-weight: 600;
    box-shadow: none;
    text-shadow: none;
}}
.tab:hover {{ color: {TEXT_TERTIARY}; background-color: {SURFACE_HOVER}; }}
.tab.active {{
    background-color: {BG_PRIMARY};
    color: {TEXT_ACCENT};
    border-color: {BORDER_DEFAULT};
    border-bottom-color: {BG_PRIMARY};
}}

/* ── Design 1: simple sidebar shell ────────────────────────────────────
   This is intentionally plain GTK3: boxes, buttons, borders and one stack.
   No browser-only layout, animation, transparency or GPU effect is required. */
.design1-shell {{ background-color: {BG_PRIMARY}; }}
.design1-content {{ background-color: {BG_PRIMARY}; }}
.design1-sidebar {{
    background-color: {BG_SECONDARY};
    border-right: 1px solid rgba(159, 239, 0, 0.12);
    padding: 16px 12px;
}}
.design1-brand {{
    border-bottom: 1px solid rgba(159, 239, 0, 0.12);
    padding: 0 6px 15px 6px;
}}
.design1-brand-name {{
    color: {TEXT_PRIMARY};
    font-size: 15px;
    font-weight: 700;
}}
.design1-brand-surface {{
    color: {TEXT_QUATERNARY};
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 1.2px;
}}
.design1-nav-heading {{
    color: {TEXT_ACCENT};
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 1.3px;
    padding: 12px 8px 5px 8px;
}}
button.design1-nav {{
    background-color: transparent;
    background-image: none;
    color: #73897b;
    border: 1px solid transparent;
    border-radius: 8px;
    padding: 8px 10px;
    box-shadow: none;
    text-shadow: none;
}}
button.design1-nav:hover {{
    color: {TEXT_SECONDARY};
    background-color: rgba(159, 239, 0, 0.04);
    border-color: rgba(159, 239, 0, 0.10);
}}
button.design1-nav.active {{
    color: #dfffb2;
    background-color: rgba(159, 239, 0, 0.09);
    border-color: rgba(159, 239, 0, 0.25);
}}
.design1-nav-label {{ font-size: 11px; font-weight: 700; }}
.design1-nav-icon {{ margin-right: 2px; }}
.design1-sidebar-status {{
    background-color: {SURFACE};
    border: 1px solid rgba(159, 239, 0, 0.12);
    border-radius: 9px;
    padding: 10px;
}}
.design1-sidebar-status-title {{
    color: {BRAND_CYAN};
    font-size: 9px;
    font-weight: 700;
    letter-spacing: 1px;
}}
.design1-sidebar-status-value {{
    color: {TEXT_PRIMARY};
    font-size: 12px;
    font-weight: 700;
}}
.design1-sidebar-status-note {{ color: #687c70; font-size: 10px; }}
.design1-content .hdr {{
    background-image: none;
    background-color: {BG_SECONDARY};
    padding: 14px 20px;
}}
.design1-content .card {{
    background-color: {SURFACE};
    border-color: rgba(159, 239, 0, 0.08);
    border-radius: 9px;
}}
.design1-content .footer {{ background-color: {BG_SECONDARY}; }}
.design1-content .state {{ background-color: {SURFACE}; }}
dialog {{ background-color: {BG_SECONDARY}; color: {TEXT_PRIMARY}; }}
"""


# The Kodachi mark, largest installed size first. Mirrors resolve_dock_icon() in
# kodachi-dock-action rather than hardcoding one path, so an image that ships
# only the small set still gets a branded window instead of falling back.
#
# THE FIRST TWO ARE THE SAME LOGO IN A DIFFERENT COLOUR, ON PURPOSE. A command
# window and the Tauri dashboard are different programs, and in a taskbar or an
# alt-tab list two identical green marks are indistinguishable. So the command
# windows wear the rank1 mark hue-rotated to BRAND_CYAN (#35e6d4), which is
# already a token in this file rather than an invented colour: same silhouette,
# same brand, unmistakably not the dashboard. Source is
# Desktop/social/ready/logo/kodachi-logos-ranked/rank1-ko-3d-bright-green, whose
# own README calls it "BEST ... use this one everywhere unless you have a reason
# not to", and differentiating two programs is that reason.
#
# Only genuinely green pixels are rotated (saturation > 0.15, hue in 0.15..0.45),
# so the chrome sword, the dark hood shading and the anti-aliased edges keep
# their original values instead of the whole image being tinted.
ICON_ROOT = os.environ.get("KODACHI_ICON_DIR", "/usr/share/kodachi/dock/icons")
# 128 BEFORE 256, AND THE ORDER IS A MEASUREMENT. With the 256px file as the
# process default icon, GTK 3 on X11 writes an EMPTY `_NET_WM_ICON` and only
# the legacy WM_HINTS pixmap, so anything that reads the modern property (a
# pager, alt-tab on another WM, a screenshot of the task list) shows no icon
# at all; with the 128px file first the property carries the 128x128 icon.
# Measured 2026-09-03 on <lab-host> with xprop on a bare Gtk.Window: 26
# bytes ("not found") for 256, a populated "Icon (128 x 128)" for 128. The
# GTK 4 status window had exported a full icon, so moving it onto this shell
# would have lost that without this swap. The likely cause is GDK's per-window
# icon size cap (a 256x256 icon is 65,538 longs), which is inferred; the two
# readings above are not.
#
# THIS TUPLE HAS FOUR CONSUMERS, NOT ONE, so the reorder is not confined to the
# exported property: `install_icon()` below (the process default icon),
# `Window._window_icon_path()` (the sidebar brand mark at 40px and the nav-row
# fallback at 22px) and `Window._header()` (the header mark at 34px). Both PNGs
# exist on every image that ships the dock, so kodachi-command-window and
# kodachi-repo-manager now draw those three marks from the 128px file as well.
# All three are rendered at 40px or below through `icon()`, which scales with
# GdkPixbuf, so a 128px source is still downscaling rather than upscaling and
# nothing gets softer. Said explicitly because "it only changes the taskbar
# icon" would have been wrong.
WINDOW_ICON_CANDIDATES = (
    os.path.join(ICON_ROOT, "kodachi/kodachi-command-window-128.png"),
    os.path.join(ICON_ROOT, "kodachi/kodachi-command-window-256.png"),
    os.path.join(ICON_ROOT, "kodachi-green-128.png"),
    "/usr/share/icons/kodachi/Kodachi_Green_big.png",
    "/usr/share/icons/kodachi/kodachi128.png",
    "/usr/share/icons/kodachi/kodachi64.png",
    "/usr/share/icons/kodachi/kodachi32.png",
)


def install_icon():
    """Give every window in this process the Kodachi mark.

    Without it GTK hands the window manager no icon at all, and the taskbar and
    alt-tab draw a blank white placeholder, which is what the operator saw. This
    is set as the process DEFAULT rather than per window, so the command windows,
    the output viewer and any future window all inherit it from one place.

    Returns the path actually used, or None, so a caller can report which file it
    got rather than assuming the first candidate existed.
    """
    for path in WINDOW_ICON_CANDIDATES:
        if os.path.isfile(path):
            try:
                Gtk.Window.set_default_icon_from_file(path)
                return path
            except Exception:
                continue
    return None


def install_css():
    """Load the design system once per process."""
    prov = Gtk.CssProvider()
    prov.load_from_data(CSS.encode())
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    install_icon()
    return prov


# ── small helpers, so a window definition never touches raw GTK ─────────
def cls(widget, *names):
    ctx = widget.get_style_context()
    for n in names:
        ctx.add_class(n)
    return widget


COMPACT_TEXT_CLASSES = frozenset(("hdr-sub", "section-note", "row-note"))

# THE SAME DEFECT AS `state-fact`, FIVE MORE TIMES. MEASURED, NOT INFERRED.
#
# An unellipsized GtkLabel reports its ENTIRE text as its MINIMUM preferred
# width, and every one of these sits in a plain box that propagates that
# minimum all the way to the toplevel. `Window.show_all` then RESIZES the
# window up to it, so a long runtime value does not truncate: it makes the
# window wider than the screen policy allows.
#
# Measured 2026-08-26 on kodachi@<lab-host>, DISPLAY=:0, offscreen, one
# process, same 765px text delta on every arm. "SHORT" is `apt update`, "LONG"
# is a realistic `sudo apt-get install -y ...` line:
#
#     subject                                   min SHORT   min LONG    delta
#     result-cmd  ResultPanel.show(command=)          593       1351     +758
#     cmd         Window.footer(command_preview=)     322       1009     +687
#     row-name    switch_row(name=)                   342       1107     +765
#     row-code    switch_row(trailing_code=)          368       1133     +765
#     pill        switch_row(state_text=)             368       1133     +765
#     state-fact  Window.state_strip()  ** FIXED **   285        285       +0
#     POSITIVE CONTROL, a bare realized GtkLabel        60        825     +765
#
# The state-fact row is the in-run proof that this harness CAN see the property
# move: the identical harness read +758..+765 on its five siblings and +0 here.
# MAX_COMPACT_WIDTH is 1080, so three of the five exceed the cap on this whole
# window family, and result-cmd is LIVE today (kodachi-command-window:4548
# passes a real command string into `show`).
#
# TOOLTIPS ARE SPLIT DELIBERATELY, AND THE SPLIT IS NOT COSMETIC. `row-name`,
# `row-code` and `pill` live inside rows that ALREADY carry a whole-row tooltip
# through `set_row_tooltip()` below, and that tooltip carries MORE than the
# label text does. Setting a second tooltip on the child would OVERRIDE the
# row's whenever the pointer is over the label, i.e. exactly where the user
# reads, so it would trade a width defect for an information loss. Only the
# classes with no owning row tooltip get one here.
#
# `state-fact` is deliberately NOT in this set. It sets its own ellipsize and
# its own richer "NAME  value" tooltip in `state_fact()`, and a calibration arm
# in tests/calibrate_repo_manager.py deletes that exact line to prove the
# contract can go red. Adding the class here would make that deletion a no-op
# and silently DISARM the arm, which is the "a second copy of the assertion
# disarms the gate that pins it" shape.
ELLIPSIZE_TEXT_CLASSES = frozenset((
    "cmd", "result-cmd", "result-title", "row-name", "row-code", "pill"))
ELLIPSIZE_TOOLTIP_CLASSES = frozenset(("cmd", "result-cmd", "result-title"))

# ── LETTER SPACING AND ELLIPSIZE CANNOT BOTH BE TRUE ON ONE LABEL ──────────
#
# A label that ellipsizes and carries inter-grapheme letter spacing CLIPS ITS
# OWN TEXT AT ANY WINDOW SIZE. GTK asks the label how wide it wants to be,
# allocates exactly that, and Pango then decides the glyphs do not fit and
# replaces the tail with an ellipsis. Nothing errors, nothing warns, and the
# result reads as a deliberate abbreviation rather than as a defect. It is why
# the operator's 3440px-wide screenshot showed
# "PENDING UPDATES  could not che..." and "SYSTEM CHANNEL  stable (defau..."
# with two thirds of the strip empty beside them, and why he could not read the
# error he was asking about.
#
# MEASURED 2026-08-30 on kodachi@<lab-host>, DISPLAY=:0, offscreen, real
# `state_fact()` labels packed in a REAL strip with this file's own CSS, at
# window widths 944, 1366 and 3390. With 1.3px of spacing, 21 of 21 label
# renders came back `is_ellipsized() == True`; with none, 0 of 21 did. Both
# arms are reproducible, and both are what
# test_no_status_fact_clips_its_own_value asserts.
#
# IT IS NOT A CSS-ONLY BUG. Moving the spacing into a Pango attribute
# (`Pango.attr_letter_spacing_new`) or into markup (`<span
# letter_spacing="1331">`) reproduces it exactly. My first fix did that and was
# wrong; only removing the spacing clears it.
#
# TWO INSTRUMENTS CANNOT SEE THIS, AND I PUBLISHED NUMBERS FROM ONE OF THEM
# BEFORE CHECKING IT, so they are recorded here as traps and not as evidence:
#
#   , growing a `set_size_request` one pixel at a time until the ellipsis
#     clears LOOKS like it measures the shortfall, and it produced a tidy table
#     of per-string deficits (6, 10, 15, 20, 31, 37px). Re-run with the SAME
#     two strings in the OPPOSITE order, the same harness returns 0 and 27, and
#     then 74 and 33. Those numbers are an artifact of allocation ordering
#     inside the loop, not a property of the label. The reason the "no spacing"
#     arm read a clean 0 six times is that its labels stop ellipsizing on the
#     FIRST iteration, so the loop exits before the artifact can accumulate:
#     the arm I trusted was the one the instrument could not corrupt.
#   , comparing `get_preferred_width()[1]` against a Pango layout rebuilt in
#     the label's own context, font and attributes is allocation-independent
#     and therefore stable, and it is BLIND: it reports a shortfall of 0 for
#     the SPACED label too (nat 137, layout 137). So the disagreement is not
#     between what the label asks for and what its text needs. It is inside
#     Pango's own ellipsize decision at exactly that allocation.
#
# THE CONSEQUENCE FOR ANY FUTURE FIX: only a render in a REAL container at a
# REAL window width can see this, so do not try to measure a shortfall and pad
# it out. There is no stable shortfall to pad.
#
# So the two ellipsizing classes give up 1.3px and 0.8px of tracking. That is
# the whole cost, and it buys a strip that renders its values.
#
# THE INVARIANT, STATED RATHER THAN ENUMERATED: letter spacing may stay on any
# class that does NOT ellipsize, and on no class that does. It is deliberately
# not a list. The list that used to be here named five classes and the
# stylesheet carried seven, having gained `.design1-nav-heading` and
# `.design1-sidebar-status-title` after it was written, which is the identical
# "the comment says the class is drained and it is not" failure the paragraph
# below confesses to. A hand-maintained roster of members re-drifts the moment
# somebody adds a rule; the invariant does not.
#
# It is enforced, not merely asserted:
# `test_no_ellipsizing_class_carries_letter_spacing` derives the ban set from
# `ELLIPSIZE_TEXT_CLASSES` rather than from a literal, so the ban cannot be
# drained by deleting a name from a test, and it carries an anti-vacuity floor
# and a positive control. To find today's members, read the stylesheet:
#     grep -n "letter-spacing" kodachi_ui.py
# and note that a comma selector puts one of its members on the LINE ABOVE,
# which is how a regex over "the nearest selector line" undercounts it.
#
# ELLIPSIZE ITSELF MUST STAY. It is what keeps a state-fact's MINIMUM width at
# 8px and data-independent; an unellipsized GtkLabel reports its entire text as
# the window's minimum, which is the 2026-08-26 defect that made this window
# open at 1236px on a machine with a few unparseable sources.list rows.
#
# A class named here must not carry `letter-spacing` in the CSS above, and
# `test_no_ellipsizing_class_carries_letter_spacing` in
# tests/test_repo_manager_run_feedback.py reads this set and the CSS and
# enforces it. THAT TEST EXISTS BECAUSE MY FIRST PASS DID NOT DRAIN THE CLASS:
# I removed the spacing from `.state-fact` and `.pill`, wrote a comment
# claiming only non-ellipsizing classes still carried it, and left
# `.result-title` at 0.8px one screen away. <agent> found it by reading
# the CSS against this very set, 2026-08-30, which is the check the comment
# was asserting and nothing was performing.
NO_LETTER_SPACING_CLASSES = frozenset((
    "state-fact", "cmd", "result-cmd", "result-title", "row-name", "row-code",
    "pill"))


def lbl(text, *classes, xalign=0.0, wrap=False):
    w = Gtk.Label(label=text, xalign=xalign)
    if wrap or COMPACT_TEXT_CLASSES.intersection(classes):
        w.set_line_wrap(True)
        w.set_max_width_chars(62)
    elif ELLIPSIZE_TEXT_CLASSES.intersection(classes):
        w.set_ellipsize(Pango.EllipsizeMode.END)
        if text and ELLIPSIZE_TOOLTIP_CLASSES.intersection(classes):
            set_ellipsis_tooltip(w, text)
    return cls(w, *classes)


def hbox(spacing=0, **kw):
    return Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing, **kw)


def vbox(spacing=0, **kw):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing, **kw)


def icon(path, px=24):
    """Render any GdkPixbuf-loadable file, SVG included, at an exact size.

    A missing or unreadable file yields a spacer of the same size rather than an
    exception: a country whose flag failed to download must still get a row, and
    the row must still line up with its neighbours.
    """
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, px, px, True)
        image = Gtk.Image.new_from_pixbuf(pb)
        image.kodachi_icon_path = path
        image.kodachi_icon_loaded = pb.get_width() > 0 and pb.get_height() > 0
        return image
    except Exception:
        ph = Gtk.Box()
        ph.set_size_request(px, px)
        ph.kodachi_icon_path = path
        ph.kodachi_icon_loaded = False
        return ph


PILL_TONES = ("on", "off", "warn", "err", "danger", "info")
STATE_TONE_COLORS = {
    "on": SUCCESS,
    "off": STATUS_INACTIVE,
    "warn": WARNING,
    "err": ERROR,
    "danger": ERROR,
    "info": INFO,
}
SCORE_DOT_COUNT = 10
SCORE_RE = re.compile(
    r"^(?P<label>.+?)\s+(?P<value>\d+(?:\.\d+)?)/(?P<maximum>\d+(?:\.\d+)?)$")


def pill(text, tone="off"):
    p = lbl(text, "pill", tone)
    p.set_valign(Gtk.Align.CENTER)
    return p


def badge(text, tone="off"):
    """Render numeric ``value/maximum`` badges as dot ratings, others as pills.

    Static row badges share one producer across every command window. Detecting
    the score shape here means present and future numeric comparisons receive a
    compact visual scale without turning facts such as "Encrypted" into score
    indicators. The label and ratio remain visible, and the original text is
    the accessible name, so color and dots are never the only information.
    """
    match = SCORE_RE.fullmatch(text)
    if match is None:
        return pill(text, tone)

    value = float(match.group("value"))
    maximum = float(match.group("maximum"))
    fraction = value / maximum if maximum > 0 else 0.0
    filled = round(max(0.0, min(1.0, fraction)) * SCORE_DOT_COUNT)

    score = cls(hbox(6), "score-dots", tone)
    score.set_valign(Gtk.Align.CENTER)
    score.pack_start(lbl(match.group("label"), "score-label"), False, False, 0)

    track = cls(hbox(1), "score-dot-track")
    track.set_valign(Gtk.Align.CENTER)
    for index in range(SCORE_DOT_COUNT):
        state = "filled" if index < filled else "empty"
        track.pack_start(lbl("●", "score-dot", state, tone), False, False, 0)
    score.pack_start(track, False, False, 0)

    ratio = f'{match.group("value")}/{match.group("maximum")}'
    score.pack_start(lbl(ratio, "score-ratio", tone), False, False, 0)
    score.set_tooltip_text(text)
    score.get_accessible().set_name(text)
    return score


def set_pill(p, text, tone="off"):
    """Repoint an existing pill at a new text and tone.

    Needed because live state is now read on a worker thread and arrives AFTER
    the row is drawn, so the pill must be mutable rather than built once from a
    value the UI thread blocked to obtain. Every tone class is removed before
    the new one is added: leaving the old one on gives a widget carrying both
    `warn` and `on`, where the winner is decided by CSS source order and not by
    the state, which is exactly the kind of "styling is not evidence of state"
    trap that already cost this window engine a day.
    """
    ctx = p.get_style_context()
    for t in PILL_TONES:
        ctx.remove_class(t)
    if tone:
        ctx.add_class(tone)
    p.set_text(text)
    p.set_visible(bool(text))
    p.set_no_show_all(not text)


def set_ellipsis_tooltip(widget, text):
    """Show `text` on hover ONLY while the label is actually truncated.

    An unconditional `set_tooltip_text` on an ellipsized label pops a tooltip
    over text that is already fully visible, on every short value, in every
    window. An advisor flagged exactly that on the first version of the
    state-fact fix, and the objection is right: the justification for the
    tooltip is "it carries the part that got cut off", which is a reason that
    only holds while something IS cut off.

    `Gtk.Label.get_layout().is_ellipsized()` answers that at hover time, which
    is the only time the answer is knowable: it depends on the width the label
    was ALLOCATED, not on the width it asked for, so it cannot be decided when
    the widget is built. Returning False from `query-tooltip` suppresses the
    popup entirely, so a short fact stays silent and a truncated one explains
    itself.
    """
    # BIND ONCE, RE-TEXT EVERY TIME. `ResultPanel.show()` calls this on every
    # result, so a plain `connect` here would stack a new handler per result and
    # keep every superseded closure alive with its stale text. The text lives on
    # the widget and the handler reads it at hover time.
    widget.kodachi_ellipsis_tip = text or ""
    widget.set_has_tooltip(True)
    if getattr(widget, "kodachi_ellipsis_tip_bound", False):
        return

    def _query(w, _x, _y, _keyboard, tip):
        full = getattr(w, "kodachi_ellipsis_tip", "")
        if not full:
            return False
        layout = w.get_layout()
        if layout is None or not layout.is_ellipsized():
            return False
        tip.set_text(full)
        return True

    widget.connect("query-tooltip", _query)
    widget.kodachi_ellipsis_tip_bound = True


def state_fact(name, value, tone="off"):
    """Render one summary fact as one label with one immutable baseline."""
    fact = lbl("", "state-fact", tone)
    # THE STRIP CARRIES RUNTIME TEXT OF UNBOUNDED LENGTH, AND WITHOUT THIS IT
    # DECIDES THE WINDOW'S MINIMUM WIDTH. `state-fact` is not in
    # COMPACT_TEXT_CLASSES, so these labels neither wrap nor ellipsize, and an
    # unellipsized GtkLabel reports its ENTIRE text as its minimum. The strip is
    # a flat hbox of such labels, so the window's minimum is the sum of whatever
    # the machine happens to have to say.
    #
    # MEASURED 2026-08-26 on <lab-host> (real seat0 :0), repo manager, CSS
    # installed, async workers settled, tree shell seeded into sys.modules:
    #     without ellipsize   as the box is 951, +3 security updates 1022,
    #                         +4 invalid source rows 1165, both 1236
    #     with ellipsize      936 in EVERY one of those states
    # against an OPEN_WIDTH of 944. GTK3 NEVER OPENS A TOPLEVEL NARROWER THAN
    # ITS MINIMUM, so the consequence is the opposite of clipping: `show_all`
    # below RESIZES the window UP, and on an ordinary machine it opened 7px
    # wider than intended, and on a machine with a few unparseable sources.list
    # rows it demanded 1236px, past MAX_COMPACT_WIDTH = 1080,
    # which is the cap on this whole window family. (1064 is merely the
    # widest opening any of them currently takes, 880 + SIDEBAR_WIDTH; it
    # is not the bound, and an inspector was right to flag me quoting it
    # as one.) Raising one window's WINDOW_WIDTH cannot
    # close that, because the text has no bound; ellipsizing does, and it makes
    # the minimum DATA-INDEPENDENT.
    #
    # WHAT ACTUALLY MOVES, STATED PROPERLY, BECAUSE MY FIRST VERSION OF THIS
    # COMMENT WAS WRONG AND AN INDEPENDENT INSPECTOR CAUGHT IT.
    # NATURAL width is unchanged (2325 on .198, 2835 on .173, both arms), so no
    # window's LAYOUT changes. But `Window.show_all` below RESIZES a window up
    # to its minimum when the minimum exceeds the opening width, so pre-fix the
    # repo manager did not clip: it silently GREW, to 951 on an ordinary machine
    # and 1236 on one with a few security updates and a few unparseable
    # sources.list rows. So the honest statement of this change is:
    #
    #     the RENDERED width of the repository manager drops from a
    #     data-dependent 951..1236 to a fixed 944, and the values ellipsize.
    #
    # That is the right trade and not a free one. 1236 is past MAX_COMPACT_WIDTH
    # (1080) and leaves 130px on the 1366-wide screens `state_strip` below is
    # explicitly designed for, and it is unbounded, because the text is
    # unbounded. But `state_strip` also says the facts "are the last thing that
    # should be pushed off the edge", so truncating them silently would be
    # trading one defect for another.
    #
    # HENCE THE TOOLTIP, WHICH IS NOT OPTIONAL AND IS WHY THIS IS A TWO-LINE FIX
    # RATHER THAN A ONE-LINE ONE. It carries the full untruncated fact, has no
    # effect on any geometry, and follows the established pattern in
    # kodachi-repo-manager (2064, 2085, 2111, 2182). The accessible name set
    # below already carries the full text as well, and ellipsize is a
    # render-time PangoLayout property that does not touch either.
    fact.set_ellipsize(Pango.EllipsizeMode.END)
    set_ellipsis_tooltip(fact, f"{name.upper()}  {value}")
    fact.set_markup(
        f'<span foreground="{TEXT_QUATERNARY}">{html.escape(name.upper())}</span>'
        f'  <span foreground="{STATE_TONE_COLORS.get(tone, TEXT_TERTIARY)}">'
        f'{html.escape(value)}</span>')
    fact.set_valign(Gtk.Align.CENTER)
    fact.get_accessible().set_name(f"{name.upper()} {value}")
    return fact


def _no_overlay_scroll(scrolled):
    """Make one ScrolledWindow's bar PERMANENT rather than overlaid.

    The CSS half of this (the `-GtkScrollbar-has-*-stepper` properties) draws
    the arrows; this half is what stops the whole bar, arrows included, fading
    out when the pointer leaves. Overlay mode is a widget property with no CSS
    equivalent in GTK3, so a stylesheet alone can never fix the operator's
    "arrows only show on hover" report and the two changes are not alternatives.

    Kept as one helper rather than three inline calls because there are three
    scroll areas in this file (the Window body, the Page body and the result
    panel) and the defect was reported against "all gtk windows": a per-site
    fix is exactly how one of the three would have been missed.
    """
    scrolled.set_overlay_scrolling(False)
    return scrolled


def scroller(horizontal=Gtk.PolicyType.AUTOMATIC,
             vertical=Gtk.PolicyType.AUTOMATIC):
    """Build a scroll area the Kodachi way. USE THIS, NOT Gtk.ScrolledWindow().

    A raw `Gtk.ScrolledWindow()` is overlay-scrolled, which is the operator's
    "the arrows only show when I hover" report (a1.png), and the CSS half of
    the fix cannot reach it because overlay mode is a widget PROPERTY with no
    GTK3 style equivalent. `install_css()` therefore makes the arrows LOOK
    fixed in an app that still fades them, which is why this was invisible in
    the Repository Manager for as long as it was: four raw scrollers there
    (card grid, detail pane, apt console, package table) inherited the styling
    and none of the behaviour.

    Exported as a factory rather than left as three inline calls because the
    gap is a CLASS: it returns the moment anyone adds a scroller in any Kodachi
    GTK app. tests/test_no_raw_scrollers.py asserts that no shipped GTK app
    constructs Gtk.ScrolledWindow directly, so the raw constructor is now the
    exception that has to justify itself rather than the default.
    """
    scrolled = Gtk.ScrolledWindow()
    scrolled.set_policy(horizontal, vertical)
    return _no_overlay_scroll(scrolled)


def copy_with_feedback(button, text, seconds=2):
    """Write `text` to the clipboard and SAY SO on the button that did it.

    USE THIS, NOT a bare `Gtk.Clipboard.get(...).set_text(...)`. A clipboard
    write produces no sound, no dialog and no visible change anywhere on
    screen, so a Copy button that only writes is indistinguishable from a Copy
    button that is broken, and the reader's only way to find out is to go and
    paste somewhere else.

    This is the second behaviour promoted out of a call site for the same
    reason `scroller()` was. ResultPanel had the label flip and the rationale
    for it; the Repository Manager reimplemented the clipboard write WITHOUT
    it, so all seven of its Copy controls (the console and six per-hash chips)
    were silent, in an app that already imports this module. A helper that
    exists in the shared library and is retyped at the call site is a
    divergence waiting to happen, not a duplication that stays in step.

    The label reverts on a timeout rather than staying "Copied", because a
    button whose label is a past-tense claim cannot be pressed a second time
    without reading as a control that has already been used up.

    THE ORIGINAL LABEL IS CACHED ON THE WIDGET, not read at click time. Read
    at click time, a second click inside the timeout window captures "Copied"
    as the original and the button keeps that word forever. The cache also
    carries the CASE, so the Repository Manager's lower-case `copy` chips flip
    to `copied` and the title-case buttons flip to `Copied`: a chip that
    shouted COPIED at chip size would read as a different control.

    `button` may be None for a copy with no visible control behind it.
    """
    Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text or "", -1)
    if button is None:
        return
    if getattr(button, "_kd_copy_label", None) is None:
        button._kd_copy_label = button.get_label()
    original = button._kd_copy_label
    if original.isupper():
        done = "COPIED"
    elif original.islower():
        done = "copied"
    else:
        done = "Copied"
    button.set_label(done)
    GLib.timeout_add_seconds(
        seconds, lambda: (button.set_label(original), False)[1])


def mark_control(row):
    """Tag one row widget as a COUNTABLE control.

    The sidebar count (`Account (3)`) has to say how many controls a
    destination holds, and the only honest way to know is to ask the widgets
    that were actually built rather than to count entries in the spec: a
    section whose rows were skipped at build time, or a hand-written page that
    never had a spec at all, would both be counted wrongly by a spec walk.

    The tag goes on the ROW, never on the inner switch or radio, so a nested
    walk cannot count one control twice.
    """
    row.kodachi_control = True
    return row


def count_controls(widget):
    """How many tagged control rows live under `widget`, recursively."""
    if getattr(widget, "kodachi_control", False):
        return 1
    if isinstance(widget, Gtk.Container):
        return sum(count_controls(child) for child in widget.get_children())
    return 0


class Window(Gtk.Window):
    """The Design 1 shell every command window shares.

    A fixed navigation rail sits beside the existing content column. Grouped
    windows use it to switch Pages; standalone windows register their existing
    section headings as scroll destinations. Command widgets, state reads,
    results and footers stay in the content objects that already own them.
    """

    SIDEBAR_WIDTH = 184
    MAX_COMPACT_WIDTH = 1080
    MAX_COMPACT_HEIGHT = 760
    MIN_STANDALONE_WIDTH = 940

    def __init__(self, title, subtitle, width=620, height=760, tabbed=False,
                 quit_on_destroy=True):
        super().__init__(title=f"Kodachi , {title}")
        cls(self, "kodachi")
        self.tabbed = tabbed
        self._quit_on_destroy = quit_on_destroy
        target_width = (self.MAX_COMPACT_WIDTH if tabbed else
                        min(self.MAX_COMPACT_WIDTH,
                            max(width + self.SIDEBAR_WIDTH,
                                self.MIN_STANDALONE_WIDTH)))
        self.set_default_size(target_width,
                              min(height, self.MAX_COMPACT_HEIGHT))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", self._on_destroy)
        # Escape is handled by do_key_press_event(), GTK's class closure. That
        # runs after consumer handlers, so a consumer can stop the shared
        # fallback by returning True.

        self.shell = cls(hbox(), "design1-shell")
        self.add(self.shell)

        self.sidebar = cls(vbox(6), "design1-sidebar")
        self.sidebar.set_size_request(self.SIDEBAR_WIDTH, -1)
        self.shell.pack_start(self.sidebar, False, False, 0)

        self.root = cls(vbox(), "root", "design1-content")
        self.shell.pack_start(self.root, True, True, 0)

        self._nav_buttons = []
        self._active_nav = None
        self._section_targets = []
        self._sidebar_brand(title)
        self._nav = vbox(4)
        self.sidebar.pack_start(lbl("NAVIGATION", "design1-nav-heading"),
                                False, False, 0)
        # The nav list goes in a scroller so a LONG nav cannot set the window's
        # minimum height. Packed bare, twenty 32px destinations plus the brand
        # and the status card give the sidebar a 832px minimum, which beats
        # set_default_size and makes the window taller than every other Kodachi
        # window (the reference, kodachi-command-window network, is 628). The
        # scroller keeps propagate-natural-height ON, so a short nav still
        # requests exactly its own height and no existing window changes shape;
        # only the minimum collapses, which is the number that was hurting.
        self._nav_scroll = _no_overlay_scroll(Gtk.ScrolledWindow())
        self._nav_scroll.set_policy(Gtk.PolicyType.NEVER,
                                    Gtk.PolicyType.AUTOMATIC)
        self._nav_scroll.set_propagate_natural_height(True)
        self._nav_scroll.set_shadow_type(Gtk.ShadowType.NONE)
        self._nav_scroll.add(self._nav)
        self.sidebar.pack_start(self._nav_scroll, False, False, 0)
        self._sidebar_status()
        self._header(title, subtitle)

        if tabbed:
            # The sidebar buttons drive this stack. Each Page still owns its
            # state, body, result and footer because each runs different work.
            self._tabbar = self._nav
            self._stack = Gtk.Stack()
            self._stack.set_transition_type(Gtk.StackTransitionType.NONE)
            self.root.pack_start(self._stack, True, True, 0)
            self._tabs = []          # [(key, button, Page)]
            self.body = None
            self._state_slot = None
            self._scroll = None
            return

        # The live-state strip belongs directly under the header. It gets its
        # own slot NOW, because packing it later would place it after the scroll
        # area and it would render at the BOTTOM of the window, underneath the
        # list it is supposed to be summarising.
        self._state_slot = vbox()
        self.root.pack_start(self._state_slot, False, False, 0)

        self._scroll = _no_overlay_scroll(Gtk.ScrolledWindow())
        self._scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.root.pack_start(self._scroll, True, True, 0)
        self.body = vbox()
        self.body.set_margin_bottom(14)
        self._scroll.add(self.body)
        # The sidebar follows the reader. Connected to the ADJUSTMENT rather
        # than to a scroll-event on the widget, because the adjustment moves for
        # every cause of movement (wheel, keyboard, touchpad kinetic scrolling,
        # and the programmatic jump `_scroll_to_section` performs) while a
        # scroll-event handler sees only the pointer ones.
        self._scroll.get_vadjustment().connect("value-changed",
                                               self._track_scroll_to_nav)

    # A WINDOW'S DECLARED GEOMETRY MUST AGREE WITH THE GEOMETRY GTK PRODUCES.
    # (This headline used to read "a window must never open narrower than its
    # content can be drawn", which GTK makes vacuously true and which the
    # retraction 40 lines below spends a paragraph refuting. Do not restore it.)
    #
    # `__init__` computes the opening width from the DECLARED SIDEBAR_WIDTH,
    # but that constant is a FLOOR the rail is free to exceed, not a cap: the
    # rail gets `set_size_request(SIDEBAR_WIDTH, -1)`, and the nav scroller
    # under it carries `set_policy(NEVER, AUTOMATIC)`, so the widest nav row
    # propagates its FULL minimum width upward and the horizontal policy never
    # clamps it. The scroller's own comment explains this for the other axis
    # ("a LONG nav cannot set the window's minimum height") and the identical
    # reasoning was never applied to WIDTH.
    #
    # MEASURED, all 25 windows, <lab-host>, DISPLAY=:0, by building each
    # one through the product's own choke point and reading
    # get_preferred_width() off the toplevel. The rail renders between 184 and
    # 284 against a declared 184, i.e. up to 100px over, which is the shape
    # this guard exists for. The Repo Manager hit the same class at 3px (943
    # against 940) and was closed by widening that ONE window (7c793e370),
    # which turned that symptom green and left the class open.
    #
    # THE PER-WINDOW NUMBERS ARE A DATED SNAPSHOT, NOT A STANDING FACT, AND
    # THE FIRST VERSION OF THIS COMMENT PRESENTED THEM AS ONE. It recorded
    # `sandbox` asking for 940 against a content minimum of 1036, i.e. a 96px
    # member. That was true when it was taken and is NOT reproducible now.
    # <agent> measured 1064 against 895 on both the pre-fix and the
    # post-fix payload, and I re-derived the whole family independently on
    # 2026-08-26 at master 4e8944ae1 with a positive control in the same run
    # (one window forced to declare 200px, which the predicate correctly
    # reported as a member, so the zero below is a real zero and not a dead
    # matcher):
    #
    #     NEGATIVE SLACK (declared below content minimum): 0 of 25
    #     sandbox declared 1064, minimum 895, slack +169
    #     the tightest window in the family is `vpn` at +151
    #
    # The declaration moved because the direct-operations contract was
    # regenerated under it (31f67932b) and the Containers window landed in
    # this family. So the guard below is currently a provable no-op on all 25
    # windows, which is what a floor is supposed to be, and NOBODY SHOULD
    # RE-QUOTE THE 96 as a current measurement. Re-run the family sweep before
    # citing any number in this block.
    #
    # WHAT THIS IS NOT, AND THE FIRST VERSION OF THIS COMMENT SAID IT WAS.
    # I wrote here that 96px "is clipped the moment it appears". That is
    # WRONG and <agent> refuted it with a positive control on
    # 2026-08-26: GTK3 will not map a toplevel below its content minimum, so
    # a window whose minimum exceeds its requested default simply OPENS AT
    # THE MINIMUM. Nothing is ever clipped on open, and two of the auditor's
    # own detectors scored the known-defective payload green before they
    # caught that, so do not re-derive the clipping claim from a detector
    # that agrees with it.
    #
    # THE DEFECT THAT IS REAL is the DISAGREEMENT between the geometry this
    # class declares and the geometry GTK actually produces. Every window in
    # the family computes its opening width from SIDEBAR_WIDTH plus a content
    # width, and that arithmetic has already produced a number GTK silently
    # overrode. The product then reasons about a width the user never
    # gets: the window cannot be dragged to it, saved-geometry and centering
    # math start from it, and the only observable symptom is that the window
    # refuses to go as narrow as its own code says it should. Making the
    # declared width equal the measured minimum is what puts the two back in
    # agreement.
    #
    # WIDENING-ONLY IS THE WHOLE POINT, and it is what keeps this out of every
    # other window's business. The branch is taken only when the measured
    # minimum EXCEEDS the opening width, which is already a broken window, so
    # it can never narrow anything: on the 24 windows that measured with slack
    # >= 0 the branch is provably not taken and their opening width is
    # unchanged. Capping the rail at SIDEBAR_WIDTH instead would ellipsize nav
    # text on the 13 windows whose rail exceeds 184, and moving SIDEBAR_WIDTH
    # would move every window in the family.
    #
    # IT RUNS AFTER THE REAL show_all, NOT BEFORE. An unmapped tree reports a
    # smaller minimum than the one the user actually gets, so measuring early
    # would under-report exactly the windows this exists to catch.
    def show_all(self):
        Gtk.Window.show_all(self)
        try:
            minimum = self.get_preferred_width()[0]
            width, height = self.get_default_size()
        except Exception:
            return
        if minimum <= width:
            return
        # `set_default_size` alone is not enough once the window is mapped: it
        # governs the NEXT map, not this one. `resize` is what the user sees.
        self.set_default_size(minimum, height)
        self.resize(minimum, max(height, self.get_size()[1]))

    # ── report surfaces ─────────────────────────────────────────────────
    def allow_horizontal_scroll(self):
        """Let the body scroll SIDEWAYS as well as down. Opt-in, for one window.

        Every command window's rows are built to fit, so a horizontal bar there
        could only ever mean a layout defect, which is why the body scroller is
        constructed with the horizontal policy at NEVER. A REPORT is different.
        kodachi-status-window carries columnar output the producer chose (the
        Tor instance table: Tag, Tor_IP, Country, Flag, Status, Age), wrapping
        would shear the columns apart, and with the policy at NEVER a single
        wide line has nowhere to go, so GTK satisfies it by making the WINDOW
        that wide. Measured 2026-08-18 on the GTK 4 predecessor of that window:
        4826x780 on a 3440px screen, with the Close button off the right edge.
        AUTOMATIC on both axes keeps the window inside the family cap and lets
        the line scroll instead. Added 2026-09-03 when the status window moved
        onto this shell; nothing else calls it. Returns self.
        """
        if self._scroll is not None:
            self._scroll.set_policy(Gtk.PolicyType.AUTOMATIC,
                                    Gtk.PolicyType.AUTOMATIC)
        return self

    def scroll_body_to_top(self):
        """Pin the body to the top of the report. Idle-safe: returns False.

        Selectable labels are focusable, and a viewport follows whichever child
        takes focus, so a report whose values can be copied opened part way down
        with its first section already off screen. The caller focuses the Close
        button and schedules this on the next idle tick, because the scroller
        has not been sized yet at the point the window is built.
        """
        if self._scroll is not None:
            self._scroll.get_vadjustment().set_value(0)
        return False

    def _on_destroy(self, *_args):
        # Command Window owns a Gtk.main loop. Repository Manager attaches the
        # same surface to Gtk.Application, whose run loop is not Gtk.main.
        # Calling main_quit without an active Gtk.main loop emits a critical.
        if self._quit_on_destroy and Gtk.main_level() > 0:
            Gtk.main_quit()

    def close(self):
        """Close this surface without changing any control."""
        if self._quit_on_destroy and Gtk.main_level() > 0:
            Gtk.main_quit()
        else:
            # Use GTK's normal close path so a consumer's delete-event guard
            # can still veto the close. Repository Manager relies on that
            # signal to warn before abandoning an apt operation.
            super().close()

    def _window_icon_path(self):
        for path in WINDOW_ICON_CANDIDATES:
            if os.path.isfile(path):
                return path
        return WINDOW_ICON_CANDIDATES[0]

    def _sidebar_brand(self, title):
        brand = cls(hbox(8), "design1-brand")
        mark = cls(icon(self._window_icon_path(), 40), "design1-nav-icon")
        brand.pack_start(mark, False, False, 0)
        copy = vbox(1)
        copy.pack_start(lbl("Kodachi", "design1-brand-name"), False, False, 0)
        surface = title.upper() if len(title) <= 22 else "COMMAND WINDOW"
        copy.pack_start(lbl(surface, "design1-brand-surface"), False, False, 0)
        brand.pack_start(copy, True, True, 0)
        self.sidebar.pack_start(brand, False, False, 0)

    def _sidebar_status(self):
        status = cls(vbox(3), "design1-sidebar-status")
        status.pack_start(lbl("CONTROL SURFACE", "design1-sidebar-status-title"),
                          False, False, 0)
        self._nav_count = lbl("Preparing navigation", "design1-sidebar-status-value")
        status.pack_start(self._nav_count, False, False, 0)
        status.pack_start(lbl("Nothing changes until you confirm.",
                              "design1-sidebar-status-note", wrap=True),
                          False, False, 0)
        self.sidebar.pack_end(status, False, False, 0)

    def _set_active_nav(self, selected):
        # Remembered so the scroll tracker can skip a redundant restyle on every
        # single scroll event: `value-changed` fires continuously during a drag
        # and re-adding a style class it already has forces a needless redraw of
        # the whole rail, which on software-rendered WebKitGTK-class VMs is the
        # difference between smooth and visibly stepping.
        self._active_nav = selected
        for button in self._nav_buttons:
            context = button.get_style_context()
            if button is selected:
                context.add_class("active")
            else:
                context.remove_class("active")

    def _add_nav(self, label, icon_path, tooltip, callback):
        button = cls(Gtk.Button(), "design1-nav")
        button.set_relief(Gtk.ReliefStyle.NONE)
        content = hbox(9)
        nav_icon = cls(icon(icon_path or self._window_icon_path(), 22),
                       "design1-nav-icon")
        content.pack_start(nav_icon, False, False, 0)
        # THE LABEL WIDGET IS KEPT, because the count it will carry is not known
        # yet. A destination's control count can only be measured once its rows
        # exist, and `section()` is called BEFORE the card under it is filled, so
        # writing "Account (3)" at this point would be writing a number nobody
        # has counted. `refresh_nav_counts()` comes back and fills it in.
        nav_label = lbl(label, "design1-nav-label")
        button.kodachi_nav_label_widget = nav_label
        button.kodachi_nav_base_label = label
        content.pack_start(nav_label, True, True, 0)
        button.add(content)
        button.set_tooltip_text(tooltip)
        set_control_accessibility(button, label, tooltip)
        button.connect("clicked", callback)
        self._nav.pack_start(button, False, False, 0)
        self._nav_buttons.append(button)
        self._nav_count.set_text(
            f"{len(self._nav_buttons)} destination" +
            ("" if len(self._nav_buttons) == 1 else "s"))
        if len(self._nav_buttons) == 1:
            self._set_active_nav(button)
        return button

    # ── sidebar control counts ──────────────────────────────────────────
    def _apply_nav_count(self, button, count):
        """Write `Label (n)` onto one nav row, or plain `Label` when n is 0.

        ZERO IS RENDERED AS NO SUFFIX ON PURPOSE. A destination with no
        countable control is a heading a reader scrolls to, and `Overview (0)`
        reads as a section that failed to load rather than one that was never
        meant to hold switches. The same reasoning as the empty-section rule in
        the driver, which stopped drawing a caption over an empty card.
        """
        label_widget = getattr(button, "kodachi_nav_label_widget", None)
        if label_widget is None:
            return
        base = getattr(button, "kodachi_nav_base_label", label_widget.get_text())
        label_widget.set_text(f"{base} ({count})" if count else base)
        button.kodachi_nav_count = count
        tip = button.get_tooltip_text() or base
        if count:
            noun = "control" if count == 1 else "controls"
            first = tip.splitlines()[0]
            button.set_tooltip_text(f"{first}\n{count} {noun} in this section.")

    def refresh_nav_counts(self):
        """Count the controls each sidebar destination owns and label it.

        Called ONCE, after the whole window is built and before it is shown.
        It cannot be done during construction: `section()` registers its nav row
        before the card beneath it has a single row in it, so any count taken
        then is zero for every section in the product.

        The two window shapes are counted from different containers because they
        ARE different containers, not as a special case: a tabbed window gives
        each destination its own Page column, while a standalone window puts
        every section into one shared body and the boundary between two sections
        is the heading widget itself.
        """
        if self.tabbed:
            for _key, button, page in self._tabs:
                self._apply_nav_count(button, count_controls(page.body))
            return
        if not self._section_targets or self.body is None:
            return
        # Sections are delimited by their own heading widgets in one flat body,
        # so walk the body in packing order and attribute everything after a
        # heading to that heading until the next one appears. Matching on
        # identity, never on the caption text, because two sections in different
        # windows can legitimately share a caption.
        boundaries = {id(heading): index
                      for index, (_c, heading, _b) in enumerate(self._section_targets)}
        counts = [0] * len(self._section_targets)
        current = None
        for child in self.body.get_children():
            index = boundaries.get(id(child))
            if index is not None:
                current = index
                continue
            if current is not None:
                counts[current] += count_controls(child)
        for (_caption, _heading, button), count in zip(self._section_targets, counts):
            self._apply_nav_count(button, count)

    def _track_scroll_to_nav(self, adjustment):
        """Move the sidebar highlight to the section actually in view.

        Operator, screenshot a1: scrolling the content left the highlight stuck
        on the first destination, so the rail said "you are in Overview" while
        the reader was three sections further down.

        The rule is LAST HEADING AT OR ABOVE THE VIEWPORT TOP, which is what a
        reader means by "the section I am in": a heading scrolled just off the
        top still owns the rows underneath it. The 24px grace matches the
        `allocation.y - 12` that `_scroll_to_section` scrolls TO, so clicking a
        destination and then reading the highlight cannot disagree with itself,
        which a tighter threshold would do on every click.
        """
        if not self._section_targets:
            return
        top = adjustment.get_value() + 24
        selected = self._section_targets[0][2]
        for _caption, heading, button in self._section_targets:
            if heading.get_allocation().y <= top:
                selected = button
            else:
                break
        if selected is not self._active_nav:
            self._set_active_nav(selected)

    def _on_key(self, _w, ev):
        if ev.keyval == Gdk.KEY_Escape:
            self.close()
            return True
        return False

    def do_key_press_event(self, ev):
        if self._on_key(self, ev):
            return True
        return Gtk.Window.do_key_press_event(self, ev)

    def _header(self, title, subtitle):
        bar = cls(hbox(14), "hdr")
        rule = cls(Gtk.Box(), "hdr-rule")
        rule.set_size_request(3, 40)
        bar.pack_start(rule, False, False, 0)
        # THE MARK, IN THE HEADER. Operator: "always show kodachi logo maybe
        # here", pointing at this bar. A taskbar icon is not enough: the window
        # itself should say whose it is, and these windows change the routing of
        # a privacy machine.
        for _p in WINDOW_ICON_CANDIDATES:
            if os.path.isfile(_p):
                mark = icon(_p, 34)
                if mark is not None:
                    mark.set_valign(Gtk.Align.CENTER)
                    cls(mark, "hdr-logo")
                    bar.pack_start(mark, False, False, 0)
                break
        text = vbox(3)
        text.set_valign(Gtk.Align.CENTER)
        text.pack_start(lbl(title, "hdr-title"), False, False, 0)
        text.pack_start(lbl(subtitle, "hdr-sub"), False, False, 0)
        bar.pack_start(text, True, True, 0)
        self.root.pack_start(bar, False, False, 0)

    # ── tabs, only on a tabbed window ───────────────────────────────────
    def add_tab(self, key, label, tooltip=None, icon_path=None):
        """Add one sidebar destination and return its existing Page."""
        if not self.tabbed:
            raise RuntimeError("add_tab() needs Window(tabbed=True)")
        page = Page(self, key)
        self._stack.add_named(page.column, key)
        # A Gtk.Stack can only make a child visible if that child is itself
        # shown, and set_visible_child_name() FAILS SILENTLY otherwise. The
        # first tab is selected during construction, long before the caller's
        # show_all(), so without this the initial page is never selected and
        # the stack falls back to whatever it likes once everything is shown.
        # Measured on the VM: the tab BUTTON took its .active class correctly
        # while the stack showed a different page, so styling is not evidence
        # that the switch worked.
        page.column.show_all()
        button = self._add_nav(
            label, icon_path, tooltip or f"{label}: open this page",
            lambda _button, k=key: self.show_tab(k))
        button.kodachi_nav_key = key
        button.kodachi_nav_icon_path = icon_path
        self._tabs.append((key, button, page))
        if len(self._tabs) == 1:
            self.show_tab(key)
        return page

    def show_tab(self, key):
        """Switch the visible page and move the .active class to its button."""
        self._stack.set_visible_child_name(key)
        for k, button, _page in self._tabs:
            if k == key:
                self._set_active_nav(button)
                break

    def tab(self, key):
        for k, _b, page in self._tabs:
            if k == key:
                return page
        raise KeyError(key)

    # ── body builders ───────────────────────────────────────────────────
    def state_strip(self, pairs, wrap_at=None):
        """pairs: [(label, value, tone)] rendered as one live-state row.

        `wrap_at` splits the facts across several rows of at most that many.
        It is opt-in and defaults to the original single row, so no existing
        window changes shape. It exists because this strip is a flat hbox: a
        window with seven facts asked for 1557px of width, which does not fit
        the 1366-wide screens these windows are designed for, and the facts are
        the last thing that should be pushed off the edge.

        RE-CALLABLE ON PURPOSE. The counts it shows (how many controls, how many
        unreadable) are only known once the worker thread has finished reading
        live state, which happens well after the surface is drawn, so this is
        called a second time with the real numbers. Without the clear below the
        second call would STACK a strip under the first and the window would
        show two contradictory summaries at once, the stale one on top.
        """
        for child in self._state_slot.get_children():
            self._state_slot.remove(child)
        vertical = bool(wrap_at) and len(pairs) > wrap_at
        wrap = Gtk.Box(orientation=Gtk.Orientation.VERTICAL) if vertical \
            else Gtk.Box()
        if vertical:
            wrap.set_spacing(8)
        wrap.set_margin_top(16)
        wrap.set_margin_start(22)
        wrap.set_margin_end(22)
        rows = ([pairs[i:i + wrap_at] for i in range(0, len(pairs), wrap_at)]
                if vertical else [pairs])
        for row in rows:
            strip = cls(hbox(22), "state")
            for name, value, tone in row:
                # One Gtk.Label owns the entire fact. Separate baseline
                # containers put STATE UNKNOWN a few pixels above CONTROLS even
                # though both containers were horizontal.
                strip.pack_start(state_fact(name, value, tone), False, False, 0)
            wrap.pack_start(strip, not vertical, not vertical, 0)
        self._state_slot.pack_start(wrap, False, False, 0)

    def section(self, caption, note=None, icon_path=None):
        heading = lbl(caption.upper(), "section")
        self.body.pack_start(heading, False, False, 0)
        if note:
            self.body.pack_start(lbl(note, "section-note", wrap=True), False, False, 0)
        button = self._add_nav(
            caption, icon_path, f"{caption}: move to this section",
            lambda _button, anchor=heading: self._scroll_to_section(anchor, _button))
        button.kodachi_nav_key = f"section-{len(self._section_targets)}"
        button.kodachi_nav_icon_path = icon_path
        self._section_targets.append((caption, heading, button))

    def _scroll_to_section(self, anchor, button):
        self._set_active_nav(button)

        def move():
            allocation = anchor.get_allocation()
            adjustment = self._scroll.get_vadjustment()
            maximum = max(adjustment.get_lower(),
                          adjustment.get_upper() - adjustment.get_page_size())
            adjustment.set_value(min(max(allocation.y - 12, adjustment.get_lower()),
                                     maximum))
            return False

        GLib.idle_add(move)

    def card(self):
        c = cls(vbox(), "card")
        self.body.pack_start(c, False, False, 0)
        return c

    def result(self):
        """The inline result panel for this surface, created on first use."""
        if getattr(self, "_result", None) is None:
            self._result = ResultPanel(self.root)
        return self._result

    def footer(self, command_preview, primary_label, on_primary, primary_enabled=True):
        self.footer_note = None
        if command_preview:
            self.footer_note = lbl(command_preview, "cmd")
            self.root.pack_start(self.footer_note, False, False, 0)
        bar = cls(hbox(10), "footer")
        primary = cls(Gtk.Button(label=primary_label), "primary")
        primary.set_sensitive(primary_enabled)
        primary.connect("clicked", on_primary)
        # The only button in the product that changes the machine, and it had no
        # hover text at all. Say what it will and will not do.
        if primary_label.strip().lower() == "close":
            primary.set_tooltip_text("Close this window. Nothing is changed.")
        elif primary_enabled:
            primary.set_tooltip_text(
                f"{primary_label}: runs only the controls you actually changed in "
                "this tab. Untouched rows are left alone.")
        else:
            primary.set_tooltip_text(
                f"{primary_label} is unavailable on this tab: there is nothing here "
                "to apply.")
        set_control_accessibility(primary, primary_label,
                                  primary.get_tooltip_text())
        bar.pack_end(primary, False, False, 0)
        # ONE Close, never two. A report-only window has no Apply, so the
        # primary button IS "Close"; adding the ghost Close beside it produced
        # two identical buttons side by side, which the operator photographed.
        if primary_label.strip().lower() != "close":
            close = cls(Gtk.Button(label="Close"), "ghost")
            close_tip = "Close this window. Nothing is applied."
            close.set_tooltip_text(close_tip)
            set_control_accessibility(close, "Close", close_tip)
            close.connect("clicked", lambda *_: self.close())
            bar.pack_end(close, False, False, 0)
        self.root.pack_end(bar, False, False, 0)
        self.primary_button = primary
        return primary


class Page:
    """One tab's content, with the same builders a Window body offers.

    A Page is deliberately API-compatible with Window for `state_strip`,
    `section`, `card` and `footer`, so a window definition does not have to know
    whether it is being rendered standalone or as one tab of several. That is
    what let the two hand-written Tor country pickers move into tabs without
    rewriting the widget code inside them: they take a target object and call
    the same four methods either way.

    Each Page owns its OWN footer. A tabbed window has no shared Apply, because
    the Exit Country tab and the DNS tab run different commands and a single
    button could not know which. The footer packs into the page column, so it is
    visible only while that tab is.
    """

    def __init__(self, window, key):
        self.window = window
        self.key = key
        self.column = cls(vbox(), "root")

        self._state_slot = vbox()
        self.column.pack_start(self._state_slot, False, False, 0)

        self._scroll = _no_overlay_scroll(Gtk.ScrolledWindow())
        self._scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.column.pack_start(self._scroll, True, True, 0)
        self.body = vbox()
        self.body.set_margin_bottom(14)
        self._scroll.add(self.body)
        self.primary_button = None

    def state_strip(self, pairs, wrap_at=None):
        # Same clear-then-build contract as Window.state_strip: see the note
        # there. A tabbed window calls this per page once its reads land.
        for child in self._state_slot.get_children():
            self._state_slot.remove(child)
        vertical = bool(wrap_at) and len(pairs) > wrap_at
        wrap = Gtk.Box(orientation=Gtk.Orientation.VERTICAL) if vertical \
            else Gtk.Box()
        if vertical:
            wrap.set_spacing(8)
        wrap.set_margin_top(16)
        wrap.set_margin_start(22)
        wrap.set_margin_end(22)
        rows = ([pairs[i:i + wrap_at] for i in range(0, len(pairs), wrap_at)]
                if vertical else [pairs])
        for row in rows:
            strip = cls(hbox(22), "state")
            for name, value, tone in row:
                strip.pack_start(state_fact(name, value, tone), False, False, 0)
            wrap.pack_start(strip, not vertical, not vertical, 0)
        self._state_slot.pack_start(wrap, False, False, 0)

    def section(self, caption, note=None, icon_path=None):
        # The owning Window already represents this Page in the sidebar. The
        # icon parameter keeps Page API-compatible with Window without creating
        # a second nested navigation rail.
        del icon_path
        self.body.pack_start(lbl(caption.upper(), "section"), False, False, 0)
        if note:
            self.body.pack_start(lbl(note, "section-note", wrap=True), False, False, 0)

    def card(self):
        c = cls(vbox(), "card")
        self.body.pack_start(c, False, False, 0)
        return c

    def result(self):
        """The inline result panel for this surface, created on first use."""
        if getattr(self, "_result", None) is None:
            self._result = ResultPanel(self.column)
        return self._result

    def footer(self, command_preview, primary_label, on_primary, primary_enabled=True):
        self.footer_note = None
        if command_preview:
            self.footer_note = lbl(command_preview, "cmd")
            self.column.pack_start(self.footer_note, False, False, 0)
        bar = cls(hbox(10), "footer")
        primary = cls(Gtk.Button(label=primary_label), "primary")
        primary.set_sensitive(primary_enabled)
        primary.connect("clicked", on_primary)
        # The only button in the product that changes the machine, and it had no
        # hover text at all. Say what it will and will not do.
        if primary_label.strip().lower() == "close":
            primary.set_tooltip_text("Close this window. Nothing is changed.")
        elif primary_enabled:
            primary.set_tooltip_text(
                f"{primary_label}: runs only the controls you actually changed in "
                "this tab. Untouched rows are left alone.")
        else:
            primary.set_tooltip_text(
                f"{primary_label} is unavailable on this tab: there is nothing here "
                "to apply.")
        set_control_accessibility(primary, primary_label,
                                  primary.get_tooltip_text())
        bar.pack_end(primary, False, False, 0)
        # ONE Close, never two. A report-only window has no Apply, so the
        # primary button IS "Close"; adding the ghost Close beside it produced
        # two identical buttons side by side, which the operator photographed.
        if primary_label.strip().lower() != "close":
            close = cls(Gtk.Button(label="Close"), "ghost")
            close_tip = "Close this window. Nothing is applied."
            close.set_tooltip_text(close_tip)
            set_control_accessibility(close, "Close", close_tip)
            close.connect("clicked", lambda *_: self.window.close())
            bar.pack_end(close, False, False, 0)
        self.column.pack_end(bar, False, False, 0)
        self.primary_button = primary
        return primary


class ResultPanel:
    """The answer to a click, shown INSIDE the surface that asked for it.

    Every report and action row used to call show_output(), which opened its own
    Gtk.Window. Five clicks meant five windows, and because the child is
    transient-for the parent the newest answer could land BEHIND the control that
    produced it. The operator's words: "response can be shown on same gtk window
    for all commands in all gtk windows instead of popping up new notification
    window for each click".

    Two deliberate properties:

    FIXED HEIGHT, REVEALED, NEVER GROWN. The panel is created once at a fixed
    height and starts hidden. Showing it does not resize or reflow the list
    above, so the row the user just clicked does not move under the pointer.
    A panel that grew the window would be the same class of defect as a
    full-island rebuild stealing focus mid-interaction.

    REPLACES, NEVER STACKS. A second click overwrites the body rather than
    appending, so the panel always holds the CURRENT answer and there is no
    scrollback to mistake for live state.

    Playbook section 17 (long answers get a window, not a notification) is
    satisfied rather than reverted: the objection there was that a notification
    TIMES OUT mid-read and ellipsises its tail. This panel does neither, and it
    keeps a Close that clears rather than a dialog to dismiss.
    """

    HEIGHT = 220

    def __init__(self, container):
        self.box = cls(vbox(), "result")
        self.box.set_no_show_all(True)

        head = cls(hbox(10), "result-hdr")
        self.title = lbl("", "result-title")
        self.command = lbl("", "result-cmd")
        text = vbox(2)
        text.pack_start(self.title, False, False, 0)
        text.pack_start(self.command, False, False, 0)
        head.pack_start(text, True, True, 0)
        self.pill_slot = hbox(6)
        self.pill_slot.set_valign(Gtk.Align.CENTER)
        head.pack_end(self.pill_slot, False, False, 0)
        close = cls(Gtk.Button(label="Clear"), "ghost")
        close.set_valign(Gtk.Align.CENTER)
        close.set_tooltip_text(
            "Clear this result panel. It only hides the output already shown; "
            "nothing is run and nothing is undone.")
        set_control_accessibility(
            close, "Clear result",
            "Clear this result panel. Nothing is run and nothing is undone.")
        close.connect("clicked", lambda *_: self.clear())
        head.pack_end(close, False, False, 0)

        # ── OUTPUT CONTROLS ────────────────────────────────────────────────
        # The panel shipped with Clear and nothing else, so the one thing a
        # reader always wants to do with a command's answer, take it somewhere
        # else, was impossible: the body is selectable, but dragging a selection
        # over 400 lines inside a 220px viewport is not a way to copy anything.
        #
        # They are packed end-first, and GTK puts each new end-child FURTHER
        # LEFT, so the reading order on screen is Keep, Wrap, Copy, Clear with
        # Clear still hard against the right edge where it has always been.
        # Moving the button that was already there would be a change nobody
        # asked for riding along with the ones they did.
        self.copy_button = cls(Gtk.Button(label="Copy"), "ghost")
        self.copy_button.set_valign(Gtk.Align.CENTER)
        copy_tip = ("Copy everything in this panel to the clipboard. Nothing is "
                    "run and nothing is changed.")
        self.copy_button.set_tooltip_text(copy_tip)
        set_control_accessibility(self.copy_button, "Copy output", copy_tip)
        self.copy_button.connect("clicked", self._copy_to_clipboard)
        head.pack_end(self.copy_button, False, False, 0)

        self.wrap_toggle = state_toggle(cls(Gtk.ToggleButton(), "ghost"), "Wrap")
        self.wrap_toggle.set_valign(Gtk.Align.CENTER)
        wrap_tip = ("Wrap long lines to the panel width instead of scrolling "
                    "sideways. Display only: the output itself is unchanged.")
        self.wrap_toggle.set_tooltip_text(wrap_tip)
        set_control_accessibility(self.wrap_toggle, "Wrap long lines", wrap_tip)
        self.wrap_toggle.connect("toggled", self._apply_wrap)
        head.pack_end(self.wrap_toggle, False, False, 0)

        self.keep_toggle = state_toggle(cls(Gtk.ToggleButton(), "ghost"), "Keep")
        self.keep_toggle.set_valign(Gtk.Align.CENTER)
        keep_tip = ("Keep previous answers instead of replacing them. The newest "
                    "answer is added at the TOP, each under its own time and "
                    "command heading, so this panel becomes a run log.")
        self.keep_toggle.set_tooltip_text(keep_tip)
        set_control_accessibility(self.keep_toggle, "Keep previous output",
                                  keep_tip)
        head.pack_end(self.keep_toggle, False, False, 0)

        self.box.pack_start(head, False, False, 0)

        self.scroll = _no_overlay_scroll(Gtk.ScrolledWindow())
        self.scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_size_request(-1, self.HEIGHT)
        self.body = lbl("", "result-body", wrap=False)
        self.body.set_selectable(True)
        self.body.set_valign(Gtk.Align.START)
        self.scroll.add(self.body)
        self.box.pack_start(self.scroll, False, False, 0)
        # Newest first. Each entry is (stamp, title, command, text) rather than
        # a pre-rendered string, because the per-block heading is only drawn
        # once there is more than one block, and rendering it in would mean
        # stripping it out again the moment the panel drops back to one.
        self._blocks = []

        container.pack_end(self.box, False, False, 0)

    def _rendered(self):
        """The panel body as it should read for the blocks currently held.

        ONE BLOCK RENDERS EXACTLY AS IT DID BEFORE THIS CHANGE, with no heading
        of its own. The panel's own header already shows that block's title and
        command, so repeating them inside the body would be a visible change to
        every window in the product for a feature the reader has not switched
        on. Headings appear only once a second block makes them load-bearing.
        """
        if not self._blocks:
            return ""
        if len(self._blocks) == 1:
            return self._blocks[0][3]
        parts = []
        for stamp, title, command, text in self._blocks:
            heading = f"── {stamp}  {title}"
            if command:
                heading += f"\n   {command}"
            parts.append(f"{heading}\n{text}")
        return "\n\n".join(parts)

    def _copy_to_clipboard(self, *_args):
        # The rationale that used to live here moved into copy_with_feedback()
        # when the Repository Manager was found reimplementing the clipboard
        # write without the feedback half. One implementation, four call sites.
        copy_with_feedback(self.copy_button, self._rendered())

    def _apply_wrap(self, *_args):
        wrap = self.wrap_toggle.get_active()
        self.body.set_line_wrap(wrap)
        # The horizontal scrollbar has to move with it. Left on AUTOMATIC while
        # wrapping, the label reports a natural width nothing can satisfy and
        # the bar appears and disappears as the text reflows.
        self.scroll.set_policy(
            Gtk.PolicyType.NEVER if wrap else Gtk.PolicyType.AUTOMATIC,
            Gtk.PolicyType.AUTOMATIC)

    def show(self, title, command, text, pill_label=None, pill_tone="on"):
        self.title.set_text(title)
        self.command.set_text(command or "")
        # THE TOOLTIP HAS TO BE REFRESHED HERE, NOT ONLY IN `lbl()`. Both of
        # these labels are constructed EMPTY and filled on every result, so the
        # construction-time tooltip in `lbl()` is skipped for them (`if text`)
        # and would be stale for the rest of the window's life if it were not.
        # Without it the ellipsize added to `result-cmd` would truncate a
        # command with nothing anywhere carrying the full text.
        set_ellipsis_tooltip(self.title, title or "")
        set_ellipsis_tooltip(self.command, command or "")
        for child in self.pill_slot.get_children():
            self.pill_slot.remove(child)
        if pill_label:
            self.pill_slot.pack_start(pill(pill_label, pill_tone), False, False, 0)
        entry = (time.strftime("%H:%M:%S"), title, command or "",
                 text or "(the command produced no output)")
        if self.keep_toggle.get_active():
            self._blocks.insert(0, entry)
        else:
            self._blocks = [entry]
        self.body.set_text(self._rendered())
        self.box.set_no_show_all(False)
        self.box.show_all()
        # Back to the top, so the answer just asked for is the one on screen.
        # Without this, a kept run log leaves the viewport wherever the PREVIOUS
        # answer had been scrolled to and the new block sits above the fold,
        # which reads as a button that did nothing.
        adjustment = self.scroll.get_vadjustment()
        GLib.idle_add(lambda: (adjustment.set_value(adjustment.get_lower()),
                               False)[1])

    def clear(self):
        self.box.hide()
        self._blocks = []
        self.body.set_text("")


def switch_row(card, name, note=None, leading=None, tone=None, state_text=None,
               active=False, on_toggle=None, trailing_code=None, badges=None):
    """One switch row: optional icon, name, note, badges, status pill, switch.

    `badges` are STATIC facts about the row, not live state: "Encrypted",
    "Speed 9/10". Text facts are pills and numeric scores are dot ratings to the
    LEFT of the state pill, so a fixed property cannot merge with live state.
    """
    row = mark_control(cls(hbox(13), "row"))
    if leading is not None:
        leading.set_valign(Gtk.Align.CENTER)
        row.pack_start(leading, False, False, 0)
    text = vbox(2)
    text.set_valign(Gtk.Align.CENTER)
    text.pack_start(lbl(name, "row-name"), False, False, 0)
    if note:
        text.pack_start(lbl(note, "row-note"), False, False, 0)
    row.pack_start(text, True, True, 0)
    if trailing_code:
        row.pack_start(lbl(trailing_code, "row-code"), False, False, 0)
    for btext, btone in (badges or ()):
        row.pack_start(badge(btext, btone), False, False, 0)
    # THE PILL IS ALWAYS BUILT, EVEN WHEN EMPTY.
    # Live state now arrives on a worker thread after the row is drawn, so the
    # pill has to already exist to be repointed by set_pill(). Building it only
    # when `state_text` is truthy meant a row that started in a known state and
    # later became unreadable had nowhere to say so.
    p = pill(state_text or "", tone or "off")
    p.set_visible(bool(state_text))
    p.set_no_show_all(not state_text)
    row.pack_start(p, False, False, 0)
    sw = Gtk.Switch()
    sw.set_valign(Gtk.Align.CENTER)
    sw.set_active(active)
    if on_toggle:
        sw.connect("notify::active", on_toggle)
    row.pack_end(sw, False, False, 0)
    card.pack_start(row, False, False, 0)
    sw.pill = p
    # THE TOOLTIP HAS TO REACH THE WHOLE ROW, not just the widget.
    # Callers set the tooltip on the object this returns, which is the SWITCH: a
    # 46x24 target at the far right of a 780px row. Hovering the name, the note,
    # the icon or the badges, which is where a reader's pointer actually goes,
    # showed nothing at all. The operator: "many gtk tabs when you hoover ont he
    # control they are [expletive] missing the corect tool tip". Exposing the row lets
    # the caller tooltip both, and set_row_tooltip() below does exactly that.
    sw.row = row
    return sw


def fact_row(card, name, note=None, leading=None, tone=None, state_text=None,
             badges=None):
    """One READ-ONLY reading: optional icon, name, note, badges, live state pill.

    `switch_row` with the switch taken out. The pill is identical and is repointed by the same
    `set_pill()`, so a worker thread lands a firmware answer here exactly as it lands a switch
    state next door.

    THREE DELIBERATE DIFFERENCES FROM `switch_row`, each one load-bearing:

    1. NO Gtk.Switch. A switch on a reading invites a click that cannot do anything, and worse,
       the declarative Apply path compares switch positions to decide what to run. A row that
       cannot be applied must not present the widget Apply reads.

    2. NO `mark_control()`, AND THE REASON IS THE SIDEBAR COUNT, not the contract.
       An earlier version of this comment claimed it protected the direct-execution
       contract's actionable-control denominator. THAT WAS WRONG, and an inspector caught it:
       `mark_control()` feeds only `count_controls()`, which is what `_apply_nav_count()` renders
       as the `(n)` suffix on a rail entry. The generator's denominators are computed from the
       REGISTRY, not from marked widgets, and they moved anyway in the same commit that added
       these rows (commandWindowRows 396 -> 410, occurrences 582 -> 596, exactly +14).
       The decision is still right: `_apply_nav_count` renders a zero count as NO suffix, so a
       panel of pure readings shows "Firmware & Platform" rather than a misleading "(14)" that
       promises fourteen things to press.

    3. The pill starts VISIBLE with whatever `state_text` says, normally "reading", because unlike
       a switch there is no other widget carrying state. An invisible pill on a row with no switch
       is a row that says nothing at all while the worker runs.
    """
    row = cls(hbox(13), "row")
    if leading is not None:
        leading.set_valign(Gtk.Align.CENTER)
        row.pack_start(leading, False, False, 0)
    text = vbox(2)
    text.set_valign(Gtk.Align.CENTER)
    text.pack_start(lbl(name, "row-name"), False, False, 0)
    if note:
        text.pack_start(lbl(note, "row-note"), False, False, 0)
    row.pack_start(text, True, True, 0)
    for btext, btone in (badges or ()):
        row.pack_start(badge(btext, btone), False, False, 0)
    p = pill(state_text or "", tone or "off")
    p.set_visible(bool(state_text))
    p.set_no_show_all(not state_text)
    row.pack_end(p, False, False, 0)
    card.pack_start(row, False, False, 0)
    # Same shape switch_row returns, so set_pill() and set_row_tooltip() work unchanged on it.
    holder = _FactHandle(row, p)
    return holder


class _FactHandle:
    """What `fact_row` hands back: the pill to repoint, and the row to tooltip.

    A tiny object rather than the pill itself, because `set_row_tooltip` needs BOTH, and callers
    of `switch_row` already expect `.pill` and `.row` on whatever they receive. Keeping the same
    two attribute names means the settle path does not need to know which kind of row it holds.
    """

    __slots__ = ("row", "pill")

    def __init__(self, row, p):
        self.row = row
        self.pill = p


def set_row_tooltip(widget, text):
    """Put one tooltip on a control AND on the row it lives in.

    Every row-building helper returns the CONTROL (a Gtk.Switch, a
    Gtk.RadioButton), because that is what the caller needs to read a value from.
    Tooltipping only that leaves most of the row's width silent, so a user who
    hovers the label he is reading gets nothing. Both, always, through here.
    """
    widget.set_tooltip_text(text)
    row = getattr(widget, "row", None)
    if row is not None:
        row.set_tooltip_text(text)
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    if lines:
        set_control_accessibility(
            widget,
            lines[0],
            "\n".join(lines[1:]) if len(lines) > 1 else lines[0],
        )


TOGGLE_ON_MARK = "\u25c9"    # filled circle: this control is ON
TOGGLE_OFF_MARK = "\u25ce"   # hollow circle: this control is OFF


def state_toggle(button, text):
    """Make a Gtk.ToggleButton read as an ON/OFF control rather than a button.

    The label becomes "<mark> <text>" and the mark flips with the state, so the
    answer to "is Wrap on right now" is legible without hovering, without
    clicking, and without relying on the accent colour. Both marks are the same
    width, so the row does not reflow when a toggle is clicked.

    Returns the button so it can be used inline where `cls(...)` is today.
    """
    # The style hook. The stylesheet targets `button.statetoggle:checked` and
    # nothing wider, so opting in here is what makes a control look like a
    # toggle, and no control that skips this helper changes by one pixel.
    context = button.get_style_context()
    if hasattr(context, "add_class"):
        context.add_class("statetoggle")

    def _paint(*_args):
        mark = TOGGLE_ON_MARK if button.get_active() else TOGGLE_OFF_MARK
        button.set_label("%s %s" % (mark, text))

    _paint()
    button.connect("toggled", _paint)
    return button


def set_control_accessibility(widget, name, description=None):
    """Bind the visible row meaning to the real focusable GTK control.

    A generic button labelled Run or an otherwise unlabeled Gtk.Switch is not
    understandable to assistive technology merely because a nearby Gtk.Label
    looks correct. The accessible object belongs to the widget that receives
    focus, so name that exact object with the operation the row describes.
    """
    accessible = widget.get_accessible()
    if accessible is not None:
        accessible.set_name(name)
        accessible.set_description(description or name)
    return widget


def set_footer_primary_label(surface, label):
    """Retitle the Apply button so it names the choice that is actually staged.

    A radio window's Apply used to carry ONE static string for the whole window
    ("Route through Tor"), set once at build time. Selecting De-Torrify left the
    button still promising to route through Tor, so the button contradicted the
    row above it and the operator photographed exactly that. The footer note was
    made truthful earlier; the BUTTON was not, and the button is the control he
    reads before clicking. The tooltip and accessible name are rebuilt from
    `button.get_label()` by set_footer_pending, so callers pair the two.
    """
    button = getattr(surface, "primary_button", None)
    if button is None or not label:
        return False
    label = str(label)
    if button.get_label() == label:
        return False
    button.set_label(label)
    return True


def set_footer_pending(surface, pending_count):
    """Expose whether Apply has real work, both visually and accessibly."""
    button = getattr(surface, "primary_button", None)
    if button is None:
        return
    pending_count = max(0, int(pending_count))
    enabled = pending_count > 0
    button.set_sensitive(enabled)
    if enabled:
        noun = "change" if pending_count == 1 else "changes"
        message = f"{pending_count} {noun} pending"
        description = (
            f"{button.get_label()}: apply {pending_count} staged {noun}. "
            "Untouched controls are left alone.")
    else:
        message = "No changes pending"
        description = (
            f"{button.get_label()} is unavailable because no control has changed.")
    note = getattr(surface, "footer_note", None)
    if note is not None:
        note.set_text(message)
    button.set_tooltip_text(description)
    set_control_accessibility(button, button.get_label(), description)


def radio_row(card, group, name, note=None, leading=None, code=None,
              active=False, tone=None, state_text=None, badges=None):
    """One radio row, returns the radio so the caller can read the choice.

    `badges` are STATIC facts about the choice ("Security 9/10", "Encrypted"),
    drawn as dot ratings or pills between the text and any live-state pill.
    They exist because
    a list of protocol names is not a comparison: the operator's own reading of
    the VPN list was that mita and dante looked SAFER than v2ray and AmneziaWG,
    which is the exact opposite of the truth, and nothing on the row said so.
    """
    row = mark_control(cls(hbox(13), "row"))
    rb = Gtk.RadioButton.new_from_widget(group)
    rb.set_valign(Gtk.Align.CENTER)
    rb.set_active(active)
    row.pack_start(rb, False, False, 0)
    if leading is not None:
        leading.set_valign(Gtk.Align.CENTER)
        row.pack_start(leading, False, False, 0)
    text = vbox(2)
    text.set_valign(Gtk.Align.CENTER)
    text.pack_start(lbl(name, "row-name"), False, False, 0)
    if note:
        text.pack_start(lbl(note, "row-note"), False, False, 0)
    row.pack_start(text, True, True, 0)
    for btext, btone in (badges or ()):
        row.pack_start(badge(btext, btone), False, False, 0)
    if state_text:
        row.pack_start(pill(state_text, tone or "info"), False, False, 0)
    if code:
        row.pack_end(lbl(code, "row-code"), False, False, 0)
    card.pack_start(row, False, False, 0)
    rb.row = row          # see the note in switch_row(): tooltip the whole row
    return rb
