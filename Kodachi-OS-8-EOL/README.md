# Kodachi OS 8.27 (END OF LIFE)

The archived source of Kodachi 8.27, the last release of the 8 line. **End of life: it
receives no updates and no security fixes, and it should not be deployed.** It is kept as a
historical record, and because the shell and Gambas sources show how Kodachi worked before
the Rust rewrite.

For a system you can actually run, see **[../Kodachi-OS-10-stable](../Kodachi-OS-10-stable)** (current, stable).
The previous line is kept as a record at **[../Kodachi-OS-9-legacy](../Kodachi-OS-9-legacy)**.

## Directory Structure

```
Kodachi-OS-8-EOL/
├── README.md          This overview
├── LICENSE            The licence in force for the 8.27 release
├── open/              The archived source, laid out as it sat on the system
│   ├── bash/          9,392 files, 427 MB. The whole shell layer:
│   │                    etc/    dnscrypt-proxy, tor, grub.d, bodhibuilder, default
│   │                    home/   the kodachi user's dotfiles and scripts
│   │                    usr/    the installed helper scripts
│   └── gambas/        43 files. The Gambas GUI applications, the pre-Tauri dashboard:
│                        kodachi-dashboard/   the dashboard, with its image assets
│                        your_location/       the geolocation utility
└── docs/              4 files, 516 KB
    ├── Kodachi-Log.txt        The complete 8.27 changelog
    ├── Kodachi-hash.txt       SHA256/MD5 integrity hashes for the release
    ├── project-structure.md   A full file-by-file map of the 8.27 tree
    └── landing-page.md        The 8.27 landing page copy
```

> **Note on the sections below.** They were written when this archive sat alongside other
> legacy material, so some of them describe directories that are not in this folder
> (`clients-config/`, `old-vps-configs/`, `auto-install/`, `openvpn/`, `www/html/`). The
> historical and architectural notes remain accurate and are kept for that reason.

## Legacy Components

### **Kodachi 8.27 Source Archive**
- **Purpose**: Historical preservation of Kodachi 8.27 source code and documentation
- **Contents**:
  - **Kodachi-Log.txt**: Complete changelog for version 8.27
  - **Kodachi-hash.txt**: SHA256/MD5 hashes for file integrity verification
  - **LICENSE**: Original licensing terms
  - **Desktop Integration**: Kodachi_Dashboard.desktop file for system integration

### **Client Configurations** (`clients-config/`)
- **High-Anonymous-Tor.ovpn**: OpenVPN configuration optimized for Tor anonymity
- **private.ovpn**: Private VPN server configuration for direct connections
- **Purpose**: Legacy VPN client configurations for version 8.27 compatibility

### **Legacy Gambas Applications** (`gambas/`)

#### **kodachi-dashboard** - Legacy Dashboard Application
- **Purpose**: Original Kodachi dashboard interface from version 8.27
- **Assets**: 50+ image files including:
  - **Brand Assets**: Kodachi logos, icons in multiple sizes (16x16, 32x32, 48x48, 64x64)
  - **Country Flags**: Geographic indicators for VPN endpoints
  - **Security Icons**: Shield, lock, protection status indicators
  - **Payment Icons**: PayPal integration graphics
  - **System Icons**: Security levels, protection status
- **Format**: Legacy Gambas 3 project structure

#### **your_location** - Legacy Location Utility
- **Purpose**: IP geolocation display utility from version 8.27
- **Assets**: Basic branding and icon files
- **Status**: Archived legacy implementation

### **Legacy VPS Configurations** (`old-vps-configs/`)

#### **Automated Installation System** (`auto-install/`)
- **etc/**: System initialization scripts for different configurations:
  - **notorrent/**: Non-torrent network configuration
  - **notorrenttor/**: Non-torrent with Tor configuration  
  - **torrrent/**: Torrent-enabled configuration
  - **torrrenttor/**: Torrent with Tor configuration

#### **OpenVPN Server Setup** (`openvpn/`)
Multiple OpenVPN server configurations:
- **ko_***: Kodachi OpenVPN server setup
- **mo_***: Mobile OpenVPN server setup  
- **sw_***: Swiss OpenVPN server setup

Each configuration includes:
- **Authentication Scripts**: PHP-based user authentication
- **Certificates**: CA certificates, server keys, DH parameters
- **Log Parsers**: Python scripts for OpenVPN log analysis
- **Server Configurations**: OpenVPN server configuration files

#### **VPN Management Scripts** (`root/`)
Legacy VPN provider integration scripts:
- **gethidmevpn.sh**: HideMe VPN integration
- **getkernvpn.sh**: Kernel VPN integration
- **getmullvadvpn.sh**: Mullvad VPN integration
- **getnordvpn.sh**: NordVPN integration
- **getprotonvpn.sh**: ProtonVPN integration
- **getvpngate.sh**: VPN Gate integration
- **block.sh**: Network blocking utility

#### **Web Interface** (`www/html/`)
Legacy web interface components:
- **index.html**: Main web interface
- **fp.php**: Fingerprinting utility
- **myipvv.php**: IP detection utility
- **proxychecker.php**: Proxy validation tool
- **VPN Configs**: Pre-packaged VPN configuration archives

### **Development Notes**
- **kodachi 9 - Debian - AMD - 64 - Debian.md**: Development notes for version 9 transition
- **API References**: IP provider endpoints and geolocation services
- **Service Status**: Working and deprecated API endpoints

## Historical Context

### **Version 8.27 Features**
- Original Gambas-based dashboard interface
- Multi-provider VPN integration system
- Automated VPS deployment scripts
- Web-based proxy and IP checking tools
- Comprehensive OpenVPN server setup

### **Architectural Evolution**
- **Version 8.27**: PHP/Gambas-based architecture
- **Version 9.0.1**: Rust/Gambas hybrid architecture
- **Migration**: Legacy resources preserved for compatibility and reference

### **Technology Stack (Version 8.27)**
- **Frontend**: Gambas 3 GUI applications
- **Backend**: PHP scripts and bash automation
- **VPN**: OpenVPN with custom authentication
- **Web**: Apache with PHP processing
- **Database**: File-based configuration storage

## Legacy API Endpoints

### **Working IP Providers** (from version 8.27)
```
curl ifconfig.me
curl icanhazip.com  
curl ipecho.net/plain
curl ip.anysrc.net/plain
curl geoip.hmageo.com/ip
curl api.ipify.org
curl wtfismyip.com/text
curl ipinfo.io/ip
curl https://md5calc.com/ip.plain
curl curlmyip.net/
curl myexternalip.com/raw
curl bot.whatismyipaddress.com
```

### **Geolocation Providers** (from version 8.27)
- **ip-api.com**: Primary geolocation service
- **ipapi.co**: Secondary geolocation service  
- **extreme-ip-lookup.com**: Backup geolocation
- **geoplugin.net**: Alternative geolocation
- **api.db-ip.com**: Free tier geolocation

## Security Considerations

### **Legacy Security Model**
- **Version 8.27**: PHP-based authentication with file storage
- **Certificate Management**: Self-signed certificates for VPN servers
- **User Authentication**: Basic PHP session management
- **Network Security**: iptables-based firewall rules

### **Migration Security**
- **Deprecated Endpoints**: Some API endpoints no longer secure
- **Certificate Updates**: Legacy certificates may need renewal
- **Authentication Upgrade**: Modern PKI-based authentication in version 9.0.1
- **Code Review**: Legacy PHP code requires security audit before use

## Usage Guidelines

### **Historical Reference**
- Use for understanding version 8.27 architecture
- Reference for migration planning
- Backup configurations for legacy deployments
- Educational purposes for system evolution

### **Legacy Deployment** (Not Recommended)
- Only use in isolated test environments
- Update all certificates and credentials
- Review all scripts for security vulnerabilities
- Consider modern alternatives from version 9.0.1

### **Asset Recovery**
- Image and icon assets can be reused with proper validation
- Configuration templates may be adapted for modern use
- Documentation provides historical context

## Migration Notes

### **From Version 8.27 to 9.0.1**
- **Backend**: PHP scripts → Rust services
- **Authentication**: File-based → PKI-based
- **Configuration**: Static files → Embedded configuration
- **Logging**: Basic → Centralized logging system
- **Security**: Custom → Industry standard cryptography

### **Preserved Functionality**
- Core VPN functionality maintained
- Geolocation services updated and expanded  
- Dashboard interface modernized in Gambas
- Security hardening significantly improved

## Maintenance Status

### **Archive Status**
- **Read-Only**: Files preserved for historical reference
- **No Updates**: Legacy code not maintained
- **Security**: Not suitable for production use
- **Documentation**: Preserved for reference

### **Support**
- No active support for version 8.27 components
- Use modern version 9.0.1 services instead
- Historical questions may be addressed for research

## License

Legacy components retain their original licensing terms. Current components follow Kodachi OS version 9.0.1 licensing.

## Contact

- **Author**: Warith Al Maawali
- **Website**: https://www.digi77.com
- **GitHub**: https://github.com/WMAL  
- **Discord**: https://discord.gg/KEFErEx
- **LinkedIn**: https://www.linkedin.com/in/warith1977
- **X (Twitter)**: https://x.com/warith2020

---

*This documentation preserves the historical record of Kodachi OS version 8.27 components and serves as a reference for the system's architectural evolution.*
