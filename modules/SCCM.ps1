<#
.SYNOPSIS
    Device DNA - SCCM Module
.DESCRIPTION
    Client-side SCCM/ConfigMgr data collection via local WMI.
    Queries the ConfigMgr client WMI namespaces to collect deployed applications,
    compliance baselines, software updates, client settings, and client info.
    No server-side (SMS Provider) connection required.
.NOTES
    Module: SCCM.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
    WMI Namespaces: root\ccm, root\ccm\ClientSDK, root\ccm\dcm, root\ccm\Policy\Machine\ActualConfig
    Reference: https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/sdk/ccm_application-client-wmi-class
#>

function Test-SCCMClient {
    <#
    .SYNOPSIS
        Checks if the SCCM/ConfigMgr client is installed on the target device.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Boolean indicating if the SCCM client is installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    try {
        $scriptBlock = {
            try {
                $ns = Get-CimInstance -Namespace 'root' -ClassName __Namespace -Filter "Name='ccm'" -ErrorAction Stop
                return ($null -ne $ns)
            }
            catch {
                return $false
            }
        }

        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        return $result
    }
    catch {
        Write-StatusMessage "Failed to check SCCM client status: $($_.Exception.Message)" -Type Warning
        return $false
    }
}

function Get-SCCMClientInfo {
    <#
    .SYNOPSIS
        Collects SCCM client information (version, site code, management point, client ID).
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Hashtable with client info or $null if unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    Write-StatusMessage "Collecting SCCM client info..." -Type Progress

    $scriptBlock = {
        $info = @{
            ClientVersion   = $null
            SiteCode        = $null
            ManagementPoint = $null
            ClientId        = $null
        }

        # Client version from CCM_InstalledComponent
        try {
            $framework = Get-CimInstance -Namespace 'root\ccm' -ClassName CCM_InstalledComponent `
                -Filter "Name='CcmFramework'" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($framework) {
                $info.ClientVersion = $framework.Version
            }
        }
        catch { }

        # Site code from SMS_Authority
        try {
            $authority = Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_Authority `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($authority -and $authority.Name) {
                # SMS_Authority.Name format is "SMS:<SiteCode>"
                $info.SiteCode = $authority.Name -replace '^SMS:', ''
            }
        }
        catch { }

        # Management point from SMS_LookupMP
        try {
            $mp = Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_LookupMP `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mp -and $mp.Name) {
                $info.ManagementPoint = $mp.Name
            }
        }
        catch { }

        # Client ID from registry
        try {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client'
            if (Test-Path $regPath) {
                $clientId = (Get-ItemProperty -Path $regPath -Name 'SMS Unique Identifier' `
                    -ErrorAction SilentlyContinue).'SMS Unique Identifier'
                if ($clientId) {
                    $info.ClientId = $clientId
                }
            }
        }
        catch { }

        return $info
    }

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        if ($result.ClientVersion) {
            Write-StatusMessage "SCCM client version: $($result.ClientVersion), Site: $($result.SiteCode)" -Type Info
        }

        return $result
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "SCCM"; message = "Failed to collect SCCM client info: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to collect SCCM client info: $($_.Exception.Message)" -Type Error
        return $null
    }
}

function Get-SCCMApplications {
    <#
    .SYNOPSIS
        Collects deployed SCCM applications with install state from CCM_Application WMI class.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Array of application hashtables.
    .NOTES
        WMI Class: CCM_Application (root\ccm\ClientSDK)
        Ref: https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/sdk/ccm_application-client-wmi-class
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    Write-StatusMessage "Collecting SCCM deployed applications..." -Type Progress

    $scriptBlock = {
        $apps = @()

        try {
            $cimApps = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName CCM_Application `
                -ErrorAction Stop

            foreach ($app in $cimApps) {
                # Map EvaluationState numeric codes to human-readable strings
                # Ref: ConfigMgr SDK CCM_Application class
                $evalStateMap = @{
                    0  = 'None'
                    1  = 'Available'
                    2  = 'Submitted'
                    3  = 'Detecting'
                    4  = 'PreDownload'
                    5  = 'Downloading'
                    6  = 'WaitInstall'
                    7  = 'Installing'
                    8  = 'PendingSoftReboot'
                    9  = 'PendingHardReboot'
                    10 = 'WaitReboot'
                    11 = 'Verifying'
                    12 = 'InstallComplete'
                    13 = 'Error'
                    14 = 'WaitServiceWindow'
                    15 = 'WaitUserLogon'
                    16 = 'WaitUserLogoff'
                    17 = 'WaitJobUserLogon'
                    18 = 'WaitUserReconnect'
                    19 = 'PendingUserLogoff'
                    20 = 'PendingUpdate'
                    21 = 'WaitingRetry'
                    22 = 'WaitPresModeOff'
                    23 = 'WaitForOrchestration'
                }

                $evalState = $null
                if ($null -ne $app.EvaluationState) {
                    $evalState = $evalStateMap[[int]$app.EvaluationState]
                    if (-not $evalState) { $evalState = "State$($app.EvaluationState)" }
                }

                $apps += @{
                    Name               = $app.Name
                    Publisher          = $app.Publisher
                    Version            = $app.SoftwareVersion
                    InstallState       = if ($app.InstallState) { $app.InstallState } else { 'Unknown' }
                    ApplicabilityState = if ($app.ApplicabilityState) { $app.ApplicabilityState } else { 'Unknown' }
                    EvaluationState    = if ($evalState) { $evalState } else { 'Unknown' }
                    ResolvedState      = $app.ResolvedState
                    IsRequired         = ($app.IsMachineTarget -or $app.EnforcePreference -eq 1)
                    Deadline           = $app.Deadline
                    LastEvalTime       = $app.LastEvalTime
                    ErrorCode          = $app.ErrorCode
                    PercentComplete    = $app.PercentComplete
                }
            }
        }
        catch {
            # Return empty array - caller handles the error
            throw $_
        }

        return $apps
    }

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        $count = if ($result) { @($result).Count } else { 0 }
        Write-StatusMessage "Found $count SCCM deployed applications" -Type Info

        return @($result)
    }
    catch {
        $script:CollectionIssues += @{ severity = "Warning"; phase = "SCCM"; message = "Failed to collect SCCM applications: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to collect SCCM applications: $($_.Exception.Message)" -Type Warning
        return @()
    }
}

function Get-SCCMComplianceBaselines {
    <#
    .SYNOPSIS
        Collects SCCM compliance baselines with compliance state from SMS_DesiredConfiguration.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Array of baseline hashtables.
    .NOTES
        WMI Class: SMS_DesiredConfiguration (root\ccm\dcm)
        Not officially documented in ConfigMgr SDK but well-established in community.
        Ref: https://www.niallbrady.com/2020/06/28/triggering-evaluation-of-sms_desiredconfiguration-instances-on-a-client-using-powershell/
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    Write-StatusMessage "Collecting SCCM compliance baselines..." -Type Progress

    $scriptBlock = {
        $baselines = @()

        try {
            $cimBaselines = Get-CimInstance -Namespace 'root\ccm\dcm' -ClassName SMS_DesiredConfiguration `
                -ErrorAction Stop

            # LastComplianceStatus mapping
            $complianceMap = @{
                0 = 'Non-Compliant'
                1 = 'Compliant'
                2 = 'Not Applicable'
                3 = 'Unknown'
                4 = 'Error'
            }

            foreach ($bl in $cimBaselines) {
                $complianceState = 'Unknown'
                if ($null -ne $bl.LastComplianceStatus) {
                    $complianceState = $complianceMap[[int]$bl.LastComplianceStatus]
                    if (-not $complianceState) { $complianceState = "Status$($bl.LastComplianceStatus)" }
                }

                $baselines += @{
                    Name            = if ($bl.DisplayName) { $bl.DisplayName } else { $bl.Name }
                    Version         = $bl.Version
                    ComplianceState = $complianceState
                    LastEvaluated   = $bl.LastEvalTime
                    IsMachineTarget = $bl.IsMachineTarget
                }
            }
        }
        catch {
            throw $_
        }

        return $baselines
    }

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        $count = if ($result) { @($result).Count } else { 0 }
        Write-StatusMessage "Found $count SCCM compliance baselines" -Type Info

        return @($result)
    }
    catch {
        $script:CollectionIssues += @{ severity = "Warning"; phase = "SCCM"; message = "Failed to collect SCCM baselines: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to collect SCCM compliance baselines: $($_.Exception.Message)" -Type Warning
        return @()
    }
}

function Get-SCCMSoftwareUpdates {
    <#
    .SYNOPSIS
        Collects SCCM software updates with compliance state from CCM_SoftwareUpdate.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Array of software update hashtables.
    .NOTES
        WMI Class: CCM_SoftwareUpdate (root\ccm\ClientSDK)
        Ref: https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/sdk/ccm_softwareupdate-client-wmi-class
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    Write-StatusMessage "Collecting SCCM software updates..." -Type Progress

    $scriptBlock = {
        $updates = @()

        try {
            $cimUpdates = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName CCM_SoftwareUpdate `
                -ErrorAction Stop

            # EvaluationState mapping (same as applications)
            $evalStateMap = @{
                0  = 'None'
                1  = 'Available'
                2  = 'Submitted'
                3  = 'Detecting'
                4  = 'PreDownload'
                5  = 'Downloading'
                6  = 'WaitInstall'
                7  = 'Installing'
                8  = 'PendingSoftReboot'
                9  = 'PendingHardReboot'
                10 = 'WaitReboot'
                11 = 'Verifying'
                12 = 'InstallComplete'
                13 = 'Error'
                14 = 'WaitServiceWindow'
                15 = 'WaitUserLogon'
                16 = 'WaitUserLogoff'
                17 = 'WaitJobUserLogon'
                18 = 'WaitUserReconnect'
                19 = 'PendingUserLogoff'
                20 = 'PendingUpdate'
                21 = 'WaitingRetry'
                22 = 'WaitPresModeOff'
                23 = 'WaitForOrchestration'
            }

            foreach ($upd in $cimUpdates) {
                $evalState = $null
                if ($null -ne $upd.EvaluationState) {
                    $evalState = $evalStateMap[[int]$upd.EvaluationState]
                    if (-not $evalState) { $evalState = "State$($upd.EvaluationState)" }
                }

                $updates += @{
                    ArticleID       = $upd.ArticleID
                    Name            = $upd.Name
                    BulletinID      = $upd.BulletinID
                    IsRequired      = ($upd.ComplianceState -eq 0)
                    EvaluationState = if ($evalState) { $evalState } else { 'Unknown' }
                    PercentComplete = $upd.PercentComplete
                    Deadline        = $upd.Deadline
                    Publisher       = $upd.Publisher
                    ErrorCode       = $upd.ErrorCode
                }
            }
        }
        catch {
            throw $_
        }

        return $updates
    }

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        $count = if ($result) { @($result).Count } else { 0 }
        Write-StatusMessage "Found $count SCCM software updates" -Type Info

        return @($result)
    }
    catch {
        $script:CollectionIssues += @{ severity = "Warning"; phase = "SCCM"; message = "Failed to collect SCCM software updates: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to collect SCCM software updates: $($_.Exception.Message)" -Type Warning
        return @()
    }
}

function Get-SCCMClientSettings {
    <#
    .SYNOPSIS
        Collects SCCM client settings/policies from the ActualConfig WMI namespace.
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Array of client settings category hashtables.
    .NOTES
        WMI Namespace: root\ccm\Policy\Machine\ActualConfig
        Classes are dynamically generated by the ConfigMgr client. Properties are read
        dynamically by iterating CimInstanceProperties, filtering out CIM metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    Write-StatusMessage "Collecting SCCM client settings..." -Type Progress

    $scriptBlock = {
        $clientSettings = @()

        $policyClasses = @(
            @{ Class = 'CCM_ClientAgentConfig';                Name = 'Client Agent' }
            @{ Class = 'CCM_SoftwareUpdatesClientConfig';      Name = 'Software Updates' }
            @{ Class = 'CCM_ApplicationManagementClientConfig'; Name = 'Application Management' }
            @{ Class = 'CCM_ComplianceEvaluationClientConfig';  Name = 'Compliance Settings' }
            @{ Class = 'CCM_HardwareInventoryClientConfig';     Name = 'Hardware Inventory' }
            @{ Class = 'CCM_SoftwareInventoryClientConfig';     Name = 'Software Inventory' }
            @{ Class = 'CCM_RemoteToolsConfig';                 Name = 'Remote Tools' }
            @{ Class = 'CCM_EndpointProtectionClientConfig';    Name = 'Endpoint Protection' }
        )

        foreach ($policy in $policyClasses) {
            try {
                $config = Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' `
                    -ClassName $policy.Class -ErrorAction SilentlyContinue | Select-Object -First 1

                if ($config) {
                    $settings = @{}
                    # Read all properties dynamically, filter out CIM metadata and system properties
                    foreach ($prop in $config.CimInstanceProperties) {
                        if ($prop.Name -notmatch '^(CIM|__)|Reserved|SiteSettingsKey') {
                            $settings[$prop.Name] = $prop.Value
                        }
                    }

                    $clientSettings += @{
                        Category = $policy.Name
                        Settings = $settings
                    }
                }
            }
            catch {
                # Skip individual policy categories that fail — non-fatal
            }
        }

        return $clientSettings
    }

    try {
        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }

        $count = if ($result) { @($result).Count } else { 0 }
        Write-StatusMessage "Collected $count SCCM client settings categories" -Type Info

        return @($result)
    }
    catch {
        $script:CollectionIssues += @{ severity = "Warning"; phase = "SCCM"; message = "Failed to collect SCCM client settings: $($_.Exception.Message)" }
        Write-StatusMessage "Failed to collect SCCM client settings: $($_.Exception.Message)" -Type Warning
        return @()
    }
}

function Get-SCCMData {
    <#
    .SYNOPSIS
        Main SCCM collection function. Aggregates all client-side SCCM data.
    .PARAMETER ComputerName
        Target computer name.
    .PARAMETER Skip
        Array of collection categories to skip (e.g., 'SCCMApps', 'SCCMUpdates').
    .OUTPUTS
        Hashtable with all collected SCCM data, or $null if SCCM client not installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [string[]]$Skip = @()
    )

    Write-StatusMessage "Starting SCCM data collection..." -Type Progress
    Write-DeviceDNALog -Message "Starting SCCM data collection for $ComputerName" -Component "Get-SCCMData" -Type 1

    # Check if SCCM client is installed
    $isInstalled = Test-SCCMClient -ComputerName $ComputerName
    if (-not $isInstalled) {
        Write-StatusMessage "SCCM client not installed — skipping SCCM collection" -Type Info
        Write-DeviceDNALog -Message "SCCM client not detected on $ComputerName" -Component "Get-SCCMData" -Type 1
        return $null
    }

    Write-StatusMessage "SCCM client detected — collecting data..." -Type Success

    $sccmData = @{
        clientInfo      = $null
        applications    = @()
        baselines       = @()
        softwareUpdates = @()
        clientSettings  = @()
    }

    # Step 1: Client info (always collected)
    $sccmData.clientInfo = Get-SCCMClientInfo -ComputerName $ComputerName

    # Step 2: Deployed applications
    if ('SCCMApps' -notin $Skip) {
        $sccmData.applications = Get-SCCMApplications -ComputerName $ComputerName
    }
    else {
        Write-StatusMessage "Skipping SCCM applications (disabled via -Skip)" -Type Info
    }

    # Step 3: Compliance baselines
    if ('SCCMBaselines' -notin $Skip) {
        $sccmData.baselines = Get-SCCMComplianceBaselines -ComputerName $ComputerName
    }
    else {
        Write-StatusMessage "Skipping SCCM baselines (disabled via -Skip)" -Type Info
    }

    # Step 4: Software updates
    if ('SCCMUpdates' -notin $Skip) {
        $sccmData.softwareUpdates = Get-SCCMSoftwareUpdates -ComputerName $ComputerName
    }
    else {
        Write-StatusMessage "Skipping SCCM software updates (disabled via -Skip)" -Type Info
    }

    # Step 5: Client settings
    if ('SCCMSettings' -notin $Skip) {
        $sccmData.clientSettings = Get-SCCMClientSettings -ComputerName $ComputerName
    }
    else {
        Write-StatusMessage "Skipping SCCM client settings (disabled via -Skip)" -Type Info
    }

    Write-DeviceDNALog -Message "SCCM collection complete: $(@($sccmData.applications).Count) apps, $(@($sccmData.baselines).Count) baselines, $(@($sccmData.softwareUpdates).Count) updates" -Component "Get-SCCMData" -Type 1

    return $sccmData
}
