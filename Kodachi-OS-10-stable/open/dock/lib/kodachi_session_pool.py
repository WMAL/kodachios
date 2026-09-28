#!/usr/bin/env python3
# Kodachi Session Status - Tor instance pool renderer
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
# Renders `tor-switch list-instances-with-ip --json` (on stdin) in two shapes.
# argv[1] picks which:
#
#   rows   tagged #SECTION and #ROW lines for kodachi-status-window
#   line   one compact line for a notification
#
# Deliberately NOT part of the snapshot: the pool is tor-switch state, and it
# is the one thing about Tor that cannot be inferred from the exit IP. Each
# instance carries its own country, so the pool reads as a row of flags.
#
# Extracted from kodachi-dock-status for the reason spelled out at the top of
# kodachi_session_report.py: the GTK command window may not execute that
# script, so the renderer had to become something both callers can import.
#
# Author: Warith Al Maawali
# Version: <lab-host>
# Last updated: 2026-09-04

import json
import os
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else "line"

# THIS FILE IS A SCRIPT, NOT AN IMPORTABLE MODULE, AND IT SAYS SO BEFORE IT
# TOUCHES STDIN. It sits in /usr/local/lib/kodachi beside five genuinely
# importable kodachi_*.py modules and shares their naming convention, so a
# future `import kodachi_session_pool` is a plausible mistake, and without this
# guard it would BLOCK FOREVER on json.load(sys.stdin) with no error and no
# traceback. Raised by the inspector.
#
# The body below is the renderer lifted VERBATIM out of kodachi-dock-status, so
# it is deliberately not indented into a __main__ block: re-indenting 570 lines
# to express "this is the entry point" would trade a real property, that the
# two callers provably run identical code, for a stylistic one.
if __name__ != "__main__":
    raise ImportError(
        "kodachi_session_pool is a command-line renderer, not a module. "
        "Run it as: python3 <path> <mode>")

try:
    doc = json.load(sys.stdin)
except (ValueError, OSError):
    sys.exit(1)

data = doc.get("data") if isinstance(doc, dict) else None
if not isinstance(data, dict):
    sys.exit(1)

instances = data.get("instances")
if not isinstance(instances, list):
    sys.exit(1)


def field(entry, *names, default=""):
    for name in names:
        value = entry.get(name)
        if value not in (None, ""):
            return str(value).strip()
    return default


# ── COUNTRY WITHOUT A NETWORK CALL, AND WITHOUT AUTHENTICATION ────────────
#
# Operator, 2026-09-04, after the first pass only EXPLAINED the gap: "no flags
# all no [expletive] countrynames". Explaining is not showing, and he is right.
#
# WHY THE FIELD IS EMPTY. tor-switch fills country/country_code/flag from
# ip_fetch_adapter::fetch_bulk_geolocation, and ip-fetch fetch_bulk
# (ip-fetch/src/lib.rs:161-165) REFUSES to run when no Kodachi session is
# signed in. Measured in /opt/kodachi/dashboard/hooks/logs at the minute he
# clicked: "ip-fetch: Authentication failed - user not authenticated", then
# "tor-switch: Failed to fetch geolocation data". So every instance came back
# with country null, on a machine whose pool was perfectly healthy.
#
# THE ANSWER IS ALREADY ON THE DISK. Tor ships its own geoip database, an
# IPv4 range table at /usr/share/tor/geoip (9.0M, 385,622 rows,
# "start_int,end_int,CC"), because the Tor daemon needs it to honour
# ExitNodes. It needs no network, no API key and no session. Measured here on
# the operator's own eight exit IPs: 5 of 5 sampled resolved in 0.76s
# (192.42.116.14 NL, 109.70.100.15 AT, 23.129.64.208 US, 204.8.96.75 US,
# 193.189.100.198 SE).
#
# THE BINARY STAYS THE SOURCE OF TRUTH. This runs ONLY for instances tor-switch
# left empty, so a signed-in session still shows the API answer and this never
# overrides it. That matters because the two can legitimately disagree: the API
# is live and the shipped table is as old as the tor package.
#
# ONE STREAMING PASS, EARLY EXIT. The file is 9MB and loading it whole to
# answer eight questions would be the wrong trade for a click. The pass stops
# as soon as every wanted IP is placed.
TOR_GEOIP = os.environ.get("KODACHI_TOR_GEOIP", "/usr/share/tor/geoip")


def _ipv4_int(text):
    parts = text.strip().split(".")
    if len(parts) != 4:
        return None
    value = 0
    for part in parts:
        if not part.isdigit():
            return None
        octet = int(part)
        if octet > 255:
            return None
        value = value * 256 + octet
    return value


def offline_countries(ips):
    """{ip: country code} from Tor own shipped table. Never raises."""
    want = {}
    for ip in ips:
        number = _ipv4_int(ip)
        if number is not None:
            want[number] = ip
    found = {}
    if not want:
        return found
    try:
        with open(TOR_GEOIP, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line or line[0] == "#":
                    continue
                fields = line.rstrip("\n").split(",", 2)
                if len(fields) != 3:
                    continue
                try:
                    low, high = int(fields[0]), int(fields[1])
                except ValueError:
                    continue
                for number in [n for n in want if low <= n <= high]:
                    code = fields[2].strip().upper()
                    # "??" is the table saying it does not know, which is an
                    # answer and must not be dressed up as a country.
                    if code and code != "??":
                        found[want[number]] = code
                    del want[number]
                if not want:
                    break
    except OSError:
        return found
    return found


def flag_for(code):
    """The regional-indicator pair for a two-letter code, computed not tabled."""
    if len(code) != 2 or not code.isalpha():
        return ""
    return "".join(chr(0x1F1E6 + ord(ch) - ord("A")) for ch in code.upper())


def name_for(code):
    """The country name, from the cache the Tor pickers already ship.

    kodachi_countries.NAME covers the 76 countries with Tor exit capacity,
    which is exactly the population an exit IP can land in. A code outside it
    is shown AS the code rather than as nothing, because two letters is still
    an answer and "unknown" is not.
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import kodachi_countries
        return kodachi_countries.NAME.get(code.upper(), code.upper())
    except Exception:
        return code.upper()


RUNNING = ("RUNNING", "ACTIVE", "UP")
running = [e for e in instances if field(e, "instance_status").upper() in RUNNING]

# WHY A COUNTRY IS MISSING IS PART OF THE ANSWER, AND "unknown country" WAS NOT
# AN ANSWER. Measured on the operator machine 2026-09-04, at the minute he
# clicked, in /opt/kodachi/dashboard/hooks/logs:
#
#   ip-fetch:   Authentication failed - user not authenticated
#   tor-switch: Failed to fetch geolocation data
#
# ip-fetch fetch_bulk (lib.rs:161-165) refuses to run when no Kodachi session is
# signed in, so get_geolocation_data returns an EMPTY map and tor-switch writes
# country, country_code and flag as null for EVERY instance. The row then read
# "unknown country" eight times, which reads as "Tor does not know where its
# exits are" and is nothing of the kind: the pool is healthy, the lookup was
# refused.
#
# So the two causes are separated. A SINGLE instance with no country is the
# ordinary case the marks section below already describes: it is stopped, or it
# is up and has not resolved its exit yet. EVERY instance missing one at once is
# the geolocation lookup itself, and that gets said in its own row rather than
# smeared across every instance as if each one had failed on its own.
# FILL WHAT THE BINARY COULD NOT, BEFORE ANY ROW IS BUILT, so both the rows
# mode and the compact line mode below get the same answer.
_missing = [field(e, "tor_ip", "ip") for e in instances
            if not (field(e, "country") or field(e, "flag"))]
_missing = [ip for ip in _missing if ip]
if _missing:
    _offline = offline_countries(_missing)
    for entry in instances:
        if field(entry, "country") or field(entry, "flag"):
            continue
        code = _offline.get(field(entry, "tor_ip", "ip"))
        if not code:
            continue
        entry["country_code"] = code
        entry["country"] = name_for(code)
        entry["flag"] = flag_for(code)

resolved = [e for e in instances if field(e, "country") or field(e, "flag")]
geo_refused = bool(instances) and not resolved

# ── THE VALUE IS THREE COLUMNS, AND THEY MUST LINE UP ──────────────────────
# The operator, 2026-09-04, looking at eight instances: "looks ugly improve it".
# The old value was three facts joined with three spaces, so every row started
# its IP at a different column and the eye had nothing to run down. The window
# draws this in a monospace face and scrolls sideways rather than wrapping
# (kodachi-status-window report_row), so fixed columns are both possible and
# the whole point.
#
# WIDTH IS COUNTED IN CELLS, NOT CHARACTERS. A regional-indicator flag is ONE
# code point pair that a terminal-style monospace face draws TWO cells wide, so
# padding by len() puts every flagged row one cell out and only the flagged ones
# move. Counted explicitly instead.
COUNTRY_CELLS = 22
IP_CELLS = 15


def cell_width(text):
    """Display cells, counting a regional-indicator flag as two."""
    return sum(2 if 0x1F1E6 <= ord(ch) <= 0x1F1FF else 1 for ch in text)


def pad(text, cells):
    missing = cells - cell_width(text)
    return text + (" " * missing if missing > 0 else "")


def pool_value(entry, status):
    """One instance as country, IP, state, in fixed columns.

    THE STATUS WORD STAYS EVEN THOUGH THE ROW ALSO CARRIES A PILL. The pill says
    OK or BAD, which is a judgement; RUNNING and STOPPED are the machine state,
    and a reader scanning a pool wants the state. They are not duplicates of
    each other.

    A MISSING COUNTRY IS A DASH WHEN THE LOOKUP ITSELF WAS REFUSED, because the
    reason is already stated once in its own row above and repeating it eight
    times is how a table becomes unreadable. When the lookup DID run and this
    one instance simply has no exit yet, that is a fact about this instance and
    it is said on this instance.
    """
    country = " ".join(y for y in (field(entry, "flag"), field(entry, "country")) if y)
    if not country:
        country = "-" if geo_refused else "resolving exit"
    return "%s %s %s" % (pad(country, COUNTRY_CELLS),
                         pad(field(entry, "tor_ip", "ip", default="-"), IP_CELLS),
                         status)


if MODE == "rows":
    print("#SECTION\tTOR INSTANCE POOL")
    print("#ROW\tInstances running\t%d of %d\t%s"
          % (len(running), len(instances), "ok" if running else "warn"))
    if geo_refused:
        print("#ROW\tCountry lookup\tno country resolved, the live lookup needs a "
              "signed-in session and the shipped Tor table did not place these "
              "addresses\twarn")
    for entry in instances:
        status = field(entry, "instance_status", default="unknown").upper()
        tag = field(entry, "tag", "name", "instance", default="instance")
        short = tag.rsplit("_", 1)[-1] if tag.startswith("kodachi_tor_inst") else tag
        label = "Instance %s%s" % (short, " (default)" if entry.get("is_default") else "")
        print("#ROW\t%s\t%s\t%s" % (label, pool_value(entry, status),
                                     "ok" if status in RUNNING else "bad"))
    sys.exit(0)

# ONE MARK PER INSTANCE, ALWAYS. An instance whose exit country is not known
# yet has flag=None and country_code=None, and the old code appended an EMPTY
# string for it. The mark was still joined, so the line read
#     Tor pool: 3 of 4 running   * MM  MM
# with a stray default-marker and double spaces: the count said 4 and the eye
# counted 2. Reported by the operator as "instances show 5 but only 3 flags".
#
# A flag is missing for a REASON (the instance is stopped, or it is up but has
# not built a circuit and resolved its exit yet), and that reason is worth
# showing rather than hiding. So an unknown exit gets a placeholder and the
# marks can never silently disagree with the count.
STOPPED_MARK = "\u00b7"   # middle dot: instance exists, not running
UNKNOWN_MARK = "?"        # running, exit country not resolved yet
marks = []
for entry in instances:
    mark = field(entry, "flag") or field(entry, "country_code").upper()
    if not mark:
        is_running = field(entry, "instance_status").upper() in RUNNING
        mark = UNKNOWN_MARK if is_running else STOPPED_MARK
    if entry.get("is_default"):
        mark += "*"
    marks.append(mark)
print("Tor pool: %d of %d running   %s"
      % (len(running), len(instances), " ".join(marks)))
