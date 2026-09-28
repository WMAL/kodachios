#!/usr/bin/env python3
# Kodachi Command Windows - Window Definitions
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
# Every command window except the two Tor country pickers, expressed as DATA.
# Adding a window is a table entry here, not a new program.
#
# NO COMMAND STRING APPEARS IN THIS FILE. Every row names a (Category, Label)
# pair from the shipped action registry, usr/local/lib/kodachi-rofi/
# menu-actions.sh, and the driver resolves it at run time.
#
# That indirection is not decoration, it is the fix for a real defect. The first
# draft of this file COPIED the command strings, and when they were checked
# against the registry almost every one was wrong in a way that still looked
# plausible: `routing-switch reset` is really `reset --force`, `auto` is really
# `auto-select --json`, `socks-enable` is really `microsocks-enable` with a
# credential the registry handler mints per invocation (D29; it used to carry a
# fixed literal here), `tor-switch verify` is really `torverify`, `start-main` is really
# `start-tor`, `new-circuit` is really `new-circuit-main-tor`, `panic --level
# soft` is really `panic-soft`, and Torrify is a three-command chain rather than
# one word. A window that shipped those would have failed at the moment of use,
# with the operator holding the bag.
#
# So: one source of truth, and `--validate` proves every reference resolves.
#
# ROW KINDS
#   switch   on / off / check, each a registry key. `check` runs before the
#            window draws so the control shows the state that IS. Apply runs
#            only what CHANGED, so opening and closing a window does nothing.
#   choice   one radio group per section; Apply runs the selected row's action.
#   action   a button that runs immediately. `danger` paints it red, `confirm`
#            makes it ask first.
#   report   a button that runs a read-only action and shows its output.
#   surface  a More button that opens an existing full command window, with an
#            optional initial tab. It never copies that window's controls.
#   sandbox  an allowlisted application launched through the dedicated
#            Firejail wrapper. It never carries a command string.
#
# A row with no `check` opens in the UNKNOWN position and says so, rather than
# showing a confident OFF for something nobody measured.

DEV = "Device Control"
SVC = "System Services"
HRD = "Hardening"
IDN = "Identity"
PRV = "Privacy Tools"
DNS = "DNS"
RTG = "Routing"
TOR = "Tor"
EMG = "Emergency"
DSP = "Display & Power"
NET = "Network Tuning"
MNT = "Maintenance"
IPN = "IP & Network"
SWP = "Swap & Memory"
STU = "Storage & USB"
DSK = "Desktop"
SES = "Session Status"
WFL = "Workflows"


def sw(name, on, off, check=None, icon=None, note=None, cat=DEV, check_cat=None,
       badges=None, recovery=False, confirm=False, success_output=False,
       launcher=None):
    """One switch. `check_cat` exists because a status row does not always live
    in the same category as the actions it describes.

    USB Guard is the case that forced it: `USB Guard Enable` and `USB Guard
    Disable` are filed under Hardening while `USB Guard Status` is filed under
    Storage & USB. With a single `cat` this helper could not express that, so
    the switch shipped with check=None and could never show the state that IS.
    That is the same defect as Block Internet and its undo living in different
    categories, reappearing one level down in my own helper: a filing taxonomy
    is not a description of how the pieces relate.
    """
    return {"kind": "switch", "name": name, "note": note, "icon": icon,
            "on": (cat, on), "off": (cat, off),
            "check": ((check_cat or cat), check) if check else None,
            "badges": badges, "recovery": recovery, "confirm": confirm,
            "effect": "mutating", "success_output": success_output,
            "launcher": launcher}


# ── RECOVERY ROWS: EXEMPT FROM THE REGISTRY'S confirm BIT ───────────────────
#
# The driver reads column 3 of the action registry and asks before running any
# row the registry marks confirm=1. That is right for the 40 unguarded rows the
# 2026-08-19 audit found, and WRONG for nine of them, which is the qualifier
# <agent> added by reading the registry BY CATEGORY:
#
#     29 of 32 Emergency rows carry confirm=1, INCLUDING Panic Recover,
#     Disarm Kill Switch, Create Recovery Point and all four Unblock rows.
#
# So in that category the bit is a CATEGORY-LEVEL "this surface can be
# mis-clicked" policy, not a per-row danger judgement. Honouring it wholesale
# would put a modal in front of THE UNDO, at the exact moment the user has just
# cut their own network and needs one click, which is worse than the hole it
# closes. One field, two axes.
#
# `recovery=True` is the explicit, per-row, reviewable exemption. It never
# silences a row that declares `confirm=True` here, and it never expands on its
# own: a new registry row is protected by default and only becomes exempt when
# somebody writes the word on it and says why.
#
# IT IS ALSO BOUNDED BY CATEGORY, AND MY FIRST VERSION WAS NOT. I measured the
# 85% blanket in Emergency and then applied the conclusion in three categories
# where I had measured nothing. Re-derived per category:
#
#     Emergency  29/34 = 85%   blanket, so the bit is a mis-click policy
#     Identity    4/19 = 21%   \
#     Hardening   5/32 = 15%    >  a deliberate PER-ROW judgement
#     Tor        11/82 = 13%   /
#
# Below 85% the author flagged individual rows on purpose, and exempting one of
# those re-opens exactly the split this whole change exists to close: the dock
# cell and rofi ask, the window row does not. The tell was sitting in the
# registry: `USB Guard Enable` is confirm=1 while `USB Guard Disable` is
# confirm=0, an ASYMMETRIC pair, which no blanket policy produces.
#
# So the exemption is SIX rows and all six are Emergency undos: the five Unblock
# Internet rows and Panic Recover. USB Guard Enable, Reset MAC, De-Torrify and
# Disarm Kill Switch were exempt for one commit and are not any more. The last
# three are TIER 2 by the registry's own doc block above, "recoverable from the
# dock, but silently drops a protection the user believes is on", which is the
# definition of a row that should ask.


# ── STATIC BADGES ───────────────────────────────────────────────────────────
#
# WHY THESE EXIST. The operator read the Connect list and said: "peope seing the
# list woudl think mita and dante are more secure then v2ray and amzin wg !!!
# its confusing". He is right, and the list caused it. A column of protocol
# names carries no comparison, so the reader supplies one, and the one they
# supply here is backwards: dante is a PLAIN SOCKS5 proxy with no encryption at
# all and it sat two rows below WireGuard looking like a peer of it.
#
# TWO SEPARATE SCALES, because collapsing them is what made the list mislead.
#   SECURITY  how strong the encryption and authentication protecting the
#             traffic is. It says nothing about speed and nothing about whether
#             a censor can SEE that you are tunnelling: that second property is
#             what the "Obfuscated" / "Not obfuscated" grouping already says,
#             and doubling it into the number would make dante and WireGuard
#             look closer than they are.
#   SPEED     throughput and latency you can expect on a normal link.
#
# The numbers are a RANKING, not a measurement, and they are ordinal: what is
# load-bearing is that dante is 1 and WireGuard is 10, not that hysteria2 is 9
# rather than 8. Basis, one line each:
#   10  WireGuard        Noise handshake, ChaCha20-Poly1305, tiny attack surface
#    9  AmneziaWG        WireGuard's crypto unchanged, only the handshake shape
#    9  OpenVPN, hysteria2, reality   TLS 1.3 / mature OpenVPN TLS+AES-GCM
#    8  xray-vless, xray-trojan       TLS transport, thinner authentication story
#    7  xray-vmess, v2ray, mita       AEAD, but older or less reviewed designs
#    6  shadowsocks      AEAD ciphers, no TLS-grade handshake authentication
#    1  dante            SOCKS5 in the clear: no encryption whatsoever
# SPEED IS THE OPERATOR'S OWN RANKING, given 2026-08-19: "hysteria2 is the
# fastest ! then wiregard so hystrea2 i woudl give it 10/10 but wg I would give
# it 8/10 then the rest will floow". So hysteria2 10, WireGuard 8, and the rest
# ladder down from there: AmneziaWG 7 (WireGuard plus junk packets on every
# handshake), the Xray family and shadowsocks and dante 6-7, mita 6, OpenVPN 5
# (userspace plus TLS framing), OpenVPN over Cloak 4 (TCP inside TCP, which
# collapses on a lossy link), Remote Tor 2 (three relays before the exit).


def _sec_tone(v):
    return "on" if v >= 9 else "info" if v >= 7 else "warn" if v >= 4 else "danger"


def _spd_tone(v):
    return "on" if v >= 9 else "info" if v >= 7 else "warn" if v >= 5 else "off"


def scores(security, speed):
    """The two badges every transport row carries."""
    return [(f"Security {security}/10", _sec_tone(security)),
            (f"Speed {speed}/10", _spd_tone(speed))]


ENC = ("Encrypted", "on")
NOENC = ("Not encrypted", "danger")
TORDNS = ("DNS through Tor", "on")
NOTORDNS = ("DNS not through Tor", "danger")

# WHICH TORRIFY MODES CARRY DNS, AND HOW I GOT IT WRONG THE FIRST TIME.
# I derived this from the registry ROW's command chain, marking a row TORDNS only
# when it contained an explicit `start-tor-dns-nftables` step. That marked the three
# Balanced modes as leaking DNS, the operator said that was wrong, and he was right:
# the chain is not the behaviour. `tor-switch torrify-system-nftables-load-balanced`
# redirects DNS ITSELF. firewall.rs:7409 says "DNS will be load balanced along with
# TCP traffic", and generate_round_robin_rules emits, per Tor instance,
#     add rule inet tor output_nat ... udp dport 53 meta mark <i> redirect to :<dnsport>
# plus the TCP twin (firewall.rs:7686-7702); the weighted and consistent generators do
# the same, deliberately under consistent hashing so a query and its response reach the
# same instance. The dashboard runs the identical two steps
# (commands_tor.rs:566-585), so the dock and the dashboard agree.
#
# The ONE mode that genuinely has no DNS is `torrify-system-iptables`, and that is the
# binary's own words, not mine: firewall.rs:3193 logs "WARNING: This command does NOT
# redirect DNS. Without DNS, internet may not work. Use torrify-system-iptables-dns
# instead."
#
# So: read what the COMMAND DOES, never what the command LINE contains.


def ch(name, label, icon=None, note=None, cat=RTG, badges=None, recovery=False,
       confirm=False, success_output=False):
    return {"kind": "choice", "name": name, "note": note, "icon": icon,
            "act": (cat, label), "badges": badges, "recovery": recovery,
            "confirm": confirm, "effect": "mutating",
            "success_output": success_output}


def act(name, label, icon=None, note=None, cat=EMG, danger=False, confirm=False,
        recovery=False, execution="wait", handoff=False, success_output=False,
        success_summary=None, failure_summary=None, effect=None,
        workflow_meta=None):
    if execution == "launch" and effect is None:
        raise ValueError("launch actions must declare their effect")
    if success_summary is not None:
        if success_output is not True:
            raise ValueError("success summaries require success_output=True")
        if not isinstance(success_summary, str) or not success_summary.strip():
            raise ValueError("success summaries must be non-empty text")
    if (failure_summary is not None
            and (not isinstance(failure_summary, str)
                 or not failure_summary.strip())):
        raise ValueError("failure summaries must be non-empty text")
    return {"kind": "action", "name": name, "note": note, "icon": icon,
            "act": (cat, label), "danger": danger, "confirm": confirm,
            "recovery": recovery, "execution": execution, "handoff": handoff,
            "effect": effect or "mutating",
            "success_output": success_output, "success_summary": success_summary,
            "failure_summary": failure_summary,
            "workflow_meta": workflow_meta}


def rep(name, label, icon=None, note=None, cat=DEV, execution="wait", handoff=False,
        effect=None, workflow_meta=None):
    if execution == "launch" and effect is None:
        raise ValueError("launch reports must declare their effect")
    return {"kind": "report", "name": name, "note": note, "icon": icon,
            "act": (cat, label), "execution": execution, "handoff": handoff,
            "effect": effect or "read-only",
            "success_output": execution != "launch",
            "workflow_meta": workflow_meta}


def fct(name, key, icon=None, note=None):
    """One READ-ONLY reading in a `mode: "facts"` section.

    `key` binds the row to a field in the section source's JSON reply. It is NOT a command: the
    command belongs to the section, is declared once, and is run once for the whole section, so a
    twenty-row panel costs one privileged subprocess rather than twenty.

    A fact row has no switch and no button, which is the point. The firmware panel is a list of
    values the machine reports; offering a control on a reading invites a click that can only
    disappoint, and the Apply path compares switch positions, so a decorative switch here would be
    a hazard rather than a cosmetic mismatch.
    """
    return {"kind": "fact", "name": name, "key": key, "icon": icon, "note": note,
            "effect": "read-only", "success_output": False}


def checked(row, required_all=(), required_any=()):
    """Declare the real executable preflight for one Verify-surface row.

    The registry remains the source of truth for the primary command.  These
    fields describe only requirements hidden behind that command, such as the
    two interchangeable ClamAV front ends.
    """
    row["check_tools"] = True
    row["required_all"] = tuple(required_all)
    row["required_any"] = tuple(tuple(group) for group in required_any)
    return row


def surface(name, target, icon=None, note=None, tab=None):
    return {"kind": "surface", "name": name, "note": note, "icon": icon,
            "surface": target, "tab": tab, "effect": "launch",
            "success_output": False}


def sandbox(name, app_id, executable, icon=None, note=None, profile="default"):
    """One reviewed Firejail target, identified by a fixed application ID."""
    if profile not in ("dedicated", "default"):
        raise ValueError("sandbox profile must be dedicated or default")
    return {"kind": "sandbox", "name": name, "note": note, "icon": icon,
            "app_id": app_id, "executable": executable, "profile": profile,
            "effect": "launch", "success_output": False}


# ── the isolation runtimes, and why the third one is usually refused ───────
#
# NATIVE IS OFFERED ON PURPOSE AND IS NEVER THE DEFAULT. The window exists so
# the user can COMPARE two isolation runtimes, and a comparison with its
# baseline hidden is not a comparison. The native arm goes through the same
# adapter, the same allowlist and the same root-owned-ancestry validation as the
# Firejail arm, so it is a labelled choice rather than a weaker door.
#
# PODMAN IS REFUSED FOR EVERY GRAPHICAL APPLICATION, and that is a property of
# the shipped container, not of the application. `add-rootless-podman-containers`
# states as an explicit non-goal: no GUI application inside Podman and no X11 or
# Wayland socket sharing. A container with no display socket can run a shell and
# cannot draw a window, so offering Podman on LibreWolf would be offering
# something that fails after the click. It is rendered INSENSITIVE WITH ITS
# REASON rather than hidden, because a hidden control leaves the user asking
# whether Kodachi supports it and a disabled one answers.
ISOLATION_RUNTIMES = ("native", "firejail", "podman")
ISOLATION_DEFAULT_RUNTIME = "firejail"
NO_DISPLAY_REASON = (
    "Kodachi containers run with no X11 or Wayland socket, so a graphical "
    "application cannot draw from inside one."
)
# THE SECOND REASON, AND NAMING THE WRONG ONE IS A DEFECT, NOT A WORDING
# CHOICE. Until 2026-08-25 every refused PODMAN arm said NO_DISPLAY_REASON,
# including on a machine with no Podman installed at all. So the window told
# the operator that his container had no display socket when the truth was
# that there was no container runtime on the box to have one. He read the
# greyed chip next to a "not run" pill and asked, correctly, "why i cant run
# pdaman and it says not run". A window that answers with the wrong cause is
# worse than one that says nothing, because it sends the reader to fix the
# wrong thing.
PODMAN_ABSENT_REASON = (
    "Podman is not installed on this system, so no container can be started "
    "here at all. Kodachi's live ISO ships it."
)


def isolated(name, app_id, executable, icon=None, note=None, profile="default",
             podman=False):
    """One reviewed application plus the runtimes it may be launched under.

    `podman` is the ONLY per-row runtime flag, because native and Firejail are
    available for every reviewed application by construction: they both run a
    program that is already installed on this host. `podman` must equal the
    adapter's CONTAINER_CAPABLE table, and tests/test_isolation_launcher.py
    asserts that in both directions so the two cannot drift apart silently.
    """
    if profile not in ("dedicated", "default"):
        raise ValueError("isolated profile must be dedicated or default")
    return {"kind": "isolated", "name": name, "note": note, "icon": icon,
            "app_id": app_id, "executable": executable, "profile": profile,
            "podman": bool(podman),
            "default_runtime": ISOLATION_DEFAULT_RUNTIME,
            "effect": "launch", "success_output": False}


CONTAINER_MANAGER = "/usr/local/libexec/kodachi/kodachi-container-manager"
FIREJAIL_WIZARD = "/usr/bin/firejail-ui"
FIRETOOLS = "/usr/bin/firetools"


def launch(name, argv, icon=None, note=None, terminal=None, danger=False):
    """One fixed local command this declaration owns, as argv, never a string.

    `argv` is a tuple of literals. It is never joined, never passed to a shell
    and never built from anything the user typed, which is the same boundary the
    isolation adapter holds: the window names a thing to run, it does not
    compose a command.

    `terminal` is the window title to open the command in when it needs an
    interactive pty. A read-only verb leaves it None and reports into the page's
    own result pane instead, which is what those six Cairo cells were using a
    `--hold` terminal to fake.
    """
    if not isinstance(argv, tuple) or not argv:
        raise ValueError("launch argv must be a non-empty tuple of literals")
    if not all(isinstance(item, str) for item in argv):
        raise ValueError("launch argv must contain only string literals")
    if not argv[0].startswith("/"):
        raise ValueError("launch argv[0] must be an absolute path")
    return {"kind": "launch", "name": name, "note": note, "icon": icon,
            "argv": argv, "terminal": terminal, "danger": bool(danger),
            "effect": "launch", "success_output": terminal is None}


WINDOWS = {
    "devices": {
        "title": "Devices",
        "subtitle": "Hardware that can see, hear or carry data off this machine.",
        "apply_label": "Apply device changes",
        "sections": [
            {"caption": "Radios and sensors", "mode": "switch", "rows": [
                sw("WiFi", "WiFi Enable", "WiFi Disable", "WiFi Status",
                   "papirus/network-wireless.svg"),
                sw("Bluetooth", "Bluetooth Enable", "Bluetooth Disable", "Bluetooth Status",
                   "papirus/bluetooth.svg"),
                sw("Webcam", "Webcam Enable", "Webcam Disable", "Webcam Status",
                   "papirus/camera-web.svg"),
                sw("Microphone", "Microphone Enable", "Microphone Disable", "Microphone Status",
                   "papirus/audio-input-microphone.svg"),
                sw("USB storage", "USB Storage Enable", "USB Storage Disable", "USB Storage Status",
                   "usb_drive.png", "Blocks mass storage. Keyboards and mice keep working."),
                sw("USBGuard protection", "USB Guard Enable", "USB Guard Disable",
                   "USB Guard Status", "papirus/usbguard-icon.svg",
                   "Blocks USB devices that are not allowed by the active USBGuard rules.",
                   cat=HRD, check_cat=STU),
                sw("Mobile modem", "ModemManager Enable", "ModemManager Disable", "ModemManager Status",
                   "papirus/network-modem.svg"),
            ]},
            # Parameter-requiring storage actions are deliberately absent.
            # The registry entries for persistence, container create/mount/
            # unmount and storage wipe omit mandatory target/path/password
            # inputs. Rendering those incomplete invocations as Run buttons
            # made a parse error or an inaccessible stdin prompt look like a
            # working product control. Keep only complete read-only commands
            # until a parameter-capable GTK flow exists.
            {"caption": "Encrypted storage", "mode": "action",
             "rows": [
                rep("Encryption status", "Encryption Status",
                    "papirus/preferences-certificates.svg", cat=STU),
                rep("LUKS volumes", "LUKS Manage List",
                    "papirus/kgpg.svg", cat=STU),
             ]},
            {"caption": "USB inspection", "mode": "action", "rows": [
                rep("Connected devices", "USB List", "hdd_usb_unmount.png", cat=STU),
                rep("Device policies", "USB Policy List", "papirus/checkbox.svg"),
                rep("USBGuard whitelist", "USB Whitelist List",
                    "papirus/preferences-desktop-peripherals.svg"),
                rep("Connection history", "USB History", "fluent-emoji/scroll.png", cat=STU),
                rep("Safety check", "USB Safety Check", "papirus/usbguard-icon.svg", cat=STU),
                rep("Watch USB connections for 30 seconds", "USB Monitor",
                    "papirus/gnome-system-monitor.svg"),
            ]},
        ],
    },

    "services": {
        "title": "Services",
        "subtitle": "Background daemons, and the ones that talk to the network.",
        "apply_label": "Apply service changes",
        "sections": [
            {"caption": "Remote access", "mode": "switch", "rows": [
                sw("SSH server", "SSH Enable", "SSH Disable", "SSH Status",
                   "papirus/putty.svg", "Lets other machines log in to this one.", cat=SVC),
            ]},
            {"caption": "Peer to peer", "mode": "switch", "rows": [
                sw("Syncthing", "Syncthing Start", "Syncthing Stop", "Syncthing Status",
                   "papirus/syncthingtray.svg", "File sync, runs as your user.", cat=SVC,
                   launcher=checked(rep(
                       "Open Syncthing", "Syncthing Web UI",
                       "papirus/web-browser.svg", cat=SVC,
                       execution="launch", handoff=True, effect="launch"))),
                sw("GnuNet", "GnuNet Start", "GnuNet Stop", "GnuNet Status",
                   "papirus/org.gnunet.Messenger.svg", cat=SVC,
                   launcher=checked(rep(
                       "Open GnuNet", "GnuNet UI",
                       "papirus/org.gnunet.Messenger.svg", cat=SVC,
                       execution="launch", handoff=True, effect="launch"))),
            ]},
            {"caption": "Protection", "mode": "switch", "rows": [
                sw("Intrusion guard", "Intrusion Guard Start", "Intrusion Guard Stop",
                   "Intrusion Guard Status", "papirus/yast-security.svg",
                   "fail2ban, bans repeated failed logins.", cat=SVC),
            ]},
            {"caption": "Traces and discovery", "mode": "switch", "rows": [
                sw("System logs", "System Logs Enable", "System Logs Disable",
                   "System Logs Status",
                   "papirus/gnome-logs.svg",
                   "Off stops journald keeping a record.", cat=SVC),
            ]},
            # THESE ARE STATES, NOT ERRANDS. They shipped as one-way "Run"
            # buttons under a heading that said "Turn off", so the window could
            # not tell you whether printing was already off and clicking twice
            # meant nothing. The operator: "they should be toggle controls based
            # on their status! this is wrong".
            #
            # Every one of the five has a full Enable/Disable/Status triplet in
            # the registry, checked before this was written, so nothing here is
            # invented: the switch reads the same Status the rofi menu reads.
            {"caption": "Exposure", "mode": "switch", "rows": [
                sw("Printing (CUPS)", "CUPS Enable", "CUPS Disable", "CUPS Status",
                   "papirus/cups.svg",
                   "A print service listening on this machine.", cat=SVC),
                sw("Network discovery (Avahi)", "Avahi Enable", "Avahi Disable", "Avahi Status",
                   "papirus/network-workgroup.svg",
                   "On announces this machine to everyone on the local network.", cat=SVC),
                sw("Shell history", "Command History Enable", "Command History Disable",
                   "Command History Status", "papirus/utilities-terminal.svg",
                   "Off stops your commands being written to disk.", cat=SVC),
                sw("Auto login", "Auto Login Enable", "Auto Login Disable", "Auto Login Status",
                   "papirus/system-users.svg",
                   "On means anyone who powers this machine on is you.", cat=SVC),
                sw("Screen lock", "Screen Lock Enable", "Screen Lock Disable", "Screen Lock Status",
                   "papirus/system-lock-screen.svg", cat=SVC),
            ]},
            {"caption": "Maintenance", "mode": "action", "rows": [
                act("Restart NetworkManager", "NetworkManager Restart",
                    "papirus/tdenetworkmanager.svg", cat=SVC),
                act("Regenerate SSH host keys", "Regenerate SSH Host Keys",
                    "papirus/keysmith.svg",
                    "Every client that trusted this machine warns on next connect.",
                    cat=SVC, confirm=True),
            ]},
        ],
    },

    "harden": {
        "title": "Hardening",
        "subtitle": "Defences that stay on in the background.",
        "apply_label": "Apply protection changes",
        "sections": [
            {"caption": "Profile", "mode": "choice", "rows": [
                ch("Standard", "Harden Standard", "papirus/security-medium.svg",
                   "The balanced set. Everything still works normally.", cat=HRD),
                ch("Medium", "Harden Medium", "papirus/security-medium.svg",
                   "Enhanced protection. Browsers and internet still work.", cat=HRD),
                ch("Paranoid", "Harden Paranoid", "papirus/security-high.svg",
                   "Maximum. Expect some conveniences to stop working.", cat=HRD),
                act("Reset hardening", "Security Reset", "papirus/ubuntu-cleaner.svg",
                    "Undoes every hardening change and returns to defaults.",
                    cat=HRD, danger=True, confirm=True),
            ]},
            {"caption": "Individual defences", "mode": "switch", "rows": [
                sw("Hide typing rhythm", "Kloak Enable", "Kloak Disable", "Kloak Status",
                   "fluent-emoji/keyboard.png",
                   "kloak. Masks the timing between your keystrokes.", cat=HRD),
                sw("Randomise TCP numbers", "Tirdad Enable", "Tirdad Disable",
                   "Tirdad Status",
                   "papirus/nm-device-wireless.svg",
                   "tirdad. Stops sequence numbers linking your connections.", cat=HRD),
                # `check` was None, so the row drew permanently unknown and its
                # generated tooltip stated "This feature has no status command",
                # which is false: Hardening / Cold Boot Status runs
                # coldboot-defense-status and the binary describes it as "Check
                # cold boot defense mechanisms status".
                sw("Cold boot defence", "Cold Boot Defense Enable", "Cold Boot Defense Disable",
                   "Cold Boot Status", "papirus/gnome-dev-memory.svg",
                   "Clears keys from RAM so a frozen memory chip gives nothing up.", cat=HRD),
                sw("Wipe RAM at shutdown", "RAM Wipe Enable", "RAM Wipe Disable",
                   "RAM Wipe Status",
                   "Memory-Freer-icon.png", cat=HRD),
                # THE STATUS COMMAND EXISTED ALL ALONG AND THE SWITCH DID NOT
                # READ IT. `check` was None, so this control could never show
                # the state that IS and opened permanently unknown. The
                # operator's complaint about the K8 carry-over was exactly this:
                # "all four K9 rows only look ... the user can read the policy
                # and cannot change it". The change half was here; what was
                # missing was the READ that makes a switch honest.
                #
                # `Storage & USB / USB Guard Status` runs `health-control
                # usb-status` and is a shipped registry row, so nothing new is
                # invented, it is simply wired to the control it describes.
                # A switch whose off command exists but whose status does not is
                # worse than a button: it renders a confident position nobody
                # measured.
                sw("Block unknown USB", "USB Guard Enable", "USB Guard Disable",
                   "USB Guard Status", "papirus/security-high.svg",
                   "usbguard. New devices are refused until you allow them.",
                   cat=HRD, check_cat=STU),
                sw("Answer ping", "Unblock Ping (ICMP)", "Block Ping (ICMP)", None,
                   "papirus/network-wired.svg",
                   "Off makes this machine invisible to a plain ICMP probe.", cat=IPN),
            ]},
            {"caption": "Swap", "mode": "action", "rows": [
                act("Encrypt swap", "Swap Encrypt", "papirus/kgpg.svg",
                    "Anything paged out of RAM stops being readable on disk.", cat=SWP, danger=True, confirm=True),
                sw("Swap", "Activate Configured Swap", "Deactivate Configured Swap", "Swap Status",
                   "papirus/gnome-power-statistics.svg",
                   "On reactivates existing configured swap only; off deactivates it without removing encrypted mappings.", cat=SWP),
                rep("Swap status", "Swap Status", "papirus/gnome-disks.svg", cat=SWP),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Verify hardening", "Security Verify", "papirus/chkrootkit.svg", cat=HRD),
                rep("IPv6 status", "IPv6 Status", "ipv6on.png", cat=HRD),
                rep("Watchguard", "Watchguard Status", "papirus/preferences-system-privacy.svg",
                    cat=HRD),
                rep("Auto updates", "Auto Updates Status", "papirus/system-software-update.svg",
                    cat=MNT),
            ]},
        ],
    },

    "identity": {
        "title": "Identity",
        "subtitle": "What this machine says about itself on the wire.",
        "apply_label": "Apply identity changes",
        "sections": [
            {"caption": "MAC address", "mode": "action", "rows": [
                act("Randomise", "Randomize MAC", "papirus/network-card.svg",
                    "New hardware address on every interface.", cat=IDN),
                act("Restore real", "Reset MAC", "papirus/network-wired.svg", cat=IDN),
                rep("Show current", "Show MAC Addresses", "papirus/office-address-book.svg",
                    cat=IDN),
            ]},
            {"caption": "Hostname", "mode": "action", "rows": [
                act("Randomise", "Randomize Hostname", "papirus/computersettings.svg", cat=IDN),
                act("Restore default", "Set Default Hostname", "papirus/user-admin.svg", cat=IDN),
                rep("Show current", "Get Hostname", "papirus/user-info.svg", cat=IDN),
            ]},
            {"caption": "Timezone", "mode": "action", "rows": [
                act("Randomise", "Randomize Timezone", "fluent-emoji/shuffle-tracks-button.png",
                    "A clock that disagrees with your real location.", cat=IDN),
                act("Match my exit IP", "Sync Timezone", "papirus/gnome-clocks.svg", cat=IDN),
                rep("Show local", "Show Timezone", "papirus/time-admin.svg", cat=IDN),
                rep("Show what my IP says", "Show Remote Timezone", "papirus/gis-weather.svg",
                    cat=IDN),
            ]},
            # THE SWITCH IS NOT A REPORT, AND THIS SECTION NEEDED BOTH.
            #
            # The operator, 2026-08-23, on the shipped window: "we dont have a
            # button to show what is the status of ip v6 enabled or disabled",
            # and on the row below it, "this should show the terminal window and
            # show the decoy traffic while its working!! now nothing happens
            # when you enable it".
            #
            # Every OTHER section in this window pairs its actions with a "Show
            # current" report; this one shipped with neither, so the switch
            # position was the only thing a user could read, and when the state
            # could not be read it showed a pill and nothing else. A switch says
            # on or off. It cannot say WHICH addresses are up, or what the
            # generator has actually been fetching.
            {"caption": "Network stack", "mode": "switch", "rows": [
                sw("IPv6", "IPv6 Enable", "IPv6 Disable", "IPv6 Status", "ipv6on.png",
                   "Off is the safer default: IPv6 leaks around some tunnels.", cat=IDN, check_cat=HRD),
                rep("Show current", "IPv6 Status", "ipv6on.png",
                    "Whether IPv6 is on right now, and on which interfaces.", cat=HRD),
                sw("Decoy traffic", "Decoy Traffic Start", "Decoy Traffic Stop",
                   "Decoy Traffic Status", "papirus/speed-dreams.svg",
                   "Cover traffic, so your real pattern is harder to read.", cat=PRV,
                   success_output=True),
                rep("Show current", "Decoy Traffic Status", "papirus/gnome-system-monitor.svg",
                    "Whether the generator is running, and its last few requests.", cat=PRV),
                # act(), not rep(): this opens a detached terminal, and rep() in
                # this module means "runs a read-only action and shows its output
                # HERE". Same call the Tor Circuit Monitor row makes.
                act("Watch it live", "Decoy Traffic Watch", "papirus/utilities-terminal.svg",
                    "Opens a terminal that follows the cover traffic as it happens. "
                    "Closing it does not stop the generator.",
                    cat=PRV, execution="launch", handoff=True, effect="launch"),
            ]},
        ],
    },

    "dns": {
        "title": "DNS",
        "subtitle": "Who resolves your names, and whether anyone can read them.",
        "apply_label": "Apply DNS changes",
        "sections": [
            {"caption": "Resolver", "mode": "choice", "rows": [
                ch("Encrypted (DNSCrypt)", "Enable DNSCrypt", "fluent-emoji/locked-with-key.png",
                   "Queries are encrypted and authenticated.", cat=DNS, badges=[ENC]),
                ch("Plain, no encryption", "Disable DNSCrypt", "fluent-emoji/unlocked.png",
                   "Anyone on the path can read every name you look up.",
                   cat=DNS, badges=[NOENC]),
                ch("Random public resolver", "Random DNS", "fluent-emoji/game-die.png",
                   "A different provider each time, in the clear.", cat=DNS, badges=[NOENC]),
                ch("Fallback", "Fallback DNS", "papirus/network-modem.svg",
                   "The built-in pool, used when nothing else resolves.",
                   cat=DNS, badges=[NOENC]),
                ch("System default", "Restore Default DNS", "papirus/kfoldersync.svg",
                   "Whatever the network handed out over DHCP.", cat=DNS, badges=[NOENC]),
            ]},
            {"caption": "Filtering", "mode": "switch", "rows": [
                sw("Pi-hole", "Pi-hole Enable", "Pi-hole Disable", "Pi-hole Status",
                   "papirus/network-server-database.svg",
                   "Blocks ad and tracker domains before they resolve.", cat=DNS),
            ]},
            {"caption": "Repair", "mode": "action", "rows": [
                act("Fix DNS", "Fix DNS", "fluent-emoji/wrench.png",
                    "Rewrites the resolver config when lookups have stopped.", cat=DNS),
                act("Flush cache", "Flush DNS Cache", "fluent-emoji/sponge.png", cat=DNS),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Status", "DNS Status", "pdns.png", cat=DNS),
                rep("DNSCrypt status", "DNSCrypt Status", "dnscryptt.png",
                    cat=DNS),
                rep("Servers in use", "List DNS Servers", "fluent-emoji/ledger.png", cat=DNS),
                rep("Health check", "DNS Health Check", "fluent-emoji/medical-symbol.png", cat=DNS),
                rep("Leak test", "DNS Leak Test", "fluent-emoji/droplet.png",
                    "Asks whether your queries are escaping the tunnel.", cat=DNS),
                rep("Leak discover", "DNS Leak Discover",
                    "fluent-emoji/magnifying-glass-tilted-right.png", cat=DNS),
            ]},
        ],
    },

    "vpn": {
        "title": "Connect",
        "subtitle": "Pick how this machine reaches the internet.",
        "apply_label": "Connect",
        "sections": [
            {"caption": "Not obfuscated",
             "note": "Faster, and recognisable for what they are to anyone watching. Security and Speed are scored out of 10.",
             "mode": "choice", "rows": [
                ch("WireGuard", "Connect WireGuard", "papirus/network-vpn.svg",
                   "Modern, small, and second only to hysteria2 here.", badges=scores(10, 8)),
                ch("hysteria2", "Connect hysteria2", "fluent-emoji/rocket.png",
                   "The fastest of these, and the best on a lossy link.", badges=scores(9, 10)),
                ch("OpenVPN", "Connect OpenVPN", "dashboard-icons/openvpn.svg",
                   "Mature and widely supported, but slower.", badges=scores(9, 5)),
                ch("mita", "Connect mita", "papirus/network-modem.svg",
                   "An encrypted proxy (mieru).", badges=scores(7, 6)),
                ch("dante", "Connect dante", "papirus/network-server.svg",
                   "A plain SOCKS proxy on the VPS. Not encrypted.",
                   badges=scores(1, 7)),
            ]},
            {"caption": "Obfuscated",
             "note": "Designed to look like ordinary traffic to a censor.",
             "mode": "choice", "rows": [
                ch("AmneziaWG", "Connect AmneziaWG", "papirus/airvpn.svg",
                   "WireGuard with the handshake disguised.", badges=scores(10, 7)),
                ch("OpenVPN over Cloak", "Connect OpenVPN over Cloak",
                   "fluent-emoji/disguised-face.png", "OpenVPN wrapped so it reads as normal TLS.",
                   badges=scores(9, 4)),
                ch("xray-vless-reality", "Connect xray-vless-reality", "fluent-emoji/gem-stone.png",
                   "Borrows a real site's TLS fingerprint.", badges=scores(9, 7)),
                ch("xray-vless", "Connect xray-vless", "fluent-emoji/large-blue-diamond.png",
                   "TLS transport, no extra disguise.", badges=scores(8, 7)),
                ch("xray-trojan", "Connect xray-trojan", "fluent-emoji/horse.png",
                   "Looks like an ordinary HTTPS site.", badges=scores(8, 6)),
                ch("xray-vmess", "Connect xray-vmess", "fluent-emoji/large-orange-diamond.png",
                   "The older Xray protocol.", badges=scores(7, 6)),
                ch("v2ray", "Connect v2ray", "fluent-emoji/sparkles.png",
                   "VMess on the original V2Ray stack.", badges=scores(7, 6)),
                ch("shadowsocks", "Connect shadowsocks", "fluent-emoji/socks.png",
                   "Simple and fast, easier to fingerprint.", badges=scores(6, 7)),
            ]},
            {"caption": "Through Tor", "mode": "choice", "rows": [
                ch("Remote Tor node", "Connect Remote Tor", "fluent-emoji/satellite-antenna.png",
                   "Tor running on the VPS, not on this machine.", badges=scores(8, 2)),
            ]},
            # A choice window applies ONE protocol, so it had no way OUT: the only
            # buttons were Close and Connect. Operator, a14: "how can someone
            # disconnect!". This runs the same row the Routing window uses.
            {"caption": "Stopping", "mode": "action", "rows": [
                act("Disconnect", "Disconnect Routing", "fluent-emoji/broken-chain.png",
                    "Drops the current tunnel and puts normal routing back.",
                    cat=RTG, danger=True),
            ]},
        ],
    },

    "routing": {
        "title": "Routing Control",
        "subtitle": "The connection you already have.",
        "apply_label": "Apply routing changes",
        "sections": [
            {"caption": "Connection", "mode": "action", "rows": [
                act("Disconnect", "Disconnect Routing", "fluent-emoji/broken-chain.png",
                    cat=RTG, danger=True),
                act("Repair routing", "Recover Routing", "repair.png",
                    "Puts the routes back without dropping the tunnel.", cat=RTG),
                act("Reset connection", "Reset Connection",
                    "fluent-emoji/counterclockwise-arrows-button.png", cat=RTG),
                act("Recover internet", "Recover Internet",
                    "papirus/network-wired.svg",
                    "Rebuilds the internet path itself when routing is not the "
                    "problem: DNS, the default route and the firewall.",
                    cat="Recovery"),
            ]},
            {"caption": "Choosing for you", "mode": "action", "rows": [
                act("Auto-select protocol", "Auto-Select Protocol", "fluent-emoji/magic-wand.png",
                    cat=RTG),
                rep("Benchmark all protocols", "Benchmark Protocols", "fluent-emoji/stopwatch.png",
                    cat=RTG),
                rep("Test all endpoints", "Test Protocol", "fluent-emoji/test-tube.png", cat=RTG),
                rep("List protocols", "List Protocols", "papirus/checkbox.svg", cat=RTG),
                rep("VPNGate servers", "VPNGate List Servers", "fluent-emoji/card-index.png",
                    cat=RTG),
            ]},
            {"caption": "Local SOCKS5 server", "mode": "switch", "rows": [
                sw("SOCKS5 server", "Enable SOCKS5 Server", "Disable SOCKS5 Server",
                   "Microsocks Status", "papirus/network-server.svg",
                   "Runs microsocks, a small SOCKS5 proxy server, so other devices "
                   "ON YOUR LAN can reach the internet through this machine's tunnel: "
                   "point their SOCKS5 setting at this machine's LAN IP on port 1080. "
                   "The listener binds 0.0.0.0 and the shipped credentials are "
                   "kodachi/kodachi, so treat it as open to the local network.",
                   cat=RTG),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Connection status", "Connection Status", "papirus/drill-search.svg", cat=RTG),
                rep("VPS info", "VPS Info", "papirus/gnome-remote-desktop.svg", cat=RTG),
            ]},
        ],
    },

    "torrify": {
        "title": "Route Through Tor",
        "subtitle": "Send this machine's traffic through the Tor network.",
        "apply_label": "Route through Tor",
        "sections": [
            {"caption": "Mode", "mode": "choice", "rows": [
                ch("Detorrify", "De-Torrify", "fluent-emoji/broken-chain.png",
                   "Traffic goes out normally.", cat=TOR, badges=[("No Tor", "off")]),
                ch("Torrify with DNS", "Enable Torrify + DNS", "fluent-emoji/cyclone.png",
                   "Everything through Tor, name lookups included. The usual choice.",
                   cat=TOR, badges=[TORDNS]),
                ch("Balanced, round robin", "Balanced Torrify RR",
                   "papirus/preferences-system-network-sharing.svg",
                   "Spreads connections evenly across the instance pool.",
                   cat=TOR, badges=[TORDNS]),
                ch("Balanced, weighted", "Balanced Torrify Weighted",
                   "fluent-emoji/balance-scale.png", "Favours the faster instances.",
                   cat=TOR, badges=[TORDNS]),
                ch("Balanced, consistent", "Balanced Torrify Consistent",
                   "fluent-emoji/chains.png", "Keeps one destination on one instance.",
                   cat=TOR, badges=[TORDNS]),
                # THE DNS ONE FIRST, THE BARE ONE UNDER IT. Operator's ruling,
                # after I first proposed dropping the bare row entirely: "or swap
                # the dns make it top and without dns make it below it". Both stay
                # reachable, and the one that works is the one you reach first.
                # The order is doing real work here, because the binary itself
                # warns about the second: firewall.rs:3193 logs "WARNING: This
                # command does NOT redirect DNS. Without DNS, internet may not
                # work. Use torrify-system-iptables-dns instead."
                ch("iptables with DNS", "Torrify iptables DNS",
                   "papirus/network-server-database.svg",
                   "Firewall level instead of nftables, with name lookups sent "
                   "through Tor.",
                   cat=TOR, badges=[TORDNS]),
                ch("iptables only", "Torrify iptables", "papirus/filter.svg",
                   "The same without DNS redirection. tor-switch itself warns "
                   "that the internet may stop working: use the row above unless "
                   "you know why you want this.",
                   cat=TOR, badges=[NOTORDNS]),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Am I on Tor?", "Verify Tor Connection", "papirus/security-medium.svg",
                    cat=TOR),
                rep("Torrify state", "Torrify State", "papirus/tor.svg", cat=SES),
            ]},
        ],
    },

    "tor-service": {
        "title": "Tor Service",
        "subtitle": "The Tor daemon and its instance pool.",
        "apply_label": "Apply Tor changes",
        "sections": [
            {"caption": "Main daemon", "mode": "switch", "rows": [
                sw("Tor", "Start Main Tor", "Stop Main Tor", "Tor Status", "papirus/tor.svg",
                   cat=TOR),
                # `check` was None so the row was permanently unknown. tor-switch
                # verify-tor-dns answers with `direct_method` and `port_method`
                # and its own success arm is `direct || port`, which read_switch
                # now mirrors. The ON command already runs this verify, so the
                # read costs nothing new.
                sw("Tor DNS", "Enable Tor DNS", "Stop Tor DNS", "Verify Tor DNS",
                   "papirus/preferences-system-network-proxy.svg",
                   "Resolves names through Tor instead of your resolver.", cat=TOR,
                   badges=[("Encrypted in the circuit", "on")]),
            ]},
            {"caption": "Actions", "mode": "action", "rows": [
                act("New circuit", "New Tor Circuit",
                    "fluent-emoji/counterclockwise-arrows-button.png",
                    "New path through the network, and a new exit.", cat=TOR),
                act("Restart Tor", "Restart Tor", "papirus/system-restart.svg", cat=TOR),
            ]},
            {"caption": "Instance pool", "mode": "action", "rows": [
                act("Start all", "Start All Tor Instances", "papirus/session-properties.svg",
                    cat=TOR),
                act("Stop all", "Stop All Tor Instances", "papirus/gnome-shutdown.svg", cat=TOR),
                act("Restart all", "Restart All Tor Instances", "papirus/colorhug-refresh.svg",
                    cat=TOR),
                rep("Pool overview", "Tor Instance Pool", "papirus/org.gnome.Boxes.svg", cat=SES),
                rep("Instances and their IPs", "List Instances With IPs", "papirus/gnome-maps.svg",
                    cat=TOR),
                act("Circuit monitor", "Tor Circuit Monitor", "fluent-emoji/chart-increasing.png",
                    "Opens nyx in a terminal.", cat=PRV, execution="launch",
                    effect="launch"),
            ]},
        ],
    },

    "display": {
        "title": "Display and Power",
        "subtitle": "Screens, the desktop overlay and sleep behaviour.",
        "apply_label": "Apply display changes",
        "sections": [
            {"caption": "Screen layout", "mode": "choice", "rows": [
                ch("Single screen", "Display Single Screen", "papirus/display.svg", cat=DSK),
                ch("Extend", "Display Extend", "papirus/gnome-multi-writer.svg", cat=DSK),
                ch("Mirror", "Display Mirror", "papirus/preferences-desktop-remote-desktop.svg",
                   cat=DSK),
            ]},
            {"caption": "Overlays and sleep", "mode": "switch", "rows": [
                sw("Conky overlay", "Conky Enable", "Conky Disable", "Conky Status",
                   "papirus/gnome-system-monitor.svg",
                   "The live status panel on the desktop.", cat=DSP),
                sw("Screensaver", "Screensaver Enable", "Screensaver Disable",
                   "Screensaver Status",
                   "papirus/preferences-desktop-screensaver.svg", cat=DSP),
                sw("Screen blanking (DPMS)", "DPMS Enable", "DPMS Disable",
                   "DPMS Status",
                   "papirus/gnome-power-manager.svg", cat=DSP),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Display status", "Display Status", "papirus/preferences-desktop-keyboard.svg",
                    cat=DSK),
            ]},
        ],
    },

    "nettune": {
        "title": "Network Tuning",
        "subtitle": "Throughput settings. None of these change what is visible.",
        "apply_label": "Apply tuning changes",
        "sections": [
            {"caption": "Kernel", "mode": "switch", "rows": [
                sw("BBR congestion control", "BBR Enable", "BBR Disable", "BBR Status",
                   "papirus/network-server-database.svg",
                   "Google's algorithm. Usually faster on a long link.", cat=NET),
                # health-control documents --action check for this and the Tauri
                # dashboard already uses it; only the registry row was missing,
                # which is why the switch shipped claiming no status exists.
                sw("Network optimisation", "Net Optimize Enable", "Net Optimize Disable",
                   "Net Optimize Status",
                   "papirus/network-defaultroute.svg",
                   "Buffer and queue tuning for the current link.", cat=NET),
            ]},
        ],
    },

    "killswitch": {
        "title": "Kill Switch",
        "subtitle": "What happens to your traffic if the tunnel drops.",
        "apply_label": "Set kill switch",
        "sections": [
            {"caption": "Level", "mode": "choice", "rows": [
                ch("Off", "Disarm Kill Switch", "papirus/network-firewall.svg",
                   "Traffic keeps flowing unprotected if the tunnel dies.", cat=EMG),
                ch("Soft", "Activate Soft Kill Switch", "fluent-emoji/no-entry.png",
                   "Blocks new connections, leaves existing ones alone.", cat=EMG),
                ch("Medium", "Activate Medium Kill Switch", "papirus/yast-firewall.svg", cat=EMG),
                ch("Armed", "Arm Kill Switch", "papirus/network-firewall.svg",
                   "Everything stops the moment the tunnel does.", cat=EMG),
            ]},
            {"caption": "Check", "mode": "action", "rows": [
                rep("Kill switch status", "Kill Switch Status", "papirus/drill-search.svg",
                    cat=EMG),
                rep("Lockdown status", "Lockdown Status", "shield_yellow.png", cat=EMG),
            ]},
        ],
    },

    "emergency": {
        "title": "Emergency",
        "subtitle": "For when something has gone wrong and you need it to stop.",
        "sections": [
            {"caption": "Panic", "mode": "action", "rows": [
                act("Panic, soft", "Panic Soft", "papirus/security-low.svg",
                    "Drops the network and clears the obvious traces.",
                    cat=EMG, danger=True, confirm=True),
                act("Panic, medium", "Panic Medium", "papirus/security-medium.svg",
                    cat=EMG, danger=True, confirm=True),
                act("Recover", "Panic Recover", "papirus/system-restart.svg",
                    "Undo a panic and put the machine back.", cat=EMG,
                    recovery=True, success_output=True),
            ]},
            # A DESTRUCTIVE ACTION AND ITS REVERSE BELONG IN THE SAME PLACE.
            #
            # This section used to hold "Block internet" ALONE. The undo,
            # `Unblock Internet`, sits in the Recovery category, and these
            # windows are built per category, so cutting your own network here
            # meant hunting for the restore behind the System icon. The operator
            # found it immediately: "some window have block intenrt but does not
            # have unblock !!!". Being one click from the undo matters most at
            # exactly the moment you have just cut yourself off.
            #
            # SEVEN METHODS EXIST AND ONE BARE ROW SHIPPED. The binary takes
            # --method firewall|ufw|iptables|nftables|interfaces|auto|all on both
            # subcommands, plus --allow-local on the block. "Keep this LAN" is
            # listed FIRST because a plain block takes SSH and the local router
            # with it, which is how a fail-closed ipv4 DROP stranded a test VM
            # for seven minutes with no rollback. The safest shape is the one the
            # eye lands on first, and the widest one is marked danger.
            {"caption": "Cut the network", "mode": "action",
             "note": "Every cut here has its undo directly underneath it.",
             "rows": [
                act("Block internet, keep this LAN", "Block Internet, Keep LAN",
                    "papirus/network-wired.svg",
                    "Cuts the internet but leaves the local network reachable, "
                    "so you do not lock yourself out of this machine.",
                    cat=EMG, danger=True, confirm=True),
                # WAS "Block Internet", the bare command, which is --method auto.
                # auto calls detect_best_method() and picks ONE mechanism, so the
                # row promised "nothing in or out" and delivered whichever layer
                # the binary happened to choose. Now --method all, which is what
                # the label always claimed. The bare row still exists in the
                # registry for rofi and the dock cell.
                act("Block internet, everything", "Block Internet, All",
                    "fluent-emoji/no-entry.png",
                    "Every mechanism at once: nothing in or out, including the "
                    "LAN and any SSH session you are using right now.",
                    cat=EMG, danger=True, confirm=True),
                rep("Is it blocked right now?", "Internet Block Status",
                    "fluent-emoji/magnifying-glass-tilted-left.png",
                    "Ask before you cut, and check after you restore.", cat=EMG),
            ]},
            {"caption": "Put the network back", "mode": "action",
             "note": "Start with the first one. The others target a single "
                     "mechanism if you know which one is still holding.",
             "rows": [
                # "Undoes every block method at once" was FALSE for one of them.
                # internet_block.rs:564-568 rewrites All and Auto to Firewall for
                # the unblock action, and :1033 marks the All arm unreachable, so
                # unblock_with_network_interfaces() could not be reached from any
                # row a user could click. The interfaces restore is now its own
                # row directly below, and this note no longer over-promises.
                act("Restore internet", "Unblock Internet",
                    "papirus/network-defaultroute.svg",
                    "Clears the firewall, iptables and nftables blocks. Start "
                    "here. It does NOT bring downed interfaces back, that is "
                    "the row below.", cat=EMG, recovery=True,
                    success_output=True),
                act("Restore, firewall only", "Unblock Internet, Firewall",
                    "papirus/gufw.svg", cat=EMG, recovery=True,
                    success_output=True),
                act("Restore, iptables only", "Unblock Internet, iptables",
                    "papirus/network-firewall.svg", cat=EMG, recovery=True,
                    success_output=True),
                act("Restore, nftables only", "Unblock Internet, nftables",
                    "papirus/preferences-system-firewall.svg", cat=EMG,
                    recovery=True, success_output=True),
                act("Bring interfaces back up", "Unblock Internet, Interfaces",
                    "papirus/network-card.svg",
                    "The undo for \"Take interfaces down\". Nothing else "
                    "restores a downed link.", cat=EMG, recovery=True,
                    success_output=True),
            ]},
            {"caption": "Cut one mechanism only", "mode": "action",
             "note": "For when you know exactly which layer you want down. "
                     "Each has its matching restore above.",
             "rows": [
                act("Block via firewall", "Block Internet, Firewall",
                    "papirus/gufw.svg", cat=EMG, danger=True, confirm=True),
                act("Block via iptables", "Block Internet, iptables",
                    "papirus/network-firewall.svg", cat=EMG, danger=True, confirm=True),
                act("Block via nftables", "Block Internet, nftables",
                    "papirus/preferences-system-firewall.svg",
                    cat=EMG, danger=True, confirm=True),
                act("Take interfaces down", "Block Internet, Interfaces",
                    "papirus/network-card.svg",
                    "Downs the network interfaces themselves. There is no "
                    "firewall rule to undo, the links simply go away.",
                    cat=EMG, danger=True, confirm=True),
            ]},
            {"caption": "Destroy the disk key", "mode": "action", "rows": [
                act("Arm LUKS nuke", "LUKS Nuke Arm", "kodachi/nuke-armed.svg",
                    "Once armed, the nuke passphrase destroys the key slots and the disk "
                    "becomes unrecoverable. There is no undo after it fires.",
                    cat=EMG, danger=True, confirm=True),
                act("Disarm LUKS nuke", "LUKS Nuke Disarm", "kodachi/nuke-disarmed.svg", cat=EMG),
            ]},
            {"caption": "End the session", "mode": "action", "rows": [
                act("Lock screen", "Lock Screen", "papirus/system-lock-screen.svg", cat=EMG),
                act("Log out", "Logout", "papirus/system-log-out.svg", cat=EMG, confirm=True),
                act("Suspend", "Suspend", "papirus/system-suspend.svg", cat=EMG),
                act("Reboot", "Reboot", "papirus/gshutdown.svg", cat=EMG, confirm=True),
                act("Shut down", "Shutdown", "papirus/system-shutdown.svg",
                    cat=EMG, danger=True, confirm=True),
            ]},
        ],
    },
}


# ── windows originally generated from dock-actions.tsv ────────────────────
#
# THE GENERATOR FOR THIS BLOCK NO LONGER EXISTS and I am saying so rather than
# leaving a pointer to a path nobody can follow. It ran once, out of an agent
# scratchpad, and was not committed. These sections have been hand-edited many
# times since, so regenerating them would now LOSE work rather than refresh it.
# Treat this block as hand-maintained. The Recipes block below is different: its
# generator IS committed and IS still the source.
# Every (Category, Label) pair below was READ from the side-car, never
# retyped, and every section caption is the _SEP_ row that already grouped
# those cells on the dock. Regenerate rather than hand-editing.

WINDOWS["sandbox"] = {
    "title": "Applications",
    # MEASURED, NOT GUESSED. Eight rows of name + note + a three-arm chip strip
    # + a pill + a Launch button need 852px minimum and 876px natural on a real
    # display. The shell resolves a standalone window to
    # min(1080, max(width + SIDEBAR_WIDTH, 940)), so the 640 default produced
    # 940 and this window opened 96px narrower than its own content, clipping
    # the Launch column and refusing to be dragged down to the size it opened
    # at. 880 + 184 = 1064 covers the natural width and stays inside the 1080
    # family bound. Pinned by tests/test_isolation_window.py GeometryContracts,
    # which measures get_default_size() against get_preferred_width(); reading
    # get_size() after show_all() cannot see this, because GTK has already
    # grown the allocation to the minimum and the arm compares it to itself.
    "width": 880,
    "subtitle": "FIREJAIL: graphical applications and terminals. PODMAN: "
                "terminal shells only, because Kodachi containers have no "
                "display socket. NATIVE: no sandbox. Whole Podman workspaces "
                "live on the Containers tab.",
    "sections": [
        {"caption": "Browsers", "mode": "isolated", "rows": [
            isolated("LibreWolf", "librewolf", "/usr/local/bin/librewolf",
                     "custom/firejail-browser-shield.png",
                     "Uses the dedicated LibreWolf Firejail profile.",
                     profile="dedicated"),
        ]},
        {"caption": "Passwords", "mode": "isolated", "rows": [
            isolated("KeePassXC", "keepassxc", "/usr/bin/keepassxc",
                     "papirus/keepassxc.svg",
                     "Uses the dedicated KeePassXC Firejail profile.",
                     profile="dedicated"),
        ]},
        {"caption": "Wallets", "mode": "isolated", "rows": [
            isolated("Electrum", "electrum", "/usr/bin/electrum",
                     "fluent-emoji/large-orange-diamond.png",
                     "Uses the dedicated Electrum Firejail profile.",
                     profile="dedicated"),
            isolated("Monero Wallet GUI", "monero-wallet",
                     "/usr/local/bin/monero-wallet-gui",
                     "fluent-emoji/gem-stone.png",
                     "Uses Firejail's default profile because no dedicated "
                     "Monero Wallet GUI profile is installed."),
        ]},
        {"caption": "Files", "mode": "isolated", "rows": [
            isolated("Thunar", "thunar", "/usr/bin/thunar",
                     "custom/thunar-file-folder.png",
                     "Uses the dedicated Thunar Firejail profile.",
                     profile="dedicated"),
            isolated("Double Commander", "double-commander", "/usr/bin/doublecmd",
                     "apps/doublecmd.svg",
                     "Uses Firejail's default profile because no dedicated "
                     "Double Commander profile is installed."),
        ]},
        # THE ONLY TWO ROWS THAT MAY OFFER PODMAN, and the reason is the shipped
        # container's missing display socket, not anything about terminals being
        # special. A shell needs a pty; every row above needs a window.
        #
        # NEITHER NOTE MENTIONS PODMAN ANY MORE, on purpose. Both used to end
        # with "Podman opens the offline disposable container shell instead.",
        # which is a claim about the MACHINE, and this module cannot know
        # whether Podman is installed on it. On a box without it the row read
        # that promise beside a chip saying "PODMAN , not installed". The
        # driver composes that sentence now, from podman_row_sentence(), which
        # can ask. `podman=True` still says what the ROW offers, which is the
        # part that genuinely belongs here.
        {"caption": "Terminals", "mode": "isolated", "rows": [
            isolated("XFCE Terminal", "xfce-terminal", "/usr/bin/xfce4-terminal",
                     "custom/terminals-computer.png",
                     "Uses Firejail's default profile because no dedicated "
                     "XFCE Terminal profile is installed.",
                     podman=True),
            isolated("XTerm", "xterm", "/usr/bin/xterm", "apps/xterm.svg",
                     "Uses Firejail's default profile because no dedicated "
                     "XTerm profile is installed.",
                     podman=True),
        ]},
    ],
}

# ── the six container verbs, moved off the dock and into one destination ───
#
# These were six separate Cairo cells in a `Containers` sub-dock. Every one of
# them spawned `xfce4-terminal --hold --command="<manager> <verb>"`, so the
# terminal was doing the work of a result pane. The three read-only verbs now
# report INTO the window, and only the three that need an interactive pty still
# open a terminal.
WINDOWS["containers"] = {
    "title": "Containers",
    # "its nto clear are we cxontrolling podaman here or firejail !!!", the
    # operator, 2026-08-25, on this exact page. Every verb here is Podman and
    # not one of them said so: the rows read Disposable Shell, Status, Start
    # All, Stop All, which name a lifecycle without naming whose lifecycle it
    # is. The subtitle said Podman once, above the fold, in small type. The
    # section captions now carry it, because a caption is on screen next to the
    # button being pressed.
    "subtitle": "PODMAN ONLY. Every button on this page drives rootless "
                "Podman containers owned by Kodachi. Firejail is not "
                "controlled here. Firejail runs graphical applications and "
                "terminals from the Applications tab.",
    "sections": [
        {"caption": "Open a Podman workspace", "mode": "launch",
         "note": "PODMAN ONLY. Opens a shell INSIDE a container. Firejail "
                 "runs graphical applications and terminals from the "
                 "Applications tab; nothing here touches Firejail.",
         "rows": [
            launch("Disposable Shell", (CONTAINER_MANAGER, "disposable-shell"),
                   "custom/podman-disposable-ghost-shell.png",
                   "A throwaway offline shell. It is removed the moment you "
                   "leave it.",
                   terminal="Podman Disposable Shell"),
            launch("Persistent Workbench", (CONTAINER_MANAGER, "persistent-workbench"),
                   "fluent-emoji/toolbox.png",
                   "The named Kodachi workbench. It survives stop and start.",
                   terminal="Podman Persistent Workbench"),
        ]},
        {"caption": "Podman container lifecycle", "mode": "launch",
         "note": "Neither button touches a container you created yourself: "
                 "both act only on containers labelled io.kodachi.managed=true. "
                 "Start All takes all of them. Stop All takes all of them "
                 "EXCEPT disposable shells, because a disposable is removed the "
                 "moment it ends, so stopping one would discard what is in it. "
                 "Type exit in that window to close it.",
         "rows": [
            launch("Status", (CONTAINER_MANAGER, "status"),
                   "fluent-emoji/stethoscope.png",
                   "The bundled image and every container Kodachi owns."),
            launch("Start All", (CONTAINER_MANAGER, "start-all"),
                   "fluent-emoji/play-button.png",
                   "Starts only containers labelled io.kodachi.managed=true."),
            launch("Stop All", (CONTAINER_MANAGER, "stop-all"),
                   "fluent-emoji/stop-button.png",
                   "Stops containers labelled io.kodachi.managed=true, except "
                   "disposable shells."),
        ]},
        {"caption": "Destructive, Podman only", "mode": "launch", "rows": [
            launch("Reset Workbench", (CONTAINER_MANAGER, "reset-workbench"),
                   "fluent-emoji/recycling-symbol.png",
                   "Removes the persistent workbench and everything in it. "
                   "The manager asks you to confirm in the terminal.",
                   terminal="Reset Podman Workbench", danger=True),
        ]},
    ],
}

WINDOWS["status"] = {
    "title": "Status",
    "subtitle": "What is true about this machine right now.",
    "sections": [
        {"caption": "Overview", "mode": "action", "rows": [
            rep("Full Session Report", "Everything About This Session", "papirus/utilities-system-monitor.svg", cat="Session Status"),
            rep("Full Report, Fresh", "Everything, Fresh Data", "papirus/hardinfo.svg", cat="Session Status"),
        ]},
        {"caption": "Who Am I", "mode": "action", "rows": [
            rep("My Session ID", "My Session ID", "papirus/seahorse.svg", cat="Session Status"),
            rep("Sign-In Status", "Sign-In Status", "papirus/system-users.svg", cat="Session Status"),
            rep("My Hostname", "My Hostname", "papirus/computer.svg", cat="Session Status"),
            rep("My MAC Address", "My MAC Address", "papirus/network-card.svg", cat="Session Status"),
            rep("My Timezone", "My Timezone", "papirus/accessories-clock.svg", cat="Session Status"),
            rep("Timezone Of My IP", "Timezone Of My IP", "papirus/gis-weather.svg", cat="Session Status"),
        ]},
        {"caption": "Where Am I", "mode": "action", "rows": [
            rep("My Public IP", "My Public IP", "papirus/network-workgroup.svg", cat="Session Status"),
            rep("My Local IP", "My Local IP", "papirus/network-wired.svg", cat="Session Status"),
            rep("Internet State", "Internet State", "papirus/gnome-nettool.svg", cat="Session Status"),
            rep("Tor Exit", "Tor Exit", "papirus/tor.svg", cat="Session Status"),
            rep("Tor Instance Pool", "Tor Instance Pool", "papirus/tor.svg", cat="Session Status"),
        ]},
        {"caption": "What Protects Me", "mode": "action", "rows": [
            rep("Torrify State", "Torrify State", "papirus/tor.svg", cat="Session Status"),
            rep("VPN State", "VPN State", "papirus/network-vpn.svg", cat="Session Status"),
            rep("DNS Mode", "DNS Mode", "papirus/network-server.svg", cat="Session Status"),
            rep("DNS Servers In Use", "DNS Servers In Use", "papirus/gnome-todo.svg", cat="Session Status"),
            rep("DNSCrypt State", "DNSCrypt State", "dnscryptt.png", cat="Session Status"),
            rep("Pi-hole State", "Pi-hole State", "papirus/preferences-system-firewall.svg", cat="Session Status"),
            rep("Firewall State", "Firewall State", "papirus/yast-security.svg", cat="Session Status"),
            rep("IPv6 State", "IPv6 State", "papirus/network-wireless.svg", cat="Session Status"),
            rep("Security Score", "Security Score", "papirus/Stacer.svg", cat="Session Status"),
            rep("Version Info", "Version Info", "papirus/system-software-update.svg", cat="Session Status"),
        ]},
        # ── FIRMWARE AND PLATFORM ────────────────────────────────────────────
        #
        # THE ROW BELOW IS THE SAME READING THE DASHBOARD'S VITALS PANEL SHOWS, because both run
        # `health-control firmware-security-check`. That is deliberate: a firmware panel written
        # twice is a firmware panel that will eventually disagree with itself about one machine,
        # which is the two-numbers defect the operator has already had to report on the score.
        #
        # It sits after "What Protects Me" and before the IP lookups because firmware is part of
        # what protects the machine, not part of checking where it appears to be.
        #
        # `Boot Integrity` is NOT a new registry key. It already exists at [System Info][Boot
        # Integrity] and is already surfaced by the System window; it is referenced here because
        # the boot chain is half of this subject and a second key would be a second answer.
        # THE PANEL IS THE ANSWER, NOT A BUTTON THAT PRODUCES ONE.
        #
        # This section reads one command ONCE and paints every row from that single reply, so the
        # user sees the machine's firmware posture on open rather than after a click. `source` is
        # the registry pair the driver runs; the rows bind to fields in its JSON by `key`.
        #
        # WHY FOURTEEN AND NOT ALL OF THEM, since the strip's own total says 21 or 24 and the
        # dashboard's Vitals panel lists every one. This is a CURATED panel on purpose: these are
        # the checks a reader can act on or should recognise, in a fixed order that does not
        # change between machines. The strip carries the full denominator precisely so the
        # curation is visible rather than hidden, and Vitals is the place to read all of them.
        #
        # The keys are fwupd's own attribute names, lower-cased. They are NOT invented: each one is
        # the `Name` field of a Host Security Interface attribute as `fwupdtool security --json`
        # emits it, so a row can never describe a check fwupd does not perform. A key with no
        # matching attribute on this machine renders "not offered" rather than a verdict, because
        # the HSI attribute set genuinely differs between machines: a legacy-BIOS box reports 21
        # attributes where a UEFI box reports 24, and calling an absent check a failure would be a
        # lie about hardware that simply has nothing to say.
        {"caption": "Firmware & Platform", "mode": "facts",
         "source": ("System Info", "Firmware Security"),
         "note": "Read once when this window opens. Nothing here changes the machine.",
         "rows": [
            fct("SPI flash write protection", "spi write", "papirus/org.gnome.Firmware.svg",
                "The BIOS chip refuses writes from the running system"),
            fct("SPI configuration lock", "spi lock", "papirus/org.gnome.Firmware.svg",
                "Firmware settings frozen after boot"),
            fct("SPI BIOS region", "spi bios region", "papirus/org.gnome.Firmware.svg",
                "Descriptor protection on the BIOS region"),
            fct("UEFI Secure Boot", "uefi secure boot", "papirus/yast-security.svg",
                "Only signed boot binaries may run"),
            fct("UEFI platform key", "uefi platform key", "papirus/seahorse.svg",
                "Platform key present and well formed"),
            fct("UEFI boot service variables", "uefi bootservice variables", "papirus/seahorse.svg",
                "Hidden from the system after boot services end"),
            fct("Intel BootGuard", "intel bootguard", "papirus/computer.svg",
                "Hardware root of trust for the boot block"),
            fct("TPM 2.0", "tpm v2.0", "papirus/seahorse.svg",
                "Measured boot and sealed secrets"),
            fct("IOMMU / DMA protection", "iommu", "papirus/network-card.svg",
                "Blocks a malicious device reading memory"),
            fct("Pre-boot DMA protection", "pre-boot dma protection", "papirus/network-card.svg",
                "DMA is fenced before the system takes over"),
            fct("Kernel lockdown", "linux kernel lockdown", "papirus/yast-security.svg",
                "Root cannot reach firmware through the kernel"),
            fct("Encrypted swap", "linux swap", "papirus/drive-harddisk.svg",
                "Swap cannot leak memory contents to disk"),
            fct("Kernel taint", "linux kernel", "papirus/utilities-system-monitor.svg",
                "Out-of-tree code loaded into the kernel"),
            fct("SMAP", "smap", "papirus/computer.svg",
                "The kernel cannot be tricked into reading user memory"),
        ]},
        {"caption": "Firmware Reports", "mode": "action", "rows": [
            rep("Firmware Security", "Firmware Security", "papirus/org.gnome.Firmware.svg", cat="System Info"),
            rep("Boot Integrity", "Boot Integrity", "papirus/org.gnome.Firmware.svg", cat="System Info"),
        ]},
        {"caption": "Check My Ip Another Way", "mode": "action", "rows": [
            rep("My IP Via Tor", "IP via Tor Proxy", "fluent-emoji/satellite-antenna.png", cat="IP Lookup"),
            rep("Am I Torrified", "Check If Using Tor", "papirus/wireshark.svg", cat="IP Lookup"),
            rep("IP, Many Sources", "Multi-Source Verify", "papirus/drill-search.svg", cat="IP Lookup"),
            rep("Where Do I Look Like", "Geolocation Test", "papirus/marble.svg", cat="IP Lookup"),
        ]},
        {"caption": "Kodachi Cloud", "mode": "action", "rows": [
            rep("Kodachi Cloud Status", "Online Status", "papirus/network-server-database.svg", cat="Online Info"),
            rep("Proof Of Freshness", "Proof of Freshness", "papirus/colorhug-refresh.svg", cat="Online Info"),
            rep("Latest Releases", "Kodachi Releases", "papirus/gnome-software.svg", cat="Online Info"),
        ]},
    ],
}

WINDOWS["verify"] = {
    "title": "Verify",
    "subtitle": "Prove the system is what it claims to be.",
    "sections": [
        {"caption": "Overview", "mode": "action", "rows": [
            checked(rep("Verify System", "Check All", "papirus/security-high.svg", cat="Security & Integrity")),
            checked(rep("Security Score", "Security Score", "papirus/Stacer.svg", cat="Security & Integrity")),
            checked(rep("Security Status", "Security Status", "papirus/drill-search.svg", cat="Security & Integrity")),
        ]},
        {"caption": "Files And Binaries", "mode": "action", "rows": [
            checked(rep("File Integrity", "Check Integrity", "papirus/gtkhash.svg", cat="Security & Integrity")),
            checked(rep("Binary Signatures", "Check Signatures", "papirus/kgpg.svg", cat="Security & Integrity")),
            checked(rep("AIDE Check", "AIDE Check", "papirus/quickhash.svg", cat="Security & Integrity"), required_all=("aide",)),
            checked(rep("Versions", "Check Versions", "papirus/gnome-software.svg", cat="Security & Integrity")),
            checked(rep("Config Check", "Check Config", "papirus/gnome-tweak-tool.svg", cat="Security & Integrity")),
        ]},
        {"caption": "Malware", "mode": "action", "rows": [
            checked(rep("Rootkit Scan", "Rootkit Scan", "papirus/chkrootkit.svg", cat="Security & Integrity")),
            checked(rep("Deep Rootkit Scan", "Enhanced Rootkit Scan", "fluent-emoji/microscope.png", cat="Security & Integrity"), required_any=(("rkhunter", "chkrootkit"),)),
            checked(rep("Virus Scan", "ClamAV Scan", "papirus/clamav.svg", cat="Security & Integrity"), required_any=(("clamscan", "clamdscan"),)),
        ]},
        {"caption": "Audit", "mode": "action", "rows": [
            checked(rep("Full Audit", "Lynis Audit", "fluent-emoji/scroll.png", cat="Security & Integrity"), required_all=("lynis",)),
            checked(rep("Audit Status", "Lynis Status", "papirus/searchmonkey.svg", cat="Security & Integrity")),
            checked(rep("Check Hardware RNG", "Hardware RNG Verify", "papirus/preferences-other.svg", cat="Storage & USB")),
        ]},
        {"caption": "Reports", "mode": "action", "rows": [
            checked(rep("Security History", "Security History", "fluent-emoji/spiral-calendar.png", cat="Security & Integrity"), required_all=("journalctl",)),
            checked(rep("Security Report", "Security Report", "papirus/document-viewer.svg", cat="Security & Integrity")),
            checked(rep("Scan Security Findings", "Security Remediate", "papirus/freefilesync.svg",
                        "Scans for common findings. It does not apply changes.",
                        cat="Security & Integrity"), required_all=("ufw", "apt")),
        ]},
        {"caption": "Network", "mode": "action", "rows": [
            checked(rep("Am I On Tor?", "Verify Tor Connection", "papirus/security-medium.svg", cat="Tor")),
            checked(rep("Instances And IPs", "List Instances With IPs", "papirus/utilities-log-viewer.svg", cat="Tor")),
        ]},
        # ONE section, not one per row. Each of these arrived as its own
        # `{"caption": "Added, read only"}` block, so the window drew the SAME
        # heading twice in a row with a single row under each. Measured on
        # testvm-kodachi-91fb5c: 2 identical captions here and 7 in `system`.
        # A caption repeated verbatim reads to the user as a rendering fault.
        {"caption": "Security operations, read only", "mode": "action", "rows": [
            checked(rep("SOC Snapshot", "SOC Snapshot", "papirus/gnome-system-monitor.svg", "Full host telemetry snapshot.", cat="Security & Integrity")),
            checked(rep("SOC Exposure Summary", "SOC Exposure Summary", "fluent-emoji/magnifying-glass-tilted-right.png", "What this host exposes, summarised.", cat="Security & Integrity")),
        ]},
    ],
}

# The first WINDOWS["account"] definition used to sit here and was fully
# overwritten by the one below, so it never rendered. It was also the OLD
# shape the operator rejected: rep("Sign In") and rep("Sign Out") as two
# Show buttons rather than one switch that reads the live state. Removed
# rather than left as 20 lines of code that cannot run.

WINDOWS["system"] = {
    "title": "System",
    "subtitle": "The desktop, storage, cleanup and recovery.",
    "apply_label": "Apply system changes",
    "sections": [
        {"caption": "Overview", "mode": "action", "rows": [
            # act(), NOT rep(). This module defines rep() as "a button that runs a
            # read-only action and shows its output", and these two open a root
            # file manager (`sudo -n thunar /`) and a root shell
            # (`sudo -n x-terminal-emulator`). Nothing about that is read-only.
            # The misclassification also gave them the wrong button label and, once
            # the driver started honouring the registry's confirm column, would have
            # let two root sessions open with no prompt. Same family as the act()
            # row that sat under a "Nothing here changes a setting" caption.
            act("Files As Root", "File Manager as Root", "papirus/user-admin.svg",
                "Opens a file manager as root. Nothing in it is protected from you.",
                cat="Desktop", danger=True, confirm=True, execution="launch",
                handoff=True, effect="launch"),
            act("Root Terminal", "Root Terminal", "papirus/utilities-terminal.svg",
                "Opens a shell as root.", cat="Desktop", danger=True, confirm=True,
                execution="launch", handoff=True, effect="launch"),
            rep("Generate Password", "Generate Password", "papirus/passwords.svg", cat="Maintenance"),
        ]},
        {"caption": "Screen layout", "mode": "choice", "rows": [
            ch("Single screen", "Display Single Screen", "papirus/display.svg", cat=DSK),
            ch("Extend", "Display Extend", "papirus/gnome-multi-writer.svg", cat=DSK),
            ch("Mirror", "Display Mirror", "papirus/preferences-desktop-remote-desktop.svg",
               cat=DSK),
        ]},
        {"caption": "Screens, continued", "mode": "action", "rows": [
            # Screen LAYOUT is one choice with three answers, and the display
            # window already modelled it that way. The generator, which maps one
            # TSV cell to one report row, flattened all three into "Show"
            # buttons: the operator asked "is it [expletive] show or run!" because a
            # button that CHANGES YOUR SCREEN LAYOUT was labelled like a report.
            # Restored as a radio group; see the Screen layout section below.
            rep("Screen Layout", "Display Status", "papirus/preferences-desktop-keyboard.svg", cat="Desktop"),
        ]},
        {"caption": "Storage", "mode": "action", "rows": [
            rep("Storage Devices", "List Storage Devices", "papirus/drive-harddisk.svg", cat="Storage & USB"),
            act("Encrypt A Drive", "Storage Encrypt", "papirus/encryptpad.svg", cat="Storage & USB", danger=True, confirm=True),
            rep("Encryption Status", "Disk Encryption Status", "papirus/drill-search.svg", cat="Storage & USB"),
        ]},
        {"caption": "Clean Up", "mode": "action", "rows": [
            act("Clear System Logs", "Wipe Logs", "papirus/trashindicator.svg", cat="Data Wiping", danger=True, confirm=True),
            act("Clear Browser Data", "Wipe Browser Data", "papirus/sweeper.svg", cat="Data Wiping", danger=True, confirm=True),
            act("Clear Caches", "Clear Cache", "papirus/gcleaner.svg", cat="Data Wiping", danger=True, confirm=True),
            act("Kill Top Memory Hog", "Memory Force Clean", "papirus/gnome-dev-memory.svg", cat="Data Wiping", danger=True, confirm=True),
            act("Clean Up Packages", "Package Cleanup", "papirus/synaptic.svg", cat="Maintenance", danger=True, confirm=True),
        ]},
        {"caption": "Repair", "mode": "action", "rows": [
            act("Fix The Clock", "Sync System Time", "papirus/gnome-clocks.svg", cat="Recovery", confirm=True),
            act("Repair Internet", "Fast Recover Internet", "papirus/freefilesync.svg", cat="Recovery", confirm=True),
            act("Unblock Internet", "Unblock Internet", "papirus/network-wired.svg", cat="Recovery", confirm=True),
            act("Restart DNSCrypt", "DNSCrypt Restart", "papirus/grsync.svg", cat="DNS", confirm=True),
            rep("Network Interfaces", "Show Network Interfaces", "papirus/cs-network.svg", cat="Identity"),
        ]},
        {"caption": "Config Files", "mode": "action", "rows": [
            act("Proxychains Config", "Edit Proxychains Config", "papirus/nsm-proxy.svg",
                "Opens the Proxychains configuration editor.", cat="Privacy Tools",
                execution="launch", handoff=True, effect="launch"),
            rep("Intrusion Guard Rules", "Intrusion Guard Rules",
                "papirus/accessories-text-editor.svg", cat="System Services",
                execution="launch", handoff=True, effect="launch"),
        ]},
        {"caption": "About", "mode": "action", "rows": [
            rep("Licence", "Kodachi License", "papirus/preferences-certificates.svg",
                cat="Desktop", execution="launch", handoff=True, effect="launch"),
            rep("Support Kodachi", "Support Kodachi", "papirus/love.svg",
                cat="Desktop", execution="launch", handoff=True, effect="launch"),
        ]},
        {"caption": "Desktop Widgets", "mode": "switch", "rows": [
            sw("Conky desktop panels", "Conky Enable", "Conky Disable", "Conky Status",
               "state/conky-on.png", "The live status panels on the desktop.",
               cat="Display & Power", confirm=True),
            sw("Hide sensitive Conky fields", "Conky Mask Enable", "Conky Mask Disable",
               "Conky Mask Status", "papirus/security-high.svg",
               "On replaces identity and network details with *** for safe screenshots. "
               "Off exposes those fields in the desktop panels.",
               cat="Display & Power"),
        ]},
        {"caption": "Screen Power", "mode": "switch", "rows": [
            sw("Screensaver", "Screensaver Enable", "Screensaver Disable",
               "Screensaver Status", "state/preferences-desktop-screensaver-on.png",
               cat="Display & Power", confirm=True),
            sw("Display sleep", "DPMS Enable", "DPMS Disable", "DPMS Status",
               "state/gnome-power-manager-on.png",
               "Lets the monitor sleep when it is idle.", cat="Display & Power",
               confirm=True),
        ]},
        {"caption": "What Is This Machine", "mode": "action", "rows": [
            rep("Full System Report", "All System Info", "papirus/hardinfo.svg", cat="System Info"),
            rep("Hardware", "Hardware Info", "papirus/cpu-x.svg", cat="System Info"),
            rep("Storage", "Storage Info", "papirus/gnome-disks.svg", cat="System Info"),
            rep("Running Processes", "Process Info", "papirus/htop.svg", cat="System Info"),
            rep("Randomness Pool", "Entropy Status", "papirus/seahorse.svg", cat="System Info"),
            rep("Boot Integrity", "Boot Integrity", "papirus/org.gnome.Firmware.svg", cat="System Info"),
        ]},
        {"caption": "Network Tuning", "mode": "switch", "rows": [
            sw("Network optimisation", "Net Optimize Enable", "Net Optimize Disable",
               "Net Optimize Status", "state/network-defaultroute-on.png",
               "Buffer and queue tuning for the current link.", cat="Network Tuning",
               confirm=True),
            sw("BBR congestion control", "BBR Enable", "BBR Disable", "BBR Status",
               "state/network-server-database-on.png",
               "Usually improves throughput on long links.", cat="Network Tuning",
               confirm=True),
        ]},
        # SEVEN sections captioned "Added, read only", one row in each, is what
        # this was: the window drew the identical heading seven times running.
        # Grouped by what they actually are, and by their registry category,
        # which is also what the rows already agreed on.
        {"caption": "Maintenance checks, read only", "mode": "action", "rows": [
            rep("Check All Dependencies", "Check All Dependencies", "papirus/system-software-update.svg", "Reports missing dependencies. A non-zero exit here IS the finding.", cat="Maintenance"),
            rep("List Binary Dependencies", "List Binary Dependencies", "fluent-emoji/ledger.png", None, cat="Maintenance"),
            rep("Permission Status", "Permission Status", "papirus/preferences-system-privacy.svg", None, cat="Maintenance"),
            rep("Permission Scan", "Permission Scan", "papirus/drill-search.svg", "Read-only scan. Never runs with --fix from here.", cat="Maintenance"),
            rep("Launcher Verify", "Launcher Verify", "papirus/kfoldersync.svg", "Checks every deployed symlink still resolves.", cat="Maintenance"),
        ]},
        {"caption": "Workflow templates, read only", "mode": "action", "rows": [
            rep("WF: List Templates", "WF: List Templates", "papirus/checkbox.svg", None, cat="Workflows"),
            rep("WF: Show State", "WF: Show State", "papirus/gnome-system-monitor.svg", "Takes about 20 seconds.", cat="Workflows"),
        ]},
    ],
}



# ── Account, hand written rather than generated ─────────────────────────────
#
# The generator maps one TSV cell to one row, which is right for a launcher list
# and WRONG for a control surface: it turned all eight Account cells into
# `rep()` rows, so every control in the window literally read "Show". The
# operator's words: "why the account gtk is bad in all controls it says show !!
# it should be a toggle button sign in or for sign out".
#
# He is right, and the reason is worth keeping: A LAUNCHER IS A VERB, A CONTROL
# IS A STATE. Authenticate and Logout are not two errands, they are two ends of
# one fact about the session, and the same is true of Activate and Release for
# the licence. Both become switches whose position is READ before the window
# draws. Only the two rows that genuinely have no state stay as reports.
WINDOWS["account"] = {
    "title": "Account",
    "subtitle": "Signed in, licensed, and what this device reports as itself.",
    "apply_label": "Apply account changes",
    "sections": [
        {"caption": "Session", "mode": "switch", "rows": [
            sw("Signed in", "Authenticate", "Sign Out", "Check Login",
               "papirus/keyring-manager.svg",
               "Sign in to Kodachi, or sign out of this device.", cat="Authentication"),
        ]},
        {"caption": "Licence", "mode": "switch", "rows": [
            sw("Licence active", "Activate License", "Release License", "License Status",
               "papirus/preferences-certificates.svg",
               "Releasing frees the seat so another device can take it.",
               cat="Authentication"),
        ]},
        {"caption": "This device", "mode": "action", "rows": [
            rep("Device and session IDs", "Show IDs", "papirus/user-info.svg",
                cat="Authentication"),
            rep("Everything about the account", "All Status", "fluent-emoji/ledger.png",
                cat="Authentication"),
        ]},
    ],
}


# Proposal B: one compact Quick surface for the actions a user needs before a
# full control window. Every command remains a registry key, so confirmation,
# authentication, timeout and output handling stay identical to the longer
# surfaces. Each final row opens the matching full window rather than copying
# its extra controls here.
WINDOWS["quick"] = {
    "title": "Quick Commands",
    "subtitle": "Fast privacy, connection, identity and session controls.",
    "sections": [
        {"caption": "Account", "mode": "action", "rows": [
            act("Sign in", "Authenticate", "papirus/keyring-manager.svg",
                cat="Authentication"),
            act("Sign out", "Sign Out", "fluent-emoji/unlocked.png",
                cat="Authentication"),
            surface("More account controls", "account", "papirus/system-users.svg"),
        ]},
        {"caption": "Connection", "mode": "action", "rows": [
            act("Connect WireGuard", "Connect WireGuard", "papirus/network-vpn.svg",
                cat=RTG),
            act("Connect hysteria2", "Connect hysteria2", "fluent-emoji/rocket.png",
                cat=RTG),
            act("Disconnect", "Disconnect Routing", "fluent-emoji/broken-chain.png",
                cat=RTG, confirm=True),
            surface("More connection controls", "network", "fluent-emoji/vpn-shield.png",
                    tab="connect"),
        ]},
        {"caption": "Tor routing", "mode": "action", "rows": [
            act("Torrify with DNS", "Enable Torrify + DNS", "fluent-emoji/cyclone.png",
                cat=TOR, confirm=True),
            act("De-Torrify", "De-Torrify", "papirus/tor.svg",
                cat=TOR, confirm=True),
            surface("More Tor controls", "network", "papirus/tor.svg", tab="tor"),
        ]},
        {"caption": "Identity", "mode": "action", "rows": [
            act("Random hostname", "Randomize Hostname", "papirus/computersettings.svg",
                cat=IDN, confirm=True, success_output=True,
                failure_summary="Hostname randomization failed."),
            act("Random timezone", "Randomize Timezone",
                "fluent-emoji/shuffle-tracks-button.png", cat=IDN,
                success_output=True,
                failure_summary="Timezone randomization failed."),
            act("Random MAC", "Randomize MAC", "papirus/network-card.svg",
                cat=IDN, confirm=True, success_output=True,
                failure_summary="MAC address randomization failed."),
            surface("More identity controls", "identity", "papirus/deflemask.svg"),
        ]},
        {"caption": "DNS", "mode": "action", "rows": [
            act("Enable DNSCrypt", "Enable DNSCrypt", "fluent-emoji/locked-with-key.png",
                cat=DNS),
            act("Tor DNS with nftables", "Enable Tor DNS",
                "papirus/preferences-system-network-proxy.svg", cat=TOR),
            act("Random DNS", "Random DNS", "fluent-emoji/game-die.png", cat=DNS),
            act("Fallback DNS", "Fallback DNS", "papirus/network-modem.svg", cat=DNS),
            surface("More DNS controls", "network", "pdns.png", tab="dns"),
        ]},
        # G18, operator a10: Quick Commands had nothing to REPAIR with, so a
        # user whose internet had just died had to go hunting through the
        # Network and Recovery surfaces. The three families he named, in the
        # order you would actually try them: internet, then routing, then DNS.
        {"caption": "Repair", "mode": "action", "rows": [
            act("Fast repair internet", "Fast Recover Internet",
                "papirus/network-wired.svg",
                "The quick pass: the checks that fix most outages.", cat="Recovery"),
            act("Full repair internet", "Recover Internet",
                "papirus/preferences-system-network.svg",
                "The thorough pass: DNS, the default route and the firewall.",
                cat="Recovery"),
            act("Unblock internet", "Unblock Internet", "fluent-emoji/unlocked.png",
                "Undoes a panic block or a kill switch that is still holding.",
                cat="Recovery", confirm=True),
            act("Repair routing", "Recover Routing", "repair.png",
                "Puts the routes back without dropping the tunnel.", cat=RTG),
            act("Fix DNS", "Fix DNS", "pdns.png",
                "Rewrites resolv.conf and restarts the resolver.", cat=DNS),
            act("Restore default DNS", "Restore Default DNS",
                "papirus/network-modem.svg",
                "Hands name lookups back to the network you are on.",
                cat=DNS, confirm=True),
            # Every other Quick group ends in a More link and this one shipped
            # without it, so the six repair rows were a dead end: nothing here
            # led to the fuller recovery controls. The routing tab is where
            # "Recover internet" lives, so that is where More goes.
            surface("More repair controls", "network", "repair.png",
                    tab="routing"),
        ]},
        {"caption": "Show me", "mode": "action", "rows": [
            rep("My public IP", "My Public IP", "papirus/network-workgroup.svg", cat=SES),
            rep("My hostname", "My Hostname", "papirus/computer.svg", cat=SES),
            rep("My timezone", "My Timezone", "papirus/accessories-clock.svg", cat=SES),
            rep("Timezone of my IP", "Timezone Of My IP", "papirus/gis-weather.svg",
                cat=SES),
            rep("My MAC", "My MAC Address", "papirus/office-address-book.svg", cat=SES),
            surface("More status controls", "status", "papirus/Stacer.svg"),
        ]},
        {"caption": "Session", "mode": "action", "rows": [
            act("Log out", "Logout", "papirus/system-log-out.svg",
                cat=EMG, confirm=True),
            act("Reboot", "Reboot", "papirus/gshutdown.svg", cat=EMG, confirm=True),
            act("Shut down", "Shutdown", "papirus/system-shutdown.svg",
                cat=EMG, danger=True, confirm=True),
            surface("More session controls", "emergency", "kodachi/radiation.svg"),
        ]},
    ],
}


# ── grouped windows: one dock icon, several surfaces as tabs ────────────────
#
# Each tab NAMES an existing entry in WINDOWS above rather than restating it, so
# the nine surfaces the Network icon replaces are still exactly the nine specs
# already validated by --validate, and fixing one fixes the tab. A "@" prefix
# means one of the two hand-written country pickers in kodachi-command-window,
# which cannot be expressed as a spec because the registry maps a fixed label to
# a fixed command and cannot carry a 76-value country parameter.
TABBED = {
    # ── the isolation manager ────────────────────────────────────────────
    #
    # THIRTEEN DOCK CELLS COLLAPSE INTO THIS ONE WINDOW, and the count is not a
    # tidiness claim: LibreWolf-under-Firejail and the Firejail terminal each
    # had TWO cells, one in their functional group and a duplicate inside the
    # `Containers` sub-dock, so the dock was asking the same question in four
    # places with two of the answers repeated.
    #
    # THE FIRST TWO DESTINATIONS ARE DECLARATIVE AND THE LAST THREE ARE BUILTIN,
    # on purpose. Applications and Containers are fixed sets that belong in a
    # reviewable table. Running now, Images and Profiles are READINGS of the
    # machine, and declaring a reading is exactly how you end up claiming a
    # dedicated Firejail profile that is not installed.
    "isolation": {
        # THE TITLE MATCHES THE DOCK CELL. The cell says Isolation Manager and
        # the window said Sandbox, so the operator clicked one name and a
        # different name opened. It also under-described the window: three of
        # the seven tabs below are Podman, and "Sandbox" reads as Firejail
        # alone. Count them in the list rather than trusting this sentence,
        # which said "two of the five" until the catalog, custom-application
        # and image tabs were added under it.
        "title": "Isolation Manager",
        "subtitle": "FIREJAIL: graphical applications and terminals. PODMAN: "
                    "terminal shells only; containers have no display socket.",
        "width": 820,
        "height": 880,
        "tabs": [
            ("apps", "Applications", "sandbox"),
            ("catalog", "More applications", "@isolation-catalog"),
            ("custom", "My applications", "@isolation-custom"),
            ("containers", "Containers", "containers"),
            ("running", "Running now", "@isolation-running"),
            ("images", "Images", "@isolation-images"),
            ("profiles", "Profiles", "@isolation-profiles"),
        ],
    },
    "network": {
        "title": "Network",
        "subtitle": "Everything about how this machine reaches the internet and Tor.",
        "width": 780,
        "height": 860,
        # ORDER IS THE OPERATOR'S, NUMBERED ON HIS OWN SCREENSHOT (a7):
        # Connect 1, Routing 2, Tor 3, Exit Country 4, Avoid 5, Tor Service 6.
        # "you have the grouping wrong keep the tor tabs all together and connect
        # call it something with vpn and keep them together".
        #
        # The first draft put Routing between Avoid and Tor Service, which split
        # the four Tor surfaces in half with a VPN surface. Now the two VPN tabs
        # are adjacent, then all four Tor tabs are adjacent, then the three that
        # belong to neither.
        "tabs": [
            ("connect", "VPN Connect", "vpn"),
            ("routing", "VPN Routing", "routing"),
            ("tor", "Tor", "torrify"),
            ("tor-exit", "Tor Exit Country", "@tor-exit"),
            ("tor-exclude", "Tor Avoid", "@tor-exclude"),
            ("tor-service", "Tor Service", "tor-service"),
            ("killswitch", "Kill Switch", "killswitch"),
            ("dns", "DNS", "dns"),
            ("nettune", "Tuning", "nettune"),
        ],
    },
}


def referenced_keys():
    """Every (Category, Label) any window depends on."""
    keys = []
    for win in WINDOWS.values():
        for section in win["sections"]:
            for row in section["rows"]:
                for field in ("act", "on", "off", "check"):
                    if row.get(field):
                        keys.append(row[field])
                launcher = row.get("launcher")
                if launcher and launcher.get("act"):
                    keys.append(launcher["act"])
    return keys


def referenced_surfaces():
    """Every (window, optional tab) opened by a declarative surface row."""
    refs = []
    for win in WINDOWS.values():
        for section in win["sections"]:
            for row in section["rows"]:
                if row.get("surface"):
                    refs.append((row["surface"], row.get("tab")))
    return refs


# ── the Recipes window, generated by ─────────────────────────────────────
#   livebuilds/kodachi-terminal-build/scripts/dock/gen-recipes-window.py
#
# MEASURED GAP: the shipped registry holds 96 `Workflows` rows and exactly TWO
# were reachable from any window. A workflow is a multi-step recipe the product
# already implements (`workflow-manager run <name>`), which is the single most
# valuable thing a dock can offer: one click for a sequence a user would
# otherwise have to assemble by hand, in the right order, from eight controls.
#
# Grouped by WHAT THE USER WANTS rather than by internal name, so "Maximum
# anonymity" is found before "Base Tor DNS iptables". The "Base ..." rows are
# implementation vocabulary and sit last under Building blocks.
#
# 96 of 96 placed. Regenerate rather than hand-editing: the generator asserts
# every label against the registry and REFUSES TO EMIT if one has been renamed.
#
# BE PRECISE ABOUT WHEN THAT PROTECTION APPLIES. It fires when somebody RUNS the
# generator. NOTHING RUNS IT AT BUILD TIME, and nothing runs
# `kodachi_windows.py --validate` or `kodachi-dock-action --check` during an ISO
# build either. An earlier version of this comment said "fails at build time",
# which promised a gate that does not exist. The real protection between a
# renamed registry label and a dead dock button is a person remembering to run
# the validator, so run it after touching menu-actions.sh:
#
#   KODACHI_MENU_ACTIONS=<repo>/.../menu-actions.sh python3 kodachi_windows.py

WINDOWS["workflows"] = {
    "title": "Recipes",
    "subtitle": "122 canonical workflow files; 94 runnable recipe controls + 2 workflow tools = 96 controls, generated from the registry and canonical profiles.",
    "sections": [
        {"caption": 'Protect me now', "mode": "action",
         "note": 'One click each. These run a whole sequence, not a single setting.',
         "rows": [
            act('Maximum anonymity', 'WF: Max Anonymity', 'fluent-emoji/disguised-face.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'privacy-maximum-anonymity', 'profile_path': 'dashboard/hooks/config/profiles/privacy-maximum-anonymity.json', 'description': 'Maximum anonymity: Tor round-robin, DNSCrypt, random hostname, MAC randomization. Uses base-auth-check profile for authentication.', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Paranoid, everything on', 'WF: Paranoid Full', 'papirus/security-high.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'protection-paranoid-full', 'profile_path': 'dashboard/hooks/config/profiles/protection-paranoid-full.json', 'description': 'Maximum security: auth check, harden system, wipe traces, verify all. Uses base-auth-check profile for authentication.', 'body_steps': 7, 'body_commands': 6, 'body_pauses': 1, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 9, 'expanded_commands': 8, 'expanded_pauses': 1, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Best connection for me', 'WF: Best Connection', 'speed.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'adaptive-best-connection', 'profile_path': 'dashboard/hooks/config/profiles/adaptive-best-connection.json', 'description': "Inspect live protocol latency, then independently use routing-switch's static score table to connect the highest-ranked eligible protocol and verify", 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Harden this system', 'WF: Harden System', 'papirus/security-high.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'protection-harden-system', 'profile_path': 'dashboard/hooks/config/profiles/protection-harden-system.json', 'description': 'Apply comprehensive security hardening and verify all modules', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('User security', 'WF: User Security', 'papirus/system-users.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'protection-user-security', 'profile_path': 'dashboard/hooks/config/profiles/protection-user-security.json', 'description': 'Enable user-level security hardening', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 3, 'expanded_commands': 3, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Identity rotation', 'WF: Identity Rotation', 'fluent-emoji/counterclockwise-arrows-button.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'privacy-identity-rotation', 'profile_path': 'dashboard/hooks/config/profiles/privacy-identity-rotation.json', 'description': 'Complete identity rotation: new Tor circuit, random DNS, random hostname, verify IP change', 'body_steps': 6, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Randomise hostname', 'WF: Hostname Randomize', 'papirus/computer.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'privacy-hostname-randomize', 'profile_path': 'dashboard/hooks/config/profiles/privacy-hostname-randomize.json', 'description': 'Randomize system hostname for enhanced anonymity. Changes hostname to random value and updates system identification to prevent tracking.', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
         ]},
        {"caption": 'Set up a tunnel', "mode": "action",
         "note": 'Provision and connect one transport end to end.',
         "rows": [
            act('WireGuard', 'WF: Setup WireGuard', 'papirus/network-vpn.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_wireguard_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_wireguard_only.json', 'description': 'Terminal ISO startup with WireGuard connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('WireGuard, then Tor', 'WF: Setup WireGuard+Torrify', 'papirus/tor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_wireguard_torrify', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_wireguard_torrify.json', 'description': 'Terminal ISO startup with WireGuard connection and security hardening (with Tor torrification capability)', 'body_steps': 10, 'body_commands': 10, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-no-tor-guard',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 55, 'expanded_commands': 55, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-no-tor-guard'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('AmneziaWG (obfuscated)', 'WF: Setup AmneziaWG', 'fluent-emoji/disguised-face.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_amneziawg_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_amneziawg_only.json', 'description': 'Terminal ISO startup with AmneziaWG (obfuscated WireGuard) connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('OpenVPN', 'WF: Setup OpenVPN', 'papirus/openvpn.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_openvpn_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_openvpn_only.json', 'description': 'Terminal ISO startup with OpenVPN connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('OpenVPN over Cloak', 'WF: Setup OpenVPN over Cloak', 'fluent-emoji/socks.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_openvpn_cloak_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_openvpn_cloak_only.json', 'description': 'Terminal ISO startup with OpenVPN over Cloak connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Shadowsocks', 'WF: Setup Shadowsocks', 'papirus/nsm-proxy.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_shadowsocks_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_shadowsocks_only.json', 'description': 'Terminal ISO startup with Shadowsocks connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Hysteria2', 'WF: Setup Hysteria2', 'fluent-emoji/rocket.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_hysteria2_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_hysteria2_only.json', 'description': 'Terminal ISO startup with Hysteria2 connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('V2Ray', 'WF: Setup V2Ray', 'papirus/network-server.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_v2ray_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_v2ray_only.json', 'description': 'Terminal ISO startup with V2Ray connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Xray VLESS', 'WF: Setup Xray-VLESS', 'papirus/network-server-database.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_xray_vless_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_xray_vless_only.json', 'description': 'Terminal ISO startup with Xray-VLESS connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Xray VLESS Reality', 'WF: Setup Xray-VLESS-Reality', 'fluent-emoji/gem-stone.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_xray_vless_reality_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_xray_vless_reality_only.json', 'description': 'Terminal ISO startup with Xray-VLESS-Reality connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Xray Trojan', 'WF: Setup Xray-Trojan', 'fluent-emoji/horse.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_xray_trojan_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_xray_trojan_only.json', 'description': 'Terminal ISO startup with Xray-Trojan connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor', 'WF: Setup Tor', 'papirus/tor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_tor_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_tor_only.json', 'description': 'Terminal ISO startup with Tor connection and security hardening', 'body_steps': 46, 'body_commands': 46, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 48, 'expanded_commands': 48, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Dante proxy', 'WF: Setup Dante', 'papirus/preferences-system-network-proxy.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_dante_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_dante_only.json', 'description': 'Terminal ISO startup with Dante SOCKS5 connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Mita', 'WF: Setup Mita', 'papirus/modem.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_mita_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_mita_only.json', 'description': 'Terminal ISO startup with Mita connection and security hardening (no Tor)', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-terminal-setup-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-terminal-setup-full', 'base-tor-guard-vpn'), 'inherited_executions': 7, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Auth, then Tor', 'WF: Setup Auth+Torrify', 'papirus/keyring-manager.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'initial_terminal_setup_auth_torrify_only', 'profile_path': 'dashboard/hooks/config/profiles/initial_terminal_setup_auth_torrify_only.json', 'description': 'Minimal terminal setup: Authentication and Tor torrification with nftables+DNS (no VPN, no security hardening)', 'body_steps': 19, 'body_commands': 19, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 21, 'expanded_commands': 21, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
         ]},
        {"caption": 'Put things back', "mode": "action",
         "note": 'Recovery sequences, widest first.',
         "rows": [
            act('Recovery master', 'WF: Recovery Master', 'repair.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'recovery-master-complete', 'profile_path': 'dashboard/hooks/config/profiles/recovery-master-complete.json', 'description': 'Complete network recovery workflow with internet check, force disconnect, recover, reset, and verification', 'body_steps': 1, 'body_commands': 1, 'body_pauses': 0, 'top_level_includes': ('detorrify-complete-verify', 'base-recovery-sequence'), 'inline_includes': (), 'direct_include_edges': 2, 'expanded_steps': 14, 'expanded_commands': 14, 'expanded_pauses': 0, 'inherited_profiles': ('base-recovery-sequence', 'detorrify-complete-verify'), 'inherited_executions': 2, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Restore the network', 'WF: Recovery Network Restore', 'network.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'recovery-network-restore', 'profile_path': 'dashboard/hooks/config/profiles/recovery-network-restore.json', 'description': 'Low-level network interface and service restoration workflow. Resets network configuration, restarts services in proper order, and restores routing tables. Addresses interface-level issues like DHCP failures, corrupted routing tables, or stuck network services. Use when higher-level recovery fails.', 'body_steps': 12, 'body_commands': 12, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 12, 'expanded_commands': 12, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Network emergency', 'WF: Recovery Network Emergency', 'papirus/network-defaultroute.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'network-emergency-recovery', 'profile_path': 'dashboard/hooks/config/profiles/network-emergency-recovery.json', 'description': 'Emergency recovery: detect failure, recover internet, restart Tor, verify', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('DNS fallback', 'WF: Recovery DNS Fallback', 'pdns.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'recovery-dns-fallback', 'profile_path': 'dashboard/hooks/config/profiles/recovery-dns-fallback.json', 'description': "DNS-specific recovery workflow that tests current DNS configuration and switches to emergency fallback servers if DNS resolution fails. Addresses common DNS-related connectivity issues where network is up but domain resolution doesn't work. Maintains privacy preferences during fallback.", 'body_steps': 7, 'body_commands': 6, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 7, 'expanded_commands': 6, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Recover everything', 'WF: Emergency Recovery All', 'papirus/system-restart.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-recovery-all', 'profile_path': 'dashboard/hooks/config/profiles/emergency-recovery-all.json', 'description': 'Complete emergency recovery: master recovery, verify connectivity, restart all services', 'body_steps': 14, 'body_commands': 14, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 14, 'expanded_commands': 14, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
         ]},
        {"caption": 'Clean up after myself', "mode": "action",
         "note": 'Anti-forensics. These delete data and cannot be undone.',
         "rows": [
            act('Anti-forensics sweep', 'WF: Anti-Forensics', 'accessories-system-cleaner.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'privacy-anti-forensics', 'profile_path': 'dashboard/hooks/config/profiles/privacy-anti-forensics.json', 'description': 'Anti-forensics procedures including secure free space erasure, memory clearing, and sensitive data removal. WARNING: Time-intensive operations that cannot be interrupted.', 'body_steps': 4, 'body_commands': 3, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 3, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Remove traces', 'WF: Trace Removal', 'fluent-emoji/broom.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'privacy-trace-removal', 'profile_path': 'dashboard/hooks/config/profiles/privacy-trace-removal.json', 'description': 'Remove all traces: wipe logs, browser data, history, and temp files', 'body_steps': 4, 'body_commands': 3, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 3, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Wipe traces', 'WF: Wipe Traces', 'fluent-emoji/sponge.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'security-wipe-traces', 'profile_path': 'dashboard/hooks/config/profiles/security-wipe-traces.json', 'description': 'Security trace wipe: auth verify, wipe logs, wipe browser, wipe free space', 'body_steps': 5, 'body_commands': 4, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 4, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Wipe logs', 'WF: Wipe Logs', 'papirus/gnome-logs.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'protection-wipe-logs', 'profile_path': 'dashboard/hooks/config/profiles/protection-wipe-logs.json', 'description': 'Securely wipe system logs and browser data for privacy', 'body_steps': 4, 'body_commands': 3, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 3, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Wipe free space', 'WF: Wipe Free Space', 'papirus/drive-harddisk.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'protection-wipe-free-space', 'profile_path': 'dashboard/hooks/config/profiles/protection-wipe-free-space.json', 'description': 'Secure erasure of filesystem free space to eliminate recoverable deleted data. WARNING: Extremely time-intensive, can take hours depending on disk size.', 'body_steps': 5, 'body_commands': 4, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 4, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
         ]},
        {"caption": 'Check my work', "mode": "action",
         "note": 'Mostly read-only. Rows marked Changes things may harden, switch DNS, start Tor DNS, or remove torrify rules before they verify the result.',
         "rows": [
            rep('Full security audit', 'WF: Security Full Audit', 'fluent-emoji/microscope.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'security-full-audit', 'profile_path': 'dashboard/hooks/config/profiles/security-full-audit.json', 'description': 'Complete security audit: auth check, integrity verify, hardware RNG, entropy status', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            act('Threat check', 'WF: Security Threat', 'fluent-emoji/police-car-light.png',
                'Changes things: its second step hardens to the standard profile.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'adaptive-security-threat', 'profile_path': 'dashboard/hooks/config/profiles/adaptive-security-threat.json', 'description': 'Adaptive security threat response: score current posture, harden only when authenticated and below threshold, then report any remaining critical posture without implicitly running panic actions.', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Verify everything', 'WF: Verification', 'papirus/checkbox.svg',
                'Changes things when login is absent: its included authentication step runs with --relogin.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'verification', 'profile_path': 'dashboard/hooks/config/profiles/verification.json', 'description': 'Comprehensive verification: runs network verification and security verification (via includes), then system-level checks (connectivity, boot integrity, Tor reachability, Tor instance status). (Per-type selection is not possible in the workflow runner because step conditions cannot read parameters.)', 'body_steps': 6, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': ('base-network-verification', 'base-security-verification'), 'inline_includes': (), 'direct_include_edges': 2, 'expanded_steps': 19, 'expanded_commands': 19, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-network-verification', 'base-security-verification'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            rep('Network verification', 'WF: Base Network Verification', 'earth_scan.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-network-verification', 'profile_path': 'dashboard/hooks/config/profiles/base-network-verification.json', 'description': 'Base profile: Comprehensive network verification (health check, IP fetch, Tor check, routing status, DNS status, leak test). Include this for network diagnostics and verification workflows.', 'body_steps': 6, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            act('Security verification', 'WF: Base Security Verification', 'papirus/security-medium.svg',
                'Changes things when login is absent: its included authentication step runs with --relogin.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-security-verification', 'profile_path': 'dashboard/hooks/config/profiles/base-security-verification.json', 'description': 'Base profile: Comprehensive security verification (auth check, security score, security verify, integrity check, hardware RNG verify, entropy status). Include this for security audit and verification workflows.', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('DNS leak check', 'WF: DNS Leak Verify', 'fluent-emoji/droplet.png',
                'Changes settings: switches to a random DNS resolver before testing.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'connectivity-dns-leak-verify', 'profile_path': 'dashboard/hooks/config/profiles/connectivity-dns-leak-verify.json', 'description': 'Switch DNS configuration and verify DNS leak test succeeds', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor DNS leak check', 'WF: Tor DNS Verify Leak', 'papirus/tor.svg',
                'Changes settings: starts Tor and Tor DNS redirection before testing.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'tor-dns-verify-leak', 'profile_path': 'dashboard/hooks/config/profiles/tor-dns-verify-leak.json', 'description': 'Setup Tor DNS and verify no DNS leaks exist', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 3, 'expanded_commands': 3, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            rep('Auth full verify', 'WF: Auth Full Verify', 'papirus/preferences-certificates.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'auth-full-verify', 'profile_path': 'dashboard/hooks/config/profiles/auth-full-verify.json', 'description': 'Complete authentication verification with all checks: login, IDs, heartbeat, group', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            act('Detorrify verify', 'WF: Detorrify Verify', 'papirus/filter.svg',
                'Changes things: it removes the torrify rules, then verifies.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'detorrify-complete-verify', 'profile_path': 'dashboard/hooks/config/profiles/detorrify-complete-verify.json', 'description': 'Complete detorrification: remove all Tor routing and verify direct connection', 'body_steps': 6, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
         ]},
        {"caption": 'Diagnose a problem', "mode": "action",
         "note": 'When something is wrong and you do not yet know what.',
         "rows": [
            rep('Network diagnostic', 'WF: Network Diagnostic', 'papirus/gnome-nettool.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'network-full-diagnostic', 'profile_path': 'dashboard/hooks/config/profiles/network-full-diagnostic.json', 'description': 'Complete network diagnostic: health check, Tor status, DNS leak, IP fetch', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            rep('Network status', 'WF: Network Status', 'papirus/network-card.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'network-status-comprehensive', 'profile_path': 'dashboard/hooks/config/profiles/network-status-comprehensive.json', 'description': 'Comprehensive network status: auth, routing, Tor, DNS, IP information', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            rep('System check, basic', 'WF: System Check Basic', 'papirus/hardinfo.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'system-check-basic', 'profile_path': 'dashboard/hooks/config/profiles/system-check-basic.json', 'description': 'Quick system overview: memory, disk, interfaces, and active processes', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ()}),
            rep('System check, advanced', 'WF: System Check Advanced', 'papirus/gtk-info.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'system-check-advanced', 'profile_path': 'dashboard/hooks/config/profiles/system-check-advanced.json', 'description': 'Deep system analysis: kernel, firewall, security audit, and network diagnostics', 'body_steps': 9, 'body_commands': 9, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 9, 'expanded_commands': 9, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            act('Benchmark routing', 'WF: Routing Benchmark', 'speed.png',
                'Changes settings: benchmarks protocols and exports routing config.',
                cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'routing-protocol-benchmark', 'profile_path': 'dashboard/hooks/config/profiles/routing-protocol-benchmark.json', 'description': 'Benchmark all routing protocols, export results, display scores', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            rep('Monitoring', 'WF: Monitoring', 'papirus/utilities-system-monitor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'monitoring', 'profile_path': 'dashboard/hooks/config/profiles/monitoring.json', 'description': 'Comprehensive read-only monitoring snapshot: current IP/geo, DNS configuration, routing status, Tor instance status, active network connections and routes. (Per-type selection is not possible in the workflow runner because step conditions cannot read parameters; this shows all monitors at once.)', 'body_steps': 9, 'body_commands': 9, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 9, 'expanded_commands': 9, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            rep('Show workflow state', 'WF: Show State', 'fluent-emoji/ledger.png', cat=WFL, workflow_meta={'kind': 'utility', 'command': 'sudo workflow-manager state', 'description': 'Workflow utility, not a runnable workflow.'}),
            rep('List templates', 'WF: List Templates', 'fluent-emoji/card-index.png', cat=WFL, workflow_meta={'kind': 'utility', 'command': 'sudo workflow-manager list', 'description': 'Workflow utility, not a runnable workflow.'}),
         ]},
        {"caption": 'Emergency recipes', "mode": "action",
         "note": 'The panic and lockdown sequences. Every one of these is disruptive.',
         "rows": [
            act('Panic', 'WF: Emergency Panic', 'papirus/security-low.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-panic', 'profile_path': 'dashboard/hooks/config/profiles/emergency-panic.json', 'description': 'Unified emergency panic profile: Execute soft, medium, or hard panic mode based on selected level parameter. Uses base-auth-check profile for authentication. Consolidates 3 panic profiles into one parametrized workflow with optional security score checking.', 'body_steps': 3, 'body_commands': 2, 'body_pauses': 1, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 5, 'expanded_commands': 4, 'expanded_pauses': 1, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Panic, medium', 'WF: Emergency Panic Medium', 'papirus/security-medium.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-panic-medium', 'profile_path': 'dashboard/hooks/config/profiles/emergency-panic-medium.json', 'description': 'Emergency medium panic mode: kill network, terminate processes, clear memory, unmount devices. Uses base-auth-check profile for authentication.', 'body_steps': 4, 'body_commands': 2, 'body_pauses': 2, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 6, 'expanded_commands': 4, 'expanded_pauses': 2, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Disconnect everything', 'WF: Emergency Disconnect All', 'fluent-emoji/broken-chain.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-disconnect-all', 'profile_path': 'dashboard/hooks/config/profiles/emergency-disconnect-all.json', 'description': 'Disconnect all protocols, reset routing, and verify clean state', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Kill the network', 'WF: Emergency Network Kill', 'Network-Off-icon.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-network-kill', 'profile_path': 'dashboard/hooks/config/profiles/emergency-network-kill.json', 'description': 'Emergency network kill: immediately kill all network connections and verify blocked', 'body_steps': 4, 'body_commands': 3, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 3, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Arm the kill switch', 'WF: Emergency Kill Switch Arm', 'fluent-emoji/no-entry.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-kill-switch-arm', 'profile_path': 'dashboard/hooks/config/profiles/emergency-kill-switch-arm.json', 'description': 'Arm emergency kill switch for high-alert preparedness state', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 3, 'expanded_commands': 3, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Set up the kill switch', 'WF: Emergency Kill Switch Setup', 'papirus/preferences-system-firewall.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'network-kill-switch-setup', 'profile_path': 'dashboard/hooks/config/profiles/network-kill-switch-setup.json', 'description': 'Setup network kill switch: arm, configure panic profile, verify setup', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Emergency wipe', 'WF: Emergency Wipe', 'nuke.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'protection-emergency-wipe', 'profile_path': 'dashboard/hooks/config/profiles/protection-emergency-wipe.json', 'description': 'Emergency data wipe: logs, browser, temp files, and free space', 'body_steps': 5, 'body_commands': 4, 'body_pauses': 1, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 4, 'expanded_pauses': 1, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Block if not on Tor', 'WF: Emergency Block If Not Tor', 'papirus/tor.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-block-if-not-tor', 'profile_path': 'dashboard/hooks/config/profiles/emergency-block-if-not-tor.json', 'description': 'Check if Tor is active and block internet if Tor is not detected', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Block by country', 'WF: Emergency Block Country', 'fluent-emoji/world-map.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-block-if-country-match', 'profile_path': 'dashboard/hooks/config/profiles/emergency-block-if-country-match.json', 'description': 'Block internet if current IP country matches specified high-risk country (e.g., US)', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Block suspicious geo', 'WF: Emergency Block Suspicious Geo', 'earth_scan.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-block-suspicious-geo', 'profile_path': 'dashboard/hooks/config/profiles/emergency-block-suspicious-geo.json', 'description': 'Block internet if IP geolocates to 5eyes surveillance countries', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Block non-numeric IP', 'WF: Emergency Block Non-Numeric IP', 'papirus/filter.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'emergency-block-if-ip-not-numeric', 'profile_path': 'dashboard/hooks/config/profiles/emergency-block-if-ip-not-numeric.json', 'description': 'Fetch IP and block internet if IP is not a valid numeric address', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
         ]},
        {"caption": 'Tor routing variants', "mode": "action",
         "note": 'Different ways to push traffic through Tor. Pick one; they are alternatives, not steps.',
         "rows": [
            act('Torrify, iptables', 'WF: Torrify iptables Simple', 'papirus/filter.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-dns-iptables-simple', 'profile_path': 'dashboard/hooks/config/profiles/torrify-dns-iptables-simple.json', 'description': 'Simple Tor DNS torrification with iptables: auth check, torrify system and DNS, verify connection', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-torrify-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-torrify-full'), 'inherited_executions': 2, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Torrify, nftables', 'WF: Torrify nftables Simple', 'papirus/preferences-system-firewall.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-dns-nftables-simple', 'profile_path': 'dashboard/hooks/config/profiles/torrify-dns-nftables-simple.json', 'description': 'Simple Tor DNS torrification with nftables: auth check, torrify system and DNS, verify connection', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-torrify-full',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-torrify-full'), 'inherited_executions': 2, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, iptables round robin', 'WF: Torrify LB iptables RR', 'fluent-emoji/shuffle-tracks-button.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-iptables-roundrobin', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-iptables-roundrobin.json', 'description': 'Load-balanced Tor torrification with iptables using ROUND-ROBIN algorithm: Distributes traffic evenly across all Tor instances in sequential order.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, iptables weighted', 'WF: Torrify LB iptables Weighted', 'fluent-emoji/balance-scale.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-iptables-weighted', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-iptables-weighted.json', 'description': 'Load-balanced Tor torrification with iptables using WEIGHTED algorithm: Distributes traffic based on instance weight/priority for prioritized routing.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, iptables consistent', 'WF: Torrify LB iptables Consistent', 'fluent-emoji/chains.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-iptables-consistent', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-iptables-consistent.json', 'description': 'Load-balanced Tor torrification with iptables using CONSISTENT-HASHING algorithm: Routes traffic based on connection hash for stable routing per connection.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, nftables round robin', 'WF: Torrify LB nftables RR', 'fluent-emoji/shuffle-tracks-button.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-nftables-roundrobin', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-nftables-roundrobin.json', 'description': 'Load-balanced Tor torrification with nftables using ROUND-ROBIN algorithm: Distributes traffic evenly across all Tor instances in sequential order.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, nftables weighted', 'WF: Torrify LB nftables Weighted', 'fluent-emoji/balance-scale.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-nftables-weighted', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-nftables-weighted.json', 'description': 'Load-balanced Tor torrification with nftables using WEIGHTED algorithm: Distributes traffic based on instance weight/priority for prioritized routing.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Balance, nftables consistent', 'WF: Torrify LB nftables Consistent', 'fluent-emoji/chains.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'torrify-balance-nftables-consistent', 'profile_path': 'dashboard/hooks/config/profiles/torrify-balance-nftables-consistent.json', 'description': 'Load-balanced Tor torrification with nftables using CONSISTENT-HASHING algorithm: Routes traffic based on connection hash for stable routing per connection.', 'body_steps': 0, 'body_commands': 0, 'body_pauses': 0, 'top_level_includes': ('base-tor-load-balance',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-load-balance', 'base-tor-multiinstance-setup'), 'inherited_executions': 3, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor DNS via iptables', 'WF: Base Tor DNS iptables', 'pdns.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'tor-dns-iptables-full', 'profile_path': 'dashboard/hooks/config/profiles/tor-dns-iptables-full.json', 'description': 'Setup Tor DNS ONLY with iptables (no torrification)', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor DNS via nftables', 'WF: Base Tor DNS nftables', 'papirus/network-server.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'tor-dns-nftables-full', 'profile_path': 'dashboard/hooks/config/profiles/tor-dns-nftables-full.json', 'description': 'Setup Tor DNS ONLY with nftables (no torrification)', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
         ]},
        {"caption": 'DNS recipes', "mode": "action",
         "note": 'Whole DNS configurations, applied in one step.',
         "rows": [
            act('Enable DNSCrypt', 'WF: DNS DNSCrypt Enable', 'dnscryptt.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-dnscrypt-enable', 'profile_path': 'dashboard/hooks/config/profiles/dns-dnscrypt-enable.json', 'description': 'Enable DNSCrypt with Cloudflare resolver for encrypted DNS queries', 'body_steps': 6, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 6, 'expanded_commands': 6, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor DNS, then verify', 'WF: DNS Tor Enable Verify', 'papirus/tor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-tor-enable-verify', 'profile_path': 'dashboard/hooks/config/profiles/dns-tor-enable-verify.json', 'description': 'Enable Tor DNS with nftables and verify no DNS leaks', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Random switch', 'WF: DNS Random Switch', 'fluent-emoji/game-die.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-random-switch', 'profile_path': 'dashboard/hooks/config/profiles/dns-random-switch.json', 'description': 'Switch to random DNS servers for enhanced privacy', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Random, mixed sources', 'WF: DNS Random Mixed', 'fluent-emoji/shuffle-tracks-button.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-switch-random-mixed', 'profile_path': 'dashboard/hooks/config/profiles/dns-switch-random-mixed.json', 'description': 'Switch DNS to 14 random servers: 7 reputable + 7 normal, with health verification', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Pi-hole', 'WF: DNS Pi-hole Enable', 'papirus/network-server-database.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-pihole-enable', 'profile_path': 'dashboard/hooks/config/profiles/dns-pihole-enable.json', 'description': 'Enable Pi-hole DNS filtering for ad and tracker blocking', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Emergency fallback', 'WF: DNS Fallback Emergency', 'state/network-server-off.png',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'dns-fallback-emergency', 'profile_path': 'dashboard/hooks/config/profiles/dns-fallback-emergency.json', 'description': 'Emergency DNS fallback with connectivity verification', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 3, 'expanded_commands': 3, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor DNS fallback', 'WF: Tor DNS Fallback', 'papirus/tor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'tor-dns-fallback', 'profile_path': 'dashboard/hooks/config/profiles/tor-dns-fallback.json', 'description': 'Try Tor DNS setup with automatic fallback to regular DNS if fails', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            rep('Health check', 'WF: DNS Health Check', 'fluent-emoji/medical-symbol.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'dns-health-check-switch', 'profile_path': 'dashboard/hooks/config/profiles/dns-health-check-switch.json', 'description': 'DNS health check and automatic switch to best performing servers', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
         ]},
        {"caption": 'Connection and session', "mode": "action",
         "note": 'Routing changes and the sign-in lifecycle.',
         "rows": [
            act('Connect by protocol', 'WF: Routing Protocol Connect', 'papirus/network-vpn.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'routing-protocol-connect', 'profile_path': 'dashboard/hooks/config/profiles/routing-protocol-connect.json', 'description': 'Universal routing protocol connection: Connect to any supported routing protocol (OpenVPN, WireGuard, Shadowsocks, Tor, etc.) with authentication check, IP verification, and alert on IP change. Replaces 12+ individual protocol profiles.', 'body_steps': 8, 'body_commands': 7, 'body_pauses': 1, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 10, 'expanded_commands': 9, 'expanded_pauses': 1, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Disconnect cleanly', 'WF: Routing Disconnect Clean', 'papirus/network-defaultroute.svg',
                'This runs a whole sequence of steps, not one command. Accepting here is the only time this window asks you.',
                cat=WFL, danger=True, confirm=True, workflow_meta={'kind': 'run', 'profile_id': 'routing-disconnect-clean', 'profile_path': 'dashboard/hooks/config/profiles/routing-disconnect-clean.json', 'description': 'Pure disconnect profile that cleanly disconnects all routing connections (VPN/Tor), verifies the disconnection status, and displays current IP address.', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Failover cascade', 'WF: Failover Cascade', 'fluent-emoji/counterclockwise-arrows-button.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'adaptive-failover-cascade', 'profile_path': 'dashboard/hooks/config/profiles/adaptive-failover-cascade.json', 'description': 'Try WireGuard, OpenVPN, AmneziaWG, OpenVPN over Cloak, then Tor. Each fallback runs only when the preceding connection attempt fails.', 'body_steps': 7, 'body_commands': 7, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 9, 'expanded_commands': 9, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Re-check sign-in', 'WF: Auth Check Reauth', 'papirus/keyring-manager.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'auth-check-reauth', 'profile_path': 'dashboard/hooks/config/profiles/auth-check-reauth.json', 'description': 'Check authentication status and re-authenticate if needed', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Set up heartbeat', 'WF: Auth Heartbeat Setup', 'fluent-emoji/stopwatch.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'auth-heartbeat-setup', 'profile_path': 'dashboard/hooks/config/profiles/auth-heartbeat-setup.json', 'description': 'Setup authenticated session with heartbeat monitoring for continuous connectivity', 'body_steps': 3, 'body_commands': 3, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Terminal routing', 'WF: Base Terminal Routing', 'terminal(1).png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-terminal-routing-connect', 'profile_path': 'dashboard/hooks/config/profiles/base-terminal-routing-connect.json', 'description': 'Base profile: Robust routing protocol connection with recovery fallback. Handles connection, verification, and automatic recovery if connection fails. Parametrized by protocol.', 'body_steps': 10, 'body_commands': 10, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 10, 'expanded_commands': 10, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Terminal setup, full', 'WF: Base Terminal Setup Full', 'papirus/utilities-terminal.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-terminal-setup-full', 'profile_path': 'dashboard/hooks/config/profiles/base-terminal-setup-full.json', 'description': 'Base profile: Complete terminal setup workflow for VPN/routing protocols. Includes authentication, network check, initial status, security hardening, DNSCrypt setup, Tor guard, protocol connection, and final status. Parametrized by protocol.', 'body_steps': 11, 'body_commands': 6, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': ('base-security-hardening', 'base-dnscrypt-setup', 'base-tor-guard-vpn', 'base-terminal-routing-connect', 'base-system-status'), 'direct_include_edges': 6, 'expanded_steps': 38, 'expanded_commands': 38, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect', 'base-tor-guard-vpn'), 'inherited_executions': 6, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Terminal, no Tor guard', 'WF: Base Terminal No Tor Guard', 'papirus/ssh-askpass-gnome.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-terminal-setup-no-tor-guard', 'profile_path': 'dashboard/hooks/config/profiles/base-terminal-setup-no-tor-guard.json', 'description': 'Base profile: Complete terminal setup workflow for VPN/routing protocols WITHOUT Tor guard check. For workflows that will torrify after connection. Includes authentication, network check, initial status, security hardening, DNSCrypt setup, protocol connection, and final status. Parametrized by protocol.', 'body_steps': 13, 'body_commands': 8, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': ('base-system-status', 'base-security-hardening', 'base-dnscrypt-setup', 'base-terminal-routing-connect', 'base-system-status'), 'direct_include_edges': 6, 'expanded_steps': 45, 'expanded_commands': 45, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-dnscrypt-setup', 'base-security-hardening', 'base-system-status', 'base-terminal-routing-connect'), 'inherited_executions': 6, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
         ]},
        {"caption": 'Building blocks', "mode": "action",
         "note": 'The pieces the recipes above are assembled from. Use these only if you know which single step you want.',
         "rows": [
            act('Auth check', 'WF: Base Auth Check', 'papirus/keyring-manager.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-auth-check', 'profile_path': 'dashboard/hooks/config/profiles/base-auth-check.json', 'description': 'Base profile: Authentication check and conditional re-authentication. Include this in profiles that require authenticated access. Used by 30+ profiles.', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Routing connect', 'WF: Base Routing Connect', 'papirus/network-vpn.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-routing-connect-template', 'profile_path': 'dashboard/hooks/config/profiles/base-routing-connect-template.json', 'description': 'Base profile template: Generic routing protocol connection workflow. This is a parametrized template that can be used for any routing protocol (openvpn, wireguard, shadowsocks, tor, etc.). Include this and provide protocol parameter.', 'body_steps': 8, 'body_commands': 7, 'body_pauses': 1, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 10, 'expanded_commands': 9, 'expanded_pauses': 1, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('DNSCrypt setup', 'WF: Base DNSCrypt Setup', 'dnscryptt.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-dnscrypt-setup', 'profile_path': 'dashboard/hooks/config/profiles/base-dnscrypt-setup.json', 'description': 'Base profile: Configure and verify DNSCrypt for encrypted DNS queries. Include this for terminal setup workflows requiring DNSCrypt.', 'body_steps': 2, 'body_commands': 2, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 2, 'expanded_commands': 2, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Security hardening', 'WF: Base Security Hardening', 'shield_yellow.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-security-hardening', 'profile_path': 'dashboard/hooks/config/profiles/base-security-hardening.json', 'description': 'Base profile: Perform security hardening actions (verify, conditional harden, MAC randomization, hostname randomization, timezone randomization). Include this for security setup workflows.', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 5, 'expanded_commands': 5, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            rep('System status', 'WF: Base System Status', 'papirus/Stacer.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-system-status', 'profile_path': 'dashboard/hooks/config/profiles/base-system-status.json', 'description': 'Base profile: Display current system status (IP, MAC, hostname, timezone, security, routing, DNS). Read-only status display. Include this for system state visibility.', 'body_steps': 9, 'body_commands': 9, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 9, 'expanded_commands': 9, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'sudo')}),
            act('Recovery sequence', 'WF: Base Recovery Sequence', 'repair.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-recovery-sequence', 'profile_path': 'dashboard/hooks/config/profiles/base-recovery-sequence.json', 'description': 'Base profile: Standard recovery sequence (disconnect, recover, reset, recover-internet, verify connectivity). Include this for network recovery workflows. Designed to restore network connectivity after failures or panic modes.', 'body_steps': 7, 'body_commands': 7, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ('auth', 'confirmation', 'danger', 'destructive', 'sudo')}),
            act('Torrify, full', 'WF: Base Torrify Full', 'papirus/tor.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-torrify-full', 'profile_path': 'dashboard/hooks/config/profiles/base-torrify-full.json', 'description': 'Base profile: Complete system torrification with DNS and all traffic routed through Tor. Supports both simple and full modes with parametrized firewall backend (iptables/nftables).', 'body_steps': 9, 'body_commands': 9, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor multi-instance', 'WF: Base Tor Multi-Instance', 'papirus/org.gnome.Boxes.svg', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-tor-multiinstance-setup', 'profile_path': 'dashboard/hooks/config/profiles/base-tor-multiinstance-setup.json', 'description': 'Base profile: Tor multi-instance setup (auth check, Tor status check, start if needed, create instances, start all, list IPs). Include this for Tor load-balancing workflows. Note: Does NOT include balancing mode setup - that must be added by the including profile.', 'body_steps': 5, 'body_commands': 5, 'body_pauses': 0, 'top_level_includes': ('base-auth-check',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 7, 'expanded_commands': 7, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check',), 'inherited_executions': 1, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor load balance', 'WF: Base Tor Load Balance', 'fluent-emoji/balance-scale.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-tor-load-balance', 'profile_path': 'dashboard/hooks/config/profiles/base-tor-load-balance.json', 'description': 'Base profile: Load-balanced Tor torrification with parametrized firewall backend. Creates multiple Tor instances and distributes traffic using selected load balancing algorithm.', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': ('base-tor-multiinstance-setup',), 'inline_includes': (), 'direct_include_edges': 1, 'expanded_steps': 11, 'expanded_commands': 11, 'expanded_pauses': 0, 'inherited_profiles': ('base-auth-check', 'base-tor-multiinstance-setup'), 'inherited_executions': 2, 'flags': ('auth', 'confirmation', 'danger', 'sudo')}),
            act('Tor guard + VPN', 'WF: Base Tor Guard VPN', 'fluent-emoji/vpn-shield.png', cat=WFL, workflow_meta={'kind': 'run', 'profile_id': 'base-tor-guard-vpn', 'profile_path': 'dashboard/hooks/config/profiles/base-tor-guard-vpn.json', 'description': 'Base profile: Tor/VPN conflict guard - prevents VPN connections while system is torrified. Include this before VPN connection attempts to avoid conflicts.', 'body_steps': 4, 'body_commands': 4, 'body_pauses': 0, 'top_level_includes': (), 'inline_includes': (), 'direct_include_edges': 0, 'expanded_steps': 4, 'expanded_commands': 4, 'expanded_pauses': 0, 'inherited_profiles': (), 'inherited_executions': 0, 'flags': ()}),
         ]},
    ],
}


if __name__ == "__main__":
    import os
    import sys

    # The installed path is the default because that is the only one that
    # exists on the ISO this file ships on. A checkout is named at run time
    # through KODACHI_MENU_ACTIONS, so no developer's home directory is baked
    # into a shipped file.
    path = os.environ.get("KODACHI_MENU_ACTIONS",
                          "/usr/local/lib/kodachi-rofi/menu-actions.sh")
    if len(sys.argv) > 1 and os.path.exists(sys.argv[-1]):
        path = sys.argv[-1]
    known = set()
    # errors="replace" so a bad byte in menu-actions.sh fails this validator
    # as a PARITY failure with a readable list, not as a UnicodeDecodeError
    # that says nothing about which row is wrong.
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("#") or "\t" not in line:
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 5:
            known.add((f[0], f[1]))
    keys = referenced_keys()
    missing = sorted({k for k in keys if k not in known})
    rows = sum(len(s["rows"]) for w in WINDOWS.values() for s in w["sections"])
    # A tab that names a window key which does not exist would render an empty
    # tab and say nothing, so check the references the same way the row keys are
    # checked. "@" prefixed tabs are the hand-written pickers and have no spec.
    bad_tabs = sorted(
        f"{group}/{key} -> {ref}"
        for group, spec in TABBED.items()
        for key, _label, ref in spec["tabs"]
        if not ref.startswith("@") and ref not in WINDOWS)
    bad_surfaces = []
    for target, tab in referenced_surfaces():
        if target not in WINDOWS and target not in TABBED:
            bad_surfaces.append(f"{target} -> unknown surface")
            continue
        if tab is not None:
            if target not in TABBED:
                bad_surfaces.append(f"{target}/{tab} -> target is not tabbed")
                continue
            valid_tabs = {key for key, _label, _ref in TABBED[target]["tabs"]}
            if tab not in valid_tabs:
                bad_surfaces.append(f"{target}/{tab} -> unknown tab")
    print(f"windows {len(WINDOWS)}   rows {rows}   registry references {len(keys)}   "
          f"registry rows read {len(known)}   tabbed groups {len(TABBED)}   "
          f"tabs {sum(len(v['tabs']) for v in TABBED.values())}")
    for t in bad_tabs:
        print(f"  UNRESOLVED TAB  {t}")
    for surface in sorted(bad_surfaces):
        print(f"  UNRESOLVED SURFACE  {surface}")
    for k in missing:
        print(f"  UNRESOLVED  {k[0]} / {k[1]}")
    # missing holds (Category, Label) TUPLES and bad_tabs holds STRINGS, so they
    # are counted together and printed apart. Merging them into one list made the
    # tuple-unpacking print above iterate a string's characters and emit
    # "UNRESOLVED n / e", which is a real defect this file's own sabotage run
    # surfaced: a failure report that is itself malformed hides what failed.
    total_bad = len(missing) + len(bad_tabs) + len(bad_surfaces)
    print("ALL REFERENCES RESOLVE" if not total_bad else f"{total_bad} UNRESOLVED")
    sys.exit(1 if total_bad else 0)
