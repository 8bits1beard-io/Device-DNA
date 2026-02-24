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
    [int]$BranchReadiness = 32,  # 32 = GA Channel

    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [switch]$ViewOnly,

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$HistoryTop = 5
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
        Write-WUFBLog -Message "Parameters: DeferFeatureDays=$DeferFeatureDays, DeferQualityDays=$DeferQualityDays, BranchReadiness=$BranchReadiness, Interactive=$Interactive, ViewOnly=$ViewOnly, HistoryTop=$HistoryTop" -Type 1
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
        $ccmService = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        $sccmNamespace = Get-WmiObject -Namespace "root\ccm" -Class "__Namespace" -ErrorAction SilentlyContinue
        if ($ccmService -or $sccmNamespace) {
            $sccmInstalled = $true
            $source = "Configuration Manager (SCCM)"
            $management = "SCCM"
            Write-WUFBLog -Message "Detected SCCM management (takes precedence)" -Type 2
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

function New-WUEvidence {
    [CmdletBinding()]
    param(
        [string]$Category,
        [string]$Signal,
        [object]$Value,
        [string]$Path,
        [int]$Weight = 50,
        [string]$Notes
    )

    [pscustomobject]@{
        Category = $Category
        Signal   = $Signal
        Value    = $Value
        Path     = $Path
        Weight   = $Weight
        Notes    = $Notes
    }
}

function Get-WUManagementEvidence {
    [CmdletBinding()]
    param()

    $evidence = New-Object System.Collections.Generic.List[object]

    $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
    $auPolicy = Get-ItemProperty -Path $auPolicyPath -ErrorAction SilentlyContinue

    if ($auPolicy -and ($auPolicy.PSObject.Properties.Name -contains 'UseWUServer')) {
        $evidence.Add((New-WUEvidence -Category 'WSUS' -Signal 'UseWUServer' -Value $auPolicy.UseWUServer -Path $auPolicyPath -Weight 80 -Notes 'AU policy controls WSUS usage'))
    }

    if ($wuPolicy) {
        foreach ($name in 'WUServer', 'WUStatusServer', 'DeferFeatureUpdates', 'DeferQualityUpdates', 'BranchReadinessLevel') {
            if ($wuPolicy.PSObject.Properties.Name -contains $name) {
                $evidence.Add((New-WUEvidence -Category 'PolicyRegistry' -Signal $name -Value $wuPolicy.$name -Path $wuPolicyPath -Weight 60 -Notes 'Windows Update policy registry value present'))
            }
        }
    }

    if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'WUServer') -and $wuPolicy.WUServer) {
        if ($wuPolicy.WUServer -match '\.mp\.microsoft\.com' -or $wuPolicy.WUServer -match 'eus\.wu\.manage\.microsoft\.com') {
            $evidence.Add((New-WUEvidence -Category 'Intune-ESUS' -Signal 'WUServerPattern' -Value $wuPolicy.WUServer -Path $wuPolicyPath -Weight 95 -Notes 'Cloud update endpoint indicates Intune/ESUS style management'))
        }
    }

    $policyManagerUpdatePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $pmUpdate = Get-ItemProperty -Path $policyManagerUpdatePath -ErrorAction SilentlyContinue
    if ($pmUpdate) {
        $evidence.Add((New-WUEvidence -Category 'MDM' -Signal 'PolicyManagerUpdate' -Value 'Present' -Path $policyManagerUpdatePath -Weight 85 -Notes 'Policy CSP Update node present'))
    }

    try {
        $ccmSvc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        if ($ccmSvc) {
            $evidence.Add((New-WUEvidence -Category 'SCCM' -Signal 'CcmExecService' -Value $ccmSvc.Status -Path 'Service:CcmExec' -Weight 95 -Notes 'ConfigMgr client service detected'))
        }
    } catch {}

    try {
        $ccmNs = Get-CimInstance -Namespace 'root\ccm' -ClassName '__NAMESPACE' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ccmNs) {
            $evidence.Add((New-WUEvidence -Category 'SCCM' -Signal 'CimNamespaceRootCcm' -Value 'Present' -Path 'root\ccm' -Weight 90 -Notes 'ConfigMgr WMI namespace detected'))
        }
    } catch {
        try {
            $ccmNsLegacy = Get-WmiObject -Namespace 'root\ccm' -Class '__Namespace' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ccmNsLegacy) {
                $evidence.Add((New-WUEvidence -Category 'SCCM' -Signal 'WmiNamespaceRootCcm' -Value 'Present' -Path 'root\ccm' -Weight 90 -Notes 'ConfigMgr WMI namespace detected (legacy)'))
            }
        } catch {}
    }

    $wufbIndicators = @(
        'DeferFeatureUpdates',
        'DeferQualityUpdates',
        'BranchReadinessLevel',
        'PauseFeatureUpdatesStartTime',
        'PauseQualityUpdatesStartTime'
    )
    if ($wuPolicy) {
        foreach ($indicator in $wufbIndicators) {
            if ($wuPolicy.PSObject.Properties.Name -contains $indicator) {
                $evidence.Add((New-WUEvidence -Category 'WUFB' -Signal $indicator -Value $wuPolicy.$indicator -Path $wuPolicyPath -Weight 70 -Notes 'WUFB-related policy value present'))
            }
        }
    }

    return @($evidence)
}

function Resolve-WUManagementSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Evidence
    )

    $categories = @($Evidence | ForEach-Object { $_.Category } | Sort-Object -Unique)
    $signals = @($Evidence | ForEach-Object { $_.Signal })

    $hasSCCM = $categories -contains 'SCCM'
    $hasMDM = $categories -contains 'MDM'
    $hasESUS = $categories -contains 'Intune-ESUS'
    $hasWUFB = $categories -contains 'WUFB'

    $useWUServerEvidence = $Evidence | Where-Object { $_.Signal -eq 'UseWUServer' } | Select-Object -First 1
    $useWUServer = if ($useWUServerEvidence) { [int]$useWUServerEvidence.Value } else { $null }
    $hasWSUS = ($useWUServer -eq 1) -or ($signals | Where-Object { $_ -in @('WUServer', 'WUStatusServer', 'WUServerPattern') }).Count -gt 0

    $sourcesDetected = New-Object System.Collections.Generic.List[string]
    if ($hasSCCM) { $sourcesDetected.Add('SCCM') }
    if ($hasESUS) { $sourcesDetected.Add('Intune-ESUS') }
    elseif ($hasMDM -and $hasWUFB) { $sourcesDetected.Add('Intune-WUFB') }
    elseif ($hasMDM) { $sourcesDetected.Add('MDM') }
    if ($hasWSUS) { $sourcesDetected.Add('WSUS') }
    if ($hasWUFB) { $sourcesDetected.Add('WUFB') }

    $effective = 'Direct'
    $confidence = 'Medium'
    $overrideRisk = 'Low'
    $editableLocally = $true

    if ($hasSCCM) {
        $effective = 'SCCM'
        $confidence = 'High'
        $overrideRisk = 'High'
        $editableLocally = $false
    } elseif ($hasESUS) {
        $effective = 'Intune-ESUS'
        $confidence = 'High'
        $overrideRisk = 'High'
        $editableLocally = $false
    } elseif ($hasMDM -and $hasWUFB) {
        $effective = 'Intune-WUFB'
        $confidence = 'High'
        $overrideRisk = 'High'
        $editableLocally = $false
    } elseif ($hasWSUS -and $hasWUFB) {
        $effective = 'CoManaged (WSUS + WUFB)'
        $confidence = 'Medium'
        $overrideRisk = 'Medium'
    } elseif ($hasWSUS) {
        $effective = 'WSUS'
        $confidence = 'High'
        $overrideRisk = if ($hasMDM) { 'High' } else { 'Medium' }
    } elseif ($hasWUFB) {
        $effective = 'WUFB (Local/Policy)'
        $confidence = 'Medium'
        $overrideRisk = if ($hasMDM) { 'High' } else { 'Low' }
        $editableLocally = -not $hasMDM
    } elseif ($Evidence.Count -eq 0) {
        $effective = 'Direct'
        $confidence = 'Medium'
        $overrideRisk = 'Low'
    }

    [pscustomobject]@{
        EffectiveSource = $effective
        SourcesDetected = @($sourcesDetected)
        Confidence = $confidence
        IsCoManaged = (@($sourcesDetected).Count -gt 1)
        EditableLocally = $editableLocally
        OverrideRisk = $overrideRisk
        Evidence = @($Evidence)
    }
}

function Get-WUPolicyConfig {
    [CmdletBinding()]
    param()

    $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
    $auPolicy = Get-ItemProperty -Path $auPolicyPath -ErrorAction SilentlyContinue

    [pscustomobject]@{
        UseWUServer = if ($auPolicy -and ($auPolicy.PSObject.Properties.Name -contains 'UseWUServer')) { $auPolicy.UseWUServer } else { $null }
        WUServer = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'WUServer')) { $wuPolicy.WUServer } else { $null }
        WUStatusServer = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'WUStatusServer')) { $wuPolicy.WUStatusServer } else { $null }
        DoNotConnectToWindowsUpdateInternetLocations = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'DoNotConnectToWindowsUpdateInternetLocations')) { $wuPolicy.DoNotConnectToWindowsUpdateInternetLocations } else { $null }
        DeferFeatureUpdates = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'DeferFeatureUpdates')) { $wuPolicy.DeferFeatureUpdates } else { $null }
        DeferFeatureUpdatesPeriodInDays = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'DeferFeatureUpdatesPeriodinDays')) { $wuPolicy.DeferFeatureUpdatesPeriodinDays } else { $null }
        DeferQualityUpdates = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'DeferQualityUpdates')) { $wuPolicy.DeferQualityUpdates } else { $null }
        DeferQualityUpdatesPeriodInDays = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'DeferQualityUpdatesPeriodinDays')) { $wuPolicy.DeferQualityUpdatesPeriodinDays } else { $null }
        BranchReadinessLevel = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'BranchReadinessLevel')) { $wuPolicy.BranchReadinessLevel } else { $null }
        PauseFeatureUpdatesStartTime = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'PauseFeatureUpdatesStartTime')) { $wuPolicy.PauseFeatureUpdatesStartTime } else { $null }
        PauseQualityUpdatesStartTime = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'PauseQualityUpdatesStartTime')) { $wuPolicy.PauseQualityUpdatesStartTime } else { $null }
        AllowAutoWindowsUpdateDownloadOverMeteredNetwork = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork')) { $wuPolicy.AllowAutoWindowsUpdateDownloadOverMeteredNetwork } else { $null }
    }
}

function Get-WUActiveHours {
    [CmdletBinding()]
    param()

    $uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $ux = Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue

    $start = $null
    foreach ($n in @('ActiveHoursStart', 'SmartActiveHoursStart', 'SetActiveHoursStart')) {
        if ($ux -and ($ux.PSObject.Properties.Name -contains $n)) { $start = $ux.$n; break }
    }

    $end = $null
    foreach ($n in @('ActiveHoursEnd', 'SmartActiveHoursEnd', 'SetActiveHoursEnd')) {
        if ($ux -and ($ux.PSObject.Properties.Name -contains $n)) { $end = $ux.$n; break }
    }

    $smart = $null
    foreach ($n in @('SmartActiveHoursState', 'SmartActiveHoursEnabled')) {
        if ($ux -and ($ux.PSObject.Properties.Name -contains $n)) { $smart = $ux.$n; break }
    }

    [pscustomobject]@{
        StartHour = $start
        EndHour = $end
        SmartActiveHoursEnabled = $smart
        Source = 'Local'
        Editable = $true
        RegistryPath = $uxPath
    }
}

function Get-WUMeteredState {
    [CmdletBinding()]
    param()

    $wuPolicy = Get-ItemProperty -Path $wuPolicyPath -ErrorAction SilentlyContinue
    [pscustomobject]@{
        AllowAutoWindowsUpdateDownloadOverMeteredNetwork = if ($wuPolicy -and ($wuPolicy.PSObject.Properties.Name -contains 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork')) { $wuPolicy.AllowAutoWindowsUpdateDownloadOverMeteredNetwork } else { $null }
        Source = 'Policy'
        Editable = $true
        RegistryPath = $wuPolicyPath
    }
}

function Get-WUUpdateHistory {
    [CmdletBinding()]
    param(
        [int]$Top = 5
    )

    $recent = @()
    $lastInstalled = $null

    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()

        if ($count -gt 0) {
            $entries = $searcher.QueryHistory(0, [Math]::Min($count, [Math]::Max($Top, 20)))
            $recent = @(
                $entries |
                    Where-Object { $_.Operation -eq 1 } |
                    Select-Object -First $Top -Property @{
                        Name = 'Date'; Expression = { $_.Date }
                    }, @{
                        Name = 'Title'; Expression = { $_.Title }
                    }, @{
                        Name = 'ResultCode'; Expression = { $_.ResultCode }
                    }
            )
            $lastInstalled = $recent | Select-Object -First 1
        }
    } catch {
        try {
            $recent = @(
                Get-HotFix -ErrorAction SilentlyContinue |
                    Sort-Object InstalledOn -Descending |
                    Select-Object -First $Top -Property @{
                        Name = 'Date'; Expression = { $_.InstalledOn }
                    }, @{
                        Name = 'Title'; Expression = { $_.HotFixID }
                    }, @{
                        Name = 'ResultCode'; Expression = { $null }
                    }
            )
            $lastInstalled = $recent | Select-Object -First 1
        } catch {}
    }

    [pscustomobject]@{
        LastInstalled = $lastInstalled
        Recent = @($recent)
        LastScanTime = $null
    }
}

function Get-WUServiceState {
    [CmdletBinding()]
    param()

    $serviceItems = foreach ($svcName in @('wuauserv', 'UsoSvc', 'BITS')) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            $startMode = $null
            try {
                $svcCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
                if ($svcCim) { $startMode = $svcCim.StartMode }
            } catch {}

            [pscustomobject]@{
                Name = $svc.Name
                Status = [string]$svc.Status
                StartType = $startMode
            }
        }
    }

    [pscustomobject]@{
        RebootRequired = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Services = @($serviceItems)
    }
}

function Get-WUDashboardData {
    [CmdletBinding()]
    param(
        [int]$HistoryTop = 5
    )

    $evidence = Get-WUManagementEvidence
    [pscustomobject]@{
        Timestamp = Get-Date
        ComputerName = $env:COMPUTERNAME
        Management = Resolve-WUManagementSource -Evidence $evidence
        UpdateConfig = Get-WUPolicyConfig
        ActiveHours = Get-WUActiveHours
        Metered = Get-WUMeteredState
        UpdateHistory = Get-WUUpdateHistory -Top $HistoryTop
        SystemState = Get-WUServiceState
    }
}

function Show-WUDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dashboard
    )

    $m = $Dashboard.Management
    $c = $Dashboard.UpdateConfig
    $a = $Dashboard.ActiveHours
    $metered = $Dashboard.Metered
    $h = $Dashboard.UpdateHistory
    $s = $Dashboard.SystemState

    Write-Host "`n[DISCOVERY] Windows Update Management & Status" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Gray

    Write-Host "`nManagement Source" -ForegroundColor Yellow
    Write-Host "  Effective:      $($m.EffectiveSource)" -ForegroundColor White
    Write-Host "  Confidence:     $($m.Confidence)" -ForegroundColor Gray
    Write-Host "  Co-managed:     $($m.IsCoManaged)" -ForegroundColor Gray
    Write-Host "  Editable local: $($m.EditableLocally)" -ForegroundColor Gray
    Write-Host "  Override risk:  $($m.OverrideRisk)" -ForegroundColor Gray
    if ($m.SourcesDetected.Count -gt 0) {
        Write-Host "  Detected:       $($m.SourcesDetected -join ', ')" -ForegroundColor Gray
    }

    Write-Host "`nWindows Update Policy State" -ForegroundColor Yellow
    Write-Host "  UseWUServer:    $($c.UseWUServer)" -ForegroundColor Gray
    Write-Host "  WUServer:       $($c.WUServer)" -ForegroundColor Gray
    Write-Host "  WUStatusServer: $($c.WUStatusServer)" -ForegroundColor Gray
    Write-Host "  Block Internet: $($c.DoNotConnectToWindowsUpdateInternetLocations)" -ForegroundColor Gray
    Write-Host "  Feature Deferral: $($c.DeferFeatureUpdates) / Days=$($c.DeferFeatureUpdatesPeriodInDays)" -ForegroundColor Gray
    Write-Host "  Quality Deferral: $($c.DeferQualityUpdates) / Days=$($c.DeferQualityUpdatesPeriodInDays)" -ForegroundColor Gray
    Write-Host "  BranchReadiness:  $($c.BranchReadinessLevel)" -ForegroundColor Gray

    Write-Host "`nActive Hours" -ForegroundColor Yellow
    Write-Host "  Start:          $($a.StartHour)" -ForegroundColor Gray
    Write-Host "  End:            $($a.EndHour)" -ForegroundColor Gray
    Write-Host "  Smart Active:   $($a.SmartActiveHoursEnabled)" -ForegroundColor Gray
    Write-Host "  Editable:       $($a.Editable)" -ForegroundColor Gray

    Write-Host "`nMetered Downloads" -ForegroundColor Yellow
    Write-Host "  Allow auto download over metered: $($metered.AllowAutoWindowsUpdateDownloadOverMeteredNetwork)" -ForegroundColor Gray
    Write-Host "  Editable:       $($metered.Editable)" -ForegroundColor Gray

    Write-Host "`nSystem State" -ForegroundColor Yellow
    Write-Host "  Reboot Required: $($s.RebootRequired)" -ForegroundColor Gray
    foreach ($svc in $s.Services) {
        Write-Host "  Service $($svc.Name): $($svc.Status) (StartType=$($svc.StartType))" -ForegroundColor Gray
    }

    Write-Host "`nRecent Installed Updates" -ForegroundColor Yellow
    if ($h.Recent.Count -gt 0) {
        $i = 1
        foreach ($item in $h.Recent) {
            $dateText = if ($item.Date) { try { (Get-Date $item.Date -Format 'yyyy-MM-dd HH:mm') } catch { "$($item.Date)" } } else { '(unknown)' }
            Write-Host ("  [{0}] {1}  {2}" -f $i, $dateText, $item.Title) -ForegroundColor Gray
            $i++
        }
    } else {
        Write-Host "  (No history available)" -ForegroundColor Gray
    }

    Write-Host "`nEvidence (Top signals)" -ForegroundColor Yellow
    if ($m.Evidence.Count -gt 0) {
        $m.Evidence |
            Sort-Object Weight -Descending |
            Select-Object -First 8 |
            ForEach-Object {
                Write-Host "  [$($_.Category)] $($_.Signal) = $($_.Value) (Weight=$($_.Weight))" -ForegroundColor Gray
            }
    } else {
        Write-Host "  (No strong management evidence found)" -ForegroundColor Gray
    }

    Write-Host ""
}

function Get-WUSettingsCatalog {
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{ Id='AU.UseWUServer'; Path=$auPolicyPath; Name='UseWUServer'; Type='DWord'; Category='Source'; Editable=$true; Responsibility='Download source selection'; Description='Controls whether Automatic Updates uses a WSUS server (1) or Windows Update/Microsoft service endpoints (0).' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.WUServer'; Path=$wuPolicyPath; Name='WUServer'; Type='String'; Category='Source'; Editable=$true; Responsibility='Update discovery/download source'; Description='WSUS server URL used for update discovery and content retrieval when UseWUServer=1.' ; ValidValues='URL or blank' }
        [pscustomobject]@{ Id='WU.WUStatusServer'; Path=$wuPolicyPath; Name='WUStatusServer'; Type='String'; Category='Source'; Editable=$true; Responsibility='Reporting target'; Description='WSUS reporting/status URL used by the client when WSUS is enabled.' ; ValidValues='URL or blank' }
        [pscustomobject]@{ Id='WU.DoNotConnectToWindowsUpdateInternetLocations'; Path=$wuPolicyPath; Name='DoNotConnectToWindowsUpdateInternetLocations'; Type='DWord'; Category='Connectivity'; Editable=$true; Responsibility='Internet endpoint access'; Description='Blocks direct access to Microsoft Windows Update internet locations when enabled (1).' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.DisableDualScan'; Path=$wuPolicyPath; Name='DisableDualScan'; Type='DWord'; Category='Connectivity'; Editable=$true; Responsibility='Scan source behavior'; Description='Legacy control that affects whether the device scans Microsoft Update while WSUS policies are present.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.AllowAutoWindowsUpdateDownloadOverMeteredNetwork'; Path=$wuPolicyPath; Name='AllowAutoWindowsUpdateDownloadOverMeteredNetwork'; Type='DWord'; Category='Downloads'; Editable=$true; Responsibility='Download behavior on metered links'; Description='Allows or blocks automatic Windows Update downloads when the current network is metered.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.ExcludeWUDriversInQualityUpdate'; Path=$wuPolicyPath; Name='ExcludeWUDriversInQualityUpdate'; Type='DWord'; Category='Content'; Editable=$true; Responsibility='Content selection'; Description='When enabled, excludes driver updates from Windows Update quality update scans/install offers.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.DeferFeatureUpdates'; Path=$wuPolicyPath; Name='DeferFeatureUpdates'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Feature update installation timing'; Description='Enables feature update deferral policy. Must be 1 for DeferFeatureUpdatesPeriodinDays to take effect.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.DeferFeatureUpdatesPeriodinDays'; Path=$wuPolicyPath; Name='DeferFeatureUpdatesPeriodinDays'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Feature update install timing'; Description='Number of days to defer feature updates after release.' ; ValidValues='0-365' }
        [pscustomobject]@{ Id='WU.DeferQualityUpdates'; Path=$wuPolicyPath; Name='DeferQualityUpdates'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Quality update installation timing'; Description='Enables quality update deferral policy. Must be 1 for DeferQualityUpdatesPeriodinDays to take effect.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.DeferQualityUpdatesPeriodinDays'; Path=$wuPolicyPath; Name='DeferQualityUpdatesPeriodinDays'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Quality update install timing'; Description='Number of days to defer quality updates after release.' ; ValidValues='0-30' }
        [pscustomobject]@{ Id='WU.BranchReadinessLevel'; Path=$wuPolicyPath; Name='BranchReadinessLevel'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Feature update channel selection'; Description='Legacy servicing channel / branch readiness level (e.g., GA, Release Preview, Insider rings).' ; ValidValues='2,4,8,32' }
        [pscustomobject]@{ Id='WU.PauseFeatureUpdatesStartTime'; Path=$wuPolicyPath; Name='PauseFeatureUpdatesStartTime'; Type='String'; Category='Servicing'; Editable=$true; Responsibility='Feature update install pause'; Description='Start time marker for paused feature updates. Clearing it resumes paused feature updates.' ; ValidValues='DateTime string or blank' }
        [pscustomobject]@{ Id='WU.PauseQualityUpdatesStartTime'; Path=$wuPolicyPath; Name='PauseQualityUpdatesStartTime'; Type='String'; Category='Servicing'; Editable=$true; Responsibility='Quality update install pause'; Description='Start time marker for paused quality updates. Clearing it resumes paused quality updates.' ; ValidValues='DateTime string or blank' }
        [pscustomobject]@{ Id='WU.TargetReleaseVersion'; Path=$wuPolicyPath; Name='TargetReleaseVersion'; Type='DWord'; Category='Servicing'; Editable=$true; Responsibility='Feature version targeting'; Description='Enables targeting a specific Windows release version when paired with ProductVersion/TargetReleaseVersionInfo.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='WU.TargetReleaseVersionInfo'; Path=$wuPolicyPath; Name='TargetReleaseVersionInfo'; Type='String'; Category='Servicing'; Editable=$true; Responsibility='Feature version targeting'; Description='Target Windows release version (example: 23H2) used when TargetReleaseVersion=1.' ; ValidValues='Version label or blank' }
        [pscustomobject]@{ Id='WU.ProductVersion'; Path=$wuPolicyPath; Name='ProductVersion'; Type='String'; Category='Servicing'; Editable=$true; Responsibility='Feature version targeting'; Description='Product family targeted by release version policy (example: Windows 10 or Windows 11).' ; ValidValues='Product string or blank' }
        [pscustomobject]@{ Id='WU.SetAutoRestartNotificationDisable'; Path=$wuPolicyPath; Name='SetAutoRestartNotificationDisable'; Type='DWord'; Category='Restart UX'; Editable=$true; Responsibility='Restart notification behavior'; Description='Controls auto-restart notification behavior for updates that require a restart.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.NoAutoUpdate'; Path=$auPolicyPath; Name='NoAutoUpdate'; Type='DWord'; Category='Automatic Updates'; Editable=$true; Responsibility='Discovery/download/install automation'; Description='Disables Automatic Updates when set to 1. Device may still allow manual scanning/install depending on other policies.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.AUOptions'; Path=$auPolicyPath; Name='AUOptions'; Type='DWord'; Category='Automatic Updates'; Editable=$true; Responsibility='Discovery/download/install mode'; Description='Defines automatic update behavior (notify/download/schedule). Common values: 2 notify, 3 auto download notify install, 4 auto download schedule install.' ; ValidValues='2,3,4,5,7 (OS-dependent)' }
        [pscustomobject]@{ Id='AU.ScheduledInstallDay'; Path=$auPolicyPath; Name='ScheduledInstallDay'; Type='DWord'; Category='Scheduling'; Editable=$true; Responsibility='Scheduled installation day'; Description='Scheduled install day for AUOptions=4. 0=Every day, 1-7=Sunday-Saturday.' ; ValidValues='0-7' }
        [pscustomobject]@{ Id='AU.ScheduledInstallTime'; Path=$auPolicyPath; Name='ScheduledInstallTime'; Type='DWord'; Category='Scheduling'; Editable=$true; Responsibility='Scheduled installation hour'; Description='Scheduled install hour for AUOptions=4 in 24-hour format.' ; ValidValues='0-23' }
        [pscustomobject]@{ Id='AU.NoAutoRebootWithLoggedOnUsers'; Path=$auPolicyPath; Name='NoAutoRebootWithLoggedOnUsers'; Type='DWord'; Category='Restart'; Editable=$true; Responsibility='Install/restart enforcement'; Description='Prevents automatic restart for scheduled installations when a user is logged on.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.AlwaysAutoRebootAtScheduledTime'; Path=$auPolicyPath; Name='AlwaysAutoRebootAtScheduledTime'; Type='DWord'; Category='Restart'; Editable=$true; Responsibility='Install/restart enforcement'; Description='Forces automatic restart at the scheduled time after installation when enabled (legacy policy).' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.AlwaysAutoRebootAtScheduledTimeMinutes'; Path=$auPolicyPath; Name='AlwaysAutoRebootAtScheduledTimeMinutes'; Type='DWord'; Category='Restart'; Editable=$true; Responsibility='Install/restart enforcement timing'; Description='Minutes delay before forced reboot when AlwaysAutoRebootAtScheduledTime is enabled.' ; ValidValues='1-180 (common)' }
        [pscustomobject]@{ Id='AU.DetectionFrequencyEnabled'; Path=$auPolicyPath; Name='DetectionFrequencyEnabled'; Type='DWord'; Category='Scanning'; Editable=$true; Responsibility='Discovery cadence'; Description='Enables custom detection frequency for update scans.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.DetectionFrequency'; Path=$auPolicyPath; Name='DetectionFrequency'; Type='DWord'; Category='Scanning'; Editable=$true; Responsibility='Discovery cadence'; Description='Custom update detection frequency in hours when DetectionFrequencyEnabled=1.' ; ValidValues='1-22' }
        [pscustomobject]@{ Id='AU.RebootWarningTimeoutEnabled'; Path=$auPolicyPath; Name='RebootWarningTimeoutEnabled'; Type='DWord'; Category='Restart UX'; Editable=$true; Responsibility='Restart warning timing'; Description='Enables custom restart warning timeout before automatic restart.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.RebootWarningTimeout'; Path=$auPolicyPath; Name='RebootWarningTimeout'; Type='DWord'; Category='Restart UX'; Editable=$true; Responsibility='Restart warning timing'; Description='Minutes users are warned before automatic restart when enabled.' ; ValidValues='1-30 (common)' }
        [pscustomobject]@{ Id='AU.RebootRelaunchTimeoutEnabled'; Path=$auPolicyPath; Name='RebootRelaunchTimeoutEnabled'; Type='DWord'; Category='Restart UX'; Editable=$true; Responsibility='Restart reminder timing'; Description='Enables custom timeout before restart prompts are shown again.' ; ValidValues='0 or 1' }
        [pscustomobject]@{ Id='AU.RebootRelaunchTimeout'; Path=$auPolicyPath; Name='RebootRelaunchTimeout'; Type='DWord'; Category='Restart UX'; Editable=$true; Responsibility='Restart reminder timing'; Description='Minutes before restart notification reappears when enabled.' ; ValidValues='1-1440 (common)' }
        [pscustomobject]@{ Id='UX.ActiveHoursStart'; Path='HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name='ActiveHoursStart'; Type='DWord'; Category='Active Hours'; Editable=$true; Responsibility='Install/restart window'; Description='Beginning of active hours. Windows tries to avoid automatic restarts during this time.' ; ValidValues='0-23' }
        [pscustomobject]@{ Id='UX.ActiveHoursEnd'; Path='HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name='ActiveHoursEnd'; Type='DWord'; Category='Active Hours'; Editable=$true; Responsibility='Install/restart window'; Description='End of active hours. Windows may restart outside this window when required.' ; ValidValues='0-23' }
        [pscustomobject]@{ Id='UX.SmartActiveHoursState'; Path='HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name='SmartActiveHoursState'; Type='DWord'; Category='Active Hours'; Editable=$true; Responsibility='Install/restart window automation'; Description='Controls whether Windows dynamically adjusts active hours based on device usage patterns (build-dependent).' ; ValidValues='0 or 1 (build-dependent)' }
    )
}

function Get-RegistrySettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.PSObject.Properties.Name -contains $Name) { return $item.$Name }
    return $null
}

function Get-WUSettingsInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Catalog
    )

    $Catalog | ForEach-Object {
        $value = Get-RegistrySettingValue -Path $_.Path -Name $_.Name
        [pscustomobject]@{
            Id = $_.Id
            Category = $_.Category
            Responsibility = $_.Responsibility
            Description = $_.Description
            ValidValues = $_.ValidValues
            Path = $_.Path
            Name = $_.Name
            Type = $_.Type
            Editable = $_.Editable
            Value = $value
            IsSet = $null -ne $value
        }
    }
}

function Format-WUSettingValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$Value
    )

    if ($null -eq $Value) { return '(not set)' }
    if ($Value -is [array]) { return ($Value -join ', ') }
    return [string]$Value
}

function ConvertTo-WUSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Setting,
        [Parameter(Mandatory)]
        [string]$RawValue
    )

    if ($RawValue -eq '') {
        return [pscustomobject]@{ Clear = $true; Value = $null }
    }

    switch ($Setting.Type) {
        'DWord' {
            if ($RawValue -notmatch '^-?\d+$') {
                throw "Value must be an integer for $($Setting.Id)"
            }
            return [pscustomobject]@{ Clear = $false; Value = [int]$RawValue }
        }
        default {
            return [pscustomobject]@{ Clear = $false; Value = $RawValue }
        }
    }
}

function Set-WURegistryCatalogSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Setting,
        [Parameter(Mandatory)]
        [string]$RawValue
    )

    $converted = ConvertTo-WUSettingValue -Setting $Setting -RawValue $RawValue

    if (-not (Test-Path $Setting.Path)) {
        New-Item -Path $Setting.Path -Force | Out-Null
    }

    if ($converted.Clear) {
        Remove-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction SilentlyContinue
        Write-WUFBLog -Message "Cleared setting $($Setting.Id) ($($Setting.Path)\$($Setting.Name))" -Type 1
        return $null
    }

    Set-ItemProperty -Path $Setting.Path -Name $Setting.Name -Value $converted.Value -Type $Setting.Type -ErrorAction Stop
    Write-WUFBLog -Message "Set $($Setting.Id) = $($converted.Value)" -Type 1
    return $converted.Value
}

function Write-WUSettingsReferenceMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dashboard,
        [Parameter()]
        [string]$ChangedSettingId,
        [Parameter()]
        [object]$ChangedValue
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = "WU-Settings-Reference_$timestamp.md"
    $outputPath = Join-Path -Path (Get-Location) -ChildPath $fileName

    $catalog = @($Dashboard.SettingsCatalog)
    $inventory = @($Dashboard.SettingsInventory)
    $mgmt = $Dashboard.Management

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Windows Update Settings Reference")
    $lines.Add("")
    $lines.Add("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("- Computer: $($Dashboard.ComputerName)")
    $lines.Add("- Effective management source: $($mgmt.EffectiveSource)")
    $lines.Add("- Confidence: $($mgmt.Confidence)")
    $lines.Add("- Override risk: $($mgmt.OverrideRisk)")
    if ($ChangedSettingId) {
        $lines.Add("- Changed this run: ``$ChangedSettingId`` = ``$(Format-WUSettingValue -Value $ChangedValue)``")
    }
    $lines.Add("")
    $lines.Add("## How To Read This")
    $lines.Add("")
    $lines.Add("- `Responsibility` explains what part of the update lifecycle the setting affects (discovery, download, install, restart, etc.).")
    $lines.Add("- `Current Value` shows what is currently set in the registry path used by this tool.")
    $lines.Add("- If a device is managed by SCCM, Intune/MDM, or domain Group Policy, local changes may be overwritten.")
    $lines.Add("")
    $lines.Add("## Current Management Summary")
    $lines.Add("")
    $lines.Add("- Effective source: **$($mgmt.EffectiveSource)**")
    $lines.Add("- Co-managed: **$($mgmt.IsCoManaged)**")
    $lines.Add("- Editable locally: **$($mgmt.EditableLocally)**")
    if ($mgmt.SourcesDetected.Count -gt 0) {
        $lines.Add("- Detected sources: $($mgmt.SourcesDetected -join ', ')")
    }
    $lines.Add("")
    $lines.Add("## Settings")
    $lines.Add("")
    $lines.Add("| ID | Current Value | Registry Path | Type | Responsibility | What It Does | Typical Values |")
    $lines.Add("| --- | --- | --- | --- | --- | --- | --- |")

    foreach ($inv in ($inventory | Sort-Object Category, Id)) {
        $currentValue = (Format-WUSettingValue -Value $inv.Value) -replace '\|', '\|'
        $description = ($inv.Description -replace '\|', '\|')
        $validValues = ($inv.ValidValues -replace '\|', '\|')
        $responsibility = ($inv.Responsibility -replace '\|', '\|')
        $pathName = ("{0}\{1}" -f $inv.Path, $inv.Name) -replace '\|', '\|'
        $lines.Add("| `$($inv.Id)` | `$currentValue` | `$pathName` | `$($inv.Type)` | $responsibility | $description | $validValues |")
    }

    $lines.Add("")
    $lines.Add("## Evidence Used To Detect Management Source")
    $lines.Add("")
    if ($mgmt.Evidence.Count -eq 0) {
        $lines.Add("- No strong evidence signals found.")
    } else {
        foreach ($ev in ($mgmt.Evidence | Sort-Object Weight -Descending, Category, Signal)) {
            $lines.Add("- **[$($ev.Category)]** `$($ev.Signal)` = `$($ev.Value)` (`Weight=$($ev.Weight)`) - $($ev.Notes)")
        }
    }

    Set-Content -Path $outputPath -Value $lines -Encoding UTF8 -ErrorAction Stop
    Write-WUFBLog -Message "Generated settings reference markdown: $outputPath" -Type 1
    return $outputPath
}

function Show-WUSettingsEditor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dashboard
    )

    while ($true) {
        $inventory = @($Dashboard.SettingsInventory | Sort-Object Category, Id)
        Write-Host "`nEditable Windows Update Settings" -ForegroundColor Cyan
        Write-Host ("=" * 80) -ForegroundColor Gray

        $indexMap = @{}
        $i = 1
        foreach ($setting in $inventory) {
            $indexMap[[string]$i] = $setting.Id
            $valueText = Format-WUSettingValue -Value $setting.Value
            Write-Host ("[{0,2}] {1} = {2}" -f $i, $setting.Id, $valueText) -ForegroundColor Gray
            Write-Host ("      {0} | {1}" -f $setting.Responsibility, $setting.Description) -ForegroundColor DarkGray
            $i++
        }

        Write-Host ""
        Write-Host "Select a setting number to edit, [D]oc export, or [Q]uit editor." -ForegroundColor Yellow
        $selection = (Read-Host 'Selection').Trim()
        if ([string]::IsNullOrWhiteSpace($selection)) { continue }
        if ($selection.ToUpperInvariant() -eq 'Q') { return 'Back' }
        if ($selection.ToUpperInvariant() -eq 'D') {
            try {
                $docPath = Write-WUSettingsReferenceMarkdown -Dashboard $Dashboard
                Write-Host "Created: $docPath" -ForegroundColor Green
                return 'Refresh'
            } catch {
                Write-Host "Failed to create markdown: $($_.Exception.Message)" -ForegroundColor Red
                Write-WUFBLog -Message "Failed markdown export: $($_.Exception.Message)" -Type 3
                continue
            }
        }

        if (-not $indexMap.ContainsKey($selection)) {
            Write-Host "Invalid selection." -ForegroundColor Yellow
            continue
        }

        $settingId = $indexMap[$selection]
        $setting = $inventory | Where-Object { $_.Id -eq $settingId } | Select-Object -First 1
        if (-not $setting) {
            Write-Host "Setting lookup failed." -ForegroundColor Red
            continue
        }

        Write-Host "`nEditing $($setting.Id)" -ForegroundColor Cyan
        Write-Host "Current value: $(Format-WUSettingValue -Value $setting.Value)" -ForegroundColor Gray
        Write-Host "Registry: $($setting.Path)\$($setting.Name)" -ForegroundColor Gray
        Write-Host "Type: $($setting.Type)" -ForegroundColor Gray
        Write-Host "Responsibility: $($setting.Responsibility)" -ForegroundColor Gray
        Write-Host "What it does: $($setting.Description)" -ForegroundColor Gray
        Write-Host "Typical values: $($setting.ValidValues)" -ForegroundColor Gray
        Write-Host "Enter a new value. Submit an empty value to clear/remove the setting." -ForegroundColor Yellow

        $newRawValue = Read-Host 'New value'
        try {
            $newValue = Set-WURegistryCatalogSetting -Setting $setting -RawValue $newRawValue
            Write-Host "Updated $($setting.Id) to $(Format-WUSettingValue -Value $newValue)." -ForegroundColor Green

            $refresh = Get-WUDashboardData -HistoryTop $HistoryTop
            try {
                $docPath = Write-WUSettingsReferenceMarkdown -Dashboard $refresh -ChangedSettingId $setting.Id -ChangedValue $newValue
                Write-Host "Created settings reference: $docPath" -ForegroundColor Green
            } catch {
                Write-Host "Setting changed, but markdown generation failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-WUFBLog -Message "Setting changed but markdown generation failed: $($_.Exception.Message)" -Type 2
            }
            return 'Refresh'
        } catch {
            Write-Host "Failed to update setting: $($_.Exception.Message)" -ForegroundColor Red
            Write-WUFBLog -Message "Failed to update setting $($setting.Id): $($_.Exception.Message)" -Type 3
        }
    }
}

function Read-ValidatedHour {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    while ($true) {
        $raw = Read-Host $Prompt
        if ($raw -match '^\d+$') {
            $value = [int]$raw
            if ($value -ge 0 -and $value -le 23) { return $value }
        }
        Write-Host "Enter an hour from 0-23." -ForegroundColor Yellow
    }
}

function Set-WUActiveHours {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 23)]
        [int]$StartHour,
        [Parameter(Mandatory)]
        [ValidateRange(0, 23)]
        [int]$EndHour
    )

    $uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    if (-not (Test-Path $uxPath)) {
        New-Item -Path $uxPath -Force | Out-Null
    }

    Set-ItemProperty -Path $uxPath -Name 'ActiveHoursStart' -Value $StartHour -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $uxPath -Name 'ActiveHoursEnd' -Value $EndHour -Type DWord -ErrorAction Stop
    Write-WUFBLog -Message "Set active hours: Start=$StartHour End=$EndHour" -Type 1
}

function Set-WUMeteredDownloadBehavior {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(0, 1)]
        [int]$Allow
    )

    if (-not (Test-Path $wuPolicyPath)) {
        New-Item -Path $wuPolicyPath -Force | Out-Null
    }

    Set-ItemProperty -Path $wuPolicyPath -Name 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork' -Value $Allow -Type DWord -ErrorAction Stop
    Write-WUFBLog -Message "Set AllowAutoWindowsUpdateDownloadOverMeteredNetwork=$Allow" -Type 1
}

function Show-WUDashboardMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dashboard
    )

    while ($true) {
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [R] Refresh dashboard" -ForegroundColor Gray
        Write-Host "  [E] Show evidence details" -ForegroundColor Gray
        Write-Host "  [H] Change active hours" -ForegroundColor Gray
        Write-Host "  [M] Change metered download setting" -ForegroundColor Gray
        Write-Host "  [W] Continue to existing WUFB configuration flow" -ForegroundColor Gray
        Write-Host "  [Q] Quit" -ForegroundColor Gray

        $choice = (Read-Host "Select").Trim().ToUpperInvariant()
        switch ($choice) {
            'R' { return 'Refresh' }
            'E' {
                Write-Host "`nFull Evidence" -ForegroundColor Yellow
                $Dashboard.Management.Evidence | Sort-Object Category, Signal | Format-Table Category, Signal, Value, Path, Weight, Notes -AutoSize
            }
            'H' {
                try {
                    $startHour = Read-ValidatedHour -Prompt 'Active hours start (0-23)'
                    $endHour = Read-ValidatedHour -Prompt 'Active hours end (0-23)'
                    Set-WUActiveHours -StartHour $startHour -EndHour $endHour
                    Write-Host "Active hours updated." -ForegroundColor Green
                    return 'Refresh'
                } catch {
                    Write-Host "Failed to set active hours: $($_.Exception.Message)" -ForegroundColor Red
                    Write-WUFBLog -Message "Failed to set active hours: $($_.Exception.Message)" -Type 3
                }
            }
            'M' {
                Write-Host "  [0] Do not allow auto-download over metered networks" -ForegroundColor Gray
                Write-Host "  [1] Allow auto-download over metered networks" -ForegroundColor Gray
                $meteredChoice = (Read-Host 'Select 0 or 1').Trim()
                if ($meteredChoice -notin @('0', '1')) {
                    Write-Host "Invalid selection." -ForegroundColor Yellow
                    continue
                }
                try {
                    Set-WUMeteredDownloadBehavior -Allow ([int]$meteredChoice)
                    Write-Host "Metered download behavior updated." -ForegroundColor Green
                    return 'Refresh'
                } catch {
                    Write-Host "Failed to set metered download behavior: $($_.Exception.Message)" -ForegroundColor Red
                    Write-WUFBLog -Message "Failed to set metered download behavior: $($_.Exception.Message)" -Type 3
                }
            }
            'W' { return 'Continue' }
            'Q' { return 'Quit' }
            default { Write-Host "Invalid selection." -ForegroundColor Yellow }
        }
    }
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
# DISCOVERY DASHBOARD (NEW)
# ============================================================================
$dashboard = Get-WUDashboardData -HistoryTop $HistoryTop
Show-WUDashboard -Dashboard $dashboard
Write-WUFBLog -Message "Discovery dashboard shown: EffectiveSource=$($dashboard.Management.EffectiveSource), Confidence=$($dashboard.Management.Confidence), OverrideRisk=$($dashboard.Management.OverrideRisk)" -Type 1

if ($ViewOnly) {
    Write-WUFBLog -Message "ViewOnly requested; exiting after dashboard" -Type 1
    Complete-WUFBLog -Success $true
    return
}

if ($Interactive) {
    while ($true) {
        $dashboardAction = Show-WUDashboardMenu -Dashboard $dashboard
        switch ($dashboardAction) {
            'Refresh' {
                $dashboard = Get-WUDashboardData -HistoryTop $HistoryTop
                Show-WUDashboard -Dashboard $dashboard
                continue
            }
            'Quit' {
                Write-WUFBLog -Message "User exited from discovery dashboard" -Type 1
                Complete-WUFBLog -Success $true
                return
            }
            'Continue' {
                break
            }
            default {
                break
            }
        }
    }
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
