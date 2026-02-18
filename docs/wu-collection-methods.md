# DeviceDNA Windows Update Data Collection Methods

## Overview
Windows Update data is collected from **registry hives**, the **Windows Update Agent (WUA) COM API**, and **reboot indicator keys** on the target device. No external service connections are made — all data is read locally (or via WinRM for remote targets).

The entry point is `Get-WindowsUpdateData` in `modules/WindowsUpdate.ps1`, which reads 10 registry hives, checks reboot status, queries WUA COM objects, and determines the update management source.

---

## Update Source Detection
After all data is collected, DeviceDNA determines which management layer controls Windows Update. Detection uses a priority hierarchy — the first match wins.

| Priority | Source | Detection Method |
|----------|--------|-----------------|
| 1 (highest) | **SCCM** | `CCM_SoftwareUpdate` WMI class returns ≥1 update (override in `Orchestration.ps1`) |
| 2 | **Intune ESUS** | `UseWUServer=1` AND `WUServer` matches `*.mp.microsoft.com` or `eus.wu.manage.microsoft.com` |
| 3 | **Intune WUFB** | Deferral policies present (`DeferFeatureUpdates`, `DeferQualityUpdates`, `BranchReadinessLevel`, etc.) without WSUS |
| 4 | **WSUS** | `UseWUServer=1` with traditional on-prem server URL |
| 5 (lowest) | **Windows Update (direct)** | Default when no management layer detected |

### SCCM Override (Orchestration.ps1)
SCCM detection happens **after** all collection tracks complete. If `collectionData.sccm.softwareUpdates` contains any entries, the `summary.updateSource` and `summary.updateManagement` fields are overwritten to `"Configuration Manager (SCCM)"` and `"SCCM"` respectively. This overrides any WUFB/WSUS/ESUS detection from the registry.

### Co-Management
If both WUFB deferral policies and a WSUS/ESUS endpoint are detected, the `updateManagement` field reflects both (e.g., `"WSUS + WUFB"` or `"Intune (ESUS) + WUFB"`).

---

## Registry Hives
All registry reads go through `Read-WURegistryHive`, which:
1. Reads all values from the registry path
2. Matches each value against a `KnownKeys` dictionary (type, meaning, description)
3. Decodes values into human-readable strings via `Get-WUDecodedValue`
4. Flags unknown keys (values not in the dictionary) unless `IgnoreExtra = $true`

### Hive 1: WindowsUpdate Policy
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` |
| **Source** | GPO / MDM (Intune) |
| **Reference** | [Configure Windows Update for Business](https://learn.microsoft.com/windows/deployment/update/waas-configure-wufb), [Update CSP](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-update) |
| **Key settings** | `WUServer`, `WUStatusServer`, `DeferFeatureUpdatesPeriodinDays`, `DeferQualityUpdatesPeriodinDays`, `BranchReadinessLevel`, `ActiveHoursStart/End`, `ExcludeWUDriversInQualityUpdate`, `AllowOptionalContent`, `TargetGroup` |

### Hive 2: Automatic Updates (AU)
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` |
| **Source** | GPO / MDM |
| **Reference** | [Windows Update settings](https://learn.microsoft.com/windows/deployment/update/waas-wu-settings), [Configure WSUS Group Policy](https://learn.microsoft.com/windows-server/administration/windows-server-update-services/deploy/4-configure-group-policy-settings-for-automatic-updates) |
| **Key settings** | `UseWUServer`, `AUOptions` (2=Notify, 3=Auto DL, 4=Schedule, 5=Local admin), `NoAutoUpdate`, `ScheduledInstallDay/Time`, `NoAutoRebootWithLoggedOnUsers` |

### Hive 3: Update Policy State
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings` |
| **Source** | Runtime (WU agent writes these, not admin-configurable) |
| **Key settings** | `PausedFeatureDate`, `PausedFeatureStatus` (0=Not paused, 1=Paused, 2=Auto-resumed), `PausedQualityDate`, `PausedQualityStatus` |

### Hive 4: UX Settings (User Preferences)
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` |
| **Source** | User via Settings app / WU orchestrator |
| **Reference** | [Device activity policies](https://learn.microsoft.com/windows/deployment/update/update-policies#device-activity-policies) |
| **Key settings** | `IsContinuousInnovationOptedIn`, `AllowMUUpdateService`, `SmartActiveHoursStart/End`, `ActiveHoursStart/End`, `PendingRebootStartTime` |

### Hive 5: Auto Update Runtime
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update` |
| **Source** | Runtime (WU agent state) |
| **Key settings** | `RebootRequired` (key presence = reboot pending), `LastOnline`, `AcceleratedInstallRequired` |

### Hive 6: Last Scan Result
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\...\WindowsUpdate\Auto Update\Results\Detect` |
| **Key settings** | `LastSuccessTime`, `LastError` (HRESULT) |

### Hive 7: Last Install Result
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\...\WindowsUpdate\Auto Update\Results\Install` |
| **Key settings** | `LastSuccessTime`, `LastError` (HRESULT) |

### Hive 8: Last Download Result
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\...\WindowsUpdate\Auto Update\Results\Download` |
| **Key settings** | `LastSuccessTime`, `LastError` (HRESULT) |

### Hive 9: OS Version
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` |
| **IgnoreExtra** | `$true` (only known keys are reported; other values silently skipped) |
| **Key settings** | `CurrentBuild`, `UBR` (patch level), `DisplayVersion` (e.g., 24H2), `EditionID`, `ProductName`, `InstallDate` (Unix epoch) |
| **Note** | OS build displayed as `CurrentBuild.UBR` (e.g., `26100.7623`) |

### Hive 10: Delivery Optimization
| Item | Detail |
|------|--------|
| **Path** | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization` |
| **Source** | GPO / MDM |
| **Reference** | [Delivery Optimization CSP](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-deliveryoptimization) |
| **Key settings** | `DODownloadMode` (0=HTTP, 1=LAN, 2=Group, 3=Internet, 99=Simple, 100=Bypass), `DOGroupId`, `DOGroupIdSource`, `DOMaxCacheSize`, `DOCacheHost` |

---

## WUA COM API
`Get-WUAUpdateStatus` queries two COM objects on the target device.

### Service State
| Item | Detail |
|------|--------|
| **Method** | `Get-Service -Name wuauserv` |
| **Returns** | `ServiceStatus` (Running/Stopped/etc.), `ServiceStartType` (Automatic/Manual/Disabled) |

### AutomaticUpdates Results
| Item | Detail |
|------|--------|
| **COM Object** | `Microsoft.Update.AutoUpdate` |
| **Reference** | [IAutomaticUpdatesResults](https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iautomaticupdatesresults) |
| **Returns** | `LastSearchSuccessDate`, `LastInstallationSuccessDate` |
| **Note** | Preferred over registry timestamps; registry is used as fallback |

### Pending Updates
| Item | Detail |
|------|--------|
| **COM Object** | `Microsoft.Update.Session` → `CreateUpdateSearcher()` |
| **Search criteria** | `"IsInstalled=0 AND IsHidden=0"` |
| **Reference** | [IUpdateSearcher](https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatesearcher) |
| **Fields** | Title, KBArticleIDs, IsDownloaded, IsMandatory, MsrcSeverity |

### Install History
| Item | Detail |
|------|--------|
| **Method** | `QueryHistory(0, 50)` (last 50 entries) |
| **Reference** | [IUpdateHistoryEntry](https://learn.microsoft.com/windows/win32/api/wuapi/nn-wuapi-iupdatehistoryentry) |
| **Fields** | Title, Date, Operation, Result, HResult |

#### Operation Codes
| Code | Meaning |
|------|---------|
| 1 | Install |
| 2 | Uninstall |

#### Result Codes (OperationResultCode)
| Code | Meaning |
|------|---------|
| 0 | Not Started |
| 1 | In Progress |
| 2 | Succeeded |
| 3 | Succeeded with Errors |
| 4 | Failed |
| 5 | Aborted |

---

## Reboot Detection
`Test-WURebootRequired` checks three indicators for pending reboot:

| Indicator | Method |
|-----------|--------|
| WU reboot key | `Test-Path HKLM:\...\WindowsUpdate\Auto Update\RebootRequired` |
| CBS reboot key | `Test-Path HKLM:\...\Component Based Servicing\RebootPending` |
| File rename ops | `PendingFileRenameOperations` property in `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` |

Returns `RebootPending` (bool) and `Indicators` (array of which checks triggered).

---

## Remote Execution Pattern
Same pattern as all DeviceDNA modules:
1. Define a `$scriptBlock` with the queries
2. If local: `& $scriptBlock` (direct invocation)
3. If remote: `Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock`

Registry reads and WUA COM queries both run on the target device.

## Error Handling
- Each function wraps its work in try/catch
- WUA COM failures are logged to `$script:CollectionIssues` with `phase = "WindowsUpdate"`
- Registry hive read failures are recorded in the hive result's `Error` field
- Individual hive failures don't block other hive reads or WUA queries

## Output Structure
`Get-WindowsUpdateData` returns a hashtable:
```
@{
    summary              = @{  # Key metrics for the report overview
        updateSource         # Detected source string (e.g., "WSUS: http://...", "Windows Update for Business (WUFB)")
        updateManagement     # Management label (e.g., "SCCM", "Intune (WUFB)", "None")
        osBuild              # "CurrentBuild.UBR" (e.g., "26100.7623")
        osVersion            # DisplayVersion (e.g., "24H2")
        osEdition            # EditionID (e.g., "Enterprise")
        lastScanTime         # Best available scan timestamp (COM > registry)
        lastInstallTime      # Best available install timestamp (COM > registry)
        rebootPending        # $true/$false
        rebootIndicators     # Array of triggered indicator paths
        serviceState         # WU service status
        serviceStartType     # WU service start type
        pendingCount         # Number of pending updates
        historyCount         # Total history entries
    }
    registryPolicy       = @{} # Flat map: "HiveName|KeyName" → { Hive, Setting, Value, Decoded, ... }
    pendingUpdates       = @() # Array of pending update hashtables from WUA
    updateHistory        = @() # Array of history entry hashtables from WUA (last 50)
    deliveryOptimization = @{} # DO policy settings from registry
    duration             = ""  # Collection time as "hh:mm:ss"
}
```
