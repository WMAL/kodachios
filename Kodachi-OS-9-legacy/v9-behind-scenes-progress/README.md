# ![Kodachi](https://img.shields.io/badge/Kodachi%20v9-Behind%20the%20Scenes%20Progress-blue?style=for-the-badge&logo=shield) Kodachi v9 – Behind the Scenes Progress

Welcome to the **Behind-the-Scenes** folder for the development of **Kodachi v9**. This space documents the ongoing engineering efforts, security architecture decisions, implementation strategies, and technical milestones shaping the next generation of the Kodachi Security OS.

Here you'll find a collection of:
- ![Security](https://img.shields.io/badge/-Security%20Design%20Documents-red?style=flat-square&logo=lock) **Security design documents**
- ![Insights](https://img.shields.io/badge/-Architecture%20Insights-yellow?style=flat-square&logo=lightbulb) **Architecture insights**
- ![Videos](https://img.shields.io/badge/-Development%20Videos-red?style=flat-square&logo=video) **Development videos and feature walkthroughs**
- ![Experimental](https://img.shields.io/badge/-Experimental%20Notes-purple?style=flat-square&logo=flask) **Experimental notes and early concepts**
- ![Technical](https://img.shields.io/badge/-Technical%20Breakdowns-gray?style=flat-square&logo=toolbox) **Technical breakdowns of hardened components**

---

!!! tip "New: Kodachi Dashboard Available"
    The **Kodachi Dashboard** is now included in the binary packages! This modern Tauri + Svelte desktop application provides centralized control over all security services including authentication, connections, TOR, DNS, and system health. Install the binaries to try it out - feedback welcome on [Discord](https://discord.gg/KEFErEx).

---

## ![Purpose](https://img.shields.io/badge/-Purpose-green?style=flat-square&logo=pushpin) Purpose

The goal of this folder is to provide **transparency and technical depth** into the decisions and challenges involved in building Kodachi v9. It's a **progress log** from the perspective of the lead developer, designed to share not only solutions, but the *thinking behind them*.

We believe security tools should be as open in design as they are strong in defense — this folder is part of that commitment.

---

## ![Contents](https://img.shields.io/badge/-Contents-blue?style=flat-square&logo=folder) Contents

| Type         | Title / Description                                                                 | Link                                                                                                           |
|--------------|--------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| ![Whitepaper](https://img.shields.io/badge/-Whitepaper-9cf?style=flat-square&logo=readthedocs) | **Kodachi OS 9 Technical Whitepaper**: Full architecture, threat model, routing, hardening, VPS fleet, and the end-to-end signing chain (RSA-4096 + BLAKE3) | [Read Whitepaper](https://www.kodachi.cloud/tools/whitepaper.html) |
| ![Article](https://img.shields.io/badge/-Article-blue?style=flat-square&logo=document) | **Securing Digital Identity** – Challenge-Response Authentication System Design     | [Read Article](https://github.com/WMAL/kodachios/blob/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/Securing%20Digital%20Identity.md) |
| ![Video](https://img.shields.io/badge/-Video-red?style=flat-square&logo=film) | **Authentication Flow Demo** – Kodachi v9 Challenge-Response Walkthrough            | [Watch Video](https://github.com/WMAL/kodachios/raw/refs/heads/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/Kodachi9-auth-demo.mp4) |
| ![Article](https://img.shields.io/badge/-Article-blue?style=flat-square&logo=document) | **IP-Fetch Utility Overview** – Enhancing Anonymity with Dynamic Network Controls   | [Read Article](https://github.com/WMAL/kodachios/blob/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/ip-fetch.md)          |
| ![Video](https://img.shields.io/badge/-Video-red?style=flat-square&logo=film) | **IP-Fetch Demo** – Real-Time Network Identity Monitoring and Control                | [Watch Video](https://github.com/WMAL/kodachios/raw/refs/heads/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/ip-fetch-c.mp4)        |
| ![Article](https://img.shields.io/badge/-Article-blue?style=flat-square&logo=document) | **Tor Manager Module** – Full Control Over Tor Instances, Circuits, and Exit Nodes  | [Read Article](https://github.com/WMAL/kodachios/blob/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/tor-manager.md)       |
| ![Video](https://img.shields.io/badge/-Video-red?style=flat-square&logo=film) | **Tor Manager Demo** – Instance Control, Circuit Refresh, and Exit Node Selection    | [Watch on Dubz](https://dubz.co/v/27417e) · [Watch on Viddler](https://www.viddler.com/tDrQ22)                 |

---

## ![Milestones](https://img.shields.io/badge/-Recent%20Milestones-brightgreen?style=flat-square&logo=check) Recent Milestones
- ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) **[Kodachi OS 9 Technical Whitepaper](https://www.kodachi.cloud/tools/whitepaper.html)**: Published, the full engineering breakdown so users can verify, not just trust
- ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) **[Kodachi Downloads Center](https://www.kodachi.cloud/downloads/)**: Single download hub with live trends and by-OS / by-country stats
- ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) **Kodachi 9 — Development Complete** – All components built, deployed, and fully functional
- ![Complete](https://img.shields.io/badge/-Complete-brightgreen?style=flat-square) **[Kodachi Desktop (Debian XFCE)](https://www.kodachi.cloud/docs/desktop-debian.html)** – Full desktop edition completed

---

## ![Feedback](https://img.shields.io/badge/-Feedback%20%26%20Contributions-green?style=flat-square&logo=heart) Feedback & Contributions

This is an **open knowledge initiative**. Whether you're a security researcher, open source enthusiast, or curious developer — feel free to follow the updates and share your thoughts via the Issues section or discussion threads.

---

> ![Mission](https://img.shields.io/badge/-Built%20for%20privacy.%20Engineered%20for%20trust.-blue?style=flat-square&logo=compass) *Built for privacy. Engineered for trust.*
