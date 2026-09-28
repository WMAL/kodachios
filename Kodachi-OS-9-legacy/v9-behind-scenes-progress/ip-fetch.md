# Progress Report – Kodachi v9's IP-Fetch Application

The IP-Fetch utility in Kodachi v9 provides comprehensive network monitoring and security features through a clean, user-friendly Gambas interface. This application focuses on giving users visibility and control over their IP address and related network security settings.

## ![Video](https://img.shields.io/badge/-Demo%20Video-red?style=flat-square&logo=youtube) Watch the IP-Fetch Demo Video

[Watch the IP-Fetch Demo Video](https://github.com/WMAL/kodachios/raw/refs/heads/main/Kodachi-OS-9-legacy/v9-behind-scenes-progress/ip-fetch-c.mp4)

---

## ![Core](https://img.shields.io/badge/-Core%20Functionality-blue?style=flat-square&logo=puzzle-piece) Core Functionality

### IP Address Monitoring

- **Real-time IP Information**: Displays your current IP address, country, and flag.
- **Connection Type Detection**: Visually indicates whether you're using Kodachi, Tor, a proxy, VPN, or direct connection.
- **Automatic Refresh**: Configurable auto-refresh intervals (15/30/45 seconds or 1–60 minutes).
- **IP Change Detection**: Identifies when your IP address changes.

### Network Security Controls

- **Internet Blocking (Kill Switch)**: Automatically blocks internet access via firewall or interfaces when IP changes to prevent accidental exposure of your real IP address. This feature acts as a safeguard against VPN or proxy disconnections, ensuring your true identity remains protected.
- **MAC Address Management**: View, change, and reset MAC addresses for specific network interfaces. Randomizing your MAC address helps prevent tracking across different networks by obscuring your device's unique hardware identifier.
- **Hostname Controls**: Set random hostnames or choose from predefined options. Spoofing your hostname adds an additional layer of anonymity by preventing easy identification of your device on a network.
- **Timezone Synchronization**: Automatically sync system timezone with IP location. Aligning your system's timezone with your IP location helps avoid discrepancies that could be used to infer your actual geographic location.

### User Notifications

- **Visual Alerts**: Shows notifications when IP changes.
- **Sound Notifications**: Optional audio alerts for IP changes.
- **Detailed Tooltips**: Provides comprehensive connection information on hover.

### History and Analysis

- **IP History Tracking**: Maintains records of previous IP addresses organized by country.
- **Detailed IP Information**: Shows ISP, organization, ASN, and geolocation data.
- **Timestamp Tracking**: Records when changes occur to IPs, MAC addresses, hostnames, and timezones.

---

## ![Technical](https://img.shields.io/badge/-Technical%20Implementation-gray?style=flat-square&logo=cog) Technical Implementation

- **System Tray Integration**: Runs in the background with tray icon access.
- **JSON-based Data Storage**: Maintains IP history in structured format.
- **Authentication System**: Requires Kodachi login before allowing operation.
- **Command-line Backend**: Uses Rust-based backend for secure API communication.

---

## ![UI](https://img.shields.io/badge/-User%20Interface%20Features-purple?style=flat-square&logo=window) User Interface Features

- **Multi-tab Design**: Separate tabs for IP information, MAC addresses, hostname settings, timezone, and application settings.
- **Visual Status Indicators**: Color-coded icons show connection security status.
- **Advanced Settings**: Configurable random task execution for automated security changes.
- **Accessibility Features**: Tooltips and visual cues throughout the interface.

---

## ![Privacy](https://img.shields.io/badge/-Privacy%20and%20Anonymity%20Enhancements-green?style=flat-square&logo=lock) Privacy and Anonymity Enhancements

The IP-Fetch utility is designed with a strong emphasis on user privacy and anonymity. Here's how the key features contribute:

- **MAC Address Randomization**: By periodically changing your device's MAC address, you prevent network observers from tracking your device across different Wi-Fi networks. This is especially useful in public Wi-Fi scenarios where tracking is prevalent.

- **Hostname Spoofing**: Altering your device's hostname prevents easy identification on local networks, adding a layer of obscurity and making it harder for potential attackers to target your device.

- **Timezone Synchronization**: Ensuring your system's timezone matches your IP location prevents websites and services from detecting inconsistencies that could hint at the use of VPNs or proxies, thereby maintaining your anonymity.

- **Internet Kill Switch**: This feature acts as a fail-safe mechanism. If your VPN or proxy connection drops unexpectedly, the kill switch automatically disables your internet connection, preventing any data from being transmitted over an unsecured connection and exposing your real IP address.

---

This application provides essential network identity visibility and management tools for Kodachi Security OS users, focusing on practical security monitoring and robust privacy protection features.

