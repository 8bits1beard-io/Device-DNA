<#
.SYNOPSIS
    Device DNA - Group Policy Module
.DESCRIPTION
    Group Policy data collection via gpresult and WinRM.
    Includes RSoP configuration, policy refresh, XML parsing, and installed app inventory.
.NOTES
    Module: GroupPolicy.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

function Set-RSoPLogging {
    <#
    .SYNOPSIS
        Enables or restores RSoP (Resultant Set of Policy) debug logging.
    .DESCRIPTION
        Configures the GPSvcDebugLevel registry value to enable detailed
        Group Policy processing logging for troubleshooting purposes.
    .PARAMETER Enable
        Switch to enable RSoP logging (sets GPSvcDebugLevel to 0x30002).
    .PARAMETER OriginalValue
        Original registry value to restore when disabling logging.
    .PARAMETER ComputerName
        Target computer name for remote execution.
    .OUTPUTS
        Original registry value when enabling, or $null.
    .EXAMPLE
        $original = Set-RSoPLogging -Enable
        # ... perform operations ...
        Set-RSoPLogging -OriginalValue $original
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Enable,

        [Parameter()]
        [object]$OriginalValue,

        [Parameter()]
        [string]$ComputerName
    )

    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics"
    $valueName = "GPSvcDebugLevel"
    $enableValue = 0x30002  # Full debug logging

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        $scriptBlock = {
            param($Path, $Name, $Value, $EnableMode, $RestoreValue)

            try {
                # Ensure the registry path exists
                if (-not (Test-Path $Path)) {
                    $null = New-Item -Path $Path -Force -ErrorAction Stop
                }

                if ($EnableMode) {
                    # Get current value before changing
                    $currentValue = $null
                    try {
                        $currentValue = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
                    }
                    catch {
                        $currentValue = $null
                    }

                    # Set the debug level
                    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop

                    return @{
                        Success = $true
                        OriginalValue = $currentValue
                        Message = "RSoP logging enabled"
                    }
                }
                else {
                    # Restore original value
                    if ($null -eq $RestoreValue) {
                        # Remove the value if it didn't exist before
                        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
                    }
                    else {
                        Set-ItemProperty -Path $Path -Name $Name -Value $RestoreValue -Type DWord -Force -ErrorAction Stop
                    }

                    return @{
                        Success = $true
                        OriginalValue = $null
                        Message = "RSoP logging restored"
                    }
                }
            }
            catch {
                return @{
                    Success = $false
                    OriginalValue = $null
                    Message = "Failed to configure RSoP logging: $($_.Exception.Message)"
                }
            }
        }

        $result = $null

        if ($isLocal) {
            $result = & $scriptBlock -Path $registryPath -Name $valueName -Value $enableValue -EnableMode $Enable.IsPresent -RestoreValue $OriginalValue
        }
        else {
            try {
                $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ArgumentList $registryPath, $valueName, $enableValue, $Enable.IsPresent, $OriginalValue -ErrorAction Stop
            }
            catch {
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to configure RSoP logging on $ComputerName : $($_.Exception.Message)" }
                return $null
            }
        }

        if ($result.Success) {
            Write-StatusMessage $result.Message -Type Info
            return $result.OriginalValue
        }
        else {
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = $result.Message }
            Write-StatusMessage $result.Message -Type Warning
            return $null
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Error in Set-RSoPLogging: $($_.Exception.Message)" }
        Write-StatusMessage "Error configuring RSoP logging: $($_.Exception.Message)" -Type Error
        return $null
    }
}

function Invoke-GPUpdate {
    <#
    .SYNOPSIS
        Executes gpupdate /force on the target machine.
    .DESCRIPTION
        Runs Group Policy update with force flag and parses the output
        to determine success or failure status.
    .PARAMETER ComputerName
        Target computer name for remote execution.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for gpupdate to complete (default: 300 seconds).
    .OUTPUTS
        PSCustomObject with Success boolean and Message string.
    .EXAMPLE
        $result = Invoke-GPUpdate -ComputerName "PC001" -TimeoutSeconds 120
        if ($result.Success) { Write-Host "Update successful" }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [int]$TimeoutSeconds = 300
    )

    $result = [PSCustomObject]@{
        Success        = $false
        Message        = ""
        ComputerPolicy = $null
        UserPolicy     = $null
        RawOutput      = ""
    }

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        $scriptBlock = {
            try {
                $output = & gpupdate /force 2>&1
                $outputString = $output -join "`n"

                # Parse output for success indicators
                $computerSuccess = $outputString -match "Computer Policy update has completed successfully" -or
                                   $outputString -match "Computer policy could not be updated successfully"
                $userSuccess = $outputString -match "User Policy update has completed successfully" -or
                               $outputString -match "User policy could not be updated successfully"

                # Check for explicit failures
                $hasErrors = $outputString -match "failed" -or
                             $outputString -match "error" -or
                             $outputString -match "could not be updated successfully"

                return @{
                    Success = -not $hasErrors
                    Output = $outputString
                    ComputerPolicy = $outputString -match "Computer Policy update has completed successfully"
                    UserPolicy = $outputString -match "User Policy update has completed successfully"
                }
            }
            catch {
                return @{
                    Success = $false
                    Output = "Exception: $($_.Exception.Message)"
                    ComputerPolicy = $false
                    UserPolicy = $false
                }
            }
        }

        Write-StatusMessage "Running gpupdate /force..." -Type Progress

        $gpResult = $null

        if ($isLocal) {
            # Local execution with timeout
            $job = Start-Job -ScriptBlock $scriptBlock
            $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds

            if ($completed) {
                $gpResult = Receive-Job -Job $job
            }
            else {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                $result.Message = "gpupdate timed out after $TimeoutSeconds seconds"
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = $result.Message }
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                return $result
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        else {
            # Remote execution with timeout
            try {
                $gpResult = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop -AsJob |
                    Wait-Job -Timeout $TimeoutSeconds |
                    Receive-Job

                if ($null -eq $gpResult) {
                    $result.Message = "gpupdate timed out on $ComputerName after $TimeoutSeconds seconds"
                    $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = $result.Message }
                    return $result
                }
            }
            catch {
                $result.Message = "Failed to run gpupdate on $ComputerName : $($_.Exception.Message)"
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $result.Message }
                return $result
            }
        }

        if ($gpResult) {
            $result.Success = $gpResult.Success
            $result.RawOutput = $gpResult.Output
            $result.ComputerPolicy = $gpResult.ComputerPolicy
            $result.UserPolicy = $gpResult.UserPolicy

            if ($result.Success) {
                $result.Message = "Group Policy update completed successfully"
                Write-StatusMessage $result.Message -Type Success
            }
            else {
                $result.Message = "Group Policy update completed with warnings or errors"
                Write-StatusMessage $result.Message -Type Warning
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = "gpupdate completed with issues: $($gpResult.Output)" }
            }
        }
    }
    catch {
        $result.Message = "Error executing gpupdate: $($_.Exception.Message)"
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $result.Message }
        Write-StatusMessage $result.Message -Type Error
    }

    return $result
}

function Get-GPResultXml {
    <#
    .SYNOPSIS
        Executes gpresult /X to generate an XML report for computer scope.
    .DESCRIPTION
        Runs gpresult with XML output format for computer configuration.
        Handles temp file creation and cleanup.
    .PARAMETER ComputerName
        Target computer name for remote execution.
    .OUTPUTS
        Raw XML string from gpresult.
    .EXAMPLE
        $xml = Get-GPResultXml -ComputerName "DESKTOP-ABC"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    try {
        Write-DeviceDNALog -Message "Starting gpresult collection for computer scope" -Component "Get-GPResultXml" -Type 1

        $gpStart = Get-Date
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName
        Write-DeviceDNALog -Message "Execution context: $(if ($isLocal) { 'Local' } else { "Remote ($ComputerName)" })" -Component "Get-GPResultXml" -Type 1 -IsDebug

        $scriptBlock = {
            $tempFile = $null
            $xmlContent = $null

            try {
                # Create temp file path
                $tempFile = [System.IO.Path]::Combine($env:TEMP, "gpresult_$(Get-Random).xml")

                # Build gpresult command arguments - computer scope only
                $arguments = @("/X", $tempFile, "/SCOPE", "COMPUTER")

                # Execute gpresult
                $process = Start-Process -FilePath "gpresult.exe" -ArgumentList $arguments -Wait -NoNewWindow -PassThru -RedirectStandardError "$env:TEMP\gpresult_err.txt"

                # Check for errors
                $errorOutput = $null
                if (Test-Path "$env:TEMP\gpresult_err.txt") {
                    $errorOutput = Get-Content "$env:TEMP\gpresult_err.txt" -Raw -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\gpresult_err.txt" -Force -ErrorAction SilentlyContinue
                }

                # Read the XML content
                if (Test-Path $tempFile) {
                    $xmlContent = Get-Content -Path $tempFile -Raw -Encoding UTF8
                }
                else {
                    # Try without /X if it failed (older systems)
                    $tempFile = [System.IO.Path]::Combine($env:TEMP, "gpresult_$(Get-Random).xml")
                    $process = Start-Process -FilePath "gpresult.exe" -ArgumentList "/X", $tempFile, "/F" -Wait -NoNewWindow -PassThru

                    if (Test-Path $tempFile) {
                        $xmlContent = Get-Content -Path $tempFile -Raw -Encoding UTF8
                    }
                }

                return @{
                    Success = ($null -ne $xmlContent)
                    XmlContent = $xmlContent
                    ExitCode = $process.ExitCode
                    ErrorOutput = $errorOutput
                }
            }
            catch {
                return @{
                    Success = $false
                    XmlContent = $null
                    ExitCode = -1
                    ErrorOutput = $_.Exception.Message
                }
            }
            finally {
                # Cleanup temp file
                if ($tempFile -and (Test-Path $tempFile)) {
                    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Write-StatusMessage "Collecting GPResult XML (Computer scope)..." -Type Progress

        $gpResult = $null

        if ($isLocal) {
            $gpResult = & $scriptBlock
        }
        else {
            try {
                $gpResult = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
            }
            catch {
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to collect GPResult XML from $ComputerName : $($_.Exception.Message)" }
                Write-StatusMessage "Failed to collect GPResult XML: $($_.Exception.Message)" -Type Error
                return $null
            }
        }

        $gpDuration = (Get-Date) - $gpStart

        if ($gpResult.Success -and $gpResult.XmlContent) {
            $xmlSize = [math]::Round($gpResult.XmlContent.Length / 1024, 1)
            Write-StatusMessage "GPResult XML collected successfully" -Type Success
            Write-DeviceDNALog -Message "GPResult collection complete: ${xmlSize}KB in $($gpDuration.TotalSeconds.ToString('F1'))s" -Component "Get-GPResultXml" -Type 1
            return $gpResult.XmlContent
        }
        else {
            $errorMsg = "Failed to generate GPResult XML"
            if ($gpResult.ErrorOutput) {
                $errorMsg += ": $($gpResult.ErrorOutput)"
            }
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = $errorMsg }
            Write-StatusMessage $errorMsg -Type Warning
            Write-DeviceDNALog -Message $errorMsg -Component "Get-GPResultXml" -Type 2
            return $null
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Error in Get-GPResultXml: $($_.Exception.Message)" }
        Write-StatusMessage "Error collecting GPResult XML: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "GPResult collection failed: $($_.Exception.Message)" -Component "Get-GPResultXml" -Type 3
        return $null
    }
}

function ConvertFrom-GPResultXml {
    <#
    .SYNOPSIS
        Parses gpresult XML into structured data.
    .DESCRIPTION
        Extracts GPO information including names, GUIDs, link locations,
        applied status, security filtering, WMI filters, and individual
        policy settings from the gpresult XML output.
    .PARAMETER XmlContent
        Raw XML string from gpresult /X command.
    .OUTPUTS
        Hashtable with structured GPO data for Computer configuration.
    .EXAMPLE
        $xml = Get-GPResultXml -ComputerName "PC001"
        $data = ConvertFrom-GPResultXml -XmlContent $xml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [string]$XmlContent
    )

    $result = @{
        computerConfiguration = @{
            appliedGPOs = @()
            deniedGPOs  = @()
            filteredGPOs = @()
        }
        userConfiguration = @{
            appliedGPOs = @()
            deniedGPOs  = @()
            filteredGPOs = @()
            userName    = $null
            userSid     = $null
        }
        metadata = @{
            domain           = $null
            siteName         = $null
            domainController = $null
            slowLink         = $null
        }
        parseErrors = @()
    }

    if ([string]::IsNullOrEmpty($XmlContent)) {
        $result.parseErrors += "No XML content provided"
        return $result
    }

    try {
        # Load XML and handle namespaces
        $xml = [xml]$XmlContent

        # Get namespace manager for xpath queries
        $nsManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)

        # GPResult XML uses the rsop namespace
        $defaultNs = $xml.DocumentElement.NamespaceURI
        if ($defaultNs) {
            $nsManager.AddNamespace("rsop", $defaultNs)
        }

        # Helper function to extract GPO data
        $extractGPOData = {
            param($gpoNode, $nsManager)

            $gpo = @{
                name           = $null
                guid           = $null
                linkLocation   = $null
                status         = "Unknown"
                securityFilter = $null
                wmiFilter      = $null
                settings       = @()
                version        = @{
                    sysvol = $null
                    ad     = $null
                }
                enabled        = $true
            }

            try {
                # Extract basic GPO information
                $gpo.name = $gpoNode.Name.'#text'
                if (-not $gpo.name) {
                    $gpo.name = $gpoNode.Name
                }

                # Extract GUID
                $pathNode = $gpoNode.Path
                if ($pathNode) {
                    $guidMatch = $pathNode.Identifier.'#text'
                    if (-not $guidMatch) {
                        $guidMatch = $pathNode.Identifier
                    }
                    $gpo.guid = $guidMatch
                }

                # Extract link location
                $linkNode = $gpoNode.Link
                if ($linkNode) {
                    $gpo.linkLocation = $linkNode.SOMPath
                    if (-not $gpo.linkLocation) {
                        $gpo.linkLocation = $linkNode.SOMName
                    }
                }

                # Check if GPO is enabled
                $enabledNode = $gpoNode.Enabled
                if ($enabledNode) {
                    $gpo.enabled = $enabledNode -eq 'true' -or $enabledNode -eq $true
                }

                # Extract security filtering info
                $securityFilterNode = $gpoNode.SecurityFilter
                if ($securityFilterNode) {
                    $gpo.securityFilter = $securityFilterNode
                }

                # Extract WMI filter info
                $wmiNode = $gpoNode.FilterAllowed
                if ($wmiNode -eq $false -or $wmiNode -eq 'false') {
                    $gpo.wmiFilter = "Denied"
                }

                $wmiFilterName = $gpoNode.WmiFilter
                if ($wmiFilterName) {
                    $wmiFilterNameText = $wmiFilterName.Name.'#text'
                    if (-not $wmiFilterNameText) {
                        $wmiFilterNameText = $wmiFilterName.Name
                    }
                    $gpo.wmiFilter = $wmiFilterNameText
                }

                # Extract version information
                $versionNode = $gpoNode.VersionDirectory
                if ($versionNode) {
                    $gpo.version.ad = $versionNode
                }
                $sysvol = $gpoNode.VersionSysvol
                if ($sysvol) {
                    $gpo.version.sysvol = $sysvol
                }

            }
            catch {
                # Continue with partial data
            }

            return $gpo
        }

        # Helper function to extract settings from extension data
        $extractSettings = {
            param($extensionNode, $gpoGuid)

            $settings = @()

            try {
                # Process each extension type
                foreach ($child in $extensionNode.ChildNodes) {
                    if ($child.NodeType -ne 'Element') { continue }

                    $category = $child.LocalName

                    # Try to extract settings based on common patterns
                    $processNode = {
                        param($node, $path)

                        foreach ($settingNode in $node.ChildNodes) {
                            if ($settingNode.NodeType -ne 'Element') { continue }

                            $setting = @{
                                name         = $null
                                category     = $path
                                state        = "Configured"
                                value        = $null
                                registryPath = $null
                                registryValue = $null
                                gpoGuid      = $gpoGuid
                            }

                            # Common property names for setting name
                            $nameProps = @('Name', 'PolicyName', 'SettingName', 'KeyPath', 'Command')
                            foreach ($prop in $nameProps) {
                                $nameVal = $settingNode.$prop
                                if ($nameVal) {
                                    $setting.name = if ($nameVal.'#text') { $nameVal.'#text' } else { $nameVal.ToString() }
                                    break
                                }
                            }

                            # If no name found, use node name
                            if (-not $setting.name) {
                                $setting.name = $settingNode.LocalName
                            }

                            # Common property names for value
                            $valueProps = @('Value', 'State', 'Setting', 'SettingValue', 'Data')
                            foreach ($prop in $valueProps) {
                                $val = $settingNode.$prop
                                if ($null -ne $val) {
                                    $setting.value = if ($val.'#text') { $val.'#text' } else { $val.ToString() }
                                    break
                                }
                            }

                            # Check for state/enabled properties
                            $stateProps = @('State', 'Enabled', 'PolicyState')
                            foreach ($prop in $stateProps) {
                                $stateVal = $settingNode.$prop
                                if ($stateVal) {
                                    $stateText = if ($stateVal.'#text') { $stateVal.'#text' } else { $stateVal.ToString() }
                                    if ($stateText -eq 'Enabled' -or $stateText -eq 'true' -or $stateText -eq '1') {
                                        $setting.state = 'Enabled'
                                    }
                                    elseif ($stateText -eq 'Disabled' -or $stateText -eq 'false' -or $stateText -eq '0') {
                                        $setting.state = 'Disabled'
                                    }
                                    else {
                                        $setting.state = $stateText
                                    }
                                    break
                                }
                            }

                            # Registry-specific settings
                            if ($settingNode.LocalName -match 'Registry' -or $category -match 'Registry') {
                                $keyPath = $settingNode.KeyPath
                                if (-not $keyPath) { $keyPath = $settingNode.Key }
                                $setting.registryPath = if ($keyPath.'#text') { $keyPath.'#text' } else { $keyPath }

                                $valueName = $settingNode.ValueName
                                if (-not $valueName) { $valueName = $settingNode.Name }
                                $setting.registryValue = if ($valueName.'#text') { $valueName.'#text' } else { $valueName }
                            }

                            if ($setting.name) {
                                $settings += $setting
                            }
                        }
                    }

                    & $processNode -node $child -path $category
                }
            }
            catch {
                # Continue with partial data
            }

            return $settings
        }

        # Process Computer Configuration
        $computerResults = $xml.Rsop.ComputerResults
        if (-not $computerResults) {
            # Try alternative path
            $computerResults = $xml.DocumentElement.ComputerResults
        }

        if ($computerResults) {
            # Extract GP processing metadata (domain, site, DC)
            try {
                $result.metadata.domain = $computerResults.Domain
                $result.metadata.siteName = $computerResults.Site
                $result.metadata.slowLink = $computerResults.SlowLink

                # DC name is an attribute on SinglePassEventsDetails inside EventsDetails
                $eventsDetails = $computerResults.EventsDetails
                if ($eventsDetails) {
                    $singlePass = $eventsDetails.SinglePassEventsDetails
                    if ($singlePass) {
                        $firstPass = if ($singlePass -is [array]) { $singlePass[0] } else { $singlePass }
                        $result.metadata.domainController = $firstPass.DomainControllerName
                    }
                }

                if ($result.metadata.domain) {
                    Write-DeviceDNALog -Message "GP metadata - Domain: $($result.metadata.domain), Site: $($result.metadata.siteName), DC: $($result.metadata.domainController)" -Component "ConvertFrom-GPResultXml" -Type 1
                }
            }
            catch {
                # Metadata extraction is optional - continue without it
                Write-DeviceDNALog -Message "Could not extract GP metadata: $($_.Exception.Message)" -Component "ConvertFrom-GPResultXml" -Type 2
            }

            # Get applied GPOs
            $appliedGPOs = $computerResults.GPO
            if ($appliedGPOs) {
                foreach ($gpoNode in $appliedGPOs) {
                    $gpoData = & $extractGPOData -gpoNode $gpoNode -nsManager $nsManager

                    # Determine status based on filtering
                    $filterAllowed = $gpoNode.FilterAllowed
                    $accessDenied = $gpoNode.AccessDenied
                    $isFiltered = $gpoNode.IsFiltered

                    if ($accessDenied -eq $true -or $accessDenied -eq 'true') {
                        $gpoData.status = "Denied"
                        $result.computerConfiguration.deniedGPOs += $gpoData
                    }
                    elseif ($filterAllowed -eq $false -or $filterAllowed -eq 'false' -or $isFiltered -eq $true) {
                        $gpoData.status = "Filtered"
                        $result.computerConfiguration.filteredGPOs += $gpoData
                    }
                    else {
                        $gpoData.status = "Applied"
                        $result.computerConfiguration.appliedGPOs += $gpoData
                    }
                }
            }

            # Extract extension data (settings)
            $extensionData = $computerResults.ExtensionData
            if ($extensionData) {
                foreach ($ext in $extensionData) {
                    $extension = $ext.Extension
                    if ($extension) {
                        $gpoGuid = $ext.GPO.Identifier.'#text'
                        if (-not $gpoGuid) { $gpoGuid = $ext.GPO.Identifier }

                        $settings = & $extractSettings -extensionNode $extension -gpoGuid $gpoGuid

                        # Match settings to GPOs
                        if ($gpoGuid) {
                            $matchedGPO = $result.computerConfiguration.appliedGPOs | Where-Object { $_.guid -eq $gpoGuid }
                            if ($matchedGPO) {
                                $matchedGPO.settings += $settings
                            }
                        }
                    }
                }
            }
        }

        # Process User Configuration
        $userResults = $xml.Rsop.UserResults
        if (-not $userResults) {
            # Try alternative path
            $userResults = $xml.DocumentElement.UserResults
        }

        if ($userResults) {
            # Extract user identity
            $result.userConfiguration.userName = $userResults.Name
            $result.userConfiguration.userSid = $userResults.SID

            # Get applied GPOs
            $appliedGPOs = $userResults.GPO
            if ($appliedGPOs) {
                foreach ($gpoNode in $appliedGPOs) {
                    $gpoData = & $extractGPOData -gpoNode $gpoNode -nsManager $nsManager

                    # Determine status
                    $filterAllowed = $gpoNode.FilterAllowed
                    $accessDenied = $gpoNode.AccessDenied
                    $isFiltered = $gpoNode.IsFiltered

                    if ($accessDenied -eq $true -or $accessDenied -eq 'true') {
                        $gpoData.status = "Denied"
                        $result.userConfiguration.deniedGPOs += $gpoData
                    }
                    elseif ($filterAllowed -eq $false -or $filterAllowed -eq 'false' -or $isFiltered -eq $true) {
                        $gpoData.status = "Filtered"
                        $result.userConfiguration.filteredGPOs += $gpoData
                    }
                    else {
                        $gpoData.status = "Applied"
                        $result.userConfiguration.appliedGPOs += $gpoData
                    }
                }
            }

            # Extract extension data (settings)
            $extensionData = $userResults.ExtensionData
            if ($extensionData) {
                foreach ($ext in $extensionData) {
                    $extension = $ext.Extension
                    if ($extension) {
                        $gpoGuid = $ext.GPO.Identifier.'#text'
                        if (-not $gpoGuid) { $gpoGuid = $ext.GPO.Identifier }

                        $settings = & $extractSettings -extensionNode $extension -gpoGuid $gpoGuid

                        # Match settings to GPOs
                        if ($gpoGuid) {
                            $matchedGPO = $result.userConfiguration.appliedGPOs | Where-Object { $_.guid -eq $gpoGuid }
                            if ($matchedGPO) {
                                $matchedGPO.settings += $settings
                            }
                        }
                    }
                }
            }
        }

        $computerGPOCount = $result.computerConfiguration.appliedGPOs.Count
        $userGPOCount = $result.userConfiguration.appliedGPOs.Count
        $computerDeniedCount = $result.computerConfiguration.deniedGPOs.Count
        $userDeniedCount = $result.userConfiguration.deniedGPOs.Count

        Write-StatusMessage "Parsed $computerGPOCount computer GPOs and $userGPOCount user GPOs" -Type Info
        Write-DeviceDNALog -Message "GP parsing complete: Computer GPOs: $computerGPOCount applied, $computerDeniedCount denied; User GPOs: $userGPOCount applied, $userDeniedCount denied" -Component "ConvertFrom-GPResultXml" -Type 1
    }
    catch {
        $result.parseErrors += "XML parsing error: $($_.Exception.Message)"
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to parse GPResult XML: $($_.Exception.Message)" }
        Write-StatusMessage "Error parsing GPResult XML: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "GP parsing failed: $($_.Exception.Message)" -Component "ConvertFrom-GPResultXml" -Type 3
    }

    return $result
}

function Get-InstalledApplications {
    <#
    .SYNOPSIS
        Collects installed applications from multiple sources.
    .DESCRIPTION
        Gathers application information from:
        - HKLM Uninstall registry (32-bit and 64-bit)
        - HKCU Uninstall registry
        - Modern apps via Get-AppxPackage
    .PARAMETER ComputerName
        Target computer name for remote execution.
    .OUTPUTS
        Array of application objects with DisplayName, Version, Publisher, etc.
    .EXAMPLE
        $apps = Get-InstalledApplications -ComputerName "PC001"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $applications = @()

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        $scriptBlock = {
            $apps = @()
            $seenApps = @{}  # For deduplication

            # Registry paths to check
            $registryPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            )

            foreach ($path in $registryPaths) {
                try {
                    if (Test-Path $path) {
                        $items = Get-ChildItem -Path $path -ErrorAction SilentlyContinue

                        foreach ($item in $items) {
                            try {
                                $props = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue

                                # Skip entries without display name
                                if ([string]::IsNullOrEmpty($props.DisplayName)) { continue }

                                # Skip system components and updates unless explicitly named
                                if ($props.SystemComponent -eq 1 -and $props.DisplayName -notmatch 'Microsoft') { continue }

                                # Create deduplication key
                                $dedupKey = "$($props.DisplayName)|$($props.DisplayVersion)"
                                if ($seenApps.ContainsKey($dedupKey)) { continue }
                                $seenApps[$dedupKey] = $true

                                # Parse install date
                                $installDate = $null
                                if ($props.InstallDate) {
                                    try {
                                        if ($props.InstallDate -match '^\d{8}$') {
                                            $installDate = [datetime]::ParseExact($props.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
                                        }
                                        else {
                                            $installDate = $props.InstallDate
                                        }
                                    }
                                    catch {
                                        $installDate = $props.InstallDate
                                    }
                                }

                                $app = @{
                                    displayName     = $props.DisplayName
                                    version         = $props.DisplayVersion
                                    publisher       = $props.Publisher
                                    installDate     = $installDate
                                    installLocation = $props.InstallLocation
                                    uninstallString = $props.UninstallString
                                    architecture    = if ($path -match 'WOW6432Node') { 'x86' } else { 'x64' }
                                    source          = 'Registry'
                                    registryPath    = $item.PSPath
                                }

                                $apps += $app
                            }
                            catch {
                                # Skip problematic entries
                            }
                        }
                    }
                }
                catch {
                    # Skip inaccessible paths
                }
            }

            # Collect modern/UWP apps
            try {
                $appxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue

                if (-not $appxPackages) {
                    # Try without -AllUsers if it fails
                    $appxPackages = Get-AppxPackage -ErrorAction SilentlyContinue
                }

                foreach ($pkg in $appxPackages) {
                    try {
                        # Skip framework packages
                        if ($pkg.IsFramework) { continue }

                        # Create deduplication key
                        $dedupKey = "$($pkg.Name)|$($pkg.Version)"
                        if ($seenApps.ContainsKey($dedupKey)) { continue }
                        $seenApps[$dedupKey] = $true

                        $app = @{
                            displayName     = $pkg.Name
                            version         = $pkg.Version.ToString()
                            publisher       = $pkg.Publisher
                            installDate     = $null
                            installLocation = $pkg.InstallLocation
                            uninstallString = $null
                            architecture    = $pkg.Architecture.ToString()
                            source          = 'AppxPackage'
                            packageFullName = $pkg.PackageFullName
                        }

                        $apps += $app
                    }
                    catch {
                        # Skip problematic packages
                    }
                }
            }
            catch {
                # AppX collection failed - continue without it
            }

            return $apps
        }

        Write-StatusMessage "Collecting installed applications..." -Type Progress

        if ($isLocal) {
            $applications = & $scriptBlock
        }
        else {
            try {
                $applications = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
            }
            catch {
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to collect applications from $ComputerName : $($_.Exception.Message)" }
                Write-StatusMessage "Failed to collect applications: $($_.Exception.Message)" -Type Warning
                return @()
            }
        }

        # Convert to proper array if needed
        if ($applications -and $applications -isnot [array]) {
            $applications = @($applications)
        }

        # Sort by display name
        $applications = $applications | Sort-Object { $_.displayName }

        Write-StatusMessage "Collected $($applications.Count) installed applications" -Type Success
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Error in Get-InstalledApplications: $($_.Exception.Message)" }
        Write-StatusMessage "Error collecting applications: $($_.Exception.Message)" -Type Error
        return @()
    }

    return $applications
}

function Get-GroupPolicyData {
    <#
    .SYNOPSIS
        Main orchestrator for Group Policy data collection.
    .DESCRIPTION
        Coordinates all GP collection activities including RSoP logging setup,
        gpupdate execution, GPResult XML collection, and installed applications.
        Returns a structured hashtable with all collected data.
    .PARAMETER ComputerName
        Target computer name for remote execution.
    .PARAMETER SkipGPUpdate
        Skip running gpupdate /force before collection.
    .OUTPUTS
        Hashtable with computerScope data structure.
    .EXAMPLE
        $data = Get-GroupPolicyData
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [switch]$SkipGPUpdate
    )

    # Initialize result structure
    $result = @{
        computerScope = @{
            appliedGPOs           = @()
            deniedGPOs            = @()
            filteredGPOs          = @()
            installedApplications = @()
            collectionTime        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        metadata = @{
            domain           = $null
            siteName         = $null
            domainController = $null
            slowLink         = $null
        }
        collectionMetadata = @{
            computerName = $ComputerName
            startTime    = Get-Date
            endTime      = $null
            rsopEnabled  = $false
            gpUpdateRun  = $false
        }
    }

    $originalRSoPValue = $null

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        Write-StatusMessage "Starting Group Policy data collection" -Type Progress
        Write-StatusMessage "Target: $(if ($isLocal) { 'Local Computer' } else { $ComputerName })" -Type Info

        try {
            # Enable RSoP logging for detailed collection
            # This is optional and may require admin rights
            $originalRSoPValue = Set-RSoPLogging -Enable -ComputerName $ComputerName
            if ($null -ne $originalRSoPValue -or $originalRSoPValue -eq 0) {
                $result.collectionMetadata.rsopEnabled = $true
            }
        }
        catch {
            # RSoP logging is optional - continue without it
            Write-StatusMessage "RSoP logging not enabled (optional): $($_.Exception.Message)" -Type Info
        }

        if (-not $SkipGPUpdate) {
            try {
                $gpUpdateResult = Invoke-GPUpdate -ComputerName $ComputerName -TimeoutSeconds 300
                $result.collectionMetadata.gpUpdateRun = $gpUpdateResult.Success
            }
            catch {
                Write-StatusMessage "GPUpdate failed but continuing with collection: $($_.Exception.Message)" -Type Warning
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = "GPUpdate failed: $($_.Exception.Message)" }
            }
        }
        else {
            Write-StatusMessage "Skipping GPUpdate as requested" -Type Info
        }

        Write-StatusMessage "Collecting computer configuration..." -Type Progress

        try {
            $computerXml = Get-GPResultXml -ComputerName $ComputerName

                if ($computerXml) {
                    $parsedComputer = ConvertFrom-GPResultXml -XmlContent $computerXml

                    if ($parsedComputer) {
                        $result.computerScope.appliedGPOs = $parsedComputer.computerConfiguration.appliedGPOs
                        $result.computerScope.deniedGPOs = $parsedComputer.computerConfiguration.deniedGPOs
                        $result.computerScope.filteredGPOs = $parsedComputer.computerConfiguration.filteredGPOs

                        # Pass through GP metadata (domain, site, DC)
                        if ($parsedComputer.metadata) {
                            $result.metadata = $parsedComputer.metadata
                        }

                        if ($parsedComputer.parseErrors.Count -gt 0) {
                            foreach ($err in $parsedComputer.parseErrors) {
                                $script:CollectionIssues += @{ severity = "Warning"; phase = "Group Policy"; message = "Computer GP parse warning: $err" }
                            }
                        }
                    }
                }
            }
            catch {
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to collect computer GPO data: $($_.Exception.Message)" }
                Write-StatusMessage "Computer GPO collection failed: $($_.Exception.Message)" -Type Warning
            }

        try {
            $applications = Get-InstalledApplications -ComputerName $ComputerName
            $result.computerScope.installedApplications = $applications
        }
        catch {
            $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Failed to collect installed applications: $($_.Exception.Message)" }
            Write-StatusMessage "Application collection failed: $($_.Exception.Message)" -Type Warning
        }

        $result.collectionMetadata.endTime = Get-Date

        # Calculate collection summary
        $totalCompApplied = ($result.computerScope.appliedGPOs).Count
        $totalCompDenied = ($result.computerScope.deniedGPOs).Count
        $totalApps = ($result.computerScope.installedApplications).Count

        Write-StatusMessage "Collection complete - Computer GPOs: $totalCompApplied applied, $totalCompDenied denied | Apps: $totalApps" -Type Success
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Critical error in Get-GroupPolicyData: $($_.Exception.Message)" }
        Write-StatusMessage "Critical error during GP collection: $($_.Exception.Message)" -Type Error
    }
    finally {
        if ($result.collectionMetadata.rsopEnabled) {
            try {
                $null = Set-RSoPLogging -OriginalValue $originalRSoPValue -ComputerName $ComputerName
            }
            catch {
                # Restoration failure is not critical
                Write-StatusMessage "Could not restore RSoP logging setting" -Type Warning
            }
        }
    }

    return $result
}
