# Kodachi OS 10 (stable)

The **current stable release**. Kodachi 10.0.3, code name **Dragon**, is the first stable
release of the 10 line (27.09.2026), built on Debian 13 (Trixie). The Desktop (XFCE), Terminal /
Server and Binary Pack editions all report the same version, and the stable APT channel carries
it. The previous line is kept as a record at [../Kodachi-OS-9-legacy](../Kodachi-OS-9-legacy).

Everything in [`open/`](open) ships inside the Kodachi 10 ISO as a plaintext file, so it is
already on the disk of every person running Kodachi. Publishing it here does not disclose
anything new, it just means you can read it before you install rather than after.

> **Download:** [Desktop ISO](https://kodachi.cloud/downloads/#desktop) &middot;
> [Terminal / Server ISO](https://kodachi.cloud/downloads/#terminal) &middot;
> [Binaries and APT](https://kodachi.cloud/downloads/#binaries) &middot;
> [Beta track](https://kodachi.cloud/downloads/?track=beta#desktop) &middot;
> [Changelog](https://kodachi.cloud/docs/changelog.html)

---

## What is in `open/`

222 files, 8.0 MB. Each directory answers a question people reasonably ask about a
privacy distribution whose core services are closed-source binaries.

| Folder | Files | What it is | The question it answers |
|---|---|---|---|
| [`open/installers/`](open/installers) | 5 | The install, dependency, login-shell and diagnostic scripts | "What does the install command actually run on my machine?" |
| [`open/workflow-profiles/`](open/workflow-profiles) | 122 | Every Kodachi workflow as a JSON step list: the exact commands, their order, conditions and timeouts | "What does Kodachi do to my network when I click Enable DNSCrypt?" |
| [`open/dock/`](open/dock) | 23 | The Cairo Dock command surface: `gtk-direct-operations.json` (425 cells with their argv templates, sudo requirement and danger level), `dock-actions.tsv`, and the GTK window code in `lib/`, `libexec/` and `bin/` | "What runs when I click a dock icon, and does it need root?" |
| [`open/thunar/`](open/thunar) | 19 | The file-manager right-click actions: GPG encrypt, sign, verify, secure wipe, sandbox, open-as-root, checksum, VirusTotal | "What tool does Securely Wipe actually call, and with how many passes?" |
| [`open/conky/`](open/conky) | 51 | The always-on desktop status panel: its configs, Lua gauges and every collector script | "Is this thing phoning home?" |
| [`open/system/`](open/system) | 2 | The AppArmor profile confining the browser, and the annotated ISO package list | "What confines LibreWolf, and what is installed by default?" |

---

## What is not here, and why

**The Rust services stay closed.** 25 signed binaries provide the routing, Tor, DNS,
authentication and integrity layers, and their source is not published. What you can read is
their complete command surface: every binary, every command and every flag is documented at
[kodachi.cloud/docs](https://kodachi.cloud/docs/), with the machine-readable index at
[`/kp/docs-assets/binaries/command-library.json`](https://kodachi.cloud/kp/docs-assets/binaries/command-library.json)
(25 binaries, 575 commands).

Also absent by design: the browser profile, any credential or key material, third-party icon
sets whose licences do not permit redistribution, and internal build tooling.

## Redaction

These are projections of the working files in the private development tree, not raw copies.
Four things are rewritten on the way out, and nothing else is:

| In the source | Published as |
|---|---|
| A private lab address, e.g. a `192.168.x.x` test VM | `<lab-host>` |
| A development lane identifier | `<agent>` |
| The developer's home directory | `/home/<user>` |
| Occasional profanity in engineering comments | `[expletive]` |

Every other byte is identical to what runs. The sync is checksum-verified in both
directions: the published copy is re-hashed after it is written, and a mismatch aborts the
publication rather than reporting success.

## Licence

[KSAN-1.1](../LICENSE.md), source-available and noncommercial. Kodachi is **not** open source
and not under GPL, MIT, Apache or BSD.
