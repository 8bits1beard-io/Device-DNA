<#
.SYNOPSIS
    Collects Intune/Graph device data only (no GPO/SCCM/WU) for a single device.
.DESCRIPTION
    Standalone diagnostic script that connects to Microsoft Graph and collects a broad
    set of Intune and Entra device details for one device, including:
    - Entra device object and transitive group memberships
    - Intune managedDevice (v1.0 + beta)
    - Intune hardwareInformation (beta)
    - Intune managedDevice related resources (category, users, protection state, logs)
    - Intune deviceHealthScriptStates (beta)
    - Best-effort Intune Reports API exports filtered to this device

    Results are written to JSON and CSV files under the specified output folder.
.PARAMETER DeviceName
    Target device name. Defaults to local computer name.
.PARAMETER OutputPath
    Directory for output files. Defaults to output/<DeviceName>/ under the repo root.
.PARAMETER SkipReports
    Skip Intune Reports API export jobs (faster, less coverage).
.EXAMPLE
    .\tests\Test-IntuneDeviceOnly.ps1
.EXAMPLE
    .\tests\Test-IntuneDeviceOnly.ps1 -DeviceName "PC001" -SkipReports
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$DeviceName,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$SkipReports
)

#region Module Loading
$scriptRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $scriptRoot 'modules\Core.ps1')
. (Join-Path $scriptRoot 'modules\Logging.ps1')
. (Join-Path $scriptRoot 'modules\Helpers.ps1')
. (Join-Path $scriptRoot 'modules\DeviceInfo.ps1')
. (Join-Path $scriptRoot 'modules\Intune.ps1')
#endregion

#region Helpers
function ConvertTo-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return "unnamed" }
    return ($Name -replace '[^\w\.\-]', '_')
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $Data | ConvertTo-Json -Depth 20 | Out-File -FilePath $Path -Encoding UTF8 -Force
}

function Invoke-EndpointCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    Write-StatusMessage "Collecting: $Name" -Type Progress
    Write-DeviceDNALog -Message "Endpoint capture: $Name -> $Uri" -Component "Test-IntuneDeviceOnly" -Type 1

    $result = [ordered]@{
        name      = $Name
        uri       = $Uri
        success   = $false
        count     = $null
        error     = $null
        data      = $null
    }

    try {
        $data = Invoke-GraphRequest -Method GET -Uri $Uri
        $result.data = $data
        $result.success = ($null -ne $data)

        if ($data -is [System.Array]) {
            $result.count = $data.Count
        }
        elseif ($null -ne $data) {
            $result.count = 1
        }
        else {
            $result.count = 0
        }
    }
    catch {
        $result.error = $_.Exception.Message
        Write-DeviceDNALog -Message "Endpoint capture failed: $Name : $($_.Exception.Message)" -Component "Test-IntuneDeviceOnly" -Type 2
    }

    return $result
}

function Export-IntuneReportCsvForDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportName,
        [Parameter(Mandatory = $true)]
        [string]$Filter,
        [Parameter(Mandatory = $true)]
        [string]$DestinationFolder
    )

    $result = [ordered]@{
        reportName = $ReportName
        filter     = $Filter
        success    = $false
        rowCount   = 0
        filePath   = $null
        error      = $null
    }

    try {
        if (-not (Test-Path $DestinationFolder)) {
            New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
        }

        $body = @{
            reportName = $ReportName
            filter     = $Filter
            format     = "csv"
        } | ConvertTo-Json

        $exportJobsUri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"
        $job = Invoke-MgGraphRequest -Uri $exportJobsUri -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop
        if (-not $job -or -not $job.id) {
            throw "Failed to create export job."
        }

        $jobStatus = Wait-ExportJobCompletion -JobUri "$exportJobsUri/$($job.id)" -MaxWaitSeconds 90
        if (-not $jobStatus -or -not $jobStatus.url) {
            throw "Export job failed, timed out, or did not return a download URL."
        }

        $tempGuid = [guid]::NewGuid().ToString()
        $tempZip = Join-Path $env:TEMP "DeviceDNA_IntuneReport_$tempGuid.zip"
        $tempExtract = Join-Path $env:TEMP "DeviceDNA_IntuneReport_$tempGuid"

        Invoke-WebRequest -Uri $jobStatus.url -Method Get -OutFile $tempZip -ErrorAction Stop
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop

        $csvFile = Get-ChildItem -Path $tempExtract -Filter "*.csv" -File | Select-Object -First 1
        if (-not $csvFile) {
            throw "No CSV file found in report archive."
        }

        $destName = "{0}.csv" -f (ConvertTo-SafeFileName $ReportName)
        $destPath = Join-Path $DestinationFolder $destName
        Copy-Item -Path $csvFile.FullName -Destination $destPath -Force

        $rows = @(Import-Csv -Path $destPath)
        $result.success = $true
        $result.rowCount = $rows.Count
        $result.filePath = $destPath

        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        $result.error = $_.Exception.Message
        Write-DeviceDNALog -Message "Report export failed ($ReportName): $($_.Exception.Message)" -Component "Test-IntuneDeviceOnly" -Type 2
    }

    return $result
}
#endregion

#region Initialization
if ([string]::IsNullOrEmpty($DeviceName)) {
    $DeviceName = $env:COMPUTERNAME
}

if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $scriptRoot "output\$DeviceName"
}

if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Initialize-DeviceDNALog -OutputPath $OutputPath -TargetDevice $DeviceName

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DeviceDNA - Intune Device Only Test" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-StatusMessage "Device: $DeviceName" -Type Info
Write-StatusMessage "Output: $OutputPath" -Type Info
if ($logPath) { Write-StatusMessage "Log: $logPath" -Type Info }

Write-DeviceDNALog -Message "=== Intune Device Only Test ===" -Component "Test-IntuneDeviceOnly" -Type 1
Write-DeviceDNALog -Message "Device: $DeviceName" -Component "Test-IntuneDeviceOnly" -Type 1
#endregion

$summary = [ordered]@{
    deviceName       = $DeviceName
    collectedAt      = (Get-Date).ToString("s")
    outputPath       = $OutputPath
    resolvedIds      = $null
    endpointCaptures = @()
    reportExports    = @()
    notes            = @(
        "Intune and Entra data only. Local OS/WMI inventory is intentionally excluded.",
        "Some fields/endpoints may return null or 403 depending on platform, enrollment state, and Graph permissions."
    )
}

try {
    # Join/tenant discovery (used only to connect Graph)
    Write-StatusMessage "Detecting device join type..." -Type Progress
    $joinInfo = Get-DeviceJoinType
    if (-not ($joinInfo.AzureAdJoined -or $joinInfo.WorkplaceJoined)) {
        Write-StatusMessage "Device is not Azure AD/Workplace joined. Intune Graph collection likely unavailable." -Type Error
        throw "Device is not Azure AD/Workplace joined."
    }

    $tenantId = if ($joinInfo.TenantId) { $joinInfo.TenantId } else { Get-TenantId -DsregOutput $joinInfo.RawOutput }

    Write-Host ""
    Write-StatusMessage "Connecting to Microsoft Graph..." -Type Progress
    if (-not (Connect-GraphAPI -TenantId $tenantId)) {
        throw "Failed to connect to Microsoft Graph."
    }

    # Resolve IDs
    Write-Host ""
    Write-StatusMessage "Resolving device identity..." -Type Progress

    $resolvedIds = [ordered]@{
        AzureADObjectId  = $null
        HardwareDeviceId = $null  # Entra deviceId / AzureAD deviceId (GUID)
        IntuneDeviceId   = $null
        UserPrincipalName = $null
    }

    $azureADDevice = Find-AzureADDevice -DeviceName $DeviceName
    if ($azureADDevice) {
        $resolvedIds.AzureADObjectId = $azureADDevice.ObjectId
        $resolvedIds.HardwareDeviceId = $azureADDevice.DeviceId
    }

    $managedDevice = $null
    if (-not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
        $managedDevice = Get-IntuneDevice -AzureADDeviceId $resolvedIds.HardwareDeviceId
    }
    if (-not $managedDevice) {
        $managedDevice = Get-IntuneDevice -DeviceName $DeviceName
    }

    if ($managedDevice) {
        $resolvedIds.IntuneDeviceId = $managedDevice.Id
        $resolvedIds.UserPrincipalName = $managedDevice.UserPrincipalName
        if ([string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId) -and $managedDevice.AzureADDeviceId) {
            $resolvedIds.HardwareDeviceId = $managedDevice.AzureADDeviceId
        }
    }

    if ([string]::IsNullOrEmpty($resolvedIds.AzureADObjectId) -and -not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
        $recovered = Find-AzureADDevice -DeviceName $DeviceName -DeviceId $resolvedIds.HardwareDeviceId
        if ($recovered) {
            $azureADDevice = $recovered
            $resolvedIds.AzureADObjectId = $recovered.ObjectId
        }
    }

    $summary.resolvedIds = $resolvedIds

    Write-StatusMessage "Azure AD object ID: $(if ($resolvedIds.AzureADObjectId) { $resolvedIds.AzureADObjectId } else { 'NOT RESOLVED' })" -Type Info
    Write-StatusMessage "Hardware device ID: $(if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { 'NOT RESOLVED' })" -Type Info
    Write-StatusMessage "Intune device ID: $(if ($resolvedIds.IntuneDeviceId) { $resolvedIds.IntuneDeviceId } else { 'NOT RESOLVED' })" -Type Info

    if ([string]::IsNullOrEmpty($resolvedIds.IntuneDeviceId)) {
        throw "Unable to resolve Intune managed device ID."
    }

    # Endpoint captures (broad device-centric coverage)
    Write-Host ""
    Write-StatusMessage "Collecting Intune/Entra device endpoints..." -Type Progress

    $captures = @()

    # Intune managed device core resources
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice (v1.0)" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice (beta)" -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice hardwareInformation (beta)" -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)?`$select=hardwareInformation"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice selected inventory fields (v1.0)" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)?`$select=id,deviceName,managedDeviceName,azureADDeviceId,serialNumber,manufacturer,model,operatingSystem,osVersion,wiFiMacAddress,ethernetMacAddress,physicalMemoryInBytes,totalStorageSpaceInBytes,freeStorageSpaceInBytes,lastSyncDateTime,enrolledDateTime,userPrincipalName,managementState,complianceState,ownerType,jailBroken,managementAgent,joinType"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice deviceCategory" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceCategory"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice windowsProtectionState" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/windowsProtectionState"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice users (beta)" -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/users"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice logCollectionRequests" -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/logCollectionRequests"
    $captures += Invoke-EndpointCapture -Name "Intune managedDevice deviceHealthScriptStates (beta)" -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceHealthScriptStates"

    # Entra device object / group memberships (used by Intune targeting)
    if (-not [string]::IsNullOrEmpty($resolvedIds.AzureADObjectId)) {
        $captures += Invoke-EndpointCapture -Name "Entra device object (v1.0)" -Uri "https://graph.microsoft.com/v1.0/devices/$($resolvedIds.AzureADObjectId)"
        $captures += Invoke-EndpointCapture -Name "Entra device transitiveMemberOf (v1.0)" -Uri "https://graph.microsoft.com/v1.0/devices/$($resolvedIds.AzureADObjectId)/transitiveMemberOf?`$top=999"
        $captures += Invoke-EndpointCapture -Name "Entra device registeredOwners (v1.0)" -Uri "https://graph.microsoft.com/v1.0/devices/$($resolvedIds.AzureADObjectId)/registeredOwners"
    }

    # User app intent/state can contain user-targeted app states for this device context
    if (-not [string]::IsNullOrEmpty($resolvedIds.UserPrincipalName)) {
        $captures += Invoke-EndpointCapture -Name "User mobileAppIntentAndStates (beta)" -Uri "https://graph.microsoft.com/beta/users/$($resolvedIds.UserPrincipalName)/mobileAppIntentAndStates"
    }

    $summary.endpointCaptures = $captures

    # Reports API (best-effort device-filtered exports)
    if (-not $SkipReports) {
        Write-Host ""
        Write-StatusMessage "Attempting Intune Reports API exports (best-effort)..." -Type Progress
        $reportsFolder = Join-Path $OutputPath "IntuneReports"
        $reportResults = @()

        $reportRequests = @(
            @{ Name = "DevicesWithInventory"; Filter = "DeviceId eq '$($resolvedIds.IntuneDeviceId)'" },
            @{ Name = "DeviceCompliance"; Filter = "DeviceId eq '$($resolvedIds.IntuneDeviceId)'" },
            @{ Name = "DeviceConfigurationPolicyStatuses"; Filter = "IntuneDeviceId eq '$($resolvedIds.IntuneDeviceId)'" },
            @{ Name = "ADMXSettingsByDeviceByPolicy"; Filter = "DeviceId eq '$($resolvedIds.IntuneDeviceId)'" }
        )

        foreach ($req in $reportRequests) {
            Write-StatusMessage "Exporting report: $($req.Name)" -Type Progress
            $reportResults += Export-IntuneReportCsvForDevice -ReportName $req.Name -Filter $req.Filter -DestinationFolder $reportsFolder
        }

        $summary.reportExports = $reportResults
    }
    else {
        Write-StatusMessage "Skipping Intune Reports API exports as requested" -Type Info
    }

    # Persist summary JSON
    $summaryFile = Join-Path $OutputPath ("IntuneDeviceOnly_{0}.json" -f $timestamp)
    Save-JsonFile -Path $summaryFile -Data $summary
    Write-StatusMessage "Saved Intune-only capture: $summaryFile" -Type Success

    # Also export endpoint payloads split out for easier inspection
    $rawFolder = Join-Path $OutputPath "IntuneRaw"
    if (-not (Test-Path $rawFolder)) {
        New-Item -Path $rawFolder -ItemType Directory -Force | Out-Null
    }

    foreach ($capture in @($summary.endpointCaptures)) {
        $safeName = ConvertTo-SafeFileName $capture.name
        $rawFile = Join-Path $rawFolder ("{0}.json" -f $safeName)
        Save-JsonFile -Path $rawFile -Data $capture
    }

    Write-Host ""
    $successCount = @($summary.endpointCaptures | Where-Object { $_.success }).Count
    $totalCount = @($summary.endpointCaptures).Count
    Write-StatusMessage "Endpoint captures succeeded: $successCount / $totalCount" -Type Info
}
catch {
    Write-StatusMessage "Test failed: $($_.Exception.Message)" -Type Error
    Write-DeviceDNALog -Message "Fatal error: $($_.Exception.Message)" -Component "Test-IntuneDeviceOnly" -Type 3
}
finally {
    Disconnect-GraphAPI
    Complete-DeviceDNALog
}

