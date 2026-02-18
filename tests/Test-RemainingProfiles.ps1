<#
.SYNOPSIS
    Test script to collect remaining Intune configuration profiles not covered by
    Test-ConfigProfileSettings.ps1 (Settings Catalog, ADMX, and other policy types).

.DESCRIPTION
    Uses the Reports API (DeviceConfigurationPolicyStatuses) to discover ALL policies
    assigned to a device, then collects settings for any that are NOT standard
    deviceConfiguration profiles (already handled by Test-ConfigProfileSettings.ps1).

    This covers:
    - Settings Catalog policies (/deviceManagement/configurationPolicies)
    - ADMX/Administrative Templates (/deviceManagement/groupPolicyConfigurations)
    - Any other policy types discovered via the report

.NOTES
    Author: Device DNA Test
    Date: 2026-02-13

    References:
    - Reports API: https://learn.microsoft.com/intune/intune-service/fundamentals/reports-export-graph-apis
    - Settings Catalog: https://learn.microsoft.com/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-get
    - Group Policy Configurations: https://learn.microsoft.com/graph/api/intune-grouppolicy-grouppolicyconfiguration-get
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

    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host "[$Type] " -NoNewline -ForegroundColor $colors[$Type]
    Write-Host $Message

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

            $allResults = @()
            if ($result.value) {
                $allResults += $result.value
            } else {
                return $result
            }

            while ($result.'@odata.nextLink') {
                Write-TestLog "  Following pagination link..." -Type Info
                $result = Invoke-MgGraphRequest -Uri $result.'@odata.nextLink' -Method GET -ErrorAction Stop
                $allResults += $result.value
            }

            return @{ value = $allResults }

        } catch {
            $retryCount++
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

            if ($isRetriable -and $retryCount -lt $MaxRetries) {
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

function Wait-ExportJobCompletion {
    param(
        [Parameter(Mandatory)]
        [string]$JobUri,

        [Parameter()]
        [int]$MaxWaitSeconds = 60
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollInterval = 500
    $maxPollInterval = 4000

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

    $filter = "deviceName eq '$DeviceName'"
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$filter&`$select=id,deviceName,operatingSystem"
    $result = Invoke-GraphRequestWithRetry -Uri $uri

    if ($result.value -and $result.value.Count -gt 0) {
        $device = $result.value[0]
        Write-TestLog "  Found device: $($device.deviceName) ($($device.operatingSystem))" -Type Success
        Write-TestLog "  Managed Device ID: $($device.id)" -Type Success
        return $device.id
    }

    throw "Device '$DeviceName' not found in Intune managed devices"
}

#endregion

#region Main Script

try {
    Write-TestLog "=== Remaining Profiles Collection Test ===" -Type Info
    Write-Host ""

    # Ensure output directory exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Initialize log file
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFilePath = Join-Path $OutputPath "Test-RemainingProfiles_$timestamp.log"
    Add-Content -Path $script:LogFilePath -Value "=== Remaining Profiles Collection Test ===" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "Device: $DeviceName" -ErrorAction SilentlyContinue
    Add-Content -Path $script:LogFilePath -Value "" -ErrorAction SilentlyContinue

    Write-TestLog "Log file: $script:LogFilePath" -Type Info
    Write-Host ""

    # Check Graph connection
    Write-TestLog "Checking Microsoft Graph connection..." -Type Info
    try {
        $context = Get-MgContext
        if (-not $context) { throw "Not connected" }
        Write-TestLog "  Connected as: $($context.Account)" -Type Success
    } catch {
        Write-TestLog "  Connecting..." -Type Warning
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All"
        Write-TestLog "  Connected" -Type Success
    }
    Write-Host ""

    # Get managed device ID
    $managedDeviceId = Get-ManagedDeviceId -DeviceName $DeviceName
    Write-Host ""

    #region Phase 1 - Reports API Discovery

    Write-TestLog "=== Phase 1: Reports API Discovery ===" -Type Info
    Write-TestLog "Creating export job for DeviceConfigurationPolicyStatuses..." -Type Info

    $reportBody = @{
        reportName = "DeviceConfigurationPolicyStatuses"
        filter = "IntuneDeviceId eq '$managedDeviceId'"
        format = "csv"
    } | ConvertTo-Json

    $exportJobUri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"
    $exportJob = Invoke-MgGraphRequest -Uri $exportJobUri -Method POST -Body $reportBody -ContentType "application/json" -ErrorAction Stop
    Write-TestLog "  Export job created: $($exportJob.id)" -Type Success

    $jobUri = "$exportJobUri/$($exportJob.id)"
    $jobStatus = Wait-ExportJobCompletion -JobUri $jobUri -MaxWaitSeconds 60

    if (-not $jobStatus) {
        throw "Export job failed or timed out"
    }

    # Download and parse report
    $reportUrl = $jobStatus.url
    $tempGuid = [guid]::NewGuid()
    $tempZip = Join-Path $env:TEMP "Test_Remaining_$tempGuid.zip"
    $tempExtract = Join-Path $env:TEMP "Test_Remaining_$tempGuid"

    Invoke-WebRequest -Uri $reportUrl -Method Get -OutFile $tempZip -ErrorAction Stop
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop
    $csvFile = Get-ChildItem -Path $tempExtract -Filter "*.csv" -File | Select-Object -First 1

    if (-not $csvFile) { throw "No CSV file found in ZIP archive" }

    $reportRows = @(Import-Csv -Path $csvFile.FullName)

    # Cleanup temp files
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-TestLog "  Parsed $($reportRows.Count) rows from report" -Type Success
    Write-Host ""

    # Deduplicate by PolicyId
    $uniquePolicies = @{}
    foreach ($row in $reportRows) {
        $polId = $row.PolicyId
        if (-not $uniquePolicies.ContainsKey($polId)) {
            $uniquePolicies[$polId] = $row
        }
        elseif ([string]::IsNullOrEmpty($uniquePolicies[$polId].UPN) -and -not [string]::IsNullOrEmpty($row.UPN)) {
            $uniquePolicies[$polId] = $row
        }
    }

    Write-TestLog "Deduplicated to $($uniquePolicies.Count) unique policies" -Type Success
    Write-Host ""

    # Log ALL column names from CSV
    if ($reportRows.Count -gt 0) {
        $columns = $reportRows[0].PSObject.Properties.Name -join ', '
        Write-TestLog "CSV columns: $columns" -Type Info
    }
    Write-Host ""

    # Log ALL unique PolicyType values with counts
    Write-TestLog "=== PolicyType Distribution ===" -Type Info
    $typeGroups = @{}
    foreach ($polId in $uniquePolicies.Keys) {
        $row = $uniquePolicies[$polId]
        $pType = if ($row.PolicyType) { $row.PolicyType } else { "(empty)" }
        if (-not $typeGroups.ContainsKey($pType)) {
            $typeGroups[$pType] = @()
        }
        $typeGroups[$pType] += $row.PolicyName
    }

    foreach ($pType in ($typeGroups.Keys | Sort-Object)) {
        Write-TestLog "  $pType : $($typeGroups[$pType].Count) policies" -Type Info
        # Log first 3 example names for each type
        $examples = $typeGroups[$pType] | Select-Object -First 3
        foreach ($name in $examples) {
            Write-TestLog "    - $name" -Type Info
        }
        if ($typeGroups[$pType].Count -gt 3) {
            Write-TestLog "    ... and $($typeGroups[$pType].Count - 3) more" -Type Info
        }
    }
    Write-Host ""

    #endregion

    #region Phase 2 - Identify what's already collected

    Write-TestLog "=== Phase 2: Cross-reference with deviceConfigurations ===" -Type Info

    # Get all deviceConfigurations IDs (what the first test script covers)
    $legacyProfiles = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?`$select=id,displayName"
    $legacyIds = @{}
    foreach ($lp in $legacyProfiles.value) {
        $legacyIds[$lp.id] = $lp.displayName
    }
    Write-TestLog "  Found $($legacyIds.Count) deviceConfiguration profiles in tenant" -Type Info

    # Separate policies into: already covered vs needs collection
    $alreadyCovered = @()
    $needsCollection = @()

    foreach ($polId in $uniquePolicies.Keys) {
        $row = $uniquePolicies[$polId]
        if ($legacyIds.ContainsKey($polId)) {
            $alreadyCovered += $row
        } else {
            $needsCollection += $row
        }
    }

    Write-TestLog "  Already covered by Test-ConfigProfileSettings: $($alreadyCovered.Count)" -Type Success
    Write-TestLog "  Needs collection (this script): $($needsCollection.Count)" -Type Info
    Write-Host ""

    #endregion

    #region Phase 3 - Collect remaining profiles

    Write-TestLog "=== Phase 3: Collecting Remaining Profiles ===" -Type Info
    Write-Host ""

    $collectedCount = 0
    $failedCount = 0

    foreach ($row in ($needsCollection | Sort-Object { $_.PolicyName })) {
        $polId = $row.PolicyId
        $polName = $row.PolicyName
        $polType = $row.PolicyType
        $polStatus = $row.PolicyStatus

        Write-TestLog "Policy: $polName" -Type Info
        Write-TestLog "  ID: $polId" -Type Info
        Write-TestLog "  Type: $polType" -Type Info
        Write-TestLog "  Status: $polStatus" -Type Info

        try {
            # Try Settings Catalog endpoint first
            # Reference: https://learn.microsoft.com/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-get
            $policyUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$polId')"
            $policy = Invoke-MgGraphRequest -Uri $policyUri -Method GET -ErrorAction Stop

            Write-TestLog "  Found in configurationPolicies (Settings Catalog)" -Type Success

            # Get settings for this policy
            $settingsUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$polId')/settings"
            $settingsResult = Invoke-GraphRequestWithRetry -Uri $settingsUri

            $settings = [ordered]@{}
            $settingCount = 0

            if ($settingsResult.value) {
                foreach ($setting in $settingsResult.value) {
                    if ($setting.settingInstance) {
                        $defId = $setting.settingInstance.settingDefinitionId
                        $inst = $setting.settingInstance

                        # Extract value based on setting type
                        $value = $null
                        if ($inst.simpleSettingValue) {
                            $value = $inst.simpleSettingValue.value
                        } elseif ($inst.choiceSettingValue) {
                            $value = $inst.choiceSettingValue.value
                            # Include children if present
                            if ($inst.choiceSettingValue.children -and $inst.choiceSettingValue.children.Count -gt 0) {
                                $value = $inst | ConvertTo-Json -Depth 5 -Compress
                            }
                        } elseif ($inst.simpleSettingCollectionValue) {
                            $value = ($inst.simpleSettingCollectionValue | ForEach-Object { $_.value }) -join ', '
                        } elseif ($inst.groupSettingCollectionValue) {
                            $value = $inst | ConvertTo-Json -Depth 5 -Compress
                        } else {
                            $value = $inst | ConvertTo-Json -Depth 5 -Compress
                        }

                        $settings[$defId] = $value
                        $settingCount++

                        if ($settingCount -le 3) {
                            # Truncate long values for log readability
                            $logValue = "$value"
                            if ($logValue.Length -gt 100) {
                                $logValue = $logValue.Substring(0, 100) + "..."
                            }
                            Write-TestLog "    $defId = $logValue" -Type Info
                        }
                    }
                }
            }

            if ($settingCount -gt 3) {
                Write-TestLog "    ... and $($settingCount - 3) more settings" -Type Info
            }

            Write-TestLog "  Total settings: $settingCount" -Type Success

            Export-SettingsToJson -ProfileName $polName `
                                 -ProfileType "SettingsCatalog ($polType)" `
                                 -Settings $settings `
                                 -OutputPath $OutputPath

            $collectedCount++

        } catch {
            # Settings Catalog endpoint failed, try groupPolicyConfigurations
            try {
                $gpUri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$polId"
                $gpPolicy = Invoke-MgGraphRequest -Uri $gpUri -Method GET -ErrorAction Stop

                Write-TestLog "  Found in groupPolicyConfigurations (ADMX)" -Type Success

                # Get definition values (the configured settings)
                $defValuesUri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$polId/definitionValues?`$expand=definition"
                $defValues = Invoke-GraphRequestWithRetry -Uri $defValuesUri

                $settings = [ordered]@{}
                $settingCount = 0

                if ($defValues.value) {
                    foreach ($dv in $defValues.value) {
                        $defName = "(unknown)"
                        if ($dv.definition) {
                            $defName = $dv.definition.displayName
                            if (-not $defName) {
                                $defName = $dv.definition.classType + ": " + $dv.definition.categoryPath
                            }
                        }

                        $settings[$defName] = [ordered]@{
                            enabled = $dv.enabled
                            definitionId = $dv.definition.id
                            categoryPath = $dv.definition.categoryPath
                        }
                        $settingCount++

                        if ($settingCount -le 3) {
                            $enabledText = if ($dv.enabled) { "Enabled" } else { "Disabled" }
                            Write-TestLog "    $defName = $enabledText" -Type Info
                        }
                    }
                }

                if ($settingCount -gt 3) {
                    Write-TestLog "    ... and $($settingCount - 3) more settings" -Type Info
                }

                Write-TestLog "  Total settings: $settingCount" -Type Success

                Export-SettingsToJson -ProfileName $polName `
                                     -ProfileType "ADMX/GroupPolicy ($polType)" `
                                     -Settings $settings `
                                     -OutputPath $OutputPath

                $collectedCount++

            } catch {
                # Neither endpoint worked
                Write-TestLog "  SKIPPED: Not found in configurationPolicies or groupPolicyConfigurations" -Type Warning
                Write-TestLog "  Error: $($_.Exception.Message)" -Type Warning
                $failedCount++
            }
        }

        Write-Host ""
    }

    #endregion

    Write-TestLog "=== Summary ===" -Type Info
    Write-TestLog "  Total policies in report: $($uniquePolicies.Count)" -Type Info
    Write-TestLog "  Already covered (legacy test): $($alreadyCovered.Count)" -Type Info
    Write-TestLog "  Collected by this script: $collectedCount" -Type Success
    Write-TestLog "  Failed/Skipped: $failedCount" -Type $(if ($failedCount -gt 0) { 'Warning' } else { 'Success' })
    Write-TestLog "  Output: $OutputPath" -Type Info
    Write-TestLog "  Log: $script:LogFilePath" -Type Info
    Write-TestLog "=== Test Complete ===" -Type Success

} catch {
    Write-TestLog "FATAL ERROR: $($_.Exception.Message)" -Type Error
    Write-TestLog "Stack Trace: $($_.ScriptStackTrace)" -Type Error
    exit 1
}

#endregion
