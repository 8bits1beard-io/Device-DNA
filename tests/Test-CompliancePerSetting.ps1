<#
.SYNOPSIS
    Test script for per-setting compliance data via deviceCompliancePolicyStates.
.DESCRIPTION
    Connects to Graph API, resolves the device, then calls the deviceCompliancePolicyStates
    navigation property to see what per-setting compliance data is available.

    Focuses on answering:
    - Does settingStates return actual data or empty arrays?
    - What fields populate (settingName, state, currentValue, errorCode, etc.)?
    - How many settings per policy?

    Exports raw JSON for review.
.PARAMETER DeviceName
    Override the device name. Defaults to $env:COMPUTERNAME.
.EXAMPLE
    .\tests\Test-CompliancePerSetting.ps1
.EXAMPLE
    .\tests\Test-CompliancePerSetting.ps1 -DeviceName "DESKTOP-ABC123"
.NOTES
    Requires: PowerShell 5.1+, Microsoft.Graph.Authentication module
    Must run on a Windows device that is Azure AD or Hybrid joined.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$DeviceName
)

#region Module Loading
$scriptRoot = Split-Path -Parent $PSScriptRoot
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

$OutputPath = Join-Path $scriptRoot "output\$DeviceName"
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Per-Setting Compliance State Test" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Device: $DeviceName" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName
#endregion Initialization

#region Connect & Resolve Device
Write-StatusMessage "Detecting device join type..." -Type Progress
$joinInfo = Get-DeviceJoinType

if (-not $joinInfo.AzureAdJoined) {
    Write-StatusMessage "Device is NOT Azure AD joined - cannot proceed" -Type Error
    return
}
Write-StatusMessage "Device is Azure AD joined" -Type Success

$tenantId = $joinInfo.TenantId
if (-not $tenantId) {
    $tenantId = Get-TenantId -DsregOutput $joinInfo.RawOutput
}
if ($tenantId) {
    Write-StatusMessage "Tenant ID: $tenantId" -Type Info
}

Write-StatusMessage "Connecting to Microsoft Graph..." -Type Progress
$connected = Connect-GraphAPI -TenantId $tenantId
if (-not $connected) {
    Write-StatusMessage "Failed to connect to Graph API" -Type Error
    return
}

Write-Host ""
Write-StatusMessage "Resolving device identity..." -Type Progress

$resolvedIds = @{
    AzureADObjectId  = $null
    HardwareDeviceId = $null
    IntuneDeviceId   = $null
}

$azureADDevice = Find-AzureADDevice -DeviceName $DeviceName
if ($azureADDevice) {
    Write-StatusMessage "Found in Azure AD: $($azureADDevice.DisplayName)" -Type Success
    $resolvedIds.AzureADObjectId = $azureADDevice.ObjectId
    $resolvedIds.HardwareDeviceId = $azureADDevice.DeviceId
}

$managedDevice = $null
if (-not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
    $managedDevice = Get-IntuneDevice -AzureADDeviceId $resolvedIds.HardwareDeviceId
}
else {
    $managedDevice = Get-IntuneDevice -DeviceName $DeviceName
}

if ($managedDevice) {
    Write-StatusMessage "Found in Intune: $($managedDevice.DeviceName)" -Type Success
    $resolvedIds.IntuneDeviceId = $managedDevice.Id
}
else {
    Write-StatusMessage "Device not found in Intune - cannot proceed" -Type Error
    Disconnect-GraphAPI
    return
}

Write-StatusMessage "Intune Device ID: $($resolvedIds.IntuneDeviceId)" -Type Info
#endregion Connect & Resolve Device

#region Call deviceCompliancePolicyStates
Write-Host ""
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host "  Calling deviceCompliancePolicyStates" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""

$allPolicyStates = @()
$rawResponse = @()

try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceCompliancePolicyStates"
    Write-StatusMessage "GET $uri" -Type Progress

    $queryStart = Get-Date
    $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
    $rawResponse = @($response.value)

    # Paginate
    while ($response.'@odata.nextLink') {
        $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
        $rawResponse += $response.value
    }
    $queryDuration = (Get-Date) - $queryStart

    Write-StatusMessage "Got $($rawResponse.Count) policy state(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Type Success
    Write-Host ""

    # Walk each policy state
    foreach ($policyState in $rawResponse) {
        Write-Host "  -----------------------------------------------" -ForegroundColor DarkGray
        Write-StatusMessage "  Policy: $($policyState.displayName)" -Type Info
        Write-StatusMessage "    State:        $($policyState.state)" -Type $(if ($policyState.state -eq 'compliant') { 'Success' } elseif ($policyState.state -in @('nonCompliant', 'error')) { 'Error' } else { 'Warning' })
        Write-StatusMessage "    Platform:     $($policyState.platformType)" -Type Info
        Write-StatusMessage "    Setting Count: $($policyState.settingCount)" -Type Info
        Write-StatusMessage "    Version:      $($policyState.version)" -Type Info
        Write-StatusMessage "    ID:           $($policyState.id)" -Type Info

        # Per-setting details
        $settingStates = @($policyState.settingStates)

        if ($settingStates.Count -gt 0) {
            Write-Host ""
            Write-StatusMessage "    Settings ($($settingStates.Count)):" -Type Info

            foreach ($ss in $settingStates) {
                $settingStatus = if ($ss.state -eq 'compliant') { 'Success' }
                                 elseif ($ss.state -in @('nonCompliant', 'error')) { 'Error' }
                                 else { 'Warning' }

                Write-StatusMessage "      $($ss.settingName)" -Type $settingStatus
                Write-StatusMessage "        State:        $($ss.state)" -Type $settingStatus
                Write-StatusMessage "        Current Value: $($ss.currentValue)" -Type Info

                if ($ss.errorCode -and $ss.errorCode -ne 0) {
                    Write-StatusMessage "        Error Code:   $($ss.errorCode)" -Type Error
                    Write-StatusMessage "        Error Desc:   $($ss.errorDescription)" -Type Error
                }
                if ($ss.setting) {
                    Write-StatusMessage "        Setting ID:   $($ss.setting)" -Type Info
                }
                if ($ss.sources -and $ss.sources.Count -gt 0) {
                    foreach ($src in $ss.sources) {
                        Write-StatusMessage "        Source:       $($src.displayName) ($($src.sourceType))" -Type Info
                    }
                }
                if ($ss.userPrincipalName) {
                    Write-StatusMessage "        UPN:          $($ss.userPrincipalName)" -Type Info
                }
            }
        }
        else {
            Write-StatusMessage "    Settings: (empty - no settingStates returned)" -Type Warning
        }
        Write-Host ""

        $allPolicyStates += @{
            displayName  = $policyState.displayName
            state        = $policyState.state
            platformType = $policyState.platformType
            settingCount = $policyState.settingCount
            version      = $policyState.version
            id           = $policyState.id
            settingStates = @($settingStates | ForEach-Object {
                @{
                    settingName         = $_.settingName
                    setting             = $_.setting
                    state               = $_.state
                    currentValue        = $_.currentValue
                    errorCode           = $_.errorCode
                    errorDescription    = $_.errorDescription
                    userPrincipalName   = $_.userPrincipalName
                    userName            = $_.userName
                    userEmail           = $_.userEmail
                    userId              = $_.userId
                    instanceDisplayName = $_.instanceDisplayName
                    sources             = @($_.sources | ForEach-Object {
                        @{
                            id          = $_.id
                            displayName = $_.displayName
                            sourceType  = $_.sourceType
                        }
                    })
                }
            })
        }
    }
}
catch {
    Write-StatusMessage "FAILED: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "deviceCompliancePolicyStates failed: $($_.Exception.Message)" -Component "Test-CompliancePerSetting" -Type 3
}
#endregion Call deviceCompliancePolicyStates

#region Summary
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$totalPolicies = $allPolicyStates.Count
$policiesWithSettings = @($allPolicyStates | Where-Object { $_.settingStates.Count -gt 0 }).Count
$policiesWithoutSettings = $totalPolicies - $policiesWithSettings
$totalSettings = ($allPolicyStates | ForEach-Object { $_.settingStates.Count } | Measure-Object -Sum).Sum
$nonCompliantSettings = ($allPolicyStates | ForEach-Object { @($_.settingStates | Where-Object { $_.state -eq 'nonCompliant' }) } | Measure-Object -Property Count -Sum).Sum
$errorSettings = ($allPolicyStates | ForEach-Object { @($_.settingStates | Where-Object { $_.state -eq 'error' }) } | Measure-Object -Property Count -Sum).Sum

Write-StatusMessage "Total policies returned:          $totalPolicies" -Type Info
Write-StatusMessage "Policies WITH settingStates:      $policiesWithSettings" -Type $(if ($policiesWithSettings -gt 0) { 'Success' } else { 'Warning' })
Write-StatusMessage "Policies WITHOUT settingStates:   $policiesWithoutSettings" -Type $(if ($policiesWithoutSettings -eq 0) { 'Success' } else { 'Warning' })
Write-StatusMessage "Total settings across all policies: $totalSettings" -Type Info
if ($nonCompliantSettings -gt 0) {
    Write-StatusMessage "Non-compliant settings:           $nonCompliantSettings" -Type Error
}
if ($errorSettings -gt 0) {
    Write-StatusMessage "Error settings:                   $errorSettings" -Type Error
}

# Check which fields actually populated
if ($totalSettings -gt 0) {
    $allSettings = @($allPolicyStates | ForEach-Object { $_.settingStates } | ForEach-Object { $_ })
    $hasSettingName = @($allSettings | Where-Object { -not [string]::IsNullOrEmpty($_.settingName) }).Count
    $hasSetting = @($allSettings | Where-Object { -not [string]::IsNullOrEmpty($_.setting) }).Count
    $hasCurrentValue = @($allSettings | Where-Object { -not [string]::IsNullOrEmpty($_.currentValue) }).Count
    $hasErrorCode = @($allSettings | Where-Object { $_.errorCode -and $_.errorCode -ne 0 }).Count
    $hasSources = @($allSettings | Where-Object { $_.sources -and $_.sources.Count -gt 0 }).Count

    Write-Host ""
    Write-StatusMessage "Field population ($totalSettings total settings):" -Type Info
    Write-StatusMessage "  settingName:   $hasSettingName/$totalSettings populated" -Type $(if ($hasSettingName -eq $totalSettings) { 'Success' } else { 'Warning' })
    Write-StatusMessage "  setting (ID):  $hasSetting/$totalSettings populated" -Type $(if ($hasSetting -eq $totalSettings) { 'Success' } else { 'Warning' })
    Write-StatusMessage "  currentValue:  $hasCurrentValue/$totalSettings populated" -Type Info
    Write-StatusMessage "  errorCode:     $hasErrorCode/$totalSettings have non-zero errors" -Type Info
    Write-StatusMessage "  sources:       $hasSources/$totalSettings have source info" -Type Info
}
#endregion Summary

#region Export
Write-Host ""
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonFileName = "CompliancePerSetting_${DeviceName}_${timestamp}.json"
$jsonPath = Join-Path $OutputPath $jsonFileName

$exportData = @{
    deviceName        = $DeviceName
    intuneDeviceId    = $resolvedIds.IntuneDeviceId
    collectionTime    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    duration          = ((Get-Date) - $testStartTime).ToString('hh\:mm\:ss')
    policyCount       = $totalPolicies
    totalSettings     = $totalSettings
    policyStates      = $allPolicyStates
    rawApiResponse    = $rawResponse
}

$exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
Write-StatusMessage "Results exported to: $jsonPath" -Type Success

Disconnect-GraphAPI
Complete-DeviceDNALog

Write-Host ""
Write-StatusMessage "Done. Total time: $((Get-Date) - $testStartTime)" -Type Info
Write-Host ""
#endregion Export
