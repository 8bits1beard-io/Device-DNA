<#
.SYNOPSIS
    Diagnostic test script for Intune app assignment and install status.
.DESCRIPTION
    Standalone diagnostic tool that connects to Intune via Graph API, discovers which
    applications are assigned to the current device, queries installation status for
    each via the local IME registry (HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps),
    and logs everything for review. Falls back to Graph API if local registry is unavailable.

    Reuses DeviceDNA module infrastructure (logging, Graph helpers, app collection)
    by dot-sourcing the required modules.
.PARAMETER OutputPath
    Directory for output files. Defaults to output/<DeviceName>/ under the repo root.
.PARAMETER DeviceName
    Override the device name. Defaults to $env:COMPUTERNAME.
.EXAMPLE
    .\tests\Test-AppInstallStatus.ps1
.EXAMPLE
    .\tests\Test-AppInstallStatus.ps1 -DeviceName "DESKTOP-ABC123" -OutputPath "C:\Temp\AppTest"
.NOTES
    Requires: PowerShell 5.1, Microsoft.Graph.Authentication module
    Must run on a Windows device that is Azure AD or Hybrid joined.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$DeviceName
)

#region Module Loading
$scriptRoot = Split-Path -Parent $PSScriptRoot  # repo root (tests/ -> repo root)

# Dot-source modules in dependency order
. (Join-Path $scriptRoot 'modules\Core.ps1')
. (Join-Path $scriptRoot 'modules\Logging.ps1')
. (Join-Path $scriptRoot 'modules\Helpers.ps1')
. (Join-Path $scriptRoot 'modules\DeviceInfo.ps1')
. (Join-Path $scriptRoot 'modules\Intune.ps1')
. (Join-Path $scriptRoot 'modules\LocalIntune.ps1')
#endregion Module Loading

#region Initialization
$testStartTime = Get-Date

# Resolve device name
if ([string]::IsNullOrEmpty($DeviceName)) {
    $DeviceName = $env:COMPUTERNAME
}

# Resolve output path
if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $scriptRoot "output\$DeviceName"
}

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DeviceDNA - App Install Status Diagnostic" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Initialize CMTrace logging
$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName
if ($logPath) {
    Write-StatusMessage "Log file: $logPath" -Type Info
}

Write-DeviceDNALog -Message "=== App Install Status Diagnostic ===" -Component "Test-AppInstallStatus" -Type 1
Write-DeviceDNALog -Message "Device: $DeviceName" -Component "Test-AppInstallStatus" -Type 1
Write-DeviceDNALog -Message "Output: $OutputPath" -Component "Test-AppInstallStatus" -Type 1
#endregion Initialization

#region Device Join Detection
Write-StatusMessage "Detecting device join type..." -Type Progress
$joinInfo = Get-DeviceJoinType

if ($joinInfo.AzureAdJoined) {
    if ($joinInfo.DomainJoined) {
        Write-StatusMessage "Device is Hybrid Azure AD Joined" -Type Success
    }
    else {
        Write-StatusMessage "Device is Azure AD Joined" -Type Success
    }
}
else {
    Write-StatusMessage "Device is NOT Azure AD joined - Graph API collection will not work" -Type Error
    Write-DeviceDNALog -Message "Device is not Azure AD joined. Cannot proceed." -Component "Test-AppInstallStatus" -Type 3
    Complete-DeviceDNALog
    return
}

# Get tenant ID
$tenantId = $null
if ($joinInfo.TenantId) {
    $tenantId = $joinInfo.TenantId
    Write-StatusMessage "Tenant ID from dsregcmd: $tenantId" -Type Info
}
else {
    $tenantId = Get-TenantId -DsregOutput $joinInfo.RawOutput
    if ($tenantId) {
        Write-StatusMessage "Tenant ID from discovery: $tenantId" -Type Info
    }
    else {
        Write-StatusMessage "Could not determine tenant ID" -Type Warning
    }
}
Write-DeviceDNALog -Message "Tenant ID: $tenantId" -Component "Test-AppInstallStatus" -Type 1
#endregion Device Join Detection

#region Graph API Connection
Write-Host ""
Write-StatusMessage "Connecting to Microsoft Graph..." -Type Progress
$connected = Connect-GraphAPI -TenantId $tenantId

if (-not $connected) {
    Write-StatusMessage "Failed to connect to Graph API. Cannot proceed." -Type Error
    Complete-DeviceDNALog
    return
}
#endregion Graph API Connection

#region Device Identity Resolution
# Replicates the 4-phase resolution from Get-IntuneData (Intune.ps1:1968-2116)
Write-Host ""
Write-StatusMessage "Resolving device identity..." -Type Progress

$azureADDevice = $null
$managedDevice = $null
$resolvedIds = @{
    AzureADObjectId  = $null
    HardwareDeviceId = $null
    IntuneDeviceId   = $null
}

# Phase 1: Azure AD lookup
Write-StatusMessage "  Phase 1: Querying Azure AD by device name..." -Type Info
$azureADDevice = Find-AzureADDevice -DeviceName $DeviceName

if ($azureADDevice) {
    Write-StatusMessage "  Found in Azure AD: $($azureADDevice.DisplayName)" -Type Success
    if (-not [string]::IsNullOrEmpty($azureADDevice.ObjectId)) {
        $resolvedIds.AzureADObjectId = $azureADDevice.ObjectId
    }
    if (-not [string]::IsNullOrEmpty($azureADDevice.DeviceId)) {
        $resolvedIds.HardwareDeviceId = $azureADDevice.DeviceId
    }
}
else {
    Write-StatusMessage "  Device not found in Azure AD" -Type Warning
}

# Phase 2: Intune lookup
Write-StatusMessage "  Phase 2: Querying Intune..." -Type Info
if (-not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
    $managedDevice = Get-IntuneDevice -AzureADDeviceId $resolvedIds.HardwareDeviceId
}
else {
    $managedDevice = Get-IntuneDevice -DeviceName $DeviceName
}

if ($managedDevice) {
    Write-StatusMessage "  Found in Intune: $($managedDevice.DeviceName)" -Type Success
    $resolvedIds.IntuneDeviceId = $managedDevice.Id

    if (-not [string]::IsNullOrEmpty($managedDevice.AzureADDeviceId) -and
        [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
        $resolvedIds.HardwareDeviceId = $managedDevice.AzureADDeviceId
        Write-StatusMessage "    Backfilled hardware device ID from Intune" -Type Success
    }
}
else {
    Write-StatusMessage "  Device not found in Intune" -Type Warning
}

# Phase 3: Cross-reference
if ([string]::IsNullOrEmpty($resolvedIds.AzureADObjectId) -and
    -not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
    Write-StatusMessage "  Phase 3: Recovering Azure AD object ID..." -Type Info
    $recoveredDevice = Find-AzureADDevice -DeviceName $DeviceName -DeviceId $resolvedIds.HardwareDeviceId
    if ($recoveredDevice -and -not [string]::IsNullOrEmpty($recoveredDevice.ObjectId)) {
        $azureADDevice = $recoveredDevice
        $resolvedIds.AzureADObjectId = $recoveredDevice.ObjectId
        Write-StatusMessage "    Recovered Azure AD object ID" -Type Success
    }
}

# Phase 4: Summary
Write-Host ""
Write-StatusMessage "Identity Resolution Summary:" -Type Info
Write-StatusMessage "  Azure AD object ID: $(if ($resolvedIds.AzureADObjectId) { $resolvedIds.AzureADObjectId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.AzureADObjectId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Hardware device ID: $(if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.HardwareDeviceId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Intune device ID:   $(if ($resolvedIds.IntuneDeviceId) { $resolvedIds.IntuneDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.IntuneDeviceId) { 'Success' } else { 'Warning' })

Write-DeviceDNALog -Message "Resolved IDs - AzureADObjectId: $($resolvedIds.AzureADObjectId), HardwareDeviceId: $($resolvedIds.HardwareDeviceId), IntuneDeviceId: $($resolvedIds.IntuneDeviceId)" -Component "Test-AppInstallStatus" -Type 1

if ([string]::IsNullOrEmpty($resolvedIds.IntuneDeviceId)) {
    Write-StatusMessage "Cannot proceed without Intune device ID" -Type Error
    Disconnect-GraphAPI
    Complete-DeviceDNALog
    return
}
#endregion Device Identity Resolution

#region Group Memberships
Write-Host ""
Write-StatusMessage "Getting device group memberships..." -Type Progress
$deviceGroups = @()

if (-not [string]::IsNullOrEmpty($resolvedIds.AzureADObjectId)) {
    $groupMemberships = Get-DeviceGroupMemberships -AzureADObjectId $resolvedIds.AzureADObjectId
    $deviceGroups = @($groupMemberships | ForEach-Object {
        @{
            id             = $_.ObjectId
            displayName    = $_.DisplayName
            description    = $_.Description
            groupType      = $_.GroupType
            membershipRule = $_.MembershipRule
        }
    })
    Write-StatusMessage "Device is a member of $($deviceGroups.Count) groups" -Type Info
}
else {
    Write-StatusMessage "Skipping group memberships: no Azure AD object ID" -Type Warning
}

$deviceGroupIds = @($deviceGroups | ForEach-Object { $_.id })
Write-DeviceDNALog -Message "Device group IDs: $($deviceGroupIds -join ', ')" -Component "Test-AppInstallStatus" -Type 1
#endregion Group Memberships

#region Assignment Filters
Write-Host ""
Write-StatusMessage "Collecting assignment filters..." -Type Progress
$assignmentFilters = @(Get-AssignmentFilters | ForEach-Object {
    @{
        id                             = $_.Id
        displayName                    = $_.DisplayName
        platform                       = $_.Platform
        rule                           = $_.Rule
        assignmentFilterManagementType = $_.AssignmentFilterManagementType
    }
})
Write-StatusMessage "Found $($assignmentFilters.Count) assignment filters" -Type Info
#endregion Assignment Filters

#region Collect Applications
Write-Host ""
Write-StatusMessage "Collecting all Intune applications..." -Type Progress
$allApps = Get-IntuneApplications
Write-StatusMessage "Retrieved $($allApps.Count) total applications from tenant" -Type Info
Write-DeviceDNALog -Message "Total apps retrieved: $($allApps.Count)" -Component "Test-AppInstallStatus" -Type 1
#endregion Collect Applications

#region Evaluate Targeting
Write-Host ""
Write-StatusMessage "Evaluating app targeting for this device..." -Type Progress

# Targeting evaluation scriptblock — adapted from Get-IntuneData (Intune.ps1:2170-2250)
# References $deviceGroups and $assignmentFilters from the outer scope
$evaluateTargeting = {
    param($assignments, $deviceGroupIds)

    $targetingStatus = 'Not Targeted'
    $targetGroups = @()
    $assignmentFilter = $null
    $intent = $null

    foreach ($assignment in $assignments) {
        $targetType = $assignment.TargetType
        $groupId = $assignment.GroupId

        # Check assignment filter
        if ($assignment.FilterId) {
            $filterMatch = $assignmentFilters | Where-Object { $_.id -eq $assignment.FilterId }
            if ($filterMatch) {
                $assignmentFilter = @{
                    id          = $filterMatch.id
                    displayName = $filterMatch.displayName
                    filterType  = $assignment.FilterType
                }
            }
        }

        # Get intent for apps
        if ($assignment.Intent) {
            $intent = $assignment.Intent
        }

        # Evaluate targeting based on TargetType
        switch -Wildcard ($targetType) {
            'All Devices' {
                $targetingStatus = 'All Devices'
                $targetGroups += 'All Devices'
            }
            'All Users' {
                $targetingStatus = 'All Users'
                $targetGroups += 'All Licensed Users'
            }
            'Group:*' {
                $groupName = ($deviceGroups | Where-Object { $_.id -eq $groupId }).displayName

                if ($groupId -in $deviceGroupIds) {
                    $targetingStatus = "Device Group: $groupName"
                    $targetGroups += "$groupName"
                }
            }
            'Exclude:*' {
                if ($groupId -in $deviceGroupIds) {
                    $targetingStatus = 'Excluded'
                    $groupName = ($deviceGroups | Where-Object { $_.id -eq $groupId }).displayName
                    $targetGroups += "Excluded: $groupName"
                }
            }
            'Exclude Group:*' {
                if ($groupId -in $deviceGroupIds) {
                    $targetingStatus = 'Excluded'
                    $groupName = ($deviceGroups | Where-Object { $_.id -eq $groupId }).displayName
                    $targetGroups += "Excluded: $groupName"
                }
            }
        }
    }

    # Build combined targeting status
    $matchedGroups = @($targetGroups | Where-Object { $_ -notlike 'Excluded:*' })
    if ($matchedGroups.Count -gt 0) {
        $targetingStatus = ($matchedGroups) -join ', '
    }

    return @{
        targetingStatus  = $targetingStatus
        targetGroups     = $targetGroups
        assignmentFilter = $assignmentFilter
        intent           = $intent
    }
}

# Filter to apps assigned to this device
$targetedApps = @()
foreach ($app in $allApps) {
    $targeting = & $evaluateTargeting $app.Assignments $deviceGroupIds

    if ($targeting.targetingStatus -notin @('Not Targeted', 'Excluded')) {
        $targetedApps += @{
            id               = $app.Id
            displayName      = $app.DisplayName
            appType          = $app.AppType
            publisher        = $app.Publisher
            version          = $app.Version
            targetingStatus  = $targeting.targetingStatus
            intent           = $targeting.intent
            targetGroups     = $targeting.targetGroups
            assignmentFilter = $targeting.assignmentFilter
            appInstallState    = $null
            installStateDetail = $null
            errorCode          = $null
            appVersion         = $null
        }
    }
}

Write-StatusMessage "Found $($targetedApps.Count) apps assigned to this device (out of $($allApps.Count) total)" -Type Success
Write-DeviceDNALog -Message "Targeted apps: $($targetedApps.Count) out of $($allApps.Count) total" -Component "Test-AppInstallStatus" -Type 1

foreach ($app in $targetedApps) {
    Write-DeviceDNALog -Message "  Targeted: $($app.displayName) [$($app.appType)] - $($app.intent) via $($app.targetingStatus)" -Component "Test-AppInstallStatus" -Type 1
}
#endregion Evaluate Targeting

#region Query Install Status via Local IME Registry
# Reads HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps directly on this device.
# The IME stores per-app install state keyed by Intune app ID — same IDs we have from targeting.
# Device-context apps are under the S-1-5-18 SID key.
# Each app subkey has ComplianceStateMessage (JSON) and EnforcementStateMessage (JSON) with:
#   InstallState, ComplianceState, ErrorCode, AppName, Intent, etc.
# This is instant (local registry read) vs the Graph API approaches that all failed or were slow.
Write-Host ""
if ($targetedApps.Count -gt 0) {
    Write-StatusMessage "Querying install status from local IME registry..." -Type Progress
    Write-DeviceDNALog -Message "Reading local IME registry for $($targetedApps.Count) targeted apps" -Component "Test-AppInstallStatus" -Type 1

    $queryStartAll = Get-Date

    # === Diagnostic: dump raw IME registry structure ===
    $imeRegPath = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"
    if (Test-Path $imeRegPath) {
        Write-DeviceDNALog -Message "IME registry path EXISTS: $imeRegPath" -Component "Test-AppInstallStatus" -Type 1

        $sidFolders = Get-ChildItem -Path $imeRegPath -ErrorAction SilentlyContinue
        Write-DeviceDNALog -Message "  SID folders found: $($sidFolders.Count)" -Component "Test-AppInstallStatus" -Type 1

        foreach ($sidFolder in $sidFolders) {
            $sid = $sidFolder.PSChildName
            $appSubkeys = Get-ChildItem -Path $sidFolder.PSPath -ErrorAction SilentlyContinue
            Write-DeviceDNALog -Message "  SID: $sid -> $($appSubkeys.Count) app subkey(s)" -Component "Test-AppInstallStatus" -Type 1

            # Log first 3 app IDs under this SID + dump sub-subkey content
            $dumpCount = 0
            $appSubkeys | Select-Object -First 3 | ForEach-Object {
                $dumpCount++
                $appId = $_.PSChildName
                $appProps = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                $propNames = if ($appProps) {
                    ($appProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $_.Name }) -join ', '
                } else { '(no properties)' }
                Write-DeviceDNALog -Message "    AppId: $appId -> Props: $propNames" -Component "Test-AppInstallStatus" -Type 1

                # Dump sub-subkey contents for first app only (per SID)
                if ($dumpCount -eq 1) {
                    $subKeys = Get-ChildItem -Path $_.PSPath -ErrorAction SilentlyContinue
                    foreach ($sk in $subKeys) {
                        $skName = $sk.PSChildName
                        $skProps = Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue
                        if ($skProps) {
                            $skProps.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                                $valPreview = if ($_.Value -is [string] -and $_.Value.Length -gt 200) {
                                    $_.Value.Substring(0, 200) + '...'
                                } else { $_.Value }
                                Write-DeviceDNALog -Message "      SubKey[$skName].$($_.Name) = $valPreview" -Component "Test-AppInstallStatus" -Type 1
                            }
                        }
                    }
                }
            }
            if ($appSubkeys.Count -gt 3) {
                Write-DeviceDNALog -Message "    ... and $($appSubkeys.Count - 3) more" -Component "Test-AppInstallStatus" -Type 1
            }
        }
    }
    else {
        Write-DeviceDNALog -Message "IME registry path NOT FOUND: $imeRegPath" -Component "Test-AppInstallStatus" -Type 3
    }
    Write-DeviceDNALog -Message "=== End diagnostic dump ===" -Component "Test-AppInstallStatus" -Type 1

    # Direct registry read — bypasses Get-LocalIntuneApplications because:
    # 1. Registry app IDs have _N suffix (e.g., {guid}_2) that prevents matching
    # 2. ComplianceStateMessage/EnforcementStateMessage are absent on this device
    # 3. Device context folder is 00000000-0000-0000-0000-000000000000, not S-1-5-18
    # We read all SID folders, strip _N suffix for matching, and capture all available properties.

    $localAppMap = @{}  # Map of clean appId -> hashtable of properties
    $sidFolders = Get-ChildItem -Path $imeRegPath -ErrorAction SilentlyContinue
    foreach ($sidFolder in $sidFolders) {
        $sid = $sidFolder.PSChildName
        # Skip non-app folders
        if ($sid -eq 'OperationalState' -or $sid -eq 'Reporting') { continue }

        $context = if ($sid -eq '00000000-0000-0000-0000-000000000000' -or $sid -eq 'S-1-5-18') { 'Device' } else { 'User' }
        $appSubkeys = Get-ChildItem -Path $sidFolder.PSPath -ErrorAction SilentlyContinue

        foreach ($appSubkey in $appSubkeys) {
            $rawId = $appSubkey.PSChildName
            # Strip _N suffix to get clean app GUID (e.g., "21e67fea-..._2" -> "21e67fea-...")
            $cleanId = $rawId -replace '_\d+$', ''
            # Skip non-GUID entries like "GRS"
            if ($cleanId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { continue }

            $appProps = Get-ItemProperty -Path $appSubkey.PSPath -ErrorAction SilentlyContinue
            if (-not $appProps) { continue }

            # Build a record with all available properties
            $record = @{
                RawId          = $rawId
                CleanId        = $cleanId
                Context        = $context
                SID            = $sid
                Intent         = $appProps.Intent
                RebootStatus   = $appProps.RebootStatus
                LastUpdated    = $appProps.LastUpdatedTimeUtc
            }

            # ComplianceStateMessage and EnforcementStateMessage can be either:
            # (a) Properties on the parent key, or
            # (b) Sub-subkeys containing a property of the same name (observed on this device)
            # Try both approaches.

            # Approach (a): Direct properties on parent key
            if ($appProps.ComplianceStateMessage) {
                try {
                    $csm = $appProps.ComplianceStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($csm) {
                        $record.ComplianceState = $csm.ComplianceState
                        $record.Applicability = $csm.Applicability
                        $record.ErrorCode = $csm.ErrorCode
                    }
                } catch {}
            }
            if ($appProps.EnforcementStateMessage) {
                try {
                    $esm = $appProps.EnforcementStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($esm) {
                        $record.EnforcementState = $esm.EnforcementState
                        if (-not $record.ErrorCode -and $esm.ErrorCode) { $record.ErrorCode = $esm.ErrorCode }
                    }
                } catch {}
            }

            # Approach (b): Sub-subkeys — read ComplianceStateMessage and EnforcementStateMessage
            # as child registry keys, each containing a property of the same name with JSON data
            $subSubkeys = Get-ChildItem -Path $appSubkey.PSPath -ErrorAction SilentlyContinue
            if ($subSubkeys) {
                $record.SubKeyNames = ($subSubkeys | ForEach-Object { $_.PSChildName }) -join ', '

                # Read ComplianceStateMessage sub-subkey
                if (-not $record.ComplianceState) {
                    $csmKeyPath = Join-Path $appSubkey.PSPath 'ComplianceStateMessage'
                    if (Test-Path $csmKeyPath) {
                        $csmProps = Get-ItemProperty -Path $csmKeyPath -ErrorAction SilentlyContinue
                        if ($csmProps) {
                            $csmJson = $csmProps.ComplianceStateMessage
                            if ($csmJson) {
                                try {
                                    $csm = $csmJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($csm) {
                                        $record.ComplianceState = $csm.ComplianceState
                                        $record.Applicability = $csm.Applicability
                                        $record.ErrorCode = $csm.ErrorCode
                                    }
                                } catch {}
                            }
                        }
                    }
                }

                # Read EnforcementStateMessage sub-subkey
                if (-not $record.EnforcementState) {
                    $esmKeyPath = Join-Path $appSubkey.PSPath 'EnforcementStateMessage'
                    if (Test-Path $esmKeyPath) {
                        $esmProps = Get-ItemProperty -Path $esmKeyPath -ErrorAction SilentlyContinue
                        if ($esmProps) {
                            $esmJson = $esmProps.EnforcementStateMessage
                            if ($esmJson) {
                                try {
                                    $esm = $esmJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($esm) {
                                        $record.EnforcementState = $esm.EnforcementState
                                        if (-not $record.ErrorCode -and $esm.ErrorCode) {
                                            $record.ErrorCode = $esm.ErrorCode
                                        }
                                    }
                                } catch {}
                            }
                        }
                    }
                }
            }

            # Only store if we don't already have this cleanId, or prefer device context over user
            if (-not $localAppMap.ContainsKey($cleanId) -or $context -eq 'Device') {
                $localAppMap[$cleanId] = $record
            }
        }
    }

    $queryMs = ((Get-Date) - $queryStartAll).TotalMilliseconds
    Write-DeviceDNALog -Message "Direct registry scan: $($localAppMap.Count) unique app(s) in $($queryMs.ToString('F0'))ms" -Component "Test-AppInstallStatus" -Type 1

    # Match targeted apps to registry data
    $matchCount = 0
    $appIndex = 0
    foreach ($app in $targetedApps) {
        $appIndex++
        $appId = $app.id
        $appName = $app.displayName

        $regData = $localAppMap[$appId]

        if ($regData) {
            $matchCount++
            # Map IME Intent numeric codes
            $intentName = switch ($regData.Intent) {
                1 { 'Available' }
                3 { 'Required' }
                4 { 'Uninstall' }
                default { "$($regData.Intent)" }
            }

            # Determine install state from EnforcementState (primary) or ComplianceState (fallback)
            # EnforcementState codes (from IME source): 1000=Success, 2000=InProgress, 3000=ReqNotMet, 4000+=Failed
            # ComplianceState codes: 1=Compliant(Installed), 2=NotCompliant(NotInstalled), 3=Conflict, 4=Error, 5=NotEvaluated
            $installState = $null
            if ($regData.EnforcementState) {
                $esCode = [int]$regData.EnforcementState
                $installState = switch ($true) {
                    ($esCode -eq 1000) { 'Installed' }
                    ($esCode -ge 2000 -and $esCode -lt 3000) { 'In Progress' }
                    ($esCode -ge 3000 -and $esCode -lt 4000) { 'Requirements Not Met' }
                    ($esCode -ge 4000 -and $esCode -lt 5000) { 'Failed' }
                    ($esCode -ge 5000) { 'Failed' }
                    default { "Enforcement:$esCode" }
                }
            }
            if (-not $installState -and $null -ne $regData.ComplianceState) {
                $installState = switch ([int]$regData.ComplianceState) {
                    1 { 'Installed' }
                    2 { 'Not Installed' }
                    3 { 'Conflict' }
                    4 { 'Error' }
                    5 { 'Not Evaluated' }
                    default { "Compliance:$($regData.ComplianceState)" }
                }
            }
            if (-not $installState) { $installState = 'Unknown' }

            $app.appInstallState = $installState
            $app.installStateDetail = "Compliance=$($regData.ComplianceState), Enforcement=$($regData.EnforcementState)"
            $app.errorCode = $regData.ErrorCode

            $propsStr = "context=$($regData.Context), intent=$intentName, state=$installState"
            if ($regData.EnforcementState) { $propsStr += ", enforcement=$($regData.EnforcementState)" }
            if ($regData.ComplianceState) { $propsStr += ", compliance=$($regData.ComplianceState)" }
            if ($regData.ErrorCode -and $regData.ErrorCode -ne 0) { $propsStr += ", error=$($regData.ErrorCode)" }
            if ($regData.LastUpdated) { $propsStr += ", lastUpdated=$($regData.LastUpdated)" }

            $stateType = if ($installState -eq 'Installed') { 'Success' }
                         elseif ($installState -in @('Failed', 'Error', 'Conflict')) { 'Error' }
                         elseif ($installState -eq 'In Progress') { 'Warning' }
                         else { 'Info' }

            Write-DeviceDNALog -Message "  [$appIndex/$($targetedApps.Count)] $appName`: $propsStr" -Component "Test-AppInstallStatus" -Type 1
            Write-StatusMessage "  [$appIndex/$($targetedApps.Count)] $appName -> $installState ($($regData.Context))" -Type $stateType
        }
        else {
            Write-DeviceDNALog -Message "  [$appIndex/$($targetedApps.Count)] $appName`: NOT in IME registry (appId=$appId)" -Component "Test-AppInstallStatus" -Type 2
            Write-StatusMessage "  [$appIndex/$($targetedApps.Count)] $appName -> (not in IME registry)" -Type Warning
        }
    }

    $totalQueryTime = ((Get-Date) - $queryStartAll).TotalSeconds
    Write-Host ""
    Write-StatusMessage "Install status results: $matchCount/$($targetedApps.Count) matched from local registry ($($totalQueryTime.ToString('F1'))s)" -Type Info
    Write-DeviceDNALog -Message "Install status complete: $matchCount/$($targetedApps.Count) matched from local IME registry in $($totalQueryTime.ToString('F1'))s" -Component "Test-AppInstallStatus" -Type 1
}
else {
    Write-StatusMessage "No targeted apps found - nothing to query" -Type Warning
}
#endregion Query Install Status via Local IME Registry

#region Results Summary
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Results Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

if ($targetedApps.Count -gt 0) {
    # Display formatted table
    $tableData = @($targetedApps | ForEach-Object {
        $detailStr = ''
        if ($_.installStateDetail -and $_.installStateDetail -ne 'noAdditionalDetails') {
            $detailStr = $_.installStateDetail
        }
        [PSCustomObject]@{
            'App Name'       = if ($_.displayName.Length -gt 40) { $_.displayName.Substring(0, 37) + '...' } else { $_.displayName }
            'Type'           = $_.appType
            'Intent'         = $_.intent
            'Install State'  = if ($_.appInstallState) { $_.appInstallState } else { '(no data)' }
            'Detail'         = $detailStr
            'Error'          = if ($_.errorCode -and $_.errorCode -ne 0) { "0x{0:X8}" -f $_.errorCode } else { '' }
            'Version'        = if ($_.appVersion) { $_.appVersion } else { '' }
        }
    })

    $tableData | Format-Table -AutoSize -Wrap

    # Show install state breakdown
    $installed = @($targetedApps | Where-Object { $_.appInstallState -eq 'Installed' }).Count
    $notInstalled = @($targetedApps | Where-Object { $_.appInstallState -eq 'Not Installed' }).Count
    $inProgress = @($targetedApps | Where-Object { $_.appInstallState -eq 'In Progress' }).Count
    $failed = @($targetedApps | Where-Object { $_.appInstallState -in @('Failed', 'Error', 'Conflict') }).Count
    $reqNotMet = @($targetedApps | Where-Object { $_.appInstallState -eq 'Requirements Not Met' }).Count
    $unknown = @($targetedApps | Where-Object { $_.appInstallState -in @('Unknown', 'Not Evaluated') -or -not $_.appInstallState }).Count

    Write-Host ""
    Write-StatusMessage "Breakdown: $installed installed, $notInstalled not installed, $inProgress in progress, $failed failed, $reqNotMet req not met, $unknown unknown" -Type Info
}
else {
    Write-StatusMessage "No apps are targeted to this device" -Type Warning
}
#endregion Results Summary

#region Export JSON
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFileName = "AppInstallStatus_${DeviceName}_${timestamp}.json"
$jsonPath = Join-Path $OutputPath $jsonFileName

$exportData = @{
    deviceName       = $DeviceName
    tenantId         = $tenantId
    resolvedIds      = $resolvedIds
    deviceGroups     = $deviceGroups
    totalAppsInTenant = $allApps.Count
    targetedAppCount = $targetedApps.Count
    applications     = $targetedApps
    collectionTime   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    duration         = ((Get-Date) - $testStartTime).ToString('hh\:mm\:ss')
}

$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-StatusMessage "Results exported to: $jsonPath" -Type Success
Write-DeviceDNALog -Message "JSON results exported to: $jsonPath" -Component "Test-AppInstallStatus" -Type 1
#endregion Export JSON

#region Cleanup
Write-Host ""
$duration = (Get-Date) - $testStartTime
Write-StatusMessage "Total duration: $($duration.ToString('hh\:mm\:ss'))" -Type Info

Disconnect-GraphAPI
Complete-DeviceDNALog

Write-Host ""
Write-StatusMessage "Output files:" -Type Info
Write-StatusMessage "  Log:  $logPath" -Type Info
Write-StatusMessage "  JSON: $jsonPath" -Type Info
Write-Host ""
#endregion Cleanup
