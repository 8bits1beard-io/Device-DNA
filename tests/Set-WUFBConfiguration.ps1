<#
.SYNOPSIS
    Configure device to use Windows Update for Business (WUFB)

.DESCRIPTION
    Detects current Windows Update management, shows detailed configuration with explanations,
    disables WSUS, enables WUFB deferral policies, verifies changes, and logs all actions
    to C:\Windows\Logs in CMTrace-compatible format.

    Detection logic matches Device DNA's WindowsUpdate.ps1:
    - Priority: SCCM > ESUS > WUFB > WSUS > Direct

.PARAMETER DeferFeatureDays
    Number of days to defer feature updates (0-365). Default: 0

.PARAMETER DeferQualityDays
    Number of days to defer quality updates (0-30). Default: 0

.PARAMETER BranchReadiness
    Branch readiness level: GA (32), ReleasePreview (8), Slow (4), Fast (2). Default: GA (32)

.EXAMPLE
    .\Set-WUFBConfiguration.ps1
    Configures WUFB with no deferrals, shows before/after verification

.EXAMPLE
    .\Set-WUFBConfiguration.ps1 -DeferFeatureDays 30 -DeferQualityDays 7
    Defers feature updates 30 days, quality updates 7 days

.NOTES
    Requires: Administrator privileges
    Author: Joshua Walderbach
    Version: 3.0 (Enhanced with detailed explanations and CMTrace logging)
    Log Location: C:\Windows\Logs\Set-WUFBConfiguration_<timestamp>.log
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(0, 365)]
    [int]$DeferFeatureDays = 0,

    [Parameter()]
    [ValidateRange(0, 30)]
    [int]$DeferQualityDays = 0,

    [Parameter()]
    [ValidateSet(2, 4, 8, 32)]
    [int]$BranchReadiness = 32  # 32 = GA Channel
)

#Requires -RunAsAdministrator

# ============================================================================
# LOGGING FUNCTIONS (CMTrace-compatible)
# ============================================================================

$script:LogFilePath = $null
$script:LoggingEnabled = $false

function Write-WUFBLog {
    <#
    .SYNOPSIS
        Writes a log entry in CMTrace/OneTrace compatible format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [string]$Component = "Set-WUFBConfiguration",

        [Parameter()]
        [ValidateSet(1, 2, 3)]
        [int]$Type = 1  # 1=Info, 2=Warning, 3=Error
    )

    if (-not $script:LoggingEnabled -or -not $script:LogFilePath) {
        return
    }

    try {
        # Build CMTrace format timestamp
        $now = Get-Date
        $time = $now.ToString("HH:mm:ss.fff") + "+000"
        $date = $now.ToString("MM-dd-yyyy")
        $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

        # CMTrace format
        $logEntry = "<![LOG[$Message]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$threadId`" file=`"`">"

        # Append to log file
        Add-Content -Path $script:LogFilePath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Silently fail - don't break script for logging issues
    }
}

function Initialize-WUFBLog {
    <#
    .SYNOPSIS
        Initializes the log file in C:\Windows\Logs
    #>
    [CmdletBinding()]
    param()

    try {
        $logDir = "C:\Windows\Logs"
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $logFileName = "Set-WUFBConfiguration_$timestamp.log"
        $script:LogFilePath = Join-Path $logDir $logFileName
        $script:LoggingEnabled = $true

        # Write header
        Write-WUFBLog -Message "========================================" -Type 1
        Write-WUFBLog -Message "Set-WUFBConfiguration Script Started" -Type 1
        Write-WUFBLog -Message "Version: 3.0" -Type 1
        Write-WUFBLog -Message "Computer: $env:COMPUTERNAME" -Type 1
        Write-WUFBLog -Message "User: $env:USERNAME" -Type 1
        Write-WUFBLog -Message "Parameters: DeferFeatureDays=$DeferFeatureDays, DeferQualityDays=$DeferQualityDays, BranchReadiness=$BranchReadiness" -Type 1
        Write-WUFBLog -Message "========================================" -Type 1

        return $script:LogFilePath
    }
    catch {
        Write-Host "  ⚠️  Warning: Could not initialize log file: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:LoggingEnabled = $false
        return $null
    }
}

function Complete-WUFBLog {
    <#
    .SYNOPSIS
        Writes completion message to log
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [bool]$Success = $true
    )

    if (-not $script:LoggingEnabled) { return }

    $status = if ($Success) { "COMPLETED SUCCESSFULLY" } else { "COMPLETED WITH ERRORS" }
    $type = if ($Success) { 1 } else { 2 }

    Write-WUFBLog -Message "========================================" -Type $type
    Write-WUFBLog -Message "Set-WUFBConfiguration Script $status" -Type $type
    Write-WUFBLog -Message "Log file: $script:LogFilePath" -Type $type
    Write-WUFBLog -Message "========================================" -Type $type
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Registry paths
$wuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auPolicyPath = "$wuPolicyPath\AU"

function Get-WUManagementSource {
    <#
    .SYNOPSIS
        Detects Windows Update management source using Device DNA logic
    #>
    param()

    Write-WUFBLog -Message "Detecting Windows Update management source" -Type 1

    $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
    $auPolicy = Get-ItemProperty -Path $auPolicyPath -ErrorAction SilentlyContinue

    $source = 'Windows Update (direct)'
    $management = 'None'

    # Check for WSUS/ESUS (UseWUServer = 1)
    if ($auPolicy.UseWUServer -eq 1) {
        $wsusUrl = if ($wuPolicy.WUServer) { $wuPolicy.WUServer } else { '(not set)' }

        # Detect ESUS (Endpoint Update Service - Intune cloud WSUS)
        if ($wsusUrl -match '\.mp\.microsoft\.com' -or $wsusUrl -match 'eus\.wu\.manage\.microsoft\.com') {
            $source = "ESUS (Endpoint Update Service)"
            $management = 'Intune (ESUS)'
            Write-WUFBLog -Message "Detected ESUS management: $wsusUrl" -Type 1
        } else {
            $source = "WSUS: $wsusUrl"
            $management = 'WSUS'
            Write-WUFBLog -Message "Detected WSUS management: $wsusUrl" -Type 1
        }
    }

    # Check for WUFB policies
    $wufbIndicators = @(
        'DeferFeatureUpdates',
        'DeferQualityUpdates',
        'BranchReadinessLevel',
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime'
    )
    $wufbConfigured = $false
    foreach ($indicator in $wufbIndicators) {
        if ($wuPolicy.PSObject.Properties.Name -contains $indicator) {
            $wufbConfigured = $true
            Write-WUFBLog -Message "Found WUFB indicator: $indicator" -Type 1
            break
        }
    }

    # If WUFB policies present but no WSUS, it's WUFB
    if ($wufbConfigured -and $management -eq 'None') {
        $source = "Windows Update for Business (WUFB)"
        $management = 'Intune (WUFB)'
        Write-WUFBLog -Message "Detected WUFB management" -Type 1
    }
    # If WUFB + WSUS, indicate co-management
    elseif ($wufbConfigured -and $management -ne 'None') {
        $management = "$management + WUFB"
        Write-WUFBLog -Message "Detected co-management: $management" -Type 1
    }

    # Check for SCCM (would override everything in Device DNA)
    $sccmInstalled = $false
    try {
        $sccmNamespace = Get-WmiObject -Namespace "root\ccm" -Class "__Namespace" -ErrorAction SilentlyContinue
        if ($sccmNamespace) {
            $sccmUpdates = Get-WmiObject -Namespace "root\ccm\ClientSDK" -Class "CCM_SoftwareUpdate" -ErrorAction SilentlyContinue
            if ($sccmUpdates) {
                $sccmInstalled = $true
                $source = "Configuration Manager (SCCM)"
                $management = "SCCM"
                Write-WUFBLog -Message "Detected SCCM management (takes precedence)" -Type 2
            }
        }
    } catch {
        # SCCM not installed
    }

    Write-WUFBLog -Message "Management source detection complete: $management ($source)" -Type 1

    return @{
        Source = $source
        Management = $management
        SCCMInstalled = $sccmInstalled
    }
}

function Show-RegistryConfig {
    <#
    .SYNOPSIS
        Shows detailed registry configuration with explanations
    #>
    param(
        [string]$Title,
        [switch]$ShowExplanations
    )

    Write-Host "`n$Title" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Gray

    $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
    $auPolicy = Get-ItemProperty -Path $auPolicyPath -ErrorAction SilentlyContinue

    # Show AU settings (WSUS configuration)
    Write-Host "`nAutomatic Updates (AU) - WSUS Configuration:" -ForegroundColor Yellow
    if ($auPolicy) {
        $useWU = if ($auPolicy.PSObject.Properties.Name -contains 'UseWUServer') { $auPolicy.UseWUServer } else { '(not set)' }
        $color = if ($useWU -eq 0) { 'Green' } elseif ($useWU -eq 1) { 'Yellow' } else { 'Gray' }
        Write-Host "  UseWUServer:          $useWU" -ForegroundColor $color

        if ($ShowExplanations) {
            Write-Host "    └─ Controls whether device uses WSUS server or Windows Update directly" -ForegroundColor Gray
            Write-Host "       0 = Use Windows Update (direct or WUFB) | 1 = Use WSUS server" -ForegroundColor Gray
            if ($useWU -eq 1) {
                Write-Host "       ⚠️  Currently set to WSUS - will be changed to 0 for WUFB" -ForegroundColor Yellow
            } elseif ($useWU -eq 0) {
                Write-Host "       ✓ Already configured correctly for WUFB" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  (No AU policies configured)" -ForegroundColor Gray
        if ($ShowExplanations) {
            Write-Host "    └─ Registry path will be created" -ForegroundColor Gray
        }
    }

    # Show WindowsUpdate settings
    Write-Host "`nWindowsUpdate Policy - Server & WUFB Settings:" -ForegroundColor Yellow
    if ($wuPolicy) {
        # WSUS Server URLs
        $server = if ($wuPolicy.PSObject.Properties.Name -contains 'WUServer') { $wuPolicy.WUServer } else { '(not set)' }
        $statusServer = if ($wuPolicy.PSObject.Properties.Name -contains 'WUStatusServer') { $wuPolicy.WUStatusServer } else { '(not set)' }

        $serverColor = if ($server -eq '(not set)') { 'Green' } else { 'Yellow' }
        Write-Host "  WUServer:                      $server" -ForegroundColor $serverColor
        Write-Host "  WUStatusServer:                $statusServer" -ForegroundColor $serverColor

        if ($ShowExplanations -and $server -ne '(not set)') {
            Write-Host "    └─ WSUS server URLs - will be removed for WUFB" -ForegroundColor Yellow
            Write-Host "       WUFB uses Windows Update directly, not a local WSUS server" -ForegroundColor Gray
        }

        # Feature Update Deferral
        $deferFeature = if ($wuPolicy.PSObject.Properties.Name -contains 'DeferFeatureUpdates') { $wuPolicy.DeferFeatureUpdates } else { '(not set)' }
        $deferFeatureDays = if ($wuPolicy.PSObject.Properties.Name -contains 'DeferFeatureUpdatesPeriodinDays') { $wuPolicy.DeferFeatureUpdatesPeriodinDays } else { '(not set)' }

        $featureColor = if ($deferFeature -eq 1) { 'Green' } else { 'Yellow' }
        Write-Host "  DeferFeatureUpdates:           $deferFeature" -ForegroundColor $featureColor
        Write-Host "  DeferFeatureUpdatesPeriodinDays: $deferFeatureDays" -ForegroundColor $featureColor

        if ($ShowExplanations) {
            Write-Host "    └─ Controls delay for Windows version upgrades (e.g., 22H2 → 23H2)" -ForegroundColor Gray
            Write-Host "       1 = Enable deferral | 0 = No deferral" -ForegroundColor Gray
            Write-Host "       Days value: 0-365 days to wait after Microsoft releases" -ForegroundColor Gray
            if ($deferFeature -ne 1) {
                Write-Host "       ⚠️  Will be set to 1 with $DeferFeatureDays day(s) deferral" -ForegroundColor Yellow
            }
        }

        # Quality Update Deferral
        $deferQuality = if ($wuPolicy.PSObject.Properties.Name -contains 'DeferQualityUpdates') { $wuPolicy.DeferQualityUpdates } else { '(not set)' }
        $deferQualityDays = if ($wuPolicy.PSObject.Properties.Name -contains 'DeferQualityUpdatesPeriodinDays') { $wuPolicy.DeferQualityUpdatesPeriodinDays } else { '(not set)' }

        $qualityColor = if ($deferQuality -eq 1) { 'Green' } else { 'Yellow' }
        Write-Host "  DeferQualityUpdates:           $deferQuality" -ForegroundColor $qualityColor
        Write-Host "  DeferQualityUpdatesPeriodinDays: $deferQualityDays" -ForegroundColor $qualityColor

        if ($ShowExplanations) {
            Write-Host "    └─ Controls delay for monthly security/bug fix updates" -ForegroundColor Gray
            Write-Host "       1 = Enable deferral | 0 = No deferral" -ForegroundColor Gray
            Write-Host "       Days value: 0-30 days to wait after Patch Tuesday" -ForegroundColor Gray
            if ($deferQuality -ne 1) {
                Write-Host "       ⚠️  Will be set to 1 with $DeferQualityDays day(s) deferral" -ForegroundColor Yellow
            }
        }

        # Branch Readiness Level
        $branch = if ($wuPolicy.PSObject.Properties.Name -contains 'BranchReadinessLevel') { $wuPolicy.BranchReadinessLevel } else { '(not set)' }
        $branchName = switch ($branch) {
            2  { "Fast (Insider)" }
            4  { "Slow (Insider)" }
            8  { "Release Preview" }
            32 { "General Availability (GA)" }
            default { "(not set)" }
        }

        $branchColor = if ($branch -ne '(not set)') { 'Green' } else { 'Yellow' }
        Write-Host "  BranchReadinessLevel:          $branch ($branchName)" -ForegroundColor $branchColor

        if ($ShowExplanations) {
            Write-Host "    └─ Determines which update channel device receives" -ForegroundColor Gray
            Write-Host "       32 = GA (General Availability - stable, production)" -ForegroundColor Gray
            Write-Host "       8  = Release Preview (pre-release testing)" -ForegroundColor Gray
            Write-Host "       4  = Slow Ring (Insider - beta)" -ForegroundColor Gray
            Write-Host "       2  = Fast Ring (Insider - earliest access)" -ForegroundColor Gray
            if ($branch -ne $BranchReadiness) {
                Write-Host "       ⚠️  Will be set to $BranchReadiness" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  (No WindowsUpdate policies configured)" -ForegroundColor Gray
        if ($ShowExplanations) {
            Write-Host "    └─ All WUFB policies will be created" -ForegroundColor Gray
        }
    }

    Write-Host ""
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host "`n╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Windows Update for Business (WUFB) Configuration Script            ║" -ForegroundColor Cyan
Write-Host "║  Version 3.0 - Enhanced with Explanations & CMTrace Logging          ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Initialize logging
$logPath = Initialize-WUFBLog
if ($logPath) {
    Write-Host "`n📋 Logging to: $logPath" -ForegroundColor Cyan
    Write-Host "   (CMTrace-compatible format - open with CMTrace or OneTrace)" -ForegroundColor Gray
} else {
    Write-Host "`n⚠️  Logging disabled (could not create log file)" -ForegroundColor Yellow
}

# ============================================================================
# STEP 1: DETECT CURRENT MANAGEMENT SOURCE
# ============================================================================
Write-Host "`n[STEP 1/6] Detecting Current Windows Update Management..." -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 1: Detecting current management source" -Type 1

$currentMgmt = Get-WUManagementSource

Write-Host "`n  Current Management Source:" -ForegroundColor White
Write-Host "    Source:     " -NoNewline -ForegroundColor Gray
if ($currentMgmt.Management -eq 'None') {
    Write-Host "$($currentMgmt.Source)" -ForegroundColor Yellow
} elseif ($currentMgmt.Management -match 'SCCM') {
    Write-Host "$($currentMgmt.Source)" -ForegroundColor Magenta
} elseif ($currentMgmt.Management -match 'Intune') {
    Write-Host "$($currentMgmt.Source)" -ForegroundColor Green
} else {
    Write-Host "$($currentMgmt.Source)" -ForegroundColor Cyan
}

Write-Host "    Management: " -NoNewline -ForegroundColor Gray
if ($currentMgmt.Management -eq 'None') {
    Write-Host "$($currentMgmt.Management)" -ForegroundColor Yellow
} elseif ($currentMgmt.Management -match 'SCCM') {
    Write-Host "$($currentMgmt.Management)" -ForegroundColor Magenta
} else {
    Write-Host "$($currentMgmt.Management)" -ForegroundColor Green
}

if ($currentMgmt.SCCMInstalled) {
    Write-Host "`n  ⚠️  WARNING: SCCM is managing updates!" -ForegroundColor Red
    Write-Host "     SCCM takes precedence over WUFB." -ForegroundColor Yellow
    Write-Host "     This script will configure WUFB policies, but SCCM will override them." -ForegroundColor Yellow
    Write-Host "     To use WUFB, you must disable SCCM software update management.`n" -ForegroundColor Yellow

    Write-WUFBLog -Message "WARNING: SCCM detected managing updates" -Type 2

    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne 'y' -and $continue -ne 'Y') {
        Write-Host "`nExiting without making changes." -ForegroundColor Red
        Write-WUFBLog -Message "User chose to exit due to SCCM management" -Type 2
        Complete-WUFBLog -Success $false
        exit 0
    }
    Write-WUFBLog -Message "User chose to continue despite SCCM management" -Type 2
}

# ============================================================================
# STEP 2: SHOW CURRENT REGISTRY CONFIGURATION
# ============================================================================
Write-Host "`n[STEP 2/6] Current Registry Configuration" -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 2: Showing current registry configuration" -Type 1
Show-RegistryConfig -Title "BEFORE Changes" -ShowExplanations

# ============================================================================
# STEP 3: CREATE REGISTRY PATHS IF NEEDED
# ============================================================================
Write-Host "`n[STEP 3/6] Ensuring Registry Paths Exist..." -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 3: Ensuring registry paths exist" -Type 1

Write-Host "`n  What this does:" -ForegroundColor Cyan
Write-Host "    Windows Update policies are stored in the registry under:" -ForegroundColor Gray
Write-Host "    HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ForegroundColor Gray
Write-Host "    These paths must exist before we can write WUFB settings.`n" -ForegroundColor Gray

if (-not (Test-Path $wuPolicyPath)) {
    New-Item -Path $wuPolicyPath -Force | Out-Null
    Write-Host "  ✓ Created $wuPolicyPath" -ForegroundColor Green
    Write-WUFBLog -Message "Created registry path: $wuPolicyPath" -Type 1
} else {
    Write-Host "  ✓ Path exists: $wuPolicyPath" -ForegroundColor Green
    Write-WUFBLog -Message "Registry path already exists: $wuPolicyPath" -Type 1
}

if (-not (Test-Path $auPolicyPath)) {
    New-Item -Path $auPolicyPath -Force | Out-Null
    Write-Host "  ✓ Created $auPolicyPath" -ForegroundColor Green
    Write-WUFBLog -Message "Created registry path: $auPolicyPath" -Type 1
} else {
    Write-Host "  ✓ Path exists: $auPolicyPath" -ForegroundColor Green
    Write-WUFBLog -Message "Registry path already exists: $auPolicyPath" -Type 1
}

# ============================================================================
# STEP 4: DISABLE WSUS (Point to Windows Update cloud)
# ============================================================================
Write-Host "`n[STEP 4/6] Disabling WSUS Configuration..." -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 4: Disabling WSUS configuration" -Type 1

Write-Host "`n  What this does:" -ForegroundColor Cyan
Write-Host "    WSUS (Windows Server Update Services) is an on-premises update server." -ForegroundColor Gray
Write-Host "    WUFB uses Windows Update (Microsoft's cloud), NOT a local WSUS server." -ForegroundColor White
Write-Host "" -ForegroundColor Gray
Write-Host "    This step removes WSUS configuration so the device connects to:" -ForegroundColor White
Write-Host "      update.microsoft.com (Windows Update cloud)" -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
Write-Host "    Then Step 5 will add WUFB policies to control update timing.`n" -ForegroundColor Yellow

try {
    # Set UseWUServer to 0 (disable WSUS)
    $currentUseWU = (Get-ItemProperty -Path $auPolicyPath -ErrorAction SilentlyContinue).UseWUServer
    Set-ItemProperty -Path $auPolicyPath -Name 'UseWUServer' -Value 0 -Type DWord -ErrorAction Stop

    if ($currentUseWU -eq 0) {
        Write-Host "  ✓ UseWUServer already set to 0 (correct)" -ForegroundColor Green
        Write-WUFBLog -Message "UseWUServer already set to 0" -Type 1
    } else {
        Write-Host "  ✓ Set UseWUServer = 0 (changed from $currentUseWU)" -ForegroundColor Green
        Write-Host "    └─ This tells Windows to NOT use a WSUS server" -ForegroundColor Gray
        Write-WUFBLog -Message "Changed UseWUServer from $currentUseWU to 0" -Type 1
    }

    # Remove WSUS server URLs
    $hadWUServer = (Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue).WUServer
    $hadStatusServer = (Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue).WUStatusServer

    Remove-ItemProperty -Path $wuPolicyPath -Name 'WUServer' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $wuPolicyPath -Name 'WUStatusServer' -ErrorAction SilentlyContinue

    if ($hadWUServer -or $hadStatusServer) {
        Write-Host "  ✓ Removed WSUS server URLs" -ForegroundColor Green
        Write-Host "    └─ Deleted: WUServer ($hadWUServer) and WUStatusServer ($hadStatusServer)" -ForegroundColor Gray
        Write-WUFBLog -Message "Removed WSUS server URLs: WUServer=$hadWUServer, WUStatusServer=$hadStatusServer" -Type 1
    } else {
        Write-Host "  ✓ No WSUS server URLs to remove (correct)" -ForegroundColor Green
        Write-WUFBLog -Message "No WSUS server URLs found" -Type 1
    }

    # Remove internet blocking policies
    $hadBlockPolicy = (Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue).DoNotConnectToWindowsUpdateInternetLocations
    Remove-ItemProperty -Path $wuPolicyPath -Name 'DoNotConnectToWindowsUpdateInternetLocations' -ErrorAction SilentlyContinue

    if ($hadBlockPolicy) {
        Write-Host "  ✓ Removed internet blocking policy" -ForegroundColor Green
        Write-Host "    └─ This policy prevented direct internet access to Windows Update" -ForegroundColor Gray
        Write-WUFBLog -Message "Removed DoNotConnectToWindowsUpdateInternetLocations policy" -Type 1
    } else {
        Write-Host "  ✓ No internet blocking policy to remove (correct)" -ForegroundColor Green
        Write-WUFBLog -Message "No internet blocking policy found" -Type 1
    }
} catch {
    Write-Host "  ⚠️  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-WUFBLog -Message "Warning during WSUS disable: $($_.Exception.Message)" -Type 2
}

# ============================================================================
# STEP 5: ENABLE WUFB
# ============================================================================
Write-Host "`n[STEP 5/6] Configuring Windows Update for Business (WUFB)..." -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 5: Configuring WUFB" -Type 1

Write-Host "`n  What this does:" -ForegroundColor Cyan
Write-Host "    WUFB is NOT a separate server - it's Windows Update (Microsoft cloud)" -ForegroundColor White
Write-Host "    WITH management policies applied." -ForegroundColor White
Write-Host "" -ForegroundColor Gray
Write-Host "    The deferral policies we're setting below ARE what makes it WUFB:" -ForegroundColor Yellow
Write-Host "      • Plain Windows Update = No policies, get updates immediately" -ForegroundColor Gray
Write-Host "      • WUFB = Windows Update + Deferral/Branch policies (control)" -ForegroundColor Gray
Write-Host "      • WSUS = Local on-premises server (we disabled this in Step 4)" -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
Write-Host "    By setting these 3 policies, the device becomes WUFB-managed:" -ForegroundColor White
Write-Host "      1. DeferFeatureUpdates - Controls version upgrade timing" -ForegroundColor Gray
Write-Host "      2. DeferQualityUpdates - Controls security patch timing" -ForegroundColor Gray
Write-Host "      3. BranchReadinessLevel - Controls update channel (GA/Preview/Insider)`n" -ForegroundColor Gray

try {
    # Feature update deferral
    Set-ItemProperty -Path $wuPolicyPath -Name 'DeferFeatureUpdates' -Value 1 -Type DWord
    Set-ItemProperty -Path $wuPolicyPath -Name 'DeferFeatureUpdatesPeriodinDays' -Value $DeferFeatureDays -Type DWord
    Write-Host "  ✓ Feature updates: Defer $DeferFeatureDays days" -ForegroundColor Green
    Write-Host "    └─ Feature updates = Windows version upgrades (e.g., 22H2 → 23H2)" -ForegroundColor Gray
    Write-Host "       Deferral allows testing before deployment to all devices" -ForegroundColor Gray
    Write-WUFBLog -Message "Set DeferFeatureUpdates=1 with $DeferFeatureDays day(s) deferral" -Type 1

    # Quality update deferral
    Set-ItemProperty -Path $wuPolicyPath -Name 'DeferQualityUpdates' -Value 1 -Type DWord
    Set-ItemProperty -Path $wuPolicyPath -Name 'DeferQualityUpdatesPeriodinDays' -Value $DeferQualityDays -Type DWord
    Write-Host "  ✓ Quality updates: Defer $DeferQualityDays days" -ForegroundColor Green
    Write-Host "    └─ Quality updates = Monthly security patches (Patch Tuesday)" -ForegroundColor Gray
    Write-Host "       Deferral allows time to verify stability before mass deployment" -ForegroundColor Gray
    Write-WUFBLog -Message "Set DeferQualityUpdates=1 with $DeferQualityDays day(s) deferral" -Type 1

    # Branch readiness level
    Set-ItemProperty -Path $wuPolicyPath -Name 'BranchReadinessLevel' -Value $BranchReadiness -Type DWord
    $branchName = switch ($BranchReadiness) {
        2  { "Fast (Insider)" }
        4  { "Slow (Insider)" }
        8  { "Release Preview" }
        32 { "General Availability (GA)" }
    }
    Write-Host "  ✓ Branch readiness: $branchName" -ForegroundColor Green
    Write-Host "    └─ GA = Stable production updates (recommended for most devices)" -ForegroundColor Gray
    Write-Host "       Release Preview = Pre-release testing before GA" -ForegroundColor Gray
    Write-Host "       Insider = Early access to upcoming features (for testing only)" -ForegroundColor Gray
    Write-WUFBLog -Message "Set BranchReadinessLevel=$BranchReadiness ($branchName)" -Type 1

    # Restart Windows Update service
    Write-Host "`n  ✓ Restarting Windows Update service..." -ForegroundColor Yellow
    Write-Host "    └─ Ensures new settings are picked up immediately" -ForegroundColor Gray
    Restart-Service wuauserv -Force -ErrorAction Stop
    Write-Host "  ✓ Windows Update service restarted" -ForegroundColor Green
    Write-WUFBLog -Message "Restarted Windows Update service (wuauserv)" -Type 1

    # Explain what was just configured
    Write-Host "`n  ╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host   "  ║  WUFB CONFIGURATION COMPLETE                                   ║" -ForegroundColor Green
    Write-Host   "  ╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host   "`n  The 3 policies above ARE the WUFB configuration." -ForegroundColor White
    Write-Host   "  Device will now:" -ForegroundColor White
    Write-Host   "    • Connect to Windows Update (update.microsoft.com)" -ForegroundColor Gray
    Write-Host   "    • Apply deferral policies to control update timing" -ForegroundColor Gray
    Write-Host   "    • Be detected as 'WUFB managed' by Device DNA and Intune" -ForegroundColor Gray
    Write-Host   "`n  There is NO separate 'WUFB server' - these policies ARE WUFB." -ForegroundColor Yellow

} catch {
    Write-Host "  ❌ Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-WUFBLog -Message "ERROR during WUFB configuration: $($_.Exception.Message)" -Type 3
    Complete-WUFBLog -Success $false
    exit 1
}

# ============================================================================
# STEP 6: VERIFY CHANGES
# ============================================================================
Write-Host "`n[STEP 6/6] Verifying Changes..." -ForegroundColor Yellow
Write-WUFBLog -Message "STEP 6: Verifying changes" -Type 1

# Wait a moment for registry to settle
Start-Sleep -Milliseconds 500

# Show new registry configuration
Show-RegistryConfig -Title "AFTER Changes" -ShowExplanations:$false

# Detect new management source
$newMgmt = Get-WUManagementSource

Write-Host "`n╔═══════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  VERIFICATION COMPLETE                                                ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green

# Show before/after comparison
Write-Host "`nBEFORE:" -ForegroundColor Yellow
Write-Host "  Source:     $($currentMgmt.Source)" -ForegroundColor Gray
Write-Host "  Management: $($currentMgmt.Management)" -ForegroundColor Gray

Write-Host "`nAFTER:" -ForegroundColor Green
Write-Host "  Source:     $($newMgmt.Source)" -ForegroundColor White
Write-Host "  Management: $($newMgmt.Management)" -ForegroundColor White

Write-WUFBLog -Message "Verification: BEFORE - $($currentMgmt.Management) | AFTER - $($newMgmt.Management)" -Type 1

# Verify expected state
$verified = $false
if ($newMgmt.SCCMInstalled) {
    Write-Host "`n⚠️  SCCM is still managing updates (as expected - SCCM takes precedence)" -ForegroundColor Yellow
    Write-Host "   WUFB policies are configured but inactive due to SCCM." -ForegroundColor Yellow
    Write-WUFBLog -Message "SCCM still managing updates (expected)" -Type 2
    $verified = $true
} elseif ($newMgmt.Management -match 'WUFB') {
    Write-Host "`n✅ SUCCESS! Device is now managed by Windows Update for Business" -ForegroundColor Green
    Write-WUFBLog -Message "SUCCESS: Device now managed by WUFB" -Type 1
    $verified = $true
} else {
    Write-Host "`n⚠️  WARNING: Expected WUFB management, but detected: $($newMgmt.Management)" -ForegroundColor Yellow
    Write-Host "   Registry keys are set correctly, but detection shows: $($newMgmt.Source)" -ForegroundColor Yellow
    Write-WUFBLog -Message "WARNING: Expected WUFB but detected $($newMgmt.Management)" -Type 2
}

# Next steps
Write-Host "`n" -NoNewline
Write-Host ("=" * 80) -ForegroundColor Gray
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Gray

Write-Host "`n1. Run Device DNA to verify WUFB detection:" -ForegroundColor White
Write-Host "   .\DeviceDNA.ps1" -ForegroundColor Gray

Write-Host "`n2. Check Windows Update settings:" -ForegroundColor White
Write-Host "   start ms-settings:windowsupdate" -ForegroundColor Gray

Write-Host "`n3. Force a Windows Update scan:" -ForegroundColor White
Write-Host "   UsoClient ScanInstallWait" -ForegroundColor Gray

Write-Host "`n4. View update history:" -ForegroundColor White
Write-Host "   start ms-settings:windowsupdate-history" -ForegroundColor Gray

Write-Host "`n5. View log file in CMTrace/OneTrace:" -ForegroundColor White
Write-Host "   $logPath" -ForegroundColor Gray

Write-Host ""

# Complete logging
Complete-WUFBLog -Success $verified

# Show appreciation call-to-action
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Found this script helpful?" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "If this tool saved you time or made your work easier," -ForegroundColor White
Write-Host "consider giving a " -NoNewline -ForegroundColor White
Write-Host "Badge " -NoNewline -ForegroundColor Green
Write-Host "to recognize the effort!" -ForegroundColor White
Write-Host ""
Write-Host "Author: " -NoNewline -ForegroundColor Gray
Write-Host "Joshua Walderbach (j0w03ow)" -ForegroundColor White
Write-Host "Badgify: " -NoNewline -ForegroundColor Gray
Write-Host "https://internal.walmart.com/content/badgify/home/badgify.html" -ForegroundColor Cyan
Write-Host ""
Write-Host "Thank you for using Set-WUFBConfiguration! " -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
