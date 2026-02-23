<#
.SYNOPSIS
    Device DNA - Intune Module
.DESCRIPTION
    Microsoft Graph API and Intune data collection.
    Includes authentication, device discovery, configuration profiles, applications,
    compliance policies, and assignment logic.
.NOTES
    Module: Intune.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

<#
.SYNOPSIS
    Graph API and Intune Collection Functions for DeviceDNA
.DESCRIPTION
    This module provides Microsoft Graph API authentication and Intune data collection
    functionality for the DeviceDNA script.
.NOTES
    Version: 1.0.0
    Requires: PowerShell 5.1+
    Graph API Scopes Required:
    - Device.Read.All
    - DeviceManagementConfiguration.Read.All
    - DeviceManagementApps.Read.All
    - DeviceManagementManagedDevices.Read.All
    - Group.Read.All
    - User.Read
#>

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Core wrapper for Microsoft Graph API calls using Microsoft.Graph.Authentication module.
    .DESCRIPTION
        Uses Invoke-MgGraphRequest from the Microsoft.Graph.Authentication module with built-in handling for:
        - Auto-pagination via @odata.nextLink
        - 429 (throttling) retry with exponential backoff
        - 5xx retry with exponential backoff (max 3 retries)
        - Graceful failure with logging
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE, PUT).
    .PARAMETER Uri
        Full URI for the Graph API endpoint.
    .PARAMETER Body
        Optional request body (hashtable, will be converted automatically).
    .OUTPUTS
        Combined results for paginated responses, or single response object.
    .EXAMPLE
        Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/devices"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter()]
        [object]$Body
    )

    $maxRetries = 3
    $allResults = @()
    $isCollectionResponse = $false

    try {
        # Validate we have a Graph connection
        if (-not $script:GraphConnected) {
            Write-StatusMessage "No Graph API connection. Call Connect-GraphAPI first." -Type Error
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API call attempted without connection" }
            return $null
        }

        $currentUri = $Uri

        do {
            $retryCount = 0
            $success = $false

            while (-not $success -and $retryCount -lt $maxRetries) {
                try {
                    $invokeParams = @{
                        Method      = $Method
                        Uri         = $currentUri
                        ErrorAction = 'Stop'
                    }

                    # Add body for methods that support it
                    if ($Body -and $Method -in @('POST', 'PATCH', 'PUT')) {
                        $invokeParams['Body'] = $Body
                    }

                    $response = Invoke-MgGraphRequest @invokeParams
                    $success = $true

                    # Collect results - Graph API returns collections wrapped in { value: [...] }
                    # Use IDictionary to handle Hashtable, OrderedDictionary, Dictionary<TKey,TValue>, etc.
                    # Invoke-MgGraphRequest may return different dictionary types depending on PS/module version.
                    $hasValueProperty = $false
                    if ($response -is [System.Collections.IDictionary]) {
                        $hasValueProperty = $response.Contains('value')
                    }
                    elseif ($null -ne $response) {
                        $hasValueProperty = $null -ne $response.PSObject.Properties['value']
                    }

                    if ($hasValueProperty) {
                        # Collection response - extract items from value array
                        # Note: value might be empty array @() which is valid
                        $isCollectionResponse = $true
                        # Use IDictionary indexer for dictionaries, dot notation for PSCustomObject
                        $items = if ($response -is [System.Collections.IDictionary]) { $response['value'] } else { $response.value }
                        if ($null -ne $items) {
                            $allResults += @($items)
                        }
                    }
                    elseif ($response -and -not $response.'@odata.nextLink') {
                        # Single object response (not a collection) - e.g., GET /devices/{id}
                        $allResults += $response
                    }

                    # Check for pagination
                    $currentUri = $response.'@odata.nextLink'
                }
                catch {
                    $errorMessage = $_.Exception.Message

                    # Check for throttling (429)
                    if ($errorMessage -match '429' -or $errorMessage -match 'throttl') {
                        $waitTime = [math]::Pow(2, $retryCount) * 10
                        Write-StatusMessage "Graph API throttled (429). Waiting $waitTime seconds..." -Type Warning
                        Start-Sleep -Seconds $waitTime
                        $retryCount++
                    }
                    # Check for server errors (5xx)
                    elseif ($errorMessage -match '5\d\d' -or $errorMessage -match 'server error') {
                        $waitTime = [math]::Pow(2, $retryCount) * 2
                        Write-StatusMessage "Graph API server error. Retry $($retryCount + 1)/$maxRetries after $waitTime seconds..." -Type Warning
                        Start-Sleep -Seconds $waitTime
                        $retryCount++
                    }
                    # Check for auth errors
                    elseif ($errorMessage -match '401' -or $errorMessage -match 'unauthorized') {
                        Write-StatusMessage "Graph API unauthorized (401). Token may be invalid or expired." -Type Error
                        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API 401 Unauthorized: $errorMessage" }
                        return $null
                    }
                    elseif ($errorMessage -match '403' -or $errorMessage -match 'forbidden') {
                        Write-StatusMessage "Graph API forbidden (403). Insufficient permissions." -Type Error
                        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API 403 Forbidden: $errorMessage - URI: $currentUri" }
                        return $null
                    }
                    elseif ($errorMessage -match '404' -or $errorMessage -match 'not found') {
                        Write-StatusMessage "Graph API resource not found (404): $currentUri" -Type Warning
                        $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Graph API 404 Not Found: $currentUri" }
                        return $null
                    }
                    elseif ($errorMessage -match '400' -or $errorMessage -match 'bad request' -or $errorMessage -match 'BadRequest') {
                        Write-StatusMessage "Graph API bad request (400). Check query syntax." -Type Error
                        Write-StatusMessage "  URI: $currentUri" -Type Error
                        Write-StatusMessage "  Error: $errorMessage" -Type Error
                        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API 400 BadRequest: $errorMessage - URI: $currentUri" }
                        return $null
                    }
                    else {
                        # Other errors - log and fail with full context
                        Write-StatusMessage "Graph API error: $errorMessage" -Type Error
                        Write-StatusMessage "  URI: $currentUri" -Type Error
                        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API error: $errorMessage - URI: $currentUri" }
                        return $null
                    }
                }
            }

            if (-not $success) {
                Write-StatusMessage "Graph API request failed after $maxRetries retries" -Type Error
                $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph API request failed after $maxRetries retries - URI: $currentUri" }
                return $null
            }

        } while ($currentUri) # Continue while there are more pages

        # Return results
        # Only unwrap single-item results for single-object GETs (e.g., /devices/{id}).
        # Collection endpoints (with 'value' array) always return arrays, even if 1 item.
        if ($allResults.Count -eq 1 -and $Method -eq 'GET' -and -not $isCollectionResponse) {
            return $allResults[0]
        }
        return $allResults
    }
    catch {
        Write-StatusMessage "Unexpected error in Invoke-GraphRequest: $($_.Exception.Message)" -Type Error
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Invoke-GraphRequest error: $($_.Exception.Message)" }
        return $null
    }
}

function Wait-ExportJobCompletion {
    <#
    .SYNOPSIS
        Polls a Reports API export job until completion using exponential backoff.
    .DESCRIPTION
        Uses exponential backoff to efficiently poll export jobs: starts at 500ms,
        increases by 1.5x each iteration, caps at 4 seconds. Reduces API calls while
        maintaining responsiveness.
    .PARAMETER JobUri
        The URI to poll for job status.
    .PARAMETER MaxWaitSeconds
        Maximum time to wait in seconds (default: 60).
    .OUTPUTS
        Job status object if completed, $null if timeout/failed.
    .NOTES
        Polling strategy: 0.5s → 0.75s → 1.1s → 1.7s → 2.5s → 4s (capped)
        Typical job completion: 5-15 seconds
        Source: https://learn.microsoft.com/intune/intune-service/fundamentals/reports-export-graph-apis
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
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
                Write-DeviceDNALog -Message "Export job completed after $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds" -Component "Wait-ExportJobCompletion" -Type 1
                return $jobStatus
            }
            elseif ($jobStatus.status -eq 'failed') {
                Write-DeviceDNALog -Message "Export job failed: $($jobStatus.errorMessage)" -Component "Wait-ExportJobCompletion" -Type 3
                return $null
            }

            # Exponential backoff: 0.5s → 0.75s → 1.1s → 1.7s → 2.5s → 4s (capped)
            $pollInterval = [Math]::Min([int]($pollInterval * 1.5), $maxPollInterval)
        }
        catch {
            Write-DeviceDNALog -Message "Error polling export job: $($_.Exception.Message)" -Component "Wait-ExportJobCompletion" -Type 2
            return $null
        }
    }

    Write-DeviceDNALog -Message "Export job timeout after $MaxWaitSeconds seconds" -Component "Wait-ExportJobCompletion" -Type 2
    return $null
}

function Connect-GraphAPI {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph using the Microsoft.Graph.Authentication module.
    .DESCRIPTION
        Uses Connect-MgGraph for authentication, which:
        - Supports MFA and Conditional Access policies
        - Opens browser for interactive authentication
        - Handles enterprise auth requirements automatically
        - Caches tokens for session reuse
    .PARAMETER TenantId
        Azure AD Tenant ID (GUID or domain name). Optional.
    .OUTPUTS
        $true on success, $false on failure.
    .EXAMPLE
        $connected = Connect-GraphAPI -TenantId "contoso.onmicrosoft.com"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$TenantId
    )

    try {
        # Check if Microsoft.Graph.Authentication module is installed
        # (included in full Microsoft.Graph SDK, or can be installed standalone)
        $graphModule = Get-Module -ListAvailable Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
        if (-not $graphModule) {
            Write-StatusMessage "Microsoft.Graph.Authentication module not installed" -Type Warning
            Write-StatusMessage "Attempting to install Microsoft.Graph.Authentication (CurrentUser scope)..." -Type Progress
            Write-DeviceDNALog -Message "Microsoft.Graph.Authentication module missing - attempting auto-install" -Component "Connect-GraphAPI" -Type 2

            try {
                Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                $graphModule = Get-Module -ListAvailable Microsoft.Graph.Authentication -ErrorAction SilentlyContinue

                if (-not $graphModule) {
                    throw "Install-Module completed but Microsoft.Graph.Authentication was not found afterward."
                }

                Write-StatusMessage "Installed Microsoft.Graph.Authentication successfully" -Type Success
                Write-DeviceDNALog -Message "Auto-install of Microsoft.Graph.Authentication succeeded" -Component "Connect-GraphAPI" -Type 1
            }
            catch {
                Write-StatusMessage "Failed to install Microsoft.Graph.Authentication automatically" -Type Error
                Write-Host ""
                Write-Host "  The Microsoft.Graph.Authentication module is required for Intune data collection." -ForegroundColor Yellow
                Write-Host "  Install it with:" -ForegroundColor Gray
                Write-Host "    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" -ForegroundColor Cyan
                Write-Host ""
                Write-DeviceDNALog -Message "Auto-install failed: $($_.Exception.Message)" -Component "Connect-GraphAPI" -Type 3
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Microsoft.Graph.Authentication module not installed - Intune collection unavailable" }
                return $false
            }
        }

        Write-StatusMessage "Connecting to Microsoft Graph (browser authentication)..." -Type Progress
        Write-DeviceDNALog -Message "Initiating Graph connection" -Component "Connect-GraphAPI" -Type 1
        Write-Host ""

        $connectParams = @{
            Scopes      = $script:RequiredGraphScopes
            ErrorAction = 'Stop'
        }

        if (-not [string]::IsNullOrEmpty($TenantId)) {
            $connectParams['TenantId'] = $TenantId
            Write-DeviceDNALog -Message "Using tenant ID: $TenantId" -Component "Connect-GraphAPI" -Type 1
        }

        Write-DeviceDNALog -Message "Requested scopes: $($script:RequiredGraphScopes -join ', ')" -Component "Connect-GraphAPI" -Type 1

        # Connect to Graph - this will open browser for authentication
        $connectStart = Get-Date
        Connect-MgGraph @connectParams | Out-Null
        $connectDuration = (Get-Date) - $connectStart

        $script:GraphConnected = $true
        Write-StatusMessage "Connected to Microsoft Graph successfully" -Type Success
        Write-DeviceDNALog -Message "Graph connection established in $($connectDuration.TotalSeconds.ToString('F1'))s" -Component "Connect-GraphAPI" -Type 1

        return $true
    }
    catch {
        Write-StatusMessage "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Graph connection failed: $($_.Exception.Message)" -Component "Connect-GraphAPI" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Graph connection failed: $($_.Exception.Message)" }
        $script:GraphConnected = $false
        return $false
    }
}

function Disconnect-GraphAPI {
    <#
    .SYNOPSIS
        Disconnects from Microsoft Graph.
    #>
    [CmdletBinding()]
    param()

    try {
        if ($script:GraphConnected) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $script:GraphConnected = $false
            Write-StatusMessage "Disconnected from Microsoft Graph" -Type Info
        }
    }
    catch {
        # Ignore disconnect errors
    }
}

function Get-GraphPermissions {
    <#
    .SYNOPSIS
        Validates that required Graph permissions are available.
    .DESCRIPTION
        - Checks the current Graph context for granted scopes
        - Compares against required scopes for Intune data collection
        - Returns object with permission status and details
    .OUTPUTS
        PSCustomObject with: HasAllPermissions, GrantedScopes, MissingScopes
    .EXAMPLE
        $permissions = Get-GraphPermissions
        if (-not $permissions.HasAllPermissions) {
            Write-Warning "Missing scopes: $($permissions.MissingScopes -join ', ')"
        }
    #>
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        HasAllPermissions = $false
        GrantedScopes     = @()
        MissingScopes     = @()
    }

    try {
        if (-not $script:GraphConnected) {
            Write-StatusMessage "No Graph connection available to check permissions" -Type Warning
            $result.MissingScopes = $script:RequiredGraphScopes
            return $result
        }

        # Get current Graph context
        $context = Get-MgContext -ErrorAction SilentlyContinue

        if (-not $context) {
            Write-StatusMessage "Could not retrieve Graph context" -Type Warning
            $result.MissingScopes = $script:RequiredGraphScopes
            return $result
        }

        # Get granted scopes from context
        $grantedScopes = @($context.Scopes)
        $result.GrantedScopes = $grantedScopes

        # Compare against required scopes
        $missingScopes = @()
        foreach ($requiredScope in $script:RequiredGraphScopes) {
            # Check for exact match or elevated permission
            $hasScope = $grantedScopes | Where-Object {
                $_ -eq $requiredScope -or
                $_ -eq $requiredScope.Replace('.Read.', '.ReadWrite.') -or
                $_ -eq 'Directory.Read.All' -or
                $_ -eq 'Directory.ReadWrite.All'
            }

            if (-not $hasScope) {
                $missingScopes += $requiredScope
            }
        }

        $result.MissingScopes = $missingScopes
        $result.HasAllPermissions = ($missingScopes.Count -eq 0)

        if ($result.HasAllPermissions) {
            Write-StatusMessage "All required Graph permissions are granted" -Type Success
        }
        else {
            Write-StatusMessage "Missing Graph permissions: $($missingScopes -join ', ')" -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Missing Graph permissions: $($missingScopes -join ', ')" }
        }

        return $result
    }
    catch {
        Write-StatusMessage "Error checking Graph permissions: $($_.Exception.Message)" -Type Error
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error checking Graph permissions: $($_.Exception.Message)" }
        $result.MissingScopes = $script:RequiredGraphScopes
        return $result
    }
}

function Find-AzureADDevice {
    <#
    .SYNOPSIS
        Finds an Azure AD device by display name or device ID.
    .DESCRIPTION
        Queries Microsoft Graph to find a device in Azure AD.
        Uses the same pattern as the working DeviceDNA implementation.
    .PARAMETER DeviceName
        The display name of the device to find.
    .PARAMETER DeviceId
        Optional Azure AD device ID (GUID) for direct lookup.
    .OUTPUTS
        Device object with: id, deviceId, displayName, trustType, isManaged
    .EXAMPLE
        $device = Find-AzureADDevice -DeviceName "DESKTOP-ABC123"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,

        [Parameter()]
        [string]$DeviceId
    )

    try {
        Write-StatusMessage "Searching for Azure AD device: $DeviceName" -Type Progress

        $device = $null

        # Search by device name - matching working implementation exactly
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$DeviceName'"
        Write-DeviceDNALog -Message "Graph API call: GET $uri" -Component "Find-AzureADDevice" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        $resultCount = if ($response.value) { $response.value.Count } else { 0 }
        Write-DeviceDNALog -Message "Graph API response: $resultCount device(s) returned in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Find-AzureADDevice" -Type 1

        if ($response.value.Count -gt 0) {
            $device = $response.value[0]

            if ($response.value.Count -gt 1) {
                Write-DeviceDNALog -Message "Multiple Azure AD devices found ($resultCount) with name '$DeviceName'" -Component "Find-AzureADDevice" -Type 2

                if ($DeviceId) {
                    # Best case: exact match by hardware device ID
                    Write-DeviceDNALog -Message "Filtering by DeviceId: $DeviceId" -Component "Find-AzureADDevice" -Type 1
                    $match = $response.value | Where-Object { $_.deviceId -eq $DeviceId }
                    if ($match) { $device = $match }
                }
                else {
                    # No DeviceId provided — disambiguate by preferring managed, then most recent sign-in
                    # Stale/orphaned Azure AD records often have isManaged=false
                    $managedDevices = @($response.value | Where-Object { $_.isManaged -eq $true })
                    if ($managedDevices.Count -eq 1) {
                        $device = $managedDevices[0]
                        Write-DeviceDNALog -Message "Selected device with isManaged=True (deviceId: $($device.deviceId))" -Component "Find-AzureADDevice" -Type 1
                    }
                    elseif ($managedDevices.Count -gt 1) {
                        # Multiple managed devices — pick most recently active
                        $sorted = $managedDevices | Sort-Object -Property approximateLastSignInDateTime -Descending
                        $device = $sorted[0]
                        Write-DeviceDNALog -Message "Multiple managed devices found ($($managedDevices.Count)), selected most recently active (deviceId: $($device.deviceId), lastSignIn: $($device.approximateLastSignInDateTime))" -Component "Find-AzureADDevice" -Type 2
                    }
                    else {
                        # No managed devices — pick most recently active overall
                        $sorted = $response.value | Sort-Object -Property approximateLastSignInDateTime -Descending
                        $device = $sorted[0]
                        Write-DeviceDNALog -Message "No managed devices found among $resultCount results, selected most recently active (deviceId: $($device.deviceId), lastSignIn: $($device.approximateLastSignInDateTime))" -Component "Find-AzureADDevice" -Type 2
                    }
                }
            }
        }

        if ($device) {
            Write-StatusMessage "Found Azure AD device: $($device.displayName)" -Type Success

            # Log the two critical IDs for device identity resolution tracking
            Write-DeviceDNALog -Message "Azure AD ObjectId (for group queries): $($device.id)" -Component "Find-AzureADDevice" -Type 1
            Write-DeviceDNALog -Message "Azure AD DeviceId (for Intune lookup): $(if ($device.deviceId) { $device.deviceId } else { 'NULL - not available' })" -Component "Find-AzureADDevice" -Type $(if ($device.deviceId) { 1 } else { 2 })
            Write-DeviceDNALog -Message "Device TrustType: $($device.trustType), IsManaged: $($device.isManaged), IsCompliant: $($device.isCompliant)" -Component "Find-AzureADDevice" -Type 1

            return [PSCustomObject]@{
                # id = Azure AD object ID - use for /devices/{id}/memberOf
                ObjectId                      = $device.id
                # deviceId = hardware device ID GUID - use to match azureADDeviceId on Intune managed devices
                DeviceId                      = $device.deviceId
                DisplayName                   = $device.displayName
                OperatingSystem               = $device.operatingSystem
                OSVersion                     = $device.operatingSystemVersion
                TrustType                     = $device.trustType
                IsManaged                     = $device.isManaged
                IsCompliant                   = $device.isCompliant
                ApproximateLastSignInDateTime = $device.approximateLastSignInDateTime
                RegistrationDateTime          = $device.registrationDateTime
            }
        }
        else {
            Write-StatusMessage "Azure AD device not found: $DeviceName" -Type Warning
            Write-DeviceDNALog -Message "Device not found in Azure AD. Device may not be Azure AD joined/registered." -Component "Find-AzureADDevice" -Type 2
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Azure AD device not found: $DeviceName. The device may not be Azure AD joined/registered." }
            return $null
        }
    }
    catch {
        Write-StatusMessage "Error finding Azure AD device: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Graph API error: $($_.Exception.Message)" -Component "Find-AzureADDevice" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error finding Azure AD device: $($_.Exception.Message)" }
        return $null
    }
}

function Get-IntuneDevice {
    <#
    .SYNOPSIS
        Gets Intune managed device information.
    .DESCRIPTION
        Queries Microsoft Graph for Intune managed device details.
        Uses beta endpoint matching the working DeviceDNA implementation.
    .PARAMETER DeviceName
        The name of the device to find.
    .PARAMETER AzureADDeviceId
        The Azure AD device ID (hardware GUID) to filter by.
    .OUTPUTS
        Managed device object with: id, deviceName, complianceState, lastSyncDateTime, managementAgent
    .EXAMPLE
        $managedDevice = Get-IntuneDevice -AzureADDeviceId "12345678-1234-1234-1234-123456789abc"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DeviceName,

        [Parameter()]
        [string]$AzureADDeviceId
    )

    try {
        Write-StatusMessage "Searching for Intune managed device..." -Type Progress

        $managedDevice = $null

        # Prefer searching by Azure AD Device ID for accuracy
        if (-not [string]::IsNullOrEmpty($AzureADDeviceId)) {
            $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=azureADDeviceId eq '$AzureADDeviceId'&`$select=id,deviceName,managementState,complianceState,lastSyncDateTime,managementAgent,enrolledDateTime,operatingSystem,osVersion,userPrincipalName,azureADDeviceId"
            Write-DeviceDNALog -Message "Graph API call: GET managedDevices by azureADDeviceId" -Component "Get-IntuneDevice" -Type 1
            Write-DeviceDNALog -Message "Filter: azureADDeviceId eq '$AzureADDeviceId'" -Component "Get-IntuneDevice" -Type 1 -IsDebug

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            $queryDuration = (Get-Date) - $queryStart

            $resultCount = if ($response.value) { $response.value.Count } else { 0 }
            Write-DeviceDNALog -Message "Graph API response: $resultCount device(s) returned in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-IntuneDevice" -Type 1

            if ($response.value -and $response.value.Count -gt 0) {
                $managedDevice = $response.value[0]
                Write-DeviceDNALog -Message "Device found by azureADDeviceId lookup" -Component "Get-IntuneDevice" -Type 1
            }
        }

        # Fallback to device name search
        if (-not $managedDevice -and -not [string]::IsNullOrEmpty($DeviceName)) {
            Write-DeviceDNALog -Message "Falling back to device name lookup: $DeviceName" -Component "Get-IntuneDevice" -Type 2
            $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=deviceName eq '$DeviceName'&`$select=id,deviceName,managementState,complianceState,lastSyncDateTime,managementAgent,enrolledDateTime,operatingSystem,osVersion,userPrincipalName,azureADDeviceId"

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            $queryDuration = (Get-Date) - $queryStart

            $resultCount = if ($response.value) { $response.value.Count } else { 0 }
            Write-DeviceDNALog -Message "Graph API response: $resultCount device(s) returned in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-IntuneDevice" -Type 1

            if ($response.value -and $response.value.Count -gt 0) {
                $managedDevice = $response.value[0]
                Write-DeviceDNALog -Message "Device found by name lookup" -Component "Get-IntuneDevice" -Type 1
            }
        }

        if ($managedDevice) {
            Write-StatusMessage "Found Intune managed device: $($managedDevice.deviceName)" -Type Success
            Write-DeviceDNALog -Message "Intune Device ID: $($managedDevice.id)" -Component "Get-IntuneDevice" -Type 1
            Write-DeviceDNALog -Message "Compliance State: $($managedDevice.complianceState), Management State: $($managedDevice.managementState)" -Component "Get-IntuneDevice" -Type 1
            Write-DeviceDNALog -Message "Last Sync: $($managedDevice.lastSyncDateTime), Management Agent: $($managedDevice.managementAgent)" -Component "Get-IntuneDevice" -Type 1

            return [PSCustomObject]@{
                Id                = $managedDevice.id
                AzureADDeviceId   = $managedDevice.azureADDeviceId
                DeviceName        = $managedDevice.deviceName
                ComplianceState   = $managedDevice.complianceState
                ManagementState   = $managedDevice.managementState
                LastSyncDateTime  = $managedDevice.lastSyncDateTime
                ManagementAgent   = $managedDevice.managementAgent
                EnrolledDateTime  = $managedDevice.enrolledDateTime
                OperatingSystem   = $managedDevice.operatingSystem
                OSVersion         = $managedDevice.osVersion
                UserPrincipalName = $managedDevice.userPrincipalName
            }
        }
        else {
            Write-StatusMessage "Intune managed device not found. Device may be Azure AD joined but not Intune enrolled." -Type Warning
            Write-DeviceDNALog -Message "Device not found in Intune. May be Azure AD joined but not Intune enrolled." -Component "Get-IntuneDevice" -Type 2
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Device not found in Intune. It may be Azure AD joined but not Intune enrolled." }
            return $null
        }
    }
    catch {
        Write-StatusMessage "Error finding Intune device: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Graph API error: $($_.Exception.Message)" -Component "Get-IntuneDevice" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error finding Intune device: $($_.Exception.Message)" }
        return $null
    }
}

function Get-DeviceGroupMemberships {
    <#
    .SYNOPSIS
        Gets all group memberships for an Azure AD device.
    .DESCRIPTION
        Queries group membership for a device object using /memberOf endpoint.
        Matches the working DeviceDNA implementation from Get-DeviceGroupMemberships.ps1.
    .PARAMETER AzureADObjectId
        The Azure AD device object ID (the 'id' property, not 'deviceId').
    .OUTPUTS
        Array of group objects with: ObjectId, DisplayName, Description, GroupType, MembershipRule
    .EXAMPLE
        $groups = Get-DeviceGroupMemberships -AzureADObjectId "12345678-1234-1234-1234-123456789abc"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AzureADObjectId
    )

    try {
        # Graceful handling of empty/null device ID
        if ([string]::IsNullOrEmpty($AzureADObjectId)) {
            Write-StatusMessage "Cannot get device group memberships: Azure AD object ID is empty" -Type Warning
            Write-DeviceDNALog -Message "Skipped: Azure AD object ID not available" -Component "Get-DeviceGroupMemberships" -Type 2
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Device group memberships skipped: Azure AD object ID not available" }
            return @()
        }

        Write-StatusMessage "Getting device group memberships..." -Type Progress

        # Use /transitiveMemberOf to include nested group memberships
        $memberOfUri = "https://graph.microsoft.com/v1.0/devices/$AzureADObjectId/transitiveMemberOf?`$top=999"
        Write-DeviceDNALog -Message "Graph API call: GET devices/$AzureADObjectId/transitiveMemberOf" -Component "Get-DeviceGroupMemberships" -Type 1

        $queryStart = Get-Date
        $memberResponse = Invoke-MgGraphRequest -Uri $memberOfUri -Method GET -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        $allMembers = @($memberResponse.value)
        $pageCount = 1

        while ($memberResponse.'@odata.nextLink') {
            $pageCount++
            $memberResponse = Invoke-MgGraphRequest -Uri $memberResponse.'@odata.nextLink' -Method GET -ErrorAction Stop
            $allMembers += $memberResponse.value
        }

        Write-DeviceDNALog -Message "Graph API response: $($allMembers.Count) membership(s) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-DeviceGroupMemberships" -Type 1

        # Filter to groups only and format output matching working implementation
        $groups = @($allMembers |
            Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } |
            ForEach-Object {
                $membershipRule = $null
                $groupType = 'Assigned'

                if ($_.membershipRule) {
                    $membershipRule = $_.membershipRule
                    $groupType = 'Dynamic'
                }

                if ($_.groupTypes -contains 'DynamicMembership') {
                    $groupType = 'Dynamic'
                }

                [PSCustomObject]@{
                    ObjectId        = $_.id
                    DisplayName     = $_.displayName
                    Description     = $_.description
                    GroupType       = $groupType
                    MembershipRule  = $membershipRule
                    MailEnabled     = $_.mailEnabled
                    SecurityEnabled = $_.securityEnabled
                    Mail            = $_.mail
                }
            })

        Write-StatusMessage "Found $($groups.Count) group memberships for device" -Type Info

        # Log group details for assignment matching diagnostics
        $dynamicCount = @($groups | Where-Object { $_.GroupType -eq 'Dynamic' }).Count
        $assignedCount = @($groups | Where-Object { $_.GroupType -eq 'Assigned' }).Count
        Write-DeviceDNALog -Message "Device groups: $($groups.Count) total ($dynamicCount dynamic, $assignedCount assigned)" -Component "Get-DeviceGroupMemberships" -Type 1

        if ($groups.Count -gt 0) {
            $groupNames = ($groups | Select-Object -First 10 | ForEach-Object { $_.DisplayName }) -join ', '
            Write-DeviceDNALog -Message "Groups: $groupNames$(if ($groups.Count -gt 10) { '...' })" -Component "Get-DeviceGroupMemberships" -Type 1 -IsDebug
        }

        return $groups
    }
    catch {
        Write-StatusMessage "Error getting device group memberships: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Graph API error: $($_.Exception.Message)" -Component "Get-DeviceGroupMemberships" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error getting device group memberships: $($_.Exception.Message)" }
        return @()
    }
}


function Resolve-GroupDisplayNames {
    <#
    .SYNOPSIS
        Resolves Azure AD group IDs to display names with caching.
    .DESCRIPTION
        Queries Microsoft Graph for group display names and caches results
        in $script:GroupNameCache to avoid redundant API calls.
    .PARAMETER GroupIds
        Array of group ID GUIDs to resolve.
    .OUTPUTS
        Hashtable mapping group IDs to display names.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GroupIds
    )

    $resolved = @{}
    $toQuery = @()

    foreach ($id in $GroupIds) {
        if ([string]::IsNullOrEmpty($id)) { continue }
        if ($script:GroupNameCache.ContainsKey($id)) {
            $resolved[$id] = $script:GroupNameCache[$id]
        }
        else {
            $toQuery += $id
        }
    }

    foreach ($id in $toQuery) {
        try {
            $group = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$id" -Method GET
            $name = if ($group -and $group.displayName) { $group.displayName } else { $id }
            $script:GroupNameCache[$id] = $name
            $resolved[$id] = $name
        }
        catch {
            # If we can't resolve, use the ID itself
            $script:GroupNameCache[$id] = $id
            $resolved[$id] = $id
            Write-DeviceDNALog -Message "Could not resolve group $id : $($_.Exception.Message)" -Component "Resolve-GroupDisplayNames" -Type 2
        }
    }

    return $resolved
}

function Get-ProactiveRemediations {
    <#
    .SYNOPSIS
        Collects Intune proactive remediations (device health scripts) with assignments.
    .DESCRIPTION
        Retrieves proactive remediation scripts from Intune using $expand=assignments.
        Endpoint: /beta/deviceManagement/deviceHealthScripts
    .OUTPUTS
        Array of remediation objects with: Id, DisplayName, Description, Publisher, RunAsAccount, Assignments[]
    #>
    [CmdletBinding()]
    param()

    try {
        Write-StatusMessage "Collecting proactive remediations..." -Type Progress
        Write-DeviceDNALog -Message "Starting proactive remediation collection" -Component "Get-ProactiveRemediations" -Type 1

        $uri = 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?$expand=assignments&$top=999'
        Write-DeviceDNALog -Message "Graph API call: GET deviceHealthScripts with assignments" -Component "Get-ProactiveRemediations" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

        $allScripts = @($response.value)
        $pageCount = 1
        while ($response.'@odata.nextLink') {
            $pageCount++
            $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
            $allScripts += $response.value
        }
        $queryDuration = (Get-Date) - $queryStart
        Write-DeviceDNALog -Message "Proactive remediations: $($allScripts.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-ProactiveRemediations" -Type 1

        if ($allScripts.Count -eq 0) {
            Write-StatusMessage "No proactive remediations found" -Type Info
            return @()
        }

        $remediations = @(foreach ($script in $allScripts) {
            # Parse assignments
            $assignments = @($script.assignments | Where-Object { $_ } | ForEach-Object {
                $target = $_.target
                $targetLabel = switch ($target.'@odata.type') {
                    '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                    '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                    '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                    '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                    default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                }

                [PSCustomObject]@{
                    TargetType = $targetLabel
                    GroupId    = $target.groupId
                    FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                    FilterType = $target.deviceAndAppManagementAssignmentFilterType
                }
            })

            [PSCustomObject]@{
                Id                   = $script.id
                DisplayName          = $script.displayName
                Description          = $script.description
                Publisher            = $script.publisher
                RunAsAccount         = if ($script.runAsAccount -eq 'system') { 'System' } else { 'User' }
                EnforceSignatureCheck = $script.enforceSignatureCheck
                RunAs32Bit           = $script.runAs32Bit
                CreatedDateTime      = $script.createdDateTime
                LastModifiedDateTime = $script.lastModifiedDateTime
                Assignments          = $assignments
                IsAssigned           = ($assignments.Count -gt 0)
            }
        })

        $assignedCount = @($remediations | Where-Object IsAssigned).Count
        Write-StatusMessage "Found $($remediations.Count) proactive remediations ($assignedCount with assignments)" -Type Success
        Write-DeviceDNALog -Message "Proactive remediation collection complete: $($remediations.Count) scripts ($assignedCount with assignments)" -Component "Get-ProactiveRemediations" -Type 1

        return $remediations
    }
    catch {
        Write-StatusMessage "Error collecting proactive remediations: $($_.Exception.Message)" -Type Warning
        Write-DeviceDNALog -Message "Proactive remediation collection failed: $($_.Exception.Message)" -Component "Get-ProactiveRemediations" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting proactive remediations: $($_.Exception.Message)" }
        return @()
    }
}

function Get-ConfigurationProfiles {
    <#
    .SYNOPSIS
        Collects all Intune configuration profiles with their assignments.
    .DESCRIPTION
        Retrieves configuration profiles from multiple endpoints using $expand=assignments
        to get assignments in a single call (matching working DeviceDNA implementation):
        - Device configurations (beta with $expand)
        - Settings Catalog policies (beta with $expand)
        - Administrative Templates (beta)
    .OUTPUTS
        Array of unified profile objects with: Id, DisplayName, PolicyType, Platform, Assignments[]
    .EXAMPLE
        $profiles = Get-ConfigurationProfiles
    #>
    [CmdletBinding()]
    param()

    try {
        Write-StatusMessage "Collecting Intune configuration profiles..." -Type Progress
        Write-DeviceDNALog -Message "Starting configuration profile collection" -Component "Get-ConfigurationProfiles" -Type 1

        $allProfiles = @()
        $phaseStart = Get-Date

        # 1. Device Configurations with assignments expanded (beta, matching Get-GraphPolicyData.ps1)
        Write-StatusMessage "  - Collecting device configurations..." -Type Progress
        try {
            $uri = 'https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations?$expand=assignments&$top=999'
            Write-DeviceDNALog -Message "Graph API call: GET deviceConfigurations with assignments" -Component "Get-ConfigurationProfiles" -Type 1

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

            $deviceConfigs = @($response.value)
            $pageCount = 1
            while ($response.'@odata.nextLink') {
                $pageCount++
                $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                $deviceConfigs += $response.value
            }
            $queryDuration = (Get-Date) - $queryStart
            Write-DeviceDNALog -Message "Device configurations: $($deviceConfigs.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-ConfigurationProfiles" -Type 1

            foreach ($config in $deviceConfigs) {
                # Determine platform from @odata.type
                $platform = switch -Wildcard ($config.'@odata.type') {
                    '*windows*'    { 'Windows10' }
                    '*ios*'        { 'iOS' }
                    '*android*'    { 'Android' }
                    '*macOS*'      { 'macOS' }
                    default        { 'Unknown' }
                }

                # Parse assignments matching working implementation pattern
                $assignments = @($config.assignments | Where-Object { $_ } | ForEach-Object {
                    $target = $_.target
                    $targetLabel = switch ($target.'@odata.type') {
                        '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                        '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                        '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                        '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                        default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                    }

                    [PSCustomObject]@{
                        TargetType = $targetLabel
                        GroupId    = $target.groupId
                        FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                        FilterType = $target.deviceAndAppManagementAssignmentFilterType
                    }
                })

                $allProfiles += [PSCustomObject]@{
                    Id                   = $config.id
                    DisplayName          = $config.displayName
                    Description          = $config.description
                    PolicyType           = 'Device Configuration'
                    Platform             = $platform
                    OdataType            = $config.'@odata.type'
                    CreatedDateTime      = $config.createdDateTime
                    LastModifiedDateTime = $config.lastModifiedDateTime
                    Assignments          = $assignments
                }
            }
            Write-StatusMessage "    Found $($deviceConfigs.Count) device configurations" -Type Info
        }
        catch {
            Write-StatusMessage "    Error collecting device configurations: $($_.Exception.Message)" -Type Warning
            Write-DeviceDNALog -Message "Device configurations query failed: $($_.Exception.Message)" -Component "Get-ConfigurationProfiles" -Type 3
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting device configurations: $($_.Exception.Message)" }
        }

        # 2. Settings Catalog with assignments expanded (beta, matching Get-GraphPolicyData.ps1)
        Write-StatusMessage "  - Collecting Settings Catalog policies..." -Type Progress
        try {
            $uri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$expand=assignments&$top=999'
            Write-DeviceDNALog -Message "Graph API call: GET configurationPolicies with assignments" -Component "Get-ConfigurationProfiles" -Type 1

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

            $settingsCatalog = @($response.value)
            $pageCount = 1
            while ($response.'@odata.nextLink') {
                $pageCount++
                $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                $settingsCatalog += $response.value
            }
            $queryDuration = (Get-Date) - $queryStart
            Write-DeviceDNALog -Message "Settings Catalog: $($settingsCatalog.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-ConfigurationProfiles" -Type 1

            foreach ($policy in $settingsCatalog) {
                $assignments = @($policy.assignments | Where-Object { $_ } | ForEach-Object {
                    $target = $_.target
                    $targetLabel = switch ($target.'@odata.type') {
                        '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                        '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                        '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                        '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                        default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                    }

                    [PSCustomObject]@{
                        TargetType = $targetLabel
                        GroupId    = $target.groupId
                        FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                        FilterType = $target.deviceAndAppManagementAssignmentFilterType
                    }
                })

                $allProfiles += [PSCustomObject]@{
                    Id                   = $policy.id
                    DisplayName          = $policy.name
                    Description          = $policy.description
                    PolicyType           = 'Settings Catalog'
                    Platform             = $policy.platforms
                    Technologies         = $policy.technologies
                    CreatedDateTime      = $policy.createdDateTime
                    LastModifiedDateTime = $policy.lastModifiedDateTime
                    Assignments          = $assignments
                }
            }
            Write-StatusMessage "    Found $($settingsCatalog.Count) Settings Catalog policies" -Type Info
        }
        catch {
            Write-StatusMessage "    Error collecting Settings Catalog policies: $($_.Exception.Message)" -Type Warning
            Write-DeviceDNALog -Message "Settings Catalog query failed: $($_.Exception.Message)" -Component "Get-ConfigurationProfiles" -Type 3
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting Settings Catalog policies: $($_.Exception.Message)" }
        }

        # 3. Administrative Templates / Group Policy Configurations (beta)
        Write-StatusMessage "  - Collecting Administrative Templates..." -Type Progress
        try {
            $uri = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations?$expand=assignments&$top=999'
            Write-DeviceDNALog -Message "Graph API call: GET groupPolicyConfigurations with assignments" -Component "Get-ConfigurationProfiles" -Type 1

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

            $adminTemplates = @($response.value)
            $pageCount = 1
            while ($response.'@odata.nextLink') {
                $pageCount++
                $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                $adminTemplates += $response.value
            }
            $queryDuration = (Get-Date) - $queryStart
            Write-DeviceDNALog -Message "Administrative Templates: $($adminTemplates.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-ConfigurationProfiles" -Type 1

            foreach ($template in $adminTemplates) {
                $assignments = @($template.assignments | Where-Object { $_ } | ForEach-Object {
                    $target = $_.target
                    $targetLabel = switch ($target.'@odata.type') {
                        '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                        '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                        '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                        '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                        default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                    }

                    [PSCustomObject]@{
                        TargetType = $targetLabel
                        GroupId    = $target.groupId
                        FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                        FilterType = $target.deviceAndAppManagementAssignmentFilterType
                    }
                })

                $allProfiles += [PSCustomObject]@{
                    Id                   = $template.id
                    DisplayName          = $template.displayName
                    Description          = $template.description
                    PolicyType           = 'Administrative Template'
                    Platform             = 'Windows10'
                    CreatedDateTime      = $template.createdDateTime
                    LastModifiedDateTime = $template.lastModifiedDateTime
                    Assignments          = $assignments
                }
            }
            Write-StatusMessage "    Found $($adminTemplates.Count) Administrative Templates" -Type Info
        }
        catch {
            Write-StatusMessage "    Error collecting Administrative Templates: $($_.Exception.Message)" -Type Warning
            Write-DeviceDNALog -Message "Administrative Templates query failed: $($_.Exception.Message)" -Component "Get-ConfigurationProfiles" -Type 3
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting Administrative Templates: $($_.Exception.Message)" }
        }

        # 4. Endpoint Security Intents (beta) - NEW
        Write-StatusMessage "  - Collecting Endpoint Security intents..." -Type Progress
        try {
            $uri = 'https://graph.microsoft.com/beta/deviceManagement/intents?$expand=assignments&$top=999'
            Write-DeviceDNALog -Message "Graph API call: GET intents with assignments" -Component "Get-ConfigurationProfiles" -Type 1

            $queryStart = Get-Date
            $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

            $intents = @($response.value)
            $pageCount = 1
            while ($response.'@odata.nextLink') {
                $pageCount++
                $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                $intents += $response.value
            }
            $queryDuration = (Get-Date) - $queryStart
            Write-DeviceDNALog -Message "Endpoint Security intents: $($intents.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-ConfigurationProfiles" -Type 1

            foreach ($intent in $intents) {
                $assignments = @($intent.assignments | Where-Object { $_ } | ForEach-Object {
                    $target = $_.target
                    $targetLabel = switch ($target.'@odata.type') {
                        '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                        '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                        '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                        '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                        default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                    }

                    [PSCustomObject]@{
                        TargetType = $targetLabel
                        GroupId    = $target.groupId
                        FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                        FilterType = $target.deviceAndAppManagementAssignmentFilterType
                    }
                })

                $allProfiles += [PSCustomObject]@{
                    Id                   = $intent.id
                    DisplayName          = $intent.displayName
                    Description          = $intent.description
                    PolicyType           = 'Endpoint Security'
                    Platform             = 'Windows10'
                    OdataType            = $intent.'@odata.type'
                    CreatedDateTime      = $intent.createdDateTime
                    LastModifiedDateTime = $intent.lastModifiedDateTime
                    Assignments          = $assignments
                }
            }
            Write-StatusMessage "    Found $($intents.Count) Endpoint Security intents" -Type Info
        }
        catch {
            Write-StatusMessage "    Error collecting Endpoint Security intents: $($_.Exception.Message)" -Type Warning
            Write-DeviceDNALog -Message "Endpoint Security intents query failed: $($_.Exception.Message)" -Component "Get-ConfigurationProfiles" -Type 3
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting Endpoint Security intents: $($_.Exception.Message)" }
        }

        $phaseDuration = (Get-Date) - $phaseStart
        Write-StatusMessage "Total configuration profiles collected: $($allProfiles.Count)" -Type Success
        Write-DeviceDNALog -Message "Configuration profile collection complete: $($allProfiles.Count) profiles in $($phaseDuration.TotalSeconds.ToString('F1'))s" -Component "Get-ConfigurationProfiles" -Type 1

        return $allProfiles
    }
    catch {
        Write-StatusMessage "Error collecting configuration profiles: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Configuration profile collection failed: $($_.Exception.Message)" -Component "Get-ConfigurationProfiles" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting configuration profiles: $($_.Exception.Message)" }
        return @()
    }
}

function Get-AppInstallStatuses {
    <#
    .SYNOPSIS
        Retrieves app install statuses for assigned apps on a specific device.
    .DESCRIPTION
        Uses the Microsoft Graph mobileAppIntentAndStates API to get ALL app install
        statuses for a user's devices in a SINGLE API call.

        Endpoint: GET /users/{userId}/mobileAppIntentAndStates
        Returns: mobileAppIntentAndState objects containing device ID and app list with
                 install state for each app.
    .PARAMETER IntuneDeviceId
        The Intune device ID (GUID format) to filter results.
    .PARAMETER UserPrincipalName
        The user's UPN (e.g., user@contoso.com) required for the API endpoint.
    .OUTPUTS
        Array of PSCustomObjects with app install status data compatible with existing code.
    .NOTES
        Source: https://learn.microsoft.com/graph/api/intune-troubleshooting-mobileappintentandstate-list
        This replaces the slow per-app Reports API approach with a single efficient call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneDeviceId,

        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName
    )

    try {
        Write-StatusMessage "Querying app install statuses for user device..." -Type Progress
        Write-DeviceDNALog -Message "Using mobileAppIntentAndStates API for user: $UserPrincipalName" -Component "Get-AppInstallStatuses" -Type 1

        # Call the user-centric endpoint that returns all apps for all user devices
        $uri = "https://graph.microsoft.com/beta/users/$UserPrincipalName/mobileAppIntentAndStates"
        $response = Invoke-GraphRequest -Method GET -Uri $uri

        if (-not $response -or $response.Count -eq 0) {
            Write-DeviceDNALog -Message "No app intent/state data returned for user" -Component "Get-AppInstallStatuses" -Type 2
            return @()
        }

        # Find the entry for our specific device
        $deviceEntry = $response | Where-Object { $_.managedDeviceIdentifier -eq $IntuneDeviceId } | Select-Object -First 1

        if (-not $deviceEntry) {
            Write-DeviceDNALog -Message "No app data found for device $IntuneDeviceId" -Component "Get-AppInstallStatuses" -Type 2
            return @()
        }

        # Convert mobileAppList to format expected by existing code
        $allStatuses = @()
        foreach ($appDetail in $deviceEntry.mobileAppList) {
            $statusObj = [PSCustomObject]@{
                'app' = @{ id = $appDetail.applicationId }
                'mobileAppInstallStatusValue' = $appDetail.installState
                'installState' = $appDetail.installState
                'installStateDetail' = $null  # Not available in this API
                'errorCode' = $null  # Not available in this API
                'deviceName' = $null  # Not available in this API
                'deviceId' = $IntuneDeviceId
                'userName' = $null  # Not available in this API
                'userPrincipalName' = $UserPrincipalName
                'lastModifiedDateTime' = $null  # Not available in this API
                'platform' = $null  # Not available in this API
                'displayName' = $appDetail.displayName
                'displayVersion' = $appDetail.displayVersion
                'intent' = $appDetail.mobileAppIntent
            }
            $allStatuses += $statusObj
            Write-DeviceDNALog -Message "  App: $($appDetail.displayName) - Status: $($appDetail.installState)" -Component "Get-AppInstallStatuses" -Type 1
        }

        Write-StatusMessage "Retrieved install status for $($allStatuses.Count) app(s)" -Type Success
        Write-DeviceDNALog -Message "App install status collection complete: $($allStatuses.Count) statuses retrieved" -Component "Get-AppInstallStatuses" -Type 1

        return $allStatuses
    }
    catch {
        Write-StatusMessage "Failed to query app install statuses: $($_.Exception.Message)" -Type Warning
        Write-DeviceDNALog -Message "App install status query failed: $($_.Exception.Message)" -Component "Get-AppInstallStatuses" -Type 2
        $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Failed to query app install statuses: $($_.Exception.Message)" }
        return @()
    }
}
function Get-IntuneApplications {
    <#
    .SYNOPSIS
        Collects Intune applications with their assignments.
    .DESCRIPTION
        Retrieves mobile apps from Intune using $expand=assignments to get all data
        in a single call (matching working Get-DeviceAppAssignments.ps1 implementation).
    .OUTPUTS
        Array of application objects with: Id, DisplayName, AppType, Publisher, Assignments[]
    .EXAMPLE
        $apps = Get-IntuneApplications
    #>
    [CmdletBinding()]
    param()

    try {
        Write-StatusMessage "Collecting Intune applications..." -Type Progress
        Write-DeviceDNALog -Message "Starting application collection" -Component "Get-IntuneApplications" -Type 1

        # Use beta endpoint with $expand=assignments matching Get-DeviceAppAssignments.ps1
        $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$expand=assignments&$top=999'
        Write-DeviceDNALog -Message "Graph API call: GET mobileApps with assignments" -Component "Get-IntuneApplications" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

        $allApps = @($response.value)
        $pageCount = 1
        while ($response.'@odata.nextLink') {
            $pageCount++
            $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
            $allApps += $response.value
        }
        $queryDuration = (Get-Date) - $queryStart
        Write-DeviceDNALog -Message "Applications: $($allApps.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-IntuneApplications" -Type 1

        if ($allApps.Count -eq 0) {
            Write-StatusMessage "No applications found" -Type Warning
            return @()
        }

        $apps = @(foreach ($app in $allApps) {
            # Determine app type from odata type (matching Get-DeviceAppAssignments.ps1)
            $odataType = $app.'@odata.type'
            $appType = switch -Wildcard ($odataType) {
                '*win32LobApp'              { 'Win32 App' }
                '*windowsMobileMSI'         { 'MSI (LOB)' }
                '*microsoftStoreForBusiness*' { 'Microsoft Store' }
                '*winGetApp'                { 'WinGet App' }
                '*webApp'                   { 'Web Link' }
                '*officeSuiteApp'           { 'Microsoft 365 Apps' }
                '*windowsUniversalAppX'     { 'MSIX/AppX' }
                '*windowsAppX'              { 'AppX' }
                '*managedIOSStoreApp'       { 'iOS Store App' }
                '*managedAndroidStoreApp'   { 'Android Store App' }
                default                     { $odataType -replace '#microsoft\.graph\.' }
            }

            # Parse assignments matching working implementation pattern
            $assignments = @($app.assignments | Where-Object { $_ } | ForEach-Object {
                $target = $_.target
                $intentLabel = switch ($_.intent) {
                    'required'              { 'Required' }
                    'available'             { 'Available' }
                    'uninstall'             { 'Uninstall' }
                    'availableWithoutEnrollment' { 'Available (No Enrollment)' }
                    default                 { $_.intent }
                }

                $targetLabel = switch ($target.'@odata.type') {
                    '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                    '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                    '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                    '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude Group: $($target.groupId)" }
                    default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                }

                [PSCustomObject]@{
                    Intent     = $intentLabel
                    TargetType = $targetLabel
                    GroupId    = $target.groupId
                    FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                    FilterType = $target.deviceAndAppManagementAssignmentFilterType
                }
            })

            # Get version - different app types store version in different properties
            $appVersion = $app.displayVersion
            if (-not $appVersion) { $appVersion = $app.version }
            if (-not $appVersion) { $appVersion = $app.productVersion }

            [PSCustomObject]@{
                Id                   = $app.id
                DisplayName          = $app.displayName
                Description          = $app.description
                AppType              = $appType
                OdataType            = $odataType
                Publisher            = $app.publisher
                Version              = $appVersion
                CreatedDateTime      = $app.createdDateTime
                LastModifiedDateTime = $app.lastModifiedDateTime
                Assignments          = $assignments
                IsAssigned           = ($assignments.Count -gt 0)
            }
        })

        $assignedCount = @($apps | Where-Object IsAssigned).Count
        Write-StatusMessage "Found $($apps.Count) applications ($assignedCount with assignments)" -Type Success
        Write-DeviceDNALog -Message "Application collection complete: $($apps.Count) apps ($assignedCount with assignments)" -Component "Get-IntuneApplications" -Type 1

        return $apps
    }
    catch {
        Write-StatusMessage "Error collecting applications: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Application collection failed: $($_.Exception.Message)" -Component "Get-IntuneApplications" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting applications: $($_.Exception.Message)" }
        return @()
    }
}

function Get-CompliancePolicies {
    <#
    .SYNOPSIS
        Collects Intune compliance policies with their assignments.
    .DESCRIPTION
        Retrieves device compliance policies from Intune using $expand=assignments
        (matching working Get-GraphPolicyData.ps1 implementation).
    .OUTPUTS
        Array of compliance policy objects with: Id, DisplayName, Platform, Assignments[]
    .EXAMPLE
        $policies = Get-CompliancePolicies
    #>
    [CmdletBinding()]
    param()

    try {
        Write-StatusMessage "Collecting compliance policies..." -Type Progress
        Write-DeviceDNALog -Message "Starting compliance policy collection" -Component "Get-CompliancePolicies" -Type 1

        # Use beta endpoint with $expand=assignments
        $uri = 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$expand=assignments&$top=999'
        Write-DeviceDNALog -Message "Graph API call: GET deviceCompliancePolicies with assignments" -Component "Get-CompliancePolicies" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

        $allPolicies = @($response.value)
        $pageCount = 1
        while ($response.'@odata.nextLink') {
            $pageCount++
            $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
            $allPolicies += $response.value
        }
        $queryDuration = (Get-Date) - $queryStart
        Write-DeviceDNALog -Message "Compliance policies: $($allPolicies.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-CompliancePolicies" -Type 1

        if ($allPolicies.Count -eq 0) {
            Write-StatusMessage "No compliance policies found" -Type Warning
            Write-DeviceDNALog -Message "No compliance policies found in tenant" -Component "Get-CompliancePolicies" -Type 2
            return @()
        }

        $compliancePolicies = @(foreach ($policy in $allPolicies) {
            # Determine platform from @odata.type
            $platform = switch -Wildcard ($policy.'@odata.type') {
                '*windows*'    { 'Windows10' }
                '*ios*'        { 'iOS' }
                '*android*'    { 'Android' }
                '*macOS*'      { 'macOS' }
                default        { 'Unknown' }
            }

            # Parse assignments matching working implementation pattern
            $assignments = @($policy.assignments | Where-Object { $_ } | ForEach-Object {
                $target = $_.target
                $targetLabel = switch ($target.'@odata.type') {
                    '#microsoft.graph.allDevicesAssignmentTarget'       { 'All Devices' }
                    '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'All Users' }
                    '#microsoft.graph.groupAssignmentTarget'            { "Group: $($target.groupId)" }
                    '#microsoft.graph.exclusionGroupAssignmentTarget'   { "Exclude: $($target.groupId)" }
                    default { $target.'@odata.type' -replace '#microsoft\.graph\.' }
                }

                [PSCustomObject]@{
                    TargetType = $targetLabel
                    GroupId    = $target.groupId
                    FilterId   = $target.deviceAndAppManagementAssignmentFilterId
                    FilterType = $target.deviceAndAppManagementAssignmentFilterType
                }
            })

            [PSCustomObject]@{
                Id                   = $policy.id
                DisplayName          = $policy.displayName
                Description          = $policy.description
                Platform             = $platform
                OdataType            = $policy.'@odata.type'
                CreatedDateTime      = $policy.createdDateTime
                LastModifiedDateTime = $policy.lastModifiedDateTime
                Assignments          = $assignments
            }
        })

        Write-StatusMessage "Found $($compliancePolicies.Count) compliance policies" -Type Success
        Write-DeviceDNALog -Message "Compliance policy collection complete: $($compliancePolicies.Count) policies" -Component "Get-CompliancePolicies" -Type 1

        return $compliancePolicies
    }
    catch {
        Write-StatusMessage "Error collecting compliance policies: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Compliance policy collection failed: $($_.Exception.Message)" -Component "Get-CompliancePolicies" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting compliance policies: $($_.Exception.Message)" }
        return @()
    }
}

function Get-DeviceCompliancePolicyStates {
    <#
    .SYNOPSIS
        Gets the compliance policy states for a specific managed device.
    .DESCRIPTION
        Retrieves per-policy compliance evaluation results using the Intune Reports API
        (getDevicePoliciesComplianceReport) — the same synchronous POST endpoint used by
        the Intune admin portal. Filters by DeviceId for fast, per-device results.
        Ref: https://learn.microsoft.com/graph/api/intune-reporting-devicemanagementreports-getdevicepoliciescompliancereport
    .PARAMETER IntuneDeviceId
        The Intune managed device ID (from managedDevice.id).
    .OUTPUTS
        Array of policy state objects with: PolicyId, PolicyName, State, Platform, Version, UPN, LastContact
    .EXAMPLE
        $states = Get-DeviceCompliancePolicyStates -IntuneDeviceId "abc123-def456"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneDeviceId
    )

    try {
        Write-StatusMessage "Collecting device compliance policy states..." -Type Progress
        Write-DeviceDNALog -Message "Starting device compliance policy state collection for device: $IntuneDeviceId" -Component "Get-DeviceCompliancePolicyStates" -Type 1

        # Direct report POST — synchronous, returns inline JSON, supports DeviceId filter
        $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getDevicePoliciesComplianceReport"
        $reportBody = @{
            filter = "(DeviceId eq '$IntuneDeviceId')"
            select = @("DeviceId", "PolicyId", "PolicyName", "PolicyPlatformType", "PolicyStatus", "PolicyVersion", "UPN", "UserName", "LastContact")
            top    = 50
            skip   = 0
        } | ConvertTo-Json

        Write-DeviceDNALog -Message "Graph API call: POST getDevicePoliciesComplianceReport filtered by DeviceId=$IntuneDeviceId" -Component "Get-DeviceCompliancePolicyStates" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method POST -Body $reportBody -ContentType "application/json" -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        # Response format: Schema (column definitions) + Values (row arrays)
        $columns = @($response.Schema | ForEach-Object { $_.Column })
        $rows = @($response.Values)

        Write-DeviceDNALog -Message "Compliance report: $($rows.Count) row(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms (columns: $($columns -join ', '))" -Component "Get-DeviceCompliancePolicyStates" -Type 1

        if ($rows.Count -eq 0) {
            Write-StatusMessage "No compliance policy states found for device" -Type Info
            Write-DeviceDNALog -Message "No compliance policy states found for device $IntuneDeviceId" -Component "Get-DeviceCompliancePolicyStates" -Type 1
            return @()
        }

        # Convert row arrays to objects using column names
        $policyStates = @()
        foreach ($row in $rows) {
            $rowObj = @{}
            for ($i = 0; $i -lt $columns.Count; $i++) {
                if ($i -lt $row.Count) {
                    $rowObj[$columns[$i]] = $row[$i]
                }
            }

            # Use PolicyStatus_loc (localized string from API) if available, otherwise map numeric code
            $stateString = $rowObj.PolicyStatus_loc
            if ([string]::IsNullOrEmpty($stateString)) {
                $stateString = switch ($rowObj.PolicyStatus) {
                    1 { 'NonCompliant' }
                    2 { 'Compliant' }
                    3 { 'Unknown' }
                    4 { 'Error' }
                    5 { 'NotApplicable' }
                    6 { 'InGracePeriod' }
                    default { 'Unknown' }
                }
            }

            $policyStates += [PSCustomObject]@{
                PolicyId    = $rowObj.PolicyId
                PolicyName  = $rowObj.PolicyName
                State       = $stateString
                Platform    = $rowObj.PolicyPlatformType
                Version     = $rowObj.PolicyVersion
                UPN         = $rowObj.UPN
                UserName    = $rowObj.UserName
                LastContact = $rowObj.LastContact
            }

            Write-DeviceDNALog -Message "  Policy: $($rowObj.PolicyName) -> $stateString (PolicyId=$($rowObj.PolicyId))" -Component "Get-DeviceCompliancePolicyStates" -Type 1
        }

        Write-StatusMessage "Found $($policyStates.Count) compliance policy states for device" -Type Success
        Write-DeviceDNALog -Message "Device compliance policy state collection complete: $($policyStates.Count) states" -Component "Get-DeviceCompliancePolicyStates" -Type 1

        return $policyStates
    }
    catch {
        Write-StatusMessage "Error collecting device compliance policy states: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Device compliance policy state collection failed: $($_.Exception.Message)" -Component "Get-DeviceCompliancePolicyStates" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting device compliance policy states: $($_.Exception.Message)" }
        return @()
    }
}

function Get-AssignmentFilters {
    <#
    .SYNOPSIS
        Collects Intune assignment filters.
    .DESCRIPTION
        Retrieves assignment filters used to refine policy targeting.
        Uses direct Invoke-MgGraphRequest matching the working implementation pattern.
    .OUTPUTS
        Array of filter objects with: Id, DisplayName, Platform, Rule
    .EXAMPLE
        $filters = Get-AssignmentFilters
    #>
    [CmdletBinding()]
    param()

    try {
        Write-StatusMessage "Collecting assignment filters..." -Type Progress
        Write-DeviceDNALog -Message "Starting assignment filter collection" -Component "Get-AssignmentFilters" -Type 1

        $uri = 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?$top=999'
        Write-DeviceDNALog -Message "Graph API call: GET assignmentFilters" -Component "Get-AssignmentFilters" -Type 1

        $queryStart = Get-Date
        $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop

        $allFilters = @($response.value)
        $pageCount = 1
        while ($response.'@odata.nextLink') {
            $pageCount++
            $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
            $allFilters += $response.value
        }
        $queryDuration = (Get-Date) - $queryStart
        Write-DeviceDNALog -Message "Assignment filters: $($allFilters.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-AssignmentFilters" -Type 1

        if ($allFilters.Count -eq 0) {
            Write-StatusMessage "No assignment filters found" -Type Info
            return @()
        }

        $assignmentFilters = @(foreach ($filter in $allFilters) {
            [PSCustomObject]@{
                Id                              = $filter.id
                DisplayName                     = $filter.displayName
                Description                     = $filter.description
                Platform                        = $filter.platform
                Rule                            = $filter.rule
                AssignmentFilterManagementType  = $filter.assignmentFilterManagementType
                CreatedDateTime                 = $filter.createdDateTime
                LastModifiedDateTime            = $filter.lastModifiedDateTime
            }
        })

        Write-StatusMessage "Found $($assignmentFilters.Count) assignment filters" -Type Success
        return $assignmentFilters
    }
    catch {
        Write-StatusMessage "Error collecting assignment filters: $($_.Exception.Message)" -Type Error
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting assignment filters: $($_.Exception.Message)" }
        return @()
    }
}

function Get-ProfileSettings {
    <#
    .SYNOPSIS
        Gets the settings configured in a specific policy.
    .DESCRIPTION
        Retrieves detailed settings for a policy based on its type:
        - Settings Catalog: Gets from /settings endpoint with $expand=settingDefinitions
        - Device Configuration: Parses policy properties (filters cert blobs and metadata)
        - Administrative Template: Gets definition values (Enabled/Disabled per setting)
        - Endpoint Security: Not yet supported, returns empty array
        Routes all Graph calls through Invoke-GraphRequest for pagination and retry.
    .PARAMETER PolicyId
        The ID of the policy to get settings for.
    .PARAMETER PolicyType
        The type of policy.
    .OUTPUTS
        Array of setting objects with: name, value, dataType
    .EXAMPLE
        $settings = Get-ProfileSettings -PolicyId "abc123" -PolicyType "Settings Catalog"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Settings Catalog', 'Device Configuration', 'Administrative Template', 'Endpoint Security')]
        [string]$PolicyType
    )

    $component = "Get-ProfileSettings"

    try {
        $settings = @()

        switch ($PolicyType) {
            'Settings Catalog' {
                # Use Invoke-MgGraphRequest directly (same proven pattern as other collection endpoints)
                $uri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies('$PolicyId')/settings?`$expand=settingDefinitions"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
                $results = @($response.value)
                while ($response.'@odata.nextLink') {
                    $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                    $results += $response.value
                }

                if ($results -and $results.Count -gt 0) {
                    foreach ($setting in $results) {
                        $settingInstance = $setting.settingInstance
                        # settingDefinitions may be array or single — handle both
                        $definitions = $setting.settingDefinitions
                        $definition = if ($definitions -is [array]) { $definitions | Select-Object -First 1 } else { $definitions }

                        $settingName = $null
                        if ($definition) {
                            # Hashtable in PS 5.1 — use indexer, not .property
                            if ($definition -is [hashtable]) {
                                $settingName = $definition['displayName']
                            } else {
                                $settingName = $definition.displayName
                            }
                        }
                        if (-not $settingName) {
                            if ($settingInstance -is [hashtable]) {
                                $settingName = $settingInstance['settingDefinitionId']
                            } else {
                                $settingName = $settingInstance.settingDefinitionId
                            }
                        }
                        if (-not $settingName) { $settingName = 'Unknown' }

                        # Extract value based on setting type
                        $settingValue = $null
                        $dataType = if ($settingInstance -is [hashtable]) { $settingInstance['@odata.type'] } else { $settingInstance.'@odata.type' }

                        switch -Wildcard ($dataType) {
                            '*choiceSettingInstance' {
                                $csv = if ($settingInstance -is [hashtable]) { $settingInstance['choiceSettingValue'] } else { $settingInstance.choiceSettingValue }
                                $settingValue = if ($csv -is [hashtable]) { $csv['value'] } else { $csv.value }
                            }
                            '*simpleSettingInstance' {
                                $ssv = if ($settingInstance -is [hashtable]) { $settingInstance['simpleSettingValue'] } else { $settingInstance.simpleSettingValue }
                                $settingValue = if ($ssv -is [hashtable]) { $ssv['value'] } else { $ssv.value }
                            }
                            '*simpleSettingCollectionInstance' {
                                $coll = if ($settingInstance -is [hashtable]) { $settingInstance['simpleSettingCollectionValue'] } else { $settingInstance.simpleSettingCollectionValue }
                                if ($coll) {
                                    $settingValue = ($coll | ForEach-Object {
                                        if ($_ -is [hashtable]) { $_['value'] } else { $_.value }
                                    }) -join '; '
                                }
                            }
                            '*groupSettingCollectionInstance' {
                                $settingValue = "[Group Collection]"
                            }
                            default {
                                $settingValue = $settingInstance | ConvertTo-Json -Depth 3 -Compress
                            }
                        }

                        $defId = if ($settingInstance -is [hashtable]) { $settingInstance['settingDefinitionId'] } else { $settingInstance.settingDefinitionId }

                        $settings += [PSCustomObject]@{
                            name         = $settingName
                            value        = $settingValue
                            dataType     = $dataType
                            definitionId = $defId
                        }
                    }
                }

                Write-DeviceDNALog -Message "Settings Catalog $PolicyId : $($settings.Count) settings" -Component $component -Type 1
            }

            'Device Configuration' {
                # Single object GET — Invoke-GraphRequest returns the object directly
                $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$PolicyId"
                $policy = Invoke-GraphRequest -Method GET -Uri $uri

                if ($policy) {
                    # Properties to exclude (metadata + large binary blobs)
                    $excludeProperties = @(
                        'id', 'displayName', 'description', 'createdDateTime',
                        'lastModifiedDateTime', 'version', '@odata.type', '@odata.context',
                        'supportsScopeTags', 'deviceManagementApplicabilityRuleOsEdition',
                        'deviceManagementApplicabilityRuleOsVersion', 'deviceManagementApplicabilityRuleDeviceMode',
                        'roleScopeTagIds', 'assignments',
                        # Certificate blobs — large base64 data not useful in reports
                        'trustedRootCertificate', 'certContent', 'trustedServerCertificate',
                        'contentData', 'payloadContent'
                    )

                    # PS 5.1: Invoke-MgGraphRequest returns hashtable, not PSObject
                    $propNames = @()
                    if ($policy -is [hashtable]) {
                        $propNames = $policy.Keys | Where-Object { $_ -notin $excludeProperties }
                    } else {
                        $propNames = $policy.PSObject.Properties.Name | Where-Object { $_ -notin $excludeProperties }
                    }

                    foreach ($propName in $propNames) {
                        $propValue = if ($policy -is [hashtable]) { $policy[$propName] } else { $policy.$propName }

                        if ($null -ne $propValue) {
                            $displayValue = $propValue
                            if ($propValue -is [array] -or $propValue -is [hashtable]) {
                                $displayValue = $propValue | ConvertTo-Json -Depth 3 -Compress
                            }

                            $settings += [PSCustomObject]@{
                                name     = $propName
                                value    = $displayValue
                                dataType = $propValue.GetType().Name
                            }
                        }
                    }
                }

                Write-DeviceDNALog -Message "Device Configuration $PolicyId : $($settings.Count) settings" -Component $component -Type 1
            }

            'Administrative Template' {
                # Use Invoke-MgGraphRequest directly (same proven pattern as other collection endpoints)
                $uri = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations/$PolicyId/definitionValues?`$expand=definition"
                $response = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
                $results = @($response.value)
                while ($response.'@odata.nextLink') {
                    $response = Invoke-MgGraphRequest -Uri $response.'@odata.nextLink' -Method GET -ErrorAction Stop
                    $results += $response.value
                }

                if ($results -and $results.Count -gt 0) {
                    foreach ($defValue in $results) {
                        $definition = if ($defValue -is [hashtable]) { $defValue['definition'] } else { $defValue.definition }

                        $settingName = $null
                        if ($definition) {
                            $settingName = if ($definition -is [hashtable]) { $definition['displayName'] } else { $definition.displayName }
                            if (-not $settingName) {
                                $settingName = if ($definition -is [hashtable]) { $definition['id'] } else { $definition.id }
                            }
                        }
                        if (-not $settingName) { $settingName = 'Unknown' }

                        $isEnabled = if ($defValue -is [hashtable]) { $defValue['enabled'] } else { $defValue.enabled }
                        $settingValue = if ($isEnabled) { "Enabled" } else { "Disabled" }

                        $categoryPath = $null
                        $classType = $null
                        if ($definition) {
                            $categoryPath = if ($definition -is [hashtable]) { $definition['categoryPath'] } else { $definition.categoryPath }
                            $classType = if ($definition -is [hashtable]) { $definition['classType'] } else { $definition.classType }
                        }

                        $settings += [PSCustomObject]@{
                            name      = $settingName
                            value     = $settingValue
                            dataType  = 'AdministrativeTemplate'
                            category  = $categoryPath
                            classType = $classType
                        }
                    }
                }

                Write-DeviceDNALog -Message "Administrative Template $PolicyId : $($settings.Count) settings" -Component $component -Type 1
            }

            'Endpoint Security' {
                # Endpoint Security profiles use /deviceManagement/intents — not yet supported
                Write-DeviceDNALog -Message "Endpoint Security profile $PolicyId : settings collection not yet supported" -Component $component -Type 2
            }
        }

        return $settings
    }
    catch {
        Write-DeviceDNALog -Message "Error getting settings for $PolicyType profile $PolicyId : $($_.Exception.Message)" -Component $component -Type 3
        $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Failed to collect settings for profile $PolicyId : $($_.Exception.Message)" }
        return @()
    }
}

function Get-NotDeployedReason {
    <#
    .SYNOPSIS
        Determines why a profile assigned to a device was not deployed.
    .DESCRIPTION
        Analyzes assignment targeting and filter data to determine why a profile
        that is assigned (candidate) was not actually deployed to the device.
        Returns a descriptive reason string for troubleshooting.
    #>
    param(
        [hashtable]$Targeting,
        [object]$Profile,
        [array]$DeviceGroupIds,
        [array]$UserGroupIds
    )

    # Check if device/user is in any target group
    $hasMatchingGroup = $false
    foreach ($assignment in $Profile.Assignments) {
        $target = $assignment.target.'@odata.type'
        $groupId = $assignment.target.groupId

        if ($target -eq '#microsoft.graph.allDevicesAssignmentTarget' -or
            $target -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') {
            $hasMatchingGroup = $true
            break
        }

        if ($groupId -in $DeviceGroupIds -or $groupId -in $UserGroupIds) {
            $hasMatchingGroup = $true
            break
        }
    }

    # Determine reason
    if (-not $hasMatchingGroup) {
        # Not in any target group
        $groupNames = $Targeting.targetGroups -join ', '
        if ([string]::IsNullOrEmpty($groupNames)) {
            return "Device/user not member of any target group"
        }
        return "Device/user not member of target group(s): $groupNames"
    }
    elseif ($Targeting.assignmentFilter) {
        # In target group but has filter - likely excluded by filter
        return "Excluded by assignment filter: $($Targeting.assignmentFilter)"
    }
    else {
        # In target group, no filter, but still not deployed - unknown reason
        # Could be: platform incompatibility, conflict, pending deployment
        return "Assigned but not deployed (reason unknown - check Intune portal)"
    }
}

function Get-IntuneData {
    <#
    .SYNOPSIS
        Main orchestrator for Intune data collection.
    .DESCRIPTION
        Coordinates all Intune collection activities:
        - Finds device in Azure AD and Intune
        - Gets group memberships
        - Collects profiles, apps, policies
        - Determines targeting status for each assignment
    .PARAMETER DeviceName
        The name of the device to collect data for.
    .PARAMETER TenantId
        The Azure AD tenant ID.
    .PARAMETER DeviceGroups
        Pre-fetched device group memberships (optional).
    .PARAMETER Skip
        Array of collection targets to skip (optional).
    .OUTPUTS
        Structured hashtable with all Intune data.
    .EXAMPLE
        $intuneData = Get-IntuneData -DeviceName "DESKTOP-ABC123" -TenantId "contoso.onmicrosoft.com"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter()]
        [array]$DeviceGroups,

        [Parameter()]
        [string[]]$Skip = @()
    )

    # Initialize result structure
    $result = @{
        azureADDevice          = $null
        managedDevice          = $null
        deviceGroups           = @()
        configurationProfiles  = @()
        applications           = @()
        compliancePolicies     = @()
        proactiveRemediations  = @()
        assignmentFilters      = @()
        collectionTimestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }

    try {
        Write-StatusMessage "Starting Intune data collection for: $DeviceName" -Type Progress
        Write-Host ""

        # Verify Graph connection (auth should have happened in Phase 0)
        if (-not $script:GraphConnected) {
            Write-StatusMessage "Graph API not connected. Skipping Intune collection." -Type Error
            $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Intune collection aborted: Graph not connected" }
            return $result
        }

        # Verify permissions
        $permissions = Get-GraphPermissions
        if (-not $permissions.HasAllPermissions) {
            Write-StatusMessage "Warning: Missing some required permissions. Collection may be incomplete." -Type Warning
        }

        #region Resilient Device Identity Resolution
        # Goal: By the end of this section, we need:
        #   - Azure AD object ID (id) -> for /devices/{id}/transitiveMemberOf (group queries)
        #   - Hardware device ID (deviceId/azureADDeviceId) -> for Intune managed device matching
        # We try multiple sources and cross-reference to fill in missing pieces.

        Write-StatusMessage "Step 1/6: Resolving device identity..." -Type Progress
        Write-Host ""

        $azureADDevice = $null
        $managedDevice = $null

        # Track what IDs we have resolved
        $resolvedIds = @{
            AzureADObjectId = $null      # id from Azure AD - for group membership queries
            HardwareDeviceId = $null     # deviceId/azureADDeviceId - for Intune matching
            IntuneDeviceId = $null       # id from Intune managed device record
        }

        # --- Phase 1: Try Azure AD lookup by device name ---
        Write-StatusMessage "  Phase 1: Querying Azure AD by device name..." -Type Info
        $azureADDevice = Find-AzureADDevice -DeviceName $DeviceName

        if ($azureADDevice) {
            Write-StatusMessage "  Found device in Azure AD: $($azureADDevice.DisplayName)" -Type Success
            if (-not [string]::IsNullOrEmpty($azureADDevice.ObjectId)) {
                $resolvedIds.AzureADObjectId = $azureADDevice.ObjectId
                Write-StatusMessage "    Azure AD object ID (id): $($azureADDevice.ObjectId)" -Type Info
            }
            if (-not [string]::IsNullOrEmpty($azureADDevice.DeviceId)) {
                $resolvedIds.HardwareDeviceId = $azureADDevice.DeviceId
                Write-StatusMessage "    Hardware device ID (deviceId): $($azureADDevice.DeviceId)" -Type Info
            }
        }
        else {
            Write-StatusMessage "  Device not found in Azure AD by name" -Type Warning
        }

        # --- Phase 2: Try Intune lookup ---
        Write-StatusMessage "  Phase 2: Querying Intune for managed device..." -Type Info

        if (-not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
            # We have hardware device ID from Azure AD - use it for precise Intune lookup
            Write-StatusMessage "    Using hardware device ID for Intune lookup: $($resolvedIds.HardwareDeviceId)" -Type Info
            $managedDevice = Get-IntuneDevice -AzureADDeviceId $resolvedIds.HardwareDeviceId
        }
        else {
            # No hardware device ID yet - try name-based lookup
            Write-StatusMessage "    No hardware device ID available, trying name lookup..." -Type Info
            $managedDevice = Get-IntuneDevice -DeviceName $DeviceName
        }

        if ($managedDevice) {
            Write-StatusMessage "  Found Intune managed device: $($managedDevice.DeviceName)" -Type Success
            $resolvedIds.IntuneDeviceId = $managedDevice.Id
            Write-StatusMessage "    Intune device ID: $($managedDevice.Id)" -Type Info

            # Extract AzureADDeviceId from Intune record
            if (-not [string]::IsNullOrEmpty($managedDevice.AzureADDeviceId)) {
                Write-StatusMessage "    azureADDeviceId from Intune: $($managedDevice.AzureADDeviceId)" -Type Info

                # Backfill hardware device ID if we didn't get it from Azure AD
                if ([string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
                    $resolvedIds.HardwareDeviceId = $managedDevice.AzureADDeviceId
                    Write-StatusMessage "    Backfilled hardware device ID from Intune record" -Type Success
                }
            }
        }
        else {
            Write-StatusMessage "  Device not found in Intune" -Type Warning
        }

        # --- Phase 3: Cross-reference to fill gaps ---
        Write-StatusMessage "  Phase 3: Cross-referencing to fill identity gaps..." -Type Info

        # If we have hardware device ID but no Azure AD object ID, query Azure AD by deviceId
        if ([string]::IsNullOrEmpty($resolvedIds.AzureADObjectId) -and
            -not [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
            Write-StatusMessage "    Missing Azure AD object ID - querying by hardware device ID..." -Type Info
            $recoveredDevice = Find-AzureADDevice -DeviceName $DeviceName -DeviceId $resolvedIds.HardwareDeviceId

            if ($recoveredDevice -and -not [string]::IsNullOrEmpty($recoveredDevice.ObjectId)) {
                $azureADDevice = $recoveredDevice
                $resolvedIds.AzureADObjectId = $recoveredDevice.ObjectId
                Write-StatusMessage "    Recovered Azure AD object ID: $($recoveredDevice.ObjectId)" -Type Success

                # Also update hardware device ID if Azure AD returned it
                if (-not [string]::IsNullOrEmpty($recoveredDevice.DeviceId)) {
                    $resolvedIds.HardwareDeviceId = $recoveredDevice.DeviceId
                }
            }
            else {
                Write-StatusMessage "    Could not recover Azure AD object ID" -Type Warning
            }
        }

        # If we have Azure AD object ID but no hardware device ID, and Intune wasn't found,
        # we can't do Intune matching - log this clearly
        if (-not [string]::IsNullOrEmpty($resolvedIds.AzureADObjectId) -and
            [string]::IsNullOrEmpty($resolvedIds.HardwareDeviceId)) {
            Write-StatusMessage "    WARNING: Have Azure AD object ID but no hardware device ID" -Type Warning
            Write-StatusMessage "    Group memberships will work, but Intune device matching may fail" -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Device identity incomplete: Azure AD deviceId (hardware ID) unavailable" }
        }

        # --- Phase 4: Summary ---
        Write-Host ""
        Write-StatusMessage "  Identity Resolution Summary:" -Type Info
        Write-StatusMessage "    Azure AD object ID (for groups): $(if ($resolvedIds.AzureADObjectId) { $resolvedIds.AzureADObjectId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.AzureADObjectId) { 'Success' } else { 'Warning' })
        Write-StatusMessage "    Hardware device ID (for Intune): $(if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.HardwareDeviceId) { 'Success' } else { 'Warning' })
        Write-StatusMessage "    Intune device ID: $(if ($resolvedIds.IntuneDeviceId) { $resolvedIds.IntuneDeviceId } else { 'NOT RESOLVED' })" -Type $(if ($resolvedIds.IntuneDeviceId) { 'Success' } else { 'Warning' })
        Write-Host ""

        # --- Store results ---
        if ($azureADDevice) {
            $result.azureADDevice = @{
                id                            = $azureADDevice.ObjectId
                deviceId                      = if ($resolvedIds.HardwareDeviceId) { $resolvedIds.HardwareDeviceId } else { $azureADDevice.DeviceId }
                displayName                   = $azureADDevice.DisplayName
                operatingSystem               = $azureADDevice.OperatingSystem
                operatingSystemVersion        = $azureADDevice.OSVersion
                trustType                     = $azureADDevice.TrustType
                isManaged                     = $azureADDevice.IsManaged
                isCompliant                   = $azureADDevice.IsCompliant
                approximateLastSignInDateTime = $azureADDevice.ApproximateLastSignInDateTime
                registrationDateTime          = $azureADDevice.RegistrationDateTime
            }
        }

        if ($managedDevice) {
            $result.managedDevice = @{
                id                = $managedDevice.Id
                azureADDeviceId   = $managedDevice.AzureADDeviceId
                deviceName        = $managedDevice.DeviceName
                complianceState   = $managedDevice.ComplianceState
                managementState   = $managedDevice.ManagementState
                lastSyncDateTime  = $managedDevice.LastSyncDateTime
                managementAgent   = $managedDevice.ManagementAgent
                enrolledDateTime  = $managedDevice.EnrolledDateTime
                operatingSystem   = $managedDevice.OperatingSystem
                osVersion         = $managedDevice.OSVersion
                userPrincipalName = $managedDevice.UserPrincipalName
            }
        }

        # Store resolved IDs for use in downstream queries
        $result.resolvedIds = $resolvedIds

        #endregion Resilient Device Identity Resolution

        # Step 2: Get Device Group Memberships
        # Use resolved Azure AD object ID for /devices/{id}/memberOf query
        if ('GroupMemberships' -in $Skip) {
            Write-StatusMessage "Step 2/6: Skipping device group memberships (disabled via -Skip parameter)" -Type Info
        }
        else {
            Write-StatusMessage "Step 2/6: Getting device group memberships..." -Type Progress
            if ($DeviceGroups) {
                $result.deviceGroups = $DeviceGroups
            }
            elseif (-not [string]::IsNullOrEmpty($resolvedIds.AzureADObjectId)) {
                Write-StatusMessage "  Using resolved Azure AD object ID: $($resolvedIds.AzureADObjectId)" -Type Info
                $deviceGroupMemberships = Get-DeviceGroupMemberships -AzureADObjectId $resolvedIds.AzureADObjectId
                $result.deviceGroups = @($deviceGroupMemberships | ForEach-Object {
                    @{
                        id              = $_.ObjectId
                        displayName     = $_.DisplayName
                        description     = $_.Description
                        groupType       = $_.GroupType
                        membershipRule  = $_.MembershipRule
                    }
                })
            }
            else {
                Write-StatusMessage "Skipping device group memberships: Azure AD device object ID unavailable" -Type Warning
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Device group memberships skipped: Azure AD device object ID not available" }
            }
        }

        # Build group ID lists for targeting evaluation
        $deviceGroupIds = @($result.deviceGroups | ForEach-Object { $_.id })

        # Step 4: Collect Assignment Filters
        Write-StatusMessage "Step 4/6: Collecting assignment filters..." -Type Progress
        $filters = Get-AssignmentFilters
        $result.assignmentFilters = @($filters | ForEach-Object {
            @{
                id                             = $_.Id
                displayName                    = $_.DisplayName
                platform                       = $_.Platform
                rule                           = $_.Rule
                assignmentFilterManagementType = $_.AssignmentFilterManagementType
            }
        })

        # Helper function to evaluate targeting
        # Note: Our assignment objects now have pre-resolved properties:
        #   TargetType: "All Devices", "All Users", "Group: <id>", "Exclude: <id>", "Exclude Group: <id>"
        #   GroupId: The group ID for group-based assignments
        #   FilterId: Assignment filter ID
        #   FilterType: "include" or "exclude"
        #   Intent: For apps - "Required", "Available", "Uninstall"
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
                    $filterMatch = $result.assignmentFilters | Where-Object { $_.id -eq $assignment.FilterId }
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
                        # Only show groups the device is actually a member of
                        $groupName = ($result.deviceGroups | Where-Object { $_.id -eq $groupId }).displayName

                        if ($groupId -in $deviceGroupIds) {
                            # Device IS member of this group
                            $targetingStatus = "Device Group: $groupName"
                            $targetGroups += "$groupName ✓"
                        }
                        # Skip groups device is not member of - they're not relevant for troubleshooting
                    }
                    'Exclude:*' {
                        if ($groupId -in $deviceGroupIds) {
                            $targetingStatus = 'Excluded'
                            $groupName = ($result.deviceGroups | Where-Object { $_.id -eq $groupId }).displayName
                            $targetGroups += "Excluded: $groupName"
                        }
                    }
                    'Exclude Group:*' {
                        if ($groupId -in $deviceGroupIds) {
                            $targetingStatus = 'Excluded'
                            $groupName = ($result.deviceGroups | Where-Object { $_.id -eq $groupId }).displayName
                            $targetGroups += "Excluded: $groupName"
                        }
                    }
                }
            }

            # Build targetingStatus from all matched groups (comma-joined)
            $matchedGroups = @($targetGroups | Where-Object { $_ -notlike 'Excluded:*' })
            if ($matchedGroups.Count -gt 0) {
                # Strip ✓ markers for clean display
                $targetingStatus = ($matchedGroups | ForEach-Object { $_ -replace ' ✓$', '' }) -join ', '
            }

            return @{
                targetingStatus  = $targetingStatus
                targetGroups     = $targetGroups
                assignmentFilter = $assignmentFilter
                intent           = $intent
            }
        }

        # Step 5: Collect Configuration Profiles - Use Device Configuration States as Source of Truth
        if ('ConfigProfiles' -in $Skip) {
            Write-StatusMessage "Step 5/6: Skipping configuration profiles (disabled via -Skip parameter)" -Type Info
        }
        else {
            Write-StatusMessage "Step 5/6: Collecting configuration profiles..." -Type Progress

            # Query all configuration profiles with assignments to determine which groups assigned them
            Write-StatusMessage "Querying configuration profile assignments..." -Type Progress
            $allConfigProfiles = Get-ConfigurationProfiles

            # Create lookup map by profile ID and name for matching
            $profileLookup = @{}
            foreach ($profile in $allConfigProfiles) {
                if ($profile.Id) {
                    $profileLookup[$profile.Id] = $profile
                }
                # Also index by display name for matching when we only have the name
                $profileLookup[$profile.DisplayName] = $profile
            }

            # NEW APPROACH: Filter profiles by assignment matching, then query deviceStatuses
            # This replaces the deprecated deviceConfigurationStates API
            if (-not [string]::IsNullOrEmpty($resolvedIds.IntuneDeviceId)) {
                # Use Reports API as authoritative source for deployed policies
                # Per Microsoft documentation, Reports API returns what's actually deployed
                # No pre-filtering needed - we'll look up each deployed policy in the full tenant collection
                Write-StatusMessage "Querying Reports API for deployed policies..." -Type Progress
                Write-DeviceDNALog -Message "Using Reports API as source of truth for device $($resolvedIds.IntuneDeviceId)" -Component "Get-IntuneData" -Type 1
                Write-DeviceDNALog -Message "Total tenant profiles available for lookup: $($allConfigProfiles.Count)" -Component "Get-IntuneData" -Type 1

                # Query Reports API to get all policy statuses for this device
                Write-StatusMessage "Creating device configuration status report..." -Type Progress
                Write-DeviceDNALog -Message "Using Reports API: DeviceConfigurationPolicyStatuses for device $($resolvedIds.IntuneDeviceId)" -Component "Get-IntuneData" -Type 1

                $deploymentStates = @()
                try {
                    # Create export job for device configuration policy statuses
                    $reportBody = @{
                        reportName = "DeviceConfigurationPolicyStatuses"
                        filter = "IntuneDeviceId eq '$($resolvedIds.IntuneDeviceId)'"
                        format = "csv"
                    } | ConvertTo-Json

                    $exportJobUri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"
                    $exportJob = Invoke-MgGraphRequest -Uri $exportJobUri -Method POST -Body $reportBody -ContentType "application/json" -ErrorAction Stop

                    Write-DeviceDNALog -Message "Export job created: $($exportJob.id)" -Component "Get-IntuneData" -Type 1

                    # Poll for job completion using exponential backoff (timeout after 60 seconds)
                    $jobId = $exportJob.id
                    $jobUri = "$exportJobUri/$jobId"

                    Write-StatusMessage "Waiting for report generation..." -Type Progress

                    $jobStatus = Wait-ExportJobCompletion -JobUri $jobUri -MaxWaitSeconds 60

                    if (-not $jobStatus) {
                        throw "Export job failed or timed out"
                    }

                    # Download the report
                    Write-StatusMessage "Downloading configuration status report..." -Type Progress
                    $reportUrl = $jobStatus.url

                    # Report URL is Azure Blob Storage (not Graph API), returns ZIP file
                    # Pattern verified from Microsoft samples:
                    # https://github.com/microsoftgraph/powershell-intune-samples/blob/master/IntuneDataExport/Export-IntuneData.ps1
                    $tempGuid = [guid]::NewGuid()
                    $tempZip = Join-Path $env:TEMP "DeviceDNA_Report_$tempGuid.zip"
                    $tempExtract = Join-Path $env:TEMP "DeviceDNA_Report_$tempGuid"

                    # Download ZIP from blob storage (use Invoke-WebRequest, not Invoke-MgGraphRequest)
                    Invoke-WebRequest -Uri $reportUrl -Method Get -OutFile $tempZip -ErrorAction Stop
                    Write-DeviceDNALog -Message "ZIP file downloaded from blob storage" -Component "Get-IntuneData" -Type 1

                    # Extract ZIP
                    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop
                    Write-DeviceDNALog -Message "ZIP file extracted" -Component "Get-IntuneData" -Type 1

                    # Find CSV file (should be [exportJobId].csv)
                    $csvFile = Get-ChildItem -Path $tempExtract -Filter "*.csv" -File | Select-Object -First 1
                    if (-not $csvFile) {
                        throw "No CSV file found in ZIP archive"
                    }
                    Write-DeviceDNALog -Message "Found report file: $($csvFile.Name)" -Component "Get-IntuneData" -Type 1

                    # Parse CSV - Import-Csv creates PSObjects with NoteProperties
                    # Each row has .PolicyId, .PolicyName, etc. as string properties
                    # This avoids ConvertFrom-Json nested array issues in PS 5.1
                    $reportRows = @(Import-Csv -Path $csvFile.FullName)

                    # Cleanup temp files
                    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
                    Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

                    Write-DeviceDNALog -Message "Parsed $($reportRows.Count) report rows from CSV" -Component "Get-IntuneData" -Type 1

                    Write-DeviceDNALog -Message "Report downloaded: $($reportRows.Count) policy statuses" -Component "Get-IntuneData" -Type 1
                    Write-StatusMessage "Found $($reportRows.Count) policy statuses from Intune" -Type Info

                    # Deduplicate report data by PolicyId (prefer rows with populated UPN)
                    # Microsoft returns multiple rows per policy (device context + user context)
                    $uniquePolicies = @{}
                    foreach ($reportRow in $reportRows) {
                        $policyId = $reportRow.PolicyId

                        if (-not $uniquePolicies.ContainsKey($policyId)) {
                            $uniquePolicies[$policyId] = $reportRow
                        }
                        elseif ([string]::IsNullOrEmpty($uniquePolicies[$policyId].UPN) -and -not [string]::IsNullOrEmpty($reportRow.UPN)) {
                            # Replace empty UPN row with populated UPN row
                            $uniquePolicies[$policyId] = $reportRow
                        }
                    }

                    Write-DeviceDNALog -Message "Deduplicated to $($uniquePolicies.Count) unique policies" -Component "Get-IntuneData" -Type 1
                    Write-StatusMessage "Processing $($uniquePolicies.Count) unique deployed policies..." -Type Progress

                    # Match each deployed policy with full profile metadata from tenant collection
                    foreach ($policyId in $uniquePolicies.Keys) {
                        $reportRow = $uniquePolicies[$policyId]
                        $policyName = $reportRow.PolicyName
                        $policyStatus = $reportRow.PolicyStatus

                        # Find matching profile from all tenant profiles (not filtered by assignment)
                        $matchedProfile = $allConfigProfiles | Where-Object { $_.Id -eq $policyId }

                        if ($matchedProfile) {
                            $deploymentStates += [PSCustomObject]@{
                                ProfileId       = $policyId
                                Profile         = $matchedProfile
                                IsDeployed      = $true
                                State           = $policyStatus
                                LastReportedDateTime = $null
                                UserPrincipalName = $reportRow.UPN
                                SettingStates   = @()  # Reports API doesn't include setting states
                                NotDeployedReason = $null
                            }
                        }
                        else {
                            # Policy deployed but not found in tenant collection
                            # This can happen with certain policy types (certificates, security baselines, etc.)
                            Write-DeviceDNALog -Message "Policy deployed but not found in tenant collection: $policyName ($policyId) - Type: $($reportRow.UnifiedPolicyType)" -Component "Get-IntuneData" -Type 2

                            # Create minimal profile object from Reports API data
                            $minimalProfile = [PSCustomObject]@{
                                Id           = $policyId
                                DisplayName  = $policyName
                                Description  = "Deployed on device (not found in tenant profile collection)"
                                PolicyType   = $reportRow.UnifiedPolicyType
                                Platform     = $reportRow.UnifiedPolicyPlatformType
                                OdataType    = $null
                                Assignments  = @()
                            }

                            $deploymentStates += [PSCustomObject]@{
                                ProfileId       = $policyId
                                Profile         = $minimalProfile
                                IsDeployed      = $true
                                State           = $policyStatus
                                LastReportedDateTime = $null
                                UserPrincipalName = $reportRow.UPN
                                SettingStates   = @()
                                NotDeployedReason = $null
                            }
                        }
                    }
                }
                catch {
                    Write-StatusMessage "Error querying configuration status report: $($_.Exception.Message)" -Type Error
                    Write-DeviceDNALog -Message "Reports API failed: $($_.Exception.Message)" -Component "Get-IntuneData" -Type 3
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error querying device configuration status report: $($_.Exception.Message)" }
                }

                # Collect per-setting error details for failed profiles via Reports API
                # Uses ADMXSettingsByDeviceByPolicy export (replaces deprecated deviceConfigurationStates endpoint)
                # Note: This report covers ADMX/Settings Catalog profiles; other types degrade gracefully with empty settingStates
                try {
                    $errorStates = @($deploymentStates | Where-Object { $_.State -eq 5 })
                    if ($errorStates.Count -gt 0) {
                        Write-StatusMessage "Collecting error details for $($errorStates.Count) failed configuration profile(s)..." -Type Progress
                        Write-DeviceDNALog -Message "Using Reports API: ADMXSettingsByDeviceByPolicy for per-setting error details" -Component "Get-IntuneData" -Type 1

                        # Create export job for per-setting status filtered by device
                        $settingReportBody = @{
                            reportName = "ADMXSettingsByDeviceByPolicy"
                            filter = "DeviceId eq '$($resolvedIds.IntuneDeviceId)'"
                            format = "csv"
                        } | ConvertTo-Json

                        $settingExportJobUri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"
                        $settingExportJob = Invoke-MgGraphRequest -Uri $settingExportJobUri -Method POST -Body $settingReportBody -ContentType "application/json" -ErrorAction Stop

                        Write-DeviceDNALog -Message "Setting states export job created: $($settingExportJob.id)" -Component "Get-IntuneData" -Type 1

                        # Poll for job completion using exponential backoff (timeout after 60 seconds)
                        $settingJobId = $settingExportJob.id
                        $settingJobUri = "$settingExportJobUri/$settingJobId"

                        $settingJobStatus = Wait-ExportJobCompletion -JobUri $settingJobUri -MaxWaitSeconds 60

                        if (-not $settingJobStatus) {
                            throw "Setting states export job failed or timed out"
                        }

                        # Download and extract the report
                        $settingReportUrl = $settingJobStatus.url
                        $settingTempGuid = [guid]::NewGuid()
                        $settingTempZip = Join-Path $env:TEMP "DeviceDNA_SettingReport_$settingTempGuid.zip"
                        $settingTempExtract = Join-Path $env:TEMP "DeviceDNA_SettingReport_$settingTempGuid"

                        Invoke-WebRequest -Uri $settingReportUrl -Method Get -OutFile $settingTempZip -ErrorAction Stop
                        Expand-Archive -Path $settingTempZip -DestinationPath $settingTempExtract -Force -ErrorAction Stop

                        $settingCsvFile = Get-ChildItem -Path $settingTempExtract -Filter "*.csv" -File | Select-Object -First 1
                        if (-not $settingCsvFile) {
                            throw "No CSV file found in setting states ZIP archive"
                        }

                        $settingRows = @(Import-Csv -Path $settingCsvFile.FullName)

                        # Cleanup temp files
                        Remove-Item $settingTempZip -Force -ErrorAction SilentlyContinue
                        Remove-Item $settingTempExtract -Recurse -Force -ErrorAction SilentlyContinue

                        Write-DeviceDNALog -Message "Parsed $($settingRows.Count) per-setting status rows from CSV" -Component "Get-IntuneData" -Type 1

                        # Group setting rows by PolicyId for lookup
                        $settingsByPolicy = @{}
                        foreach ($settingRow in $settingRows) {
                            $settingPolicyId = $settingRow.PolicyId
                            if (-not $settingsByPolicy.ContainsKey($settingPolicyId)) {
                                $settingsByPolicy[$settingPolicyId] = @()
                            }
                            $settingsByPolicy[$settingPolicyId] += $settingRow
                        }

                        # Attach per-setting details to each error state profile
                        foreach ($errorState in $errorStates) {
                            if ($settingsByPolicy.ContainsKey($errorState.ProfileId)) {
                                $matchedSettings = $settingsByPolicy[$errorState.ProfileId]
                                Write-DeviceDNALog -Message "Found $($matchedSettings.Count) setting states for profile $($errorState.Profile.DisplayName)" -Component "Get-IntuneData" -Type 1

                                $errorState.SettingStates = @($matchedSettings | ForEach-Object {
                                    [PSCustomObject]@{
                                        SettingName      = $_.SettingName
                                        Setting          = $_.SettingId
                                        State            = $_.SettingStatus
                                        ErrorCode        = $_.ErrorCode
                                        ErrorDescription = $_.ErrorType
                                        CurrentValue     = $null
                                    }
                                })
                            }
                            else {
                                Write-DeviceDNALog -Message "No per-setting data available for profile $($errorState.Profile.DisplayName) ($($errorState.ProfileId))" -Component "Get-IntuneData" -Type 2
                            }
                        }

                        Write-StatusMessage "Error details collected for $($errorStates.Count) failed profile(s)" -Type Success
                    }
                }
                catch {
                    Write-StatusMessage "Warning: Could not retrieve detailed error information: $($_.Exception.Message)" -Type Warning
                    Write-DeviceDNALog -Message "ADMXSettingsByDeviceByPolicy report failed: $($_.Exception.Message)" -Component "Get-IntuneData" -Type 2
                    # Non-fatal error - continue without detailed error codes
                }

                # Step 3: Build final profile objects for deployed policies
                Write-StatusMessage "Found $($deploymentStates.Count) deployed configuration profiles" -Type Info
                Write-DeviceDNALog -Message "Found $($deploymentStates.Count) total configuration profiles (deployed on device)" -Component "Get-IntuneData" -Type 1

                foreach ($state in $deploymentStates) {
                    $profile = $state.Profile

                    # Get targeting info (shows ALL groups, not filtered)
                    $targeting = & $evaluateTargeting $profile.Assignments $deviceGroupIds

                    # Determine deployment status and reason
                    if ($state.IsDeployed) {
                        $targetingStatus = $targeting.targetingStatus

                        # If deployed but targeting shows "Not Targeted", the device/user
                        # isn't in any of the assigned groups we know about. Keep as-is —
                        # we can't determine the matching group from available data.

                        $notDeployedReason = $null
                    }
                    else {
                        # Determine WHY not deployed
                        $targetingStatus = 'Not Applied'
                        $notDeployedReason = Get-NotDeployedReason -Targeting $targeting -Profile $profile -DeviceGroupIds $deviceGroupIds -UserGroupIds $userGroupIds
                    }

                    # Map numeric PolicyStatus to human-readable string
                    $deploymentStateText = switch ([int]$state.State) {
                        1 { 'Not Applicable' }
                        2 { 'Succeeded' }
                        5 { 'Error' }
                        default { "Unknown ($($state.State))" }
                    }

                    $result.configurationProfiles += @{
                        id                   = $state.ProfileId
                        displayName          = $profile.DisplayName
                        description          = $profile.Description
                        policyType           = $profile.PolicyType
                        platform             = $profile.Platform
                        targetingStatus      = $targetingStatus
                        notDeployedReason    = $notDeployedReason
                        assignments          = @($profile.Assignments)
                        targetGroups         = $targeting.targetGroups
                        assignmentFilter     = $targeting.assignmentFilter
                        deploymentState      = $deploymentStateText
                        settingStates        = if ($state.IsDeployed) { $state.SettingStates } else { @() }
                        lastReportedDateTime = $state.LastReportedDateTime
                        complianceGracePeriodExpirationDateTime = $state.ComplianceGracePeriodExpirationDateTime
                        userPrincipalName    = $state.UserPrincipalName
                        createdDateTime      = $profile.CreatedDateTime
                        lastModifiedDateTime = $profile.LastModifiedDateTime
                        settings             = @()
                    }
                }

                # Collect per-profile settings (the actual configured values)
                if ('ConfigProfileSettings' -in $Skip) {
                    Write-StatusMessage "Skipping profile settings collection (disabled via -Skip parameter)" -Type Info
                }
                else {
                    $deployedProfiles = @($result.configurationProfiles | Where-Object { $_.deploymentState -ne 'Not Applicable' })
                    if ($deployedProfiles.Count -gt 0) {
                        Write-StatusMessage "Collecting profile settings for $($deployedProfiles.Count) deployed profiles..." -Type Progress
                        $settingsIndex = 0
                        foreach ($profileObj in $deployedProfiles) {
                            $settingsIndex++
                            $pType = $profileObj.policyType
                            # Only collect for supported policy types
                            if ($pType -in @('Settings Catalog', 'Device Configuration', 'Administrative Template', 'Endpoint Security')) {
                                Write-StatusMessage "  Collecting settings [$settingsIndex/$($deployedProfiles.Count)]: $($profileObj.displayName)" -Type Progress
                                $profileSettings = Get-ProfileSettings -PolicyId $profileObj.id -PolicyType $pType
                                if ($profileSettings -and $profileSettings.Count -gt 0) {
                                    $profileObj.settings = @($profileSettings)
                                }
                            }
                        }
                        $withSettings = @($deployedProfiles | Where-Object { $_.settings.Count -gt 0 }).Count
                        Write-StatusMessage "Collected settings for $withSettings of $($deployedProfiles.Count) deployed profiles" -Type Success
                        Write-DeviceDNALog -Message "Profile settings collected: $withSettings of $($deployedProfiles.Count) deployed profiles have settings data" -Component "Get-IntuneData" -Type 1
                    }
                }

                Write-StatusMessage "Found $($result.configurationProfiles.Count) total configuration profiles ($deployedCount deployed, $notDeployedCount not deployed)" -Type Success
            }
            else {
                Write-StatusMessage "Skipping configuration profiles: Intune device ID unavailable" -Type Warning
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "Configuration profiles skipped: Intune device ID not available" }
            }
        }

        # Step 5b: Collect Applications
        if ('IntuneApps' -in $Skip) {
            Write-StatusMessage "Skipping applications (disabled via -Skip parameter)" -Type Info
            $apps = @()
        }
        else {
            Write-StatusMessage "Collecting applications..." -Type Progress
            $apps = Get-IntuneApplications
        }

        foreach ($app in $apps) {
            $targeting = & $evaluateTargeting $app.Assignments $deviceGroupIds

            # Only include apps that are actually assigned to this device/user
            if ($targeting.targetingStatus -notin @('Not Targeted', 'Excluded')) {
                $result.applications += @{
                    id               = $app.Id
                    displayName      = $app.DisplayName
                    description      = $app.Description
                    appType          = $app.AppType
                    publisher        = $app.Publisher
                    version          = $app.Version
                    targetingStatus  = $targeting.targetingStatus
                    intent           = $targeting.intent
                    targetGroups     = $targeting.targetGroups
                    assignmentFilter = $targeting.assignmentFilter
                    installedOnDevice = $false
                }
            }
        }

        # Query app install statuses using local IME registry (instant vs ~2-3min Reports API)
        if ($result.applications.Count -gt 0) {
            try {
                $target = if ([string]::IsNullOrEmpty($script:TargetComputer)) { 'localhost' } else { $script:TargetComputer }
                Write-StatusMessage "Querying install status for $($result.applications.Count) apps via local registry..." -Type Progress
                Write-DeviceDNALog -Message "Querying app install status via local IME registry on $target" -Component "Get-IntuneData" -Type 1

                $localAppMap = Get-LocalIntuneApplications -ComputerName $target -IncludeUserContext

                $matchCount = 0
                foreach ($app in $result.applications) {
                    if (-not $app.id) { continue }

                    $regData = $localAppMap[$app.id]
                    if ($regData) {
                        $matchCount++
                        $app.appInstallState = $regData.InstallState
                        $app.appInstallStateDetails = "Compliance=$($regData.ComplianceState), Enforcement=$($regData.EnforcementState)"
                        $app.installErrorCode = $regData.ErrorCode
                        $app.installedOnDevice = ($regData.InstallState -eq 'Installed')
                    }
                }

                Write-StatusMessage "Found install status for $matchCount/$($result.applications.Count) apps via local registry" -Type Info
                Write-DeviceDNALog -Message "App install status: $matchCount matches out of $($result.applications.Count) apps from local IME registry" -Component "Get-IntuneData" -Type 1
            }
            catch {
                Write-DeviceDNALog -Message "Failed to query local IME registry for app install status: $($_.Exception.Message)" -Component "Get-IntuneData" -Type 2
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Intune"; message = "App install status from local registry failed: $($_.Exception.Message)" }
                Write-StatusMessage "Could not query local app install status: $($_.Exception.Message)" -Type Warning
            }
        }

        # Step 6: Collect Compliance Policies and States
        if ('CompliancePolicies' -in $Skip) {
            Write-StatusMessage "Step 6/6: Skipping compliance policies (disabled via -Skip parameter)" -Type Info
            $compliancePolicies = @()
        }
        else {
            Write-StatusMessage "Step 6/6: Collecting compliance policies..." -Type Progress
            $compliancePolicies = Get-CompliancePolicies
        }

        # Get device compliance policy states if we have an Intune device ID
        $deviceComplianceStates = @()
        if (-not [string]::IsNullOrEmpty($resolvedIds.IntuneDeviceId)) {
            Write-StatusMessage "Collecting device compliance policy states..." -Type Progress
            $deviceComplianceStates = Get-DeviceCompliancePolicyStates -IntuneDeviceId $resolvedIds.IntuneDeviceId
        }
        else {
            Write-StatusMessage "Skipping device compliance states: Intune device ID unavailable" -Type Warning
        }

        foreach ($policy in $compliancePolicies) {
            $targeting = & $evaluateTargeting $policy.Assignments $deviceGroupIds

            # Only include policies that are actually assigned to this device/user
            if ($targeting.targetingStatus -notin @('Not Targeted', 'Excluded')) {
                # Match compliance state by PolicyId from the report data
                $policyState = $deviceComplianceStates | Where-Object { $_.PolicyId -eq $policy.Id } | Select-Object -First 1

                $complianceState = 'Unknown'
                if ($policyState) {
                    $complianceState = $policyState.State
                }

                $result.compliancePolicies += @{
                    id               = $policy.Id
                    displayName      = $policy.DisplayName
                    description      = $policy.Description
                    platform         = $policy.Platform
                    targetingStatus  = $targeting.targetingStatus
                    targetGroups     = $targeting.targetGroups
                    assignmentFilter = $targeting.assignmentFilter
                    complianceState  = $complianceState
                }
            }
        }

        # Step 7: Collect Proactive Remediations
        if ('ProactiveRemediations' -in $Skip) {
            Write-StatusMessage "Skipping proactive remediations (disabled via -Skip parameter)" -Type Info
        }
        elseif ([string]::IsNullOrEmpty($resolvedIds.IntuneDeviceId)) {
            Write-StatusMessage "Skipping proactive remediations: Intune device ID unavailable" -Type Warning
        }
        else {
            Write-StatusMessage "Collecting proactive remediations..." -Type Progress

            # Use the per-device deviceHealthScriptStates endpoint — same API the Intune portal uses.
            # Single call returns all health script states for this device.
            # Ref: https://learn.microsoft.com/graph/api/resources/intune-devices-devicehealthscriptpolicystate
            try {
                $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($resolvedIds.IntuneDeviceId)/deviceHealthScriptStates"
                Write-DeviceDNALog -Message "Graph API call: GET deviceHealthScriptStates for device $($resolvedIds.IntuneDeviceId)" -Component "Get-IntuneData" -Type 1

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
                Write-DeviceDNALog -Message "Device health script states: $($allStates.Count) returned across $pageCount page(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-IntuneData" -Type 1

                foreach ($state in $allStates) {
                    $result.proactiveRemediations += @{
                        id               = $state.policyId
                        displayName      = $state.policyName
                        description      = $null
                        publisher        = $null
                        runAsAccount     = $null
                        targetingStatus  = 'Targeted'
                        targetGroups     = @()
                        assignmentFilter = $null
                        deviceRunState   = @{
                            detectionState                       = $state.detectionState
                            remediationState                     = $state.remediationState
                            lastStateUpdateDateTime              = $state.lastStateUpdateDateTime
                            preRemediationDetectionScriptOutput  = $state.preRemediationDetectionScriptOutput
                            remediationScriptError               = $state.remediationScriptError
                            postRemediationDetectionScriptOutput = $state.postRemediationDetectionScriptOutput
                        }
                    }
                }

                Write-StatusMessage "Found $($allStates.Count) proactive remediation states for device" -Type Success
                Write-DeviceDNALog -Message "Proactive remediation collection complete: $($allStates.Count) states" -Component "Get-IntuneData" -Type 1
            }
            catch {
                Write-StatusMessage "Error collecting proactive remediations: $($_.Exception.Message)" -Type Warning
                Write-DeviceDNALog -Message "Proactive remediation collection failed: $($_.Exception.Message)" -Component "Get-IntuneData" -Type 3
                $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Error collecting proactive remediations: $($_.Exception.Message)" }
            }
        }

        # Summary
        Write-Host ""
        Write-StatusMessage "Intune data collection complete!" -Type Success
        Write-StatusMessage "  Azure AD Device: $(if ($result.azureADDevice) { 'Found' } else { 'Not Found' })" -Type Info
        Write-StatusMessage "  Managed Device: $(if ($result.managedDevice) { 'Found' } else { 'Not Found' })" -Type Info
        Write-StatusMessage "  Entra ID Device Groups: $($result.deviceGroups.Count)" -Type Info
        Write-StatusMessage "  Configuration Profiles: $($result.configurationProfiles.Count)" -Type Info
        Write-StatusMessage "  Applications: $($result.applications.Count)" -Type Info
        Write-StatusMessage "  Compliance Policies: $($result.compliancePolicies.Count)" -Type Info
        Write-StatusMessage "  Proactive Remediations: $($result.proactiveRemediations.Count)" -Type Info
        Write-Host ""

        return $result
    }
    catch {
        Write-StatusMessage "Error in Intune data collection: $($_.Exception.Message)" -Type Error
        $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = "Intune collection error: $($_.Exception.Message)" }
        return $result
    }
}
