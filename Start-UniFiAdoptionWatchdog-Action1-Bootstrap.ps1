# ==========================================
# UniFi Adoption Watchdog - Bootstrap Script
# Downloads and runs the full script from GitHub
# ==========================================

# Action1 Parameters
param(
    [string]$Controller = "https://your-controller-url.com",
    [string]$ControllerUser = "your-username",
    [string]$ControllerPass = "your-password",
    [string]$InformURL = "http://your-controller-url.com/inform"
)

# GitHub raw URL for the Action1 version
$scriptUrl = "https://raw.githubusercontent.com/in2digital/unifi-adoption-watchdog/main/Start-UniFiAdoptionWatchdog-Action1.ps1"

# Download the script
Write-Output "[Bootstrap] Downloading UniFi Adoption Watchdog from GitHub..."
try {
    $scriptContent = Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing -ErrorAction Stop | Select-Object -ExpandProperty Content
    Write-Output "[Bootstrap] Script downloaded successfully ($($scriptContent.Length) bytes)"
}
catch {
    Write-Output "[Bootstrap] Failed to download script: $($_.Exception.Message)"
    exit 1
}

# Inject credentials into the script
Write-Output "[Bootstrap] Injecting credentials..."
$scriptContent = $scriptContent -replace '\$Controller = "https://your-controller-url.com"', "`$Controller = `"$Controller`""
$scriptContent = $scriptContent -replace '\$ControllerUser = "your-username"', "`$ControllerUser = `"$ControllerUser`""
$scriptContent = $scriptContent -replace '\$ControllerPass = "your-password"', "`$ControllerPass = `"$ControllerPass`""
$scriptContent = $scriptContent -replace '\$InformURL = "http://your-controller-url.com/inform"', "`$InformURL = `"$InformURL`""

# Execute the script
Write-Output "[Bootstrap] Executing UniFi Adoption Watchdog..."
try {
    $scriptBlock = [ScriptBlock]::Create($scriptContent)
    & $scriptBlock
    exit $LASTEXITCODE
}
catch {
    Write-Output "[Bootstrap] Script execution failed: $($_.Exception.Message)"
    exit 1
}
