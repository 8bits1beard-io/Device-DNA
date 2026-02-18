<#
.SYNOPSIS
    Diagnostic test script for Windows Update configuration, status, and history.
.DESCRIPTION
    Standalone diagnostic that reads all Windows Update registry hives, queries the
    Windows Update Agent (WUA) COM API for pending updates and install history, checks
    OS build/patch level, Delivery Optimization settings, and reboot status.

    Registry hives examined:
    1.  HKLM\...\Policies\...\WindowsUpdate          (GPO: update source, deferrals, active hours)
    2.  HKLM\...\Policies\...\WindowsUpdate\AU        (GPO: automatic update behavior, WSUS, restart)
    3.  HKLM\...\WindowsUpdate\UpdatePolicy\Settings   (Runtime: pause state)
    4.  HKLM\...\WindowsUpdate\UX\Settings             (User: Settings app preferences)
    5.  HKLM\...\WindowsUpdate\Auto Update             (Runtime: reboot pending)
    6.  HKLM\...\Auto Update\Results\Detect            (Last scan timestamp + error)
    7.  HKLM\...\Auto Update\Results\Install           (Last install timestamp + error)
    8.  HKLM\...\Auto Update\Results\Download          (Last download timestamp + error)
    9.  HKLM\...\Windows NT\CurrentVersion             (OS build, UBR, edition)
    10. HKLM\...\Policies\...\DeliveryOptimization     (P2P delivery mode, bandwidth, cache)

    WUA COM API queries:
    - Windows Update service state (wuauserv)
    - IAutomaticUpdatesResults: LastSearchSuccessDate, LastInstallationSuccessDate
    - IUpdateSearcher.Search: Pending (not installed, not hidden) updates
    - IUpdateSearcher.QueryHistory: Recent update install/uninstall history

    Ref: https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb
    Ref: https://learn.microsoft.com/windows/win32/wua_sdk/windows-update-agent-object-model
    Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatehistoryentry
    Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iautomaticupdatesresults
    Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization
.PARAMETER OutputPath
    Directory for output files. Defaults to output/<DeviceName>/ under the repo root.
.PARAMETER DeviceName
    Override the device name. Defaults to $env:COMPUTERNAME.
.PARAMETER ComputerName
    Remote computer to query. If omitted, reads local registry.
.EXAMPLE
    .\tests\Test-WindowsUpdateConfig.ps1
.EXAMPLE
    .\tests\Test-WindowsUpdateConfig.ps1 -ComputerName "PC001"
.NOTES
    Requires: PowerShell 5.1+, local admin rights (for HKLM policy keys + WUA COM)
    No Graph API or Azure AD join required.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$DeviceName,

    [Parameter()]
    [string]$ComputerName
)

#region Module Loading
$scriptRoot = Split-Path -Parent $PSScriptRoot  # repo root (tests/ -> repo root)

# Dot-source modules in dependency order (only what we need for logging)
. (Join-Path $scriptRoot 'modules\Core.ps1')
. (Join-Path $scriptRoot 'modules\Logging.ps1')
. (Join-Path $scriptRoot 'modules\Helpers.ps1')
#endregion Module Loading

#region Initialization
$testStartTime = Get-Date
$isRemote = -not [string]::IsNullOrEmpty($ComputerName)

if ([string]::IsNullOrEmpty($DeviceName)) {
    $DeviceName = if ($isRemote) { $ComputerName } else { $env:COMPUTERNAME }
}

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $scriptRoot "output\$DeviceName"
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DeviceDNA - Windows Update Config Diagnostic" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName
if ($logPath) {
    Write-StatusMessage "Log file: $logPath" -Type Info
}

$component = "Test-WUConfig"
Write-DeviceDNALog -Message "=== Windows Update Config Diagnostic ===" -Component $component -Type 1
Write-DeviceDNALog -Message "Device: $DeviceName" -Component $component -Type 1
Write-DeviceDNALog -Message "Remote: $isRemote" -Component $component -Type 1
Write-DeviceDNALog -Message "Output: $OutputPath" -Component $component -Type 1
#endregion Initialization

#region Registry Hive Definitions
# Each hive defines the registry path and the known keys with their meaning.
# This lets us log both known keys (with decoded values) and any unexpected keys we find.
# IgnoreExtra = $true means unknown keys are captured silently (no [EXTRA] warnings).

$registryHives = @(
    @{
        Name = 'WindowsUpdate Policy'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        Description = 'GPO/MDM-controlled update source, deferrals, and active hours'
        IgnoreExtra = $false
        KnownKeys = @{
            'WUServer'                               = @{ Type = 'REG_SZ';    Meaning = 'WSUS server URL' }
            'WUStatusServer'                         = @{ Type = 'REG_SZ';    Meaning = 'WSUS status reporting URL' }
            'DoNotConnectToWindowsUpdateInternetLocations' = @{ Type = 'REG_DWORD'; Meaning = '1=Block WU internet (WSUS only)' }
            'DisableWindowsUpdateAccess'             = @{ Type = 'REG_DWORD'; Meaning = '1=Disable WU access entirely' }
            'SetActiveHours'                         = @{ Type = 'REG_DWORD'; Meaning = '0=Disabled, 1=Enabled' }
            'ActiveHoursStart'                       = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)' }
            'ActiveHoursEnd'                         = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)' }
            'BranchReadinessLevel'                   = @{ Type = 'REG_DWORD'; Meaning = '2=Insider Fast, 4=Insider Slow, 8=Release Preview, absent=GA' }
            'DeferFeatureUpdates'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Defer feature updates' }
            'DeferFeatureUpdatesPeriodinDays'        = @{ Type = 'REG_DWORD'; Meaning = '0-365 days deferral' }
            'DeferQualityUpdates'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Defer quality updates' }
            'DeferQualityUpdatesPeriodinDays'        = @{ Type = 'REG_DWORD'; Meaning = '0-35 days deferral' }
            'PauseFeatureUpdatesStartTime'           = @{ Type = 'REG_DWORD'; Meaning = '1=Feature updates paused' }
            'PauseQualityUpdatesStartTime'           = @{ Type = 'REG_DWORD'; Meaning = '1=Quality updates paused' }
            'ExcludeWUDriversInQualityUpdate'        = @{ Type = 'REG_DWORD'; Meaning = '1=Exclude drivers from updates' }
            'AllowOptionalContent'                   = @{ Type = 'REG_DWORD'; Meaning = '1=Auto optional+CFRs, 2=Auto optional, 3=User selects' }
            'AllowTemporaryEnterpriseFeatureControl' = @{ Type = 'REG_DWORD'; Meaning = '1=Enable features behind enterprise control' }
            'TargetGroup'                            = @{ Type = 'REG_SZ';    Meaning = 'WSUS target group name' }
            'TargetGroupEnabled'                     = @{ Type = 'REG_DWORD'; Meaning = '1=Client-side targeting enabled' }
            'ElevateNonAdmins'                       = @{ Type = 'REG_DWORD'; Meaning = '1=Non-admins can approve updates' }
            'SetProxyBehaviorForUpdateDetection'     = @{ Type = 'REG_DWORD'; Meaning = '0=Default proxy, 1=No proxy for detection' }
            'AcceptTrustedPublisherCerts'            = @{ Type = 'REG_DWORD'; Meaning = '1=Accept third-party publisher certs from WSUS' }
            'DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection' = @{ Type = 'REG_DWORD'; Meaning = '0=Enforce TLS cert pinning, 1=Disable' }
            'UseUpdateClassPolicySource'             = @{ Type = 'REG_DWORD'; Meaning = '0=Default, 1=Use policy for update classification' }
            'UpdateServiceUrlAlternate'              = @{ Type = 'REG_SZ';    Meaning = 'Alternate update service URL (e.g. SCCM local cache)' }
            'FillEmptyContentUrls'                   = @{ Type = 'REG_DWORD'; Meaning = '1=Fill empty content URLs with fallback' }
            'AUPowerManagement'                      = @{ Type = 'REG_DWORD'; Meaning = '1=Wake computer to install updates' }
        }
    },
    @{
        Name = 'Automatic Updates (AU)'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        Description = 'GPO/MDM-controlled automatic update behavior, WSUS, restart'
        IgnoreExtra = $false
        KnownKeys = @{
            'NoAutoUpdate'                          = @{ Type = 'REG_DWORD'; Meaning = '1=Disable automatic updates' }
            'AUOptions'                             = @{ Type = 'REG_DWORD'; Meaning = '2=Notify DL+Install, 3=Auto DL notify Install, 4=Auto DL+Schedule, 5=Local admin decides' }
            'UseWUServer'                           = @{ Type = 'REG_DWORD'; Meaning = '1=Use WSUS server' }
            'ScheduledInstallDay'                   = @{ Type = 'REG_DWORD'; Meaning = '0=Every day, 1=Sun..7=Sat' }
            'ScheduledInstallTime'                  = @{ Type = 'REG_DWORD'; Meaning = '0-23 (hour)' }
            'AlwaysAutoRebootAtScheduledTime'       = @{ Type = 'REG_DWORD'; Meaning = '1=Force restart at scheduled time' }
            'AlwaysAutoRebootAtScheduledTimeMinutes'= @{ Type = 'REG_DWORD'; Meaning = '15-180 minutes warning before restart' }
            'NoAutoRebootWithLoggedOnUsers'         = @{ Type = 'REG_DWORD'; Meaning = '1=No restart if user signed in' }
            'IncludeRecommendedUpdates'             = @{ Type = 'REG_DWORD'; Meaning = '1=Include recommended updates' }
            'AutoInstallMinorUpdates'               = @{ Type = 'REG_DWORD'; Meaning = '1=Silently install minor updates' }
            'AUPowerManagement'                     = @{ Type = 'REG_DWORD'; Meaning = '1=Wake computer to install updates' }
        }
    },
    @{
        Name = 'Update Policy State'
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'
        Description = 'Runtime pause/deferral state (not policy - reflects current state)'
        IgnoreExtra = $false
        KnownKeys = @{
            'PausedFeatureDate'    = @{ Type = 'REG_SZ';    Meaning = 'Date feature updates were paused' }
            'PausedFeatureStatus'  = @{ Type = 'REG_DWORD'; Meaning = '0=Not paused, 1=Paused, 2=Auto-resumed' }
            'PausedQualityDate'    = @{ Type = 'REG_SZ';    Meaning = 'Date quality updates were paused' }
            'PausedQualityStatus'  = @{ Type = 'REG_DWORD'; Meaning = '0=Not paused, 1=Paused, 2=Auto-resumed' }
        }
    },
    @{
        Name = 'UX Settings (User Preferences)'
        Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        Description = 'User-chosen preferences from Settings app'
        IgnoreExtra = $false
        KnownKeys = @{
            'IsContinuousInnovationOptedIn'  = @{ Type = 'REG_DWORD'; Meaning = '1=Get latest updates ASAP' }
            'AllowMUUpdateService'           = @{ Type = 'REG_DWORD'; Meaning = '1=Receive updates for other MS products' }
            'IsExpedited'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Restart 15 min after install' }
            'RestartNotificationsAllowed2'   = @{ Type = 'REG_DWORD'; Meaning = '1=Show restart notifications' }
            'ActiveHoursStart'               = @{ Type = 'REG_DWORD'; Meaning = '0-23 (user-set active hours start)' }
            'ActiveHoursEnd'                 = @{ Type = 'REG_DWORD'; Meaning = '0-23 (user-set active hours end)' }
            'PendingRebootStartTime'         = @{ Type = 'REG_SZ';    Meaning = 'Timestamp when reboot became pending' }
        }
    },
    @{
        Name = 'Auto Update Runtime'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        Description = 'Runtime auto-update state (reboot pending, last detection)'
        IgnoreExtra = $false
        KnownKeys = @{
            'RebootRequired'  = @{ Type = 'REG_DWORD'; Meaning = 'Reboot pending for updates (key presence = pending)' }
            'LastOnline'      = @{ Type = 'REG_SZ';    Meaning = 'Last time WU checked online' }
        }
    },
    @{
        Name = 'Last Scan Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Detect'
        Description = 'Last successful update scan timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful scan time' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last scan attempt' }
        }
    },
    @{
        Name = 'Last Install Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install'
        Description = 'Last successful update install timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful install time' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last install attempt' }
        }
    },
    @{
        Name = 'Last Download Result'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Download'
        Description = 'Last successful update download timestamp and error code'
        IgnoreExtra = $false
        KnownKeys = @{
            'LastSuccessTime' = @{ Type = 'REG_SZ';    Meaning = 'Last successful download time' }
            'LastError'       = @{ Type = 'REG_DWORD'; Meaning = 'HRESULT of last download attempt' }
        }
    },
    @{
        Name = 'OS Version'
        Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Description = 'Current OS build, feature update version, and edition'
        IgnoreExtra = $true  # This key has many values we don't need; only capture listed keys
        KnownKeys = @{
            'CurrentBuild'       = @{ Type = 'REG_SZ';    Meaning = 'OS build number (e.g. 26100)' }
            'CurrentBuildNumber' = @{ Type = 'REG_SZ';    Meaning = 'OS build number (alias)' }
            'UBR'                = @{ Type = 'REG_DWORD'; Meaning = 'Update Build Revision (cumulative update level)' }
            'DisplayVersion'     = @{ Type = 'REG_SZ';    Meaning = 'Feature update version (e.g. 24H2)' }
            'ProductName'        = @{ Type = 'REG_SZ';    Meaning = 'OS product name' }
            'EditionID'          = @{ Type = 'REG_SZ';    Meaning = 'OS edition (Enterprise, Professional, etc.)' }
            'InstallDate'        = @{ Type = 'REG_DWORD'; Meaning = 'Unix timestamp of OS installation' }
            'ReleaseId'          = @{ Type = 'REG_SZ';    Meaning = 'Release ID (deprecated, always 2009 on 21H1+)' }
            'InstallationType'   = @{ Type = 'REG_SZ';    Meaning = 'Client or Server' }
            'BuildBranch'        = @{ Type = 'REG_SZ';    Meaning = 'Build branch (e.g. ge_release)' }
        }
    },
    @{
        # Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization
        Name = 'Delivery Optimization'
        Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        Description = 'P2P content delivery and bandwidth policies for updates'
        IgnoreExtra = $false
        KnownKeys = @{
            'DODownloadMode'                           = @{ Type = 'REG_DWORD'; Meaning = '0=HTTP only, 1=LAN, 2=Group, 3=Internet, 99=Simple, 100=Bypass' }
            'DOGroupId'                                = @{ Type = 'REG_SZ';    Meaning = 'Custom peer group GUID' }
            'DOGroupIdSource'                          = @{ Type = 'REG_DWORD'; Meaning = '1=AD Site, 2=Auth domain SID, 3=DHCP, 4=DNS suffix, 5=AAD tenant' }
            'DORestrictPeerSelectionBy'                = @{ Type = 'REG_DWORD'; Meaning = '0=None, 1=Subnet mask, 2=Local discovery (DNS-SD)' }
            'DOMaxCacheSize'                           = @{ Type = 'REG_DWORD'; Meaning = 'Max cache size (% of disk)' }
            'DOAbsoluteMaxCacheSize'                   = @{ Type = 'REG_DWORD'; Meaning = 'Max cache size (GB, absolute)' }
            'DOMaxCacheAge'                            = @{ Type = 'REG_DWORD'; Meaning = 'Max cache age (seconds)' }
            'DOMaxBackgroundDownloadBandwidth'         = @{ Type = 'REG_DWORD'; Meaning = 'Max background download bandwidth (KB/s)' }
            'DOMaxForegroundDownloadBandwidth'         = @{ Type = 'REG_DWORD'; Meaning = 'Max foreground download bandwidth (KB/s)' }
            'DOAllowVPNPeerCaching'                    = @{ Type = 'REG_DWORD'; Meaning = '1=Allow peer caching over VPN' }
            'DOMinRAMAllowedToPeer'                    = @{ Type = 'REG_DWORD'; Meaning = 'Min RAM (GB) for peer caching' }
            'DOMinDiskSizeAllowedToPeer'               = @{ Type = 'REG_DWORD'; Meaning = 'Min disk size (GB) for peer caching' }
            'DOMinFileSizeToCache'                     = @{ Type = 'REG_DWORD'; Meaning = 'Min file size (MB) for peer caching' }
            'DOMinBatteryPercentageAllowedToUpload'    = @{ Type = 'REG_DWORD'; Meaning = 'Min battery % to allow upload' }
            'DOCacheHost'                              = @{ Type = 'REG_SZ';    Meaning = 'Connected Cache server hostname or IP' }
            'DOCacheHostSource'                        = @{ Type = 'REG_DWORD'; Meaning = '1=DHCP option 235, 2=Group policy' }
            'DODelayBackgroundDownloadFromHttp'        = @{ Type = 'REG_DWORD'; Meaning = 'Delay background HTTP download (seconds)' }
            'DODelayForegroundDownloadFromHttp'        = @{ Type = 'REG_DWORD'; Meaning = 'Delay foreground HTTP download (seconds)' }
            'DODelayCacheServerFallbackBackground'     = @{ Type = 'REG_DWORD'; Meaning = 'Delay cache server fallback for background (seconds)' }
            'DODelayCacheServerFallbackForeground'     = @{ Type = 'REG_DWORD'; Meaning = 'Delay cache server fallback for foreground (seconds)' }
        }
    }
)
#endregion Registry Hive Definitions

#region Registry Reading Functions
function Read-RegistryHive {
    <#
    .SYNOPSIS
        Reads all values from a registry path and logs findings.
    .DESCRIPTION
        Reads a registry hive, decodes known keys, flags unknown keys,
        and returns a structured hashtable of results.
    #>
    param(
        [hashtable]$HiveDef,
        [string]$RemoteComputer
    )

    $hiveName = $HiveDef.Name
    $hivePath = $HiveDef.Path
    $knownKeys = $HiveDef.KnownKeys
    $ignoreExtra = if ($HiveDef.ContainsKey('IgnoreExtra')) { $HiveDef.IgnoreExtra } else { $false }

    Write-DeviceDNALog -Message "--- Reading: $hiveName ---" -Component $component -Type 1
    Write-DeviceDNALog -Message "  Path: $hivePath" -Component $component -Type 1

    $result = @{
        Name        = $hiveName
        Path        = $hivePath
        Description = $HiveDef.Description
        Exists      = $false
        Values      = @{}
        UnknownKeys = @{}
        Error       = $null
    }

    try {
        # For remote, we need to use Invoke-Command
        if (-not [string]::IsNullOrEmpty($RemoteComputer)) {
            $regData = Invoke-Command -ComputerName $RemoteComputer -ScriptBlock {
                param($path)
                $out = @{ Exists = $false; Properties = @{} }
                if (Test-Path $path) {
                    $out.Exists = $true
                    $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                    if ($item) {
                        $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                            $out.Properties[$_.Name] = $_.Value
                        }
                    }
                }
                return $out
            } -ArgumentList $hivePath -ErrorAction Stop

            $result.Exists = $regData.Exists
            $properties = $regData.Properties
        }
        else {
            # Local read
            if (Test-Path $hivePath) {
                $result.Exists = $true
                $item = Get-ItemProperty -Path $hivePath -ErrorAction SilentlyContinue
                $properties = @{}
                if ($item) {
                    $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                        $properties[$_.Name] = $_.Value
                    }
                }
            }
            else {
                $result.Exists = $false
                $properties = @{}
            }
        }

        if (-not $result.Exists) {
            Write-DeviceDNALog -Message "  Key does NOT exist (not configured)" -Component $component -Type 1
            Write-StatusMessage "  $hiveName`: Key not present (not configured)" -Type Info
            return $result
        }

        Write-DeviceDNALog -Message "  Key EXISTS - reading values..." -Component $component -Type 1

        if ($properties.Count -eq 0) {
            Write-DeviceDNALog -Message "  Key exists but has NO values" -Component $component -Type 1
            Write-StatusMessage "  $hiveName`: Key exists but empty" -Type Info
            return $result
        }

        # Process each property found
        foreach ($propName in $properties.Keys) {
            $propValue = $properties[$propName]

            if ($knownKeys.ContainsKey($propName)) {
                # Known key - decode and log
                $keyInfo = $knownKeys[$propName]
                $result.Values[$propName] = @{
                    Value   = $propValue
                    Meaning = $keyInfo.Meaning
                    Known   = $true
                }

                # Decode specific values for human-readable logging
                $decoded = Get-DecodedValue -KeyName $propName -Value $propValue
                Write-DeviceDNALog -Message "  [KNOWN] $propName = $propValue ($decoded)" -Component $component -Type 1
            }
            else {
                if ($ignoreExtra) {
                    # Silently skip - don't log or capture
                    continue
                }
                # Unknown key - log as informational
                $result.UnknownKeys[$propName] = $propValue
                $result.Values[$propName] = @{
                    Value   = $propValue
                    Meaning = '(not in known key list)'
                    Known   = $false
                }
                Write-DeviceDNALog -Message "  [EXTRA] $propName = $propValue" -Component $component -Type 2
            }
        }

        # Check for known keys that are absent (worth noting)
        $absentKeys = @()
        foreach ($knownName in $knownKeys.Keys) {
            if (-not $properties.ContainsKey($knownName)) {
                $absentKeys += $knownName
            }
        }
        if ($absentKeys.Count -gt 0) {
            Write-DeviceDNALog -Message "  Absent known keys: $($absentKeys -join ', ')" -Component $component -Type 1
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-DeviceDNALog -Message "  ERROR reading hive: $($_.Exception.Message)" -Component $component -Type 3
        Write-StatusMessage "  $hiveName`: ERROR - $($_.Exception.Message)" -Type Error
    }

    return $result
}

function Get-DecodedValue {
    <#
    .SYNOPSIS
        Decodes a registry value into a human-readable description.
    #>
    param(
        [string]$KeyName,
        $Value
    )

    switch ($KeyName) {
        'AUOptions' {
            switch ($Value) {
                2 { return 'Notify download + install' }
                3 { return 'Auto download, notify install' }
                4 { return 'Auto download + schedule install' }
                5 { return 'Local admin decides' }
                default { return "Unknown ($Value)" }
            }
        }
        'ScheduledInstallDay' {
            switch ($Value) {
                0 { return 'Every day' }
                1 { return 'Sunday' }
                2 { return 'Monday' }
                3 { return 'Tuesday' }
                4 { return 'Wednesday' }
                5 { return 'Thursday' }
                6 { return 'Friday' }
                7 { return 'Saturday' }
                default { return "Unknown ($Value)" }
            }
        }
        'ScheduledInstallTime' {
            if ($Value -ge 0 -and $Value -le 23) {
                $hour = if ($Value -eq 0) { '12:00 AM' }
                        elseif ($Value -lt 12) { "$Value`:00 AM" }
                        elseif ($Value -eq 12) { '12:00 PM' }
                        else { "$($Value - 12)`:00 PM" }
                return $hour
            }
            return "Invalid ($Value)"
        }
        'ActiveHoursStart' {
            if ($Value -ge 0 -and $Value -le 23) {
                $hour = if ($Value -eq 0) { '12:00 AM' }
                        elseif ($Value -lt 12) { "$Value`:00 AM" }
                        elseif ($Value -eq 12) { '12:00 PM' }
                        else { "$($Value - 12)`:00 PM" }
                return $hour
            }
            return "Invalid ($Value)"
        }
        'ActiveHoursEnd' {
            if ($Value -ge 0 -and $Value -le 23) {
                $hour = if ($Value -eq 0) { '12:00 AM' }
                        elseif ($Value -lt 12) { "$Value`:00 AM" }
                        elseif ($Value -eq 12) { '12:00 PM' }
                        else { "$($Value - 12)`:00 PM" }
                return $hour
            }
            return "Invalid ($Value)"
        }
        'BranchReadinessLevel' {
            switch ($Value) {
                2  { return 'Windows Insider - Fast' }
                4  { return 'Windows Insider - Slow' }
                8  { return 'Release Preview' }
                32 { return 'General Availability Channel' }
                default { return "Unknown ($Value)" }
            }
        }
        'PausedFeatureStatus' {
            switch ($Value) {
                0 { return 'Not paused' }
                1 { return 'Paused' }
                2 { return 'Auto-resumed after pause' }
                default { return "Unknown ($Value)" }
            }
        }
        'PausedQualityStatus' {
            switch ($Value) {
                0 { return 'Not paused' }
                1 { return 'Paused' }
                2 { return 'Auto-resumed after pause' }
                default { return "Unknown ($Value)" }
            }
        }
        'AllowOptionalContent' {
            switch ($Value) {
                1 { return 'Auto optional + CFRs' }
                2 { return 'Auto optional only' }
                3 { return 'User selects' }
                default { return "Not configured ($Value)" }
            }
        }
        # Ref: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization#dodownloadmode
        'DODownloadMode' {
            switch ($Value) {
                0   { return 'HTTP only (no peering)' }
                1   { return 'LAN (peers behind same NAT)' }
                2   { return 'Group (private group peering)' }
                3   { return 'Internet (internet peering)' }
                99  { return 'Simple (HTTP only, no DO cloud)' }
                100 { return 'Bypass (BITS, deprecated Win11)' }
                default { return "Unknown ($Value)" }
            }
        }
        'DOGroupIdSource' {
            switch ($Value) {
                1 { return 'AD Site' }
                2 { return 'Authenticated domain SID' }
                3 { return 'DHCP option ID' }
                4 { return 'DNS suffix' }
                5 { return 'AAD tenant ID' }
                default { return "Unknown ($Value)" }
            }
        }
        'DORestrictPeerSelectionBy' {
            switch ($Value) {
                0 { return 'None' }
                1 { return 'Subnet mask' }
                2 { return 'Local discovery (DNS-SD)' }
                default { return "Unknown ($Value)" }
            }
        }
        'DOCacheHostSource' {
            switch ($Value) {
                1 { return 'DHCP option 235' }
                2 { return 'Group Policy' }
                default { return "Unknown ($Value)" }
            }
        }
        'LastError' {
            if ($Value -eq 0) { return 'Success (0x00000000)' }
            return ('0x{0:X8}' -f $Value)
        }
        'InstallDate' {
            try {
                $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
                $date = $epoch.AddSeconds($Value).ToLocalTime()
                return $date.ToString('yyyy-MM-dd HH:mm:ss')
            }
            catch { return "$Value" }
        }
        default {
            # Boolean-style DWORD keys
            if ($Value -is [int] -and $Value -le 1) {
                $boolKeys = @(
                    'NoAutoUpdate', 'UseWUServer', 'SetActiveHours',
                    'DoNotConnectToWindowsUpdateInternetLocations', 'DisableWindowsUpdateAccess',
                    'DeferFeatureUpdates', 'DeferQualityUpdates',
                    'ExcludeWUDriversInQualityUpdate', 'NoAutoRebootWithLoggedOnUsers',
                    'AlwaysAutoRebootAtScheduledTime', 'IsContinuousInnovationOptedIn',
                    'AllowMUUpdateService', 'IsExpedited', 'RestartNotificationsAllowed2',
                    'AllowTemporaryEnterpriseFeatureControl', 'TargetGroupEnabled',
                    'ElevateNonAdmins', 'IncludeRecommendedUpdates', 'AutoInstallMinorUpdates',
                    'SetProxyBehaviorForUpdateDetection', 'AcceptTrustedPublisherCerts',
                    'DoNotEnforceEnterpriseTLSCertPinningForUpdateDetection',
                    'UseUpdateClassPolicySource', 'FillEmptyContentUrls', 'AUPowerManagement',
                    'DOAllowVPNPeerCaching'
                )
                if ($KeyName -in $boolKeys) {
                    if ($Value -eq 1) { return 'Enabled' } else { return 'Disabled' }
                }
            }
            return "$Value"
        }
    }
}
#endregion Registry Reading Functions

#region Special Checks
function Test-RebootRequired {
    <#
    .SYNOPSIS
        Checks multiple indicators for pending reboot from Windows Update.
    #>
    param([string]$RemoteComputer)

    $rebootPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )

    $results = @{
        RebootRequired   = $false
        RebootPending    = $false
        PendingFileRename = $false
        Indicators       = @()
    }

    try {
        if (-not [string]::IsNullOrEmpty($RemoteComputer)) {
            $remoteResult = Invoke-Command -ComputerName $RemoteComputer -ScriptBlock {
                param($paths)
                $out = @{ Indicators = @() }
                foreach ($p in $paths) {
                    if (Test-Path $p) {
                        $out.Indicators += $p
                    }
                }
                # Check PendingFileRenameOperations
                $sfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($sfr -and $sfr.PendingFileRenameOperations) {
                    $out.Indicators += 'PendingFileRenameOperations'
                }
                return $out
            } -ArgumentList (,$rebootPaths) -ErrorAction Stop

            $results.Indicators = $remoteResult.Indicators
        }
        else {
            foreach ($path in $rebootPaths) {
                if (Test-Path $path) {
                    $results.Indicators += $path
                }
            }
            # Check PendingFileRenameOperations
            $sfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($sfr -and $sfr.PendingFileRenameOperations) {
                $results.Indicators += 'PendingFileRenameOperations'
            }
        }

        foreach ($indicator in $results.Indicators) {
            if ($indicator -like '*RebootRequired*') { $results.RebootRequired = $true }
            if ($indicator -like '*RebootPending*') { $results.RebootPending = $true }
            if ($indicator -eq 'PendingFileRenameOperations') { $results.PendingFileRename = $true }
        }
    }
    catch {
        Write-DeviceDNALog -Message "Error checking reboot status: $($_.Exception.Message)" -Component $component -Type 3
    }

    return $results
}

function Get-WUAUpdateStatus {
    <#
    .SYNOPSIS
        Queries WUA COM API for service state, pending updates, and install history.
    .DESCRIPTION
        Uses Microsoft.Update.Session and Microsoft.Update.AutoUpdate COM objects.
        Ref: https://learn.microsoft.com/windows/win32/wua_sdk/windows-update-agent-object-model
        Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatehistoryentry
        Ref: https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iautomaticupdatesresults
    #>
    param([string]$RemoteComputer)

    $wuaScript = {
        $result = @{
            ServiceStatus    = 'Unknown'
            ServiceStartType = 'Unknown'
            LastSearchSuccess  = $null
            LastInstallSuccess = $null
            PendingUpdates   = @()
            PendingCount     = 0
            RecentHistory    = @()
            TotalHistoryCount = 0
            Error            = $null
        }

        try {
            # --- Service state ---
            $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
            if ($svc) {
                $result.ServiceStatus = $svc.Status.ToString()
                $result.ServiceStartType = $svc.StartType.ToString()
            }

            # --- AutomaticUpdates results (last scan/install dates) ---
            # Ref: IAutomaticUpdatesResults interface
            try {
                $au = New-Object -ComObject Microsoft.Update.AutoUpdate
                $auResults = $au.Results
                if ($auResults.LastSearchSuccessDate) {
                    $result.LastSearchSuccess = $auResults.LastSearchSuccessDate.ToString('yyyy-MM-dd HH:mm:ss')
                }
                if ($auResults.LastInstallationSuccessDate) {
                    $result.LastInstallSuccess = $auResults.LastInstallationSuccessDate.ToString('yyyy-MM-dd HH:mm:ss')
                }
            }
            catch {
                # AutoUpdate COM may fail if service is disabled or not available
            }

            # --- WUA Session: pending updates + history ---
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()

            # Pending updates (not installed, not hidden)
            try {
                $searchResult = $searcher.Search("IsInstalled=0 AND IsHidden=0")
                $result.PendingCount = $searchResult.Updates.Count
                for ($i = 0; $i -lt $searchResult.Updates.Count; $i++) {
                    $update = $searchResult.Updates.Item($i)
                    $kbs = @()
                    for ($k = 0; $k -lt $update.KBArticleIDs.Count; $k++) {
                        $kbs += "KB$($update.KBArticleIDs.Item($k))"
                    }
                    $severity = $update.MsrcSeverity
                    if (-not $severity) { $severity = 'Unspecified' }
                    $result.PendingUpdates += @{
                        Title        = $update.Title
                        KBArticleIDs = ($kbs -join ', ')
                        IsDownloaded = [bool]$update.IsDownloaded
                        IsMandatory  = [bool]$update.IsMandatory
                        MsrcSeverity = $severity
                    }
                }
            }
            catch {
                $result.Error = "Pending search failed: $($_.Exception.Message)"
            }

            # Recent history (last 50)
            # Ref: IUpdateHistoryEntry - Operation: 1=Install, 2=Uninstall
            # Ref: OperationResultCode: 0=NotStarted, 1=InProgress, 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
            try {
                $totalHistory = $searcher.GetTotalHistoryCount()
                $result.TotalHistoryCount = $totalHistory
                if ($totalHistory -gt 0) {
                    $count = $totalHistory
                    if ($count -gt 50) { $count = 50 }
                    $history = $searcher.QueryHistory(0, $count)
                    for ($i = 0; $i -lt $history.Count; $i++) {
                        $entry = $history.Item($i)
                        $rc = switch ([int]$entry.ResultCode) {
                            0 { 'Not Started' }
                            1 { 'In Progress' }
                            2 { 'Succeeded' }
                            3 { 'Succeeded with Errors' }
                            4 { 'Failed' }
                            5 { 'Aborted' }
                            default { "Unknown ($([int]$entry.ResultCode))" }
                        }
                        $op = switch ([int]$entry.Operation) {
                            1 { 'Install' }
                            2 { 'Uninstall' }
                            default { "Unknown ($([int]$entry.Operation))" }
                        }
                        $dateStr = $null
                        if ($entry.Date) {
                            try { $dateStr = $entry.Date.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
                        }
                        $hresult = $null
                        if ($entry.HResult -and $entry.HResult -ne 0) {
                            $hresult = '0x{0:X8}' -f $entry.HResult
                        }
                        $result.RecentHistory += @{
                            Title     = $entry.Title
                            Date      = $dateStr
                            Operation = $op
                            Result    = $rc
                            HResult   = $hresult
                        }
                    }
                }
            }
            catch {
                if (-not $result.Error) {
                    $result.Error = "History query failed: $($_.Exception.Message)"
                }
            }
        }
        catch {
            $result.Error = $_.Exception.Message
        }

        return $result
    }

    try {
        if (-not [string]::IsNullOrEmpty($RemoteComputer)) {
            return Invoke-Command -ComputerName $RemoteComputer -ScriptBlock $wuaScript -ErrorAction Stop
        }
        else {
            return & $wuaScript
        }
    }
    catch {
        return @{
            ServiceStatus    = 'Unknown'
            ServiceStartType = 'Unknown'
            LastSearchSuccess  = $null
            LastInstallSuccess = $null
            PendingUpdates   = @()
            PendingCount     = 0
            RecentHistory    = @()
            TotalHistoryCount = 0
            Error            = $_.Exception.Message
        }
    }
}
#endregion Special Checks

#region Main Collection
Write-Host ""
Write-StatusMessage "Reading Windows Update registry configuration..." -Type Progress
Write-StatusMessage "Target: $(if ($isRemote) { $ComputerName } else { 'Local' })" -Type Info
Write-Host ""

$allResults = @{}
$hiveIndex = 0

foreach ($hive in $registryHives) {
    $hiveIndex++
    Write-StatusMessage "[$hiveIndex/$($registryHives.Count)] $($hive.Name)..." -Type Progress

    $remoteParam = if ($isRemote) { $ComputerName } else { $null }
    $hiveResult = Read-RegistryHive -HiveDef $hive -RemoteComputer $remoteParam
    $allResults[$hive.Name] = $hiveResult

    # Console summary for this hive
    if (-not $hiveResult.Exists) {
        Write-StatusMessage "  Not configured (key absent)" -Type Info
    }
    elseif ($hiveResult.Error) {
        Write-StatusMessage "  ERROR: $($hiveResult.Error)" -Type Error
    }
    else {
        $knownCount = @($hiveResult.Values.GetEnumerator() | Where-Object { $_.Value.Known }).Count
        $unknownCount = $hiveResult.UnknownKeys.Count
        Write-StatusMessage "  Found $knownCount known value(s), $unknownCount extra value(s)" -Type Success

        # Print each value
        foreach ($entry in ($hiveResult.Values.GetEnumerator() | Sort-Object Key)) {
            $decoded = Get-DecodedValue -KeyName $entry.Key -Value $entry.Value.Value
            $marker = if ($entry.Value.Known) { '' } else { ' [EXTRA]' }
            Write-StatusMessage "    $($entry.Key) = $($entry.Value.Value) ($decoded)$marker" -Type Info
        }
    }
    Write-Host ""
}

# Reboot check
Write-StatusMessage "Checking reboot indicators..." -Type Progress
$rebootStatus = Test-RebootRequired -RemoteComputer $(if ($isRemote) { $ComputerName } else { $null })

if ($rebootStatus.Indicators.Count -gt 0) {
    Write-StatusMessage "  REBOOT PENDING - $($rebootStatus.Indicators.Count) indicator(s) found" -Type Warning
    foreach ($indicator in $rebootStatus.Indicators) {
        Write-StatusMessage "    $indicator" -Type Warning
        Write-DeviceDNALog -Message "Reboot indicator: $indicator" -Component $component -Type 2
    }
}
else {
    Write-StatusMessage "  No reboot pending" -Type Success
    Write-DeviceDNALog -Message "No reboot indicators found" -Component $component -Type 1
}

# WUA COM API check
Write-Host ""
Write-StatusMessage "Querying Windows Update Agent (COM API)..." -Type Progress
Write-DeviceDNALog -Message "--- Querying WUA COM API ---" -Component $component -Type 1
$wuaStartTime = Get-Date

$wuaStatus = Get-WUAUpdateStatus -RemoteComputer $(if ($isRemote) { $ComputerName } else { $null })
$wuaDuration = (Get-Date) - $wuaStartTime

Write-DeviceDNALog -Message "  WUA query completed in $($wuaDuration.TotalSeconds.ToString('F1'))s" -Component $component -Type 1

if ($wuaStatus.Error) {
    Write-StatusMessage "  WUA Error: $($wuaStatus.Error)" -Type Warning
    Write-DeviceDNALog -Message "  WUA Error: $($wuaStatus.Error)" -Component $component -Type 2
}

# Service state
Write-StatusMessage "  Service: $($wuaStatus.ServiceStatus) (StartType: $($wuaStatus.ServiceStartType))" -Type Info
Write-DeviceDNALog -Message "  WU Service: $($wuaStatus.ServiceStatus) ($($wuaStatus.ServiceStartType))" -Component $component -Type 1

# Last scan/install from COM API
if ($wuaStatus.LastSearchSuccess) {
    Write-StatusMessage "  Last Scan (COM): $($wuaStatus.LastSearchSuccess)" -Type Info
    Write-DeviceDNALog -Message "  Last scan success (COM): $($wuaStatus.LastSearchSuccess)" -Component $component -Type 1
}
if ($wuaStatus.LastInstallSuccess) {
    Write-StatusMessage "  Last Install (COM): $($wuaStatus.LastInstallSuccess)" -Type Info
    Write-DeviceDNALog -Message "  Last install success (COM): $($wuaStatus.LastInstallSuccess)" -Component $component -Type 1
}

# Pending updates
if ($wuaStatus.PendingCount -gt 0) {
    Write-StatusMessage "  Pending Updates: $($wuaStatus.PendingCount)" -Type Warning
    Write-DeviceDNALog -Message "  Pending updates: $($wuaStatus.PendingCount)" -Component $component -Type 2
    foreach ($pending in $wuaStatus.PendingUpdates) {
        $dlStatus = if ($pending.IsDownloaded) { 'Downloaded' } else { 'Not downloaded' }
        Write-StatusMessage "    $($pending.Title) [$($pending.KBArticleIDs)] ($dlStatus, $($pending.MsrcSeverity))" -Type Info
        Write-DeviceDNALog -Message "    Pending: $($pending.Title) [$($pending.KBArticleIDs)] ($dlStatus, $($pending.MsrcSeverity))" -Component $component -Type 1
    }
}
else {
    Write-StatusMessage "  Pending Updates: None" -Type Success
    Write-DeviceDNALog -Message "  Pending updates: 0" -Component $component -Type 1
}

# Recent history summary
Write-StatusMessage "  Update History: $($wuaStatus.TotalHistoryCount) total entries (showing last $($wuaStatus.RecentHistory.Count))" -Type Info
Write-DeviceDNALog -Message "  History: $($wuaStatus.TotalHistoryCount) total, $($wuaStatus.RecentHistory.Count) retrieved" -Component $component -Type 1

# Count failures
$failedUpdates = @($wuaStatus.RecentHistory | Where-Object { $_.Result -eq 'Failed' })
if ($failedUpdates.Count -gt 0) {
    Write-StatusMessage "  Recent Failures: $($failedUpdates.Count)" -Type Warning
    Write-DeviceDNALog -Message "  Recent failures: $($failedUpdates.Count)" -Component $component -Type 2
    foreach ($fail in $failedUpdates) {
        Write-StatusMessage "    FAILED: $($fail.Title) ($($fail.Date)) $($fail.HResult)" -Type Warning
        Write-DeviceDNALog -Message "    FAILED: $($fail.Title) ($($fail.Date)) $($fail.HResult)" -Component $component -Type 2
    }
}
else {
    Write-StatusMessage "  Recent Failures: None" -Type Success
}

# Show last 5 history entries for quick reference
$recentCount = if ($wuaStatus.RecentHistory.Count -lt 5) { $wuaStatus.RecentHistory.Count } else { 5 }
if ($recentCount -gt 0) {
    Write-Host ""
    Write-StatusMessage "  Last $recentCount history entries:" -Type Info
    for ($i = 0; $i -lt $recentCount; $i++) {
        $h = $wuaStatus.RecentHistory[$i]
        $hResult = if ($h.HResult) { " $($h.HResult)" } else { '' }
        Write-StatusMessage "    [$($h.Result)] $($h.Date) - $($h.Operation): $($h.Title)$hResult" -Type Info
    }
}
#endregion Main Collection

#region Summary
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Configuration Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Derive high-level configuration picture
$wuPolicy = $allResults['WindowsUpdate Policy']
$auPolicy = $allResults['Automatic Updates (AU)']
$pauseState = $allResults['Update Policy State']
$uxSettings = $allResults['UX Settings (User Preferences)']
$osVersion = $allResults['OS Version']
$doPolicy = $allResults['Delivery Optimization']
$lastScan = $allResults['Last Scan Result']
$lastInstall = $allResults['Last Install Result']

# OS build
if ($osVersion -and $osVersion.Exists) {
    $product = if ($osVersion.Values.ContainsKey('ProductName')) { $osVersion.Values['ProductName'].Value } else { 'Windows' }
    $displayVer = if ($osVersion.Values.ContainsKey('DisplayVersion')) { " $($osVersion.Values['DisplayVersion'].Value)" } else { '' }
    $build = if ($osVersion.Values.ContainsKey('CurrentBuild')) { $osVersion.Values['CurrentBuild'].Value } else { '?' }
    $ubr = if ($osVersion.Values.ContainsKey('UBR')) { ".$($osVersion.Values['UBR'].Value)" } else { '' }
    $osStr = "$product$displayVer (Build $build$ubr)"
    Write-StatusMessage "OS: $osStr" -Type Info
    Write-DeviceDNALog -Message "OS: $osStr" -Component $component -Type 1
}

# Update source
$updateSource = 'Windows Update (default)'
if ($auPolicy.Exists -and $auPolicy.Values.ContainsKey('UseWUServer') -and $auPolicy.Values['UseWUServer'].Value -eq 1) {
    $wsusUrl = if ($wuPolicy.Values.ContainsKey('WUServer')) { $wuPolicy.Values['WUServer'].Value } else { '(URL not set)' }
    $updateSource = "WSUS: $wsusUrl"
}
Write-StatusMessage "Update Source: $updateSource" -Type Info
Write-DeviceDNALog -Message "Update source: $updateSource" -Component $component -Type 1

# WU Service state
$svcType = if ($wuaStatus.ServiceStatus -eq 'Running') { 'Success' } else { 'Warning' }
Write-StatusMessage "WU Service: $($wuaStatus.ServiceStatus) ($($wuaStatus.ServiceStartType))" -Type $svcType

# Auto-update mode
if ($auPolicy.Exists -and $auPolicy.Values.ContainsKey('NoAutoUpdate') -and $auPolicy.Values['NoAutoUpdate'].Value -eq 1) {
    Write-StatusMessage "Automatic Updates: DISABLED" -Type Warning
    Write-DeviceDNALog -Message "Automatic updates: DISABLED" -Component $component -Type 2
}
elseif ($auPolicy.Exists -and $auPolicy.Values.ContainsKey('AUOptions')) {
    $auMode = Get-DecodedValue -KeyName 'AUOptions' -Value $auPolicy.Values['AUOptions'].Value
    Write-StatusMessage "Automatic Updates: $auMode" -Type Info
    Write-DeviceDNALog -Message "AU mode: $auMode" -Component $component -Type 1
}
else {
    Write-StatusMessage "Automatic Updates: Default (not explicitly configured)" -Type Info
}

# Last scan / install timestamps
$scanTime = $null
if ($lastScan -and $lastScan.Exists -and $lastScan.Values.ContainsKey('LastSuccessTime')) {
    $scanTime = $lastScan.Values['LastSuccessTime'].Value
}
if (-not $scanTime -and $wuaStatus.LastSearchSuccess) {
    $scanTime = $wuaStatus.LastSearchSuccess
}
if ($scanTime) {
    Write-StatusMessage "Last Scan: $scanTime" -Type Info
    Write-DeviceDNALog -Message "Last scan: $scanTime" -Component $component -Type 1
}

$installTime = $null
if ($lastInstall -and $lastInstall.Exists -and $lastInstall.Values.ContainsKey('LastSuccessTime')) {
    $installTime = $lastInstall.Values['LastSuccessTime'].Value
}
if (-not $installTime -and $wuaStatus.LastInstallSuccess) {
    $installTime = $wuaStatus.LastInstallSuccess
}
if ($installTime) {
    Write-StatusMessage "Last Install: $installTime" -Type Info
    Write-DeviceDNALog -Message "Last install: $installTime" -Component $component -Type 1
}

# Pending updates
if ($wuaStatus.PendingCount -gt 0) {
    Write-StatusMessage "Pending Updates: $($wuaStatus.PendingCount)" -Type Warning
}
else {
    Write-StatusMessage "Pending Updates: 0" -Type Success
}

# Deferrals
if ($wuPolicy.Exists) {
    if ($wuPolicy.Values.ContainsKey('DeferFeatureUpdatesPeriodinDays')) {
        $days = $wuPolicy.Values['DeferFeatureUpdatesPeriodinDays'].Value
        Write-StatusMessage "Feature Update Deferral: $days day(s)" -Type Info
    }
    if ($wuPolicy.Values.ContainsKey('DeferQualityUpdatesPeriodinDays')) {
        $days = $wuPolicy.Values['DeferQualityUpdatesPeriodinDays'].Value
        Write-StatusMessage "Quality Update Deferral: $days day(s)" -Type Info
    }
}

# Pause status
if ($pauseState.Exists) {
    if ($pauseState.Values.ContainsKey('PausedFeatureStatus')) {
        $status = Get-DecodedValue -KeyName 'PausedFeatureStatus' -Value $pauseState.Values['PausedFeatureStatus'].Value
        $date = if ($pauseState.Values.ContainsKey('PausedFeatureDate')) { $pauseState.Values['PausedFeatureDate'].Value } else { 'N/A' }
        $pType = if ($pauseState.Values['PausedFeatureStatus'].Value -eq 1) { 'Warning' } else { 'Info' }
        Write-StatusMessage "Feature Updates Pause: $status (since $date)" -Type $pType
    }
    if ($pauseState.Values.ContainsKey('PausedQualityStatus')) {
        $status = Get-DecodedValue -KeyName 'PausedQualityStatus' -Value $pauseState.Values['PausedQualityStatus'].Value
        $date = if ($pauseState.Values.ContainsKey('PausedQualityDate')) { $pauseState.Values['PausedQualityDate'].Value } else { 'N/A' }
        $pType = if ($pauseState.Values['PausedQualityStatus'].Value -eq 1) { 'Warning' } else { 'Info' }
        Write-StatusMessage "Quality Updates Pause: $status (since $date)" -Type $pType
    }
}

# Drivers excluded
if ($wuPolicy.Exists -and $wuPolicy.Values.ContainsKey('ExcludeWUDriversInQualityUpdate') -and $wuPolicy.Values['ExcludeWUDriversInQualityUpdate'].Value -eq 1) {
    Write-StatusMessage "Driver Updates: EXCLUDED from quality updates" -Type Warning
}

# Delivery Optimization
if ($doPolicy -and $doPolicy.Exists) {
    if ($doPolicy.Values.ContainsKey('DODownloadMode')) {
        $doMode = Get-DecodedValue -KeyName 'DODownloadMode' -Value $doPolicy.Values['DODownloadMode'].Value
        Write-StatusMessage "Delivery Optimization: $doMode" -Type Info
        Write-DeviceDNALog -Message "DO mode: $doMode" -Component $component -Type 1
    }
}
else {
    Write-StatusMessage "Delivery Optimization: Not configured (default)" -Type Info
}

# Recent failures
if ($failedUpdates.Count -gt 0) {
    Write-StatusMessage "Recent Update Failures: $($failedUpdates.Count)" -Type Warning
}

# Reboot status
if ($rebootStatus.Indicators.Count -gt 0) {
    Write-StatusMessage "Reboot Status: PENDING ($($rebootStatus.Indicators.Count) indicator(s))" -Type Warning
}
else {
    Write-StatusMessage "Reboot Status: No reboot pending" -Type Success
}
#endregion Summary

#region Export JSON
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFileName = "WindowsUpdateConfig_${DeviceName}_${timestamp}.json"
$jsonPath = Join-Path $OutputPath $jsonFileName

# Flatten registry results for export
$exportHives = @{}
foreach ($hiveName in $allResults.Keys) {
    $hive = $allResults[$hiveName]
    $exportValues = @{}
    foreach ($entry in $hive.Values.GetEnumerator()) {
        $exportValues[$entry.Key] = @{
            Value   = $entry.Value.Value
            Meaning = $entry.Value.Meaning
            Known   = $entry.Value.Known
            Decoded = (Get-DecodedValue -KeyName $entry.Key -Value $entry.Value.Value)
        }
    }
    $exportHives[$hiveName] = @{
        Path         = $hive.Path
        Description  = $hive.Description
        Exists       = $hive.Exists
        Values       = $exportValues
        UnknownKeys  = $hive.UnknownKeys
        Error        = $hive.Error
    }
}

# Build OS version string for export
$osBuildString = $null
if ($osVersion -and $osVersion.Exists) {
    $product = if ($osVersion.Values.ContainsKey('ProductName')) { $osVersion.Values['ProductName'].Value } else { 'Windows' }
    $displayVer = if ($osVersion.Values.ContainsKey('DisplayVersion')) { " $($osVersion.Values['DisplayVersion'].Value)" } else { '' }
    $build = if ($osVersion.Values.ContainsKey('CurrentBuild')) { $osVersion.Values['CurrentBuild'].Value } else { '?' }
    $ubr = if ($osVersion.Values.ContainsKey('UBR')) { ".$($osVersion.Values['UBR'].Value)" } else { '' }
    $osBuildString = "$product$displayVer (Build $build$ubr)"
}

# Build WUA export data
$wuaExport = @{
    serviceStatus     = $wuaStatus.ServiceStatus
    serviceStartType  = $wuaStatus.ServiceStartType
    lastSearchSuccess = $wuaStatus.LastSearchSuccess
    lastInstallSuccess = $wuaStatus.LastInstallSuccess
    pendingCount      = $wuaStatus.PendingCount
    pendingUpdates    = $wuaStatus.PendingUpdates
    totalHistoryCount = $wuaStatus.TotalHistoryCount
    recentHistory     = $wuaStatus.RecentHistory
    failedCount       = $failedUpdates.Count
    error             = $wuaStatus.Error
    queryDuration     = $wuaDuration.TotalSeconds.ToString('F1') + 's'
}

$exportData = @{
    deviceName       = $DeviceName
    collectionTime   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    isRemote         = $isRemote
    osBuild          = $osBuildString
    updateSource     = $updateSource
    rebootPending    = ($rebootStatus.Indicators.Count -gt 0)
    rebootIndicators = $rebootStatus.Indicators
    registryHives    = $exportHives
    wuaStatus        = $wuaExport
    duration         = ((Get-Date) - $testStartTime).ToString('hh\:mm\:ss')
}

$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-Host ""
Write-StatusMessage "Results exported to: $jsonPath" -Type Success
Write-DeviceDNALog -Message "JSON results exported to: $jsonPath" -Component $component -Type 1
#endregion Export JSON

#region Cleanup
$duration = (Get-Date) - $testStartTime
Write-StatusMessage "Total duration: $($duration.ToString('hh\:mm\:ss'))" -Type Info

Complete-DeviceDNALog

Write-Host ""
Write-StatusMessage "Output files:" -Type Info
Write-StatusMessage "  Log:  $logPath" -Type Info
Write-StatusMessage "  JSON: $jsonPath" -Type Info
Write-Host ""
#endregion Cleanup
