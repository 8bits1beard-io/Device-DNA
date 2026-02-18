<#
.SYNOPSIS
    Device DNA - Local Intune Module
.DESCRIPTION
    Local device-perspective Intune data collection via WinRM.
    Includes app inventory, MDM diagnostics, configuration, and compliance state
    as seen from the device itself (not Graph API).
.NOTES
    Module: LocalIntune.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

function Get-LocalIntuneApplications {
    <#
    .SYNOPSIS
        Queries Win32 app installation status from local device registry via WinRM.
    .DESCRIPTION
        Queries HKLM\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps to retrieve
        actual installation status from the device's perspective.

        Returns a hashtable keyed by clean app GUID (no _N suffix) for O(1) lookup.
        Each value contains installState (string matching Reporting.ps1 badge logic),
        errorCode, context (Device/User), and raw ComplianceState/EnforcementState codes.

        Parses both device context (S-1-5-18 and 00000000-0000-0000-0000-000000000000)
        and user context (Azure AD Object IDs) apps. Device context is preferred
        when the same app ID appears under multiple contexts.

        State messages can be stored as either direct registry properties or as
        sub-subkeys (varies by device/IME version). Both approaches are tried.
    .PARAMETER ComputerName
        Target computer name. Use localhost for local queries.
    .PARAMETER IncludeUserContext
        Include user-context apps in addition to device-context apps.
    .OUTPUTS
        Hashtable keyed by app GUID. Each value is a hashtable with:
        InstallState, ErrorCode, Context, ComplianceState, EnforcementState
    .EXAMPLE
        $appMap = Get-LocalIntuneApplications -ComputerName "PC001" -IncludeUserContext
        $status = $appMap["some-guid-here"]
        if ($status) { Write-Host $status.InstallState }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUserContext
    )

    try {
        Write-StatusMessage "Querying local Win32 app registry on $ComputerName..." -Type Progress
        Write-DeviceDNALog -Message "Starting local Win32 app registry query" -Component "Get-LocalIntuneApplications" -Type 1

        # Script block to run on target device
        $scriptBlock = {
            param($IncludeUserContext)

            $localAppMap = @{}
            $imeRegPath = "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps"

            if (-not (Test-Path $imeRegPath)) {
                return @{
                    Success = $false
                    Error = "Intune Management Extension registry path not found. Device may not have Win32 apps deployed."
                    Apps = @{}
                }
            }

            $sidFolders = Get-ChildItem -Path $imeRegPath -ErrorAction SilentlyContinue

            foreach ($sidFolder in $sidFolders) {
                $sid = $sidFolder.PSChildName

                # Skip metadata folders (not app data)
                if ($sid -eq 'OperationalState' -or $sid -eq 'Reporting') { continue }

                # Both S-1-5-18 and 00000000-0000-0000-0000-000000000000 are device context
                $context = if ($sid -eq 'S-1-5-18' -or $sid -eq '00000000-0000-0000-0000-000000000000') { 'Device' } else { 'User' }

                # Skip user context if not requested
                if ($context -eq 'User' -and -not $IncludeUserContext) {
                    continue
                }

                $appSubkeys = Get-ChildItem -Path $sidFolder.PSPath -ErrorAction SilentlyContinue

                foreach ($appSubkey in $appSubkeys) {
                    $rawId = $appSubkey.PSChildName

                    # Strip _N suffix (e.g., "21e67fea-..._2" -> "21e67fea-...")
                    $cleanId = $rawId -replace '_\d+$', ''

                    # Skip non-GUID entries (e.g., "GRS")
                    if ($cleanId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { continue }

                    # Prefer device context over user context for duplicate app IDs
                    if ($localAppMap.ContainsKey($cleanId) -and $context -ne 'Device') { continue }

                    $appProps = Get-ItemProperty -Path $appSubkey.PSPath -ErrorAction SilentlyContinue
                    if (-not $appProps) { continue }

                    $record = @{
                        Context          = $context
                        ComplianceState  = $null
                        EnforcementState = $null
                        ErrorCode        = $null
                    }

                    # ComplianceStateMessage and EnforcementStateMessage can be stored as either:
                    # (a) JSON properties on the app key itself, or
                    # (b) Sub-subkeys containing a property of the same name
                    # Both patterns are observed across different devices/IME versions.

                    # Approach (a): Direct properties on parent key
                    if ($appProps.ComplianceStateMessage) {
                        try {
                            $csm = $appProps.ComplianceStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($csm) {
                                $record.ComplianceState = $csm.ComplianceState
                                $record.ErrorCode = $csm.ErrorCode
                            }
                        } catch {}
                    }
                    if ($appProps.EnforcementStateMessage) {
                        try {
                            $esm = $appProps.EnforcementStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($esm) {
                                $record.EnforcementState = $esm.EnforcementState
                                if (-not $record.ErrorCode -and $esm.ErrorCode) {
                                    $record.ErrorCode = $esm.ErrorCode
                                }
                            }
                        } catch {}
                    }

                    # Approach (b): Sub-subkeys (some devices store state as child registry keys)
                    if (-not $record.ComplianceState -or -not $record.EnforcementState) {
                        $subSubkeys = Get-ChildItem -Path $appSubkey.PSPath -ErrorAction SilentlyContinue
                        if ($subSubkeys) {
                            if (-not $record.ComplianceState) {
                                $csmKeyPath = Join-Path $appSubkey.PSPath 'ComplianceStateMessage'
                                if (Test-Path $csmKeyPath) {
                                    $csmProps = Get-ItemProperty -Path $csmKeyPath -ErrorAction SilentlyContinue
                                    if ($csmProps -and $csmProps.ComplianceStateMessage) {
                                        try {
                                            $csm = $csmProps.ComplianceStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                                            if ($csm) {
                                                $record.ComplianceState = $csm.ComplianceState
                                                if (-not $record.ErrorCode) { $record.ErrorCode = $csm.ErrorCode }
                                            }
                                        } catch {}
                                    }
                                }
                            }
                            if (-not $record.EnforcementState) {
                                $esmKeyPath = Join-Path $appSubkey.PSPath 'EnforcementStateMessage'
                                if (Test-Path $esmKeyPath) {
                                    $esmProps = Get-ItemProperty -Path $esmKeyPath -ErrorAction SilentlyContinue
                                    if ($esmProps -and $esmProps.EnforcementStateMessage) {
                                        try {
                                            $esm = $esmProps.EnforcementStateMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                                            if ($esm) {
                                                $record.EnforcementState = $esm.EnforcementState
                                                if (-not $record.ErrorCode -and $esm.ErrorCode) {
                                                    $record.ErrorCode = $esm.ErrorCode
                                                }
                                            }
                                        } catch {}
                                    }
                                }
                            }
                        }
                    }

                    # Map numeric codes to Reporting.ps1-compatible install state strings
                    # EnforcementState is primary (more granular), ComplianceState is fallback
                    # Ref: IME source — EnforcementState 1000=Success, 2000=InProgress, 3000=ReqNotMet, 4000+=Failed
                    # Ref: ComplianceState 1=Compliant, 2=NotCompliant, 3=Conflict, 4=Error, 5=NotEvaluated
                    $installState = $null
                    if ($record.EnforcementState) {
                        $esCode = [int]$record.EnforcementState
                        if ($esCode -eq 1000) { $installState = 'Installed' }
                        elseif ($esCode -ge 2000 -and $esCode -lt 3000) { $installState = 'Install Pending' }
                        elseif ($esCode -ge 3000 -and $esCode -lt 4000) { $installState = 'Not Applicable' }
                        elseif ($esCode -ge 4000) { $installState = 'Failed' }
                    }
                    if (-not $installState -and $null -ne $record.ComplianceState) {
                        $csCode = [int]$record.ComplianceState
                        if ($csCode -eq 1) { $installState = 'Installed' }
                        elseif ($csCode -eq 2) { $installState = 'Not Installed' }
                        elseif ($csCode -eq 3 -or $csCode -eq 4) { $installState = 'Failed' }
                        elseif ($csCode -eq 5) { $installState = 'Unknown' }
                    }
                    if (-not $installState) { $installState = 'Unknown' }

                    $record.InstallState = $installState
                    $localAppMap[$cleanId] = $record
                }
            }

            return @{
                Success = $true
                Error = $null
                Apps = $localAppMap
            }
        }

        # Execute on target device
        $queryStart = Get-Date
        $invokeParams = @{
            ScriptBlock = $scriptBlock
            ArgumentList = $IncludeUserContext.IsPresent
        }

        if ($ComputerName -ne 'localhost' -and $ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
        }

        $result = Invoke-Command @invokeParams -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        if ($result.Success) {
            $appCount = $result.Apps.Count
            Write-DeviceDNALog -Message "Local Win32 app query successful: $appCount apps found in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-LocalIntuneApplications" -Type 1
            Write-StatusMessage "Found $appCount Win32 apps in local registry" -Type Success
            return $result.Apps
        }
        else {
            Write-DeviceDNALog -Message "Local Win32 app query returned no data: $($result.Error)" -Component "Get-LocalIntuneApplications" -Type 2
            Write-StatusMessage "No Win32 apps found: $($result.Error)" -Type Warning
            return @{}
        }
    }
    catch {
        Write-StatusMessage "Error querying local Win32 apps: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Local Win32 app query failed: $($_.Exception.Message)" -Component "Get-LocalIntuneApplications" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Local Intune"; message = "Error querying local Win32 apps: $($_.Exception.Message)" }
        return @{}
    }
}

function Get-MdmDiagnosticReport {
    <#
    .SYNOPSIS
        Collects MDM diagnostic report from local device via mdmdiagnosticstool.exe.
    .DESCRIPTION
        Executes mdmdiagnosticstool.exe on the remote device to generate a comprehensive
        MDM diagnostic report including enrollment info, applied policies, certificates,
        and configuration state.

        Returns parsed XML data from the diagnostic report.
    .PARAMETER ComputerName
        Target computer name. Use localhost for local queries.
    .OUTPUTS
        Hashtable with: EnrollmentInfo, Policies, Certificates, ConfigurationStates, RawXml
    .EXAMPLE
        $report = Get-MdmDiagnosticReport -ComputerName "PC001"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    try {
        Write-StatusMessage "Generating MDM diagnostic report on $ComputerName..." -Type Progress
        Write-DeviceDNALog -Message "Starting MDM diagnostic report collection" -Component "Get-MdmDiagnosticReport" -Type 1

        # Script block to run on remote device
        $scriptBlock = {
            $tempPath = [System.IO.Path]::GetTempPath()
            $reportZip = Join-Path $tempPath "MDMDiagReport_$([guid]::NewGuid()).zip"
            $extractPath = Join-Path $tempPath "MDMDiag_$([guid]::NewGuid())"

            try {
                # Run MDM diagnostic tool
                $mdmToolPath = "$env:SystemRoot\System32\mdmdiagnosticstool.exe"

                if (-not (Test-Path $mdmToolPath)) {
                    return @{
                        Success = $false
                        Error = "mdmdiagnosticstool.exe not found. May not be available on this Windows version."
                        Data = $null
                    }
                }

                # Execute diagnostic tool
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $mdmToolPath
                $startInfo.Arguments = "-area DeviceEnrollment;DeviceProvisioning;Autopilot -zip `"$reportZip`""
                $startInfo.UseShellExecute = $false
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.CreateNoWindow = $true

                $process = New-Object System.Diagnostics.Process
                $process.StartInfo = $startInfo
                $process.Start() | Out-Null
                $process.WaitForExit(30000) # 30 second timeout

                if ($process.ExitCode -ne 0) {
                    return @{
                        Success = $false
                        Error = "mdmdiagnosticstool.exe failed with exit code: $($process.ExitCode)"
                        Data = $null
                    }
                }

                if (-not (Test-Path $reportZip)) {
                    return @{
                        Success = $false
                        Error = "MDM diagnostic report ZIP not created"
                        Data = $null
                    }
                }

                # Extract ZIP
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($reportZip, $extractPath)

                # Find and read XML report
                $xmlReport = Get-ChildItem -Path $extractPath -Filter "MDMDiagReport.xml" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

                if (-not $xmlReport) {
                    return @{
                        Success = $false
                        Error = "MDMDiagReport.xml not found in diagnostic output"
                        Data = $null
                    }
                }

                # Read and parse XML
                [xml]$xmlContent = Get-Content -Path $xmlReport.FullName -Raw

                # Extract key information
                $enrollmentInfo = @{}
                $policies = @()
                $certificates = @()

                # Parse enrollment info
                if ($xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Enrollment) {
                    $enrollment = $xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Enrollment
                    $enrollmentInfo = @{
                        EnrollmentState = $enrollment.EnrollmentState
                        MDMServerURL = $enrollment.DiscoveryServiceFullURL
                        DeviceID = $enrollment.DeviceID
                        AADDeviceID = $enrollment.AADDeviceID
                        EnrollmentType = $enrollment.EnrollmentType
                        UPN = $enrollment.UPN
                    }
                }

                # Parse applied policies
                if ($xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Policies) {
                    foreach ($policy in $xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Policies.Policy) {
                        $policies += @{
                            PolicyName = $policy.PolicyName
                            PolicyArea = $policy.PolicyArea
                            PolicyValue = $policy.PolicyValue
                        }
                    }
                }

                # Parse certificates
                if ($xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Certificates) {
                    foreach ($cert in $xmlContent.MDMEnterpriseDiagnosticsReport.DeviceManagementData.Certificates.Certificate) {
                        $certificates += @{
                            Thumbprint = $cert.Thumbprint
                            Subject = $cert.Subject
                            Issuer = $cert.Issuer
                            ValidFrom = $cert.ValidFrom
                            ValidTo = $cert.ValidTo
                        }
                    }
                }

                return @{
                    Success = $true
                    Error = $null
                    Data = @{
                        EnrollmentInfo = $enrollmentInfo
                        Policies = $policies
                        Certificates = $certificates
                        RawXml = $xmlContent.OuterXml
                    }
                }
            }
            catch {
                return @{
                    Success = $false
                    Error = $_.Exception.Message
                    Data = $null
                }
            }
            finally {
                # Cleanup temp files
                if (Test-Path $reportZip) { Remove-Item $reportZip -Force -ErrorAction SilentlyContinue }
                if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        # Execute on remote device
        $queryStart = Get-Date
        $invokeParams = @{
            ScriptBlock = $scriptBlock
        }

        if ($ComputerName -ne 'localhost' -and $ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
        }

        $result = Invoke-Command @invokeParams -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        if ($result.Success) {
            Write-DeviceDNALog -Message "MDM diagnostic report collected successfully in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-MdmDiagnosticReport" -Type 1
            Write-StatusMessage "MDM diagnostic report collected successfully" -Type Success
            return $result.Data
        }
        else {
            Write-DeviceDNALog -Message "MDM diagnostic report failed: $($result.Error)" -Component "Get-MdmDiagnosticReport" -Type 2
            Write-StatusMessage "MDM diagnostic report failed: $($result.Error)" -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Local Intune"; message = "MDM diagnostic report: $($result.Error)" }
            return $null
        }
    }
    catch {
        Write-StatusMessage "Error collecting MDM diagnostic report: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "MDM diagnostic report error: $($_.Exception.Message)" -Component "Get-MdmDiagnosticReport" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Local Intune"; message = "Error collecting MDM diagnostic report: $($_.Exception.Message)" }
        return $null
    }
}

function Get-LocalMdmConfiguration {
    <#
    .SYNOPSIS
        Queries MDM WMI classes and PolicyManager registry for current MDM configuration.
    .DESCRIPTION
        Queries the root\cimv2\mdm\dmmap WMI namespace to get currently applied MDM
        policy values from Configuration Service Provider (CSP) mappings.

        Also queries the PolicyManager registry for device and user policy values.
    .PARAMETER ComputerName
        Target computer name. Use localhost for local queries.
    .OUTPUTS
        Hashtable with: WmiPolicies, RegistryPolicies (Device/User), Summary
    .EXAMPLE
        $config = Get-LocalMdmConfiguration -ComputerName "PC001"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    try {
        Write-StatusMessage "Querying local MDM configuration on $ComputerName..." -Type Progress
        Write-DeviceDNALog -Message "Starting local MDM configuration query" -Component "Get-LocalMdmConfiguration" -Type 1

        # Script block to run on remote device
        $scriptBlock = {
            $result = @{
                WmiPolicies = @()
                DevicePolicies = @()
                UserPolicies = @()
                Summary = @{}
            }

            # Query MDM WMI namespace
            try {
                # Get all MDM_Policy classes
                $mdmClasses = Get-CimClass -Namespace "root\cimv2\mdm\dmmap" -ClassName "MDM_Policy_*" -ErrorAction SilentlyContinue

                foreach ($class in $mdmClasses) {
                    try {
                        $instances = Get-CimInstance -Namespace "root\cimv2\mdm\dmmap" -ClassName $class.CimClassName -ErrorAction SilentlyContinue

                        foreach ($instance in $instances) {
                            # Extract non-null properties
                            $properties = @{}
                            foreach ($prop in $instance.CimInstanceProperties) {
                                if ($null -ne $prop.Value -and $prop.Name -ne 'InstanceID' -and $prop.Name -ne 'ParentID') {
                                    $properties[$prop.Name] = $prop.Value
                                }
                            }

                            if ($properties.Count -gt 0) {
                                $result.WmiPolicies += @{
                                    ClassName = $class.CimClassName
                                    InstanceID = $instance.InstanceID
                                    Properties = $properties
                                }
                            }
                        }
                    }
                    catch {
                        # Skip classes we can't query
                        continue
                    }
                }

                $result.Summary.WmiPolicyCount = $result.WmiPolicies.Count
            }
            catch {
                $result.Summary.WmiError = $_.Exception.Message
            }

            # Query PolicyManager registry - Device policies
            try {
                $devicePolicyPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device"
                if (Test-Path $devicePolicyPath) {
                    $devicePolicyKeys = Get-ChildItem -Path $devicePolicyPath -Recurse -ErrorAction SilentlyContinue

                    foreach ($key in $devicePolicyKeys) {
                        try {
                            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                            $policyValues = @{}

                            foreach ($propName in $props.PSObject.Properties.Name) {
                                # Skip PowerShell-added properties
                                if ($propName -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                                    $policyValues[$propName] = $props.$propName
                                }
                            }

                            if ($policyValues.Count -gt 0) {
                                $result.DevicePolicies += @{
                                    PolicyPath = $key.Name -replace 'HKEY_LOCAL_MACHINE', 'HKLM:'
                                    Values = $policyValues
                                }
                            }
                        }
                        catch {
                            continue
                        }
                    }
                }

                $result.Summary.DevicePolicyCount = $result.DevicePolicies.Count
            }
            catch {
                $result.Summary.DevicePolicyError = $_.Exception.Message
            }

            # Query PolicyManager registry - User policies
            try {
                $userPolicyPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\user"
                if (Test-Path $userPolicyPath) {
                    $userPolicyKeys = Get-ChildItem -Path $userPolicyPath -Recurse -ErrorAction SilentlyContinue

                    foreach ($key in $userPolicyKeys) {
                        try {
                            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                            $policyValues = @{}

                            foreach ($propName in $props.PSObject.Properties.Name) {
                                if ($propName -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                                    $policyValues[$propName] = $props.$propName
                                }
                            }

                            if ($policyValues.Count -gt 0) {
                                $result.UserPolicies += @{
                                    PolicyPath = $key.Name -replace 'HKEY_LOCAL_MACHINE', 'HKLM:'
                                    Values = $policyValues
                                }
                            }
                        }
                        catch {
                            continue
                        }
                    }
                }

                $result.Summary.UserPolicyCount = $result.UserPolicies.Count
            }
            catch {
                $result.Summary.UserPolicyError = $_.Exception.Message
            }

            return $result
        }

        # Execute on remote device
        $queryStart = Get-Date
        $invokeParams = @{
            ScriptBlock = $scriptBlock
        }

        if ($ComputerName -ne 'localhost' -and $ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
        }

        $result = Invoke-Command @invokeParams -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        Write-DeviceDNALog -Message "Local MDM configuration query complete: WMI=$($result.Summary.WmiPolicyCount), Device=$($result.Summary.DevicePolicyCount), User=$($result.Summary.UserPolicyCount) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-LocalMdmConfiguration" -Type 1
        Write-StatusMessage "Found $($result.Summary.WmiPolicyCount) WMI policies, $($result.Summary.DevicePolicyCount) device policies, $($result.Summary.UserPolicyCount) user policies" -Type Success

        return $result
    }
    catch {
        Write-StatusMessage "Error querying local MDM configuration: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Local MDM configuration query failed: $($_.Exception.Message)" -Component "Get-LocalMdmConfiguration" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Local Intune"; message = "Error querying local MDM configuration: $($_.Exception.Message)" }
        return @{
            WmiPolicies = @()
            DevicePolicies = @()
            UserPolicies = @()
            Summary = @{ Error = $_.Exception.Message }
        }
    }
}

function Get-LocalComplianceState {
    <#
    .SYNOPSIS
        Queries local compliance state from enrollment registry and event logs.
    .DESCRIPTION
        Queries HKLM\SOFTWARE\Microsoft\Enrollments for ComplianceState and MDM
        enrollment information.

        Optionally parses DeviceManagement event logs for recent compliance evaluation events.
    .PARAMETER ComputerName
        Target computer name. Use localhost for local queries.
    .PARAMETER IncludeEventLogs
        Include recent DeviceManagement event log entries (last 24 hours).
    .OUTPUTS
        Hashtable with: EnrollmentGuid, ComplianceState, LastSyncTime, ServerUrl,
        AADDeviceId, Events (if requested)
    .EXAMPLE
        $compliance = Get-LocalComplianceState -ComputerName "PC001" -IncludeEventLogs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeEventLogs
    )

    try {
        Write-StatusMessage "Querying local compliance state on $ComputerName..." -Type Progress
        Write-DeviceDNALog -Message "Starting local compliance state query" -Component "Get-LocalComplianceState" -Type 1

        # Script block to run on remote device
        $scriptBlock = {
            param($IncludeEventLogs)

            $result = @{
                Enrollments = @()
                Events = @()
                Success = $true
                Error = $null
            }

            try {
                # Query enrollment registry
                $enrollmentsPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"

                if (-not (Test-Path $enrollmentsPath)) {
                    $result.Success = $false
                    $result.Error = "Enrollments registry path not found. Device may not be MDM enrolled."
                    return $result
                }

                # Get all enrollment GUIDs
                $enrollmentGuids = Get-ChildItem -Path $enrollmentsPath -ErrorAction SilentlyContinue

                foreach ($enrollment in $enrollmentGuids) {
                    try {
                        $enrollmentProps = Get-ItemProperty -Path $enrollment.PSPath -ErrorAction SilentlyContinue

                        if ($enrollmentProps) {
                            $result.Enrollments += @{
                                EnrollmentGuid = $enrollment.PSChildName
                                DiscoveryServiceFullURL = $enrollmentProps.DiscoveryServiceFullURL
                                AADDeviceID = $enrollmentProps.AADDeviceID
                                DeviceID = $enrollmentProps.DeviceID
                                UPN = $enrollmentProps.UPN
                                EnrollmentState = $enrollmentProps.EnrollmentState
                                EnrollmentType = $enrollmentProps.EnrollmentType
                                LastSuccessfulSync = $enrollmentProps.LastSuccessfulSync
                                ComplianceState = $enrollmentProps.ComplianceState
                            }
                        }
                    }
                    catch {
                        continue
                    }
                }

                # Query event logs if requested
                if ($IncludeEventLogs) {
                    try {
                        $startTime = (Get-Date).AddHours(-24)

                        # Query DeviceManagement-Enterprise-Diagnostics-Provider logs
                        $logName = "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin"

                        if ([System.Diagnostics.EventLog]::Exists($logName)) {
                            $events = Get-WinEvent -LogName $logName -MaxEvents 100 -ErrorAction SilentlyContinue |
                                Where-Object { $_.TimeCreated -ge $startTime } |
                                Select-Object -First 50

                            foreach ($event in $events) {
                                $result.Events += @{
                                    TimeCreated = $event.TimeCreated
                                    Id = $event.Id
                                    Level = $event.LevelDisplayName
                                    Message = $event.Message
                                }
                            }
                        }
                    }
                    catch {
                        # Event log query failed, but don't fail entire operation
                        $result.EventLogError = $_.Exception.Message
                    }
                }

                return $result
            }
            catch {
                $result.Success = $false
                $result.Error = $_.Exception.Message
                return $result
            }
        }

        # Execute on remote device
        $queryStart = Get-Date
        $invokeParams = @{
            ScriptBlock = $scriptBlock
            ArgumentList = $IncludeEventLogs.IsPresent
        }

        if ($ComputerName -ne 'localhost' -and $ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
        }

        $result = Invoke-Command @invokeParams -ErrorAction Stop
        $queryDuration = (Get-Date) - $queryStart

        if ($result.Success) {
            Write-DeviceDNALog -Message "Local compliance state query successful: $($result.Enrollments.Count) enrollment(s), $($result.Events.Count) event(s) in $($queryDuration.TotalMilliseconds.ToString('F0'))ms" -Component "Get-LocalComplianceState" -Type 1
            Write-StatusMessage "Found $($result.Enrollments.Count) MDM enrollment(s)" -Type Success
            return $result
        }
        else {
            Write-DeviceDNALog -Message "Local compliance state query failed: $($result.Error)" -Component "Get-LocalComplianceState" -Type 2
            Write-StatusMessage "Compliance state query failed: $($result.Error)" -Type Warning
            $script:CollectionIssues += @{ severity = "Warning"; phase = "Local Intune"; message = "Local compliance state: $($result.Error)" }
            return $result
        }
    }
    catch {
        Write-StatusMessage "Error querying local compliance state: $($_.Exception.Message)" -Type Error
        Write-DeviceDNALog -Message "Local compliance state query error: $($_.Exception.Message)" -Component "Get-LocalComplianceState" -Type 3
        $script:CollectionIssues += @{ severity = "Error"; phase = "Local Intune"; message = "Error querying local compliance state: $($_.Exception.Message)" }
        return @{
            Enrollments = @()
            Events = @()
            Success = $false
            Error = $_.Exception.Message
        }
    }
}
