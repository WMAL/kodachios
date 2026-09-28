#!/usr/bin/env python3
# Kodachi Command Windows - Tor Country Tables
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
# The country groups the Tor pickers offer, MIRRORED from tor-switch's own
# get_country_groups() in dashboard/hooks/rust/tor-switch/src/tor.rs. The binary
# is the source of truth; this file is a cache of it so the window does not have
# to shell out before it can draw its first row.
#
# Run `kodachi_countries.py --verify` to compare this cache against that Rust
# function and report DRIFTED for any group that no longer matches. A window
# that offers a country the binary would reject is worse than a window that
# offers fewer, so the check exists and is cheap.

# mirrored 2026-08-18 from get_country_groups() in tor-switch/src/tor.rs
import os

GROUPS = {
    "5eyes": ["US", "GB", "CA", "AU", "NZ"],
    "9eyes": ["US", "GB", "CA", "AU", "NZ", "DK", "FR", "NL", "NO"],
    "14eyes": ["US", "GB", "CA", "AU", "NZ", "DK", "FR", "NL", "NO", "DE",
               "BE", "IT", "ES", "SE"],
    "adversarial": ["CN", "RU", "IR", "KP", "BY"],
    "europe": ["AT", "BE", "BG", "CH", "CZ", "DE", "DK", "EE", "ES", "FI",
               "FR", "GB", "GR", "HR", "HU", "IE", "IS", "IT", "LT", "LU",
               "LV", "MD", "NL", "NO", "PL", "PT", "RO", "RS", "SE", "SI",
               "SK", "UA", "BY", "RU"],
    "asia": ["HK", "ID", "IN", "JP", "KR", "MY", "PH", "SG", "TH", "TW",
               "VN", "CN", "KP"],
    "africa": ["EG", "KE", "MA", "NG", "SC", "TN", "ZA"],
    "north-america": ["CA", "MX", "US"],
    "south-america": ["AR", "BR", "CL", "CO", "PE", "UY", "VE"],
    "oceania": ["AU", "NZ"],
    "middle-east": ["OM", "AE", "IR", "LB", "QA", "SA", "TR", "IL"],
    "high-volume": ["AL", "AT", "BE", "BG", "BR", "BZ", "CH", "CZ", "FI",
                    "HU", "IS", "JP", "KR", "LU", "MD", "PL", "RO", "RU",
                    "SC", "SG", "TH", "TR", "UA", "ZA"],
}

# all-world is the union of every group EXCEPT the eyes sets, which is exactly
# how the binary computes it. This tuple must stay identical to the filter in
# get_country_groups(); if the two ever disagree the window will offer a country
# the router rejects, or hide one it accepts.
_NOT_IN_ALL_WORLD = ("5eyes", "9eyes", "14eyes")

# Mirrors `const NO_EXIT_CAPACITY` in tor.rs. These three are ordinary members
# of their continents, so they can be pinned and excluded one by one, but they
# are held out of the all-world UNION because that union is what feeds
# low-volume and the three random selectors, and every one of those PINS an
# exit with StrictNodes 1. Pinning a country that runs no exit relay leaves Tor
# unable to build a circuit at all.
NO_EXIT_CAPACITY = ("CN", "KP", "BY")

GROUPS["all-world"] = sorted({
    c for g, m in GROUPS.items() if g not in _NOT_IN_ALL_WORLD
    for c in m if c not in NO_EXIT_CAPACITY})

# China, Russia, Iran, North Korea and Belarus are ORDINARY members of asia,
# europe and middle-east, so they can be pinned or excluded individually exactly
# like Italy or India. `adversarial` is only a convenience preset over them, and
# every one of its members reaches all-world through its own region.
#
# The two names below are therefore the same list today. They stay separate
# because the operations genuinely differ: ExitNodes only makes sense where exits
# exist, while ExcludeNodes takes any code and also governs guard and middle
# positions. If a future group adds a country with no exits, EXCLUDABLE is where
# it belongs and ALL is where it does not.
# ALL is what the PICKERS offer, and it is deliberately WIDER than all-world.
# `set-exit-node-main cn` works through tor-switch's two-letter path, which
# never consults the all-world union, so a country being held out of the
# automated selectors is no reason to hide it from someone choosing by hand.
ALL = sorted(set(GROUPS["all-world"]) | set(NO_EXIT_CAPACITY))
EXCLUDABLE = sorted(set(ALL) | set(GROUPS["adversarial"]))

NAME = {
    "AE": "United Arab Emirates", "AL": "Albania", "AR": "Argentina",
    "AT": "Austria", "AU": "Australia", "BE": "Belgium", "BG": "Bulgaria",
    "BR": "Brazil", "BY": "Belarus", "BZ": "Belize", "CA": "Canada",
    "CH": "Switzerland", "CL": "Chile", "CN": "China", "CO": "Colombia",
    "CZ": "Czechia", "DE": "Germany", "DK": "Denmark", "EE": "Estonia",
    "EG": "Egypt", "ES": "Spain", "FI": "Finland", "FR": "France",
    "GB": "United Kingdom", "GR": "Greece", "HK": "Hong Kong", "HR": "Croatia",
    "HU": "Hungary", "ID": "Indonesia", "IE": "Ireland", "IL": "Israel",
    "IN": "India", "IR": "Iran", "IS": "Iceland", "IT": "Italy", "JP": "Japan",
    "KE": "Kenya", "KP": "North Korea", "KR": "South Korea", "LB": "Lebanon",
    "LT": "Lithuania", "LU": "Luxembourg", "LV": "Latvia", "MA": "Morocco",
    "MD": "Moldova", "MX": "Mexico", "MY": "Malaysia", "NG": "Nigeria",
    "NL": "Netherlands", "NO": "Norway", "NZ": "New Zealand", "OM": "Oman",
    "PE": "Peru", "PH": "Philippines", "PL": "Poland", "PT": "Portugal",
    "QA": "Qatar", "RO": "Romania", "RS": "Serbia", "RU": "Russia",
    "SA": "Saudi Arabia", "SC": "Seychelles", "SE": "Sweden", "SG": "Singapore",
    "SI": "Slovenia", "SK": "Slovakia", "TH": "Thailand", "TN": "Tunisia",
    "TR": "Turkey", "TW": "Taiwan", "UA": "Ukraine", "US": "United States",
    "UY": "Uruguay", "VE": "Venezuela", "VN": "Vietnam", "ZA": "South Africa",
}

REGION_ORDER = ["europe", "north-america", "south-america", "asia",
                "middle-east", "africa", "oceania"]
REGION_LABEL = {
    "europe": "Europe", "north-america": "North America",
    "south-america": "South America", "asia": "Asia",
    "middle-east": "Middle East", "africa": "Africa", "oceania": "Oceania",
}


def by_region(universe=None):
    """Group a country universe into regions, in REGION_ORDER, without repeats.

    A country can sit in several groups, high-volume overlaps every region, so
    membership is resolved in REGION_ORDER and whatever is left over lands in a
    final bucket rather than being dropped. `universe` defaults to the
    exit-capable list; the exclude window passes the wider EXCLUDABLE set so a
    country with no exits still gets a row.
    """
    universe = set(universe or ALL)
    placed, out = set(), []
    for group in REGION_ORDER:
        members = [c for c in sorted(GROUPS[group]) if c in universe and c not in placed]
        placed |= set(members)
        if members:
            out.append((REGION_LABEL[group], members))
    rest = sorted(c for c in universe if c not in placed)
    if rest:
        out.append(("Other", rest))
    return out


# Aliases the exit picker offers. `adversarial` is absent on purpose: it is
# exclude-only, and tor-switch's exit dispatch REFUSES it with a named error.
# That refusal is an explicit match arm, not a fallthrough: the catch-all under
# it writes any non-two-letter spec into torrc verbatim, so leaving the alias
# out would have produced the unparseable line `ExitNodes adversarial` instead
# of an error.
ALIASES = [
    ("all-world", "Every country the network reaches"),
    ("high-volume", "Countries with the most relays, fastest"),
    ("low-volume", "Rare exits, computed live by the router"),
    ("europe", "Anywhere in Europe"),
    ("asia", "Anywhere in Asia"),
    ("north-america", "Anywhere in North America"),
    ("south-america", "Anywhere in South America"),
    ("africa", "Anywhere in Africa"),
    ("oceania", "Anywhere in Oceania"),
    ("middle-east", "Anywhere in the Middle East"),
]

# Presets the exclude picker offers as one-tap group switches.
EXCLUDE_PRESETS = [
    ("5eyes", "5 Eyes", "UKUSA core"),
    ("9eyes", "9 Eyes", "5 Eyes and four more"),
    ("14eyes", "14 Eyes", "SIGINT Seniors Europe"),
    ("adversarial", "Adversarial states", "China, Russia, Iran, North Korea, Belarus"),
]

# DEVELOPMENT ONLY, and deliberately not a path. This module ships on the ISO,
# where no Rust source exists and a checkout path would be a dead constant
# pointing at somebody's home directory. The source is named at run time,
# through KODACHI_TOR_RS or the --verify argument.
TOR_RS_ENV = "KODACHI_TOR_RS"


def verify(path=None):
    """Compare this cache against the Rust function it mirrors."""
    path = path or os.environ.get(TOR_RS_ENV)
    if not path:
        return [("<source>", f"NO SOURCE GIVEN, set {TOR_RS_ENV} or pass a path "
                             "to tor-switch/src/tor.rs")]
    import re

    # Same discipline as every other text read in this payload: a source file
    # from another tree is a third-party byte stream to this one.
    src = open(path, encoding="utf-8", errors="replace").read()
    seg = src[src.index("pub async fn get_country_groups"):][:60000]
    found = {n: re.findall(r'"([A-Z]{2})"', b) for n, b in re.findall(
        r'groups\.insert\(\s*"([a-z0-9\-]+)"\.to_string\(\),\s*vec!\[(.*?)\],\s*\);',
        seg, re.S)}

    # 9eyes and 14eyes are built by cloning the previous group and extending
    # it, so the literal groups.insert parser above cannot see either one.
    nine = re.search(r'nine_eyes\.extend\(vec!\[(.*?)\]\);', seg, re.S)
    fourteen = re.search(r'fourteen_eyes\.extend\(vec!\[(.*?)\]\);', seg, re.S)
    if "5eyes" in found and nine:
        found["9eyes"] = found["5eyes"] + re.findall(
            r'"([A-Z]{2})"', nine.group(1))
    if "9eyes" in found and fourteen:
        found["14eyes"] = found["9eyes"] + re.findall(
            r'"([A-Z]{2})"', fourteen.group(1))
    if not found:
        return [("<parse>", "COULD NOT READ THE RUST GROUPS, check the path")]
    rows = []
    for group, members in sorted(found.items()):
        rows.append((group, "MATCHES" if GROUPS.get(group) == members
                     else f"DRIFTED, rust has {len(members)}, this file has "
                          f"{len(GROUPS.get(group, []))}"))
    for group in sorted(set(GROUPS) - set(found) - {"all-world"}):
        rows.append((group, "NOT IN THE RUST SOURCE, remove it or add it there"))

    # THE DERIVED GROUPS, which the loop above cannot see because the Rust side
    # never writes them with groups.insert(). all-world is a union computed at
    # the end of get_country_groups, and low-volume is computed from all-world
    # at call time, so both can drift from this file while every literal group
    # still reports MATCHES. That is exactly how three countries reached the
    # random exit selectors unnoticed.
    holdout = re.search(r"const NO_EXIT_CAPACITY:[^=]*=\s*\[(.*?)\];", src, re.S)
    rust_holdout = tuple(re.findall(r'"([A-Z]{2})"', holdout.group(1))) if holdout else ()
    rows.append(("NO_EXIT_CAPACITY",
                 "MATCHES" if set(rust_holdout) == set(NO_EXIT_CAPACITY)
                 else f"DRIFTED, rust holds out {sorted(rust_holdout)}, "
                      f"this file holds out {sorted(NO_EXIT_CAPACITY)}"))

    rust_all_world = sorted({
        c for g, m in found.items() if g not in _NOT_IN_ALL_WORLD
        for c in m if c not in rust_holdout})
    rows.append(("all-world",
                 "MATCHES" if rust_all_world == GROUPS["all-world"]
                 else f"DRIFTED, rust derives {len(rust_all_world)}, this file "
                      f"has {len(GROUPS['all-world'])}, difference "
                      f"{sorted(set(rust_all_world) ^ set(GROUPS['all-world']))}"))

    # low-volume = all_world - high_volume - 14eyes (tor.rs get_low_volume_countries)
    rust_low = sorted(set(rust_all_world) - set(found.get("high-volume", []))
                      - set(found.get("14eyes", [])))
    leaked = sorted(set(NO_EXIT_CAPACITY) & set(rust_low))
    rows.append(("low-volume", f"MATCHES, {len(rust_low)} countries derived, no "
                               "held-out country reached the random selectors"
                 if not leaked else
                 f"DRIFTED, held-out countries reached low-volume: {leaked}"))
    return rows


if __name__ == "__main__":
    import sys

    if "--verify" in sys.argv:
        bad = 0
        for group, verdict in verify():
            print(f"{group:<16} {verdict}")
            bad += not verdict.startswith("MATCHES")
        sys.exit(1 if bad else 0)
    print(f"exit-capable {len(ALL)}   excludable {len(EXCLUDABLE)}   groups {len(GROUPS)}")
    for label, members in by_region(EXCLUDABLE):
        print(f"  {label:<26} {len(members)}")
