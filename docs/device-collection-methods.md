# DeviceDNA Device Data Collection Methods

## Overview
Device data is collected via WMI/CIM queries, system utilities (`dsregcmd`, `powercfg`), and local registry reads. Remote targets use CIM sessions or WinRM (`Invoke-Command`). CIM is preferred with WMI as fallback. The main aggregator is `Get-DeviceInfo`.

---

## Device Join Type
| Item | Detail |
|------|--------|
| **Function** | `Get-DeviceJoinType` |
| **Command** | `dsregcmd /status` |
| **Method** | Parses output with regex for key/value pairs |
| **Extracted Data** | AzureAdJoined, DomainJoined, WorkplaceJoined, DeviceId, TenantId, TenantName |
| **Note** | Handles Hybrid AAD Joined (both AzureAdJoined and DomainJoined = YES) and variable whitespace in output |

## Processor
| Item | Detail |
|------|--------|
| **Function** | `Get-ProcessorInfo` |
| **WMI Class** | `Win32_Processor` |
| **Extracted Data** | Name, Manufacturer, Cores, LogicalProcessors, MaxClockSpeed, Architecture |
| **Note** | Architecture code translation (0=x86, 9=x64, 12=ARM64) |

## Memory
| Item | Detail |
|------|--------|
| **Function** | `Get-MemoryInfo` |
| **WMI Classes** | `Win32_OperatingSystem` (total/available) + `Win32_PhysicalMemory` (per-module) |
| **Extracted Data** | TotalPhysicalMemory, AvailableMemory, per-module Capacity/Speed/Manufacturer/PartNumber |

## Storage
| Item | Detail |
|------|--------|
| **Function** | `Get-StorageInfo` |
| **WMI Class** | `Win32_DiskDrive` |
| **Extracted Data** | Model, Size, InterfaceType, MediaType, Status (all disks) |

## BIOS / Firmware
| Item | Detail |
|------|--------|
| **Function** | `Get-BiosInfo` |
| **WMI Class** | `Win32_BIOS` + `Win32_Tpm` (namespace `root\cimv2\Security\MicrosoftTpm`) |
| **Registry** | `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State` |
| **Extracted Data** | Manufacturer, Version, SMBIOSVersion, ReleaseDate, UEFIMode, SecureBoot, TPMPresent/Version/Enabled |
| **Note** | UEFI/SecureBoot detection is local-only (returns N/A for remote targets) |

## Network
| Item | Detail |
|------|--------|
| **Function** | `Get-NetworkInfo` |
| **WMI Class** | `Win32_NetworkAdapterConfiguration` (filter: `IPEnabled=True`) |
| **Extracted Data** | Description, MACAddress, IPAddress (IPv4/IPv6), SubnetMask, DefaultGateway, DHCPEnabled/Server, DNSServers, DNSDomain |

## Proxy
| Item | Detail |
|------|--------|
| **Function** | `Get-ProxyInfo` |
| **Registry Path** | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings` |
| **Extracted Data** | ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL |

## Security
| Item | Detail |
|------|--------|
| **Function** | `Get-SecurityInfo` |
| **Sources** | `Get-BitLockerVolume`, `Get-MpComputerStatus`, `Get-NetFirewallProfile` |
| **Extracted Data** | BitLocker volumes (MountPoint, ProtectionStatus, EncryptionPercentage), Defender version, Firewall status (Domain/Private/Public) |

## Power / Uptime
| Item | Detail |
|------|--------|
| **Function** | `Get-PowerInfo` |
| **WMI Classes** | `Win32_Battery` + `Win32_OperatingSystem` |
| **Extracted Data** | BatteryPresent, BatteryStatus, BatteryHealth (charge %), LastBootTime, Uptime |

## Installed Applications
| Item | Detail |
|------|--------|
| **Function** | `Get-InstalledApplications` (GroupPolicy.ps1) |
| **Registry Paths** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` |
| | `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall` |
| | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` |
| **Modern Apps** | `Get-AppxPackage -AllUsers` (fallback: without `-AllUsers`) |
| **Deduplication** | Key: `DisplayName\|DisplayVersion` — skips duplicates across registry hives |
| **Filtering** | Skips entries without DisplayName; skips SystemComponent=1 (unless Microsoft) |
| **Extracted Data** | DisplayName, Version, Publisher, InstallDate, Architecture (x86/x64), Source (Registry/AppxPackage) |

---

## Local Intune Data (collected from device, Intune-related)

These functions collect Intune/MDM data from the local device perspective rather than Graph API. For Graph API-based Intune collection, see [intune-collection-methods.md](intune-collection-methods.md).

### Win32 App Install Status
| Item | Detail |
|------|--------|
| **Function** | `Get-LocalIntuneApplications` (LocalIntune.ps1) |
| **Registry Path** | `HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps` |
| **Method** | Reads SID folders (S-1-5-18 / 00000000-... = Device, Azure AD OID = User), parses ComplianceStateMessage + EnforcementStateMessage JSON properties |
| **State Storage** | Two patterns observed: (a) direct JSON properties on app key, (b) sub-subkeys containing the same property name — both are tried |
| **GUID Handling** | Strips `_N` suffix for deduplication, validates GUID format, prefers device context over user context |
| **Mapping** | EnforcementState: 1000=Installed, 2000-2999=Pending, 3000-3999=NotApplicable, 4000+=Failed |
| | ComplianceState (fallback): 1=Installed, 2=Not Installed, 3/4=Failed, 5=Unknown |
| **Output** | Hashtable keyed by clean app GUID for O(1) lookup |
| **Timing** | ~50ms |
| **Limitation** | Win32 apps only — non-Win32 show "Unknown" |

### MDM Diagnostic Report
| Item | Detail |
|------|--------|
| **Function** | `Get-MdmDiagnosticReport` (LocalIntune.ps1) |
| **Command** | `mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;Autopilot -zip {tempfile}` |
| **Method** | Runs diagnostic tool → extracts ZIP → parses `MDMDiagReport.xml` |
| **Timeout** | 30 seconds |
| **Extracted Data** | EnrollmentInfo (state, server URL, DeviceID, AADDeviceID, UPN), applied Policies, Certificates |
| **Cleanup** | Removes temp ZIP and extraction folder in `finally` block |

### MDM Configuration (PolicyManager)
| Item | Detail |
|------|--------|
| **Function** | `Get-LocalMdmConfiguration` (LocalIntune.ps1) |
| **WMI Namespace** | `root\cimv2\mdm\dmmap` — queries all `MDM_Policy_*` classes |
| **Registry Paths** | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device` (device policies) |
| | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\user` (user policies) |
| **Extracted Data** | WMI policy instances with properties, device policy registry values, user policy registry values |

### Local Compliance State
| Item | Detail |
|------|--------|
| **Function** | `Get-LocalComplianceState` (LocalIntune.ps1) |
| **Registry Path** | `HKLM:\SOFTWARE\Microsoft\Enrollments` |
| **Event Log** | `Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin` (last 24h, optional) |
| **Extracted Data** | Per-enrollment: GUID, DiscoveryServiceURL, AADDeviceID, UPN, EnrollmentState/Type, LastSuccessfulSync, ComplianceState |

---

## Collection Flow (`Get-DeviceInfo`)

1. **Basic info** — `Win32_ComputerSystem` + `Win32_OperatingSystem` + `Win32_BIOS` (CIM first, WMI fallback)
2. **OS Build** — Registry `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` → `DisplayVersion`
3. **Enhanced inventory** — calls all sub-functions: Processor, Memory, Storage, BIOS, Network, Proxy, Security, Power
4. **Remote targets** — creates a CIM session once, passes to all sub-functions, cleans up at the end
