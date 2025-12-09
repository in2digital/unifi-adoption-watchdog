# UniFi Adoption Watchdog

PowerShell watchdog scripts for automatically monitoring and re-adopting UniFi Access Points that have lost connection to their controller. This tool is particularly useful for devices with faulty flash memory that periodically lose their adoption settings.

## Features

- **Automatic Detection**: Verifies adoption status via SSH to each device
- **Smart Re-adoption**: Only processes devices that need re-adoption
- **Dual Credential Support**: Tries both controller-configured and default credentials
- **Factory Reset & Re-adoption**: Fully automates the re-adoption process
- **Dry-Run Mode**: Preview changes before applying them (standard version)
- **Action1 Compatible**: Includes version optimized for Action1 RMM automation
- **Comprehensive Logging**: Detailed color-coded output for easy troubleshooting

## Prerequisites

- **PowerShell 5.1 or later**
- **Posh-SSH Module**: Automatically installed if missing
- **Network Access**: Direct network access to UniFi devices and controller
- **UniFi Controller**: Running and accessible via HTTPS

## Installation

1. Clone this repository:
```powershell
git clone https://github.com/in2digital/unifi-adoption-watchdog.git
cd unifi-adoption-watchdog
```

2. Configure your credentials (see Configuration section below)

3. The Posh-SSH module will be automatically installed on first run if not present

## Configuration

Before running the scripts, you **must** configure your UniFi Controller credentials and URLs.

### For `Start-UniFiAdoptionWatchdog.ps1`:

Edit lines 12-15 in the script:

```powershell
# Configuration
$Controller = "https://your-controller-url.com"
$ControllerUser = "your-username"
$ControllerPass = "your-password"
$InformURL = "http://your-controller-url.com/inform"
```

### For `Start-UniFiAdoptionWatchdog-Action1.ps1`:

Edit lines 9-12 in the script:

```powershell
# Configuration
$Controller = "https://your-controller-url.com"
$ControllerUser = "your-username"
$ControllerPass = "your-password"
$InformURL = "http://your-controller-url.com/inform"
```

**Important**: Replace the placeholder values with your actual:
- **Controller URL**: Your UniFi Controller's HTTPS address
- **Username**: UniFi Controller admin username
- **Password**: UniFi Controller admin password
- **Inform URL**: The HTTP inform URL for device adoption

## Usage

### Standard Version (Interactive)

**Dry-Run Mode** (recommended first run):
```powershell
.\Start-UniFiAdoptionWatchdog.ps1
```

**Live Mode** (applies changes):
```powershell
.\Start-UniFiAdoptionWatchdog.ps1 -DryRun:$false
```

**Force Mode** (skip confirmations):
```powershell
.\Start-UniFiAdoptionWatchdog.ps1 -DryRun:$false -Force
```

### Action1 Version (Automation)

Schedule to run hourly on a system that is online 24/7 and has a wired connection to the same network as the APs (not connected via the APs being managed).

```powershell
.\Start-UniFiAdoptionWatchdog-Action1.ps1
```

This version:
- Runs automatically without user interaction
- Outputs to console for log capture
- Auto-installs dependencies non-interactively
- Returns appropriate exit codes (0 = success, 1 = failure)

## How It Works

The script performs the following steps for each device that needs re-adoption:

1. **Authentication**: Logs into the UniFi Controller
2. **Device Discovery**: Retrieves all devices from the controller
3. **SSH Verification**: Connects to each device via SSH to verify actual adoption status
4. **Factory Reset**: Resets devices that need re-adoption
5. **Controller Cleanup**: Removes old device entry from controller
6. **Wait Period**: Allows device to complete reboot (180 seconds)
7. **Reconnection**: Establishes new SSH connection with default credentials
8. **Set Inform URL**: Configures device to contact the controller
9. **Auto-Adoption**: Automatically approves the adoption request
10. **Verification**: Monitors adoption status until complete (up to 5 minutes)

## SSH Credentials

The script automatically retrieves SSH credentials from the UniFi Controller settings. If not configured, it falls back to default credentials (`ubnt/ubnt`).

For devices that have reset themselves, the script tries:
1. Controller-configured credentials
2. Default credentials (`ubnt/ubnt`)

## Output Examples

### Dry-Run Mode
```
[2025-12-09 13:07:15] INFO: === UniFi AP Re-Adoption Script ===
[2025-12-09 13:07:15] WARNING: DRY-RUN MODE: No changes will be made
[2025-12-09 13:07:16] SUCCESS: Successfully authenticated to controller
[2025-12-09 13:07:16] SUCCESS: Site: Default (ID: default)
[2025-12-09 13:07:17] SUCCESS: Found 5 devices
[2025-12-09 13:07:18] INFO: Device: AP-Office (MAC: aa:bb:cc:dd:ee:ff, IP: 192.168.1.100)
[2025-12-09 13:07:19] SUCCESS: Device Status: ADOPTED (Connected with correct inform URL)
[2025-12-09 13:07:19] INFO: [DRY-RUN] Would skip this device (already adopted)
```

### Live Mode
```
[2025-12-09 13:10:20] ACTION: Performing re-adoption...
[2025-12-09 13:10:20] ACTION:   Step 1: Factory resetting device...
[2025-12-09 13:10:22] SUCCESS:   Factory reset initiated - device will reboot...
[2025-12-09 13:10:22] ACTION:   Step 2: Deleting device from controller...
[2025-12-09 13:10:23] SUCCESS:   Device deleted from controller successfully
[2025-12-09 13:10:23] ACTION:   Step 3: Waiting for device to complete factory reset and reboot...
```

## Troubleshooting

### SSH Connection Failures
- Verify network connectivity to devices
- Check firewall rules allow SSH (port 22)
- Ensure SSH is enabled on UniFi devices
- Try manually SSH'ing to verify credentials

### Adoption Failures
- Verify inform URL is correct and accessible
- Check controller is running and accessible
- Ensure devices can reach the controller on the network
- Review controller logs for adoption errors

### Module Installation Issues
If Posh-SSH fails to install automatically:
```powershell
Install-Module -Name Posh-SSH -Force -Scope CurrentUser
```

## Security Considerations

⚠️ **Important Security Notes**:

1. **Credential Storage**: This script stores credentials in plain text. Consider:
   - Using environment variables
   - Implementing credential encryption
   - Restricting file permissions
   - Using a secrets management solution

2. **SSL Certificate Validation**: The script disables SSL certificate validation for self-signed certificates. In production:
   - Use valid SSL certificates
   - Remove the `TrustAllCertsPolicy` code
   - Enable proper certificate validation

3. **Network Security**: 
   - Run from a secure, trusted network
   - Use VPN if accessing remotely
   - Implement network segmentation

## Version Differences

| Feature | Standard Version | Action1 Version |
|---------|-----------------|-----------------|
| Dry-Run Mode | ✅ Yes | ❌ No |
| Interactive | ✅ Yes | ❌ No |
| Color Output | ✅ Yes | ❌ No |
| Auto-Install Dependencies | ⚠️ Interactive | ✅ Non-Interactive |
| Exit Codes | ❌ No | ✅ Yes |
| Best For | Manual execution | Automation/RMM |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is provided as-is without warranty. Use at your own risk.

## Acknowledgments

- Built for UniFi Network devices
- Uses the Posh-SSH PowerShell module
- Designed to handle devices with faulty flash memory

## Support

For issues, questions, or contributions, please open an issue on GitHub.

---

**Disclaimer**: This script performs factory resets and device deletions. Always test in a non-production environment first and ensure you have backups of your configuration.