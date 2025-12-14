# ==========================================
# UniFi Adoption Watchdog
# https://github.com/in2digital/unifi-adoption-watchdog
# Action1 Automation Compatible Version
# ==========================================

# No parameters needed - Action1 handles logging

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

# Logging function - outputs to console for Action1 to capture
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] ${Level}: $Message"
}

# Check and install Posh-SSH if needed (non-interactive)
try {
    Import-Module Posh-SSH -ErrorAction Stop
    Write-Log "Posh-SSH module loaded" "INFO"
}
catch {
    Write-Log "Posh-SSH not found - attempting installation..." "WARNING"
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
        Import-Module Posh-SSH -ErrorAction Stop
        Write-Log "Posh-SSH installed and loaded successfully" "SUCCESS"
    }
    catch {
        Write-Log "Failed to install Posh-SSH: $($_.Exception.Message)" "ERROR"
        Write-Log "Manual installation required: Install-Module -Name Posh-SSH -Force -Scope CurrentUser" "ERROR"
        exit 1
    }
}

Write-Log "=== UniFi Adoption Watchdog (Action1 Version) ===" "INFO"

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
        Write-Log "SSH Credentials retrieved from controller" "SUCCESS"
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
}

Write-Log "=== Processing Devices ===" "INFO"

# Track processed IPs to avoid duplicates
$processedIPs = @()

# Process controller devices first
foreach ($device in $devicesJson.data) {
    $summary.Total++
    $deviceName = $device.name
    $deviceMAC = $device.mac
    $deviceIP = $device.ip
    $deviceID = $device._id
    $processedIPs += $deviceIP
    
    Write-Log "Device: $deviceName (MAC: $deviceMAC, IP: $deviceIP)" "INFO"
    
    # Try multiple credential sets
    $credentialSets = @(
        @{User = $sshUser; Pass = $sshPass; Label = "controller credentials"},
        @{User = "ubnt"; Pass = "ubnt"; Label = "default credentials"}
    )
    
    $sshSession = $null
    $credUsed = $null
    
    foreach ($credSet in $credentialSets) {
        try {
            $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
            $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ErrorAction Stop
            $credUsed = $credSet
            Write-Log "  SSH connected using $($credSet.Label)" "SUCCESS"
            break
        }
        catch {
            Write-Log "  Failed with $($credSet.Label)" "WARNING"
        }
    }
    
    if ($null -eq $sshSession) {
        Write-Log "  All SSH attempts failed - skipping device" "ERROR"
        $summary.Failed++
        continue
    }
    
    try {
        # Check adoption status
        $stream = New-SSHShellStream -SessionId $sshSession.SessionId
        Start-Sleep -Milliseconds 500
        $stream.Read() | Out-Null
        
        $stream.WriteLine("info")
        Start-Sleep -Seconds 2
        $fullOutput = $stream.Read()
        
        # Check for correct inform URL
        # Extract the hostname from InformURL for matching
        $informHost = ([System.Uri]$InformURL).Host
        if ($fullOutput -match "Status:\s+Connected.*$([regex]::Escape($informHost))") {
            $isAdopted = $true
            Write-Log "  Status: ADOPTED (correct inform URL)" "SUCCESS"
        }
        elseif ($fullOutput -match "Status:\s+Connected") {
            $isAdopted = $false
            Write-Log "  Status: WRONG INFORM URL - needs re-adoption" "WARNING"
        }
        else {
            $isAdopted = $false
            Write-Log "  Status: NOT ADOPTED - needs re-adoption" "WARNING"
        }
        
        $stream.Dispose()
        Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
    }
    catch {
        Write-Log "  SSH check failed: $($_.Exception.Message)" "ERROR"
        $summary.Failed++
        continue
    }
    
    if ($isAdopted) {
        $summary.Adopted++
        Write-Log "  Skipping - already adopted" "INFO"
    }
    else {
        $summary.NeedsReAdoption++
        Write-Log "  Performing re-adoption..." "ACTION"
        
        # Step 1: Factory reset
        Write-Log "    Step 1: Factory resetting device..." "ACTION"
        try {
            $securePass = ConvertTo-SecureString $credUsed.Pass -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($credUsed.User, $securePass)
            $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ErrorAction Stop
            
            $stream = New-SSHShellStream -SessionId $sshSession.SessionId
            Start-Sleep -Milliseconds 500
            $stream.Read() | Out-Null
            
            $stream.WriteLine("syswrapper.sh restore-default")
            Start-Sleep -Seconds 2
            $response = $stream.Read()
            
            Write-Log "    Factory reset initiated" "SUCCESS"
            
            $stream.Dispose()
            Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
        }
        catch {
            Write-Log "    Factory reset failed: $($_.Exception.Message)" "ERROR"
            $summary.Failed++
            continue
        }
        
        # Step 2: Delete from controller
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
            Invoke-WebRequest @deleteParams | Out-Null
            Write-Log "    Device deleted successfully" "SUCCESS"
        }
        catch {
            Write-Log "    Delete failed (continuing anyway)" "WARNING"
        }
        
        # Step 3: Wait for reboot and reconnect with retries
        Write-Log "    Step 3: Waiting for device to reboot and become accessible..." "ACTION"
        
        # Wait initial period for device to start rebooting
        Start-Sleep -Seconds 60
        
        # Step 4: Reconnect with extended retries and multiple credential sets
        Write-Log "    Step 4: Attempting to reconnect (up to 10 attempts over 5 minutes)..." "ACTION"
        $reconnected = $false
        $reconnectSession = $null
        
        # Try multiple credential sets - some devices keep controller creds, some reset to defaults
        $reconnectCredSets = @(
            @{User = "ubnt"; Pass = "ubnt"; Label = "default (ubnt/ubnt)"},
            @{User = $credUsed.User; Pass = $credUsed.Pass; Label = "previous credentials ($($credUsed.User))"},
            @{User = "root"; Pass = "ubnt"; Label = "alternate (root/ubnt)"},
            @{User = "admin"; Pass = "admin"; Label = "alternate (admin/admin)"}
        )
        
        for ($i = 1; $i -le 10; $i++) {
            Write-Log "    Reconnection attempt $i/10..." "INFO"
            
            foreach ($credSet in $reconnectCredSets) {
                try {
                    Write-Log "    Trying $($credSet.Label)..." "INFO"
                    $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
                    $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
                    $reconnectSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop
                    $reconnected = $true
                    Write-Log "    Reconnected successfully with $($credSet.Label) on attempt $i" "SUCCESS"
                    $sshSession = $reconnectSession
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
            Write-Log "    Reconnection failed after 10 attempts with all credential sets" "ERROR"
            Write-Log "    Device may need manual intervention or more time to reboot" "ERROR"
            $summary.Failed++
            continue
        }
        
        # Step 5: Set inform URL
        Write-Log "    Step 5: Setting inform URL..." "ACTION"
        try {
            $stream = New-SSHShellStream -SessionId $sshSession.SessionId
            Start-Sleep -Milliseconds 500
            $stream.Read() | Out-Null
            
            $stream.WriteLine("set-inform $InformURL")
            Start-Sleep -Seconds 2
            $stream.Read() | Out-Null
            
            Write-Log "    Inform URL set" "SUCCESS"
            
            $stream.Dispose()
            Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
        }
        catch {
            Write-Log "    Failed to set inform URL: $($_.Exception.Message)" "ERROR"
            $summary.Failed++
            continue
        }
        
        # Step 6: Wait for device to contact controller
        Write-Log "    Step 6: Waiting 45 seconds for device to contact controller..." "ACTION"
        Start-Sleep -Seconds 45
        
        # Step 7: Check for device
        Write-Log "    Step 7: Checking for device in controller..." "ACTION"
        try {
            $checkParams = @{
                Uri = "$Controller/api/s/$siteName/stat/device"
                WebSession = $session
                Method = 'GET'
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
            $checkDevices = Invoke-WebRequest @checkParams
            $checkJson = $checkDevices.Content | ConvertFrom-Json
            $pendingDevice = $checkJson.data | Where-Object { $_.mac -eq $deviceMAC }
            
            if (-not $pendingDevice) {
                Write-Log "    Device not found in controller" "ERROR"
                $summary.Failed++
                continue
            }
            Write-Log "    Device found in controller" "SUCCESS"
        }
        catch {
            Write-Log "    Failed to check for device: $($_.Exception.Message)" "ERROR"
            $summary.Failed++
            continue
        }
        
        # Step 8: Auto-approve adoption
        Write-Log "    Step 8: Auto-approving adoption..." "ACTION"
        try {
            $adoptBody = @{
                cmd = "adopt"
                mac = $deviceMAC
            } | ConvertTo-Json
            
            $adoptParams = @{
                Uri = "$Controller/api/s/$siteName/cmd/devmgr"
                Method = 'POST'
                Body = $adoptBody
                ContentType = 'application/json'
                WebSession = $session
                UseBasicParsing = $true
                ErrorAction = 'Stop'
            }
            Invoke-WebRequest @adoptParams | Out-Null
            Write-Log "    Adoption command sent" "SUCCESS"
        }
        catch {
            Write-Log "    Adoption failed: $($_.Exception.Message)" "ERROR"
            $summary.Failed++
            continue
        }
        
        # Step 9: Monitor adoption completion
        Write-Log "    Step 9: Monitoring adoption (up to 5 minutes)..." "ACTION"
        $adoptionComplete = $false
        
        for ($attempt = 1; $attempt -le 30; $attempt++) {
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
                
                if ($verifiedDevice -and $verifiedDevice.state -eq 1) {
                    Write-Log "    Device re-adopted successfully (State: 1)" "SUCCESS"
                    $adoptionComplete = $true
                    break
                }
                
                # Log progress every 5 checks
                if ($attempt % 5 -eq 0) {
                    Write-Log "    Check $attempt/30 - State: $($verifiedDevice.state)" "INFO"
                }
            }
            catch {
                # Silently continue
            }
        }
        
        if (-not $adoptionComplete) {
            Write-Log "    Adoption incomplete after 5 minutes (State: $($verifiedDevice.state))" "WARNING"
        }
    }
}

# Process manual AP addresses if specified
if ($ManualAPAddresses -and $ManualAPAddresses.Trim() -ne "") {
    Write-Log "" "INFO"
    Write-Log "=== Processing Manual AP Addresses ===" "INFO"
    
    $manualIPs = $ManualAPAddresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    
    foreach ($manualIP in $manualIPs) {
        # Skip if already processed from controller
        if ($processedIPs -contains $manualIP) {
            Write-Log "Skipping $manualIP - already processed from controller" "INFO"
            continue
        }
        
        $summary.Total++
        $processedIPs += $manualIP
        
        Write-Log "Manual AP: $manualIP" "INFO"
        
        # Try default credentials for manual APs
        $credentialSets = @(
            @{User = "ubnt"; Pass = "ubnt"; Label = "default (ubnt/ubnt)"},
            @{User = "root"; Pass = "ubnt"; Label = "alternate (root/ubnt)"},
            @{User = $sshUser; Pass = $sshPass; Label = "controller credentials"},
            @{User = "admin"; Pass = "admin"; Label = "alternate (admin/admin)"}
        )
        
        $sshSession = $null
        $credUsed = $null
        
        foreach ($credSet in $credentialSets) {
            try {
                $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
                $sshSession = New-SSHSession -ComputerName $manualIP -Credential $credential -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop
                $credUsed = $credSet
                Write-Log "  SSH connected using $($credSet.Label)" "SUCCESS"
                break
            }
            catch {
                Write-Log "  Failed with $($credSet.Label)" "WARNING"
            }
        }
        
        if ($null -eq $sshSession) {
            Write-Log "  All SSH attempts failed - skipping device" "ERROR"
            $summary.Failed++
            continue
        }
        
        try {
            # Check adoption status and get MAC address
            $stream = New-SSHShellStream -SessionId $sshSession.SessionId
            Start-Sleep -Milliseconds 500
            $stream.Read() | Out-Null
            
            $stream.WriteLine("info")
            Start-Sleep -Seconds 2
            $fullOutput = $stream.Read()
            
            # Extract MAC address from info output
            $deviceMAC = $null
            if ($fullOutput -match "MAC Address:\s+([0-9a-fA-F:]+)") {
                $deviceMAC = $matches[1].ToLower().Replace(":", "")
                # Convert to UniFi format (with colons)
                $deviceMAC = $deviceMAC -replace '(..)', '$1:' -replace ':$', ''
                Write-Log "  Detected MAC: $deviceMAC" "INFO"
            }
            
            # Check for correct inform URL
            $informHost = ([System.Uri]$InformURL).Host
            if ($fullOutput -match "Status:\s+Connected.*$([regex]::Escape($informHost))") {
                $isAdopted = $true
                Write-Log "  Status: ADOPTED (correct inform URL)" "SUCCESS"
            }
            elseif ($fullOutput -match "Status:\s+Connected") {
                $isAdopted = $false
                Write-Log "  Status: WRONG INFORM URL - needs re-adoption" "WARNING"
            }
            else {
                $isAdopted = $false
                Write-Log "  Status: NOT ADOPTED - needs re-adoption" "WARNING"
            }
            
            $stream.Dispose()
            Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
        }
        catch {
            Write-Log "  SSH check failed: $($_.Exception.Message)" "ERROR"
            $summary.Failed++
            continue
        }
        
        if ($isAdopted) {
            $summary.Adopted++
            Write-Log "  Skipping - already adopted" "INFO"
        }
        else {
            $summary.NeedsReAdoption++
            Write-Log "  Performing re-adoption..." "ACTION"
            
            # Step 1: Factory reset
            Write-Log "    Step 1: Factory resetting device..." "ACTION"
            try {
                $securePass = ConvertTo-SecureString $credUsed.Pass -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($credUsed.User, $securePass)
                $sshSession = New-SSHSession -ComputerName $manualIP -Credential $credential -AcceptKey -ErrorAction Stop
                
                $stream = New-SSHShellStream -SessionId $sshSession.SessionId
                Start-Sleep -Milliseconds 500
                $stream.Read() | Out-Null
                
                $stream.WriteLine("syswrapper.sh restore-default")
                Start-Sleep -Seconds 2
                $response = $stream.Read()
                
                Write-Log "    Factory reset initiated" "SUCCESS"
                
                $stream.Dispose()
                Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
            }
            catch {
                Write-Log "    Factory reset failed: $($_.Exception.Message)" "ERROR"
                $summary.Failed++
                continue
            }
            
            # Step 2: Delete from controller if we have MAC address
            if ($deviceMAC) {
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
                    Invoke-WebRequest @deleteParams | Out-Null
                    Write-Log "    Device deleted successfully" "SUCCESS"
                }
                catch {
                    Write-Log "    Delete failed (continuing anyway)" "WARNING"
                }
            }
            
            # Step 3: Wait for reboot
            Write-Log "    Step 3: Waiting for device to reboot..." "ACTION"
            Start-Sleep -Seconds 60
            
            # Step 4: Reconnect
            Write-Log "    Step 4: Attempting to reconnect (up to 10 attempts)..." "ACTION"
            $reconnected = $false
            $reconnectSession = $null
            
            $reconnectCredSets = @(
                @{User = "ubnt"; Pass = "ubnt"; Label = "default (ubnt/ubnt)"},
                @{User = $credUsed.User; Pass = $credUsed.Pass; Label = "previous credentials ($($credUsed.User))"},
                @{User = "root"; Pass = "ubnt"; Label = "alternate (root/ubnt)"},
                @{User = "admin"; Pass = "admin"; Label = "alternate (admin/admin)"}
            )
            
            for ($i = 1; $i -le 10; $i++) {
                Write-Log "    Reconnection attempt $i/10..." "INFO"
                
                foreach ($credSet in $reconnectCredSets) {
                    try {
                        Write-Log "    Trying $($credSet.Label)..." "INFO"
                        $securePass = ConvertTo-SecureString $credSet.Pass -AsPlainText -Force
                        $credential = New-Object System.Management.Automation.PSCredential($credSet.User, $securePass)
                        $reconnectSession = New-SSHSession -ComputerName $manualIP -Credential $credential -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop
                        $reconnected = $true
                        Write-Log "    Reconnected successfully with $($credSet.Label) on attempt $i" "SUCCESS"
                        $sshSession = $reconnectSession
                        break
                    }
                    catch {
                        Write-Log "    Failed with $($credSet.Label): $($_.Exception.Message)" "WARNING"
                    }
                }
                
                if ($reconnected) { break }
                
                if ($i -lt 10) {
                    Write-Log "    All credentials failed. Waiting 30 seconds..." "INFO"
                    Start-Sleep -Seconds 30
                }
            }
            
            if (-not $reconnected) {
                Write-Log "    Reconnection failed after 10 attempts" "ERROR"
                $summary.Failed++
                continue
            }
            
            # Step 5: Set inform URL
            Write-Log "    Step 5: Setting inform URL..." "ACTION"
            try {
                $stream = New-SSHShellStream -SessionId $sshSession.SessionId
                Start-Sleep -Milliseconds 500
                $stream.Read() | Out-Null
                
                $stream.WriteLine("set-inform $InformURL")
                Start-Sleep -Seconds 2
                $stream.Read() | Out-Null
                
                Write-Log "    Inform URL set" "SUCCESS"
                
                $stream.Dispose()
                Remove-SSHSession -SessionId $sshSession.SessionId | Out-Null
            }
            catch {
                Write-Log "    Failed to set inform URL: $($_.Exception.Message)" "ERROR"
                $summary.Failed++
                continue
            }
            
            # If we have MAC address, try to auto-adopt
            if ($deviceMAC) {
                # Step 6: Wait for device to contact controller
                Write-Log "    Step 6: Waiting 45 seconds for device to contact controller..." "ACTION"
                Start-Sleep -Seconds 45
                
                # Step 7: Check for device
                Write-Log "    Step 7: Checking for device in controller..." "ACTION"
                try {
                    $checkParams = @{
                        Uri = "$Controller/api/s/$siteName/stat/device"
                        WebSession = $session
                        Method = 'GET'
                        UseBasicParsing = $true
                        ErrorAction = 'Stop'
                    }
                    $checkDevices = Invoke-WebRequest @checkParams
                    $checkJson = $checkDevices.Content | ConvertFrom-Json
                    $pendingDevice = $checkJson.data | Where-Object { $_.mac -eq $deviceMAC }
                    
                    if (-not $pendingDevice) {
                        Write-Log "    Device not found in controller" "WARNING"
                        Write-Log "    Manual adoption may be required from controller UI" "INFO"
                    }
                    else {
                        Write-Log "    Device found in controller" "SUCCESS"
                        
                        # Step 8: Auto-approve adoption
                        Write-Log "    Step 8: Auto-approving adoption..." "ACTION"
                        try {
                            $adoptBody = @{
                                cmd = "adopt"
                                mac = $deviceMAC
                            } | ConvertTo-Json
                            
                            $adoptParams = @{
                                Uri = "$Controller/api/s/$siteName/cmd/devmgr"
                                Method = 'POST'
                                Body = $adoptBody
                                ContentType = 'application/json'
                                WebSession = $session
                                UseBasicParsing = $true
                                ErrorAction = 'Stop'
                            }
                            Invoke-WebRequest @adoptParams | Out-Null
                            Write-Log "    Adoption command sent" "SUCCESS"
                            
                            # Step 9: Monitor adoption completion
                            Write-Log "    Step 9: Monitoring adoption (up to 5 minutes)..." "ACTION"
                            $adoptionComplete = $false
                            
                            for ($attempt = 1; $attempt -le 30; $attempt++) {
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
                                    
                                    if ($verifiedDevice -and $verifiedDevice.state -eq 1) {
                                        Write-Log "    Device re-adopted successfully (State: 1)" "SUCCESS"
                                        $adoptionComplete = $true
                                        break
                                    }
                                    
                                    # Log progress every 5 checks
                                    if ($attempt % 5 -eq 0) {
                                        Write-Log "    Check $attempt/30 - State: $($verifiedDevice.state)" "INFO"
                                    }
                                }
                                catch {
                                    # Silently continue
                                }
                            }
                            
                            if (-not $adoptionComplete) {
                                Write-Log "    Adoption incomplete after 5 minutes (State: $($verifiedDevice.state))" "WARNING"
                            }
                        }
                        catch {
                            Write-Log "    Adoption failed: $($_.Exception.Message)" "ERROR"
                        }
                    }
                }
                catch {
                    Write-Log "    Failed to check for device: $($_.Exception.Message)" "ERROR"
                }
            }
            else {
                Write-Log "    No MAC address detected - manual adoption required from controller UI" "INFO"
            }
        }
    }
}

# Summary
Write-Log "=== Summary ===" "INFO"
Write-Log "Total Devices: $($summary.Total)" "INFO"
Write-Log "Already Adopted: $($summary.Adopted)" "INFO"
Write-Log "Re-Adopted: $($summary.NeedsReAdoption)" "INFO"
Write-Log "Failed: $($summary.Failed)" "INFO"

# Exit with appropriate code
if ($summary.Failed -gt 0) {
    exit 1
} else {
    exit 0
}