# Kodachi OS 9 (legacy)

The **previous release line**, superseded by Kodachi 10. Kodachi 9 was finished, released and
production-ready: every component shipped, from the standalone binaries and the terminal server
edition to the desktop edition, the dashboard GUI, the AI layer and the cloud platform. This
folder is kept as the record of that line.

**Kodachi 10 is now the stable release** (10.0.3, code name Dragon, released 27.09.2026), at
**[../Kodachi-OS-10-stable](../Kodachi-OS-10-stable)**. New downloads and the stable APT channel
carry Kodachi 10; get them from the **[Downloads Center](https://kodachi.cloud/downloads/)**.
The retired 8 line is archived at **[../Kodachi-OS-8-EOL](../Kodachi-OS-8-EOL)**.

## What is in this folder

```
Kodachi-OS-9-legacy/
├── README.md                     This file: the 9 development roadmap and release record
├── open/
│   └── installers/               The 5 shell scripts as they shipped for the 9 line
│                                   kodachi-binary-install.sh    binaries, no sudo needed
│                                   kodachi-deps-install.sh      system dependencies, needs sudo
│                                   kodachi-autoshield.sh        the login shell dashboard
│                                   kodachi-autoshield-shell.sh  the standalone variant
│                                   kodachi-debug-collector.sh   redacted diagnostic bundle
└── v9-behind-scenes-progress/    Engineering write-ups and demo videos from the 9 build:
                                    the challenge-response auth design, the IP-Fetch
                                    utility, and the Tor Manager rewrite
```

These installer scripts are the **Kodachi 9 versions**, kept as the historical record of
that line. The current ones live in
**[../Kodachi-OS-10-stable/open/installers/](../Kodachi-OS-10-stable/open/installers)**.

---

## Development roadmap

This roadmap provides an overview of the current status of key components in the Kodachi project. All code and infrastructure have been written from scratch; however, I have integrated the working code from the old version to avoid reinventing the wheel and accelerate development.

> ### ![Complete](https://img.shields.io/badge/-DEVELOPMENT%20COMPLETE-brightgreen?style=flat-square) Kodachi 9 is Fully Functional
> **Kodachi 9 development is complete and the platform is fully functional.** Every component below is built, deployed, and production-ready — standalone binaries, terminal server version, desktop edition (Debian XFCE), AI capabilities, and the full cloud platform.
> **[➜ Explore Kodachi 9 — Landing Page](https://kodachi.cloud/)**

> ### ![New](https://img.shields.io/badge/-NEW-red?style=flat-square) Kodachi Desktop (Debian XFCE)
> The **Kodachi Desktop Edition** is now complete — a full desktop experience built on Debian XFCE with the Gambas GUI dashboard, all Kodachi security binaries pre-integrated, and a polished user interface for privacy-first computing.
> [Download & Guide](https://kodachi.cloud/docs/desktop-debian.html)

> ### ![New](https://img.shields.io/badge/-NEW-red?style=flat-square) Kodachi OS 9 Technical Whitepaper
> A full, code-verified breakdown of how the platform works: the OS, Rust services, dashboard, routing, Tor, DNS, hardening stack, VPS fleet, and the end-to-end signing chain (RSA-4096 + BLAKE3), plus the honest threat model including what Kodachi does not protect against. Most privacy tools ask you to trust them; this shows the engineering so you can verify it.
> [Read the Whitepaper](https://kodachi.cloud/tools/whitepaper.html)

> ### ![New](https://img.shields.io/badge/-NEW-red?style=flat-square) Kodachi Downloads Center
> One hub for the Desktop ISO, Terminal Server ISO, and standalone binaries, with live download trends and by-OS / by-country statistics.
> [Open Downloads](https://kodachi.cloud/downloads/)

| Component                                                                                        | Status                                                                                     | Completion                                                                          |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| **Kodachi Workers VPS**                                                                          | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **Kodachi Master VPS**                                                                           | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Anonymity Verifier](https://kodachi.cloud/)**                                     | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Binary Documentation](https://kodachi.cloud/docs/)**               | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Standalone Binaries](https://kodachi.cloud/downloads/#binaries)**         | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Terminal Server Version](https://kodachi.cloud/docs/terminal-version.html)** | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Payment Gateway](https://kodachi.cloud/docs/support.html)**                  | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **Kodachi Admin Dashboard**                                                                      | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi License Portal (Customer Self-Service)](https://kodachi.cloud/tools/whitepaper.html#13-the-customer-license-portal)** | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **Kodachi Dashboard GUI** ([Installation](https://kodachi.cloud/downloads/#binaries) · [Desktop](https://kodachi.cloud/docs/desktop-debian.html)) | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi AI Capabilities](https://kodachi.cloud/docs/ai/index.html)**                 | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Desktop (Debian XFCE)](https://kodachi.cloud/docs/desktop-debian.html)**     | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[File Verification Tool](https://kodachi.cloud/docs/security/file-verify.html)**      | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Technical Whitepaper](https://kodachi.cloud/tools/whitepaper.html)**                  | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |
| **[Kodachi Downloads Center](https://kodachi.cloud/downloads/)**                             | ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)    | ![100%](https://img.shields.io/badge/Progress-100%25-brightgreen?style=flat-square) |

---

## Component Progress Breakdown

| Feature / Utility        | Backend                                                                   | Frontend                                                                  | Notes                                                                          |
| ------------------------ | ------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Login Manager**        | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Completed both authentication logic and UI integration.                        |
| **Internet Fix Utility** | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Network diagnostics and recovery utilities implemented.                        |
| **Application Launcher** | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Modular app launch system for privacy tools.                                   |
| **Security Tools**       | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Includes firewall toggles and protection utilities.                            |
| **IP Fetch Utility**     | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Full location + ASN lookup integrated.                                         |
| **MAC Address Utility**  | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Automatic and manual MAC spoofing supported.                                   |
| **Hostname Changer**     | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Persistent and session-based hostname updates handled.                         |
| **Time Zone Utility**    | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Geo-based adjustment; includes IP-based firewall re-evaluation.                |
| **Command Guide**        | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | CLI helper with context-aware command suggestions.                             |
| **Gambas Command Line**  | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Command line integration and debugging completed (Task #9).                    |
| **Tor Manager**          | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Backend and frontend complete; IP login testing needed (Task #6, Aug 28).      |
| **System Information**   | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Backend and frontend both completed with dynamic hardware and OS data parsing. |
| **DNS Manager**          | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Backend and frontend fully implemented.                                        |
| **Card System**          | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Decryption and patching completed (Task #1, Aug 15).                           |
| **Secure Connectivity**  | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | VPN and secure connection management fully implemented.                        |
| **Project Connector**    | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Backend Rust implementation completed (Task #2, Aug 17).                       |
| **Workflow Manager**     | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Batch command execution with conditional logic and telemetry completed.        |
| **Settings Manager**     | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | Core settings logic and GUI fully implemented.                                 |
| **CLI-Core Library**     | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | N/A                                                                       | Unified command-line interface foundation for all services.                    |
| **Dependencies Checker** | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | N/A                                                                       | Comprehensive system dependency verification and management.                   |
| **Auth-Shared Library**  | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | N/A                                                                       | Centralized authentication framework for all backend services.                 |
| **Rust-Updater**         | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | N/A                                                                       | Automated dependency updating and API compatibility management.                |
| **AI Capabilities**      | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square) | AI-powered intent classification, NLP command processing, and agent framework. |

### System-Wide Improvements

- **![Docs](https://img.shields.io/badge/-Unified%20Help%20Menus-blue?style=flat-square)**: All 10+ Rust services now feature consistent `--help` and `--examples` output formats
- **![Config](https://img.shields.io/badge/-JSON--First%20Configuration-orange?style=flat-square)**: Complete migration from YAML to JSON for all configuration and output files
- **![CLI](https://img.shields.io/badge/-Standardized%20CLI%20Options-green?style=flat-square)**: Unified `-e`, `-n`, `-v`, `-h`, and `--json` flags across all backend services
- **![Integration](https://img.shields.io/badge/-Cross--Service%20Communication-purple?style=flat-square)**: Seamless integration between all services using shared libraries and protocols
- **![UI](https://img.shields.io/badge/-GUI%20Enhancements-pink?style=flat-square)**: Modern interface updates with real-time status integration and improved error handling
- **![Security](https://img.shields.io/badge/-Security%20Improvements-red?style=flat-square)**: Enhanced authentication, session management, and platform hardening measures
- **![Performance](https://img.shields.io/badge/-Performance%20Optimization-yellow?style=flat-square)**: Improved error handling, memory management, and cryptographic integrity verification

---

## Kodachi 9 Development Timeline

**Development Started:** August 2024
**Released:** February 26, 2026
**Current Status:** Released
**Changelog:** [View Changelog](https://kodachi.cloud/docs/changelog.html) | [Raw](https://kodachi.cloud/apps/os/CHANGELOG.md)

### Project Timeline

|  #  | Task                             |                                   Status                                    | Completion Date | Notes                                            |
| :-: | :------------------------------- | :-------------------------------------------------------------------------: | :-------------: | ------------------------------------------------ |
|  1  | Gambas Command Line & Debug      |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Aug 11, 2025   | Command line integration completed               |
|  2  | Card System (Decryption & Patch) |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Aug 15, 2025   | Decryption and patching completed                |
|  3  | Project Connector in Rust        |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Aug 17, 2025   | Backend Rust implementation completed            |
|  4  | Recheck 8.27 features            |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Aug 25, 2025   | All Kodachi 8.27 features verified               |
|  5  | Test all binaries                |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Sep 17, 2025   | Compiled binaries tested across all environments |
|  6  | Research                         |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Sep 30, 2025   | Edge-case testing and hardening completed        |
|  7  | Tor Manager IP Login GUI fix     |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Jan 15, 2026   | Fix IP login functionality                       |
|  8  | DNS GUI                          |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Jan 20, 2026   | Complete GUI for DNS management                  |
|  9  | Blender GUI + scoring            |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Jan 25, 2026   | Traffic mixing and obfuscation UI                |
| 10  | Check Reference General MD       |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Jan 30, 2026   | Documentation review                             |
| 11  | Build ISO                        |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Feb 20, 2026   | Final ISO build for beta release                 |
| 12  | Blender in Rust                  | ![Cancelled](https://img.shields.io/badge/-Cancelled-red?style=flat-square) |        -        | Duplicate of Workflow Manager (completed)        |
| 13  | Desktop Final Release            |  ![Done](https://img.shields.io/badge/-Done-brightgreen?style=flat-square)  |  Feb 26, 2026   | Kodachi Desktop (Debian XFCE) final release      |

**Release Date:** February 26, 2026

See the full [Changelog](https://kodachi.cloud/docs/changelog.html) for detailed release notes ([raw](https://kodachi.cloud/apps/os/CHANGELOG.md)).

---

## Installation Scripts

All five scripts live in **[open/installers/](open/installers)**:

- **[kodachi-binary-install.sh](open/installers/kodachi-binary-install.sh)** - Downloads and installs Kodachi binaries without requiring sudo
- **[kodachi-deps-install.sh](open/installers/kodachi-deps-install.sh)** - Installs all system dependencies (requires sudo)
- **[kodachi-autoshield.sh](open/installers/kodachi-autoshield.sh)** - The login shell dashboard, sourced from `/etc/profile.d`
- **[kodachi-autoshield-shell.sh](open/installers/kodachi-autoshield-shell.sh)** - The standalone variant, run directly rather than sourced
- **[kodachi-debug-collector.sh](open/installers/kodachi-debug-collector.sh)** - Collects a redacted diagnostic bundle for support

These are the Kodachi 9 versions, kept as the historical record of that line. The
current versions are in **[../Kodachi-OS-10-stable/open/installers/](../Kodachi-OS-10-stable/open/installers)**.

---

## Release Plan Going Forward ![Release](https://img.shields.io/badge/-Release%20Plan-blue?style=for-the-badge)

### Phase 1: Kodachi Client Binary Backend ![RELEASED](https://img.shields.io/badge/-RELEASED-brightgreen?style=flat-square)

**Status:** ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)
**Documentation:** [Installation Guide](https://kodachi.cloud/downloads/#binaries)
**Description:** Standalone Kodachi binaries that work on any Linux distribution
**Benefits:**

- Fastest deployment to users
- Cross-distro compatibility testing
- Early bug detection without needing ISO builds
- Community feedback on core functionality

### Phase 2: Kodachi Terminal Server Version ![RELEASED](https://img.shields.io/badge/-RELEASED-brightgreen?style=flat-square)

**Status:** ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)
**Documentation:** [Terminal Server Version Guide](https://kodachi.cloud/docs/terminal-version.html)
**Description:** Terminal-based edition with lightweight CLI interface and full backend integration
**Technical Foundation:** Built on all standalone binaries from Phase 1 with optimized system integration

**Benefits:**

- All Phase 1 binaries pre-installed and configured
- Smaller attack surface for security hardening
- Network and security module stabilization
- Core system testing without GUI overhead
- Foundation for desktop edition
- Perfect for servers and headless systems
- Same privacy tools as standalone binaries, but with seamless integration

### Phase 3: Kodachi Desktop Edition (Debian XFCE) ![RELEASED](https://img.shields.io/badge/-RELEASED-brightgreen?style=flat-square)

**Status:** ![Complete](https://img.shields.io/badge/Status-Complete-brightgreen?style=flat-square)
**Documentation:** [Desktop Debian Guide](https://kodachi.cloud/docs/desktop-debian.html)
**Description:** Full desktop experience with polished GUI and dashboard integration built on Debian XFCE
**Benefits:**

- Incorporates all feedback from Phases 1 & 2
- Refined UX based on real-world usage
- Complete Gambas GUI dashboard
- Most stable and feature-complete release

### Why This Order?

**• Binaries First** ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) = Fastest way to get real-world coverage on any distro. We catch environment bugs early without rebuilding ISOs.

**• Terminal Server Next** ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) = Stabilize network and security modules on a smaller, lighter attack surface, and harden the core that the Desktop will use.

**• Desktop Last** ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) = Integrate user feedback, polish UX, and ship the full experience.

### Technical Progression

Each phase builds upon the previous, ensuring maximum stability and security:

**Phase 1 (Standalone Binaries)** = Individual tools → Modular testing and development
**Phase 2 (Terminal Server Version)** = Binaries + System Integration → Hardened foundation
**Phase 3 (Desktop Edition)** = Terminal + GUI Dashboard → Complete user experience

This progression ensures that each layer is thoroughly tested and hardened before the next is built on top of it.

### What This Means for Users:

• **Available Now**: Binaries and Terminal Server Version are ready for immediate use
• **Better Stability**: Desktop edition benefits from real-world testing of Phases 1 & 2
• **Flexible Deployment**: Choose the edition that fits your needs (binaries, terminal, or wait for desktop)
• **Community-Driven**: Your feedback from current releases shapes the desktop edition

### Current Status:

• ![Available](https://img.shields.io/badge/-Available-brightgreen?style=flat-square) **Standalone Binaries**: [Install individual tools on any Linux distribution](https://kodachi.cloud/downloads/#binaries) - Perfect for adding Kodachi privacy tools to your existing system

• ![Available](https://img.shields.io/badge/-Available-brightgreen?style=flat-square) **Terminal Server Version**: [Complete system with all binaries pre-integrated](https://kodachi.cloud/docs/terminal-version.html) - Perfect for dedicated privacy systems, servers, and headless deployments

• ![Available](https://img.shields.io/badge/-Available-brightgreen?style=flat-square) **Desktop Edition (Debian XFCE)**: [Full desktop experience with complete GUI dashboard](https://kodachi.cloud/docs/desktop-debian.html) built on Terminal Server Version foundation

• **All editions share the same core binaries and security features** - Choose based on your deployment needs

---

Each of the above components is now integrated or in final testing stages. Kodachi 9 will support both GUI-based control and CLI command-driven interaction.

## Development Approach

- **From Scratch with Legacy Integration:**
  Every component has been re-engineered from the ground up to ensure modern, robust architecture. That said, the working code from the previous version was utilized where applicable to maintain proven functionality and save valuable development time.

---

# Archived from the main README (moved 2026-08-14)

The main README was cut down to the current release, the Kodachi 10 work in progress, and the links that matter. Everything below is the Kodachi 9 material it used to carry, preserved verbatim.


## Kodachi 9 Releases

| Release | Description | Links |
|---------|-------------|-------|
| ![Desktop](https://img.shields.io/badge/-Desktop%20Edition-success?style=for-the-badge&logo=debian&logoColor=white) | **Kodachi 9 Desktop (Debian XFCE)** — Full desktop experience with Gambas GUI dashboard, all security binaries pre-integrated, and polished interface for privacy-first computing. | [![Download](https://img.shields.io/badge/Download-Get%20Started-blue?style=flat-square&logo=rocket&logoColor=white)](https://kodachi.cloud/docs/desktop-debian.html) |
| ![Terminal](https://img.shields.io/badge/-Terminal%20Server-orange?style=for-the-badge&logo=terminal&logoColor=white) | **Kodachi Terminal Server Version** — Lightweight ISO with all binaries pre-configured and optimized terminal interface. Perfect for servers and headless deployments. | [![Guide](https://img.shields.io/badge/Guide-blue?style=flat-square&logo=book&logoColor=white)](https://kodachi.cloud/docs/terminal-version.html) |
| ![Binaries](https://img.shields.io/badge/-Standalone%20Binaries-blue?style=for-the-badge&logo=package&logoColor=white) | **Kodachi Standalone Binaries** — Individual privacy and security tools that work on any Debian-based Linux distribution. Ships with the full Dashboard GUI. | [![Install](https://img.shields.io/badge/Installation-green?style=flat-square&logo=rocket&logoColor=white)](https://kodachi.cloud/downloads/#binaries) |
| ![Dashboard](https://img.shields.io/badge/-Dashboard%20GUI-teal?style=for-the-badge&logo=desktop&logoColor=white) | **Kodachi Dashboard GUI** — Modern Tauri + Svelte desktop application providing centralized control over all security services. Ships with all editions. | [![Install](https://img.shields.io/badge/Installation-green?style=flat-square&logo=rocket&logoColor=white)](https://kodachi.cloud/downloads/#binaries) [![Desktop](https://img.shields.io/badge/Desktop-blue?style=flat-square&logo=debian&logoColor=white)](https://kodachi.cloud/docs/desktop-debian.html) |
| ![Changelog](https://img.shields.io/badge/-Changelog-gray?style=for-the-badge&logo=clock&logoColor=white) | **Kodachi Changelog** — Full history of changes, improvements, and fixes across all Kodachi releases and components. | [![Changelog](https://img.shields.io/badge/Changelog-blue?style=flat-square&logo=clock&logoColor=white)](https://kodachi.cloud/docs/changelog.html) [![Raw](https://img.shields.io/badge/Raw-gray?style=flat-square&logo=markdown&logoColor=white)](https://kodachi.cloud/apps/os/CHANGELOG.md) |
| ![Whitepaper](https://img.shields.io/badge/-Technical%20Whitepaper-9cf?style=for-the-badge&logo=readthedocs&logoColor=white) | **Kodachi OS 9 Technical Whitepaper:** A full, honest breakdown of how the platform works: the OS, Rust services, dashboard, routing, Tor, DNS, hardening stack, VPS fleet, end-to-end signing chain (RSA-4096 + BLAKE3), and the real threat model (including what Kodachi does not protect against). No black boxes. | [![Read](https://img.shields.io/badge/Read-blue?style=flat-square&logo=readthedocs&logoColor=white)](https://kodachi.cloud/tools/whitepaper.html) |
| ![Downloads](https://img.shields.io/badge/-Downloads%20Center-blueviolet?style=for-the-badge&logo=cloudsmith&logoColor=white) | **Kodachi Downloads Center:** One place to grab the Desktop ISO, Terminal Server ISO, and standalone binaries, with live download trends and by-OS / by-country stats. | [![Open](https://img.shields.io/badge/Open-green?style=flat-square&logo=cloudsmith&logoColor=white)](https://kodachi.cloud/downloads/) |

## What's New (as of June 2026)

> **Recent Platform Updates:**
>
> - **[Kodachi OS 9 Technical Whitepaper](https://kodachi.cloud/tools/whitepaper.html)** - Newly published! A full, code-verified breakdown of the architecture, Rust services, routing, hardening, VPS fleet, signing chain (RSA-4096 + BLAKE3), and the honest threat model, so you can verify the engineering instead of taking privacy claims on trust
> - **[Community Contributors: Roll of Honor](https://kodachi.cloud/community/contributors.html)** - A new recognition page thanking the people who help make Kodachi OS successful: contributors, developers, auditors, feature proposers, moderators, and the wider community who leave Kodachi better than they found it
> - **[Kodachi Downloads Center](https://kodachi.cloud/downloads/)** - A single hub for the Desktop ISO, Terminal Server ISO, and standalone binaries, with live download trends and by-OS / by-country statistics
> - **[Customer License Portal](https://kodachi.cloud/tools/whitepaper.html#13-the-customer-license-portal)** - A new self-service online dashboard for customers, separate from the admin command center: paste your license key (no account, no sign-up) to see each license's tier, seat usage, expiry, registered devices, download links, and transaction history, release a device seat remotely, and use the new **Your Nodes** panel listing the VPN nodes your license can use with live per-service status. The portal link is revealed on your purchase-confirmation page and in the support FAQ
> - **AutoShield Auto-VPN** - AutoShield now auto-connects your saved external VPN (e.g. ProtonVPN) at boot, before the kill-switch and Tor, instead of silently skipping it
> - **[Dashboard Gallery](https://kodachi.cloud/docs/gallery.html)** - Preview the Kodachi dashboard before installing, with annotated screenshots you can filter by topic (SOC, VPN, Tor, DNS, Mobile, and more) and open full-screen
> - **[Tor Bridges (obfs4)](https://kodachi.cloud/docs/changelog.html)** - Tor now starts even on networks that block or interfere with it, including over a Reality/XTLS VPN: paste obfs4 bridges, pick All or Random, and let them rotate automatically
> - **SOC Security Center** - The on-device security operations page now watches more signals (DNS health and leaks, running Tor instances, sign-in history, and additional intrusion patterns), with selectable themes, clearer tooltips, lighter CPU use on low-power machines, and a tunable refresh interval. It now also flags background screen-capture activity (MITRE T1113) and escalates while a password manager is open
> - **[Kodachi Desktop (Debian XFCE)](https://kodachi.cloud/docs/desktop-debian.html)** - Full desktop edition released! Complete GUI experience built on Debian XFCE with all security binaries pre-integrated
> - **[Kodachi AI Capabilities](https://kodachi.cloud/docs/ai/index.html)** - KAICS (Kodachi AI Command Intelligence System) brings 7 AI-powered binaries for intelligent command processing, NLP-driven service control, and proactive security automation
> - **[Kodachi Dashboard GUI](https://kodachi.cloud/downloads/#binaries)** - Modern Tauri + Svelte desktop application providing centralized control over all security services
> - **[Domain Checker](https://kodachi.cloud/tools/domain-checker.html)** - Global DNS propagation checker with multi-server verification
> - **[API Documentation Portal](https://kodachi.cloud/tools/api-docs.html)** - New API docs for IP geolocation, platform stats, and binary service endpoints
> - **[Infrastructure Status Dashboard](https://kodachi.cloud/apps/status.php)** - Live monitoring of servers and services across multiple regions
> - **[File Verification Tool](https://kodachi.cloud/docs/security/file-verify.html)** - Browser-based file integrity verification with hash computation and automatic checksum comparison against official Kodachi releases
> - **[Redesigned Landing Page](https://kodachi.cloud/)** - The Kodachi 9 home page has a new marketing-style layout: an editions row, a side-by-side comparison against Tails / Whonix / Parrot / Qubes, live download and country counters, a curated tools grid, and a "Verify ISO" button on every edition card

## Deployment Options, Built on the Same Foundation

All Kodachi 9 editions are built on the same core security foundation:

- **Standalone Binaries**: Individual privacy and security tools that can be installed on any Debian-based system. Perfect for adding Kodachi security features to your existing Linux installation.
- **Terminal Server Version**: Lightweight ISO with all binaries pre-configured and optimized terminal interface. Ideal for dedicated privacy systems, servers, and headless deployments.
- **Desktop Edition (Debian XFCE)**: Complete experience with GUI dashboard built on the Terminal Server Version foundation. Provides the full Kodachi experience with intuitive graphical controls.

**All three options share the same core binaries and security features** - choose based on your deployment needs and preferences.

## Features at a Glance

- ![Secure](https://img.shields.io/badge/-Secure%20by%20Default-green?style=flat-square&logo=lock) **Secure by Default:** Kodachi ensures that from the moment you boot up, you're protected. With a **pre-configured VPN**, **Tor network**, and **DNSCrypt** service, your internet traffic is encrypted and anonymized without requiring any configuration.
- ![Privacy](https://img.shields.io/badge/-Privacy%20Focused-blue?style=flat-square&logo=shield) **Privacy Focused:** All your online connections are routed through a multi-layered protection stack, including **VPN** and **Tor**, making your identity extremely difficult to trace.
- ![Live](https://img.shields.io/badge/-Live%20System-purple?style=flat-square&logo=desktop) **Live System:** Kodachi operates directly from **RAM**, ensuring that no data is written to your hard disk unless explicitly saved. Once the session is over, all traces of your activity are erased.
- ![Friendly](https://img.shields.io/badge/-User%20Friendly-orange?style=flat-square&logo=smile) **User-Friendly:** Kodachi is designed for users of all levels. Whether you're an experienced Linux user or a beginner, you can enjoy the benefits of Kodachi with minimal setup.
- ![Crypto](https://img.shields.io/badge/-Cryptographic%20Tools-red?style=flat-square&logo=key) **Cryptographic Tools:** Built-in tools for **file encryption**, **secure email communication**, and **instant messaging** help you maintain control over your data and communications.
- ![Forensic](https://img.shields.io/badge/-Anti--Forensic-black?style=flat-square&logo=user-secret) **Anti-Forensic Features:** Includes measures to thwart forensic analysis, ensuring your activities remain private even if your system is physically compromised.
- ![Monitor](https://img.shields.io/badge/-System%20Monitoring-teal?style=flat-square&logo=chart-bar) **System Monitoring:** Real-time monitoring tools provide insights into your **network connections**, **system performance**, and **security status**.

## Why Choose Kodachi?

Kodachi was born out of a need to bridge the gap between **user-friendly operating systems** and the increasingly sophisticated world of **digital privacy threats**. With Kodachi, you can:

- ![Anonymous](https://img.shields.io/badge/-Browse%20Anonymously-blue?style=flat-square&logo=user-secret) **Browse the web anonymously** through layers of encryption and the **Tor network**.
- ![No Trace](https://img.shields.io/badge/-Leave%20No%20Trace-gray?style=flat-square&logo=database) **Leave no trace** on the hardware you're using, making it perfect for environments where **privacy is critical**.
- ![Crypto](https://img.shields.io/badge/-Cryptographic%20Tools-red?style=flat-square&logo=lock) **Use cutting-edge cryptographic tools** for secure communication and data storage.
- ![Protected](https://img.shields.io/badge/-Stay%20Protected-green?style=flat-square&logo=shield) **Stay protected against malware** and network attacks with built-in **security features**.

Kodachi is more than just another Linux distribution—it's a **robust**, **lightweight operating system** that puts your **security and privacy first**.

## Getting Started

You don't need to be a cybersecurity expert to use Kodachi. Choose the deployment option that best fits your needs:

### Option A: Terminal Server Version (Recommended for Full System)

The Terminal Server Version provides a complete Kodachi installation with all binaries pre-configured in a lightweight terminal interface.

1. **[Download Terminal Server Version ISO](https://kodachi.cloud/docs/terminal-version.html)**
2. **Create Bootable Media:** Use **Rufus** (Windows) or **Etcher** (Linux/Mac) to create a bootable USB drive
3. **Boot and Install:** Restart your computer, boot from USB, and follow the installation wizard
4. **Full Documentation:** [Terminal Server Version Guide](https://kodachi.cloud/docs/terminal-version.html)

**Perfect for:** Dedicated privacy systems, servers, headless deployments, and users who want everything pre-configured.

### Option B: Standalone Binaries (For Existing Systems)

Install individual Kodachi tools on your current Debian-based Linux distribution.

1. **[Installation Guide for Standalone Binaries](https://kodachi.cloud/downloads/#binaries)**
2. **Choose Your Tools:** Install all binaries or select specific privacy tools you need
3. **Works On:** Any Debian-based distribution (Ubuntu, Debian, Linux Mint, etc.)

**Perfect for:** Users who want to add Kodachi privacy features to their existing Linux system.

### Option C: Virtual Machine Testing

Test the Terminal Server Version in a virtual environment before full installation:

**VMware Workstation:**

1. Open VMware Workstation and create a new virtual machine
2. Select "Installer disc image file (iso)" and browse to the Kodachi Terminal Server Version ISO
3. Configure VM settings (recommended: 2GB+ RAM, 20GB+ disk)
4. Start the VM and Kodachi will boot in live mode

**VirtualBox:**

1. Open VirtualBox and create a new virtual machine
2. Select "Linux" as the type and "Debian (64-bit)" as the version
3. Configure VM settings (recommended: 2GB+ RAM, 20GB+ disk)
4. In "Storage" settings, add the Kodachi Terminal Server Version ISO as a virtual optical disk
5. Start the VM and Kodachi will boot in live mode

**Perfect for:** Testing, learning, or running Kodachi alongside your current operating system.

## Tutorials and Resources

To learn how to use Kodachi, explore the following resources:

- **YouTube Tutorials:**
  - Search for **Kodachi OS** on YouTube or visit [this link](https://www.youtube.com/results?search_query=linux+kodachi) for a collection of video tutorials.
- **Official Documentation:** Visit the [Kodachi Documentation](https://kodachi.cloud/docs/) for detailed guides.
- **Community Support:** Join the **[Kodachi support](https://discord.gg/KEFErEx)** to ask questions and share insights.
