#!/usr/bin/env python3
# Kodachi Session Status - snapshot renderer
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
# Turns ONE `conky-status panel all --json` snapshot into the tagged stream
# kodachi-status-window lays out:
#
#   #TITLE / #AGE / #SECTION <title> / #ROW <label> <value> <state>
#
# Reads the snapshot JSON on stdin. argv[1] is the mode (`report`, a single
# field name, or `--list-fields`), argv[2] the already-resolved remote
# timezone. That is the EXACT calling convention the code had when it lived
# inside `python3 -c` in kodachi-dock-status, because `python3 -c code a b` and
# `python3 file.py a b` both put the first argument at sys.argv[1].
#
# WHY IT IS A FILE NOW. It had two consumers and could only be reached by one.
# kodachi-dock-status is a shell script and kodachi-command-window is a GTK
# program, and the GTK program may not execute a presentation wrapper: the
# direct-execution contract lists kodachi-dock-status in PROXY_BASENAMES and
# the whole contract fails to load if any binding names it (kodachi_direct.py
# _validate_binding). So the GTK Status window had no way to reach this
# renderer, its two report rows ran `conky-status panel all` instead, and the
# operator got a key=value dump where a laid-out window used to be. A module
# both callers import is the only shape that gives the window back WITHOUT a
# second renderer: two copies of a status renderer is two machines that will
# eventually disagree about the same box.
#
# Being a file also retires a real hazard the old form carried: the code lived
# inside a single-quoted shell string, so it could not contain an apostrophe
# anywhere, comments included, and adding one broke the script at parse time.
#
# Author: Warith Al Maawali
# Version: <lab-host>
# Last updated: 2026-09-04

import calendar
import json
import os
import subprocess
import sys
import time

# THIS FILE IS A SCRIPT, NOT AN IMPORTABLE MODULE, AND IT SAYS SO BEFORE IT
# TOUCHES STDIN. It sits in /usr/local/lib/kodachi beside five genuinely
# importable kodachi_*.py modules and shares their naming convention, so a
# future `import kodachi_session_report` is a plausible mistake, and without this
# guard it would BLOCK FOREVER on json.load(sys.stdin) with no error and no
# traceback. Raised by the inspector.
#
# THE GUARD USED TO SIT BELOW THE TWO `sys.argv` READS AND THEREFORE COULD
# NEVER FIRE. Measured 2026-09-04: importing this file raised
# `IndexError: list index out of range` from `MODE = sys.argv[1]`, not the
# sentence below, because an importer's argv has no [1]. The message that
# exists to tell the next reader how to run this file was unreachable, and the
# error they actually got named neither the file's nature nor the fix. The
# sibling kodachi_session_pool.py has the same guard ABOVE its first read,
# which is why that one reports correctly. Order is the whole fix.
#
# The body below is the renderer lifted VERBATIM out of kodachi-dock-status, so
# it is deliberately not indented into a __main__ block: re-indenting 570 lines
# to express "this is the entry point" would trade a real property, that the
# two callers provably run identical code, for a stylistic one.
if __name__ != "__main__":
    raise ImportError(
        "kodachi_session_report is a command-line renderer, not a module. "
        "Run it as: python3 <path> <mode>")

MODE = sys.argv[1]
REMOTE_TZ = sys.argv[2] if len(sys.argv) > 2 else ""

try:
    doc = json.load(sys.stdin)
except (ValueError, OSError):
    sys.exit(1)

# `panel all` returns the data section; a full snapshot nests it under data.data.
root = doc
for step in ("data", "data"):
    if isinstance(root, dict) and step in root and isinstance(root[step], dict):
        root = root[step]

UNKNOWN = "unknown"


def dig(*path, default=UNKNOWN):
    """Walk a key path. A missing or empty leaf reads as unknown, never as blank,
    so a field that failed to collect can never be mistaken for a real answer."""
    node = root
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    if node is None:
        return default
    if isinstance(node, bool):
        return "Yes" if node else "No"
    text = str(node).strip()
    return text if text else default


# ── Facts a dock action CHANGES, read live rather than from the snapshot ──
#
# The snapshot is deliberately allowed to be up to STATUS_TTL (90s) old, because
# collecting a fresh one walks eight adapters and was measured at 10.45s. That
# is the right trade for almost every field, and the wrong one for the three
# facts the dock itself can change from the row directly above: Random hostname,
# Random timezone and Random MAC. The operator hit exactly that, 2026-08-23:
# "both of them changed but they take a while, they do not change immediately,
# when using the show button you see the old one for almost 20 to 30 seconds".
#
# Refreshing the snapshot would cost 10s per click and fix it slowly. These
# three are instead read STRAIGHT FROM THE KERNEL, which costs one file read
# each, no subprocess and no adapter. A live read that fails falls back to the
# snapshot value, so this can only ever be fresher, never emptier.
def live_hostname():
    try:
        import socket
        return socket.gethostname().strip()
    except Exception:
        return ""


def live_timezone():
    # /etc/localtime FIRST, and the order is the whole point.
    #
    # I had /etc/timezone first, which reintroduced the exact staleness this
    # function exists to remove. Caught by <agent>. The producer is
    # health-control TimezoneSync.update_timezone (commands/timezone.rs:805-834):
    # it does `ln -sf /usr/share/zoneinfo/<zone> /etc/localtime` and then
    # `timedatectl set-timezone`, and NEITHER of those writes /etc/timezone.
    # systemd deprecated that file; on Debian it is maintained by the tzdata
    # package, so it can sit at the install-time zone forever. A
    # nonempty stale value there would have masked the fresh symlink and the
    # dock would have kept showing the old zone with no cache involved at all.
    try:
        target = os.readlink("/etc/localtime")
        marker = "/zoneinfo/"
        cut = target.find(marker)
        if cut >= 0:
            value = target[cut + len(marker):].strip()
            if value:
                return value
    except Exception:
        pass
    # Fallback only: a box where /etc/localtime is a real file rather than a
    # symlink (some minimal images copy it) has nothing to read back from it.
    try:
        with open("/etc/timezone", encoding="utf-8") as handle:
            value = handle.read().strip()
        if value:
            return value
    except Exception:
        pass
    return ""


def live_mac(iface):
    if not iface or iface == UNKNOWN:
        return ""
    try:
        with open("/sys/class/net/%s/address" % iface, encoding="utf-8") as handle:
            return handle.read().strip()
    except Exception:
        return ""


def fresher(live_value, cached_value):
    """The live reading when there is one, the cached reading otherwise.

    FALL BACK, never fail. A live reader that cannot answer (a container with no
    /sys, a hostname syscall that raises) must leave the field exactly as it was
    rather than blanking a fact the snapshot knows."""
    live_value = (live_value or "").strip()
    return live_value if live_value else cached_value


def onoff(*path):
    value = dig(*path)
    if value in ("True", "true", "Yes"):
        return "On"
    if value in ("False", "false", "No"):
        return "Off"
    return value


def joined(*parts):
    kept = [p for p in parts if p and p != UNKNOWN]
    return ", ".join(kept) if kept else UNKNOWN


def nameservers():
    node = root.get("dns", {})
    servers = node.get("nameservers")
    if isinstance(servers, list):
        listed = [str(s).strip() for s in servers if str(s).strip()]
        if listed:
            return listed
    listed = [dig("dns", "ns%d" % n, default="") for n in (1, 2, 3)]
    listed = [s for s in listed if s and s != UNKNOWN]
    return listed or [UNKNOWN]


def snapshot_age():
    """How old the DATA is, in words.

    Two traps, both hit on 2026-08-17 and both producing a confidently wrong
    number rather than an error:

    1. The stamp to use is the envelope timestamp, the one beside `command` and
       `status`, because that is when this snapshot was produced. The nested
       online_status timestamp is when one adapter last reached the network and
       runs behind it.
    2. Every Kodachi stamp is UTC. `time.mktime` interprets a struct_time as
       LOCAL time, so on this Europe/Berlin box the first version reported a
       56-second-old snapshot as 181 minutes old. calendar.timegm is the UTC
       counterpart and is what makes the number mean anything.
    """
    stamp = ""
    if isinstance(doc, dict):
        stamp = str(doc.get("timestamp") or "").strip()
    if not stamp:
        stamp = dig("online_info", "online_status", "timestamp", default="")
    if not stamp or stamp == UNKNOWN:
        return ""
    try:
        cleaned = stamp.split(".")[0].replace("Z", "")
        taken = calendar.timegm(time.strptime(cleaned, "%Y-%m-%dT%H:%M:%S"))
        delta = max(0, int(time.time() - taken))
    except (ValueError, OverflowError):
        return ""
    if delta < 90:
        return "%ds ago" % delta
    if delta < 5400:
        return "%dm ago" % (delta // 60)
    return "%dh ago" % (delta // 3600)


def public_ip():
    return joined(dig("ip", "public"),
                  dig("online_info", "online_status", "country_flag", default=""),
                  dig("online_info", "online_status", "country", default=""))


def login_word():
    """Signed-in, but never while the device is BLOCKED.

    Belt and braces, NOT a fix for a known defect. The history is worth keeping
    because it is a good example of a plausible bug that was not one:
    <agent> traced a client-side asymmetry (online-auth check-login
    rejects is_blocked:true at main.rs:2002 while check-all-status, which the
    conky snapshot is built from, only prints the flag) and read it as "a
    blocked device renders Signed in: On". <agent> then checked the
    SERVER, and auth_check.php:352-385 gates every action check-all-status uses
    behind the same block list, before any handler, so a blocked session can
    never reach the field at all. The finding was retracted.

    The guard stays anyway: it costs one comparison, and if the snapshot ever
    does carry blocked=Yes, calling that "signed in" would be wrong no matter
    which layer let it through. It asserts nothing about online-auth.

    Still unexplained, and I am not claiming a cause: on
    testvm-Pixel-8-Pro-3eb556 this field read "Signed in: On   Group: Premium"
    off a 2-second-old snapshot while `online-auth check-login` said the
    session was invalid. Snapshot age is not the answer, but a PER-ADAPTER
    cache inside conky-status would be, since the envelope timestamp records
    when the snapshot was assembled and not when each adapter last ran. That is
    a hypothesis, unverified, and I could not re-derive it after authenticating.
    """
    login = dig("auth", "login")
    blocked = str(dig("auth", "blocked_human", default="")).strip().lower()
    if blocked in ("on", "yes", "true", "blocked"):
        return "No, this device is BLOCKED"
    return login


def tor_line():
    ip = dig("ip", "tor", "ip", default="")
    if ip and ip != UNKNOWN:
        return joined(ip,
                      dig("ip", "tor", "flag", default=""),
                      joined(dig("ip", "tor", "city", default=""),
                             dig("ip", "tor", "country", default="")))
    return "no Tor exit seen"


def torrify_line():
    """Whether SYSTEM traffic leaves through Tor, which is not the same question
    as whether the Tor daemon is up. The snapshot answers it by comparing the
    effective egress source against the Tor exit."""
    source = dig("ip", "effective_source", default="")
    effective = dig("ip", "effective", "ip", default="")
    tor_ip = dig("ip", "tor", "ip", default="")
    if source == "tor" or (effective != UNKNOWN and effective == tor_ip):
        return "On, system traffic exits via Tor"
    if tor_ip and tor_ip != UNKNOWN:
        return "Off, Tor is reachable but system traffic is not routed through it"
    return "Off"


FIREWALL_UNITS = {
    "nftables": "nftables.service",
    "fail2ban": "fail2ban.service",
    "ufw": "ufw.service",
    "firewalld": "firewalld.service",
    "iptables": "netfilter-persistent.service",
}

# nftables and iptables are kernel netfilter. Their units are oneshots that load
# a ruleset and exit, so MainPID is 0 and there is no daemon to name. Printing
# "pid 0" there would read as a broken lookup, so they are described instead.
FIREWALL_NO_DAEMON = ("nftables", "iptables")


def unit_detail(unit):
    """LoadState, ActiveState and MainPID for one systemd unit, unprivileged.

    Deliberately NOT pgrep. Measured on <lab-host> while writing this:
    pgrep -f fail2ban-server returned the real pid PLUS the probing shell and
    its ssh peer, because the pattern matches the command line of whatever is
    doing the asking. systemctl show answers the question that was asked.
    """
    try:
        result = subprocess.run(
            ["systemctl", "show", unit, "--no-pager",
             "-p", "LoadState", "-p", "ActiveState", "-p", "MainPID"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=3, universal_newlines=True, errors="replace")
        out = result.stdout or ""
    except (OSError, ValueError, subprocess.SubprocessError):
        return ("", "", "")
    got = {}
    for line in out.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            got[key.strip()] = value.strip()
    return (got.get("LoadState", ""), got.get("ActiveState", ""),
            got.get("MainPID", ""))


def firewall_line():
    """WHICH firewall is active, with its pid, not merely whether one is on.

    "Firewall: On" is true and useless: it names nothing, so it cannot be
    checked and it cannot be acted on. The NAMES are already in the snapshot
    under system.runtime.firewall.lines, collected by the same single call
    every other field reads, so naming them costs nothing. The PID is not in
    the snapshot and is read live from systemd, once per named firewall, which
    is a few milliseconds and needs no privileges.
    """
    state = onoff("health", "firewall")
    node = root.get("system", {})
    node = node.get("runtime", {}) if isinstance(node, dict) else {}
    node = node.get("firewall", {}) if isinstance(node, dict) else {}
    names = []
    if isinstance(node, dict) and isinstance(node.get("lines"), list):
        names = [str(x).strip() for x in node["lines"] if str(x).strip()]
    if not names:
        return "Firewall: " + state + "   Active: none named by the snapshot"
    parts = []
    for name in names:
        unit = FIREWALL_UNITS.get(name.lower())
        if not unit:
            parts.append(name + " (no systemd unit known for this name)")
            continue
        load, active, pid = unit_detail(unit)
        shown = active or "state unknown"
        if load in ("", "not-found"):
            parts.append(name + " (" + unit + " not installed)")
        elif name.lower() in FIREWALL_NO_DAEMON:
            parts.append(name + " (" + unit + " " + shown
                         + ", kernel netfilter, no daemon process)")
        elif pid and pid != "0":
            parts.append(name + " (" + unit + " " + shown + ", pid " + pid + ")")
        else:
            parts.append(name + " (" + unit + " " + shown
                         + ", no running process)")
    return "Firewall: " + state + "   Active: " + ", ".join(parts)


def vpn_tunnels():
    """The tunnel counts, in the vocabulary the panel itself uses: ON, UP, OFF.

    ON and UP are different questions and the snapshot answers both. Collapsing
    them lies: measured on <lab-host> while writing this, on_count was 1
    and up_count was 0, so reporting on_count as "up" printed a tunnel as up
    directly beside "Routing: Off". The named service is listed when the list is
    short enough to read, because "1 on" without a name cannot be acted on.
    """
    node = root.get("system", {})
    node = node.get("runtime", {}) if isinstance(node, dict) else {}
    node = node.get("vpn", {}) if isinstance(node, dict) else {}
    if not isinstance(node, dict):
        return UNKNOWN
    on, up, off = node.get("on_count"), node.get("up_count"), node.get("off_count")
    if on is None and up is None:
        return UNKNOWN
    text = "%s on, %s up, %s off" % (on, up, off)
    entries = node.get("entries")
    if isinstance(entries, list):
        named = [str(x.get("label", "")).strip() for x in entries
                 if isinstance(x, dict) and str(x.get("state", "")).lower() != "off"]
        named = [n for n in named if n]
        if named and len(named) <= 4:
            text += " (" + ", ".join(named) + ")"
    return text


def with_unit(value, unit):
    """Append a unit only to a real number. "unknown ms" reads as a measurement
    and is not one, so an unknown value stays the bare word."""
    return value + " " + unit if value and value != UNKNOWN else UNKNOWN


def local_time():
    return time.strftime("%Y-%m-%d %H:%M:%S")

FIELDS = {
    "ip":         lambda: "Public IP: " + public_ip()
                          + "   Egress source: " + dig("ip", "effective_source")
                          + "   City: " + dig("ip", "city"),
    "localip":    lambda: "Local IP: " + joined(
                      dig("system", "network", "local_ip"),
                      "iface " + dig("system", "network", "interface"),
                      "gw " + dig("system", "network", "gateway"))
                          + "   Ping: " + with_unit(
                              dig("system", "network", "ping_ms"), "ms"),
    "mac":        lambda: "MAC: " + fresher(
                              live_mac(dig("system", "network", "interface")),
                              dig("system", "network", "mac"))
                          + "   Interface: " + dig("system", "network", "interface")
                          + "   Local IP: " + dig("system", "network", "local_ip"),
    "hostname":   lambda: "Hostname: " + fresher(
                              live_hostname(), dig("system", "os", "hostname"))
                          + "   Kernel: " + dig("system", "os", "kernel")
                          + "   Mode: " + dig("system", "os", "mode")
                          + "   Up: " + dig("system", "uptime"),
    "timezone":   lambda: "Timezone: " + fresher(
                              live_timezone(), dig("system", "os", "timezone"))
                          + "   Local time: " + local_time()
                          + "   UTC offset: " + time.strftime("%z"),
    "remotetz":   lambda: "Timezone of my public IP: " + (REMOTE_TZ or UNKNOWN)
                          + "   Public IP: " + dig("ip", "public")
                          + "   Timezone of this machine: "
                          + fresher(live_timezone(), dig("system", "os", "timezone")),
    "session":    lambda: "Session ID: " + dig("auth", "session_id")
                          + "   Secure ID: " + dig("auth", "secure_id")
                          + "   Authenticated: " + dig("auth", "authenticated_human"),
    "login":      lambda: "Signed in: " + login_word()
                          + "   Group: " + dig("auth", "group")
                          + "   Blocked: " + dig("auth", "blocked_human")
                          + "   Authenticated: " + dig("auth", "authenticated_human"),
    "tor":        lambda: "Tor exit: " + tor_line()
                          + "   Daemon: " + dig("tor", "onoff")
                          + "   Instances: " + dig("tor", "instances_display")
                          + "   Backend: " + dig("tor", "backend")
                          + "   Up: " + dig("tor", "uptime"),
    "torrify":    lambda: "Torrify: " + torrify_line()
                          + "   Tor DNS: " + dig("tor", "tor_dns_onoff")
                          + "   Instances: " + dig("tor", "instances_display")
                          + "   Tor process age: "
                          + dig("system", "process_age", "tor", "value"),
    "vpn":        lambda: "Routing: " + onoff("routing", "connected")
                          + "   Protocol: " + dig("routing", "protocol")
                          + "   Server: " + dig("routing", "server")
                          + "   Up: " + dig("routing", "uptime")
                          + "   Tunnel device: " + dig("routing", "tun_device")
                          + "   Tunnels: " + vpn_tunnels(),
    "dns":        lambda: "DNS mode: " + dig("dns", "mode")
                          + "   Kodachi is the resolver: "
                          + onoff("dns", "configured_as_resolver")
                          + "   Servers: " + ", ".join(nameservers()),
    "dnsservers": lambda: "DNS servers: " + ", ".join(nameservers())
                          + "   Mode: " + dig("dns", "mode")
                          + "   Kodachi is the resolver: "
                          + onoff("dns", "configured_as_resolver"),
    "dnscrypt":   lambda: "DNSCrypt: " + onoff("dns", "dnscrypt_active")
                          + "   Service running: " + onoff("dns", "dnscrypt_service_up")
                          + "   Mode: " + dig("dns", "mode")
                          + "   Servers: " + ", ".join(nameservers()),
    "pihole":     lambda: "Pi-hole: " + onoff("dns", "pihole_active")
                          + "   DNS mode: " + dig("dns", "mode")
                          + "   Kodachi is the resolver: "
                          + onoff("dns", "configured_as_resolver"),
    "score":      lambda: "Security score: " + dig("health", "score_display")
                          + "/" + dig("health", "max_score")
                          + " (" + dig("health", "percentage_display") + "%)"
                          + "   Level: " + dig("health", "level")
                          + "   Hardening: " + dig("health", "hardening", "display")
                          + "   Firewall: " + onoff("health", "firewall")
                          + "   IPv6 disabled: " + onoff("health", "ipv6_disabled"),
    "internet":   lambda: "Internet: " + dig("health", "internet", "status")
                          + "   Connectivity: "
                          + dig("online_info", "online_status", "connectivity")
                          + "   Ping: " + with_unit(
                              dig("system", "network", "ping_ms"), "ms")
                          + "   Down: " + with_unit(
                              dig("system", "network", "traffic", "down_kib_s"), "KiB/s")
                          + "   Up: " + with_unit(
                              dig("system", "network", "traffic", "up_kib_s"), "KiB/s"),
    "firewall":   lambda: firewall_line(),
    "ipv6":       lambda: "IPv6 disabled: " + onoff("health", "ipv6_disabled")
                          + "   Measured rather than assumed: "
                          + dig("health", "ipv6_disabled_known")
                          + "   Interface: " + dig("system", "network", "interface"),
    "version":    lambda: "Kodachi: " + dig("system", "os", "local_version")
                          + "   Binaries: " + dig("health", "binary_version")
                          + "   Mode: " + dig("system", "os", "mode")
                          + "   Kernel: " + dig("system", "os", "kernel")
                          + "   Update status: " + dig("versions", "binary", "status"),
}

if MODE == "--list-fields":
    for name in sorted(FIELDS):
        print(name)
    sys.exit(0)

if MODE != "report":
    if MODE not in FIELDS:
        print("unknown field: " + MODE, file=sys.stderr)
        sys.exit(2)
    print(FIELDS[MODE]())
    sys.exit(0)

age = snapshot_age()

# Tagged output, rendered by kodachi-status-window in the Kodachi palette.
#
# CAREFUL: this whole python body is ONE single-quoted SHELL string, opened at
# the python3 -c line above and closed at the very bottom. A lone apostrophe
# anywhere in here, including inside a comment or a docstring, ends that string
# and bash starts parsing python as shell. Do not write a possessive. This
# comment itself caused the failure once, at the exact moment it was added to
# warn about it, which is why the file is bash -n checked before every deploy.
# The STATE on each row is what lets the window paint a protection that is ON in
# lime and one that is OFF in amber, so the window can be read at a glance rather
# than word by word.
PROTECTIVE_ON = {"On", "Yes", "Online", "Enabled", "Active"}
PROTECTIVE_OFF = {"Off", "No", "Offline", "Disabled", "Inactive"}


def state_of(value, invert=False):
    """ok when the value means "protected", warn when it means "not protected".
    `invert` is for the fields where Yes is the bad answer (Blocked)."""
    text = str(value).strip()
    if text in ("", UNKNOWN, "unknown", "not checked", "-"):
        return "warn"
    if text in PROTECTIVE_ON:
        return "bad" if invert else "ok"
    if text in PROTECTIVE_OFF:
        return "ok" if invert else "warn"
    return "neutral"


def section(title):
    print("#SECTION\t%s" % title)


def row(label, value, state=None):
    value = str(value)
    print("#ROW\t%s\t%s\t%s" % (label, value, state or state_of(value)))


print("#TITLE\tKODACHI SESSION STATUS")
# NAME THE PATH, NOT JUST THE CLOCK. "taken 3s ago" and "taken 2s ago" are the
# same sentence to a reader; "every value re-read just now" and "reused a cached
# snapshot" are different facts, and they are the actual difference between the
# two dock rows that produce this report.
if os.environ.get("STATUS_WAS_REFRESHED") == "1":
    print("#AGE\tfresh data, every value re-read just now")
elif age:
    print("#AGE\tcached snapshot, taken %s (use Fresh Data to re-read)" % age)
else:
    print("#AGE\tlive snapshot")

section("IDENTITY")
row("Session ID", dig("auth", "session_id"), "neutral")
row("Secure ID", dig("auth", "secure_id"), "neutral")
row("Signed in", login_word())
row("Account group", dig("auth", "group"), "neutral")
row("Blocked", dig("auth", "blocked_human"), state_of(dig("auth", "blocked_human"), invert=True))

section("MACHINE")
row("Hostname", fresher(live_hostname(), dig("system", "os", "hostname")), "neutral")
row("MAC address",
    fresher(live_mac(dig("system", "network", "interface")),
            dig("system", "network", "mac")), "neutral")
row("Local IP", dig("system", "network", "local_ip"), "neutral")
row("Interface", dig("system", "network", "interface"), "neutral")
row("Gateway", dig("system", "network", "gateway"), "neutral")
row("Timezone", fresher(live_timezone(), dig("system", "os", "timezone")), "neutral")
row("Timezone of my IP", REMOTE_TZ or "not checked")
row("Kernel", dig("system", "os", "kernel"), "neutral")
row("Kodachi version", dig("system", "os", "local_version")
    + "   binaries " + dig("health", "binary_version"), "neutral")

section("NETWORK IDENTITY")
row("Public IP", public_ip(), "neutral")
row("Effective egress", dig("ip", "effective_source"), "neutral")
row("Internet", dig("health", "internet", "status"))
row("Connectivity", dig("online_info", "online_status", "connectivity"), "neutral")
row("Ping", dig("system", "network", "ping_ms") + " ms", "neutral")

section("ROUTING")
row("VPN connected", onoff("routing", "connected"))
row("Protocol", dig("routing", "protocol"), "neutral")
row("Server", dig("routing", "server"), "neutral")
row("Tunnel device", dig("routing", "tun_device"), "neutral")
row("Uptime", dig("routing", "uptime"), "neutral")

section("TOR")
_torrify = torrify_line()
row("Torrify", _torrify, "ok" if _torrify.startswith("On") else "warn")
row("Tor exit", tor_line(), "neutral")
row("Tor process age", dig("system", "process_age", "tor", "value"), "neutral")

section("DNS")
row("Mode", dig("dns", "mode"), "neutral")
row("DNSCrypt", onoff("dns", "dnscrypt_active"))
row("DNSCrypt service", onoff("dns", "dnscrypt_service_up"))
row("Kodachi is resolver", onoff("dns", "configured_as_resolver"))
row("Pi-hole", onoff("dns", "pihole_active"), "neutral")
for index, server in enumerate(nameservers(), start=1):
    row("DNS server %d" % index, server, "neutral")

section("PROTECTION")
row("Security score", dig("health", "score_display") + " / " + dig("health", "max_score")
    + "   (" + dig("health", "percentage_display") + "%)", "neutral")
row("Level", dig("health", "level"), "neutral")
row("Hardening applied", dig("health", "hardening", "display"), "neutral")
row("Firewall", firewall_line().split("Firewall: ")[1], state_of(onoff("health", "firewall")))
row("IPv6 disabled", onoff("health", "ipv6_disabled"))
row("USBGuard", dig("system", "services", "usbguard"))
row("USBKill", dig("system", "services", "usbkill"))
