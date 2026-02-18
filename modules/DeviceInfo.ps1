<#
.SYNOPSIS
    Device DNA - Device Information Module
.DESCRIPTION
    Device inventory collection including hardware, network, security, and power information.
    Uses CIM-first approach with WMI fallback for compatibility.
.NOTES
    Module: DeviceInfo.ps1
    Dependencies: Core.ps1, Logging.ps1, Helpers.ps1
    Version: 0.2.0
#>

function Get-DeviceJoinType {
    <#
    .SYNOPSIS
        Determines the device join type by parsing dsregcmd /status output.
    .PARAMETER ComputerName
        Optional computer name for remote execution.
    .OUTPUTS
        PSCustomObject with join status properties.
    .NOTES
        Handles Hybrid Azure AD Joined devices (both AzureAdJoined and DomainJoined = YES).
        The dsregcmd output format has variable whitespace around the colon separator.
        Example output:
            +----------------------------------------------------------------------+
            | Device State                                                         |
            +----------------------------------------------------------------------+
                         AzureAdJoined : YES
                      EnterpriseJoined : NO
                          DomainJoined : YES
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $joinInfo = [PSCustomObject]@{
        AzureAdJoined     = $false
        DomainJoined      = $false
        WorkplaceJoined   = $false
        DeviceId          = $null
        TenantId          = $null
        TenantName        = $null
        RawOutput         = $null
    }

    try {
        $dsregOutput = $null

        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            # Local execution - no WinRM overhead
            $dsregOutput = & dsregcmd /status 2>&1
        }
        else {
            # Remote execution via WinRM
            try {
                $dsregOutput = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                    & dsregcmd /status 2>&1
                } -ErrorAction Stop
            }
            catch {
                $script:CollectionIssues += @{ severity = "Error"; phase = "Device Info"; message = "Failed to execute dsregcmd on $ComputerName : $($_.Exception.Message)" }
                return $joinInfo
            }
        }

        if ($dsregOutput) {
            # IMPORTANT: Invoke-Command returns an array of strings, not a single string.
            # The -match operator on an array returns matching elements (not a boolean),
            # and does NOT populate the $Matches automatic variable.
            # We must join to a single string first for regex matching to work correctly.
            $dsregString = if ($dsregOutput -is [array]) {
                $dsregOutput -join "`n"
            } else {
                [string]$dsregOutput
            }

            $joinInfo.RawOutput = $dsregString

            # Parse AzureAdJoined - handle variable whitespace and case-insensitive comparison
            # Format: "             AzureAdJoined : YES" (leading spaces, spaces around colon)
            if ($dsregString -match 'AzureAdJoined\s*:\s*(\w+)') {
                $joinInfo.AzureAdJoined = ($Matches[1] -ieq 'YES')
            }

            # Parse DomainJoined - same format handling
            if ($dsregString -match 'DomainJoined\s*:\s*(\w+)') {
                $joinInfo.DomainJoined = ($Matches[1] -ieq 'YES')
            }

            # Parse WorkplaceJoined (Workplace Join / Azure AD Registered)
            if ($dsregString -match 'WorkplaceJoined\s*:\s*(\w+)') {
                $joinInfo.WorkplaceJoined = ($Matches[1] -ieq 'YES')
            }

            # Parse DeviceId
            if ($dsregString -match 'DeviceId\s*:\s*([\w-]+)') {
                $joinInfo.DeviceId = $Matches[1]
            }

            # Parse TenantId
            if ($dsregString -match 'TenantId\s*:\s*([\w-]+)') {
                $joinInfo.TenantId = $Matches[1]
            }

            # Parse TenantName - handle both "TenantName" and "Tenant Name" formats
            if ($dsregString -match 'TenantName\s*:\s*(.+)' -or $dsregString -match 'Tenant Name\s*:\s*(.+)') {
                $joinInfo.TenantName = $Matches[1].Trim()
            }
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Device Info"; message = "Error parsing device join type: $($_.Exception.Message)" }
    }

    return $joinInfo
}

function Test-MdmEnrollment {
    <#
    .SYNOPSIS
        Checks if the device is enrolled in an MDM service (e.g. Intune).
    .DESCRIPTION
        Reads HKLM:\SOFTWARE\Microsoft\Enrollments\* to find active MDM enrollments.
        A sub-key with a non-empty ProviderID indicates active MDM enrollment.
        Ref: https://learn.microsoft.com/windows/client-management/mdm-diagnose-enrollment
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Hashtable with IsEnrolled (bool), ProviderID, DiscoveryUrl, UPN.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $result = @{
        IsEnrolled   = $false
        ProviderID   = $null
        DiscoveryUrl = $null
        UPN          = $null
    }

    try {
        $scriptBlock = {
            $enrollResult = @{ IsEnrolled = $false; ProviderID = $null; DiscoveryUrl = $null; UPN = $null }
            $enrollPath = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
            if (Test-Path $enrollPath) {
                $subKeys = Get-ChildItem -Path $enrollPath -ErrorAction SilentlyContinue
                foreach ($key in $subKeys) {
                    $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.ProviderID -and $props.ProviderID -ne '') {
                        $enrollResult.IsEnrolled = $true
                        $enrollResult.ProviderID = $props.ProviderID
                        $enrollResult.DiscoveryUrl = $props.DiscoveryServiceFullURL
                        $enrollResult.UPN = $props.UPN
                        break
                    }
                }
            }
            return $enrollResult
        }

        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }
    }
    catch {
        Write-DeviceDNALog -Message "MDM enrollment check failed: $($_.Exception.Message)" -Component 'Test-MdmEnrollment' -Type 2
    }

    return $result
}

function Test-CoManagement {
    <#
    .SYNOPSIS
        Checks for co-management indicators on the device.
    .DESCRIPTION
        Reads HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM\ClientHealthStatus.
        When the ConfigMgr client is co-managed with Intune, it writes health status here.
        Bit 1 (value is odd) = client installed and reporting to Intune.
        Ref: https://learn.microsoft.com/troubleshoot/mem/intune/comanage-configmgr/troubleshoot-co-management-bootstrap
    .PARAMETER ComputerName
        Target computer name.
    .OUTPUTS
        Hashtable with IsCoManaged (bool), ClientHealthStatus (int).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $result = @{
        IsCoManaged        = $false
        ClientHealthStatus = $null
    }

    try {
        $scriptBlock = {
            $coResult = @{ IsCoManaged = $false; ClientHealthStatus = $null }
            $mdmPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MDM'
            if (Test-Path $mdmPath) {
                $props = Get-ItemProperty -Path $mdmPath -ErrorAction SilentlyContinue
                if ($props -and $null -ne $props.ClientHealthStatus) {
                    $coResult.ClientHealthStatus = $props.ClientHealthStatus
                    # Bit 1 = client installed, reporting health to Intune
                    $coResult.IsCoManaged = (($props.ClientHealthStatus -band 1) -eq 1)
                }
            }
            return $coResult
        }

        if (Test-IsLocalComputer -ComputerName $ComputerName) {
            $result = & $scriptBlock
        }
        else {
            $result = Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
        }
    }
    catch {
        Write-DeviceDNALog -Message "Co-management check failed: $($_.Exception.Message)" -Component 'Test-CoManagement' -Type 2
    }

    return $result
}

function Get-ManagementType {
    <#
    .SYNOPSIS
        Determines the device management type from join state, SCCM, and MDM signals.
    .DESCRIPTION
        Returns a management type string based on 4 input signals:
        - azureAdJoined, domainJoined, sccmInstalled, mdmEnrolled
        Ref: https://learn.microsoft.com/intune/configmgr/comanage/how-to-monitor
    .PARAMETER AzureAdJoined
        Whether the device is Azure AD joined.
    .PARAMETER DomainJoined
        Whether the device is domain joined.
    .PARAMETER SccmInstalled
        Whether the SCCM/ConfigMgr client is installed.
    .PARAMETER MdmEnrolled
        Whether the device is MDM enrolled.
    .PARAMETER IsCoManaged
        Whether co-management health status was detected.
    .OUTPUTS
        String: management type label.
    #>
    [CmdletBinding()]
    param(
        [bool]$AzureAdJoined,
        [bool]$DomainJoined,
        [bool]$SccmInstalled,
        [bool]$MdmEnrolled,
        [bool]$IsCoManaged
    )

    # Azure AD only (no domain)
    if ($AzureAdJoined -and -not $DomainJoined) {
        if ($MdmEnrolled -and -not $SccmInstalled) {
            return 'Cloud-only'
        }
        elseif ($MdmEnrolled -and $SccmInstalled) {
            return 'Cloud (Co-managed)'
        }
        else {
            return 'Azure AD Joined'
        }
    }

    # Domain only (no Azure AD)
    if ($DomainJoined -and -not $AzureAdJoined) {
        if ($SccmInstalled) {
            return 'On-prem only'
        }
        else {
            return 'On-prem only (GPO)'
        }
    }

    # Hybrid (both Azure AD + Domain)
    if ($AzureAdJoined -and $DomainJoined) {
        if ($SccmInstalled -and $MdmEnrolled) {
            return 'Co-managed'
        }
        elseif ($MdmEnrolled -and -not $SccmInstalled) {
            return 'Hybrid (Intune)'
        }
        elseif ($SccmInstalled -and -not $MdmEnrolled) {
            return 'Hybrid (SCCM)'
        }
        else {
            return 'Hybrid (GPO only)'
        }
    }

    return 'Unmanaged'
}

function Get-ProcessorInfo {
    <#
    .SYNOPSIS
        Collects CPU/Processor information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with processor information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $processorInfo = @{
        Name         = $null
        Manufacturer = $null
        Cores        = $null
        LogicalProcessors = $null
        MaxClockSpeed = $null
        Architecture = $null
    }

    try {
        if ($CimSession) {
            $cpu = Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        }
        elseif ($ComputerName) {
            $cpu = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        }
        else {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        }

        if ($cpu) {
            $processorInfo.Name = $cpu.Name
            $processorInfo.Manufacturer = $cpu.Manufacturer
            $processorInfo.Cores = $cpu.NumberOfCores
            $processorInfo.LogicalProcessors = $cpu.NumberOfLogicalProcessors
            $processorInfo.MaxClockSpeed = "$($cpu.MaxClockSpeed) MHz"

            # Translate architecture
            $archMap = @{ 0 = 'x86'; 1 = 'MIPS'; 2 = 'Alpha'; 3 = 'PowerPC'; 5 = 'ARM'; 6 = 'ia64'; 9 = 'x64'; 12 = 'ARM64' }
            $processorInfo.Architecture = if ($archMap.ContainsKey($cpu.Architecture)) { $archMap[$cpu.Architecture] } else { "Unknown ($($cpu.Architecture))" }
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect processor info: $($_.Exception.Message)" -Component "Get-ProcessorInfo" -Type 2
    }

    return $processorInfo
}

function Get-MemoryInfo {
    <#
    .SYNOPSIS
        Collects memory/RAM information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with memory information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $memoryInfo = @{
        TotalPhysicalMemory = $null
        AvailableMemory = $null
        MemoryModules = @()
    }

    try {
        # Get total memory from OS
        if ($CimSession) {
            $os = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
            $modules = Get-CimInstance -CimSession $CimSession -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
        }
        elseif ($ComputerName) {
            $os = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_OperatingSystem -ErrorAction Stop
            $modules = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
        }
        else {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $modules = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
        }

        if ($os) {
            $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
            $availableGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
            $memoryInfo.TotalPhysicalMemory = "$totalGB GB"
            $memoryInfo.AvailableMemory = "$availableGB GB"
        }

        # Get memory module details
        # Group by DeviceLocator to consolidate DDR5 ranks into physical DIMMs
        # (DDR5 WMI may report multiple entries per physical stick)
        if ($modules) {
            $grouped = @{}
            foreach ($module in $modules) {
                $slot = $module.DeviceLocator
                if (-not $slot) { $slot = "Unknown" }

                if ($grouped.ContainsKey($slot)) {
                    $grouped[$slot].Capacity += $module.Capacity
                }
                else {
                    $grouped[$slot] = @{
                        Capacity = [uint64]$module.Capacity
                        Speed = $module.Speed
                        Manufacturer = $module.Manufacturer
                        PartNumber = $module.PartNumber
                        DeviceLocator = $slot
                    }
                }
            }

            foreach ($slot in $grouped.Keys) {
                $info = $grouped[$slot]
                $capacityGB = [math]::Round($info.Capacity / 1GB, 2)
                $memoryInfo.MemoryModules += @{
                    Capacity = "$capacityGB GB"
                    Speed = "$($info.Speed) MHz"
                    Manufacturer = $info.Manufacturer
                    PartNumber = $info.PartNumber
                    Slot = $info.DeviceLocator
                }
            }
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect memory info: $($_.Exception.Message)" -Component "Get-MemoryInfo" -Type 2
    }

    return $memoryInfo
}

function Get-StorageInfo {
    <#
    .SYNOPSIS
        Collects storage/disk information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with storage information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $storageInfo = @{
        Disks = @()
    }

    try {
        if ($CimSession) {
            $disks = Get-CimInstance -CimSession $CimSession -ClassName Win32_DiskDrive -ErrorAction Stop
        }
        elseif ($ComputerName) {
            $disks = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_DiskDrive -ErrorAction Stop
        }
        else {
            $disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop
        }

        foreach ($disk in $disks) {
            $sizeGB = [math]::Round($disk.Size / 1GB, 2)
            $storageInfo.Disks += @{
                Model = $disk.Model
                Size = "$sizeGB GB"
                InterfaceType = $disk.InterfaceType
                MediaType = $disk.MediaType
                Status = $disk.Status
            }
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect storage info: $($_.Exception.Message)" -Component "Get-StorageInfo" -Type 2
    }

    return $storageInfo
}

function Get-BiosInfo {
    <#
    .SYNOPSIS
        Collects BIOS/firmware, TPM, and Secure Boot information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with BIOS information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $biosInfo = @{
        Manufacturer = $null
        Version = $null
        ReleaseDate = $null
        SMBIOSVersion = $null
        UEFIMode = $null
        SecureBoot = $null
        TPMPresent = $null
        TPMVersion = $null
        TPMEnabled = $null
    }

    try {
        # Get BIOS info
        if ($CimSession) {
            $bios = Get-CimInstance -CimSession $CimSession -ClassName Win32_BIOS -ErrorAction Stop
        }
        elseif ($ComputerName) {
            $bios = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_BIOS -ErrorAction Stop
        }
        else {
            $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        }

        if ($bios) {
            $biosInfo.Manufacturer = $bios.Manufacturer
            $biosInfo.Version = $bios.SMBIOSBIOSVersion
            $biosInfo.ReleaseDate = $bios.ReleaseDate
            $biosInfo.SMBIOSVersion = "$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)"
        }

        # Check UEFI mode (requires running on target system)
        if (-not $ComputerName -and -not $CimSession) {
            try {
                $biosInfo.UEFIMode = if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'Legacy BIOS' }

                # Get Secure Boot status
                $secureBootState = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction SilentlyContinue
                $biosInfo.SecureBoot = if ($secureBootState.UEFISecureBootEnabled -eq 1) { 'Enabled' } else { 'Disabled' }
            }
            catch {
                $biosInfo.UEFIMode = 'N/A (Remote)'
                $biosInfo.SecureBoot = 'N/A (Remote)'
            }
        }
        else {
            $biosInfo.UEFIMode = 'N/A (Remote)'
            $biosInfo.SecureBoot = 'N/A (Remote)'
        }

        # Get TPM info
        try {
            if ($CimSession) {
                $tpm = Get-CimInstance -CimSession $CimSession -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            }
            elseif ($ComputerName) {
                $tpm = Get-CimInstance -ComputerName $ComputerName -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            }
            else {
                $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue
            }

            if ($tpm) {
                $biosInfo.TPMPresent = 'Yes'
                $biosInfo.TPMEnabled = if ($tpm.IsEnabled().IsEnabled) { 'Enabled' } else { 'Disabled' }
                $biosInfo.TPMVersion = "$($tpm.SpecVersion)"
            }
            else {
                $biosInfo.TPMPresent = 'No'
            }
        }
        catch {
            $biosInfo.TPMPresent = 'Unknown'
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect BIOS info: $($_.Exception.Message)" -Component "Get-BiosInfo" -Type 2
    }

    return $biosInfo
}

function Get-NetworkInfo {
    <#
    .SYNOPSIS
        Collects network configuration information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with network information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $networkInfo = @{
        Adapters = @()
    }

    try {
        if ($CimSession) {
            $adapters = Get-CimInstance -CimSession $CimSession -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        }
        elseif ($ComputerName) {
            $adapters = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        }
        else {
            $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
        }

        foreach ($adapter in $adapters) {
            $adapterInfo = @{
                Description = $adapter.Description
                MACAddress = $adapter.MACAddress
                IPAddress = if ($adapter.IPAddress) { $adapter.IPAddress -join ', ' } else { 'N/A' }
                SubnetMask = if ($adapter.IPSubnet) { $adapter.IPSubnet -join ', ' } else { 'N/A' }
                DefaultGateway = if ($adapter.DefaultIPGateway) { $adapter.DefaultIPGateway -join ', ' } else { 'N/A' }
                DHCPEnabled = if ($adapter.DHCPEnabled) { 'Yes' } else { 'No' }
                DHCPServer = if ($adapter.DHCPServer) { $adapter.DHCPServer } else { 'N/A' }
                DNSServers = if ($adapter.DNSServerSearchOrder) { $adapter.DNSServerSearchOrder -join ', ' } else { 'N/A' }
                DNSDomain = if ($adapter.DNSDomain) { $adapter.DNSDomain } else { 'N/A' }
            }
            $networkInfo.Adapters += $adapterInfo
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect network info: $($_.Exception.Message)" -Component "Get-NetworkInfo" -Type 2
    }

    return $networkInfo
}

function Get-ProxyInfo {
    <#
    .SYNOPSIS
        Collects proxy configuration from registry.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .OUTPUTS
        Hashtable with proxy information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $proxyInfo = @{
        ProxyEnable = $null
        ProxyServer = $null
        ProxyOverride = $null
        AutoConfigURL = $null
    }

    try {
        if ($ComputerName) {
            # Remote registry access
            $proxySettings = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue
        }
        else {
            $proxySettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        }

        if ($proxySettings) {
            $proxyInfo.ProxyEnable = if ($proxySettings.ProxyEnable -eq 1) { 'Enabled' } else { 'Disabled' }
            $proxyInfo.ProxyServer = $proxySettings.ProxyServer
            $proxyInfo.ProxyOverride = $proxySettings.ProxyOverride
            $proxyInfo.AutoConfigURL = $proxySettings.AutoConfigURL
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect proxy info: $($_.Exception.Message)" -Component "Get-ProxyInfo" -Type 2
    }

    return $proxyInfo
}

function Get-SecurityInfo {
    <#
    .SYNOPSIS
        Collects security status information (BitLocker, Defender, Firewall).
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .OUTPUTS
        Hashtable with security information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $securityInfo = @{
        BitLockerVolumes = @()
        DefenderVersion = $null
        FirewallStatus = @{
            Domain = $null
            Private = $null
            Public = $null
        }
    }

    try {
        if ($ComputerName) {
            # Remote execution
            $remoteSecInfo = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                $result = @{
                    BitLocker = @()
                    Defender = $null
                    Firewall = @{}
                }

                # BitLocker
                try {
                    $blVolumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
                    foreach ($vol in $blVolumes) {
                        $result.BitLocker += @{
                            MountPoint = $vol.MountPoint
                            ProtectionStatus = $vol.ProtectionStatus
                            EncryptionPercentage = $vol.EncryptionPercentage
                        }
                    }
                }
                catch { }

                # Defender
                try {
                    $mpPref = Get-MpComputerStatus -ErrorAction SilentlyContinue
                    if ($mpPref) {
                        $result.Defender = $mpPref.AMProductVersion
                    }
                }
                catch { }

                # Firewall
                try {
                    $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
                    foreach ($profile in $fwProfiles) {
                        $result.Firewall[$profile.Name] = if ($profile.Enabled) { 'Enabled' } else { 'Disabled' }
                    }
                }
                catch { }

                return $result
            } -ErrorAction SilentlyContinue

            if ($remoteSecInfo) {
                $securityInfo.BitLockerVolumes = $remoteSecInfo.BitLocker
                $securityInfo.DefenderVersion = $remoteSecInfo.Defender
                $securityInfo.FirewallStatus = $remoteSecInfo.Firewall
            }
        }
        else {
            # Local execution
            try {
                $blVolumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
                foreach ($vol in $blVolumes) {
                    $securityInfo.BitLockerVolumes += @{
                        MountPoint = $vol.MountPoint
                        ProtectionStatus = $vol.ProtectionStatus.ToString()
                        EncryptionPercentage = $vol.EncryptionPercentage
                    }
                }
            }
            catch { }

            try {
                $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
                if ($mpStatus) {
                    $securityInfo.DefenderVersion = $mpStatus.AMProductVersion
                }
            }
            catch { }

            try {
                $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
                foreach ($profile in $fwProfiles) {
                    $securityInfo.FirewallStatus[$profile.Name] = if ($profile.Enabled) { 'Enabled' } else { 'Disabled' }
                }
            }
            catch { }
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect security info: $($_.Exception.Message)" -Component "Get-SecurityInfo" -Type 2
    }

    return $securityInfo
}

function Get-PowerInfo {
    <#
    .SYNOPSIS
        Collects power/battery and uptime information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .PARAMETER CimSession
        Optional CIM session for remote collection.
    .OUTPUTS
        Hashtable with power information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName,

        [Parameter()]
        [CimSession]$CimSession
    )

    $powerInfo = @{
        BatteryPresent = $null
        BatteryStatus = $null
        BatteryHealth = $null
        LastBootTime = $null
        Uptime = $null
    }

    try {
        # Get battery info
        if ($CimSession) {
            $battery = Get-CimInstance -CimSession $CimSession -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
            $os = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        elseif ($ComputerName) {
            $battery = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
            $os = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        else {
            $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        }

        if ($battery) {
            $powerInfo.BatteryPresent = 'Yes'
            $statusMap = @{ 1 = 'Discharging'; 2 = 'AC'; 3 = 'Fully Charged'; 4 = 'Low'; 5 = 'Critical'; 6 = 'Charging'; 7 = 'Charging High'; 8 = 'Charging Low'; 9 = 'Charging Critical'; 10 = 'Undefined'; 11 = 'Partially Charged' }
            $powerInfo.BatteryStatus = if ($statusMap.ContainsKey($battery.BatteryStatus)) { $statusMap[$battery.BatteryStatus] } else { "Unknown" }
            $powerInfo.BatteryHealth = if ($battery.EstimatedChargeRemaining) { "$($battery.EstimatedChargeRemaining)%" } else { 'N/A' }
        }
        else {
            $powerInfo.BatteryPresent = 'No (Desktop/Server)'
        }

        # Get uptime
        if ($os) {
            $powerInfo.LastBootTime = $os.LastBootUpTime
            $uptime = (Get-Date) - $os.LastBootUpTime
            $powerInfo.Uptime = "$($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes"
        }
    }
    catch {
        Write-DeviceDNALog -Message "Failed to collect power info: $($_.Exception.Message)" -Component "Get-PowerInfo" -Type 2
    }

    return $powerInfo
}

function Get-DeviceInfo {
    <#
    .SYNOPSIS
        Collects comprehensive device information.
    .PARAMETER ComputerName
        Optional computer name for remote collection.
    .OUTPUTS
        Hashtable with device information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ComputerName
    )

    $deviceInfo = @{
        Hostname       = $null
        FQDN           = $null
        OSName         = $null
        OSVersion      = $null
        OSBuild        = $null
        SerialNumber   = $null
        CurrentUser    = $null
        CollectionTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        ScriptVersion  = $script:Version
    }

    try {
        $isLocal = Test-IsLocalComputer -ComputerName $ComputerName

        if ($isLocal) {
            # Local collection - no WinRM overhead
            try {
                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop

                $deviceInfo.Hostname = $computerSystem.Name
                $deviceInfo.FQDN = "$($computerSystem.Name).$($computerSystem.Domain)"
                $deviceInfo.OSName = $operatingSystem.Caption
                $deviceInfo.OSVersion = $operatingSystem.Version
                $deviceInfo.OSBuild = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
                $deviceInfo.SerialNumber = $bios.SerialNumber
                $deviceInfo.CurrentUser = $computerSystem.UserName
            }
            catch {
                # Fallback to WMI
                try {
                    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
                    $operatingSystem = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
                    $bios = Get-WmiObject -Class Win32_BIOS -ErrorAction Stop

                    $deviceInfo.Hostname = $computerSystem.Name
                    $deviceInfo.FQDN = "$($computerSystem.Name).$($computerSystem.Domain)"
                    $deviceInfo.OSName = $operatingSystem.Caption
                    $deviceInfo.OSVersion = $operatingSystem.Version
                    $deviceInfo.OSBuild = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
                    $deviceInfo.SerialNumber = $bios.SerialNumber
                    $deviceInfo.CurrentUser = $computerSystem.UserName
                }
                catch {
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Device Info"; message = "Failed to collect device info locally: $($_.Exception.Message)" }
                }
            }
        }
        else {
            # Remote collection
            try {
                $cimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop

                $computerSystem = Get-CimInstance -CimSession $cimSession -ClassName Win32_ComputerSystem -ErrorAction Stop
                $operatingSystem = Get-CimInstance -CimSession $cimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
                $bios = Get-CimInstance -CimSession $cimSession -ClassName Win32_BIOS -ErrorAction Stop

                $deviceInfo.Hostname = $computerSystem.Name
                $deviceInfo.FQDN = "$($computerSystem.Name).$($computerSystem.Domain)"
                $deviceInfo.OSName = $operatingSystem.Caption
                $deviceInfo.OSVersion = $operatingSystem.Version
                $deviceInfo.SerialNumber = $bios.SerialNumber
                $deviceInfo.CurrentUser = $computerSystem.UserName

                # Get OS Build remotely
                $osBuild = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
                } -ErrorAction SilentlyContinue
                $deviceInfo.OSBuild = $osBuild

                Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
            }
            catch {
                # Fallback to WMI
                try {
                    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ComputerName -ErrorAction Stop
                    $operatingSystem = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
                    $bios = Get-WmiObject -Class Win32_BIOS -ComputerName $ComputerName -ErrorAction Stop

                    $deviceInfo.Hostname = $computerSystem.Name
                    $deviceInfo.FQDN = "$($computerSystem.Name).$($computerSystem.Domain)"
                    $deviceInfo.OSName = $operatingSystem.Caption
                    $deviceInfo.OSVersion = $operatingSystem.Version
                    $deviceInfo.SerialNumber = $bios.SerialNumber
                    $deviceInfo.CurrentUser = $computerSystem.UserName
                }
                catch {
                    $script:CollectionIssues += @{ severity = "Error"; phase = "Device Info"; message = "Failed to collect device info from $ComputerName : $($_.Exception.Message)" }
                }
            }
        }
    }
    catch {
        $script:CollectionIssues += @{ severity = "Error"; phase = "Device Info"; message = "Error in Get-DeviceInfo: $($_.Exception.Message)" }
    }

    # Collect enhanced inventory using helper functions
    try {
        Write-DeviceDNALog -Message "Collecting enhanced device inventory" -Component "Get-DeviceInfo" -Type 1

        # Determine CIM session for remote collection
        $cimSession = $null
        if (-not $isLocal -and $ComputerName) {
            try {
                $cimSession = New-CimSession -ComputerName $ComputerName -ErrorAction SilentlyContinue
            }
            catch {
                Write-DeviceDNALog -Message "Could not create CIM session for enhanced inventory: $($_.Exception.Message)" -Component "Get-DeviceInfo" -Type 2
            }
        }

        # Collect hardware information
        $deviceInfo.Processor = Get-ProcessorInfo -ComputerName $ComputerName -CimSession $cimSession
        $deviceInfo.Memory = Get-MemoryInfo -ComputerName $ComputerName -CimSession $cimSession
        $deviceInfo.Storage = Get-StorageInfo -ComputerName $ComputerName -CimSession $cimSession
        $deviceInfo.BIOS = Get-BiosInfo -ComputerName $ComputerName -CimSession $cimSession

        # Collect network information
        $deviceInfo.Network = Get-NetworkInfo -ComputerName $ComputerName -CimSession $cimSession
        $deviceInfo.Proxy = Get-ProxyInfo -ComputerName $ComputerName

        # Collect security information
        $deviceInfo.Security = Get-SecurityInfo -ComputerName $ComputerName

        # Collect power/uptime information
        $deviceInfo.Power = Get-PowerInfo -ComputerName $ComputerName -CimSession $cimSession

        # Cleanup CIM session
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }

        Write-DeviceDNALog -Message "Enhanced device inventory collection complete" -Component "Get-DeviceInfo" -Type 1
    }
    catch {
        Write-DeviceDNALog -Message "Error collecting enhanced inventory: $($_.Exception.Message)" -Component "Get-DeviceInfo" -Type 2
        $script:CollectionIssues += @{ severity = "Warning"; phase = "Device Info"; message = "Enhanced device inventory collection failed: $($_.Exception.Message)" }
    }

    return $deviceInfo
}
