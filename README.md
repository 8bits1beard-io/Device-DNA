# Device DNA

Device DNA collects Group Policy, Microsoft Intune, and SCCM/ConfigMgr configuration data from Windows devices and generates a self-contained interactive HTML report. It runs locally or remotely via WinRM and targets Windows PowerShell 5.1.

## Prerequisites

- **Windows PowerShell 5.1** (built into Windows 10/11). PowerShell 7+ is not supported.
- **Administrator privileges** recommended (some data is unavailable without elevation).
- **Microsoft.Graph.Authentication** PowerShell module required for Intune data collection:
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- **Azure AD or Hybrid Azure AD joined** device required for Graph API collection. Workgroup-only devices can still collect Group Policy and device inventory.
- **WinRM** enabled on remote targets (for `-ComputerName` usage).

### Required Graph API Permissions

When prompted to authenticate, the following scopes are requested:

| Scope | Purpose |
|-------|---------|
| `DeviceManagementConfiguration.Read.All` | Configuration profiles, compliance policies |
| `DeviceManagementManagedDevices.Read.All` | Managed device lookup, health script states |
| `DeviceManagementApps.Read.All` | Applications, app install status |
| `Directory.Read.All` | Device group memberships, group name resolution |
| `Device.Read.All` | Azure AD device discovery |

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/8bits1beard-io/Device-DNA.git
cd Device-DNA
```

### Run the Script

```powershell
# Basic local collection
.\DeviceDNA.ps1

# Remote target
.\DeviceDNA.ps1 -ComputerName "PC001"

# Auto-open report in browser when complete
.\DeviceDNA.ps1 -AutoOpen

# Skip GP refresh before collection
.\DeviceDNA.ps1 -SkipGPUpdate

# Skip specific collection categories
.\DeviceDNA.ps1 -Skip GroupPolicy,IntuneApps

# Custom output directory
.\DeviceDNA.ps1 -OutputPath "C:\Reports"

# Combined
.\DeviceDNA.ps1 -ComputerName "PC001" -AutoOpen -SkipGPUpdate -Skip CompliancePolicies
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | String | localhost | Target computer name. Uses WinRM for remote targets. |
| `-OutputPath` | String | Current directory | Base directory for output. Reports are written to `<OutputPath>/output/<DeviceName>/`. |
| `-AutoOpen` | Switch | Off | Open the HTML report in the default browser after generation. |
| `-SkipGPUpdate` | Switch | Off | Skip running `gpupdate /force` before Group Policy collection. |
| `-Skip` | String[] | Empty | Skip one or more collection categories (see below). |

### Skip Values

| Value | What It Skips |
|-------|---------------|
| `GroupPolicy` | All Group Policy collection (gpresult, installed apps) |
| `Intune` | All Intune collection (Graph API + local registry) |
| `ConfigProfiles` | Configuration profiles only |
| `IntuneApps` | Intune applications and install status only |
| `CompliancePolicies` | Compliance policies only |
| `GroupMemberships` | Device group memberships only |
| `InstalledApps` | Installed applications inventory only |
| `SCCM` | All SCCM/ConfigMgr collection |
| `SCCMApps` | SCCM deployed applications only |
| `SCCMBaselines` | SCCM compliance baselines only |
| `SCCMUpdates` | SCCM software updates only |
| `SCCMSettings` | SCCM client settings only |

## What Data Is Collected

### Group Policy (source: `gpresult.exe`)
- Applied, denied, and filtered GPOs (computer and user scope)
- Per-GPO settings, link location, security filter, WMI filter
- GP metadata: domain, site name, domain controller, slow link status
- Optional `gpupdate /force` before collection

### Intune Configuration Profiles (source: Microsoft Graph API)
- Device Configurations (`/beta/deviceManagement/deviceConfigurations`)
- Settings Catalog policies (`/beta/deviceManagement/configurationPolicies`)
- Administrative Templates (`/beta/deviceManagement/groupPolicyConfigurations`)
- Endpoint Security Intents (`/beta/deviceManagement/intents`)
- Per-device deployment status via Reports API async export job
- Per-setting error details for failed profiles via ADMX Reports API

### Intune Applications (source: Graph API + local registry)
- Application list with assignments (`/beta/deviceAppManagement/mobileApps`)
- Install status from local IME registry (`HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps`)
- Win32 app states mapped from EnforcementState/ComplianceState codes
- Non-Win32 apps (Store, web links) show "Unknown" install status (expected)

### Intune Compliance Policies (source: Graph API)
- Policy definitions with assignments (`/beta/deviceManagement/deviceCompliancePolicies`)
- Per-device compliance state via synchronous Reports API POST (`getDevicePoliciesComplianceReport`)

### Proactive Remediations (source: Graph API)
- Script definitions with assignments (`/beta/deviceManagement/deviceHealthScripts`)
- Per-device run states: detection state, remediation state, last run time (`/beta/.../deviceHealthScriptStates`)

### Device Group Memberships (source: Graph API)
- Transitive group memberships (`/v1.0/devices/{id}/transitiveMemberOf`)
- Group type (Assigned/Dynamic) and membership rules

### Device Inventory (source: WMI/CIM, registry, system utilities)
- OS, hostname, serial number, current user
- Processor, memory, storage, BIOS/TPM
- Network adapters, proxy configuration
- Security status (BitLocker, Defender, Firewall)
- Battery/power and uptime
- Device join type via `dsregcmd /status`

### SCCM/ConfigMgr (source: local WMI — no server connection needed)
- Client info: version, site code, management point, client ID
- Deployed applications via `CCM_Application` (`root\ccm\ClientSDK`)
- Compliance baselines via `SMS_DesiredConfiguration` (`root\ccm\dcm`)
- Software updates via `CCM_SoftwareUpdate` (`root\ccm\ClientSDK`)
- Client settings from 8 policy classes in `root\ccm\Policy\Machine\ActualConfig`
- SCCM client auto-detected; sections hidden in report if client not installed

### Installed Applications (source: registry + AppX)
- Registry: `HKLM:\...\Uninstall`, `WOW6432Node`, `HKCU:\...\Uninstall`
- Modern apps via `Get-AppxPackage`

### Windows Update (source: registry + WUA COM API)
- Configuration registry hives (10 sources): UseWUServer, DeferQualityUpdates, DeferFeatureUpdates, and more
- WUA COM API: pending updates, update history, service state, last scan time
- Windows Update management source detection (SCCM, Intune WUFB, Intune ESUS, WSUS, or direct)
- Priority-based detection: SCCM takes precedence, followed by ESUS, WUFB, WSUS, then direct Windows Update

## Output

All output is written to `<OutputPath>/output/<DeviceName>/`:

| File | Description |
|------|-------------|
| `DeviceDNA_<DeviceName>_<timestamp>.html` | Self-contained interactive HTML report |
| `DeviceDNA_<DeviceName>_<timestamp>.json` | Raw collected data in JSON format |
| `DeviceDNA_<DeviceName>_<timestamp>.log` | CMTrace-compatible log file |

### HTML Report Features
- Collapsible sections for each data category (all sections collapsed by default except Overview tab for easier navigation)
- Windows Update section shows management source with color-coded 'Managed By' badge (Blue=SCCM, Green=Intune, Gray=WSUS/Direct)
- Client-side search, filtering, and sorting
- Status badges with color coding (success/warning/error)
- Dark/light theme toggle
- Export to Markdown, CSV, JSON, and Excel (via SheetJS)

### Log File

Logs are written in CMTrace/OneTrace compatible format and can be opened with either tool for filtered, color-coded viewing. The log includes timestamped entries for every API call, collection step, and error encountered during the run.

Log levels: **Info** (1), **Warning** (2), **Error** (3).

## Collection Flow

1. **Setup** — Interactive parameters, admin check, device join type detection, tenant discovery, Graph API authentication
2. **Collection** — Group Policy (Track A), Intune (Track B), SCCM (Track C), Windows Update (Track D). Remote GP uses `Invoke-Command -AsJob` for parallelism with Intune; SCCM and Windows Update run after both complete.
3. **Report Generation** — Exports JSON data file and generates HTML report
4. **Summary** — Prints collection statistics, optionally opens report in browser

## Project Structure

```
DeviceDNA.ps1          # Entry point
DeviceDNALogo_1.png    # Project logo (354KB)
DeviceDNALogo_2.png    # Project logo (144KB)
modules/
  Core.ps1              # Shared script-level variables
  Logging.ps1           # CMTrace-compatible logging
  Helpers.ps1           # Utility functions
  DeviceInfo.ps1        # Hardware/OS inventory (WMI + registry)
  GroupPolicy.ps1       # Group Policy collection (gpresult + registry)
  Intune.ps1            # Graph API collection (all Intune data)
  LocalIntune.ps1       # Device-side Intune data (registry + MDM diagnostics)
  SCCM.ps1              # SCCM/ConfigMgr client-side collection (WMI)
  WindowsUpdate.ps1     # Windows Update config and management source detection
  Reporting.ps1         # HTML report generation
  Interactive.ps1       # Console prompts
  Orchestration.ps1     # Main workflow coordinator
docs/
  intune-collection-methods.md    # Detailed Intune API reference
  gp-collection-methods.md        # Group Policy collection reference
  device-collection-methods.md    # Device inventory + local Intune reference
  sccm-collection-methods.md      # SCCM/ConfigMgr WMI collection reference
tests/
  *.Tests.ps1           # Pester unit tests
  Test-*.ps1            # Standalone integration tests
  Test-TableAlignment.html        # CSS alignment demonstration
output/                 # Runtime output (per-device subfolders)
```
