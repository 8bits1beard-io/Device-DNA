<#
.SYNOPSIS
    Device DNA - Orchestration Module
.DESCRIPTION
    Main collection workflow orchestrator.
    Coordinates Phase 0 (Setup), Phase 1 (Parallel Collection),
    Phase 2 (Report Generation), Phase 3 (Summary).
.NOTES
    Module: Orchestration.ps1
    Dependencies: ALL modules (Core, Logging, Helpers, DeviceInfo, GroupPolicy,
                  Intune, LocalIntune, Reporting, Interactive, Runspace)
    Version: 0.2.0
#>

function Invoke-DeviceDNACollection {
    <#
    .SYNOPSIS
        Main orchestration function for Device DNA data collection.
    #>
    [CmdletBinding()]
    param()

    $script:StartTime = Get-Date
    $collectionData = @{
        metadata = @{
            version = $script:Version
            collectionTime = (Get-Date -Format 'o')
            collectedBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        deviceInfo = @{}
        groupPolicy = @{
            computerScope = @{ appliedGPOs = @(); deniedGPOs = @(); installedApplications = @() }
            metadata = @{
                domain           = $null
                siteName         = $null
                domainController = $null
                slowLink         = $null
            }
        }
        intune = @{
            azureADDevice = $null
            managedDevice = $null
            deviceGroups = @()
            configurationProfiles = @()
            applications = @()
            compliancePolicies = @()
            proactiveRemediations = @()
        }
        sccm = @{
            clientInfo      = $null
            applications    = @()
            baselines       = @()
            softwareUpdates = @()
            clientSettings  = @()
        }
        windowsUpdate = @{
            summary              = @{}
            registryPolicy       = @{}
            pendingUpdates       = @()
            updateHistory        = @()
            deliveryOptimization = @{}
        }
        collectionIssues = @()
    }

    try {
        # Phase 0: Setup & Validation
        Write-Host ""
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host "  Device DNA v$($script:Version)" -ForegroundColor Cyan
        Write-Host "  Group Policy, Intune & SCCM Configuration Analyzer" -ForegroundColor Cyan
        Write-Host "=============================================" -ForegroundColor Cyan
        Write-Host ""

        Write-StatusMessage "Starting Device DNA collection..." -Type Progress

        # Collect interactive parameters if needed
        $params = Get-InteractiveParameters -CurrentComputerName $ComputerName

        $script:TargetComputer = $params.ComputerName

        # Initialize CMTrace logging
        # Create device-based output folder structure: output/<DeviceName>/
        $baseOutputPath = if ([string]::IsNullOrEmpty($OutputPath)) { Get-Location } else { $OutputPath }
        $targetDeviceName = if ([string]::IsNullOrEmpty($script:TargetComputer)) { $env:COMPUTERNAME } else { $script:TargetComputer }

        # Create output/<DeviceName> folder
        $deviceOutputPath = Join-Path $baseOutputPath "output"
        $deviceOutputPath = Join-Path $deviceOutputPath $targetDeviceName

        if (-not (Test-Path $deviceOutputPath)) {
            New-Item -ItemType Directory -Path $deviceOutputPath -Force | Out-Null
        }

        $logPath = Initialize-DeviceDNALog -OutputPath $deviceOutputPath -TargetDevice $targetDeviceName

        if ($logPath) {
            Write-StatusMessage "Logging to: $logPath" -Type Info -SkipLog
        }

        # Validate parameters
        if (-not (Confirm-Parameters -Parameters $params)) {
            Write-StatusMessage "Parameter validation failed. Exiting." -Type Error
            return
        }

        # Check admin rights
        Write-StatusMessage "Checking administrative privileges..." -Type Progress
        $isAdmin = Test-AdminRights -ComputerName $script:TargetComputer
        if (-not $isAdmin) {
            Write-StatusMessage "Administrative privileges are required for full data collection." -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Running without administrative privileges - some data may be unavailable" }
        }
        else {
            Write-StatusMessage "Administrative privileges confirmed" -Type Success
        }

        # Get device join type
        Write-StatusMessage "Detecting device join type..." -Type Progress
        $joinInfo = Get-DeviceJoinType -ComputerName $script:TargetComputer

        $joinTypes = @()
        if ($joinInfo.AzureAdJoined) { $joinTypes += "Azure AD Joined" }
        if ($joinInfo.DomainJoined) { $joinTypes += "Domain Joined" }
        if ($joinInfo.WorkplaceJoined) { $joinTypes += "Workplace Joined" }

        $joinTypeString = if ($joinTypes.Count -gt 0) { $joinTypes -join ', ' } else { "Not Joined" }

        if ($joinTypes.Count -gt 0) {
            Write-StatusMessage "Device join type: $joinTypeString" -Type Info
        }
        else {
            Write-StatusMessage "Device is not joined to any directory" -Type Warning
        }

        # Detect management type (MDM enrollment, SCCM, co-management)
        Write-StatusMessage "Detecting management type..." -Type Progress
        $mdmInfo = Test-MdmEnrollment -ComputerName $script:TargetComputer
        $sccmInstalled = Test-SCCMClient -ComputerName $script:TargetComputer
        $coMgmtInfo = Test-CoManagement -ComputerName $script:TargetComputer

        # Use co-management registry check to refine detection
        $isCoManaged = $coMgmtInfo.IsCoManaged
        $managementType = Get-ManagementType `
            -AzureAdJoined $joinInfo.AzureAdJoined `
            -DomainJoined $joinInfo.DomainJoined `
            -SccmInstalled $sccmInstalled `
            -MdmEnrolled $mdmInfo.IsEnrolled `
            -IsCoManaged $isCoManaged

        Write-StatusMessage "Management type: $managementType" -Type Info

        # Get tenant ID
        Write-StatusMessage "Discovering tenant information..." -Type Progress
        $tenantId = Get-TenantId -DsregOutput $joinInfo.RawOutput

        if ($tenantId) {
            Write-StatusMessage "Tenant ID: $tenantId" -Type Info
        }
        else {
            Write-StatusMessage "Could not determine tenant ID - Intune collection will be skipped" -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Could not determine tenant ID" }
        }

        # Authenticate to Graph API if device is Azure AD or Hybrid joined (unless Intune is skipped)
        if ('Intune' -notin $Skip -and $tenantId -and ($joinInfo.AzureAdJoined -or $joinInfo.WorkplaceJoined)) {
            Write-Host ""
            Write-StatusMessage "Connecting to Microsoft Graph API..." -Type Progress
            $graphConnected = Connect-GraphAPI -TenantId $tenantId

            if (-not $graphConnected) {
                Write-StatusMessage "Graph authentication failed - Intune data will not be collected" -Type Warning
                $script:CollectionIssues += @{ severity = "Warning"; phase = "Setup"; message = "Graph authentication failed" }
            }
        }
        elseif ('Intune' -in $Skip) {
            Write-StatusMessage "Skipping Graph authentication - Intune collection disabled via -Skip parameter" -Type Info
            Write-DeviceDNALog -Message "Intune collection skipped via -Skip parameter" -Component "Invoke-DeviceDNACollection" -Type 1
        }
        else {
            Write-StatusMessage "Skipping Graph authentication - device not Azure AD joined or tenant unknown" -Type Info
        }

        # Get device info
        Write-StatusMessage "Collecting device information..." -Type Progress
        $deviceInfo = Get-DeviceInfo -ComputerName $script:TargetComputer

        # Populate device info in collection data
        $collectionData.deviceInfo = @{
            name = $deviceInfo.Hostname
            fqdn = $deviceInfo.FQDN
            osName = $deviceInfo.OSName
            osVersion = $deviceInfo.OSVersion
            osBuild = $deviceInfo.OSBuild
            serialNumber = $deviceInfo.SerialNumber
            currentUser = $deviceInfo.CurrentUser
            joinType = $joinTypeString
            managementType = $managementType
            mdmProvider = $mdmInfo.ProviderID
            tenantId = $tenantId
            Processor = $deviceInfo.Processor
            Memory = $deviceInfo.Memory
            Storage = $deviceInfo.Storage
            BIOS = $deviceInfo.BIOS
            Network = $deviceInfo.Network
            Proxy = $deviceInfo.Proxy
            Security = $deviceInfo.Security
            Power = $deviceInfo.Power
        }

        Write-StatusMessage "Device: $($deviceInfo.Hostname) ($($deviceInfo.OSName))" -Type Info

        # Log skipped collections
        if ($Skip.Count -gt 0) {
            Write-StatusMessage "Skip parameter specified: $($Skip -join ', ')" -Type Info
            Write-DeviceDNALog -Message "Collections to skip: $($Skip -join ', ')" -Component "Invoke-DeviceDNACollection" -Type 1

            # Add to collection issues so it shows in report
            foreach ($skipItem in $Skip) {
                $script:CollectionIssues += @{ severity = "Info"; phase = "Setup"; message = "Collection skipped via -Skip parameter: $skipItem" }
            }
        }

        # Phase 1: Parallel Collection (Track A: GP, Track B: Intune)
        Write-Host ""
        Write-StatusMessage "Phase 1: Starting collection (GP + Intune + SCCM + WU)..." -Type Progress

        # Determine if we should run collections based on environment and -Skip parameter
        $shouldCollectGP = 'GroupPolicy' -notin $Skip
        $shouldCollectIntune = 'Intune' -notin $Skip -and $script:GraphConnected -and $tenantId -and ($joinInfo.AzureAdJoined -or $joinInfo.WorkplaceJoined)

        # Track A: Start GP collection using the existing function in main thread first
        # Track B: Run Intune collection immediately after starting GP (they run "interleaved" not truly parallel
        #          because Graph needs main thread, but we start Intune before waiting for GP to fully complete)
        #
        # For truly parallel execution on REMOTE targets, we use Invoke-Command -AsJob
        # For LOCAL targets, we run sequentially (both compete for local resources anyway, and we avoid WinRM overhead)

        $isRemoteTarget = -not (Test-IsLocalComputer -ComputerName $script:TargetComputer)

        $gpJob = $null
        $gpData = $null

        if ($isRemoteTarget) {
            # REMOTE TARGET: Use Invoke-Command -AsJob for true parallelism via WinRM

            if ($shouldCollectGP) {
                Write-StatusMessage "Track A: Starting remote GP collection (async via WinRM)..." -Type Progress
            }
            else {
                Write-StatusMessage "Track A: Skipping GP collection (disabled via -Skip parameter)" -Type Info
            }

            try {
                if ($shouldCollectGP) {
                # Start remote GP collection as a job
                $gpJob = Invoke-Command -ComputerName $script:TargetComputer -AsJob -ScriptBlock {
                    param($SkipGPUpdate)

                    $result = @{
                        Success = $false
                        ComputerGPOs = @()
                        UserGPOs = @()
                        UserName = $null
                        Error = $null
                    }

                    # Enable RSoP logging before gpresult (required for gpresult /X to produce output)
                    $rsopRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics"
                    $rsopValueName = "GPSvcDebugLevel"
                    $rsopEnableValue = 0x30002
                    $rsopOriginalValue = $null
                    $rsopWasEnabled = $false

                    try {
                        if (-not (Test-Path $rsopRegPath)) {
                            $null = New-Item -Path $rsopRegPath -Force -ErrorAction Stop
                        }
                        try {
                            $rsopOriginalValue = (Get-ItemProperty -Path $rsopRegPath -Name $rsopValueName -ErrorAction SilentlyContinue).$rsopValueName
                        } catch { $rsopOriginalValue = $null }

                        Set-ItemProperty -Path $rsopRegPath -Name $rsopValueName -Value $rsopEnableValue -Type DWord -Force -ErrorAction Stop
                        $rsopWasEnabled = $true
                    } catch { }

                    try {
                        # Run gpupdate if not skipped
                        if (-not $SkipGPUpdate) {
                            & gpupdate /force 2>&1 | Out-Null
                        }

                        # Collect gpresult XML (computer scope only — no user session over WinRM)
                        $tempFile = [System.IO.Path]::GetTempFileName() + ".xml"
                        & gpresult /X $tempFile /SCOPE COMPUTER 2>&1 | Out-Null

                        if (Test-Path $tempFile) {
                            [xml]$xml = Get-Content $tempFile -Raw
                            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

                            # Parse Computer GPOs
                            $computerData = $xml.Rsop.ComputerResults
                            if ($computerData.GPO) {
                                foreach ($gpo in $computerData.GPO) {
                                    $result.ComputerGPOs += @{
                                        name = $gpo.Name
                                        guid = if ($gpo.Path.Identifier.'#text') { $gpo.Path.Identifier.'#text' } else { '' }
                                        link = $gpo.Link.SOMPath
                                        status = 'Applied'
                                    }
                                }
                            }

                            # Parse User GPOs
                            $userData = $xml.Rsop.UserResults
                            if ($userData.GPO) {
                                foreach ($gpo in $userData.GPO) {
                                    $result.UserGPOs += @{
                                        name = $gpo.Name
                                        guid = if ($gpo.Path.Identifier.'#text') { $gpo.Path.Identifier.'#text' } else { '' }
                                        link = $gpo.Link.SOMPath
                                        status = 'Applied'
                                    }
                                }
                            }

                            $result.UserName = $userData.User.Name
                            $result.Success = $true
                        }
                        else {
                            $result.Error = "gpresult did not produce output file"
                        }
                    }
                    catch {
                        $result.Error = $_.Exception.Message
                    }
                    finally {
                        # Restore RSoP logging to original state
                        if ($rsopWasEnabled) {
                            try {
                                if ($null -eq $rsopOriginalValue) {
                                    Remove-ItemProperty -Path $rsopRegPath -Name $rsopValueName -ErrorAction SilentlyContinue
                                } else {
                                    Set-ItemProperty -Path $rsopRegPath -Name $rsopValueName -Value $rsopOriginalValue -Type DWord -Force -ErrorAction SilentlyContinue
                                }
                            } catch { }
                        }
                    }

                    return $result
                } -ArgumentList $SkipGPUpdate
                }
            }
            catch {
                if ($shouldCollectGP) {
                    Write-StatusMessage "Failed to start remote GP collection: $($_.Exception.Message)" -Type Error
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $_.Exception.Message }
                }
            }

            # Track B: Run Intune collection in main thread while GP job runs
            if ($shouldCollectIntune) {
                Write-StatusMessage "Track B: Starting Intune collection (parallel with GP)..." -Type Progress
                try {
                    $intuneData = Get-IntuneData -DeviceName $deviceInfo.Hostname -TenantId $tenantId -Skip $Skip

                    if ($intuneData) {
                        $collectionData.intune.azureADDevice = $intuneData.azureADDevice
                        $collectionData.intune.managedDevice = $intuneData.managedDevice
                        $collectionData.intune.deviceGroups = $intuneData.deviceGroups
                        $collectionData.intune.configurationProfiles = $intuneData.configurationProfiles
                        $collectionData.intune.applications = $intuneData.applications
                        $collectionData.intune.compliancePolicies = $intuneData.compliancePolicies
                        $collectionData.intune.proactiveRemediations = $intuneData.proactiveRemediations
                    }
                }
                catch {
                    Write-StatusMessage "Intune collection failed: $($_.Exception.Message)" -Type Error
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = $_.Exception.Message }
                }
            }
            elseif (-not $script:GraphConnected) {
                Write-StatusMessage "Track B: Skipping Intune collection - Graph API not connected" -Type Info
                $script:CollectionIssues += @{ severity = "Info"; phase = "Intune"; message = "Skipped - Graph API authentication failed" }
            }
            else {
                Write-StatusMessage "Track B: Skipping Intune - device not Azure AD joined" -Type Info
                $script:CollectionIssues += @{ severity = "Info"; phase = "Intune"; message = "Skipped - device not Azure AD joined or tenant unknown" }
            }

            # Wait for GP job to complete
            if ($gpJob) {
                Write-StatusMessage "Waiting for remote GP collection to complete..." -Type Progress
                try {
                    # Wait up to 5 minutes for the remote GP job to finish
                    $gpTimeoutSeconds = 300
                    $null = Wait-Job -Job $gpJob -Timeout $gpTimeoutSeconds

                    if ($gpJob.State -eq 'Completed') {
                        $gpJobResult = Receive-Job -Job $gpJob -ErrorAction Stop

                        if ($gpJobResult -and $gpJobResult.Success) {
                            $collectionData.groupPolicy.computerScope.appliedGPOs = $gpJobResult.ComputerGPOs
                            Write-StatusMessage "Track A: Remote GP collection completed" -Type Success
                        }
                        elseif ($gpJobResult -and $gpJobResult.Error) {
                            Write-StatusMessage "Track A: GP collection failed: $($gpJobResult.Error)" -Type Error
                            $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $gpJobResult.Error }
                        }
                    }
                    else {
                        Write-StatusMessage "Track A: Remote GP collection timed out after $gpTimeoutSeconds seconds" -Type Error
                        $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = "Remote GP collection timed out after $gpTimeoutSeconds seconds" }
                        Stop-Job -Job $gpJob -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    Write-StatusMessage "Error retrieving GP job results: $($_.Exception.Message)" -Type Error
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $_.Exception.Message }
                }
                finally {
                    Remove-Job -Job $gpJob -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            # LOCAL TARGET: Run sequentially (both need local resources)

            if ($shouldCollectGP) {
                Write-StatusMessage "Track A: Starting local GP collection..." -Type Progress
            }
            else {
                Write-StatusMessage "Track A: Skipping GP collection (disabled via -Skip parameter)" -Type Info
            }

            try {
                if ($shouldCollectGP) {
                    $gpData = Get-GroupPolicyData -ComputerName $script:TargetComputer -SkipGPUpdate:$SkipGPUpdate
                }

                if ($gpData) {
                    $collectionData.groupPolicy.computerScope.appliedGPOs = $gpData.computerScope.appliedGPOs
                    $collectionData.groupPolicy.computerScope.deniedGPOs = $gpData.computerScope.deniedGPOs + $gpData.computerScope.filteredGPOs
                    $collectionData.groupPolicy.computerScope.installedApplications = $gpData.computerScope.installedApplications

                    # Pass through GP metadata (domain, site, DC) from parsed XML
                    if ($gpData.metadata) {
                        $collectionData.groupPolicy.metadata = $gpData.metadata
                    }

                    Write-StatusMessage "Track A: Local GP collection completed" -Type Success
                }
            }
            catch {
                Write-StatusMessage "GP collection failed: $($_.Exception.Message)" -Type Error
                $script:CollectionIssues += @{ severity = "Error"; phase = "Group Policy"; message = $_.Exception.Message }
            }

            # Track B: Run Intune collection after GP (sequential for local)
            if ($shouldCollectIntune) {
                Write-StatusMessage "Track B: Starting Intune collection..." -Type Progress
                try {
                    $intuneData = Get-IntuneData -DeviceName $deviceInfo.Hostname -TenantId $tenantId -Skip $Skip

                    if ($intuneData) {
                        $collectionData.intune.azureADDevice = $intuneData.azureADDevice
                        $collectionData.intune.managedDevice = $intuneData.managedDevice
                        $collectionData.intune.deviceGroups = $intuneData.deviceGroups
                        $collectionData.intune.configurationProfiles = $intuneData.configurationProfiles
                        $collectionData.intune.applications = $intuneData.applications
                        $collectionData.intune.compliancePolicies = $intuneData.compliancePolicies
                        $collectionData.intune.proactiveRemediations = $intuneData.proactiveRemediations
                    }
                }
                catch {
                    Write-StatusMessage "Intune collection failed: $($_.Exception.Message)" -Type Error
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Intune"; message = $_.Exception.Message }
                }
            }
            elseif (-not $script:GraphConnected) {
                Write-StatusMessage "Track B: Skipping Intune collection - Graph API not connected" -Type Info
                $script:CollectionIssues += @{ severity = "Info"; phase = "Intune"; message = "Skipped - Graph API authentication failed" }
            }
            else {
                Write-StatusMessage "Track B: Skipping Intune - device not Azure AD joined" -Type Info
                $script:CollectionIssues += @{ severity = "Info"; phase = "Intune"; message = "Skipped - device not Azure AD joined or tenant unknown" }
            }
        }

        # Track C: SCCM collection (runs after GP and Intune, uses local WMI)
        $shouldCollectSCCM = 'SCCM' -notin $Skip
        if ($shouldCollectSCCM) {
            Write-StatusMessage "Track C: Starting SCCM collection..." -Type Progress
            try {
                $sccmData = Get-SCCMData -ComputerName $script:TargetComputer -Skip $Skip

                if ($sccmData) {
                    $collectionData.sccm.clientInfo = $sccmData.clientInfo
                    $collectionData.sccm.applications = $sccmData.applications
                    $collectionData.sccm.baselines = $sccmData.baselines
                    $collectionData.sccm.softwareUpdates = $sccmData.softwareUpdates
                    $collectionData.sccm.clientSettings = $sccmData.clientSettings
                    Write-StatusMessage "Track C: SCCM collection completed" -Type Success
                }
                else {
                    Write-StatusMessage "Track C: SCCM client not installed — skipped" -Type Info
                }
            }
            catch {
                Write-StatusMessage "SCCM collection failed: $($_.Exception.Message)" -Type Error
                $script:CollectionIssues += @{ severity = "Error"; phase = "SCCM"; message = $_.Exception.Message }
            }
        }
        else {
            Write-StatusMessage "Track C: Skipping SCCM collection (disabled via -Skip parameter)" -Type Info
        }

        # Track D: Windows Update configuration (registry + WUA COM API)
        $shouldCollectWU = 'WindowsUpdate' -notin $Skip
        if ($shouldCollectWU) {
            Write-StatusMessage "Track D: Starting Windows Update collection..." -Type Progress
            try {
                $wuData = Get-WindowsUpdateData -ComputerName $script:TargetComputer
                if ($wuData) {
                    $collectionData.windowsUpdate = $wuData
                    Write-StatusMessage "Track D: Windows Update collection completed" -Type Success
                }
            }
            catch {
                Write-StatusMessage "Windows Update collection failed: $($_.Exception.Message)" -Type Error
                $script:CollectionIssues += @{ severity = "Error"; phase = "WindowsUpdate"; message = $_.Exception.Message }
            }
        }
        else {
            Write-StatusMessage "Track D: Skipping Windows Update collection (disabled via -Skip parameter)" -Type Info
        }

        # Post-collection: Determine actual Windows Update management authority
        # SCCM takes precedence over WUFB/WSUS/WU if SCCM is managing software updates
        if ($collectionData.windowsUpdate -and $collectionData.sccm -and $collectionData.sccm.softwareUpdates) {
            $sccmUpdatesCount = if ($collectionData.sccm.softwareUpdates -is [Array]) { $collectionData.sccm.softwareUpdates.Count } else { 1 }
            if ($sccmUpdatesCount -gt 0) {
                # SCCM is actively managing software updates
                $collectionData.windowsUpdate.summary.updateSource = "Configuration Manager (SCCM)"
                $collectionData.windowsUpdate.summary.updateManagement = "SCCM"
                Write-DeviceDNALog -Message "Update management override: SCCM detected managing $sccmUpdatesCount update(s)" -Component 'Orchestration' -Type 1
            }
        }

        # Phase 2: Report Generation
        Write-Host ""
        Write-StatusMessage "Phase 2: Report Generation" -Type Progress

        # Add collection issues to the data
        $collectionData.collectionIssues = $script:CollectionIssues

        # Generate report using template + JSON architecture
        # NOTE: New-DeviceDNAReport now exports JSON internally and copies the template files
        $reportResult = $null
        $jsonPath = $null
        $templatePath = $null
        $reportUrl = $null

        try {
            Write-StatusMessage "Generating DeviceDNA report..." -Type Progress
            $reportResult = New-DeviceDNAReport -Data $collectionData -OutputPath $deviceOutputPath -DeviceName $deviceInfo.Hostname

            # Extract paths from result hashtable
            if ($reportResult) {
                $jsonPath = $reportResult.JsonPath
                $templatePath = $reportResult.TemplatePath
                $reportUrl = $reportResult.ReportUrl

                Write-StatusMessage "Report generated successfully" -Type Success
                Write-StatusMessage "  JSON: $(Split-Path -Leaf $jsonPath)" -Type Info
                Write-StatusMessage "  Template: $(Split-Path -Leaf $templatePath)" -Type Info
            }
        }
        catch {
            Write-StatusMessage "Failed to generate report: $($_.Exception.Message)" -Type Error
            $script:CollectionIssues += @{ severity = "Error"; phase = "Report"; message = $_.Exception.Message }
            $reportResult = $null
            $jsonPath = $null
            $templatePath = $null
            $reportUrl = $null
        }

        # For backward compatibility, set $reportPath to template path
        $reportPath = $templatePath

        # Generate README.md for repo display
        $readmePath = $null
        try {
            Write-StatusMessage "Generating README.md..." -Type Progress

            # Extract filenames from paths
            $htmlFileName = if ($reportPath) { Split-Path -Leaf $reportPath } else { $null }
            $jsonFileNameOnly = if ($jsonPath) { Split-Path -Leaf $jsonPath } else { $null }
            $logFileNameOnly = if ($script:LogFilePath) { Split-Path -Leaf $script:LogFilePath } else { $null }

            $readmePath = New-DeviceDNAReadme -Data $collectionData -OutputPath $deviceOutputPath -DeviceName $deviceInfo.Hostname -HtmlFileName $htmlFileName -JsonFileName $jsonFileNameOnly -LogFileName $logFileNameOnly
            Write-StatusMessage "README.md saved: $readmePath" -Type Success
        }
        catch {
            Write-StatusMessage "Failed to generate README.md: $($_.Exception.Message)" -Type Warning
            Write-DeviceDNALog -Message "README generation failed: $($_.Exception.Message)" -Component "Invoke-DeviceDNACollection" -Type 2
            $readmePath = $null
        }

        # Phase 3: Summary
        Write-Host ""
        $script:EndTime = Get-Date
        $duration = $script:EndTime - $script:StartTime

        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "  Collection Complete" -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Duration:       $([math]::Round($duration.TotalSeconds, 2)) seconds"
        Write-Host "  Management:     $($collectionData.deviceInfo.managementType)"
        Write-Host "  Computer GPOs:  $($collectionData.groupPolicy.computerScope.appliedGPOs.Count)"
        Write-Host "  Intune Profiles: $($collectionData.intune.configurationProfiles.Count)"
        Write-Host "  Intune Apps:    $($collectionData.intune.applications.Count)"
        Write-Host "  Remediations:   $($collectionData.intune.proactiveRemediations.Count)"
        Write-Host "  SCCM Apps:     $($collectionData.sccm.applications.Count)"
        Write-Host "  SCCM Baselines: $($collectionData.sccm.baselines.Count)"
        Write-Host "  SCCM Updates:  $($collectionData.sccm.softwareUpdates.Count)"
        Write-Host "  WU Pending:    $($collectionData.windowsUpdate.summary.pendingCount)"
        Write-Host "  Issues:         $($script:CollectionIssues.Count)"
        if ($jsonPath) {
            Write-Host "  JSON Data:      $jsonPath"
        }
        if ($reportPath) {
            Write-Host "  HTML Report:    $reportPath"
        }
        if ($readmePath) {
            Write-Host "  README:         $readmePath"
        }
        Write-Host ""

        # Auto-open report if requested
        if ($AutoOpen -and $templatePath -and (Test-Path $templatePath)) {
            try {
                # Construct file:// URL with data parameter
                # Viewer is at output root, JSON is in device subfolder
                $jsonFileName = Split-Path -Leaf $jsonPath
                $deviceFolderName = Split-Path -Leaf $outputPath
                $outputRoot = Split-Path -Parent $outputPath
                $viewerFileName = "DeviceDNA-Viewer.html"

                # Convert to file:// URL format
                # Note: Different browsers handle file:// URLs differently with query parameters
                # This works in most modern browsers (Chrome, Edge, Firefox)
                $fileUrl = "file:///$($outputRoot.Replace('\', '/'))/$viewerFileName?data=$deviceFolderName/$jsonFileName"

                Write-DeviceDNALog -Message "Opening report: $fileUrl" -Component "Invoke-DeviceDNACollection" -Type 1
                Start-Process $fileUrl

                Write-StatusMessage "Opened report in default browser" -Type Info
            }
            catch {
                Write-StatusMessage "Could not auto-open report: $($_.Exception.Message)" -Type Warning
                Write-StatusMessage "Manually open: $templatePath" -Type Info
            }
        }

        # Disconnect from Graph API
        Disconnect-GraphAPI

        # Complete logging
        Complete-DeviceDNALog

        return @{
            Success          = $true
            ReportPath       = $reportPath
            JsonPath         = $jsonPath
            LogPath          = $script:LogFilePath
            CollectionData   = $collectionData
            CollectionIssues = $script:CollectionIssues
            Duration         = $duration
        }
    }
    catch {
        Write-StatusMessage "Critical error in Device DNA collection: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Critical error: $($_.Exception.Message)" -Component "Invoke-DeviceDNACollection" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Critical"; message = $_.Exception.Message }

        # Disconnect from Graph API on error
        Disconnect-GraphAPI

        # Complete logging even on error
        Complete-DeviceDNALog

        return @{
            Success          = $false
            ReportPath       = $null
            JsonPath         = $null
            LogPath          = $script:LogFilePath
            CollectionData   = $collectionData
            CollectionIssues = $script:CollectionIssues
            Duration         = ((Get-Date) - $script:StartTime)
        }
    }
}
