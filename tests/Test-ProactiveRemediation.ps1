<#
.SYNOPSIS
    Diagnostic test script for Intune proactive remediation (health script) state collection.
.DESCRIPTION
    Compares two approaches for retrieving per-device proactive remediation run states:

    Approach A: Current code — per-script deviceRunStates with $filter
               GET deviceHealthScripts/{id}/deviceRunStates?$filter=managedDevice/id eq '{deviceId}'
               Requires N API calls (one per targeted script)
    Approach B: Portal approach — single deviceHealthScriptStates call
               GET managedDevices/{id}/deviceHealthScriptStates
               Single API call returns all script states for the device

    Logs everything for review and exports a JSON diagnostic report.
.PARAMETER OutputPath
    Directory for output files. Defaults to output/<DeviceName>/ under the repo root.
.PARAMETER DeviceName
    Override the device name. Defaults to $env:COMPUTERNAME.
.EXAMPLE
    .\tests\Test-ProactiveRemediation.ps1
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
Write-Host "  DeviceDNA - Proactive Remediation Diagnostic" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName
if ($logPath) {
    Write-StatusMessage "Log file: $logPath" -Type Info
}

Write-DeviceDNALog -Message "=== Proactive Remediation Diagnostic ===" -Component "Test-ProactiveRemediation" -Type 1
Write-DeviceDNALog -Message "Device: $DeviceName" -Component "Test-ProactiveRemediation" -Type 1
Write-DeviceDNALog -Message "Output: $OutputPath" -Component "Test-ProactiveRemediation" -Type 1
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

Write-Host ""
Write-StatusMessage "Identity Resolution Summary:" -Type Info
Write-StatusMessage "  Azure AD object ID: $(if ($resolvedIds.AzureADObjectId) { $resolvedIds.AzureADObjectId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.AzureADObjectId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Hardware device ID: $(if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.HardwareDeviceId) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Intune device ID:   $(if ($resolvedIds.IntuneDeviceId) { $resolvedIds.IntuneDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.IntuneDeviceId) { 'Success' } else { 'Warning' })

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

#region Step 1: Collect all health scripts + targeting
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Step 1: Collect Health Scripts + Targeting" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "Collecting all proactive remediations from tenant..." -Type Progress
$allRemediations = Get-ProactiveRemediations
Write-StatusMessage "Retrieved $($allRemediations.Count) health scripts from tenant" -Type Info

# Evaluate targeting
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

$targetedRemediations = @()
foreach ($remediation in $allRemediations) {
    $targeting = & $evaluateTargeting $remediation.Assignments $deviceGroupIds

    if ($targeting.targetingStatus -notin @('Not Targeted', 'Excluded')) {
        $targetedRemediations += @{
            id              = $remediation.Id
            displayName     = $remediation.DisplayName
            description     = $remediation.Description
            publisher       = $remediation.Publisher
            runAsAccount    = $remediation.RunAsAccount
            targetingStatus = $targeting.targetingStatus
            targetGroups    = $targeting.targetGroups
        }
    }
}

Write-StatusMessage "Found $($targetedRemediations.Count) remediations targeted to this device (out of $($allRemediations.Count) total)" -Type Success

foreach ($r in $targetedRemediations) {
    Write-StatusMessage "  $($r.displayName) via $($r.targetingStatus)" -Type Info
    Write-DeviceDNALog -Message "  Targeted: $($r.displayName) [$($r.id)] via $($r.targetingStatus)" -Component "Test-ProactiveRemediation" -Type 1
}
#endregion Step 1

#region Approach A: Current code — per-script deviceRunStates with $filter
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  Approach A: Per-script deviceRunStates" -ForegroundColor Yellow
Write-Host "  (current code — N API calls with `$filter)" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""

# Current code: for each targeted script, query deviceRunStates filtered by managedDevice/id
# Ref: GET /beta/deviceManagement/deviceHealthScripts/{id}/deviceRunStates?$filter=managedDevice/id eq '{deviceId}'
$approachA_Results = @()
$approachA_ApiCalls = 0
$approachA_Start = Get-Date

foreach ($remediation in $targetedRemediations) {
    $scriptId = $remediation.id
    $scriptName = $remediation.displayName

    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$scriptId/deviceRunStates?`$filter=managedDevice/id eq '$($resolvedIds.IntuneDeviceId)'"
        Write-StatusMessage "  $scriptName -> querying deviceRunStates..." -Type Progress
        Write-DeviceDNALog -Message "Approach A: GET $uri" -Component "Test-ProactiveRemediation" -Type 1
        $approachA_ApiCalls++

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $runStates = @($response.value)
        $queryDuration = (Get-Date) - $queryStart

        if ($runStates.Count -gt 0) {
            $runState = $runStates[0]
            $approachA_Results += @{
                scriptId          = $scriptId
                displayName       = $scriptName
                detectionState    = $runState.detectionState
                remediationState  = $runState.remediationState
                lastStateUpdateDateTime = $runState.lastStateUpdateDateTime
                preRemediationDetectionScriptOutput  = $runState.preRemediationDetectionScriptOutput
                postRemediationDetectionScriptOutput = $runState.postRemediationDetectionScriptOutput
                remediationScriptError               = $runState.remediationScriptError
                queryMs           = [math]::Round($queryDuration.TotalMilliseconds)
            }
            Write-StatusMessage "  $scriptName -> detection=$($runState.detectionState), remediation=$($runState.remediationState) ($($queryDuration.TotalMilliseconds.ToString('F0'))ms)" -Type Success
            Write-DeviceDNALog -Message "  Match: $scriptName -> detection=$($runState.detectionState), remediation=$($runState.remediationState)" -Component "Test-ProactiveRemediation" -Type 1
        }
        else {
            $approachA_Results += @{
                scriptId    = $scriptId
                displayName = $scriptName
                detectionState = '(no run state)'
                queryMs     = [math]::Round($queryDuration.TotalMilliseconds)
            }
            Write-StatusMessage "  $scriptName -> no run state found ($($queryDuration.TotalMilliseconds.ToString('F0'))ms)" -Type Warning
        }
    }
    catch {
        $approachA_Results += @{
            scriptId    = $scriptId
            displayName = $scriptName
            detectionState = "ERROR: $($_.Exception.Message)"
        }
        Write-StatusMessage "  $scriptName -> ERROR: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "  Error: $scriptName -> $($_.Exception.Message)" -Component "Test-ProactiveRemediation" -Type 3
    }
}

$approachA_Duration = (Get-Date) - $approachA_Start
Write-Host ""
Write-StatusMessage "Approach A: $($approachA_ApiCalls) API calls in $([math]::Round($approachA_Duration.TotalSeconds, 1))s" -Type Info
#endregion Approach A

#region Approach B: Portal approach — single deviceHealthScriptStates call
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Approach B: deviceHealthScriptStates" -ForegroundColor Green
Write-Host "  (portal approach — single API call)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""

# Captured from the Intune portal (Remediations page, F12 > Network tab)
# Ref: https://learn.microsoft.com/graph/api/resources/intune-devices-devicehealthscriptpolicystate
# Returns deviceHealthScriptPolicyState objects with: policyId, policyName, detectionState,
#   remediationState, lastStateUpdateDateTime, script outputs, errors, etc.
$approachB_Results = @()
$approachB_Raw = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceHealthScriptStates"
    Write-StatusMessage "  GET deviceHealthScriptStates (single call for all scripts)..." -Type Progress
    Write-DeviceDNALog -Message "Approach B: GET $uri" -Component "Test-ProactiveRemediation" -Type 1

    $queryStart = Get-Date
    $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

    $allStates = @($response.value)
    $pageCount = 1
    while ($response.'@odata.nextLink') {
        $pageCount++
        $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
        $allStates += $response.value
    }
    $queryDuration = (Get-Date) - $queryStart

    Write-StatusMessage "  Got $($allStates.Count) script state(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms ($pageCount page(s))" -Type Info
    Write-DeviceDNALog -Message "Approach B: $($allStates.Count) states in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Test-ProactiveRemediation" -Type 1

    # Log all raw states
    foreach ($state in $allStates) {
        $approachB_Raw += @{
            id              = $state.id
            policyId        = $state.policyId
            policyName      = $state.policyName
            deviceId        = $state.deviceId
            deviceName      = $state.deviceName
            userName        = $state.userName
            osVersion       = $state.osVersion
            detectionState  = $state.detectionState
            remediationState = $state.remediationState
            lastStateUpdateDateTime       = $state.lastStateUpdateDateTime
            expectedStateUpdateDateTime   = $state.expectedStateUpdateDateTime
            lastSyncDateTime              = $state.lastSyncDateTime
            preRemediationDetectionScriptOutput  = $state.preRemediationDetectionScriptOutput
            preRemediationDetectionScriptError   = $state.preRemediationDetectionScriptError
            remediationScriptError               = $state.remediationScriptError
            postRemediationDetectionScriptOutput = $state.postRemediationDetectionScriptOutput
            postRemediationDetectionScriptError  = $state.postRemediationDetectionScriptError
        }

        Write-StatusMessage "  $($state.policyName) -> detection=$($state.detectionState), remediation=$($state.remediationState)" -Type Info
        Write-DeviceDNALog -Message "  State: policyName=$($state.policyName), policyId=$($state.policyId), detection=$($state.detectionState), remediation=$($state.remediationState)" -Component "Test-ProactiveRemediation" -Type 1
    }

    # Match to targeted remediations
    Write-Host ""
    Write-StatusMessage "Matching to targeted remediations..." -Type Progress
    foreach ($remediation in $targetedRemediations) {
        $match = $allStates | Where-Object { $_.policyId -eq $remediation.id } | Select-Object -First 1
        if ($match) {
            $approachB_Results += @{
                scriptId          = $remediation.id
                displayName       = $remediation.displayName
                detectionState    = $match.detectionState
                remediationState  = $match.remediationState
                lastStateUpdateDateTime       = $match.lastStateUpdateDateTime
                expectedStateUpdateDateTime   = $match.expectedStateUpdateDateTime
                preRemediationDetectionScriptOutput  = $match.preRemediationDetectionScriptOutput
                preRemediationDetectionScriptError   = $match.preRemediationDetectionScriptError
                postRemediationDetectionScriptOutput = $match.postRemediationDetectionScriptOutput
                postRemediationDetectionScriptError  = $match.postRemediationDetectionScriptError
                remediationScriptError               = $match.remediationScriptError
            }
            Write-StatusMessage "  $($remediation.displayName) -> detection=$($match.detectionState), remediation=$($match.remediationState)" -Type Success
        }
        else {
            $approachB_Results += @{
                scriptId    = $remediation.id
                displayName = $remediation.displayName
                detectionState = '(no state found)'
            }
            Write-StatusMessage "  $($remediation.displayName) -> not found in device states" -Type Warning
        }
    }

    # Check for states not in targeted list (scripts running but not in our targeting evaluation)
    Write-Host ""
    $untargetedStates = @($allStates | Where-Object {
        $stateId = $_.policyId
        -not ($targetedRemediations | Where-Object { $_.id -eq $stateId })
    })
    if ($untargetedStates.Count -gt 0) {
        Write-StatusMessage "Found $($untargetedStates.Count) script state(s) NOT in targeted list:" -Type Warning
        foreach ($state in $untargetedStates) {
            Write-StatusMessage "  EXTRA: $($state.policyName) [$($state.policyId)] detection=$($state.detectionState)" -Type Warning
            Write-DeviceDNALog -Message "  Untargeted state: $($state.policyName) [$($state.policyId)] detection=$($state.detectionState)" -Component "Test-ProactiveRemediation" -Type 2
        }
    }
}
catch {
    Write-StatusMessage "Approach B FAILED: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "Approach B failed: $($_.Exception.Message)" -Component "Test-ProactiveRemediation" -Type 3
}
#endregion Approach B

#region Results Comparison
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Results Comparison" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

Write-StatusMessage "Script-by-script comparison:" -Type Info
Write-Host ""

$comparisonTable = @()
foreach ($remediation in $targetedRemediations) {
    $aResult = $approachA_Results | Where-Object { $_.scriptId -eq $remediation.id }
    $bResult = $approachB_Results | Where-Object { $_.scriptId -eq $remediation.id }

    $aDetection = if ($aResult) { $aResult.detectionState } else { '(n/a)' }
    $bDetection = if ($bResult) { $bResult.detectionState } else { '(n/a)' }
    $aRemediation = if ($aResult.remediationState) { $aResult.remediationState } else { '-' }
    $bRemediation = if ($bResult.remediationState) { $bResult.remediationState } else { '-' }

    $row = [PSCustomObject]@{
        'Script'          = if ($remediation.displayName.Length -gt 35) { $remediation.displayName.Substring(0, 32) + '...' } else { $remediation.displayName }
        'A-Detection'     = $aDetection
        'A-Remediation'   = $aRemediation
        'B-Detection'     = $bDetection
        'B-Remediation'   = $bRemediation
        'Match'           = if ($aDetection -eq $bDetection) { 'YES' } else { 'NO' }
    }
    $comparisonTable += $row

    Write-DeviceDNALog -Message "Compare: $($remediation.displayName) | A=$aDetection/$aRemediation | B=$bDetection/$bRemediation | Match=$(if ($aDetection -eq $bDetection) { 'YES' } else { 'NO' })" -Component "Test-ProactiveRemediation" -Type 1
}

$comparisonTable | Format-Table -AutoSize -Wrap

# Summary
$aMatched = @($approachA_Results | Where-Object { $_.detectionState -and $_.detectionState -ne '(no run state)' -and $_.detectionState -notlike 'ERROR:*' }).Count
$bMatched = @($approachB_Results | Where-Object { $_.detectionState -and $_.detectionState -ne '(no state found)' -and $_.detectionState -notlike 'ERROR:*' }).Count

Write-Host ""
Write-StatusMessage "Summary:" -Type Info
Write-StatusMessage "  Approach A (per-script deviceRunStates):      $aMatched/$($targetedRemediations.Count) matched, $($approachA_ApiCalls) API calls, $([math]::Round($approachA_Duration.TotalSeconds, 1))s" -Type $(if ($aMatched -eq $targetedRemediations.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Approach B (single deviceHealthScriptStates): $bMatched/$($targetedRemediations.Count) matched, 1 API call, $([math]::Round($queryDuration.TotalSeconds, 1))s" -Type $(if ($bMatched -eq $targetedRemediations.Count) { 'Success' } else { 'Warning' })
Write-StatusMessage "  Total states from Approach B (all scripts):   $($approachB_Raw.Count)" -Type Info
#endregion Results Comparison

#region Export JSON
Write-Host ""
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFileName = "RemediationDiag_${DeviceName}_${timestamp}.json"
$jsonPath = Join-Path $OutputPath $jsonFileName

$exportData = @{
    deviceName               = $DeviceName
    tenantId                 = $tenantId
    resolvedIds              = $resolvedIds
    totalScriptsInTenant     = $allRemediations.Count
    targetedScriptCount      = $targetedRemediations.Count
    targetedRemediations     = $targetedRemediations
    approachA                = @{
        description = "Per-script deviceRunStates with `$filter (current code, N API calls)"
        results     = $approachA_Results
        apiCalls    = $approachA_ApiCalls
        durationMs  = [math]::Round($approachA_Duration.TotalMilliseconds)
        matchRate   = "$aMatched/$($targetedRemediations.Count)"
    }
    approachB                = @{
        description       = "Single deviceHealthScriptStates call (portal approach, 1 API call)"
        results           = $approachB_Results
        rawStates         = $approachB_Raw
        totalStatesOnDevice = $approachB_Raw.Count
        matchRate         = "$bMatched/$($targetedRemediations.Count)"
    }
    collectionTime           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    duration                 = ((Get-Date) - $testStartTime).ToString('hh\:mm\:ss')
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
