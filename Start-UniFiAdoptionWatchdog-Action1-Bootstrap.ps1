# ==========================================
# UniFi Adoption Watchdog - Bootstrap Script
# Downloads and runs the full script from GitHub
# ==========================================

# Action1 Variables (set these in Action1 automation)
# These will be substituted by Action1 before execution
$Controller = $Controller
$ControllerUser = $ControllerUser
$ControllerPass = $ControllerPass
$InformURL = $InformURL

# GitHub raw URL for the Action1 version (with cache-busting timestamp)
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$scriptUrl = "https://raw.githubusercontent.com/in2digital/unifi-adoption-watchdog/main/Start-UniFiAdoptionWatchdog-Action1.ps1?t=$timestamp"

# Download the script
Write-Output "[Bootstrap] Downloading UniFi Adoption Watchdog from GitHub..."
try {
    $scriptContent = Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing -Headers @{"Cache-Control"="no-cache"} -ErrorAction Stop | Select-Object -ExpandProperty Content
    Write-Output "[Bootstrap] Script downloaded successfully ($($scriptContent.Length) bytes)"
}
catch {
    Write-Output "[Bootstrap] Failed to download script: $($_.Exception.Message)"
    exit 1
}

# Inject credentials into the script
Write-Output "[Bootstrap] Injecting credentials..."
Write-Output "[Bootstrap] Controller: $Controller"
Write-Output "[Bootstrap] User: $ControllerUser"
$scriptContent = $scriptContent -replace [regex]::Escape('$Controller = "https://your-controller-url.com"'), "`$Controller = `"$Controller`""
$scriptContent = $scriptContent -replace [regex]::Escape('$ControllerUser = "your-username"'), "`$ControllerUser = `"$ControllerUser`""
$scriptContent = $scriptContent -replace [regex]::Escape('$ControllerPass = "your-password"'), "`$ControllerPass = `"$ControllerPass`""
$scriptContent = $scriptContent -replace [regex]::Escape('$InformURL = "http://your-controller-url.com/inform"'), "`$InformURL = `"$InformURL`""
Write-Output "[Bootstrap] Credentials injected successfully"

# Save to temp file and execute
$tempDir = "C:\Unifi"
$tempScript = Join-Path $tempDir "UniFi-Adoption-Watchdog-Temp.ps1"

Write-Output "[Bootstrap] Saving script to $tempScript..."
try {
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    Set-Content -Path $tempScript -Value $scriptContent -Force
    Write-Output "[Bootstrap] Script saved successfully"
}
catch {
    Write-Output "[Bootstrap] Failed to save script: $($_.Exception.Message)"
    exit 1
}

# Execute the script from file
Write-Output "[Bootstrap] Executing UniFi Adoption Watchdog from file..."
try {
    & powershell.exe -ExecutionPolicy Bypass -File $tempScript
    $exitCode = $LASTEXITCODE
    
    # Clean up
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit $exitCode
}
catch {
    Write-Output "[Bootstrap] Script execution failed: $($_.Exception.Message)"
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit 1
}
