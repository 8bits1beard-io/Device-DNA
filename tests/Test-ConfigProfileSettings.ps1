<#
.SYNOPSIS
    Test script to collect detailed settings from Intune configuration profiles.

.DESCRIPTION
    Demonstrates how to retrieve the specific settings configured in each Intune
    configuration profile (both legacy deviceConfiguration and Settings Catalog).

.NOTES
    Author: Device DNA Test
    Date: 2026-02-13

    References:
    - Legacy profiles: https://learn.microsoft.com/graph/api/intune-deviceconfig-deviceconfiguration-get
    - Settings Catalog: https://learn.microsoft.com/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-get
    - Settings collection: https://learn.microsoft.com/graph/api/intune-deviceconfigv2-devicemanagementconfigurationsetting-list
#>

#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeviceName,

    [Parameter()]
    [string]$OutputPath = ".\output"
)

#region Helper Functions

# Script-level variable for log file path
$script:LogFilePath = $null

function Write-TestLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $colors = @{
        Info    = 'Cyan'
        Success = 'Green'
        Warning = 'Yellow'
        Error   = 'Red'
    }

    # Write to console
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host "[$Type] " -NoNewline -ForegroundColor $colors[$Type]
    Write-Host $Message

    # Write to log file if initialized
    if ($script:LogFilePath) {
        $logLine = "[$timestamp] [$Type] $Message"
        Add-Content -Path $script:LogFilePath -Value $logLine -ErrorAction SilentlyContinue
    }
}

function Invoke-GraphRequestWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [string]$Method = 'GET',

        [Parameter()]
        [int]$MaxRetries = 3
    )

    $retryCount = 0
    $baseDelay = 2

    while ($retryCount -lt $MaxRetries) {
        try {
            Write-TestLog "API Call: $Method $Uri" -Type Info

            $result = Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop

            # Handle pagination
            $allResults = @()
            if ($result.value) {
                $allResults += $result.value
            } else {
                return $result
            }

            # Follow @odata.nextLink
            while ($result.'@odata.nextLink') {
                Write-TestLog "  Following pagination link..." -Type Info
                $result = Invoke-MgGraphRequest -Uri $result.'@odata.nextLink' -Method GET -ErrorAction Stop
                $allResults += $result.value
            }

            return @{ value = $allResults }

        } catch {
            $retryCount++

            # Check if this is a retriable HTTP error (429 or 5xx)
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode
            }

            $isRetriable = $false
            if ($statusCode -eq 429) {
                $isRetriable = $true
            } elseif ($statusCode -and [int]$statusCode -ge 500 -and [int]$statusCode -lt 600) {
                $isRetriable = $true
            }

            if ($isRetriable) {
                $delay = [Math]::Min([Math]::Pow(2, $retryCount) * $baseDelay, 32)
                Write-TestLog "  Rate limited or server error. Retry $retryCount/$MaxRetries in ${delay}s..." -Type Warning
                Start-Sleep -Seconds $delay
            } else {
                Write-TestLog "  Error: $($_.Exception.Message)" -Type Error
                throw
            }
        }
    }

    throw "Max retries exceeded for $Uri"
}

function ConvertTo-FriendlyValue {
    param(
        [Parameter()]
        $Value,

        [Parameter()]
        [string]$PropertyName
    )

    # Convert boolean to friendly text
    if ($Value -is [bool]) {
        if ($Value) {
            return "Enabled"
        } else {
            return "Disabled"
        }
    }

    # Convert null to "Not Configured"
    if ($null -eq $Value) {
        return "Not Configured"
    }

    # Convert arrays to comma-separated (if simple types)
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "(empty array)"
        }
        # Check if array contains complex objects
        if ($Value[0] -is [hashtable] -or $Value[0] -is [System.Collections.IDictionary]) {
            # Return nested object as JSON for complex arrays
            return ($Value | ConvertTo-Json -Depth 3 -Compress)
        }
        return ($Value -join ', ')
    }

    # Convert hashtables/dictionaries to JSON
    if ($Value -is [hashtable] -or $Value -is [System.Collections.IDictionary]) {
        return ($Value | ConvertTo-Json -Depth 3 -Compress)
    }

    # Return as-is for strings, numbers, etc.
    return $Value.ToString()
}

function Export-SettingsToJson {
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName,

        [Parameter(Mandatory)]
        [string]$ProfileType,

        [Parameter(Mandatory)]
        $Settings,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $fileName = "$($ProfileName -replace '[^\w\-]', '_')_Settings.json"
    $filePath = Join-Path $OutputPath $fileName

    $output = [ordered]@{
        ProfileName = $ProfileName
        ProfileType = $ProfileType
        CollectedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Settings    = $Settings
    }

    $output | ConvertTo-Json -Depth 10 | Out-File -FilePath $filePath -Encoding UTF8
    Write-TestLog "  Exported to: $filePath" -Type Success
}

function Get-ManagedDeviceId {
    param(
        [Parameter(Mandatory)]
        [string]$DeviceName
    )

    Write-TestLog "Looking up managed device: $DeviceName" -Type Info

    # Try exact match first
    $filter = "deviceName eq '$DeviceName'"
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=id,deviceName,operatingSystem"

    $result = Invoke-GraphRequestWithRetry -Uri $uri

    if ($result.value -and $result.value.Count -gt 0) {
        $device = $result.value[0]
        Write-TestLog "  Found device: $($device.deviceName) ($($device.operatingSystem))" -Type Success
        Write-TestLog "  Managed Device ID: $($device.id)" -Type Success
        return $device.id
    }

    # Try case-insensitive search if exact match fails
    Write-TestLog "  Exact match failed, trying case-insensitive search..." -Type Warning
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem"
    $result = Invoke-GraphRequestWithRetry -Uri $uri

    foreach ($device in $result.value) {
        if ($device.deviceName -ieq $DeviceName) {
            Write-TestLog "  Found device: $($device.deviceName) ($($device.operatingSystem))" -Type Success
            Write-TestLog "  Managed Device ID: $($device.id)" -Type Success
            return $device.id
        }
    }

    throw "Device '$DeviceName' not found in Intune managed devices"
}

function Wait-ExportJobCompletion {
    param(
        [Parameter(Mandatory)]
        [string]$JobUri,

        [Parameter()]
        [int]$MaxWaitSeconds = 60
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollInterval = 500  # Start with 500ms
    $maxPollInterval = 4000  # Cap at 4 seconds

    while ($stopwatch.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
        Start-Sleep -Milliseconds $pollInterval

        try {
            $jobStatus = Invoke-MgGraphRequest -Uri $JobUri -Method GET -ErrorAction Stop

            if ($jobStatus.status -eq 'completed') {
                Write-TestLog "  Export job completed after $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds" -Type Success
                return $jobStatus
            }
            elseif ($jobStatus.status -eq 'failed') {
                Write-TestLog "  Export job failed: $($jobStatus.errorMessage)" -Type Error
                return $null
            }

            # Exponential backoff: 0.5s → 0.75s → 1.1s → 1.7s → 2.5s → 4s (capped)
            $pollInterval = [Math]::Min([int]($pollInterval * 1.5), $maxPollInterval)
        }
        catch {
            Write-TestLog "  Error polling export job: $($_.Exception.Message)" -Type Error
            return $null
        }
    }

    Write-TestLog "  Export job timeout after $MaxWaitSeconds seconds" -Type Warning
    return $null
}

#endregion

#region Main Script

try {
    Write-TestLog "=== Configuration Profile Settings Collection Test ===" -Type Info
    Write-Host ""

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-TestLog "Created output directory: $OutputPath" -Type Info
    }

    # Initialize log file
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFilePath = Join-Path $OutputPath "Test-ConfigProfileSettings_$timestamp.log"

    # Write initial log header
    Add-Content -Path $script:LogFilePath -Value "=== Configuration Profile Settings Collection Test ===" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "Device: $DeviceName" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "Output Path: $OutputPath" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "" -ErrorAction SilentlyContinue

    Write-TestLog "Log file: $script:LogFilePath" -Type Info
    Write-Host ""

    # Check Graph connection
    Write-TestLog "Checking Microsoft Graph connection..." -Type Info
    try {
        $context = Get-MgContext
        if (-not $context) {
            throw "Not connected to Microsoft Graph"
        }
        Write-TestLog "  Connected as: $($context.Account)" -Type Success
        Write-TestLog "  Tenant: $($context.TenantId)" -Type Success
    } catch {
        Write-TestLog "  Not connected. Attempting to connect..." -Type Warning
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
        Write-TestLog "  Connected successfully" -Type Success
    }

    Write-Host ""

    # Get managed device ID
    try {
        $managedDeviceId = Get-ManagedDeviceId -DeviceName $DeviceName
    } catch {
        Write-TestLog "FATAL: $($_.Exception.Message)" -Type Error
        exit 1
    }

    Write-Host ""

    #region Legacy Device Configurations

    Write-TestLog "=== Collecting Device Configuration Profiles Assigned to $DeviceName ===" -Type Info

    # Get device configuration states for this device
    $configStatesUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedDeviceId/deviceConfigurationStates"
    $configStates = Invoke-GraphRequestWithRetry -Uri $configStatesUri

    Write-TestLog "  Found $($configStates.value.Count) assigned configuration profiles" -Type Success
    Write-Host ""

    # Get all device configurations to match against states
    # Query both v1.0 and beta to get all profile types (certificates, SCEP, ADMX, wired network, health monitoring, etc.)
    Write-TestLog "Querying all device configuration profiles..." -Type Info

    $v1Profiles = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations"
    $betaProfiles = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"

    Write-TestLog "  v1.0 endpoint returned: $($v1Profiles.value.Count) profiles" -Type Info
    Write-TestLog "  beta endpoint returned: $($betaProfiles.value.Count) profiles" -Type Info

    # Merge and deduplicate by ID
    $allProfilesById = @{}
    foreach ($p in $v1Profiles.value) {
        $allProfilesById[$p.id] = $p
    }
    foreach ($p in $betaProfiles.value) {
        if (-not $allProfilesById.ContainsKey($p.id)) {
            $allProfilesById[$p.id] = $p
        }
    }

    Write-TestLog "  Total unique profiles after merge: $($allProfilesById.Count)" -Type Success
    Write-Host ""

    # Create lookup by display name
    $profileLookup = @{}
    foreach ($profileId in $allProfilesById.Keys) {
        $p = $allProfilesById[$profileId]
        if (-not $profileLookup.ContainsKey($p.displayName)) {
            $profileLookup[$p.displayName] = $p
        }
    }

    foreach ($state in $configStates.value) {
        # Match state to profile by display name
        if (-not $profileLookup.ContainsKey($state.displayName)) {
            Write-TestLog "WARNING: Could not find profile '$($state.displayName)'" -Type Warning
            continue
        }

        $profileRef = $profileLookup[$state.displayName]

        # Get the full profile details with all settings (use beta since our lookup includes beta profiles)
        $profile = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($profileRef.id)"
        Write-TestLog "Profile: $($profile.displayName)" -Type Info
        Write-TestLog "  Type: $($profile.'@odata.type')" -Type Info
        Write-TestLog "  ID: $($profile.id)" -Type Info

        # Get full profile details with all settings
        $fullProfile = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$($profile.id)"

        # Extract settings (all properties except metadata)
        $excludedProps = @('id', '@odata.type', '@odata.context', 'createdDateTime', 'lastModifiedDateTime',
                          'version', 'displayName', 'description', 'supportsScopeTags', 'roleScopeTagIds')

        $settings = [ordered]@{}
        $settingCount = 0

        # Iterate through hashtable keys (Invoke-MgGraphRequest returns hashtable)
        foreach ($key in $fullProfile.Keys) {
            if ($key -notin $excludedProps -and $null -ne $fullProfile[$key]) {
                $friendlyValue = ConvertTo-FriendlyValue -Value $fullProfile[$key] -PropertyName $key
                $settings[$key] = $friendlyValue
                $settingCount++

                # Log first 5 settings as examples
                if ($settingCount -le 5) {
                    Write-TestLog "    $key = $friendlyValue" -Type Info
                }
            }
        }

        if ($settingCount -gt 5) {
            Write-TestLog "    ... and $($settingCount - 5) more settings" -Type Info
        }

        Write-TestLog "  Total configured settings: $settingCount" -Type Success

        # Export to JSON
        Export-SettingsToJson -ProfileName $profile.displayName `
                             -ProfileType $profile.'@odata.type' `
                             -Settings $settings `
                             -OutputPath $OutputPath

        Write-Host ""
    }

    #endregion

    #region Settings Catalog Configuration Policies

    Write-TestLog "=== Collecting Settings Catalog Policies Assigned to $DeviceName ===" -Type Info
    Write-TestLog "Using Reports API to get device-scoped policy assignments..." -Type Info
    Write-Host ""

    try {
        # Create export job for device configuration policy statuses
        # This returns BOTH legacy and Settings Catalog policies assigned to the device
        $reportBody = @{
            reportName = "DeviceConfigurationPolicyStatuses"
            filter = "IntuneDeviceId eq '$managedDeviceId'"
            format = "csv"
        } | ConvertTo-Json

        $exportJobUri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"
        Write-TestLog "Creating export job for policy statuses..." -Type Info
        $exportJob = Invoke-MgGraphRequest -Uri $exportJobUri -Method POST -Body $reportBody -ContentType "application/json" -ErrorAction Stop

        Write-TestLog "  Export job created: $($exportJob.id)" -Type Success

        # Poll for job completion
        $jobUri = "$exportJobUri/$($exportJob.id)"
        Write-TestLog "  Waiting for report generation..." -Type Info
        $jobStatus = Wait-ExportJobCompletion -JobUri $jobUri -MaxWaitSeconds 60

        if (-not $jobStatus) {
            throw "Export job failed or timed out"
        }

        # Download the report ZIP from blob storage
        Write-TestLog "  Downloading report from blob storage..." -Type Info
        $reportUrl = $jobStatus.url

        $tempGuid = [guid]::NewGuid()
        $tempZip = Join-Path $env:TEMP "Test_Report_$tempGuid.zip"
        $tempExtract = Join-Path $env:TEMP "Test_Report_$tempGuid"

        Invoke-WebRequest -Uri $reportUrl -Method Get -OutFile $tempZip -ErrorAction Stop
        Write-TestLog "  ZIP downloaded: $([math]::Round((Get-Item $tempZip).Length / 1KB, 2)) KB" -Type Success

        # Extract and parse CSV
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop
        $csvFile = Get-ChildItem -Path $tempExtract -Filter "*.csv" -File | Select-Object -First 1

        if (-not $csvFile) {
            throw "No CSV file found in ZIP archive"
        }

        Write-TestLog "  Parsing report CSV..." -Type Info
        $reportRows = @(Import-Csv -Path $csvFile.FullName)

        # Cleanup temp files
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

        Write-TestLog "  Parsed $($reportRows.Count) policy status rows from report" -Type Success
        Write-Host ""

        # Deduplicate by PolicyId (Reports API returns multiple rows per policy)
        $uniquePolicies = @{}
        foreach ($reportRow in $reportRows) {
            $policyId = $reportRow.PolicyId

            if (-not $uniquePolicies.ContainsKey($policyId)) {
                $uniquePolicies[$policyId] = $reportRow
            }
            elseif ([string]::IsNullOrEmpty($uniquePolicies[$policyId].UPN) -and -not [string]::IsNullOrEmpty($reportRow.UPN)) {
                # Prefer rows with populated UPN
                $uniquePolicies[$policyId] = $reportRow
            }
        }

        Write-TestLog "Deduplicated to $($uniquePolicies.Count) unique policies" -Type Success
        Write-Host ""

        # Filter to Settings Catalog policies only (skip legacy profiles already collected)
        # Settings Catalog policies have Platform "windows10" and Type "SettingsCatalog"
        $settingsCatalogCount = 0

        foreach ($policyId in $uniquePolicies.Keys) {
            $reportRow = $uniquePolicies[$policyId]
            $policyName = $reportRow.PolicyName
            $policyType = $reportRow.PolicyType

            # Only process Settings Catalog policies (skip legacy deviceConfiguration)
            if ($policyType -ne 'SettingsCatalog') {
                continue
            }

            $settingsCatalogCount++

            Write-TestLog "Settings Catalog Policy: $policyName" -Type Info
            Write-TestLog "  Policy ID: $policyId" -Type Info
            Write-TestLog "  Status: $($reportRow.PolicyStatus)" -Type Info

            # Get full policy details with settings
            try {
                $policyUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$policyId')"
                $policy = Invoke-GraphRequestWithRetry -Uri $policyUri

                # Get settings for this policy
                $settingsUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$policyId')/settings"
                $settingsResult = Invoke-GraphRequestWithRetry -Uri $settingsUri

                # Extract settings
                $settings = [ordered]@{}
                $settingCount = 0

                if ($settingsResult.value) {
                    foreach ($setting in $settingsResult.value) {
                        # Settings Catalog uses a different structure than legacy profiles
                        # Each setting has settingInstance with settingDefinitionId and value
                        if ($setting.settingInstance) {
                            $settingDefinitionId = $setting.settingInstance.settingDefinitionId
                            $settingValue = $setting.settingInstance

                            # Convert to friendly format
                            if ($settingValue.simpleSettingValue) {
                                $value = $settingValue.simpleSettingValue.value
                            } elseif ($settingValue.choiceSettingValue) {
                                $value = $settingValue.choiceSettingValue.value
                            } else {
                                $value = $settingValue | ConvertTo-Json -Depth 3 -Compress
                            }

                            $friendlyValue = ConvertTo-FriendlyValue -Value $value -PropertyName $settingDefinitionId
                            $settings[$settingDefinitionId] = $friendlyValue
                            $settingCount++

                            # Log first 5 settings as examples
                            if ($settingCount -le 5) {
                                Write-TestLog "    $settingDefinitionId = $friendlyValue" -Type Info
                            }
                        }
                    }
                }

                if ($settingCount -gt 5) {
                    Write-TestLog "    ... and $($settingCount - 5) more settings" -Type Info
                }

                Write-TestLog "  Total configured settings: $settingCount" -Type Success

                # Export to JSON
                Export-SettingsToJson -ProfileName $policyName `
                                     -ProfileType 'SettingsCatalog' `
                                     -Settings $settings `
                                     -OutputPath $OutputPath

                Write-Host ""

            } catch {
                Write-TestLog "  ERROR collecting settings: $($_.Exception.Message)" -Type Error
                Write-Host ""
            }
        }

        if ($settingsCatalogCount -eq 0) {
            Write-TestLog "No Settings Catalog policies assigned to this device" -Type Info
        } else {
            Write-TestLog "Successfully collected $settingsCatalogCount Settings Catalog policies" -Type Success
        }

    } catch {
        Write-TestLog "ERROR during Settings Catalog collection: $($_.Exception.Message)" -Type Error
        Write-TestLog "Stack Trace: $($_.ScriptStackTrace)" -Type Error
    }

    Write-Host ""

    #endregion

    Write-TestLog "=== Test Complete ===" -Type Success
    Write-TestLog "Output files saved to: $OutputPath" -Type Success
    Write-TestLog "Log file saved to: $script:LogFilePath" -Type Success

} catch {
    Write-TestLog "FATAL ERROR: $($_.Exception.Message)" -Type Error
    Write-TestLog "Stack Trace: $($_.ScriptStackTrace)" -Type Error
    exit 1
}

#endregion
