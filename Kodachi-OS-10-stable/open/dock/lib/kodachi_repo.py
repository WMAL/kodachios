#!/usr/bin/env python3
# Kodachi Repository Manager - data layer
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
# Everything the repository window knows about packages, with NO GTK import, so
# it can be tested without a display and without running apt.
#
# The three things this module refuses to invent, because the window shows them
# to a user deciding whether to install something:
#
#   - a VERSION it did not read out of an apt index;
#   - a HASH it did not read out of an apt index;
#   - a DATE it did not read out of a Release file or an HTTP Last-Modified.
#
# Anything it cannot read comes back as None and the window says so in words.
# The curated benefit/use copy IS ours and is marked as such by living in one
# table down the bottom, keyed by package name, never merged into the index
# fields.

import json
import os
import re
import stat
import subprocess
import time
from urllib.parse import urlsplit

CHANNELS = {
    "stable": {
        "label": "Stable",
        "url": "https://kodachi.cloud/repo",
        "suite": "stable",
        "auth": "public",
        "list_key": "kodachi.cloud_repo",
    },
    "beta": {
        "label": "Beta",
        "url": "https://kodachi.cloud/repo-beta",
        "suite": "beta",
        "auth": "public opt-in",
        "list_key": "kodachi.cloud_repo-beta",
    },
    "dev": {
        "label": "Dev",
        "url": "https://kodachi.cloud/repo-dev",
        "suite": "dev",
        "auth": "HTTP basic auth",
        "list_key": "kodachi.cloud_repo-dev",
    },
}

# The file apt itself reads for the dev channel's Basic-Auth credential, and
# the only on-disk evidence an unprivileged process has that this machine is
# entitled to that channel. It lives HERE rather than in the window because
# `catalog()` now gates the dev listing on it, so the data layer and the
# presentation layer must agree about the path; the window imports this one
# rather than keeping a second copy that could drift.
DEV_AUTH_FILE = "/etc/apt/auth.conf.d/kodachi-dev.conf"

COMPONENTS = ("main", "thirdparty", "apps")

# The repo signing key, published in the playbook and pinned by setup.sh. Shown
# so a user can compare it against an out-of-band copy, and compared by the
# window's `installed_repository_key()` against the key actually installed at
# /usr/share/keyrings/kodachi-archive-keyring.gpg, which is the one apt honours.
# Nothing in THIS module decides anything with it: by the time these indexes
# exist on disk apt has already done the verifying, so the comparison is a
# report about the machine and never a gate.
REPO_FINGERPRINT = "17D7C4B0 2273 0515 B3FC D94D 38CB C528 166E AF7B"

DEFAULT_LISTS_DIR = "/var/lib/apt/lists"
APT_MARK = "/usr/bin/apt-mark"


def lists_dir():
    """Where apt keeps the downloaded indexes.

    Overridable so the test suite can point at a fixture directory. It is NOT a
    way to feed the window invented data at runtime: the shipped launcher never
    sets it, and the window prints the directory it read in its footer.
    """
    return os.environ.get("KODACHI_REPO_LISTS_DIR") or DEFAULT_LISTS_DIR


def apt_lists_present(directory=None):
    """True when apt holds at least one downloaded binary package index.

    WHY THIS EXISTS. `apt-cache policy` answers out of the indexes in
    lists_dir(). With no indexes it still exits 0 and still prints stanzas for
    the handful of names dpkg knows, so the caller sees a well-formed answer
    that says every package is unofferable. `favourite_rows()` then returns
    `unavailable` for the whole catalog, and the page tells the user the package
    name may be wrong or the archive area may be disabled. BOTH of those are
    false, and the true cause, that apt has never fetched its lists, is the one
    thing the message does not say.

    MEASURED 2026-09-10, operator-reported. A user was told to install GIMP and
    got "not offered by apt" on all 8 Debian applications. On the installed VM
    <lab-host> with populated lists the same code reports 7 available and 1
    genuinely unavailable (nautilus-dropbox, whose contrib area is not enabled).
    Re-run with `apt-cache -o Dir::State::Lists=<empty dir>`, the reproduction of
    a fresh live boot, it reports 8 of 8 unavailable, which is exactly the
    screenshot.

    This is a real state a user is in, not an edge case: a live ISO ships with no
    indexes to save space, and a freshly installed system has none until the
    first `apt update`.

    Absence of the directory counts as absent rather than raising, because the
    caller uses this only to choose which sentence to show, and a page that
    cannot render is worse than a page that recommends a refresh.
    """
    where = directory or lists_dir()
    try:
        names = os.listdir(where)
    except OSError:
        return False
    # WHY THIS USES A SUBSTRING WHERE index_files() USES endswith(), which is a
    # real disagreement inside one module and has to be justified rather than
    # left for the next reader to trip over.
    #
    # apt writes `<host>_<path>_dists_<suite>_<component>_binary-<arch>_Packages`,
    # but under `Acquire::GzipIndexes "true"` it keeps them compressed and the
    # name gains an extension, `..._Packages.lz4`. On such a machine apt is
    # perfectly healthy and `endswith("_Packages")` finds nothing, which here
    # would mean telling a user to refresh lists they already have. The two
    # functions want different things and so use different tests:
    #
    #   index_files()       needs a path it can OPEN and parse (:491), so a
    #                       compressed name is useless to it and the strict
    #                       suffix is correct there.
    #   apt_lists_present() needs only to know whether apt has ANY data, so the
    #                       tolerant form is correct here and fails safe.
    #
    # Measured 2026-09-10, both machines: `Acquire::GzipIndexes` is unset, so
    # the two predicates agree exactly today (dev host 12 and 12, VM 11 and 11,
    # zero names differing). The distinction matters only on a machine that
    # turns it on, and on that machine this is the one that stays correct.
    return any("_Packages" in name for name in names)


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache")
    return os.path.join(base, "kodachi", "repo-manager")


# ----------------------------------------------------------------------------
# apt index parsing
# ----------------------------------------------------------------------------

# APT SPLITS A FILE ON \n AND ON NOTHING ELSE. Python's str.splitlines() also
# breaks on \r, \v, \f, \x1c, \x1d, \x1e, \x85, U+2028 and U+2029, so the two
# disagree about what a LINE is, and every disagreement is a place where this
# window shows the operator something apt is not reading.
#
# Raised by <agent>, 2026-08-21, and demonstrated by execution rather
# than by reading: a .sources file whose URIs value contains a form feed,
# `URIs: https://x/debian\x0cSigned-By: /dev/null`, parsed HERE as two fields
# and parses in APT as one malformed URI line. The window would have shown a
# signing key the system does not use, on a repository whose real URI it was
# not showing.
#
# The same shape in the pkexec helper is worse than a display bug, because
# _toggle_deb822() splits, edits and REJOINS with "\n", which turns that form
# feed into a real line break in the file on disk: enabling one repository
# would rewrite the file into a shape its author never wrote. The helper
# carries its own copy of this function for that reason, and a contract in
# tests/test_repo_manager.py asserts neither file parses apt data any other
# way, in BOTH files, so the duplicate cannot drift into one guard and one hole.
#
# A trailing \r is deliberately left on the line. Every caller here already
# ends in .strip() or .rstrip(), which removes it, and that matches apt
# trimming trailing whitespace from a field value. Stripping it in this
# function would be the one edit that could still INVENT a difference.
def apt_lines(text):
    """`text` split into lines the way apt splits it: on \n, and only on \n."""
    lines = (text or "").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


# THE deb822 FIELDS apt ACTUALLY DEFINES for a source. This governs exactly one
# decision, and a narrow one: whether a COMMENTED-OUT block is a disabled
# repository or is prose that merely looks like one. A live stanza is never
# filtered by it, so a field missing from this list costs a disabled repository
# its row in the table and can never hide a live one or change what apt does.
DEB822_FIELDS = frozenset("""
    types uris suites components enabled architectures architectures-add
    architectures-remove languages languages-add languages-remove targets
    targets-add targets-remove signed-by trusted pdiffs by-hash
    allow-insecure allow-weak allow-downgrade-to-insecure check-valid-until
    valid-until-min valid-until-max date-max-future inrelease-path snapshot
    check-date description x-repolib-name repolib-id
""".split())


class Stanza(dict):
    """One deb822 stanza, looked up the way the format defines lookup.

    P2, <agent> 2026-08-21, executed. deb822 field names are
    CASE-INSENSITIVE, and this parser stored `match.group(1)` verbatim while
    every consumer read `stanza.get("Package")` case-sensitively. A stanza
    written `package: kodachi-lowercase` produced name=None, hit
    `if not name: continue`, and the package was ABSENT from the window with no
    error, no count and no log line: a repository the operator can see in apt
    simply did not exist here.

    Keys are kept verbatim so the stanza still reads like the file it came
    from; only the LOOKUP is folded. `__contains__` is folded too, because the
    duplicate-field guard below is written as `name in stanza` and a
    case-sensitive membership test would let `Package:` and `package:` both
    through as two different fields, which is the same defect wearing the
    duplicate's clothes.
    """

    def _actual(self, name):
        if dict.__contains__(self, name):
            return name
        lowered = str(name).lower()
        for key in self:
            if key.lower() == lowered:
                return key
        return None

    def __contains__(self, name):
        return self._actual(name) is not None

    def get(self, name, default=None):
        key = self._actual(name)
        return dict.get(self, key, default) if key is not None else default


def parse_packages(text):
    """RFC822-ish stanzas -> list of dicts. Continuation lines keep their text.

    Written against the real files rather than the format description: an
    `Installed-Size` in the apps component is sometimes a human string such as
    `204 MB` rather than an integer of kibibytes, which crashed the first draft
    of this parser on a package the user can actually install.
    """
    out = []
    stanza = Stanza()
    key = None
    for raw in apt_lines(text):
        line = raw.rstrip("\n")
        if not line.strip():
            if stanza:
                out.append(stanza)
                stanza = Stanza()
                key = None
            continue
        if line.startswith((" ", "\t")) and key:
            stanza[key] = stanza[key] + "\n" + line.strip()
            continue
        # P3, same audit, executed. `\s?` consumes AT MOST ONE space, so
        # `Package:   kodachi-spaced` produced the dict key '  kodachi-spaced'
        # with two leading spaces. That string is the package's IDENTITY
        # everywhere downstream, so installed_versions() could never match it
        # and candidate() could never find it, and it rendered in the table
        # carrying its indentation. Size was silently LOSSY rather than wrong,
        # because `re.fullmatch(r"\d+", " 100")` is False.
        #
        # THE FIX IS THE `.strip()` BELOW, NOT THIS ANCHOR. I widened `\s?` to
        # `\s*` first and reverted it: with the strip in place NO input
        # distinguishes the two, so the widening was a change that could not
        # fail, and its sabotage case read GREEN, which is the harness saying
        # exactly that. One fix, calibrated, beats two where only one is real.
        match = re.match(r"^([A-Za-z0-9-]+):\s?(.*)$", line)
        if match:
            name = match.group(1)
            # A DUPLICATE FIELD KEEPS THE FIRST VALUE. Raised by
            # <agent>, 2026-08-21, executed: `Package: real / Version: 1
            # / Package: spoof` used to parse to Package=spoof, so the second
            # identity in a stanza silently displaced the first. This needs a
            # signed index to reach, which is why it is a robustness guard and
            # not a vulnerability, but a parser that prefers the SECOND name a
            # stanza gives itself is the wrong default for a window whose whole
            # job is telling the operator what they are about to install.
            # I did not measure apt's own tie-break, so this is chosen for that
            # reason and not claimed to match it.
            if name in stanza:
                key = None        # and its continuations belong to it, so drop
                continue          # them too rather than folding them into the
            key = name            # previous field.
            stanza[key] = match.group(2).strip()
    if stanza:
        out.append(stanza)
    return out


def _kibibytes(value):
    """`Installed-Size` is kibibytes as an integer, except when it is not."""
    text = (value or "").strip()
    if not text:
        return None
    if re.fullmatch(r"\d+", text):
        return int(text) * 1024
    match = re.match(r"([\d.]+)\s*([KMG])i?B?\s*$", text, re.I)
    if match:
        scale = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}[match.group(2).upper()]
        try:
            return int(float(match.group(1)) * scale)
        except ValueError:
            return None
    return None


def _split_relations(value):
    return [item.strip() for item in (value or "").split(",") if item.strip()]


def index_files(channel, directory=None):
    """Every Packages file apt has for one channel, one per component.

    apt names them `<host>_<path>_dists_<suite>_<component>_binary-<arch>_Packages`,
    so the channel is identified by the host+path prefix and NOT by the suite:
    `repo` and `repo-beta` would otherwise be told apart only by a substring
    that is itself a prefix of the other.
    """
    directory = directory or lists_dir()
    spec = CHANNELS.get(channel)
    if spec is None:
        return []
    try:
        names = sorted(os.listdir(directory))
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise RepositoryStateError(
            "apt index directory could not be read: %s: %s" %
            (type(exc).__name__, exc)) from exc
    prefix = spec["list_key"] + "_dists_" + spec["suite"] + "_"
    found = []
    for name in names:
        if name.startswith(prefix) and name.endswith("_Packages"):
            found.append(os.path.join(directory, name))
    return found


def release_file(channel, directory=None):
    directory = directory or lists_dir()
    spec = CHANNELS.get(channel)
    if spec is None:
        return None
    try:
        names = set(os.listdir(directory))
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RepositoryStateError(
            "apt Release directory could not be read: %s: %s" %
            (type(exc).__name__, exc)) from exc
    for suffix in ("_InRelease", "_Release"):
        filename = spec["list_key"] + "_dists_" + spec["suite"] + suffix
        candidate = os.path.join(directory, filename)
        if filename in names:
            return candidate
    return None


def release_date(channel, directory=None):
    """The `Date:` the publisher stamped into the Release file apt fetched.

    It is NOT the date any individual package was uploaded, and the window
    labels it as the index date for exactly that reason.

    SAY WHAT THE TRUST ACTUALLY RESTS ON. This docstring used to claim the date
    is "inside the GPG-signed index", full stop. True for `_InRelease`, which is
    inline-signed. The `_Release` fallback's signature is DETACHED, in
    `Release.gpg`, and this function reads neither signature: it opens whichever
    file release_file() found and reads a header out of it. So the guarantee
    here is apt's, not ours, and it holds because apt verifies before it writes
    into lists/. That is a fine thing to rely on. Claiming to have verified it
    ourselves is not. Raised by <agent>, 2026-08-21, as a precision
    point rather than a defect, and they were right that a reader who takes the
    old sentence at face value stops looking.
    """
    path = release_file(channel, directory)
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if line.startswith("Date:"):
                    return line.split(":", 1)[1].strip()
                if line.startswith("MD5Sum:") or line.startswith("SHA256:"):
                    break
    except OSError as exc:
        raise RepositoryStateError(
            "apt Release file could not be read: %s: %s" %
            (type(exc).__name__, exc)) from exc
    return None


def component_of(filename, path):
    """`pool/<component>/...` is authoritative; the index filename is the fallback."""
    match = re.match(r"^pool/([^/]+)/", filename or "")
    if match and match.group(1) in COMPONENTS:
        return match.group(1)
    for comp in COMPONENTS:
        if "_" + comp + "_binary-" in os.path.basename(path or ""):
            return comp
    return "main"


def _version_parts(text):
    """Split a Debian version into (epoch, upstream, revision)."""
    text = (text or "").strip()
    epoch, _, rest = text.partition(":")
    if not epoch.isdigit() or not _:
        epoch, rest = "0", text
    upstream, sep, revision = rest.rpartition("-")
    if not sep:
        upstream, revision = rest, ""
    return int(epoch or 0), upstream, revision


def _order(char):
    """dpkg's collation: `~` first, then digits-as-nothing, letters, the rest."""
    if char == "~":
        return -1
    if char.isdigit():
        return 0
    if char.isalpha():
        return ord(char)
    return ord(char) + 256


def _compare_fragment(left, right):
    i = j = 0
    while i < len(left) or j < len(right):
        # the non-digit run
        while (i < len(left) and not left[i].isdigit()) \
                or (j < len(right) and not right[j].isdigit()):
            a = _order(left[i]) if i < len(left) and not left[i].isdigit() else 0
            b = _order(right[j]) if j < len(right) and not right[j].isdigit() else 0
            if a != b:
                return -1 if a < b else 1
            if i < len(left) and not left[i].isdigit():
                i += 1
            if j < len(right) and not right[j].isdigit():
                j += 1
        # the digit run, compared as a number so 10 beats 9
        a_start, b_start = i, j
        while i < len(left) and left[i].isdigit():
            i += 1
        while j < len(right) and right[j].isdigit():
            j += 1
        a = int(left[a_start:i] or "0")
        b = int(right[b_start:j] or "0")
        if a != b:
            return -1 if a < b else 1
    return 0


def compare_versions(left, right):
    """-1, 0 or 1, following dpkg's ordering rules.

    P1, <agent> 2026-08-21, executed. `load_channel` used to write
    `result[name] = {...}` with no guard, and `index_files` returns ONE Packages
    file PER COMPONENT in sorted order, so a package published in two components
    of one channel was silently collapsed to whichever component sorts LAST.
    Measured with the versions inverted: main carrying 9.9 and thirdparty
    carrying 1.0 showed 1.0, and the main entry was not merged, not flagged and
    not counted. It was gone.

    That needs no adversary and no forged index: a package present in main and
    in thirdparty is an ordinary publishing outcome, and `thirdparty` sorts
    after `main`. The window's whole job is telling the operator what they are
    about to install, so it now keeps the HIGHEST version, which is what apt
    would select, and remembers the other one instead of discarding it.

    Implemented here rather than shelling out to `dpkg --compare-versions`
    because this runs in the window's own draw path, once per duplicate, and a
    subprocess per comparison is a poor trade for a rule that is forty lines.
    `~` sorting BEFORE the empty string is the part that matters in practice:
    it is what makes 1.0~rc1 older than 1.0.
    """
    left_epoch, left_up, left_rev = _version_parts(left)
    right_epoch, right_up, right_rev = _version_parts(right)
    if left_epoch != right_epoch:
        return -1 if left_epoch < right_epoch else 1
    verdict = _compare_fragment(left_up, right_up)
    if verdict:
        return verdict
    return _compare_fragment(left_rev, right_rev)


def load_channel(channel, directory=None):
    """name -> record, for one channel. Empty dict when the channel is absent.

    An absent channel is a normal state, not an error: beta is opt-in and dev
    needs credentials, so the window must be able to draw with one of the three
    missing rather than refusing to start.
    """
    result = {}
    for path in index_files(channel, directory):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            raise RepositoryStateError(
                "apt package index could not be read: %s: %s" %
                (type(exc).__name__, exc)) from exc
        for stanza in parse_packages(text):
            name = stanza.get("Package")
            if not name:
                continue
            filename = stanza.get("Filename", "")
            description = stanza.get("Description", "")
            lines = description.split("\n")
            size = stanza.get("Size", "")
            record = {
                "name": name,
                "component": component_of(filename, path),
                "arch": stanza.get("Architecture", ""),
                "section": stanza.get("Section", ""),
                "priority": stanza.get("Priority", ""),
                "homepage": stanza.get("Homepage", ""),
                "maintainer": stanza.get("Maintainer", ""),
                "summary": lines[0] if lines else "",
                "description": "\n".join(lines[1:]).strip(),
                "depends": _split_relations(stanza.get("Depends")),
                "recommends": _split_relations(stanza.get("Recommends")),
                "version": stanza.get("Version", ""),
                "size": int(size) if re.fullmatch(r"\d+", size or "") else None,
                "installed_size": _kibibytes(stanza.get("Installed-Size")),
                "sha256": stanza.get("SHA256", ""),
                "sha1": stanza.get("SHA1", ""),
                "md5": stanza.get("MD5sum", ""),
                "filename": filename,
                "index_path": path,
                # Every OTHER component of this channel that also publishes this
                # package, with the version it publishes. Empty in the ordinary
                # case, which is why the window only draws the line when it is
                # not: a duplicate is worth telling the operator about precisely
                # because it is unusual.
                "also_in": [],
            }
            previous = result.get(name)
            if previous is None:
                result[name] = record
                continue
            # KEEP THE HIGHER VERSION, and on a tie keep the one read FIRST,
            # which is the earlier component alphabetically and therefore main
            # before thirdparty. Neither entry is discarded: the loser is
            # recorded on the winner so the datasheet can say so.
            loser, winner = record, previous
            if compare_versions(record["version"], previous["version"]) > 0:
                loser, winner = previous, record
            winner["also_in"] = previous["also_in"] + record["also_in"] + [{
                "component": loser["component"],
                "version": loser["version"],
                "index_path": loser["index_path"],
            }]
            result[name] = winner
    return result


# ----------------------------------------------------------------------------
# what this machine actually has
# ----------------------------------------------------------------------------

class RepositoryStateError(RuntimeError):
    """A machine-state producer failed, so absence must not be inferred."""


def installed_versions():
    """dpkg's answer, not apt's cache, and only for fully installed packages.

    `${db:Status-Status}` is checked because a package in `config-files` state
    after a plain remove still has a Version, and reporting that as installed
    would show a user a version they cannot run.
    """
    try:
        proc = subprocess.run(
            ["dpkg-query", "-W", "-f=${binary:Package}\\t${db:Status-Status}\\t${Version}\\n"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=30)
    # ValueError IS LOAD-BEARING HERE, IT IS NOT DEFENSIVE PADDING.
    # UnicodeDecodeError subclasses ValueError, NOT OSError and NOT
    # SubprocessError, so the two-name tuple this used to carry reads on the
    # page as "subprocess failure is handled" while a bad byte walks straight
    # through it. `kodachi-command-window:933` already writes the three-name
    # form; this file wrote the two-name form in all four places.
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise RepositoryStateError(
            "dpkg-query could not report installed packages: %s: %s" %
            (type(exc).__name__, exc)) from exc
    if proc.returncode != 0:
        raise RepositoryStateError(
            "dpkg-query exited %d while reading installed packages: %s" %
            (proc.returncode, (proc.stderr or "").strip() or "no error text"))
    found = {}
    for line in (proc.stdout or "").splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, status, version = parts
        if status.strip() != "installed":
            continue
        found[name.split(":")[0]] = version.strip()
    return found


def held_packages():
    """Package names apt is deliberately holding at their installed version.

    A channel pin and an apt hold answer different questions. The pin chooses
    which Kodachi channel supplies a package; the hold prevents apt moving the
    installed version at all. Read apt's state rather than remembering which
    button this window last pressed, so a hold made elsewhere is visible too.
    """
    try:
        proc = subprocess.run(
            [APT_MARK, "showhold"], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, errors="replace", timeout=30)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise RepositoryStateError(
            "apt-mark could not report held packages: %s: %s" %
            (type(exc).__name__, exc)) from exc
    if proc.returncode != 0:
        raise RepositoryStateError(
            "apt-mark exited %d while reading held packages: %s" %
            (proc.returncode, (proc.stderr or "").strip() or "no error text"))
    return frozenset(
        line.strip().split(":", 1)[0]
        for line in (proc.stdout or "").splitlines() if line.strip())


PIN_DIR = "/etc/apt/preferences.d"
PIN_PREFIX = "kodachi-channel-"
SYSTEM_PIN = "kodachi-channel.pref"


def pinned_channels(directory=None):
    """Which packages this machine is deliberately tracking off stable.

    Read from the pin files the privileged helper writes, so the window reports
    the state of the SYSTEM rather than remembering what it did last time.
    """
    directory = directory or os.environ.get("KODACHI_REPO_PIN_DIR") or PIN_DIR
    pins = {}
    system = None
    try:
        names = sorted(os.listdir(directory))
    except FileNotFoundError:
        return pins, system
    except OSError as exc:
        raise RepositoryStateError(
            "apt pin directory could not be read: %s: %s" %
            (type(exc).__name__, exc)) from exc
    for name in names:
        if not name.startswith(PIN_PREFIX) and name != SYSTEM_PIN:
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            raise RepositoryStateError(
                "apt pin file could not be read: %s: %s" %
                (type(exc).__name__, exc)) from exc
        suite = None
        for line in text.splitlines():
            if line.lower().startswith("pin:"):
                release = re.search(r"\brelease\s+(.+)$", line, re.IGNORECASE)
                if release:
                    selectors = {
                        key.lower(): value
                        for key, value in re.findall(
                            r"(?:^|,)\s*([A-Za-z]+)\s*=\s*([A-Za-z0-9._-]+)",
                            release.group(1))
                    }
                    suite = selectors.get("a") or selectors.get("n")
        if suite is None:
            continue
        channel = next((key for key, spec in CHANNELS.items()
                        if spec["suite"] == suite), None)
        if channel is None:
            continue
        if name == SYSTEM_PIN:
            system = channel
        else:
            pins[name[len(PIN_PREFIX):-len(".pref")]] = channel
    return pins, system


# ----------------------------------------------------------------------------
# the merged catalog the window draws
# ----------------------------------------------------------------------------

SOURCES_DIR = "/etc/apt/sources.list.d"
# apt and the privileged helper accept only this basename alphabet.  Apply the
# same predicate before reading, so a file the GTK model reports is always one
# the action helper can name, and vice versa.
SOURCE_FILENAME_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(?:list|sources)\Z")


def sources_dir():
    return os.environ.get("KODACHI_REPO_SOURCES_DIR", SOURCES_DIR)


def native_architecture():
    """Return apt's native architecture, or refuse an unprovable match."""
    try:
        completed = subprocess.run(
            ["/usr/bin/dpkg", "--print-architecture"],
            capture_output=True, text=True, errors="replace", timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise RepositoryStateError(
            "native package architecture could not be read: %s: %s" %
            (type(exc).__name__, exc)) from exc
    value = completed.stdout.strip()
    if completed.returncode != 0 or not value:
        raise RepositoryStateError(
            "native package architecture could not be read: dpkg exited %d: %s" %
            (completed.returncode, completed.stderr.strip()))
    return value


def _architecture_allows(entry, architecture):
    """Apply apt's base, add, then remove architecture fields."""
    def values(field):
        return set((entry.get(field) or "").replace(",", " ").split())

    base = values("architectures")
    allowed = set(base) if base else {architecture}
    allowed.update(values("architectures_add"))
    allowed.difference_update(values("architectures_remove"))
    return architecture in allowed


def configured_channels(directory=None, list_file=None, architecture=None):
    """Which Kodachi channels this machine has a SOURCE for.

    This is a different question from "which channels have an index", and the
    difference is the whole reason the function exists. The official
    setup.sh writes ONE deb822 source and it carries `Suites: stable`, so a
    machine that followed the documented instructions can never see a beta
    package, no matter how many times apt update runs. Presence of an index
    proves the source was fetched at least once; presence of a source proves
    apt will fetch it again.

    Read from both deb822 (.sources) and one-line (.list) files, because a
    machine that was set up before the deb822 switch still has the old form.
    """
    directory = directory or sources_dir()
    architecture = architecture or native_architecture()
    found = {}

    for entry in system_sources(directory=directory, list_file=list_file):
        if entry["format"] == "read-error":
            subject = ("configured-source directory"
                       if entry["path"] == directory else
                       "configured-source file")
            raise RepositoryStateError(
                "%s could not be read: %s" %
                (subject, entry["components"]))
        if (entry["format"] not in {"deb822", "one-line"}
                or not entry["enabled"]
                or "deb" not in entry["types"].split()
                or not entry["components"]
                or not _architecture_allows(entry, architecture)):
            continue
        for channel, spec in CHANNELS.items():
            if (entry["suite"] == spec["suite"]
                    and _matches_channel_uri(entry["uri"], spec["url"])):
                found[channel] = entry["path"]
    return found


SOURCE_FILE_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(?:list|sources)\Z")


def files_mentioning_channel(channel, directory=None):
    """Every apt source FILE whose raw text names this channel's URL.

    UNPARSED ON PURPOSE, and that is the whole value of it. Every other
    predicate here reads a stanza and can therefore decline one: a deb822 block
    with no `Components` is `invalid` to `_deb822_scan`, a missing `Types` line
    likewise, and both are then invisible to `configured_channels` AND to
    `dormant_channel_sources`. The helper's `_channel_sources_split` has no such
    gate: it scans every name-matching file containing "kodachi.cloud" and
    parses far more loosely, so it refuses to write beside stanzas this library
    cannot see at all.

    That asymmetry is not fixable by matching filters, because the difference is
    the PARSER rather than the predicate. So the window stops asking "is this a
    channel source" for the purpose of promising a write, and asks the cheaper
    question the helper effectively asks: does any file here even MENTION this
    channel. A substring test cannot be declined by a malformed stanza.

    Added 2026-08-30 after the inspector measured the residue twice. My
    `os.path.lexists(managed_path)` note covered the managed path only, while
    the helper scans the whole directory, so a dormant stanza at
    `operator-added.sources` with no Components produced no refusal, no note,
    and a confirmation promising "This writes ...", after which the helper
    answered 4 and sent the user to press Enable on a row `_on_source_state`
    then refuses as `invalid`. A dead end reachable in three steps.

    Deliberately WEAK and deliberately loud: it over-reports (a commented-out
    mention counts) and it is used only to soften a PROMISE, never to gate a
    mutation. Over-reporting costs one extra sentence in a dialog; the
    alternative cost the user a dead end.
    """
    directory = directory or sources_dir()
    url = CHANNELS[channel]["url"]
    found = []
    try:
        entries = sorted(os.listdir(directory))
    except OSError:
        # UNREADABLE IS NOT EMPTY, and the caller must not read it as "no file
        # mentions this". Raising matches `configured_channels` and
        # `dormant_channel_sources`, both of which refuse to answer for a
        # directory they could not read.
        raise RepositoryStateError(
            "configured-source directory could not be listed: %s" % directory)
    for entry in entries:
        if not SOURCE_FILE_NAME_RE.match(entry):
            continue
        path = os.path.join(directory, entry)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as error:
            # A file that could not be read is not evidence that it does not
            # mention this channel. This answer controls whether the window
            # may present a concrete write promise, so skipping the file would
            # fail open in exactly the same way as an unreadable directory.
            raise RepositoryStateError(
                "configured-source file could not be read: %s: %s: %s" %
                (path, type(error).__name__, error)) from error
        if url in text:
            found.append(path)
    return found


def dormant_channel_sources(directory=None, list_file=None,
                            architecture=None):
    """Files that HOLD a channel with its switch off, so apt ignores them.

    The mirror of `configured_channels`, which requires `entry["enabled"]` and
    therefore reports such a file as ABSENT. Both answers are correct for their
    own question and together they are the whole truth; separately, "absent"
    is the one that misleads, because the window then offers to WRITE a file
    that already exists.

    Added 2026-08-30 after the inspector found the gap end to end: this
    window's own Disable button can switch off kodachi-stable.sources, after
    which `configured_channels` no longer reports stable, both of the Add
    path's refusals pass, the confirmation promises "This writes
    /etc/apt/sources.list.d/kodachi-stable.sources", and the helper then
    returns 4 with a CLI instruction to run `kodachi-repo-apt source-enable`,
    in a window that has a button for exactly that. The helper was right
    throughout. The window was promising something it could not deliver.

    Mirrors `channel_sources_switched_off` in kodachi-repo-apt, which is the
    predicate that actually decides, and is deliberately the weaker of the two:
    it answers only for the presentation layer and never gates a mutation.
    """
    directory = directory or sources_dir()
    # `architecture` IS ACCEPTED AND NOT RESOLVED. The parameter exists so this
    # signature matches `configured_channels` and one fixture can drive both,
    # but the predicate below deliberately ignores it (see the comment there),
    # and defaulting it would shell out to dpkg on every call and could raise
    # RepositoryStateError for a question that does not depend on the answer.
    _ = architecture
    found = {}
    for entry in system_sources(directory=directory, list_file=list_file):
        # A ROW THIS FUNCTION COULD NOT READ MUST RAISE, EXACTLY AS
        # `configured_channels` DOES, and the first version of this function
        # silently `continue`d past it. Raised by <agent>, 2026-08-30,
        # and the consequence was worse than an inconsistency between two
        # sibling predicates: the caller in the window wraps this in a
        # try/except RepositoryStateError precisely so it can refuse rather
        # than promise a write while the dormant state is unknown, and that
        # handler was UNREACHABLE for the only producer that can trigger it.
        # An unreadable /etc/apt/sources.list.d would have come back as "no
        # dormant source", which is the answer that lets the write proceed.
        #
        # A silent skip in a predicate that gates a mutation always fails in
        # the permissive direction, because "I found nothing" and "I could not
        # look" are the same value.
        #
        # WRITTEN DIFFERENTLY FROM ITS TWIN IN `configured_channels` ON
        # PURPOSE, and this is not style. Two calibration arms belonging to
        # another lane anchor on that function's exact wording; copying it
        # verbatim took both of them from 1 match to 2, and an ambiguous
        # anchor lands on whichever site comes first and then reports
        # "GREEN ** CONTRACT NOT CHECKED **", which reads as a weak test
        # rather than a misaimed sabotage. Same behaviour, same message,
        # different text, so each arm still owns exactly one site.
        if entry["format"] == "read-error":
            raise RepositoryStateError(
                "%s could not be read: %s"
                % ("configured-source directory"
                   if entry["path"] == directory else "configured-source file",
                   entry["components"]))
        # LOOSER THAN `configured_channels` IN EXACTLY TWO RESPECTS, AND NO
        # MORE, because the previous version of this comment justified dropping
        # THREE filters with a claim about the helper that was FALSE.
        #
        # I wrote that `channel_sources_switched_off` "tests neither
        # types-is-deb nor components nor architecture". It tests types. See
        # kodachi-repo-apt: the deb822 arm does `if types and "deb" not in
        # types: continue` and the one-line arm does
        # `if _one_line_source_type(...) != "deb": continue`. Only the EMPTY
        # `Types` case goes untested there. Measured by the inspector,
        # 2026-08-30, with a positive control in the same run: a switched-off
        # `Types: deb-src` stanza is NOT switched-off to the helper and my
        # loosened predicate called it dormant, so the window refused an add
        # the helper would have performed and sent the user to press Enable on
        # a row this window will not switch on. A dead end, produced by a
        # comment I did not check against the code it described.
        #
        # SO: components and architecture are dropped. The helper genuinely
        # ignores both.
        #
        # DROPPING THE FILTER DOES NOT MAKE THIS SEE A COMPONENTS-LESS STANZA,
        # AND MY PREVIOUS SENTENCE HERE IMPLIED IT DID. `_deb822_scan` requires
        # {types, uris, suites, components} and declines the stanza as
        # `invalid` BEFORE this filter ever runs, so a stanza missing
        # Components is invisible here whatever this line says. That gap is
        # covered by `files_mentioning_channel`, an unparsed scan, because the
        # difference is the PARSER and no arrangement of filters can close it.
        # Second time in two rounds that a comment of mine here overstated what
        # the code does; the inspector measured both. `deb` in types is KEPT, matching the helper, with the same
        # `types and` guard so an empty Types field still matches on both
        # sides. `architecture` stays in the signature so one fixture can drive
        # this and its sibling; it is deliberately not consulted.
        if (entry["format"] not in {"deb822", "one-line"}
                or entry["enabled"]):
            continue
        types = (entry["types"] or "").split()
        if types and "deb" not in types:
            continue
        for channel, spec in CHANNELS.items():
            if (entry["suite"] == spec["suite"]
                    and _matches_channel_uri(entry["uri"], spec["url"])):
                found.setdefault(channel, entry["path"])
    return found


def _matches_channel_uri(uri, expected):
    """True only for the channel's real host and normalized path."""
    try:
        actual = urlsplit(uri)
        wanted = urlsplit(expected)
        if actual.username is not None or actual.password is not None:
            return False
        host = (actual.hostname or "").rstrip(".")
        host = host.encode("idna").decode("ascii").lower()
        wanted_host = (wanted.hostname or "").rstrip(".").lower()
    except (AttributeError, TypeError, UnicodeError, ValueError):
        return False
    under = host == wanted_host or host.endswith("." + wanted_host)
    actual_path = "/" + actual.path.strip("/")
    wanted_path = "/" + wanted.path.strip("/")
    return (actual.scheme.lower() == wanted.scheme.lower() and under
            and actual_path == wanted_path
            and not actual.query and not actual.fragment)


def configured_channel_keyrings(channel, directory=None, list_file=None):
    """The actual Signed-By values on live official binary sources."""
    spec = CHANNELS[channel]
    return sorted({entry["signed_by"] for entry in system_sources(
        directory=directory, list_file=list_file)
        if entry["format"] in {"deb822", "one-line"}
        and entry["enabled"] and "deb" in entry["types"].split()
        and entry["suite"] == spec["suite"]
        and _matches_channel_uri(entry["uri"], spec["url"])})


def dev_entitled(path=None):
    """Whether this machine holds a dev-channel credential at all.

    `path` overrides which file is examined and defaults to DEV_AUTH_FILE.
    It exists so a CALLER's own module constant stays authoritative: the
    window keeps `DEV_AUTH_FILE` of its own (bound to this one) and passes it
    in, so patching the window's constant in a test still changes the answer.
    Without the parameter this function would silently read the library's copy
    whatever the caller had been asked to use, which is a test that cannot see
    what it is testing.

    THE WEAKEST QUESTION AN UNPRIVILEGED PROCESS MAY ASK, and deliberately so.
    /etc/apt/auth.conf.d/kodachi-dev.conf is 0600 root:root precisely so no
    local user can read the password, and the directory is 0755, which permits
    stat and never open. So size-greater-than-zero is the strongest predicate
    available here, and it is knowingly weaker than the helper's
    `dev_credentials_present()`, which parses both fields as root.

    THAT WEAKNESS DOES NOT MATTER FOR WHAT THIS GATES, and saying why is the
    point. This decides only whether the window DISPLAYS a channel's contents.
    It is not the security boundary and must never be described as one: the
    boundary is HTTP Basic Auth on /repo-dev at the server, measured 2026-08-29
    as 401 against stable and beta answering 200 in the same run. A local user
    who edits this function, or this whole file, gains exactly nothing: apt
    still cannot fetch a dev package without the credential, and after
    `dev-credentials-clear` there is no fetched dev metadata left on disk for
    an edited window to display either.

    The failure direction is the safe one: any error reading the path answers
    "not entitled", so the dev channel is hidden rather than shown.
    """
    try:
        return os.path.getsize(path or DEV_AUTH_FILE) > 0
    except OSError:
        return False


def catalog(directory=None, pin_directory=None, include_dev=None):
    """Build the package model.

    `include_dev` gates the DEV channel's contents, defaulting to whether this
    machine holds a dev credential. Passing it explicitly is for the tests and
    for the window, which resolves it once per reload so a single answer drives
    the grid, the rail counts and the datasheet together.

    WHY THE LISTING NEEDED A GATE AT ALL, given the server already enforces
    access. Operator, 2026-08-29: "dev repo should not list anything without a
    proper key, its meant for admin". He is right and the old behaviour was
    indefensible: every credential check in the window greyed a BUTTON, and not
    one of them removed a row, so the complete private catalogue, names,
    versions, byte sizes, SHA256 digests and descriptions, was listed and
    searchable to anyone. Withholding the DOWNLOAD while publishing the
    INVENTORY is not a gate, and the window even said "protected by Basic Auth"
    directly above the list it was showing.

    WHAT include_dev DOES *NOT* GATE, so nobody reads the gate as total: the
    `dates` and `present` maps below are still built over every channel, so a
    machine that has a dev index on disk still reports THAT ONE EXISTS and when
    it was published, and `_on_export` writes those dates into the exported
    manifest. That is deliberate and is the only thing that can tell a user a
    stale dev index is sitting on their machine, which became actionable once
    clearing the credential started deleting it. No package name, version,
    size, digest or description is in either map.
    """
    if include_dev is None:
        include_dev = dev_entitled()
    stable = load_channel("stable", directory)
    beta = load_channel("beta", directory)
    # An empty table, not a skipped read: every consumer below indexes `dev`
    # unconditionally, and the channel must exist and be empty rather than be
    # absent, or "no dev packages" turns into a KeyError somewhere downstream.
    dev = load_channel("dev", directory) if include_dev else {}
    installed = installed_versions()
    held = held_packages()
    pins, system_pin = pinned_channels(pin_directory)

    names = set(stable) | set(beta) | set(dev)
    packages = []
    for name in sorted(names):
        record = stable.get(name) or beta.get(name) or dev.get(name)
        entry = {
            "name": name,
            "component": record.get("component", "main"),
            "arch": record.get("arch", ""),
            "section": record.get("section", ""),
            "homepage": record.get("homepage", ""),
            "maintainer": record.get("maintainer", ""),
            "summary": record.get("summary", ""),
            "description": record.get("description", ""),
            "depends": record.get("depends", []),
            "recommends": record.get("recommends", []),
            "channels": {},
            "installed": installed.get(name),
            "pinned": pins.get(name),
            "held": name in held,
        }
        for key, table in (("stable", stable), ("beta", beta), ("dev", dev)):
            if name in table:
                entry["channels"][key] = table[name]
        blurb = BLURBS.get(name)
        entry["benefit"] = blurb[0] if blurb else ""
        entry["usecase"] = blurb[1] if blurb else ""
        entry["curated"] = blurb is not None
        packages.append(entry)

    return {
        "packages": packages,
        "installed_count": sum(1 for p in packages if p["installed"]),
        "system_pin": system_pin,
        "lists_dir": directory or lists_dir(),
        "dates": {key: release_date(key, directory) for key in CHANNELS},
        "present": {key: bool(index_files(key, directory)) for key in CHANNELS},
        "configured": configured_channels(),
    }


def candidate(package, channel):
    return package.get("channels", {}).get(channel)


def upgrade_state(package, channel):
    """One word for the table's State column, decided from versions only."""
    have = package.get("installed")
    want = candidate(package, channel)
    if not have:
        return "available" if want else "absent"
    if not want:
        return "installed"
    if have == want.get("version"):
        return "current"
    return "upgradable" if _newer(want.get("version"), have) else "downgrade"


def _newer(candidate_version, installed_version):
    """Use the in-process comparator already cross-checked against dpkg."""
    if not candidate_version or not installed_version:
        return False
    return compare_versions(candidate_version, installed_version) > 0


def human_size(value):
    if not value:
        return "n/a"
    if value >= 1024 ** 3:
        return "%.2f GB" % (value / 1024 ** 3)
    if value >= 1024 ** 2:
        return "%.1f MB" % (value / 1024 ** 2)
    return "%d KB" % (value / 1024)


# ----------------------------------------------------------------------------
# upload dates, fetched not invented
# ----------------------------------------------------------------------------

def upload_cache_path():
    return os.path.join(cache_dir(), "uploads.json")


def read_upload_cache():
    try:
        with open(upload_cache_path(), "r", encoding="utf-8",
                  errors="replace") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_upload_cache(data):
    try:
        os.makedirs(cache_dir(), exist_ok=True)
        with open(upload_cache_path(), "w", encoding="utf-8",
                  errors="replace") as handle:
            json.dump(data, handle, indent=1, sort_keys=True)
    # ValueError for the ENCODE direction, exactly as at :500 for the decode:
    # UnicodeEncodeError subclasses ValueError, not OSError, so the one-name
    # tuple read as "the write is handled" while a surrogate in the string
    # walked straight out of it.
    except (OSError, ValueError):
        return False
    return True


def fetch_upload_date(channel, filename, timeout=8):
    """HTTP HEAD -> ``(Last-Modified, error)`` for one pool file.

    Failures name the observed cause without guessing that the machine is
    offline. This is called from a worker thread and never blocks GTK.
    """
    spec = CHANNELS.get(channel)
    if not spec or not filename:
        return None, "channel or artifact identity is missing"
    url = spec["url"].rstrip("/") + "/" + filename.lstrip("/")
    try:
        proc = subprocess.run(
            ["curl", "-sSI", "--max-time", str(int(timeout)), url],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=timeout + 4)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, "%s: %s" % (type(exc).__name__, exc)
    if proc.returncode != 0:
        return None, "curl exited %d" % proc.returncode
    for line in (proc.stdout or "").splitlines():
        if line.lower().startswith("last-modified:"):
            raw = line.split(":", 1)[1].strip()
            try:
                stamp = time.strptime(raw, "%a, %d %b %Y %H:%M:%S %Z")
            except ValueError:
                return raw, ""
            return time.strftime("%Y-%m-%d %H:%M UTC", stamp), ""
    return None, "server returned no Last-Modified header"


# ----------------------------------------------------------------------------
# ISO images: the one question on this window apt cannot answer
# ----------------------------------------------------------------------------
# Operator, 2026-09-18: "GTK should also be notifying the user with the stable
# updates of ISO and the beta updates of the ISO. Same as the Tauri dashboard."
#
# This window's standing rule is that it never shows a version it did not read
# from an apt index or an HTTP header, and an ISO is in neither: apt knows
# nothing about the image a machine was installed from. So the rule is kept by
# NAMING THE OTHER SOURCE rather than by bending it. Everything below is read
# from exactly two files, both on disk or over one HTTPS GET, and every value
# that is absent stays absent:
#
#   published   https://kodachi.cloud/apps/os/main-info.json
#               the three typed product blocks are the RELEASED STABLE line;
#               channels.beta.products carries the BETA line. Those are two
#               different tracks in one file and are compared separately.
#   installed   /opt/kodachi/dashboard/hooks/config/build-meta.json, written at
#               pack time, whose `editions` map holds the per-edition build this
#               machine actually carries.
#
# WHY BOTH LINES AND NOT JUST ONE. A machine running a beta image is AHEAD of
# the stable line by design, so comparing it against stable alone produces "no
# update" forever. That is exactly what a user reported on 2026-09-18: a
# <lab-host> desktop was compared against stable 9.0.1.174, correctly refused the
# older line, and was told nothing, while beta ISO <lab-host> had been published
# that morning.

MAIN_INFO_URL = "https://kodachi.cloud/apps/os/main-info.json"

# The two images a user can be running. binary_pack is deliberately absent: it
# is a tarball of binaries, not an ISO, and apt already reports it package by
# package on every other page of this window.
ISO_PRODUCTS = (("terminal", "Terminal ISO"), ("desktop", "Desktop ISO"))

BUILD_META_DEFAULT = "/opt/kodachi/dashboard/hooks/config/build-meta.json"

# Absence, currency, an update and being ahead are FOUR answers. The window
# prints each one in its own words, because collapsing "I could not read the
# published file" into "you are up to date" is the fail-open direction on a
# distribution whose users install from these images.
ISO_UPDATE = "update"
ISO_CURRENT = "current"
ISO_AHEAD = "ahead"
ISO_UNKNOWN = "unknown"


def build_meta_path():
    return os.environ.get("KODACHI_BUILD_META") or BUILD_META_DEFAULT


def read_build_meta(path=None):
    """The pack-time metadata for this machine, or {} when it cannot be read."""
    try:
        with open(path or build_meta_path(), "r", encoding="utf-8",
                  errors="replace") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def local_iso_version(meta, product):
    """The build this machine carries for one edition, or None.

    Reads the `editions` map first, because that is the per-edition number; the
    top-level pair is only used when it is THIS machine's own track, exactly as
    the dashboard resolves it. Never falls back to another edition's number: a
    terminal build printed under Desktop would be a fabricated comparison.
    """
    if not isinstance(meta, dict):
        return None
    editions = meta.get("editions")
    if isinstance(editions, dict):
        entry = editions.get(product)
        if isinstance(entry, dict):
            value = entry.get("nightly_version")
            if isinstance(value, str) and value.strip():
                return value.strip()
    if meta.get("track") == product:
        value = meta.get("nightly_version")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def fetch_main_info(timeout=8, url=None):
    """One HTTPS GET of the published release file -> ``(dict, error)``.

    Called from a worker thread, never from the GTK main loop, and it names the
    observed cause on failure rather than concluding the machine is offline.
    """
    target = url or MAIN_INFO_URL
    try:
        proc = subprocess.run(
            ["curl", "-fsS", "--proto", "=https", "--tlsv1.2",
             "--max-time", str(int(timeout)), target],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=timeout + 4)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, "%s: %s" % (type(exc).__name__, exc)
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip().splitlines()
        return None, "curl exited %d%s" % (
            proc.returncode, (": " + detail[-1]) if detail else "")
    try:
        data = json.loads(proc.stdout or "")
    except ValueError as exc:
        return None, "published release file is not JSON: %s" % exc
    if not isinstance(data, dict):
        return None, "published release file is not an object"
    return data, ""


def iso_cache_path():
    return os.path.join(cache_dir(), "iso-images.json")


def read_iso_cache():
    try:
        with open(iso_cache_path(), "r", encoding="utf-8",
                  errors="replace") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def write_iso_cache(data):
    try:
        os.makedirs(cache_dir(), exist_ok=True)
        with open(iso_cache_path(), "w", encoding="utf-8",
                  errors="replace") as handle:
            json.dump(data, handle, indent=1, sort_keys=True)
    except (OSError, ValueError):
        return False
    return True


def _published_iso(info, product):
    """``(stable_version, beta_version, beta_url)`` out of the release file.

    The stable half is the typed top-level product block, the beta half is
    channels.beta.products. A field this file does not carry comes back None and
    is reported as never compared.
    """
    stable = None
    beta = None
    beta_url = None
    if isinstance(info, dict):
        block = info.get(product)
        if isinstance(block, dict):
            value = block.get("nightly_version") or block.get("main_version")
            if isinstance(value, str) and value.strip():
                stable = value.strip()
        channels = info.get("channels")
        if isinstance(channels, dict):
            beta_channel = channels.get("beta")
            if isinstance(beta_channel, dict):
                products = beta_channel.get("products")
                if isinstance(products, dict):
                    entry = products.get(product)
                    if isinstance(entry, dict):
                        value = (entry.get("nightly_version")
                                 or entry.get("version"))
                        if isinstance(value, str) and value.strip():
                            beta = value.strip()
                        url = entry.get("url")
                        if isinstance(url, str) and url.strip():
                            beta_url = url.strip()
    return stable, beta, beta_url


def iso_state(local, published):
    """Compare two ISO build strings with the repository's own comparator."""
    if not local or not published:
        return ISO_UNKNOWN
    order = compare_versions(published, local)
    if order > 0:
        return ISO_UPDATE
    if order < 0:
        return ISO_AHEAD
    return ISO_CURRENT


def iso_rows(info, meta=None):
    """One row per ISO edition, both published lines compared separately.

    Pure: takes the two documents and returns what they say, so the window can
    render it on the GTK thread and a test can assert it without a network.
    """
    metadata = meta if meta is not None else read_build_meta()
    rows = []
    for product, label in ISO_PRODUCTS:
        local = local_iso_version(metadata, product)
        stable, beta, beta_url = _published_iso(info, product)
        rows.append({
            "product": product,
            "label": label,
            "local": local,
            "stable": stable,
            "beta": beta,
            "beta_url": beta_url,
            "stable_state": iso_state(local, stable),
            "beta_state": iso_state(local, beta),
        })
    return rows


# ----------------------------------------------------------------------------
# OUR words, not the repository's
# ----------------------------------------------------------------------------
# Keyed by package name. `benefit` answers "what does this give me", `usecase`
# answers "when would I use it". A package with no entry here shows its own
# Description instead and the window says the copy is the maintainer's, so a
# package added to the repo tomorrow is never described by a guess made today.

BLURBS = {
    "kodachi": (
        "Installs the complete Kodachi privacy suite in one command and keeps every "
        "component on one matched version stamp.",
        "Start here. Pulls the six core components plus the routing transports, so VPN, "
        "Tor, DNS and the dashboard all work together."),
    "kodachi-hooks-core": (
        "The engine room: the signed hook binaries that do the actual routing, DNS, "
        "firewall and integrity work.",
        "Required by everything else. Owns the shared RSA-4096 public key and the PATH "
        "links the dashboard and the dock call."),
    "kodachi-dashboard": (
        "The desktop control panel: one window for VPN, Tor, DNS, kill-switch and "
        "system health.",
        "Launch it from the dock. Every control it exposes calls a signed hook."),
    "kodachi-ai": (
        "Local AI binaries that watch, learn and explain your privacy posture without "
        "sending anything off the machine.",
        "Threat monitoring, command help and anomaly detection, all offline."),
    "kodachi-assets": (
        "The data tree the hooks read: country flags, DNS and VPN provider databases, "
        "connection profiles, sounds and icons.",
        "Installed automatically. Update it when new VPN or DNS providers are added."),
    "kodachi-desktop": (
        "Freedesktop launchers and icons so Kodachi appears in the application menu "
        "like any native app.",
        "Gives you the menu entry and the icon set. Pure data, no binaries."),
    "kodachi-conky": (
        "The live on-desktop status panels: IP, Tor circuit, DNS, VPN, firewall and "
        "system load at a glance.",
        "Autostarts at login and seeds a per-user config on first run, so your edits "
        "are never overwritten."),
    "kodachi-pihole": (
        "One-click Pi-hole: network-wide ad and tracker blocking wired into Kodachi's "
        "DNSCrypt resolver.",
        "Optional. Installs and configures Pi-hole, then hands DNS control to "
        "dns-switch. Removable with apt purge."),
    "kodachi-xray": (
        "XTLS/Reality transport, the hardest to fingerprint tunnel Kodachi ships.",
        "Used by routing-switch when you pick an Xray profile."),
    "kodachi-v2ray": (
        "VMess/VLESS multi-protocol proxy core for censored networks.",
        "The backing binary for every V2Ray based server profile."),
    "kodachi-v2ray-plugin": (
        "Shadowsocks plugin that wraps traffic in WebSocket and TLS so it looks like "
        "ordinary HTTPS.",
        "Paired with a Shadowsocks profile when plain Shadowsocks is blocked."),
    "kodachi-hysteria": (
        "QUIC based transport built for lossy, throttled and high latency links.",
        "Pick it when TCP based tunnels stall."),
    "kodachi-mieru": (
        "TCP proxy designed to resist active probing and traffic analysis.",
        "An alternative when Xray and V2Ray endpoints are already blocked."),
    "kodachi-kloak": (
        "Keystroke anonymiser: randomises key press timings so you cannot be "
        "fingerprinted by typing rhythm.",
        "Runs as a service and defeats behavioural biometrics in the browser."),
    "kodachi-dnscrypt": (
        "Encrypted DNS resolver with DNSSEC, anonymised relays and no-log upstreams.",
        "The resolver behind dns-switch. Stops your ISP reading or forging lookups."),
    "kodachi-tor-browser": (
        "Tor Browser packaged for Kodachi, launched through the system Tor instance.",
        "Anonymous browsing with a fingerprint shared by every other Tor user."),
    "kodachi-monero-gui": (
        "The official Monero wallet, ready to run over Tor from the first launch.",
        "Private cryptocurrency without a custodian."),
    "kodachi-portmaster": (
        "Per-application firewall with live connection monitoring and DNS filtering.",
        "See which binary is talking to which host, and cut it off with one click."),
    "kodachi-mission-center": (
        "System resource monitor: CPU, GPU, memory, disk and per-process network.",
        "A cleaner replacement for the stock task manager when chasing a leak."),
    "exifcleaner": (
        "Strips EXIF, GPS and camera metadata from images, video and PDFs by drag "
        "and drop.",
        "Run every photo through it before you publish."),
    "librewolf": (
        "Firefox fork with telemetry removed and privacy defaults turned up.",
        "Your everyday browser when you want privacy without Tor latency."),
    "session-desktop": (
        "Onion routed messenger with no phone number and no central account.",
        "Encrypted chat that leaves no address book behind."),
    "veracrypt": (
        "Full disk and container encryption with hidden volumes.",
        "Encrypt a USB stick or a hidden partition."),
    "obsidian": (
        "Local first markdown knowledge base. Notes stay as plain files on your disk.",
        "Research notes that never touch a cloud sync service."),
    "codium": (
        "VS Code without Microsoft telemetry or branding.",
        "A full IDE for scripting and reviewing Kodachi hooks."),
    "gitkraken": (
        "Graphical Git client with visual branch history and merge tooling.",
        "Repository work when a terminal diff is not enough."),
    "tabby-terminal": (
        "Modern terminal with tabs, split panes, SSH profiles and a serial console.",
        "A friendlier terminal for long sessions."),
    "termius-app": (
        "SSH client with synced host profiles, keys and snippets.",
        "Managing many remote hosts from one keyboard."),
}


# ══════════════════════════════════════════════════════════════════════
# EVERY apt source on the machine, not only Kodachi's
# ══════════════════════════════════════════════════════════════════════
#
# The window is a Kodachi repository manager first, but a user who is deciding
# whether to take an update needs to see WHERE his software comes from, and on
# this distribution that is never one repository. A stock Kodachi machine
# carries Debian stable, Debian security, Debian updates, backports and Whonix
# before anyone adds anything, and the ones a user adds himself (a Tor
# repository, a vendor repository) are exactly the ones nobody remembers
# enabling. So the surface below reads them ALL and says which is which.

SOURCES_LIST = "/etc/apt/sources.list"

# WHAT APT ITSELF CALLS FALSE. apt's StringToBool reads "no", "false", "0",
# "off", "without" and "disable" as off, and this window used to test only the
# first three, so a stanza carrying `Enabled: off` was drawn as ENABLED beside a
# machine that was not fetching it. The window's whole job is telling the
# operator where their software comes from, so a label that disagrees with apt
# is the one defect it cannot have. The pkexec helper carries the same tuple,
# deliberately duplicated because it imports nothing, and a contract asserts the
# two are identical.
DISABLING_VALUES = ("no", "false", "0", "off", "without", "disable")

# Options whose values change apt's trust or Release-file freshness policy.
# Keep the normalized keys on every source row so the GTK detail pane can show
# the exact effective value instead of implying apt's defaults.
APT_SECURITY_OPTIONS = (
    "trusted", "allow-insecure", "allow-weak",
    "allow-downgrade-to-insecure", "check-date", "check-valid-until",
    "date-max-future", "valid-until-min", "valid-until-max",
)
APT_STANDARD_FIELDS = {
    "types", "uris", "suites", "components", "enabled", "signed-by",
}

# THE MARK kodachi-repo-apt PUTS ON A LINE IT SWITCHED OFF ITSELF. Duplicated
# here for the same reason DEB822_FIELDS is: the helper may not import from
# /usr/local/lib, and the two copies have to agree or the window draws rows the
# helper cannot act on. A contract in tests/test_repo_manager.py asserts the two
# literals are identical and a sabotage edits each copy separately.
#
# It matters to the PARSER, not only to the helper. Without it, a `.list` this
# window disabled would have every one of its rows VANISH from the table: the
# reader below looks for `deb` immediately after the comment characters, and
# `#kodachi-disabled# deb ...` does not match, so the file would go quietly
# shorter the moment the operator switched it off.
DISABLED_MARK = "#kodachi-disabled# "

KIND_LABELS = {
    "kodachi": "Kodachi",
    "debian": "Debian",
    "security": "Debian security",
    "whonix": "Whonix",
    "tor": "Tor Project",
    "local": "Local media",
    "custom": "Custom",
    "unread": "Not read",
}


def _classify(uri, path):
    """Name the family a source belongs to, from its URI.

    Deliberately conservative: anything not recognised is `custom`, which is
    the honest answer and is also the category the user most wants to see. A
    wrong confident label here would be worse than no label, because the whole
    point of the view is telling apart software the distribution ships from
    software somebody added.
    """
    try:
        parsed = urlsplit(uri)
        host = (parsed.hostname or "").rstrip(".")
        host = host.encode("idna").decode("ascii").lower()
    except (AttributeError, TypeError, UnicodeError, ValueError):
        return "custom"

    def under(domain):
        return host == domain or host.endswith("." + domain)

    if parsed.scheme.lower() in ("file", "cdrom"):
        return "local"
    if under("kodachi.cloud"):
        return "kodachi"
    if under("security.debian.org") or (
            under("debian.org") and
            "debian-security" in [part for part in parsed.path.split("/")
                                   if part]):
        return "security"
    if under("debian.org"):
        return "debian"
    if under("whonix.org"):
        return "whonix"
    if under("torproject.org"):
        return "tor"
    return "custom"


def _deb822_scan(text):
    """(stanzas, declined) for a .sources file, including commented-out ones.

    `declined` is the first line of every COMMENTED block this refused to read
    as a repository, so the caller can say it is there instead of dropping it
    without a word.

    A COMMENTED-OUT STANZA IS A DISABLED REPOSITORY, NOT AN ABSENT ONE, and
    this used to drop every commented line on the floor, so a whole stanza
    commented out with a leading `#` on each line simply did not exist as far
    as this window was concerned. The one-line .list parser has always
    reported that same shape as `enabled=False` and kept it visible, which is
    the behaviour a person managing repositories needs: you cannot switch
    something back on that the list does not show you. Debian 13 defaults to
    deb822, so this is the format where it matters most.

    A block whose every non-blank line is commented is parsed with one leading
    `#` removed and marked `_commented`. A block that merely CONTAINS a
    comment line (a human note above `Types:`) keeps the old behaviour: the
    comment is ignored and the stanza is live.
    """
    out = []
    declined = []
    block = []

    def flush():
        if not block:
            return
        commented = all(line.lstrip().startswith("#") for line in block)
        stanza = {}
        last = None
        # True while every non-blank line in this block has parsed as a KNOWN
        # deb822 field. It decides one thing only, at the bottom: whether a
        # commented block is a disabled repository or is prose.
        syntax_valid = True
        known_fields_only = True
        for raw in block:
            line = raw.rstrip()
            if commented:
                line = line.lstrip()[1:]
                if line[:1] == " ":
                    line = line[1:]
            elif line.lstrip().startswith("#"):
                continue
            if not line.strip():
                continue
            if line[:1] in (" ", "\t"):
                # A FOLDED CONTINUATION LINE IS A VALUE, NOT NOISE. This used
                # to `continue`, under a comment calling it a continuation,
                # which DELETED it. Raised by <agent>, 2026-08-21,
                # executed: `URIs: https://good/debian` folded with a second
                # line ` https://evil/debian` reported ONE uri, and
                # `Components: main` folded with ` contrib` and ` non-free`
                # reported only main. Folding a list field across lines is
                # legal deb822 and needs no adversary to appear.
                #
                # The direction is what made it worth fixing first: this is a
                # repository MANAGEMENT window, and dropping continuations
                # UNDER-reports what apt reads, so the operator auditing their
                # sources saw a shorter, cleaner, safer list than the machine
                # actually has.
                #
                # Joined with a space because every list field here (URIs,
                # Suites, Components, Architectures) is whitespace-separated
                # and both this file's consumer and apt split it that way.
                # parse_packages() joins with "\n" instead, and the two are not
                # inconsistent: the field it folds is Description, which is
                # prose, and a newline is the separator that means something
                # there.
                if last:
                    stanza[last] = (stanza[last] + " " + line.strip()).strip()
                else:
                    syntax_valid = False  # a continuation of nothing
                continue
            key, sep, value = line.partition(":")
            if not sep:
                # NO COLON IS NOT A FIELD. This used to store {"garbage line":
                # ""}, so a corrupt file parsed into a plausible stanza rather
                # than showing as corrupt. apt refuses a file like this
                # outright; this window is a viewer and not the validator, so
                # it drops the line and lets the block be judged on the fields
                # that did parse.
                syntax_valid = False
                continue
            key = key.strip().lower()
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", key):
                syntax_valid = False
                continue
            if key not in DEB822_FIELDS:
                known_fields_only = False
            stanza[key] = value.strip()
            last = key
        # A COMMENTED BLOCK IS A DISABLED REPOSITORY ONLY IF IT IS ONE ALL THE
        # WAY THROUGH. The old test was `"uris" in stanza`, and its comment
        # claimed it stopped a licence header becoming a repository. It did
        # not. Raised by <agent>, 2026-08-21, executed: a commented
        # FORMAT REFERENCE block, `# Format reference:` above `# Types: deb`
        # and `# URIs: https://example/repo`, parsed to the same shape as a
        # genuinely disabled stanza, byte for byte, and this window exists so
        # that a disabled repository can be switched back ON with one click. An
        # example URL in somebody's comment was being offered as a real
        # repository to enable.
        #
        # Content alone cannot separate the two, because a disabled stanza and
        # a documented example ARE the same text. So the predicate is
        # structural: every line of the block must be a known deb822 field, and
        # Types and URIs must both be present. THE COST IS NAMED: a genuinely
        # disabled stanza that carries a human note on a line inside the same
        # block, with no blank line between them, loses its row. That is the
        # direction that hides something already switched off, rather than the
        # direction that invents a repository which never existed.
        #
        # It also has to land WITH the folded-continuation fix above, not after
        # it. Before that fix, an INDENTED commented reference block produced
        # nothing at all, because stripping `# ` left the leading spaces and
        # every line then looked like a continuation and was deleted. The bug
        # that hid this one in its most common shape was the bug above it.
        required = {"types", "uris", "suites", "components"}
        # COMPONENTS IS NOT REQUIRED FOR A FLAT REPOSITORY. A Suites value
        # ending in `/` is apt's flat form, which carries no components by
        # design, and requiring one DECLINED the stanza: a declined stanza is
        # drawn as a "commented block, not read by this window" row that no
        # button acts on, so a legal live repository became unmanageable in
        # the one window that exists to manage it. The one-line parser below
        # carries the same exemption and the same reason.
        if str(stanza.get("suites", "")).strip().endswith("/"):
            required.discard("components")
        missing = sorted(required.difference(stanza))
        keep = (stanza and syntax_valid and not missing
                and (not commented or known_fields_only))
        if keep:
            stanza["_commented"] = commented
            out.append(stanza)
        elif block:
            # THE LOSS ABOVE IS NAMED, SO IT MUST NOT ALSO BE SILENT. The
            # predicate is deliberately strict and its cost is a genuinely
            # disabled stanza that carries a human note on a line inside the
            # same block. Raised by <agent>, 2026-08-21: "silence is
            # what makes a lost row dangerous, not the loss", because the
            # operator concludes the repository is GONE rather than hidden, and
            # the one thing they cannot do is look for something the window
            # never mentioned. The block is recorded here and system_sources()
            # draws one row per file saying it is there and was not read, which
            # turns a wrong answer into a degraded one.
            if not syntax_valid:
                reason = "malformed deb822 field"
            elif commented and not known_fields_only:
                reason = "commented prose uses non-repository fields"
            else:
                reason = "missing required field%s: %s" % (
                    "s" if len(missing) != 1 else "", ", ".join(missing))
            declined.append({
                "commented": commented,
                "first": block[0].strip(),
                "reason": reason,
            })
        del block[:]

    for raw in apt_lines(text):
        if not raw.strip():
            flush()
            continue
        block.append(raw)
    flush()
    return out, declined


def _source_fields(line):
    """Split a one-line entry the way apt treats a bracketed region: one word.

    apt's ParseQuoteWord keeps `[...]` together, which is why the
    debian-installer's own line

        deb cdrom:[Debian GNU/Linux 13.0.0 _Trixie_ - Official amd64 DVD]/ trixie main

    is a legal three-field entry and not eleven. A plain `line.split()` cut it
    into `cdrom:[Debian`, a suite of `GNU/Linux` and a components column
    holding the rest of the disc name, so the row was drawn with garbage in
    every column while apt fetched from it perfectly well (measured
    2026-08-26: rc=0).

    The `[options]` block gets the same treatment for free, and the caller's
    unclosed-block branch still fires: an unterminated `[` leaves depth above
    zero to the end of the line, so the whole remainder arrives as one token
    that does not end in `]`.
    """
    fields, token, depth = [], "", 0
    for char in line:
        if char == "[":
            depth += 1
        elif char == "]":
            depth = max(0, depth - 1)
        if char.isspace() and depth == 0:
            if token:
                fields.append(token)
                token = ""
            continue
        token += char
    if token:
        fields.append(token)
    return fields


def _source_type(line):
    """`deb`, `deb-src`, or None. The type is a TOKEN, never a prefix.

    `line.startswith("deb ")` is false for `deb\thttp://host/debian ...`,
    which apt reads as a live repository. See the call site for what that cost
    on the helper's side of the same predicate.
    """
    head = line.split(None, 1)[0] if line.split(None, 1) else ""
    return head if head in ("deb", "deb-src") else None


def _deb822_stanzas(text):
    """Every stanza `_deb822_scan` was willing to read. See it for the rules."""
    return _deb822_scan(text)[0]


def system_sources(directory=None, list_file=None):
    """Every apt source on this machine, enabled or not.

    Returns one entry per (file, uri, suite) with:
        path, filename, format ("deb822" | "one-line"), enabled, types,
        uri, suite, components, signed_by, kind, kind_label, line

    A commented-out one-line entry is reported with enabled=False rather than
    skipped, because "the repository is there but switched off" is a different
    fact from "there is no such repository", and the user needs to tell them
    apart to manage them.
    """
    # A caller who names a directory is pointing at a FIXTURE, so the matching
    # sources.list is the one beside it. Falling back to the machine's real
    # /etc/apt/sources.list here would silently mix live repositories into a
    # test's expected set, and the test would still look like it passed.
    explicit = directory is not None
    directory = directory or sources_dir()
    if list_file is None:
        if explicit or os.environ.get("KODACHI_REPO_SOURCES_DIR"):
            list_file = os.path.join(
                os.path.dirname(directory.rstrip("/")), "sources.list")
        else:
            list_file = os.environ.get("KODACHI_REPO_SOURCES_LIST") or SOURCES_LIST
    entries = []

    def read_error(path, error, mutation_reason=""):
        return {
            "path": path,
            "filename": os.path.basename(path.rstrip("/")) or path,
            "format": "read-error",
            "enabled": False,
            "switchable": False,
            "mutable": False,
            "mutation_reason": mutation_reason or
                "this source path could not be inspected safely",
            "types": "-",
            "uri": "repository source could not be read",
            "suite": "-",
            "components": "%s: %s" % (type(error).__name__, error),
            "signed_by": "",
            "architectures": "",
            "architectures_add": "",
            "architectures_remove": "",
            "options": {},
            "kind": "unread",
            "kind_label": "Unread",
            "line": "",
        }

    def invalid_entry(path, source_format, reason, line="",
                      mutation_reason=""):
        return {
            "path": path,
            "filename": os.path.basename(path.rstrip("/")) or path,
            "format": "invalid",
            "enabled": False,
            "switchable": False,
            "mutable": False,
            "mutation_reason": mutation_reason or
                "apt would reject this malformed source entry",
            "types": "-",
            "uri": "malformed %s source" % source_format,
            "suite": "-",
            "components": reason,
            "signed_by": "",
            "architectures": "",
            "architectures_add": "",
            "architectures_remove": "",
            "options": {},
            "kind": "unread",
            "kind_label": "Not read",
            "line": line,
        }

    def source_object(path):
        """Return (readable, mutable, reason), without opening special files."""
        try:
            mode = os.lstat(path).st_mode
        except OSError as exc:
            entries.append(read_error(path, exc))
            return None
        if stat.S_ISREG(mode):
            return True, True, ""
        if stat.S_ISLNK(mode):
            return True, False, (
                "apt follows this symlink, but the repository helper refuses "
                "symlink mutation")
        # apt ignores directory, FIFO, socket and device entries under
        # sources.list.d. Never open them: opening a FIFO can block forever.
        return None

    paths = []
    if os.path.lexists(list_file):
        policy = source_object(list_file)
        if policy:
            paths.append((list_file, policy))
    try:
        for name in sorted(os.listdir(directory)):
            if SOURCE_FILENAME_RE.fullmatch(name):
                path = os.path.join(directory, name)
                policy = source_object(path)
                if policy:
                    paths.append((path, policy))
    except OSError as exc:
        entries.append(read_error(directory, exc))

    for path, (_readable, mutable, mutation_reason) in paths:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError as exc:
            entries.append(read_error(path, exc, mutation_reason))
            continue

        if path.endswith(".sources"):
            stanzas, declined = _deb822_scan(text)
            for declined_block in declined:
                # ONE ROW PER UNREAD BLOCK, and it is deliberately not a
                # repository: no uri, no suite, nothing that could be acted on.
                # It exists so the file is never quietly shorter than it looks.
                # _on_source_state() refuses this row by format and says why,
                # rather than sending a verb that would be a no-op.
                entries.append({
                    "path": path,
                    "filename": os.path.basename(path),
                    "format": ("commented-block" if declined_block["commented"]
                               else "invalid"),
                    "enabled": False,
                    "switchable": False,
                    "mutable": False,
                    "mutation_reason": (
                        mutation_reason or
                        "apt would reject or ignore this source block"),
                    "types": "-",
                    "uri": ("commented block, not read by this window"
                            if declined_block["commented"] else
                            "malformed deb822 source"),
                    "suite": "-",
                    "components": declined_block["reason"],
                    "signed_by": "",
                    "architectures": "",
                    "architectures_add": "",
                    "architectures_remove": "",
                    "options": {},
                    "kind": "unread",
                    "line": declined_block["first"],
                })
            for stanza in stanzas:
                uris = stanza.get("uris", "")
                if not uris:
                    continue
                options = {
                    key: value for key, value in stanza.items()
                    if not key.startswith("_") and key not in APT_STANDARD_FIELDS
                }
                enabled = stanza.get("enabled", "yes").strip().lower() \
                    not in DISABLING_VALUES
                # A stanza that is commented out is off whatever its own
                # Enabled: line says, and it says nothing in the usual case.
                if stanza.get("_commented"):
                    enabled = False
                for uri in uris.split():
                    for suite in (stanza.get("suites", "") or "-").split():
                        entries.append({
                            "path": path,
                            "filename": os.path.basename(path),
                            "format": "deb822",
                            "switchable": mutable,
                            "mutable": mutable,
                            "mutation_reason": mutation_reason,
                            "enabled": enabled,
                            "types": stanza.get("types", "deb"),
                            "uri": uri,
                            "suite": suite,
                            "components": stanza.get("components", ""),
                            "signed_by": stanza.get("signed-by", ""),
                            "architectures": stanza.get("architectures", ""),
                            "architectures_add": stanza.get(
                                "architectures-add", ""),
                            "architectures_remove": stanza.get(
                                "architectures-remove", ""),
                            "options": dict(options),
                            "kind": _classify(uri, path),
                            "line": "",
                        })
            continue

        for raw in apt_lines(text):
            line = raw.strip()
            if not line:
                continue
            enabled = True
            # SWITCHABLE IS NOT THE SAME FACT AS ENABLED, and conflating them
            # is C4 (<agent>, 2026-08-21, executed). A .list shipped
            # with a commented `deb` and a commented `deb-src` for one URI draws
            # TWO disabled rows, but `source-enable` acts on the FILE and
            # deliberately never switches on a deb-src line the distribution
            # shipped commented. So pressing Enable from the deb-src row moved
            # the OTHER row, reported real success, and left the clicked row
            # disabled. It failed while looking correct.
            switchable = True
            if line.startswith(DISABLED_MARK):
                # This window switched it off, so this window can switch it
                # back on, deb-src included: that is what the mark is for.
                line = line[len(DISABLED_MARK):].strip()
                if _source_type(line) is None:
                    continue
                enabled = False
            elif line.startswith("#"):
                stripped = line.lstrip("#").strip()
                # `startswith("deb")` IS TOO LOOSE IN THE OTHER DIRECTION, and
                # this is the half nobody looked for while fixing the half that
                # was too tight. It matches any English comment beginning with
                # those three letters, so `# debugging note, ignore this` and
                # `# debian mirror was moved last week` were BOTH drawn as
                # rows reading "malformed one-line source". Measured 2026-08-26
                # on a three-line fixture: 4 rows returned where 2 are real.
                #
                # That is not cosmetic. The summary strip counts "%d invalid or
                # non-repository rows", so the operator is warned about a
                # problem he does not have, and <agent> measured on
                # 2026-08-25 that the invalid-row count feeds the window's
                # MINIMUM WIDTH through an unellipsized label: four such rows
                # forced the toplevel 221px wider than its designed opening
                # size. Comments starting with "deb" are ordinary in a
                # sources.list, which is the file people annotate the most.
                if _source_type(stripped) is None:
                    continue            # an ordinary comment, not a source
                enabled = False
                line = stripped
                # A deb-src line the DISTRIBUTION shipped commented stays that
                # way: switching it on doubles every index fetch and 404s on
                # repositories that publish no sources. The row is still drawn,
                # because "present but off" is a fact the operator needs, and
                # the window refuses the button on it and says why.
                switchable = _source_type(stripped) != "deb-src"
            # A BARE `#` STARTS A COMMENT FOR apt, WITH OR WITHOUT A SPACE
            # IN FRONT OF IT. This split only on `\s+#`, so
            # `deb http://host/a#b trixie main` kept the `#b` and parsed into
            # a healthy-looking enabled row with a uri of
            # `http://host/a#b`. Measured 2026-08-26: apt cuts at the `#`,
            # is left with two fields, and refuses THE ENTIRE SOURCES LIST
            # with `E: Malformed entry 1` plus `E: The list of sources could
            # not be read`. So apt was completely dead on that machine,
            # including this window's own Check for updates, while every row
            # here read healthy and the header said `N enabled, M disabled`
            # with no INCOMPLETE marker. The one tool that exists to find the
            # bad file pointed at nothing.
            line = line.split("#", 1)[0].rstrip()
            # THE TYPE IS A TOKEN, NOT A PREFIX. `startswith("deb ")` reads
            # `deb\thttp://host/debian trixie main` as an unknown repository
            # type, and apt reads it as a live repository (measured: rc=0, 7
            # URIs). The parser is not the worst half of that: the helper's
            # `_one_line_is_a_source` had the identical predicate, so Disable
            # walked past the line, reported `already disabled, nothing to
            # do`, exit 0, and the window painted a green `done:` over a
            # repository that was still being fetched, trusted and installed
            # from. Both copies are token-split now.
            if _source_type(line) is None:
                entries.append(invalid_entry(
                    path, "one-line", "unknown repository type", raw.strip(),
                    mutation_reason))
                continue
            fields = _source_fields(line)
            kind_type = fields[0]
            rest = fields[1:]
            signed_by = ""
            options = {}
            if rest and rest[0].startswith("["):
                option_tokens = []
                while rest and not rest[0].endswith("]"):
                    option_tokens.append(rest.pop(0))
                if not rest:
                    entries.append(invalid_entry(
                        path, "one-line", "unclosed option block", raw.strip(),
                        mutation_reason))
                    continue
                option_tokens.append(rest.pop(0))
                blob = " ".join(option_tokens).strip("[]")
                options = {}
                malformed_option = ""
                for token in blob.split():
                    key, separator, value = token.partition("=")
                    if not separator or not key or not value:
                        malformed_option = token
                        break
                    key = key.lower()
                    options[key] = value
                    if key == "signed-by":
                        signed_by = value
                if malformed_option:
                    entries.append(invalid_entry(
                        path, "one-line",
                        "apt option lacks key=value: %s" % malformed_option,
                        raw.strip(), mutation_reason))
                    continue
            # A SECOND `[...]` BLOCK IS NOT A URI. apt refuses
            # `deb [arch=amd64] [trusted=yes] http://host/d trixie main` with
            # `E: Malformed entry 1 ... (URI parse)` and the whole list dies
            # with it, while this parser walked on and drew
            # uri=`[trusted=yes]`, suite=`http://host/d`, enabled, healthy.
            # Same consequence as the bare `#` above: apt is dead and the
            # window says everything is fine.
            if rest and rest[0].startswith("["):
                entries.append(invalid_entry(
                    path, "one-line",
                    "a second apt option block where the URI belongs: %s"
                    % rest[0], raw.strip(), mutation_reason))
                continue
            # A FLAT REPOSITORY HAS NO COMPONENTS AND IS NOT MALFORMED.
            # `deb <uri> <directory>/`, with the second field ending in `/`,
            # is apt's flat form and carries exactly two fields after the
            # type. Measured 2026-08-26: apt fetches
            # `deb http://x/repo ./` as http://x/repo/./InRelease, rc=0,
            # while this branch labelled the identical bytes "missing
            # Components field". An invalid row is refused by
            # `_on_source_state` and `_on_source_remove` before any verb is
            # sent, so a legal, live, currently-fetching repository was
            # unmanageable and reported as broken. The standard OBS layout is
            # exactly this shape.
            flat = len(rest) == 2 and rest[1].endswith("/")
            if len(rest) < 3 and not flat:
                entries.append(invalid_entry(
                    path, "one-line", "missing Components field", raw.strip(),
                    mutation_reason))
                continue
            uri = rest[0]
            suite = rest[1] if len(rest) > 1 else "-"
            entries.append({
                "path": path,
                "filename": os.path.basename(path),
                "format": "one-line",
                "enabled": enabled,
                "switchable": switchable and mutable,
                "mutable": mutable,
                "mutation_reason": mutation_reason,
                "types": kind_type,
                "uri": uri,
                "suite": suite,
                "components": " ".join(rest[2:]),
                "signed_by": signed_by,
                "architectures": options.get("arch", ""),
                "architectures_add": options.get("arch+", ""),
                "architectures_remove": options.get("arch-", ""),
                "options": options,
                "kind": _classify(uri, path),
                "line": raw.strip(),
            })

    for entry in entries:
        entry["kind_label"] = KIND_LABELS.get(entry["kind"], "Custom")
    return entries


# ── WHAT AN apt FAILURE MEANS, AND WHAT TO DO ABOUT IT ─────────────────────
#
# `pending_updates()` returns apt's own last line on failure, and the window
# used to render that as the four words "could not check" in the status strip.
# On the operator's machine on 2026-08-30 the real reason was
# `E: Unmet dependencies. Try 'apt --fix-broken install' with no packages`,
# caused by an interrupted chromium upgrade, and the window said nothing that
# would let anybody act on it: not what was wrong, not that this window has a
# button that fixes exactly this, not even the word "dependencies". His note on
# the screenshot was "why this [expletive] error fix it !".
#
# Each entry is (needles, short, remedy). `short` is a chip value, so it is
# written to fit one: no sentence, no punctuation, no apt jargon. `remedy` is a
# full sentence for the page, and where this window can perform the repair it
# names the control by the label the user will read on screen.
#
# ORDER MATTERS. A disk-full apt run also leaves a broken dpkg state, so it
# reports BOTH conditions and the actionable one is the disk. Specific causes
# are therefore listed before the states they produce.
# HOW LONG A CHIP VALUE MAY BE, AND IT IS SHORT ON PURPOSE.
#
# The status strip lays four facts across a row inside the content column,
# which is the window's 944px minus a 155px sidebar, so a row has roughly 760px
# for four labels AND four values. MEASURED 2026-08-30 on the live window on
# <lab-host>: "broken packages, repair needed" rendered as
# "PENDING UPDATES  broken packages, repair n...", i.e. the fix for unreadable
# chips shipped a chip that was still unreadable, on the very cell the operator
# photographed.
#
# It was not caught by the clipping contract because that contract renders
# whatever state the machine is in, and at strip-draw time the error had not
# arrived yet, so it measured the word "checking". A contract that renders only
# the current state cannot see the worst case; the contract now forces every
# classified reason through the strip in turn.
#
# So a `short` is a FEW WORDS. The sentence explaining what to do lives on the
# Updates page and in the tooltip, where there is room for it.
CHIP_BUDGET = 20

APT_ERROR_CLASSES = (
    (("no space left on device", "not enough free space",
      "you don't have enough free space"),
     "no disk space",
     "This machine has run out of disk space, so apt cannot unpack anything. "
     "Maintenance > Clear download cache deletes the .deb files apt has "
     "already downloaded, which is the safest space to reclaim first."),
    (("could not get lock", "unable to lock", "another process is using it",
      "resource temporarily unavailable"),
     "apt is busy",
     "Another package manager is holding the apt lock. Wait for it to finish, "
     "then press Refresh status. Nothing here is broken."),
    (("unmet dependencies", "held broken packages", "--fix-broken",
      "broken packages", "dpkg was interrupted"),
     "broken packages",
     "A package transaction on this machine was interrupted or resolved to a "
     "conflicting set, so apt refuses to plan anything else until it is "
     "repaired. Maintenance > Repair packages runs dpkg --configure -a and "
     "apt-get -f install, the two commands apt itself recommends. apt may "
     "remove a package to resolve the breakage and asks first."),
    (("401", "unauthorized", "authentication"),
     "login refused",
     "A repository answered 401. If this is the dev channel, its stored "
     "credentials are missing, wrong or incomplete: use Dev credentials to "
     "store them again."),
    (("could not resolve", "temporary failure resolving", "connection failed",
      "network is unreachable", "connection timed out"),
     "no network",
     "apt could not reach the repository servers. Check the connection, then "
     "press Update from servers."),
    # THE REMEDY DEPENDS ON WHOSE REPOSITORY FAILED, so this entry's remedy is
    # the SOURCE-NEUTRAL one and `classify_apt_error` upgrades it when apt's
    # own words name a Kodachi URL. It used to say "Add channel re-writes the
    # Kodachi source with the signing key this application pins" for EVERY
    # signature failure, including a Debian or third-party one, where that
    # button cannot repair the source that failed and would instead add or
    # rewrite an unrelated Kodachi one. The classifier holds no repository
    # identity of its own, so the only honest default is to send the reader to
    # the source apt actually named. <agent>, 2026-08-30.
    # NOT AN apt FAILURE AT ALL: the WINDOW could not start its own worker.
    # `refresh_updates` puts "could not start updates check: <exception>" in
    # the same field apt errors use, and the fallthrough quotation then trimmed
    # it to the chip budget and produced "could not start u...", which is
    # worse than useless. Measured 2026-08-30: that string is what
    # test_every_thread_start_failure_settles_its_visible_state renders after
    # CHIP_BUDGET came down to 20. A named class gives it a readable chip and
    # a remedy the user can act on; the exception itself is still on the
    # Updates page and in the tooltip.
    (("could not start updates check", "could not read pending updates"),
     "check did not start",
     "This window could not start its own background check, which is a fault "
     "in the application rather than in apt or any repository. Nothing on "
     "this machine changed. Recount only tries again without touching the "
     "network; if it keeps failing, close and reopen the window."),
    (("no_pubkey", "gpg error", "not signed", "signatures were invalid"),
     "bad signature",
     "apt refused an index because it is unsigned or signed by a key this "
     "machine does not have. The message above names the repository; open "
     "System Sources to see that entry and the key it expects."),
)

# The extra sentence, added ONLY when apt's message names a Kodachi host, so
# the control it points at is the control that can actually repair the source
# that failed.
KODACHI_SIGNATURE_REMEDY = (
    " This is a Kodachi repository, so Add channel can rewrite its source "
    "with the signing key this application pins.")

# DERIVED FROM THE CHANNEL TABLE, AND HOSTNAMES ONLY.
#
# My first version of this list also carried the bare path fragments
# "repo-dev" and "repo-beta". The classifier scans apt's WHOLE diagnostic, not
# a parsed URL, so `https://packages.example.net/repo-dev` would have matched
# and taken the Kodachi-only arm: the false guidance this branch exists to
# remove, recreated under an ordinary third-party path. <agent>,
# 2026-08-30. Only the DOMAIN identifies a repository as ours, and it is read
# out of CHANNELS rather than retyped, so adding a channel on a new host
# cannot leave this list behind.
def _kodachi_hosts():
    hosts = set()
    for spec in CHANNELS.values():
        url = spec.get("url") or ""
        host = urlsplit(url).hostname
        if host:
            hosts.add(host.lower())
    return frozenset(hosts)


KODACHI_HOSTS = _kodachi_hosts()


def _names_a_kodachi_repository(text):
    """Does apt's message name a repository on a Kodachi HOST?

    PARSED HOSTNAMES, NOT A SUBSTRING SEARCH, and the difference is the whole
    contract. `"kodachi.cloud" in text` is true of
    `https://notkodachi.cloud/repo` and of
    `https://evil.example/repo?next=kodachi.cloud`, so a substring test hands
    the Kodachi-only repair to a third-party source: exactly the false guidance
    this branch exists to remove, one level subtler. <agent> found both
    shapes, 2026-08-30, and noted this repository already carries them as
    adversarial fixtures elsewhere in its own suite.

    Every URL-shaped token is parsed and its hostname compared for EQUALITY, so
    a lookalike domain, a subdomain of somebody else's, and a Kodachi host in a
    query string all fail. A userinfo trick (`https://kodachi.cloud@evil/`) also
    fails, because urlsplit puts `evil` in `.hostname` and `kodachi.cloud` in
    `.username`, which is the correct reading.
    """
    for token in re.findall(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s'\"<>]+", text or ""):
        try:
            host = urlsplit(token).hostname
        except ValueError:
            continue
        if host and host.lower() in KODACHI_HOSTS:
            return True
    return False


def classify_apt_error(text):
    """(short, remedy) for one apt failure. Never raises, never returns None.

    Falls through to apt's own words rather than to a generic phrase: an
    unrecognised error is still far more useful printed than summarised, and a
    catch-all like "could not check" is exactly the string this function
    exists to remove from the screen.
    """
    body = (text or "").strip()
    if not body:
        return "could not check", ""
    lowered = body.lower()
    for needles, short, remedy in APT_ERROR_CLASSES:
        if any(needle in lowered for needle in needles):
            if (short == "bad signature"
                    and _names_a_kodachi_repository(body)):
                return short, remedy + KODACHI_SIGNATURE_REMEDY
            return short, remedy
    # apt prefixes its own diagnostics with `E: `; the prefix is noise on a
    # chip and the sentence after it is the part worth showing.
    first = body.splitlines()[0].strip()
    if first.startswith("E:"):
        first = first[2:].strip()
    return (first if len(first) <= CHIP_BUDGET
            else first[:CHIP_BUDGET - 3].rstrip() + "..."), ""


def pending_updates(timeout=90):
    """What apt would upgrade right now, grouped by the repository it comes from.

    Runs `apt-get -s upgrade`, which is a SIMULATION: it needs no root, takes no
    lock that matters, installs nothing, and reports exactly the set apt itself
    would act on. Parsing `apt list --upgradable` instead would mean parsing a
    localised, explicitly unstable human format.

    Returns (entries, error). `error` is a string when apt could not be asked at
    all, and the caller prints it rather than an empty list, because "no updates"
    and "could not check" must never look the same on screen.
    """
    # THE SAME BLIND SPOT THE FAVOURITES PAGE HAD, and here it is worse.
    # With no downloaded indexes `apt-get -s upgrade` EXITS 0 and emits zero
    # `Inst ` lines, so `error` stays empty, `updates` stays empty, and the page
    # renders "nothing to upgrade". That is a FALSE GREEN about pending security
    # updates on a machine that has never checked, which is the exact failure the
    # docstring above forbids: "no updates" and "could not check" must never look
    # the same on screen. A live session and a fresh install are both in this
    # state until the first `apt update`.
    #
    # Reported by the inspector against commit 42f4db796 as the unfixed sibling
    # of the operator-reported GIMP case, and fixed here rather than deferred,
    # because it is the same class and this task is what surfaced it.
    if not apt_lists_present():
        return [], ("apt has no package lists yet, so it cannot say what is "
                    "upgradable. Refresh the lists (System sources > Refresh, "
                    "or `sudo apt update`) and check again.")
    command = ["/usr/bin/apt-get", "-s", "-q", "-o", "Dpkg::Use-Pty=0", "upgrade"]
    env = dict(os.environ, LC_ALL="C.UTF-8", DEBIAN_FRONTEND="noninteractive")
    try:
        completed = subprocess.run(command, capture_output=True, text=True,
                                   errors="replace", timeout=timeout, env=env)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return [], "could not run apt-get -s upgrade: %s" % exc
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip().splitlines()
        return [], (detail[-1] if detail else
                    "apt-get -s upgrade exited %d" % completed.returncode)

    updates = []
    for line in completed.stdout.splitlines():
        if not line.startswith("Inst "):
            continue
        # Inst <name> [<old>] (<new> <origin> [<arch>])
        rest = line[5:].strip()
        name, _, tail = rest.partition(" ")
        current = ""
        if tail.startswith("["):
            current = tail[1:tail.index("]")] if "]" in tail else ""
            tail = tail[tail.index("]") + 1:].strip() if "]" in tail else tail
        new_version, origin = "", ""
        if tail.startswith("("):
            inner = tail[1:tail.rindex(")")] if ")" in tail else tail[1:]
            parts = inner.split()
            if parts:
                new_version = parts[0]
            if len(parts) > 1:
                origin = " ".join(parts[1:])
                if origin.endswith("]") and "[" in origin:
                    origin = origin[:origin.rindex("[")].strip()
        updates.append({
            "name": name,
            "installed": current,
            "candidate": new_version,
            "origin": origin or "unknown",
            "kind": "kodachi" if origin.lower().startswith("kodachi")
                    else ("security" if "security" in origin.lower() else "other"),
        })
    return updates, ""


# ---------------------------------------------------------------------------
# FAVOURITE APPS
#
# The applications a Kodachi user most often wants and that Debian already
# ships. Chosen 2026-08-21 on operator instruction, which replaced the ISO's
# one-click installer framework outright:
#
#     "in live iso we should remove all install by one click from the iso, now
#      we have the kodachi repo and the kodachi gtk repo manager so we stick to
#      that. anything that is available in debian repo users will use debian
#      repo. anything that is not available in debian repo we add it to kodachi
#      repo. in the gtk kodachi repo manager we add a tab or section we call it
#      favourite apps and in there we add the one click apps that are available
#      in the debian repo but not installed like vlc gimp etc."
#
# So this table is DEBIAN-ONLY BY DEFINITION. An application that Debian does
# not ship does not belong here; it belongs in the Kodachi `apps` component,
# declared in installers/vendor-apps-catalog.sh, and it reaches the user
# through the package table on the Stable channel exactly like gitkraken and
# codium do today. Adding a non-Debian name here would recreate the ISO defect
# this whole change exists to remove.
#
# WHY EVERY NAME IS RESOLVED AT RUNTIME RATHER THAN TRUSTED
#
# A catalog entry is a CLAIM ABOUT A PACKAGE NAME, and this project has now
# shipped that claim wrong three times: `exifcleaner` was registered against a
# name in no repository (recorded in Kodachi-APT-Repository-Playbook), `code`
# was registered on two ISO variants for a package Debian does not carry, and
# `tabby` was registered under a name the upstream deb does not declare. All
# three shipped a button that could never work, and nothing detected any of
# them, because nothing ever asked apt whether the name resolved.
#
# favourite_rows() therefore asks apt about every name on every refresh and
# reports UNAVAILABLE for anything apt cannot see, rather than drawing an
# Install button over a name that resolves nowhere. That state is not an error
# path to be tidied away later: it is the whole lesson, made visible.
#
# THE COMPONENT TRAP, measured 2026-08-21 and worth stating because it inverts
# the answer. `apt-cache policy nautilus-dropbox` on the DEVELOPMENT host
# returns Candidate:(none), which reads exactly like "Debian does not have it".
# Debian does have it, in NON-FREE; that host's sources simply carry
# `main non-free-firmware`. The ISO enables `main contrib non-free
# non-free-firmware` (config/bootstrap LB_ARCHIVE_AREAS), so the shipped system
# resolves names the development host cannot. A machine's own apt is the only
# honest oracle for that machine, which is the other reason this is resolved at
# runtime on the user's box rather than baked in from a build-host measurement.
# ---------------------------------------------------------------------------

# (app id, title, package names, category, one-line purpose)
FAVOURITE_APPS = (
    ("vlc", "VLC Media Player", ("vlc",), "Media",
     "Plays practically every audio and video format without extra codecs."),
    ("audacity", "Audacity", ("audacity",), "Media",
     "Multi-track audio recording and editing."),
    ("gimp", "GIMP", ("gimp",), "Graphics",
     "Photo retouching and raster image editing."),
    ("inkscape", "Inkscape", ("inkscape",), "Graphics",
     "Vector drawing and SVG editing."),
    ("bluefish", "Bluefish Editor", ("bluefish",), "Development",
     "Lightweight editor for web pages and scripts."),
    ("docker", "Docker Engine and Compose", ("docker.io", "docker-compose"),
     "Development",
     "Containers, from Debian's own build rather than Docker's repository."),
    # TEN PACKAGES, ONE ROW, on purpose: a virtualization host is unusable
    # with a subset. virt-manager alone cannot start a guest without
    # qemu-system-x86 and libvirt-daemon-system, so a user who installed the
    # obvious one and nothing else would get a window that fails at the point
    # of use rather than at the point of install.
    ("virt-stack", "QEMU and Virt Manager",
     ("virt-manager", "qemu-system-x86", "qemu-utils",
      "libvirt-daemon-system", "libvirt-clients", "virtinst",
      "bridge-utils", "spice-vdagent", "qemu-guest-agent",
      "hyperv-daemons"),
     "Virtualization",
     "Run virtual machines with QEMU/KVM and manage them from a GUI."),
    # DROPBOX IS HERE BECAUSE THE OPERATOR'S RULE PUTS IT HERE, not because it
    # is a natural fit for a privacy distribution. It is a proprietary
    # cloud-sync daemon, `nautilus-dropbox` is a Debian NON-FREE downloader
    # stub that fetches that daemon on first run, and I recommended dropping
    # it. That recommendation was mine to make and not mine to enact: the rule
    # given was "anything available in debian repo users will use debian repo",
    # Debian ships it, and quietly omitting it would substitute my judgement
    # for his without saying so. Removing this row is a one-line change.
    #
    # WHICH ARCHIVE AREA THIS LIVES IN, and the correction that produced this
    # comment, because the first version of it asserted the wrong half.
    #
    # `nautilus-dropbox` is in Debian `non-free`, not `main` and not
    # `non-free-firmware`, which is a DIFFERENT archive area despite the name.
    # Every other package this catalog names is in `main`. So this row is the
    # only one whose availability depends on which areas a given machine
    # enables, and the two answers diverge:
    #
    #   The Kodachi ISO enables all four areas. `LB_ARCHIVE_AREAS="main contrib
    #   non-free non-free-firmware"` at livebuilds/kodachi-terminal-build/
    #   config/bootstrap:28, and the medium's own sources.list carries the same
    #   four on trixie, -security, -updates and -backports. On that machine the
    #   package resolves and this row installs normally.
    #
    #   A plain Debian trixie install enables `main non-free-firmware` only,
    #   which is the installer's default. `apt-cache policy nautilus-dropbox`
    #   returns no candidate there, measured 2026-08-22 on <lab-host> and
    #   <lab-host>.
    #
    # I ORIGINALLY WROTE THE OPPOSITE HERE, that the ISO does not enable
    # non-free, on the strength of that same measurement. Both machines report
    # no /run/live/rootfs, so neither is an ISO boot: they are Debian installs
    # carrying the Kodachi repo, and their sources.list is Debian's default
    # rather than this project's. The measurement was real and the artifact was
    # not the one the claim was about. Kept as a comment because the corrected
    # conclusion is the reason the row survives at all.
    #
    # THE ROW IS DELIBERATELY KEPT ANYWAY, and it degrades honestly rather than
    # failing: `favourite_rows` puts it in state `unavailable`, Install is dead,
    # and the detail line already names the cause and points at the System
    # sources page in this same window. That is the correct behaviour for a
    # package a user CAN reach after one deliberate choice, and it is why the
    # `unavailable` state was added in this window in the first place.
    ("dropbox", "Dropbox", ("nautilus-dropbox",), "Network",
     "Proprietary cloud sync. Debian non-free; fetches its daemon on first run. "
     "Needs the non-free archive area enabled."),
)


def favourite_packages():
    """Every package name the catalog names, de-duplicated, in table order.

    This is the ALLOWLIST the privileged helper enforces. It is derived from
    FAVOURITE_APPS rather than written out a second time, so a row added above
    cannot be installable-but-unlisted or listed-but-uninstallable here.
    """
    names = []
    for _app_id, _title, packages, _category, _note in FAVOURITE_APPS:
        for package in packages:
            if package not in names:
                names.append(package)
    return tuple(names)


def _policy_text(packages, _run=None):
    """`apt-cache policy` output, or an explicit error when apt cannot run.

    apt-cache is used rather than a python-apt binding because this window has
    to work on a live ISO with nothing extra installed, and rather than
    dpkg-query because dpkg cannot answer "could this be installed", which is
    the only question this page exists to ask.
    """
    if not packages:
        return ""
    runner = _run or subprocess.run
    try:
        proc = runner(["apt-cache", "policy"] + list(packages),
                      stdin=subprocess.DEVNULL, capture_output=True,
                      text=True, errors="replace", timeout=30)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise RepositoryStateError(
            "apt-cache policy could not report package availability: %s: %s"
            % (type(exc).__name__, exc)) from exc
    if proc.returncode != 0:
        raise RepositoryStateError(
            "apt-cache policy exited %d: %s" %
            (proc.returncode, (proc.stderr or "").strip() or "no error text"))
    return proc.stdout or ""


def parse_policy(text):
    """{package: candidate-version-or-None} from `apt-cache policy` output.

    A package apt has never heard of produces NO stanza at all (the message
    goes to stderr), so it is simply absent from the result, and the caller
    reads absence as UNAVAILABLE. A package apt knows but cannot install
    produces a stanza with `Candidate: (none)`, which is mapped to None and
    means the same thing to the caller for a different reason: the name is
    real, the archive area carrying it is not enabled.
    """
    found = {}
    current = None
    for raw in (text or "").split("\n"):
        if not raw.strip():
            continue
        if not raw[0].isspace():
            # `vlc:` or, on a multi-arch query, `vlc:amd64:`.
            current = raw.strip().rstrip(":").split(":")[0]
            found.setdefault(current, None)
            continue
        stripped = raw.strip()
        if current and stripped.startswith("Candidate:"):
            value = stripped.split(":", 1)[1].strip()
            found[current] = None if value in ("(none)", "") else value
    return found


def favourite_rows(installed=None, policy=None):
    """One row per catalog entry, with the state the page draws.

    `installed` and `policy` are injectable so a test can drive every state
    without needing a machine in that state. Nothing else in this module needs
    that, but every state below is a state a user's machine can be in, and a
    page that has only ever been seen in one of them is a page nobody has
    tested.

    State is one of:
      installed    , every package of the entry is installed
      partial      , some are, which a plain dpkg check would report as
                     installed and which is why the count is carried
      available    , none installed, and apt can install all of them
      unavailable  , apt cannot offer at least one package, so INSTALL is
                     not drawn. See the module comment: this is the state
                     that the one-click framework never had and needed.
                     Note it OUTRANKS `partial`, so a half-installed entry
                     with one unofferable sibling lands here and still has
                     packages to remove; `installed_packages` is what the
                     Remove button must use.
    """
    have = installed_versions() if installed is None else installed
    text = policy if policy is not None else _policy_text(favourite_packages())
    candidates = parse_policy(text) if isinstance(text, str) else text

    rows = []
    for app_id, title, packages, category, note in FAVOURITE_APPS:
        present = [p for p in packages if p in have]
        missing_from_apt = [p for p in packages
                            if candidates.get(p) is None and p not in have]
        if len(present) == len(packages):
            state = "installed"
        elif missing_from_apt:
            state = "unavailable"
        elif present:
            state = "partial"
        else:
            state = "available"
        rows.append({
            "id": app_id,
            "title": title,
            "packages": tuple(packages),
            "category": category,
            "note": note,
            "state": state,
            "installed_count": len(present),
            # The NAMES, not just the count. Remove has to act on exactly
            # these: sending a name apt has no stanza for fails the whole
            # apt-get call, and that is reachable here, because a bundle
            # with one package installed and one apt cannot offer is
            # `unavailable` rather than `partial`.
            "installed_packages": tuple(present),
            "total_count": len(packages),
            "version": (have.get(packages[0], "")
                        if state in ("installed", "partial")
                        else (candidates.get(packages[0]) or "")),
            "unavailable": tuple(missing_from_apt),
        })
    return rows
