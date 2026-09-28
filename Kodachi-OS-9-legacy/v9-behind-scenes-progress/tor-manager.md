# ![Major Update](https://img.shields.io/badge/-Tor--Manager%20Major%20Update-blue?style=for-the-badge&logo=rocket) Tor-Manager: Major Update for Kodachi OS v9

---

## ![Overview](https://img.shields.io/badge/-Overview-orange?style=flat-square&logo=wrench) Overview

The **Tor-Manager** has been completely rebuilt from the ground up in **Rust**, transforming how Kodachi OS handles Tor network operations. This upgrade replaces legacy shell-based implementations with a high-performance, secure, and extensible backend that gives users unmatched control, speed, and privacy.

---

## ![Architecture](https://img.shields.io/badge/-Key%20Architectural%20Highlights-purple?style=flat-square&logo=brain) Key Architectural Highlights

- **Rust Backend**: Built in Rust for speed, safety, and concurrency.
- **JSON API**: Every command returns structured JSON—ideal for automation or UI.
- **Security by Design**: Defaults to client-only mode with enforced anti-exit settings.
- **Modular CLI**: A single `tor-switch` binary controls all features and modes.

---

## ![Demo Videos](https://img.shields.io/badge/-Demo%20Videos-red?style=flat-square&logo=film) Tor Manager Demo Videos

Watch the Tor-Manager in action, showcasing real-time control over instances, circuits, and exit nodes:

- ![Link](https://img.shields.io/badge/-Watch-blue?style=flat-square&logo=link) [Watch on Dubz](https://dubz.co/v/27417e)
- ![Link](https://img.shields.io/badge/-Watch-blue?style=flat-square&logo=link) [Watch on Viddler](https://www.viddler.com/tDrQ22)
  
---

## ![New Features](https://img.shields.io/badge/-What's%20New-red?style=flat-square&logo=fire) What's New?

### ![Feature](https://img.shields.io/badge/-Multi--Instance%20Management-green?style=flat-square) Multi-Instance Management
Run unlimited isolated Tor instances:
```bash
sudo tor-switch create_instance secure
sudo tor-switch list_instances_with_ip
```

### ![Global](https://img.shields.io/badge/-Advanced%20Exit%20Node%20Control-blue?style=flat-square&logo=globe) Advanced Exit Node Control
Select exit countries or regions:
```bash
sudo tor-switch set_exit_node ch        # Switzerland
sudo tor-switch set_exclude_node 14eyes
```

### ![Balance](https://img.shields.io/badge/-Load%20Balancing%20Modes-teal?style=flat-square&logo=balance-scale) Load Balancing Modes
Balance traffic intelligently:
```bash
sudo tor-switch set_load_balancing_mode round-robin
sudo tor-switch torrify_system_nftables_load_balanced
```

### ![Rotation](https://img.shields.io/badge/-Automated%20IP%20Rotation-orange?style=flat-square&logo=sync) Automated IP Rotation
Schedule dynamic identity refresh:
```bash
sudo tor-switch update_ip_all_timer 1h
```

### ![Tools](https://img.shields.io/badge/-HAProxy%20Integration-gray?style=flat-square&logo=toolbox) HAProxy Integration
Support for advanced proxy strategies:
```bash
sudo tor-switch generate_haproxy_config leastconn 9055
```

### ![Security](https://img.shields.io/badge/-System--Wide%20Torrification-red?style=flat-square&logo=lock) System-Wide Torrification
Route everything—including DNS—through Tor:
```bash
sudo tor-switch torrify_system_iptables_dns
```

### ![Hardened](https://img.shields.io/badge/-Hardened%20Security-darkred?style=flat-square&logo=shield) Hardened Security
- Enforced `ClientOnly 1`, `ExitRelay 0`
- Password-based access control
- YAML config protection & auto-migration

---

## ![Use Cases](https://img.shields.io/badge/-Example%20Use%20Cases-green?style=flat-square&logo=target) Example Use Cases

| Use Case              | Features Utilized                                  |
|-----------------------|-----------------------------------------------------|
| **Geo-Streaming**     | Consistent hashing + country exit control          |
| **Audit Mode**        | Exclude surveillance nations (14-eyes)             |
| **Multi-App Routing** | Separate Tor instances per use (stream, browser)   |
| **Auto Privacy**      | Timed IP rotation with DNS over Tor                |

---

## ![Integration](https://img.shields.io/badge/-GUI%20%26%20System%20Integration-purple?style=flat-square&logo=puzzle) GUI & System Integration

- ![Package](https://img.shields.io/badge/-Kodachi%20Launcher-brown?style=flat-square&logo=package) **Kodachi Launcher**: Available under Button5 + Tray Menu
- ![Data](https://img.shields.io/badge/-JSON%20Outputs-blue?style=flat-square&logo=chart-bar) **JSON Outputs**: Real-time metrics feed the Gambas GUI
- ![Firewall](https://img.shields.io/badge/-Firewall%20Sync-red?style=flat-square&logo=shield) **Firewall Sync**: iptables and nftables support
- ![Logs](https://img.shields.io/badge/-Logs--Hook-gray?style=flat-square&logo=file-text) **Logs-Hook**: All actions are centrally logged  

---

## ![Performance](https://img.shields.io/badge/-Performance%20Gains-yellow?style=flat-square&logo=trending-up) Performance Gains

- ![Speed](https://img.shields.io/badge/-10x%20Faster-green?style=flat-square) Up to **10x faster** than previous shell-based version
- ![Clean](https://img.shields.io/badge/-Resilient-teal?style=flat-square) Resilient against race conditions, memory leaks, or stale configs
- ![Fast](https://img.shields.io/badge/-Fast%20Regeneration-orange?style=flat-square&logo=sync) Fast circuit regeneration & live status checks  

---

## ![Note](https://img.shields.io/badge/-A%20Personal%20Note%20from%20the%20Developer-blue?style=flat-square&logo=pencil) A Personal Note from the Developer

This phase—**Tor-Manager for Kodachi OS**—has taken nearly **12 weeks of continuous, intense development**, including countless sleepless nights. Every line of code, every edge case, every safeguard was carefully written and tested to serve one purpose: give users full, uncompromised control over their anonymity.

Although **Kodachi 9 is not yet fully complete**, I can confidently say that even at this stage, **what has been built rivals and surpasses many of the tools I’ve seen across other security and privacy-focused distributions**. What you see here is not a clone, not a script bundle—it’s a meticulously engineered system with **features I have yet to find anywhere else** in a privacy OS.

My vision is simple: **to give users real power, real transparency, and real privacy**.  

By the time this project reaches final release, I am hopeful that **Kodachi 9 will empower its users** with tools that provide not just peace of mind—but operational superiority in today’s surveillance-heavy digital landscape.

---

## ![Commands](https://img.shields.io/badge/-Summary%20of%20Major%20Commands-purple?style=flat-square&logo=terminal) Summary of Major Commands

```bash
# Instance Management
sudo tor-switch create_multiple_instances 3 region     # Create 3 Tor instances with 'region' prefix
sudo tor-switch list_instances_with_ip                 # List running instances with their current exit IPs
sudo tor-switch set_default_instance secure            # Set 'secure' as the default instance

# Exit Node & Exclusion Control
sudo tor-switch set_exit_node ch --instance=streaming  # Route 'streaming' instance through Switzerland
sudo tor-switch set_exclude_node 14eyes                # Block Fourteen Eyes countries for current instance
sudo tor-switch set_exit_node random_high_volume       # Use high-volume Tor exits for better performance

# Load Balancing
sudo tor-switch set_load_balancing_mode round-robin    # Distribute traffic sequentially across instances
sudo tor-switch set_instance_weight secure 10          # Prioritize 'secure' instance in weighted distribution
sudo tor-switch torrify_system_nftables_load_balanced  # Apply balanced routing using nftables

# DNS & Full-System Torrification
sudo tor-switch torrify_system_iptables_dns            # Route all traffic + DNS over Tor with iptables
sudo tor-switch verify_tor_dns                         # Confirm DNS is routed securely through Tor

# Tor Circuit & IP Rotation
sudo tor-switch new_tor_circuit_all                    # Generate new circuits (IP refresh) for all instances
sudo tor-switch update_ip_all_timer 1h                 # Rotate exit IPs for all instances every 1 hour

# HAProxy Integration
sudo tor-switch generate_haproxy_config leastconn 9050 # HAProxy with least-connection strategy on port 9050
sudo tor-switch haproxy_status                         # Check status of HAProxy service

# Diagnostics & Cleanup
sudo tor-switch check_tor                              # Verify Tor is working properly
sudo tor-switch cleanup --thorough                     # Remove all temporary and residual data safely
```

These commands offer a powerful preview of the depth and precision available in Kodachi's Tor-Manager. They represent only a fraction of what's possible, but clearly demonstrate its operational maturity and strategic flexibility.


---

## ![Complete](https://img.shields.io/badge/-Final%20Thoughts-green?style=flat-square&logo=check) Final Thoughts

The **Tor-Manager in Kodachi OS v9** isn’t just an upgrade—it’s a complete evolution. With the power of **Rust**, secure-by-default policies, and full system integration, users now have the tools to **fully control** their anonymity with **minimal complexity** and **maximum reliability**.

Whether you're a privacy-first individual or a cybersecurity professional, Kodachi 9 will hand you capabilities that once required complex setups—and deliver them in a secure, GUI-integrated, and blazing-fast way.

---

![Security](https://img.shields.io/badge/Kodachi%20OS%20v9-Privacy%20by%20default.%20Power%20by%20design-red?style=for-the-badge&logo=shield) **Kodachi OS v9**: Privacy by default. Power by design.
![Updates](https://img.shields.io/badge/-Stay%20Tuned-blue?style=flat-square&logo=satellite) Stay tuned for more feature rollouts and final release notes.
