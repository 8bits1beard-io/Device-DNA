<#
.SYNOPSIS
    Diagnostic test script for Intune compliance policy state collection.
.DESCRIPTION
    Standalone diagnostic tool that connects to Intune via Graph API, discovers which
    compliance policies are assigned to the current device, and tests multiple approaches
    for retrieving compliance state:

    Approach A: Current code — undocumented deviceCompliancePolicyStates endpoint
                (managedDevices/{id}/deviceCompliancePolicyStates), matched by displayName
                Also tests ID-based matching as alternative to displayName
    Approach B: Documented v1.0 — deviceCompliancePolicies/{id}/deviceStatuses
                Per-policy query with $filter by deviceDisplayName
    Approach C: Beta deviceStatuses (paginated) — per-policy, $top=999, stop on match
    Approach D: Per-setting state detail — deviceSettingStateSummaries
    Approach E: Per-setting device states — deviceComplianceSettingStates with $filter=deviceName
    Approach F: managedDevice.complianceState — overall device compliance (sanity check)

    Logs everything for review and exports a JSON diagnostic report.

    Reuses DeviceDNA module infrastructure (logging, Graph helpers, compliance collection)
    by dot-sourcing the required modules.
.PARAMETER OutputPath
    Directory for output files. Defaults to output/<DeviceName>/ under the repo root.
.PARAMETER DeviceName
    Override the device name. Defaults to $env:COMPUTERNAME.
.EXAMPLE
    .\tests\Test-CompliancePolicy.ps1
.EXAMPLE
    .\tests\Test-CompliancePolicy.ps1 -DeviceName "DESKTOP-ABC123" -OutputPath "C:\Temp"
.NOTES
    Requires: PowerShell 5.1+, Microsoft.Graph.Authentication module
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
#endregion Module Loading

#region Initialization
$testStartTime = Get-Date

if ([string]::IsNullOrEmpty($DeviceName)) {
    $DeviceName = $env:COMPUTERNAME
}

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $scriptRoot "output\$DeviceName"
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DeviceDNA - Compliance Policy Diagnostic" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName
if ($logPath) {
    Write-StatusMessage "Log file: $logPath" -Type Info
}

Write-DeviceDNALog -Message "=== Compliance Policy Diagnostic ===" -Component "Test-CompliancePolicy" -Type 1
Write-DeviceDNALog -Message "Device: $DeviceName" -Component "Test-CompliancePolicy" -Type 1
Write-DeviceDNALog -Message "Output: $OutputPath" -Component "Test-CompliancePolicy" -Type 1
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
    Complete-DeviceDNALog
    return
}

$tenantId = $null
if ($joinInfo.TenantId) {
    $tenantId = $joinInfo.TenantId
    Write-StatusMessage "Tenant ID: $tenantId" -Type Info
}
else {
    $tenantId = Get-TenantId -DsregOutput $joinInfo.RawOutput
    if ($tenantId) {
        Write-StatusMessage "Tenant ID from discovery: $tenantId" -Type Info
    }
}
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
    }
}

# Phase 3: Cross-reference
if ([string]::IsNullOrEmpty($resolvedIds.AzureADObjectId) -and
    -not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
    $recoveredDevice = Find-AzureADDevice -DeviceName $DeviceName -DeviceId $resolvedIds.HardwareDeviceId
    if ($recoveredDevice -and -not [string]::IsNullOrEmpty($recoveredDevice.ObjectId)) {
        $azureADDevice = $recoveredDevice
        $resolvedIds.AzureADObjectId = $recoveredDevice.ObjectId
    }
}

Write-Host ""
Write-StatusMessage "Identity Resolution Summary:" -Type Info
Write-StatusMessage "  Azure AD object ID: $(if ($resolvedIds.AzureADObjectId) { $resolvedIds.AzureADObjectId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.AzureADObjectId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Hardware device ID: $(if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.HardwareDeviceId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Intune device ID:   $(if ($resolvedIds.IntuneDeviceId) { $resolvedIds.IntuneDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.IntuneDeviceId) { 'Success' } else { 'Warning' })

Write-DeviceDNALog -Message "Resolved IDs - AzureADObjectId: $($resolvedIds.AzureADObjectId), HardwareDeviceId: $($resolvedIds.HardwareDeviceId), IntuneDeviceId: $($resolvedIds.IntuneDeviceId)" -Component "Test-CompliancePolicy" -Type 1

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

$deviceGroupIds = @($deviceGroups | ForEach-Object { $_.id })
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

#region Collect Compliance Policies
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Step 1: Collect Compliance Policies" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "Collecting all compliance policies from tenant..." -Type Progress
$allPolicies = Get-CompliancePolicies
Write-StatusMessage "Retrieved $($allPolicies.Count) compliance policies from tenant" -Type Info

# Evaluate targeting for each policy
$evaluateTargeting = {
    param($assignments, $deviceGroupIds)

    $targetingStatus = 'Not Targeted'
    $targetGroups = @()
    $assignmentFilter = $null

    foreach ($assignment in $assignments) {
        $targetType = $assignment.TargetType
        $groupId = $assignment.GroupId

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

    $matchedGroups = @($targetGroups | Where-Object { $_ -notlike 'Excluded:*' })
    if ($matchedGroups.Count -gt 0) {
        $targetingStatus = ($matchedGroups) -join ', '
    }

    return @{
        targetingStatus  = $targetingStatus
        targetGroups     = $targetGroups
        assignmentFilter = $assignmentFilter
    }
}

$targetedPolicies = @()
foreach ($policy in $allPolicies) {
    $targeting = & $evaluateTargeting $policy.Assignments $deviceGroupIds

    if ($targeting.targetingStatus -notin @('Not Targeted', 'Excluded')) {
        $targetedPolicies += @{
            id               = $policy.Id
            displayName      = $policy.DisplayName
            description      = $policy.Description
            platform         = $policy.Platform
            targetingStatus  = $targeting.targetingStatus
            targetGroups     = $targeting.targetGroups
            assignmentFilter = $targeting.assignmentFilter
        }
    }
}

Write-StatusMessage "Found $($targetedPolicies.Count) policies targeted to this device (out of $($allPolicies.Count) total)" -Type Success
Write-DeviceDNALog -Message "Targeted compliance policies: $($targetedPolicies.Count) out of $($allPolicies.Count) total" -Component "Test-CompliancePolicy" -Type 1

foreach ($p in $targetedPolicies) {
    Write-DeviceDNALog -Message "  Targeted: $($p.displayName) [$($p.platform)] via $($p.targetingStatus)" -Component "Test-CompliancePolicy" -Type 1
    Write-StatusMessage "  $($p.displayName) [$($p.platform)] via $($p.targetingStatus)" -Type Info
}
#endregion Collect Compliance Policies

#region Approach A: Current code — deviceCompliancePolicyStates (undocumented)
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  Approach A: deviceCompliancePolicyStates" -ForegroundColor Yellow
Write-Host "  (current code — undocumented beta endpoint)" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""

$approachA_Raw = @()
$approachA_Results = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceCompliancePolicyStates"
    Write-StatusMessage "GET $uri" -Type Progress
    Write-DeviceDNALog -Message "Approach A: GET $uri" -Component "Test-CompliancePolicy" -Type 1

    $queryStart = Get-Date
    $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
    $approachA_Raw = @($response.value)

    $pageCount = 1
    while ($response.'@odata.nextLink') {
        $pageCount++
        $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
        $approachA_Raw += $response.value
    }
    $queryDuration = (Get-Date) - $queryStart

    Write-StatusMessage "Returned $($approachA_Raw.Count) state(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Type Info
    Write-DeviceDNALog -Message "Approach A: $($approachA_Raw.Count) state(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Test-CompliancePolicy" -Type 1

    # Dump raw fields for each state
    foreach ($state in $approachA_Raw) {
        $stateFields = @{}
        foreach ($key in $state.Keys) {
            if ($key -ne 'settingStates') {
                $stateFields[$key] = $state[$key]
            }
        }
        Write-DeviceDNALog -Message "  Raw state: $($stateFields | ConvertTo-Json -Compress -Depth 2)" -Component "Test-CompliancePolicy" -Type 1
        Write-StatusMessage "  id=$($state.id)" -Type Info
        Write-StatusMessage "    displayName = '$($state.displayName)'" -Type Info
        Write-StatusMessage "    state       = '$($state.state)'" -Type Info
        Write-StatusMessage "    platformType= '$($state.platformType)'" -Type Info
        Write-StatusMessage "    version     = '$($state.version)'" -Type Info
        Write-StatusMessage "    settingCount= '$($state.settingCount)'" -Type Info

        # Dump settingStates
        $settingStates = @($state.settingStates)
        if ($settingStates.Count -gt 0) {
            Write-StatusMessage "    settingStates ($($settingStates.Count)):" -Type Info
            foreach ($ss in $settingStates) {
                Write-StatusMessage "      $($ss.settingName): state=$($ss.state), currentValue=$($ss.currentValue)" -Type Info
                Write-DeviceDNALog -Message "    settingState: $($ss | ConvertTo-Json -Compress -Depth 2)" -Component "Test-CompliancePolicy" -Type 1
            }
        }
        else {
            Write-StatusMessage "    settingStates: (empty)" -Type Warning
        }
    }

    # Try matching by displayName (current code logic)
    Write-Host ""
    Write-StatusMessage "Matching Approach A states to targeted policies by displayName..." -Type Progress
    foreach ($policy in $targetedPolicies) {
        $match = $approachA_Raw | Where-Object { $_.displayName -eq $policy.displayName } | Select-Object -First 1
        $matchState = if ($match) { $match.state } else { '(NO MATCH)' }
        $approachA_Results += @{
            policyId        = $policy.id
            displayName     = $policy.displayName
            platform        = $policy.platform
            matchedState    = $matchState
            matchedById     = if ($match) { $match.id } else { $null }
            matchedByName   = if ($match) { $match.displayName } else { $null }
        }

        $stateType = if ($match) { 'Success' } else { 'Error' }
        Write-StatusMessage "  $($policy.displayName) -> $matchState" -Type $stateType
        Write-DeviceDNALog -Message "  Match: '$($policy.displayName)' -> $matchState (matched=$([bool]$match))" -Component "Test-CompliancePolicy" -Type 1
    }

    # Also try matching by policy ID instead of displayName
    Write-Host ""
    Write-StatusMessage "Matching Approach A states to targeted policies by ID..." -Type Progress
    $approachA_IdResults = @()
    foreach ($policy in $targetedPolicies) {
        $match = $approachA_Raw | Where-Object { $_.id -eq $policy.id } | Select-Object -First 1
        $matchState = if ($match) { $match.state } else { '(NO MATCH)' }
        $approachA_IdResults += @{
            policyId      = $policy.id
            displayName   = $policy.displayName
            platform      = $policy.platform
            matchedState  = $matchState
            matchedById   = if ($match) { $match.id } else { $null }
            matchedByName = if ($match) { $match.displayName } else { $null }
        }

        $stateType = if ($match) { 'Success' } else { 'Error' }
        Write-StatusMessage "  $($policy.displayName) -> $matchState (by ID)" -Type $stateType
        Write-DeviceDNALog -Message "  ID Match: '$($policy.displayName)' id=$($policy.id) -> $matchState" -Component "Test-CompliancePolicy" -Type 1
    }

    # Check for states that didn't match any targeted policy
    foreach ($state in $approachA_Raw) {
        $policyMatch = $targetedPolicies | Where-Object { $_.displayName -eq $state.displayName }
        if (-not $policyMatch) {
            Write-StatusMessage "  ORPHAN state: '$($state.displayName)' state=$($state.state) (not in targeted policies)" -Type Warning
            Write-DeviceDNALog -Message "  Orphan state: '$($state.displayName)' -> $($state.state)" -Component "Test-CompliancePolicy" -Type 2
        }
    }
}
catch {
    Write-StatusMessage "Approach A FAILED: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "Approach A failed: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
}
#endregion Approach A

#region Approach B: Documented v1.0 — deviceStatuses per policy
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Approach B: Per-policy deviceStatuses" -ForegroundColor Green
Write-Host "  (documented v1.0 endpoint)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# Ref: https://learn.microsoft.com/graph/api/resources/intune-deviceconfig-devicecompliancedevicestatus
# GET /deviceManagement/deviceCompliancePolicies/{id}/deviceStatuses
# Returns: deviceComplianceDeviceStatus with: id, deviceDisplayName, status, lastReportedDateTime, userPrincipalName
$approachB_Results = @()

foreach ($policy in $targetedPolicies) {
    $policyId = $policy.id
    $policyName = $policy.displayName

    try {
        # Query device statuses for this policy, filter by device name
        # Ref: deviceComplianceDeviceStatus.deviceDisplayName contains the device name
        $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$policyId/deviceStatuses?`$filter=deviceDisplayName eq '$DeviceName'&`$top=10"
        Write-StatusMessage "  $policyName -> querying deviceStatuses..." -Type Progress
        Write-DeviceDNALog -Message "Approach B: GET $uri" -Component "Test-CompliancePolicy" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $statuses = @($response.value)
        $queryDuration = (Get-Date) - $queryStart

        if ($statuses.Count -gt 0) {
            $deviceStatus = $statuses[0]  # Take first match
            $approachB_Results += @{
                policyId              = $policyId
                displayName           = $policyName
                platform              = $policy.platform
                status                = $deviceStatus.status
                lastReportedDateTime  = $deviceStatus.lastReportedDateTime
                userPrincipalName     = $deviceStatus.userPrincipalName
                deviceDisplayName     = $deviceStatus.deviceDisplayName
                complianceGracePeriodExpirationDateTime = $deviceStatus.complianceGracePeriodExpirationDateTime
                statusId              = $deviceStatus.id
            }
            $statusType = if ($deviceStatus.status -eq 'compliant') { 'Success' }
                          elseif ($deviceStatus.status -eq 'nonCompliant' -or $deviceStatus.status -eq 'error') { 'Error' }
                          else { 'Info' }
            Write-StatusMessage "  $policyName -> $($deviceStatus.status) (in $($queryDuration.TotalMilliseconds.ToString('F0'))ms)" -Type $statusType
            Write-DeviceDNALog -Message "  Match: $policyName -> status=$($deviceStatus.status), lastReported=$($deviceStatus.lastReportedDateTime)" -Component "Test-CompliancePolicy" -Type 1
            Write-DeviceDNALog -Message "    Raw: $($deviceStatus | ConvertTo-Json -Compress -Depth 2)" -Component "Test-CompliancePolicy" -Type 1
        }
        else {
            $approachB_Results += @{
                policyId    = $policyId
                displayName = $policyName
                platform    = $policy.platform
                status      = '(no deviceStatus record)'
            }
            Write-StatusMessage "  $policyName -> no deviceStatus found (in $($queryDuration.TotalMilliseconds.ToString('F0'))ms)" -Type Warning
            Write-DeviceDNALog -Message "  No match: $policyName (0 statuses returned for device $DeviceName)" -Component "Test-CompliancePolicy" -Type 2
        }
    }
    catch {
        $approachB_Results += @{
            policyId    = $policyId
            displayName = $policyName
            platform    = $policy.platform
            status      = "ERROR: $($_.Exception.Message)"
        }
        Write-StatusMessage "  $policyName -> ERROR: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  Error: $policyName -> $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
    }
}
#endregion Approach B

#region Approach C: Per-policy deviceStatuses (beta, full pagination, stop on match)
Write-Host ""
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "  Approach C: Beta deviceStatuses (paginated)" -ForegroundColor Magenta
Write-Host "  (full pagination, $top=999, stop on match)" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host ""

# $filter returns NotImplemented, so paginate without filter using $top=999
# and search each page for our device. Stop as soon as found.
$approachC_Results = @()

foreach ($policy in $targetedPolicies) {
    $policyId = $policy.id
    $policyName = $policy.displayName

    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$policyId/deviceStatuses?`$top=999"
        Write-StatusMessage "  $policyName -> paginating deviceStatuses..." -Type Progress
        Write-DeviceDNALog -Message "Approach C: GET $uri (paginated, stop on match)" -Component "Test-CompliancePolicy" -Type 1

        $queryStart = Get-Date
        $deviceMatch = $null
        $pageCount = 0
        $totalScanned = 0

        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $pageCount++
        $pageResults = @($response.value)
        $totalScanned += $pageResults.Count

        # Search this page
        $deviceMatch = $pageResults | Where-Object { $_.deviceDisplayName -eq $DeviceName } | Select-Object -First 1

        # Keep paginating until found or no more pages
        while (-not $deviceMatch -and $response.'@odata.nextLink') {
            $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
            $pageCount++
            $pageResults = @($response.value)
            $totalScanned += $pageResults.Count
            $deviceMatch = $pageResults | Where-Object { $_.deviceDisplayName -eq $DeviceName } | Select-Object -First 1

            # Safety: stop after 20 pages (20,000 records)
            if ($pageCount -ge 20) {
                Write-DeviceDNALog -Message "  Stopping after $pageCount pages ($totalScanned records)" -Component "Test-CompliancePolicy" -Type 2
                break
            }
        }

        $queryDuration = (Get-Date) - $queryStart

        if ($deviceMatch) {
            $approachC_Results += @{
                policyId              = $policyId
                displayName           = $policyName
                platform              = $policy.platform
                status                = $deviceMatch.status
                lastReportedDateTime  = $deviceMatch.lastReportedDateTime
                userPrincipalName     = $deviceMatch.userPrincipalName
                deviceDisplayName     = $deviceMatch.deviceDisplayName
                pagesScanned          = $pageCount
                totalScanned          = $totalScanned
            }
            Write-StatusMessage "    FOUND on page $pageCount ($totalScanned scanned): status=$($deviceMatch.status) (in $([math]::Round($queryDuration.TotalSeconds, 1))s)" -Type Success
            Write-DeviceDNALog -Message "    Device found on page $pageCount ($totalScanned records scanned): $($deviceMatch | ConvertTo-Json -Compress -Depth 2)" -Component "Test-CompliancePolicy" -Type 1
        }
        else {
            $approachC_Results += @{
                policyId     = $policyId
                displayName  = $policyName
                platform     = $policy.platform
                status       = "(not found in $totalScanned records, $pageCount pages)"
                pagesScanned = $pageCount
                totalScanned = $totalScanned
            }
            Write-StatusMessage "    NOT found after $pageCount pages ($totalScanned records, $([math]::Round($queryDuration.TotalSeconds, 1))s)" -Type Warning
            Write-DeviceDNALog -Message "    Device not found after $pageCount pages ($totalScanned records)" -Component "Test-CompliancePolicy" -Type 2
        }
    }
    catch {
        $approachC_Results += @{
            policyId    = $policyId
            displayName = $policyName
            platform    = $policy.platform
            status      = "ERROR: $($_.Exception.Message)"
        }
        Write-StatusMessage "  $policyName -> ERROR: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  Error: $policyName -> $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
    }
}
#endregion Approach C

#region Approach D: Per-policy deviceSettingStateSummaries (setting-level detail)
Write-Host ""
Write-Host "=============================================" -ForegroundColor DarkCyan
Write-Host "  Approach D: Per-setting state detail" -ForegroundColor DarkCyan
Write-Host "  (deviceComplianceSettingStates)" -ForegroundColor DarkCyan
Write-Host "=============================================" -ForegroundColor DarkCyan
Write-Host ""

# If Approach B/C found a match, try to get per-setting detail for that policy.
# Ref: https://learn.microsoft.com/graph/api/resources/intune-deviceconfig-devicecompliancepolicysettingstate
# The setting states are on the deviceComplianceDeviceStatus -> settingStates relationship.
# Alternative: use deviceCompliancePolicies/{id}/deviceSettingStateSummaries for setting-level data.
$approachD_Results = @()

# Pick a policy that had a status from Approach B/C to test setting detail
$testPolicy = $approachB_Results | Where-Object { $_.status -and $_.status -notin @('(no deviceStatus record)', '') -and $_.status -notlike 'ERROR:*' } | Select-Object -First 1

if ($testPolicy) {
    $policyId = $testPolicy.policyId
    $policyName = $testPolicy.displayName

    Write-StatusMessage "Testing per-setting detail for: $policyName" -Type Progress

    # Try deviceSettingStateSummaries
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$policyId/deviceSettingStateSummaries"
        Write-StatusMessage "  GET deviceSettingStateSummaries..." -Type Progress
        Write-DeviceDNALog -Message "Approach D: GET $uri" -Component "Test-CompliancePolicy" -Type 1

        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $summaries = @($response.value)

        Write-StatusMessage "  Got $($summaries.Count) setting summaries" -Type Info
        foreach ($summary in $summaries) {
            Write-StatusMessage "    $($summary.settingName): compliant=$($summary.compliantDeviceCount), nonCompliant=$($summary.nonCompliantDeviceCount), error=$($summary.errorDeviceCount)" -Type Info
            Write-DeviceDNALog -Message "    Setting: $($summary | ConvertTo-Json -Compress -Depth 2)" -Component "Test-CompliancePolicy" -Type 1
            $approachD_Results += @{
                policyId    = $policyId
                policyName  = $policyName
                settingName = $summary.settingName
                setting     = $summary.setting
                compliant   = $summary.compliantDeviceCount
                nonCompliant = $summary.nonCompliantDeviceCount
                error       = $summary.errorDeviceCount
                unknown     = $summary.unknownDeviceCount
            }
        }
    }
    catch {
        Write-StatusMessage "  deviceSettingStateSummaries FAILED: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  deviceSettingStateSummaries failed: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
    }

    # Try the per-device setting states via deviceComplianceSettingStates
    # This is a separate endpoint that gives per-device, per-setting compliance state
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicySettingStateSummaries"
        Write-StatusMessage "  GET deviceCompliancePolicySettingStateSummaries (global)..." -Type Progress
        Write-DeviceDNALog -Message "Approach D (global): GET $uri" -Component "Test-CompliancePolicy" -Type 1

        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $globalSummaries = @($response.value)
        Write-StatusMessage "  Got $($globalSummaries.Count) global setting state summaries" -Type Info
        Write-DeviceDNALog -Message "  Global setting summaries: $($globalSummaries.Count)" -Component "Test-CompliancePolicy" -Type 1

        # Just log the first 5 for diagnostic
        $globalSummaries | Select-Object -First 5 | ForEach-Object {
            Write-DeviceDNALog -Message "    $($_.settingName) [$($_.platformType)]: compliant=$($_.compliantDeviceCount), nonCompliant=$($_.nonCompliantDeviceCount)" -Component "Test-CompliancePolicy" -Type 1
        }
    }
    catch {
        Write-StatusMessage "  Global setting summaries FAILED: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  Global setting summaries failed: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
    }
}
else {
    Write-StatusMessage "Skipping Approach D: no successful policy status from Approach B/C" -Type Warning
}
#endregion Approach D

#region Approach E: Per-setting deviceComplianceSettingStates with $filter
Write-Host ""
Write-Host "=============================================" -ForegroundColor Blue
Write-Host "  Approach E: Per-setting device states" -ForegroundColor Blue
Write-Host "  (deviceComplianceSettingStates + filter)" -ForegroundColor Blue
Write-Host "=============================================" -ForegroundColor Blue
Write-Host ""

# Ref: https://learn.microsoft.com/graph/api/intune-deviceconfig-devicecompliancesettingstate-list
# Path: deviceCompliancePolicies/{id}/deviceSettingStateSummaries/{id}/deviceComplianceSettingStates
# The deviceComplianceSettingState resource has: deviceName, deviceId, state, settingName
# Supports $filter on deviceName
$approachE_Results = @()

foreach ($policy in $targetedPolicies) {
    $policyId = $policy.id
    $policyName = $policy.displayName
    $settingStatesFound = @()

    try {
        # Step 1: Get setting summaries for this policy
        $summaryUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$policyId/deviceSettingStateSummaries"
        Write-StatusMessage "  $policyName -> getting setting summaries..." -Type Progress
        Write-DeviceDNALog -Message "Approach E: GET $summaryUri" -Component "Test-CompliancePolicy" -Type 1

        $queryStart = Get-Date
        $summaryResponse = Invoke-MgGraphRequest -Uri $summaryUri -Method GET -ErrorAction Stop
        $summaries = @($summaryResponse.value)
        Write-StatusMessage "    Found $($summaries.Count) setting summaries" -Type Info

        if ($summaries.Count -eq 0) {
            $approachE_Results += @{
                policyId       = $policyId
                displayName    = $policyName
                platform       = $policy.platform
                status         = '(no setting summaries)'
                settingCount   = 0
                settingDetails = @()
            }
            Write-StatusMessage "  $policyName -> no setting summaries found" -Type Warning
            continue
        }

        # Step 2: For each setting summary, query deviceComplianceSettingStates filtered by deviceName
        foreach ($summary in $summaries) {
            $summaryId = $summary.id
            $settingName = $summary.settingName
            $stateUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicySettingStateSummaries/$summaryId/deviceComplianceSettingStates?`$filter=deviceName eq '$DeviceName'&`$top=10"
            Write-DeviceDNALog -Message "  GET $stateUri" -Component "Test-CompliancePolicy" -Type 1

            try {
                $stateResponse = Invoke-MgGraphRequest -Uri $stateUri -Method GET -ErrorAction Stop
                $states = @($stateResponse.value)

                if ($states.Count -gt 0) {
                    $deviceState = $states[0]
                    $settingStatesFound += @{
                        settingName  = $settingName
                        state        = $deviceState.state
                        deviceId     = $deviceState.deviceId
                        deviceName   = $deviceState.deviceName
                        setting      = $deviceState.setting
                        userName     = $deviceState.userName
                        complianceGracePeriodExpirationDateTime = $deviceState.complianceGracePeriodExpirationDateTime
                    }
                    Write-StatusMessage "    $settingName -> $($deviceState.state)" -Type Info
                    Write-DeviceDNALog -Message "    Setting '$settingName' -> state=$($deviceState.state), deviceId=$($deviceState.deviceId)" -Component "Test-CompliancePolicy" -Type 1
                }
                else {
                    Write-DeviceDNALog -Message "    Setting '$settingName' -> no record for device $DeviceName" -Component "Test-CompliancePolicy" -Type 2
                }
            }
            catch {
                Write-DeviceDNALog -Message "    Setting '$settingName' -> ERROR: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
            }
        }

        $queryDuration = (Get-Date) - $queryStart

        # Aggregate: derive overall policy status from per-setting states
        if ($settingStatesFound.Count -gt 0) {
            $settingStateValues = @($settingStatesFound | ForEach-Object { $_.state })
            # If any nonCompliant -> nonCompliant; if any error -> error; if any unknown -> unknown; else compliant
            if ($settingStateValues -contains 'nonCompliant') { $overallStatus = 'nonCompliant' }
            elseif ($settingStateValues -contains 'error') { $overallStatus = 'error' }
            elseif ($settingStateValues -contains 'conflict') { $overallStatus = 'conflict' }
            elseif ($settingStateValues -contains 'unknown') { $overallStatus = 'unknown' }
            elseif ($settingStateValues -contains 'notApplicable') { $overallStatus = 'notApplicable' }
            else { $overallStatus = 'compliant' }

            $approachE_Results += @{
                policyId       = $policyId
                displayName    = $policyName
                platform       = $policy.platform
                status         = "$overallStatus ($($settingStatesFound.Count)/$($summaries.Count) settings)"
                settingCount   = $summaries.Count
                settingsFound  = $settingStatesFound.Count
                settingDetails = $settingStatesFound
            }
            $statusType = if ($overallStatus -eq 'compliant') { 'Success' }
                          elseif ($overallStatus -in @('nonCompliant', 'error')) { 'Error' }
                          else { 'Info' }
            Write-StatusMessage "  $policyName -> $overallStatus ($($settingStatesFound.Count)/$($summaries.Count) settings matched, $([math]::Round($queryDuration.TotalSeconds, 1))s)" -Type $statusType
        }
        else {
            $approachE_Results += @{
                policyId       = $policyId
                displayName    = $policyName
                platform       = $policy.platform
                status         = "(device not found in any of $($summaries.Count) settings)"
                settingCount   = $summaries.Count
                settingsFound  = 0
                settingDetails = @()
            }
            Write-StatusMessage "  $policyName -> device not found in any of $($summaries.Count) setting states ($([math]::Round($queryDuration.TotalSeconds, 1))s)" -Type Warning
        }
    }
    catch {
        $approachE_Results += @{
            policyId    = $policyId
            displayName = $policyName
            platform    = $policy.platform
            status      = "ERROR: $($_.Exception.Message)"
        }
        Write-StatusMessage "  $policyName -> ERROR: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  Error: $policyName -> $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
    }
}
#endregion Approach E

#region Approach F: managedDevice.complianceState (sanity check)
Write-Host ""
Write-Host "=============================================" -ForegroundColor White
Write-Host "  Approach F: managedDevice.complianceState" -ForegroundColor White
Write-Host "  (overall device compliance — sanity check)" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host ""

# Ref: https://learn.microsoft.com/graph/api/intune-devices-manageddevice-get
# The managedDevice resource has complianceState property: compliant, noncompliant, conflict, error, unknown, etc.
# This gives the OVERALL device compliance state, not per-policy. Useful as a sanity check.
$approachF_Results = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)?`$select=deviceName,complianceState,complianceGracePeriodExpirationDateTime,managedDeviceName,lastSyncDateTime"
    Write-StatusMessage "  GET managedDevice complianceState..." -Type Progress
    Write-DeviceDNALog -Message "Approach F: GET $uri" -Component "Test-CompliancePolicy" -Type 1

    $queryStart = Get-Date
    $device = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
    $queryDuration = (Get-Date) - $queryStart

    $overallState = $device.complianceState
    $gracePeriod = $device.complianceGracePeriodExpirationDateTime
    $lastSync = $device.lastSyncDateTime

    $approachF_Results += @{
        overallComplianceState = $overallState
        complianceGracePeriodExpirationDateTime = $gracePeriod
        lastSyncDateTime = $lastSync
        deviceName = $device.deviceName
    }

    $statusType = if ($overallState -eq 'compliant') { 'Success' }
                  elseif ($overallState -in @('noncompliant', 'error', 'conflict')) { 'Error' }
                  else { 'Warning' }
    Write-StatusMessage "  Overall compliance state: $overallState (in $($queryDuration.TotalMilliseconds.ToString('F0'))ms)" -Type $statusType
    Write-StatusMessage "  Grace period expiration:  $gracePeriod" -Type Info
    Write-StatusMessage "  Last sync:                $lastSync" -Type Info
    Write-DeviceDNALog -Message "  complianceState=$overallState, gracePeriod=$gracePeriod, lastSync=$lastSync" -Component "Test-CompliancePolicy" -Type 1
}
catch {
    Write-StatusMessage "Approach F FAILED: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "Approach F failed: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
}
#endregion Approach F

#region Approach G: Direct report POST — getDevicePoliciesComplianceReport
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Approach G: Direct Report POST" -ForegroundColor Green
Write-Host "  (getDevicePoliciesComplianceReport + filter)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# Captured from the Intune portal itself (F12 > Network tab on the compliance policy page)
# This is a SYNCHRONOUS POST — returns data inline, no export job needed.
# Ref: https://learn.microsoft.com/graph/api/intune-reporting-devicemanagementreports-getdevicepoliciescompliancereport
# POST body supports: filter, select, top, skip, orderBy, search, groupBy, sessionId
# Filter by DeviceId to get only this device's compliance data
$approachG_Results = @()
$approachG_Raw = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getDevicePoliciesComplianceReport"

    $reportBody = @{
        filter  = "(DeviceId eq '$($resolvedIds.IntuneDeviceId)')"
        select  = @("DeviceId", "PolicyId", "PolicyName", "PolicyPlatformType", "PolicyStatus", "PolicyVersion", "UPN", "UserName", "LastContact")
        top     = 50
        skip    = 0
    } | ConvertTo-Json

    Write-StatusMessage "  POST getDevicePoliciesComplianceReport (filter by DeviceId)..." -Type Progress
    Write-DeviceDNALog -Message "Approach G: POST $uri with filter=(DeviceId eq '$($resolvedIds.IntuneDeviceId)')" -Component "Test-CompliancePolicy" -Type 1

    $queryStart = Get-Date
    $response = Invoke-MgGraphRequest -Uri $uri -Method POST -Body $reportBody -ContentType "application/json" -ErrorAction Stop
    $queryDuration = (Get-Date) - $queryStart

    # The response has 'Schema' (column definitions) and 'Values' (rows as arrays)
    $columns = @($response.Schema | ForEach-Object { $_.Column })
    $rows = @($response.Values)

    Write-StatusMessage "  Got $($rows.Count) row(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms (columns: $($columns -join ', '))" -Type Info
    Write-DeviceDNALog -Message "  Response: $($rows.Count) rows, columns=$($columns -join ',')" -Component "Test-CompliancePolicy" -Type 1

    # Convert rows to objects using column names
    foreach ($row in $rows) {
        $rowObj = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            if ($i -lt $row.Count) {
                $rowObj[$columns[$i]] = $row[$i]
            }
        }
        $approachG_Raw += $rowObj

        Write-StatusMessage "  $($rowObj.PolicyName) [$($rowObj.PolicyPlatformType)] -> $($rowObj.PolicyStatus)" -Type Info
        Write-DeviceDNALog -Message "  Row: PolicyName=$($rowObj.PolicyName), PolicyStatus=$($rowObj.PolicyStatus), Platform=$($rowObj.PolicyPlatformType), PolicyId=$($rowObj.PolicyId)" -Component "Test-CompliancePolicy" -Type 1
    }

    # Match to targeted policies
    Write-Host ""
    Write-StatusMessage "Matching report data to targeted policies..." -Type Progress
    foreach ($policy in $targetedPolicies) {
        $match = $approachG_Raw | Where-Object { $_.PolicyId -eq $policy.id } | Select-Object -First 1
        if ($match) {
            $approachG_Results += @{
                policyId           = $policy.id
                displayName        = $policy.displayName
                platform           = $policy.platform
                status             = $match.PolicyStatus
                reportPolicyName   = $match.PolicyName
                reportPlatformType = $match.PolicyPlatformType
                policyVersion      = $match.PolicyVersion
                upn                = $match.UPN
                lastContact        = $match.LastContact
            }
            $statusType = if ($match.PolicyStatus -in @('Compliant', 'compliant')) { 'Success' }
                          elseif ($match.PolicyStatus -in @('NonCompliant', 'noncompliant', 'Error', 'error')) { 'Error' }
                          else { 'Info' }
            Write-StatusMessage "  $($policy.displayName) -> $($match.PolicyStatus)" -Type $statusType
        }
        else {
            $approachG_Results += @{
                policyId    = $policy.id
                displayName = $policy.displayName
                platform    = $policy.platform
                status      = '(not found in report)'
            }
            Write-StatusMessage "  $($policy.displayName) -> not found in report" -Type Warning
        }
    }
}
catch {
    Write-StatusMessage "Approach G FAILED: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "Approach G failed: $($_.Exception.Message)" -Component "Test-CompliancePolicy" -Type 3
}
#endregion Approach G

#region Results Comparison
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Results Comparison" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "Policy-by-policy comparison:" -Type Info
Write-Host ""

$comparisonTable = @()
foreach ($policy in $targetedPolicies) {
    $aResult = $approachA_Results | Where-Object { $_.policyId -eq $policy.id }
    $aIdResult = $approachA_IdResults | Where-Object { $_.policyId -eq $policy.id }
    $bResult = $approachB_Results | Where-Object { $_.policyId -eq $policy.id }
    $cResult = $approachC_Results | Where-Object { $_.policyId -eq $policy.id }
    $eResult = $approachE_Results | Where-Object { $_.policyId -eq $policy.id }
    $gResult = $approachG_Results | Where-Object { $_.policyId -eq $policy.id }

    $row = [PSCustomObject]@{
        'Policy'            = if ($policy.displayName.Length -gt 30) { $policy.displayName.Substring(0, 27) + '...' } else { $policy.displayName }
        'Platform'          = $policy.platform
        'A-Name'            = if ($aResult) { $aResult.matchedState } else { '(n/a)' }
        'A-ID'              = if ($aIdResult) { $aIdResult.matchedState } else { '(n/a)' }
        'B (v1.0+filter)'   = if ($bResult) { $bResult.status } else { '(n/a)' }
        'C (beta-paginate)' = if ($cResult) { $cResult.status } else { '(n/a)' }
        'E (settings)'      = if ($eResult) { $eResult.status } else { '(n/a)' }
        'G (report POST)'   = if ($gResult) { $gResult.status } else { '(n/a)' }
    }
    $comparisonTable += $row

    Write-DeviceDNALog -Message "Compare: $($policy.displayName) | A-Name=$($row.'A-Name') | A-ID=$($row.'A-ID') | B=$($row.'B (v1.0+filter)') | C=$($row.'C (beta-paginate)') | E=$($row.'E (settings)') | G=$($row.'G (report POST)')" -Component "Test-CompliancePolicy" -Type 1
}

$comparisonTable | Format-Table -AutoSize -Wrap

# Approach F sanity check (overall device state, not per-policy)
if ($approachF_Results.Count -gt 0) {
    Write-Host ""
    Write-StatusMessage "Overall device compliance (Approach F sanity check): $($approachF_Results[0].overallComplianceState)" -Type Info
}

# Summary
$aMatched = @($approachA_Results | Where-Object { $_.matchedState -and $_.matchedState -ne '(NO MATCH)' }).Count
$aIdMatched = @($approachA_IdResults | Where-Object { $_.matchedState -and $_.matchedState -ne '(NO MATCH)' }).Count
$bMatched = @($approachB_Results | Where-Object { $_.status -and $_.status -notin @('(no deviceStatus record)', '') -and $_.status -notlike 'ERROR:*' }).Count
$cMatched = @($approachC_Results | Where-Object { $_.status -and $_.status -notlike '(not found*' -and $_.status -notlike 'ERROR:*' }).Count
$eMatched = @($approachE_Results | Where-Object { $_.status -and $_.status -notlike '(no setting*' -and $_.status -notlike '(device not*' -and $_.status -notlike 'ERROR:*' }).Count
$gMatched = @($approachG_Results | Where-Object { $_.status -and $_.status -notin @('(not found in report)', '') -and $_.status -notlike 'ERROR:*' }).Count

Write-Host ""
Write-StatusMessage "Match rates:" -Type Info
Write-StatusMessage "  Approach A-Name (deviceCompliancePolicyStates + displayName):    $aMatched/$($targetedPolicies.Count)" -Type $(if ($aMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach A-ID   (deviceCompliancePolicyStates + policy ID):      $aIdMatched/$($targetedPolicies.Count)" -Type $(if ($aIdMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach B      (per-policy deviceStatuses v1.0 + filter):       $bMatched/$($targetedPolicies.Count)" -Type $(if ($bMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach C      (per-policy deviceStatuses beta paginated):      $cMatched/$($targetedPolicies.Count)" -Type $(if ($cMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach E      (per-setting deviceComplianceSettingStates):     $eMatched/$($targetedPolicies.Count)" -Type $(if ($eMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach G      (direct report POST + DeviceId filter):          $gMatched/$($targetedPolicies.Count)" -Type $(if ($gMatched -eq $targetedPolicies.Count) { 'Success' } else { 'Warning' })
#endregion Results Comparison

#region Export JSON
Write-Host ""
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFileName = "ComplianceDiag_${DeviceName}_${timestamp}.json"
$jsonPath = Join-Path $OutputPath $jsonFileName

$exportData = @{
    deviceName           = $DeviceName
    tenantId             = $tenantId
    resolvedIds          = $resolvedIds
    totalPoliciesInTenant = $allPolicies.Count
    targetedPolicyCount  = $targetedPolicies.Count
    targetedPolicies     = $targetedPolicies
    approachA            = @{
        description      = "deviceCompliancePolicyStates (undocumented beta, current code)"
        rawStates        = $approachA_Raw
        resultsByName    = $approachA_Results
        resultsByID      = $approachA_IdResults
        matchRateByName  = "$aMatched/$($targetedPolicies.Count)"
        matchRateByID    = "$aIdMatched/$($targetedPolicies.Count)"
    }
    approachB            = @{
        description = "Per-policy deviceStatuses (v1.0, filter by deviceDisplayName)"
        results     = $approachB_Results
        matchRate   = "$bMatched/$($targetedPolicies.Count)"
    }
    approachC            = @{
        description = "Per-policy deviceStatuses (beta, paginated $top=999, stop on match)"
        results     = $approachC_Results
        matchRate   = "$cMatched/$($targetedPolicies.Count)"
    }
    approachD            = @{
        description = "Per-setting state detail (deviceSettingStateSummaries)"
        results     = $approachD_Results
    }
    approachE            = @{
        description = "Per-setting deviceComplianceSettingStates (with deviceName filter)"
        results     = $approachE_Results
        matchRate   = "$eMatched/$($targetedPolicies.Count)"
    }
    approachF            = @{
        description = "managedDevice.complianceState (overall device compliance sanity check)"
        results     = $approachF_Results
    }
    approachG            = @{
        description = "Direct report POST (getDevicePoliciesComplianceReport + DeviceId filter)"
        results     = $approachG_Results
        rawRows     = $approachG_Raw
        matchRate   = "$gMatched/$($targetedPolicies.Count)"
    }
    collectionTime       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    duration             = ((Get-Date) - $testStartTime).ToString('hh\:mm\:ss')
}

$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-StatusMessage "Results exported to: $jsonPath" -Type Success
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
