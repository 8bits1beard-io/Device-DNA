# DeviceDNA SCCM/ConfigMgr Data Collection Methods

## Overview
All SCCM data is collected **client-side only** via local WMI queries on the target device. No SMS Provider (site server) connection is needed. If the SCCM client is not installed, the entire SCCM section is skipped gracefully.

The entry point is `Get-SCCMData` in `modules/SCCM.ps1`, which calls individual collection functions and respects the `-Skip` parameter for granular control.

---

## SCCM Client Detection
| Item | Detail |
|------|--------|
| **Function** | `Test-SCCMClient` |
| **Method** | `Get-CimInstance -Namespace 'root' -ClassName __Namespace -Filter "Name='ccm'"` |
| **Returns** | `$true` if `root\ccm` namespace exists, `$false` otherwise |
| **Note** | If client not detected, `Get-SCCMData` returns `$null` and all SCCM report sections are hidden |

## Client Info
| Item | Detail |
|------|--------|
| **Function** | `Get-SCCMClientInfo` |
| **WMI Queries** | |
| Client Version | `Get-CimInstance -Namespace 'root\ccm' -ClassName CCM_InstalledComponent -Filter "Name='CcmFramework'"` → `.Version` |
| Site Code | `Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_Authority` → `.Name` (strip `SMS:` prefix) |
| Management Point | `Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_LookupMP` → `.Name` |
| Client ID | Registry: `HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client` → `SMS Unique Identifier` |
| **Skip Value** | Always collected when SCCM client is detected (no individual skip) |

## Deployed Applications
| Item | Detail |
|------|--------|
| **Function** | `Get-SCCMApplications` |
| **WMI Class** | `CCM_Application` in `root\ccm\ClientSDK` |
| **Reference** | [CCM_Application Client WMI Class](https://learn.microsoft.com/mem/configmgr/develop/reference/core/clients/sdk/ccm_application-client-wmi-class) |
| **Fields** | Name, Publisher, SoftwareVersion, InstallState, ApplicabilityState, EvaluationState, ResolvedState, IsMachineTarget, EnforcePreference, Deadline, LastEvalTime, ErrorCode, PercentComplete |
| **Skip Value** | `SCCMApps` |

### EvaluationState Mapping
Both applications and software updates use the same numeric evaluation state codes:

| Code | State | Description |
|------|-------|-------------|
| 0 | None | No evaluation state |
| 1 | Available | Content is available |
| 2 | Submitted | Submitted for evaluation |
| 3 | Detecting | Detection in progress |
| 4 | PreDownload | Pre-download phase |
| 5 | Downloading | Downloading content |
| 6 | WaitInstall | Waiting to install |
| 7 | Installing | Installation in progress |
| 8 | PendingSoftReboot | Pending soft reboot |
| 9 | PendingHardReboot | Pending hard reboot |
| 10 | WaitReboot | Waiting for reboot |
| 11 | Verifying | Verifying installation |
| 12 | InstallComplete | Installation complete |
| 13 | Error | Error occurred |
| 14 | WaitServiceWindow | Waiting for maintenance window |
| 15 | WaitUserLogon | Waiting for user logon |
| 16 | WaitUserLogoff | Waiting for user logoff |
| 17 | WaitJobUserLogon | Waiting for job user logon |
| 18 | WaitUserReconnect | Waiting for user reconnect |
| 19 | PendingUserLogoff | Pending user logoff |
| 20 | PendingUpdate | Pending update |
| 21 | WaitingRetry | Waiting to retry |
| 22 | WaitPresModeOff | Waiting for presentation mode off |
| 23 | WaitForOrchestration | Waiting for orchestration |

## Compliance Baselines
| Item | Detail |
|------|--------|
| **Function** | `Get-SCCMComplianceBaselines` |
| **WMI Class** | `SMS_DesiredConfiguration` in `root\ccm\dcm` |
| **Note** | Not officially documented in ConfigMgr SDK but well-established in community usage |
| **Fields** | DisplayName/Name, Version, LastComplianceStatus, LastEvalTime, IsMachineTarget |
| **Skip Value** | `SCCMBaselines` |

### LastComplianceStatus Mapping
| Code | State |
|------|-------|
| 0 | Non-Compliant |
| 1 | Compliant |
| 2 | Not Applicable |
| 3 | Unknown |
| 4 | Error |

## Software Updates
| Item | Detail |
|------|--------|
| **Function** | `Get-SCCMSoftwareUpdates` |
| **WMI Class** | `CCM_SoftwareUpdate` in `root\ccm\ClientSDK` |
| **Reference** | [CCM_SoftwareUpdate Client WMI Class](https://learn.microsoft.com/mem/configmgr/develop/reference/core/clients/sdk/ccm_softwareupdate-client-wmi-class) |
| **Fields** | ArticleID, Name, BulletinID, ComplianceState (0=Required), EvaluationState, PercentComplete, Deadline, Publisher, ErrorCode |
| **Skip Value** | `SCCMUpdates` |

## Client Settings (Policy Classes)
| Item | Detail |
|------|--------|
| **Function** | `Get-SCCMClientSettings` |
| **WMI Namespace** | `root\ccm\Policy\Machine\ActualConfig` |
| **Method** | Properties read dynamically via `CimInstanceProperties` iteration; CIM metadata (`CIM*`, `__*`, `Reserved`, `SiteSettingsKey`) is filtered out |
| **Skip Value** | `SCCMSettings` |

### Policy Classes Queried
| WMI Class | Display Category |
|-----------|-----------------|
| `CCM_ClientAgentConfig` | Client Agent |
| `CCM_SoftwareUpdatesClientConfig` | Software Updates |
| `CCM_ApplicationManagementClientConfig` | Application Management |
| `CCM_ComplianceEvaluationClientConfig` | Compliance Settings |
| `CCM_HardwareInventoryClientConfig` | Hardware Inventory |
| `CCM_SoftwareInventoryClientConfig` | Software Inventory |
| `CCM_RemoteToolsConfig` | Remote Tools |
| `CCM_EndpointProtectionClientConfig` | Endpoint Protection |

**Note:** These classes are dynamically generated by the ConfigMgr client and are not individually documented in the official SDK. Their properties vary by ConfigMgr version and site configuration.

---

## Remote Execution Pattern
All functions follow the same local/remote pattern used by other DeviceDNA modules:
1. Define a `$scriptBlock` with the WMI queries
2. If local: `& $scriptBlock` (direct invocation)
3. If remote: `Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock`

This keeps WMI queries running on the target device regardless of where DeviceDNA is executed from.

## Error Handling
- Each function wraps its WMI queries in try/catch
- Failures are logged to `$script:CollectionIssues` with `phase = "SCCM"`
- Individual sub-collection failures (e.g., baselines fail) don't block other collections
- Client settings categories that fail are silently skipped (non-fatal)
