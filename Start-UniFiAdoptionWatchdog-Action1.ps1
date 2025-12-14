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

# Setup SSL/TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -TypeDefinition "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
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
        # Install NuGet provider first (non-interactive)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        
        # Install Posh-SSH (non-interactive)
        Install-Module -Name Posh-SSH -Force -Scope CurrentUser -AllowClobber -SkipPublisherCheck -Confirm:$false
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

foreach ($device in $devicesJson.data) {
    $summary.Total++
    $deviceName = $device.name
    $deviceMAC = $device.mac
    $deviceIP = $device.ip
    $deviceID = $device._id
    
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
                ErrorAction = 'Stop'
            }
            Invoke-WebRequest @deleteParams | Out-Null
            Write-Log "    Device deleted successfully" "SUCCESS"
        }
        catch {
            Write-Log "    Delete failed (continuing anyway)" "WARNING"
        }
        
        # Step 3: Wait for reboot
        Write-Log "    Step 3: Waiting 180 seconds for reboot..." "ACTION"
        Start-Sleep -Seconds 180
        
        # Step 4: Reconnect
        Write-Log "    Step 4: Reconnecting after reset..." "ACTION"
        $reconnected = $false
        for ($i = 1; $i -le 3; $i++) {
            try {
                $securePass = ConvertTo-SecureString "ubnt" -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential("ubnt", $securePass)
                $sshSession = New-SSHSession -ComputerName $deviceIP -Credential $credential -AcceptKey -ErrorAction Stop
                $reconnected = $true
                Write-Log "    Reconnected (attempt $i)" "SUCCESS"
                break
            }
            catch {
                if ($i -lt 3) { Start-Sleep -Seconds 10 }
            }
        }
        
        if (-not $reconnected) {
            Write-Log "    Reconnection failed" "ERROR"
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