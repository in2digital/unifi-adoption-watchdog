# ==========================================
# UniFi Adoption Watchdog
# https://github.com/in2digital/unifi-adoption-watchdog
# Dry-Run Mode: Shows what would happen without making changes
# ==========================================

param(
    [switch]$DryRun = $true,
    [switch]$Force = $false
)

# Configuration
$Controller = "https://your-controller-url.com"
$ControllerUser = "your-username"
$ControllerPass = "your-password"
$InformURL = "http://your-controller-url.com/inform"

# Optional: Manually specify AP IP addresses (comma-separated) to process with default credentials
# These will be processed IN ADDITION to devices from the controller
# Leave empty ("") to only process controller devices
$ManualAPAddresses = ""  # Example: "192.168.1.10,192.168.1.11,192.168.1.12"

# Setup SSL/TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# Logging function
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "White" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "ACTION" { "Cyan" }
        default { "White" }
    }
    Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

# Check if Posh-SSH is installed
Write-Log "Checking for Posh-SSH module..." "INFO"
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Log "Posh-SSH module not found. Installing..." "WARNING"
    try {
        # Bootstrap NuGet and install Posh-SSH completely non-interactively
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        # Download and install NuGet provider manually to avoid prompts
        $nugetUrl = "https://onegetcdn.azureedge.net/providers/Microsoft.PackageManagement.NuGetProvider-2.8.5.208.dll"
        $nugetPath = "$env:LOCALAPPDATA\PackageManagement\ProviderAssemblies"
        
        if (-not (Test-Path $nugetPath)) {
            New-Item -Path $nugetPath -ItemType Directory -Force | Out-Null
        }
        
        $nugetDll = Join-Path $nugetPath "Microsoft.PackageManagement.NuGetProvider-2.8.5.208.dll"
        
        if (-not (Test-Path $nugetDll)) {
            Write-Log "Downloading NuGet provider..." "INFO"
            Invoke-WebRequest -Uri $nugetUrl -OutFile $nugetDll -UseBasicParsing
            Write-Log "NuGet provider downloaded" "SUCCESS"
        }
        
        # Import the NuGet provider
        Import-PackageProvider -Name NuGet -RequiredVersion 2.8.5.208 -Force | Out-Null
        
        # Set PSGallery as trusted
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        
        # Install Posh-SSH (should now work without prompts)
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber -SkipPublisherCheck -Confirm:$false -ErrorAction Stop
        Write-Log "Posh-SSH installed successfully" "SUCCESS"
    }
    catch {
        Write-Log "Failed to install Posh-SSH: $($_.Exception.Message)" "ERROR"
        Write-Log "Please run: Install-Module -Name Posh-SSH -Force" "ERROR"
        exit 1
    }
}
Import-Module Posh-SSH

Write-Log "=== UniFi Adoption Watchdog ===" "INFO"
if ($DryRun) {
    Write-Log "DRY-RUN MODE: No changes will be made" "WARNING"
} else {
    Write-Log "LIVE MODE: Changes will be applied" "WARNING"
}
Write-Log "" "INFO"

# Create session container
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# Login to controller
Write-Log "Connecting to UniFi Controller: $Controller" "INFO"
$loginBody = @{
    username = $ControllerUser
    password = $ControllerPass
} | ConvertTo-Json

try {
    $loginParams = @{
        Uri = "$Controller/api/login"
        Method = 'POST'
        Body = $loginBody
        ContentType = 'application/json'
        WebSession = $session
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    $login = Invoke-WebRequest @loginParams
    Write-Log "Successfully authenticated to controller" "SUCCESS"
}
catch {
    Write-Log "Failed to login to controller: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Get sites
Write-Log "Retrieving site information..." "INFO"
try {
    $sitesParams = @{
        Uri = "$Controller/api/self/sites"
        WebSession = $session
        Method = 'GET'
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    $sites = Invoke-WebRequest @sitesParams
    $sitesJson = $sites.Content | ConvertFrom-Json
    $siteName = $sitesJson.data[0].name
    $siteDesc = $sitesJson.data[0].desc
    Write-Log "Site: $siteDesc (ID: $siteName)" "SUCCESS"
}
catch {
    Write-Log "Failed to retrieve sites: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Get SSH credentials from controller
Write-Log "Retrieving device SSH credentials from controller..." "INFO"
try {
    $settingsParams = @{
        Uri = "$Controller/api/s/$siteName/get/setting"
        WebSession = $session
        Method = 'GET'
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    $settings = Invoke-WebRequest @settingsParams
    $settingsJson = $settings.Content | ConvertFrom-Json
    $mgmtSettings = $settingsJson.data | Where-Object { $_.key -eq 'mgmt' }
    
    if ($mgmtSettings -and $mgmtSettings.x_ssh_username -and $mgmtSettings.x_ssh_password) {
        $sshUser = $mgmtSettings.x_ssh_username
        $sshPass = $mgmtSettings.x_ssh_password
        Write-Log "SSH Credentials retrieved: $sshUser / [password hidden]" "SUCCESS"
    } else {
        Write-Log "SSH credentials not found in controller, using defaults (ubnt/ubnt)" "WARNING"
        $sshUser = "ubnt"
        $sshPass = "ubnt"
    }
}
catch {
    Write-Log "Failed to retrieve SSH credentials: $($_.Exception.Message)" "WARNING"
    Write-Log "Using default credentials (ubnt/ubnt)" "WARNING"
    $sshUser = "ubnt"
    $sshPass = "ubnt"
}

# Get devices
Write-Log "Retrieving device list..." "INFO"
try {
    $devicesParams = @{
        Uri = "$Controller/api/s/$siteName/stat/device"
        WebSession = $session
        Method = 'GET'
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    $devices = Invoke-WebRequest @devicesParams
    $devicesJson = $devices.Content | ConvertFrom-Json
    Write-Log "Found $($devicesJson.data.Count) devices" "SUCCESS"
}
catch {
    Write-Log "Failed to retrieve devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Process each device
$summary = @{
    Total = 0
    Adopted = 0
    NeedsReAdoption = 0
    Failed = 0
    Skipped = 0
}

Write-Log "" "INFO"
Write-Log "=== Processing Devices ===" "INFO"
Write-Log "" "INFO"

foreach ($device in $devicesJson.data) {
    $summary.Total++
    $deviceName = $device.name
    $deviceMAC = $device.mac
    $deviceIP = $device.ip
    $deviceID = $device._id
    
    Write-Log "Device: $deviceName (MAC: $deviceMAC, IP: $deviceIP)" "INFO"
    
    # SSH to device and check adoption status
    Write-Log "  Checking adoption status via SSH..." "ACTION"
    Write-Log "  Controller shows: state=$($device.state), adopted=$($device.adopted)" "INFO"
    
    # ALWAYS verify via SSH - controller state can be wrong for devices with bad flash
    # Try multiple credential sets in case device reset itself
    $credentialSets = @(
        @{User = $sshUser; Pass = $sshPass; Label = "controller credentials"},
        @{User = "ubnt"; Pass = "ubnt"; Label = "default credentials (ubnt/ubnt)"}
    )
    
    $sshSession = $null
    $credUsed = $null
    
    foreach ($credSet in $credentialSets) {
        try {
            Write-Log "  Trying SSH with $($credSet.Label)..." "INFO"
            $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
            
            # Create SSH session with shell stream
            $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ErrorAction Stop
            $credUsed = $credSet
            Write-Log "  SSH connection established using $($credSet.Label)" "SUCCESS"
            break
        }
        catch {
            Write-Log "  Failed with $($credSet.Label): $($_.Exception.Message)" "WARNING"
        }
    }
    
    if ($null -eq $sshSession) {
        Write-Log "  All SSH credential attempts failed - skipping device" "ERROR"
        $summary.Failed++
        Write-Log "" "INFO"
        continue
    }
    
    try {
        
        # Create shell stream for interactive commands
        $stream = New-SSHShellStream -SessionId $sshSession.SessionId
        Start-Sleep -Milliseconds 500  # Wait for shell to be ready
        
        # Clear any initial output
        $stream.Read() | Out-Null
        
        # Send info command
        $stream.WriteLine("info")
        Start-Sleep -Seconds 2  # Wait for command to execute
        
        # Read the output
        $fullOutput = $stream.Read()
        
        Write-Log "  SSH command output:" "INFO"
        foreach ($line in $fullOutput -split "`n") {
            if ($line.Trim() -ne "") {
                Write-Log "    $line" "INFO"
            }
        }
        
        # Check if device shows as connected/adopted with CORRECT inform URL
        # Extract the hostname from InformURL for matching
        $informHost = ([System.Uri]$InformURL).Host
        if ($fullOutput -match "Status:\s+Connected.*$([regex]::Escape($informHost))") {
            $isAdopted = $true
            Write-Log "  Device Status: ADOPTED (Connected with correct inform URL)" "SUCCESS"
        }
        elseif ($fullOutput -match "Status:\s+Managed by.*$([regex]::Escape($informHost))") {
            $isAdopted = $true
            Write-Log "  Device Status: ADOPTED (Managed with correct inform URL)" "SUCCESS"
        }
        elseif ($fullOutput -match "Status:\s+Connected") {
            $isAdopted = $false
            Write-Log "  Device Status: WRONG INFORM URL (needs re-adoption)" "WARNING"
            Write-Log "  Current inform URL does not match expected: $InformURL" "WARNING"
        }
        else {
            $isAdopted = $false
            Write-Log "  Device Status: NOT ADOPTED (needs re-adoption)" "WARNING"
        }
        
        # Close stream and session
        $stream.Dispose()
        Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
    }
    catch {
        Write-Log "  SSH connection failed: $($_.Exception.Message)" "ERROR"
        Write-Log "  Cannot verify adoption status - skipping device" "ERROR"
        $summary.Failed++
        Write-Log "" "INFO"
        continue
    }
    
    try {
        
        if ($isAdopted) {
            Write-Log "  Status: ADOPTED - Device is properly managed" "SUCCESS"
            $summary.Adopted++
            
            if ($DryRun) {
                Write-Log "  [DRY-RUN] Would skip this device (already adopted)" "INFO"
            }
        }
        else {
            Write-Log "  Status: NOT ADOPTED - Device needs re-adoption" "WARNING"
            $summary.NeedsReAdoption++
            
            if ($DryRun) {
                Write-Log "  [DRY-RUN] Would perform the following actions:" "ACTION"
                Write-Log "    1. Factory reset device (syswrapper.sh restore-default)" "ACTION"
                Write-Log "    2. Delete device from controller (MAC: $deviceMAC)" "ACTION"
                Write-Log "    3. Wait 180 seconds for device to reboot" "ACTION"
                Write-Log "    4. Reconnect with default credentials (ubnt/ubnt)" "ACTION"
                Write-Log "    5. SSH to device and run: set-inform $InformURL" "ACTION"
                Write-Log "    6. Wait 45 seconds for device to contact controller" "ACTION"
                Write-Log "    7. Auto-approve adoption request" "ACTION"
            }
            else {
                Write-Log "  Performing re-adoption..." "ACTION"
                
                # Step 1: Factory reset the device FIRST
                Write-Log "    Step 1: Factory resetting device..." "ACTION"
                try {
                    # Reconnect with the credentials that worked
                    $securePass = ConvertTo-SecureString $credUsed.Pass -AsPlainText -Force
                    $credential = New-Object System.Management.Automation.PSCredential($credUsed.User, $securePass)
                    
                    $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ErrorAction Stop
                    
                    # Use shell stream for factory reset
                    $stream = New-SSHShellStream -SessionId $sshSession.SessionId
                    Start-Sleep -Milliseconds 500
                    
                    # Clear initial output
                    $stream.Read() | Out-Null
                    
                    # Send factory reset command
                    Write-Log "    Sending: syswrapper.sh restore-default" "INFO"
                    $stream.WriteLine("syswrapper.sh restore-default")
                    Start-Sleep -Seconds 2
                    
                    # Read response
                    $response = $stream.Read()
                    Write-Log "    Response: $response" "INFO"
                    
                    Write-Log "    Factory reset initiated - device will reboot..." "SUCCESS"
                    
                    $stream.Dispose()
                    Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
                }
                catch {
                    Write-Log "    Failed to factory reset device: $($_.Exception.Message)" "ERROR"
                    $summary.Failed++
                    continue
                }
                
                # Step 2: Delete device from controller while it's rebooting
                Write-Log "    Step 2: Deleting device from controller..." "ACTION"
                try {
                    $deleteBody = @{
                        mac = $deviceMAC
                        cmd = "delete-device"
                    } | ConvertTo-Json
                    
                    $deleteParams = @{
                        Uri = "$Controller/api/s/$siteName/cmd/sitemgr"
                        Method = 'POST'
                        Body = $deleteBody
                        ContentType = 'application/json'
                        WebSession = $session
                        UseBasicParsing = $true
                        ErrorAction = 'Stop'
                    }
                    $deleteResult = Invoke-WebRequest @deleteParams
                    Write-Log "    Device deleted from controller successfully" "SUCCESS"
                }
                catch {
                    Write-Log "    Delete command failed: $($_.Exception.Message)" "WARNING"
                    Write-Log "    Continuing anyway..." "INFO"
                }
                
                # Step 3: Wait for device to finish rebooting
                Write-Log "    Step 3: Waiting for device to complete factory reset and reboot..." "ACTION"
                Write-Log "    Initial wait of 60 seconds..." "INFO"
                Start-Sleep -Seconds 60
                
                # Step 4: Reconnect after reset with extended retries and multiple credential sets
                Write-Log "    Step 4: Reconnecting to device after reset..." "ACTION"
                try {
                    # Try multiple credential sets - some devices keep controller creds, some reset to defaults
                    $reconnectCredSets = @(
                        @{User = "ubnt"; Pass = "ubnt"; Label = "default (ubnt/ubnt)"},
                        @{User = $credUsed.User; Pass = $credUsed.Pass; Label = "previous credentials ($($credUsed.User))"},
                        @{User = "root"; Pass = "ubnt"; Label = "alternate (root/ubnt)"},
                        @{User = "admin"; Pass = "admin"; Label = "alternate (admin/admin)"}
                    )
                    
                    # Try to reconnect (up to 10 attempts over 5 minutes)
                    $reconnected = $false
                    for ($i = 1; $i -le 10; $i++) {
                        Write-Log "    Reconnection attempt $i/10..." "INFO"
                        
                        foreach ($credSet in $reconnectCredSets) {
                            try {
                                Write-Log "    Trying $($credSet.Label)..." "INFO"
                                $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
                                $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
                                $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop
                                $reconnected = $true
                                Write-Log "    Reconnected successfully with $($credSet.Label) on attempt $i" "SUCCESS"
                                break
                            }
                            catch {
                                Write-Log "    Failed with $($credSet.Label): $($_.Exception.Message)" "WARNING"
                            }
                        }
                        
                        if ($reconnected) { break }
                        
                        if ($i -lt 10) {
                            Write-Log "    All credentials failed. Waiting 30 seconds before next attempt..." "INFO"
                            Start-Sleep -Seconds 30
                        }
                    }
                    
                    if (-not $reconnected) {
                        Write-Log "    Failed to reconnect after factory reset (10 attempts with all credential sets)" "ERROR"
                        Write-Log "    Device may need manual intervention or more time to reboot" "ERROR"
                        $summary.Failed++
                        continue
                    }
                    
                    # Use shell stream for set-inform command
                    $stream = New-SSHShellStream -SessionId $sshSession.SessionId
                    Start-Sleep -Milliseconds 500
                    
                    # Clear initial output
                    $stream.Read() | Out-Null
                    
                    # Send set-inform command
                    Write-Log "    Sending: set-inform $InformURL" "INFO"
                    $stream.WriteLine("set-inform $InformURL")
                    Start-Sleep -Seconds 2
                    
                    # Read response
                    $response = $stream.Read()
                    Write-Log "    Response: $response" "INFO"
                    
                    # Verify it was set by running info command
                    $stream.WriteLine("info")
                    Start-Sleep -Seconds 2
                    $infoOutput = $stream.Read()
                    Write-Log "    Verification output: $infoOutput" "INFO"
                    
                    if ($infoOutput -match "Status:.*$([regex]::Escape($informHost))") {
                        Write-Log "    Adoption request sent and verified" "SUCCESS"
                    }
                    else {
                        Write-Log "    Warning: Could not verify inform URL was set" "WARNING"
                    }
                    
                    $stream.Dispose()
                    Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
                }
                catch {
                    Write-Log "    Failed to send adoption request: $($_.Exception.Message)" "ERROR"
                    $summary.Failed++
                    continue
                }
                
                # Step 4: Wait for device to contact controller
                Write-Log "    Step 4: Waiting for device to contact controller..." "ACTION"
                Write-Log "    This may take up to 45 seconds..." "INFO"
                Start-Sleep -Seconds 45
                
                # Check if device appeared in controller
                Write-Log "    Checking for device in controller..." "ACTION"
                try {
                    $checkDevicesParams = @{
                        Uri = "$Controller/api/s/$siteName/stat/device"
                        WebSession = $session
                        Method = 'GET'
                        UseBasicParsing = $true
                        ErrorAction = 'Stop'
                    }
                    $checkDevices = Invoke-WebRequest @checkDevicesParams
                    $checkDevicesJson = $checkDevices.Content | ConvertFrom-Json
                    
                    $pendingDevice = $checkDevicesJson.data | Where-Object { $_.mac -eq $deviceMAC }
                    
                    if ($pendingDevice) {
                        Write-Log "    Device found in controller (ID: $($pendingDevice._id))" "SUCCESS"
                        $newDeviceID = $pendingDevice._id
                    }
                    else {
                        Write-Log "    Device not found in controller yet - may need more time" "WARNING"
                        Write-Log "    You may need to manually adopt the device from the controller UI" "WARNING"
                        $summary.Failed++
                        continue
                    }
                }
                catch {
                    Write-Log "    Failed to check for device: $($_.Exception.Message)" "ERROR"
                    $summary.Failed++
                    continue
                }
                
                # Step 5: Auto-approve adoption
                Write-Log "    Step 5: Auto-approving adoption..." "ACTION"
                Write-Log "    Device state: $($pendingDevice.state), Type: $($pendingDevice.type)" "INFO"
                
                try {
                    # Try using device ID in the adopt command
                    $adoptBody = @{
                        cmd = "adopt"
                        mac = $deviceMAC
                    } | ConvertTo-Json
                    
                    Write-Log "    Sending adopt command with body: $adoptBody" "INFO"
                    
                    $adoptParams = @{
                        Uri = "$Controller/api/s/$siteName/cmd/devmgr"
                        Method = 'POST'
                        Body = $adoptBody
                        ContentType = 'application/json'
                        WebSession = $session
                        UseBasicParsing = $true
                        ErrorAction = 'Stop'
                    }
                    $adoptResult = Invoke-WebRequest @adoptParams
                    $adoptResponse = $adoptResult.Content | ConvertFrom-Json
                    
                    Write-Log "    API Response: $($adoptResult.Content)" "INFO"
                    Write-Log "    Adoption command sent successfully!" "SUCCESS"
                    
                    # Wait for adoption to complete (can take up to 5 minutes)
                    Write-Log "    Waiting for adoption to complete..." "ACTION"
                    Write-Log "    This may take up to 5 minutes..." "INFO"
                    
                    $adoptionComplete = $false
                    $maxAttempts = 30  # 30 attempts x 10 seconds = 5 minutes
                    
                    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                        Start-Sleep -Seconds 10
                        
                        try {
                            $verifyParams = @{
                                Uri = "$Controller/api/s/$siteName/stat/device"
                                WebSession = $session
                                Method = 'GET'
                                UseBasicParsing = $true
                                ErrorAction = 'Stop'
                            }
                            $verifyDevices = Invoke-WebRequest @verifyParams
                            $verifyJson = $verifyDevices.Content | ConvertFrom-Json
                            $verifiedDevice = $verifyJson.data | Where-Object { $_.mac -eq $deviceMAC }
                            
                            if ($verifiedDevice) {
                                Write-Log "    Check $attempt/$maxAttempts - State: $($verifiedDevice.state)" "INFO"
                                
                                if ($verifiedDevice.state -eq 1) {
                                    Write-Log "    Device re-adopted successfully! (State: 1 - Connected)" "SUCCESS"
                                    $adoptionComplete = $true
                                    break
                                }
                            }
                        }
                        catch {
                            Write-Log "    Verification attempt $attempt failed: $($_.Exception.Message)" "WARNING"
                        }
                    }
                    
                    if (-not $adoptionComplete) {
                        Write-Log "    Adoption may still be in progress after 5 minutes" "WARNING"
                        Write-Log "    Final state: $($verifiedDevice.state)" "INFO"
                        Write-Log "    State 5 = Upgrading firmware, State 7 = Provisioning" "INFO"
                        Write-Log "    Check controller UI to verify adoption completed" "INFO"
                    }
                }
                catch {
                    Write-Log "    Failed to approve adoption: $($_.Exception.Message)" "ERROR"
                    Write-Log "    Device may be visible in controller - try manual adoption" "WARNING"
                    $summary.Failed++
                    continue
                }
            }
        }
    }
    catch {
        Write-Log "  Failed to connect via SSH: $($_.Exception.Message)" "ERROR"
        $summary.Failed++
        
        if ($DryRun) {
            Write-Log "  [DRY-RUN] Would skip this device due to SSH failure" "WARNING"
        }
    }
    
    Write-Log "" "INFO"
}

# Summary
Write-Log "=== Summary ===" "INFO"
Write-Log "Total Devices: $($summary.Total)" "INFO"
Write-Log "Already Adopted: $($summary.Adopted)" "SUCCESS"
Write-Log "Need Re-Adoption: $($summary.NeedsReAdoption)" "WARNING"
Write-Log "Failed: $($summary.Failed)" "ERROR"

if ($DryRun) {
    Write-Log "" "INFO"
    Write-Log "This was a DRY-RUN. No changes were made." "WARNING"
    Write-Log "To apply changes, run with -DryRun:`$false" "INFO"
}