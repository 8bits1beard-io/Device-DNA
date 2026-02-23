# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Device DNA collects Group Policy, Intune, and SCCM/ConfigMgr configuration data from Windows devices via PowerShell 5.1 and Microsoft Graph API, then generates a self-contained interactive HTML report. It runs on-device (or remotely via WinRM) and outputs per-device reports to `output/<DeviceName>/`.

## Critical Constraints

### PowerShell 5.1 Compatibility (MANDATORY)
This script targets Windows PowerShell 5.1 — NOT PowerShell 7+. These syntaxes will cause runtime errors:
- `??` (null coalescing) — use `if ($x) { $x } else { $default }`
- `? :` (ternary) — use `if/else`
- `?.` (null conditional member access) — use `if ($obj) { $obj.Prop }`
- `ConvertFrom-Json` breaks nested arrays in PS 5.1 — use CSV + `Import-Csv` for tabular data from Reports API

### Always Verify Microsoft Documentation
Never guess or assume Graph API endpoints, Intune behaviors, or Windows PowerShell features. Always research official Microsoft docs before implementing and cite sources in code comments.

## Architecture

### Entry Point and Module Loading
`DeviceDNA.ps1` dot-sources all modules in dependency order, then calls `Invoke-DeviceDNACollection` (in Orchestration.ps1). The load order matters:

1. **Core.ps1** — script-level variables (`$script:GraphConnected`, `$script:CollectionIssues`, etc.)
2. **Logging.ps1** — CMTrace-compatible log format
3. **Helpers.ps1** — `Write-StatusMessage`, `Test-AdminRights`, `Get-TenantId`
4. **Domain modules** (independent of each other): DeviceInfo.ps1, GroupPolicy.ps1, Intune.ps1, LocalIntune.ps1, SCCM.ps1, WindowsUpdate.ps1
5. **Supporting modules**: Reporting.ps1, Interactive.ps1, Runspace.ps1
6. **Orchestration.ps1** — depends on everything above

### Collection Pipeline (Orchestration.ps1)
Four phases:
- **Phase 0:** Setup — interactive params, admin check, device join type, tenant discovery, Graph auth
- **Phase 1:** Collection — GP (Track A), Intune (Track B), SCCM (Track C), Windows Update (Track D). Remote GP uses `Invoke-Command -AsJob` for parallelism with Intune; SCCM and Windows Update run after both complete. After Track D, SCCM override logic checks if ConfigMgr is managing updates and overrides WU source.
- **Phase 2:** Report generation — exports JSON data + HTML report
- **Phase 3:** Summary

### Graph API Pattern (Intune.ps1)
All Graph calls go through `Invoke-GraphRequest` which wraps `Invoke-MgGraphRequest` with:
- Auto-pagination via `@odata.nextLink`
- 429/5xx retry with exponential backoff (max 3 retries)
- Connection state validation against `$script:GraphConnected`

Two Reports API patterns are used:

**Async export jobs** (config profile per-device status, ADMX per-setting errors):
1. POST to create an export job at `/beta/deviceManagement/reports/exportJobs`
2. Poll with `Wait-ExportJobCompletion` (exponential backoff: 500ms → 4s cap)
3. Download CSV from the completed job's URL
4. Parse with `Import-Csv` (avoids PS 5.1 JSON array bugs)

**Synchronous POST** (compliance policy states):
1. POST to `/beta/deviceManagement/reports/getDevicePoliciesComplianceReport` with filter/select
2. Response contains inline JSON with Schema/Values arrays (no polling needed)

**Local registry** (app install status):
- `Get-LocalIntuneApplications` reads IME registry instead of Graph API (~50ms vs ~2-3min)
- See `docs/device-collection-methods.md` for details

### SCCM Collection (SCCM.ps1)
Client-side only — queries local WMI namespaces on the target device, no SMS Provider connection needed:
- `root\ccm` — client info (CCM_InstalledComponent, SMS_Authority, SMS_LookupMP)
- `root\ccm\ClientSDK` — deployed applications (CCM_Application) and software updates (CCM_SoftwareUpdate)
- `root\ccm\dcm` — compliance baselines (SMS_DesiredConfiguration)
- `root\ccm\Policy\Machine\ActualConfig` — client settings (8 dynamic policy classes)
- Registry: `HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client` for client ID

`Get-SCCMData` is the main aggregator. Returns `$null` if SCCM client not installed (detected via `root\ccm` namespace check).

### Windows Update Collection (WindowsUpdate.ps1)
Enhanced with management source detection logic that detects SCCM, Intune WUFB (Windows Update for Business), Intune ESUS (Endpoint Update Service), WSUS, or direct Windows Update. Detection priority: SCCM > ESUS > WUFB > WSUS > Direct. SCCM detection via `CCM_SoftwareUpdate` WMI overrides all other sources. ESUS detected via `*.mp.microsoft.com` endpoints, WUFB via deferral policy registry keys, WSUS via UseWUServer=1.

### Report Generation (Reporting.ps1)
`New-DeviceDNAReport` produces a single self-contained HTML file with embedded CSS, JavaScript, and data. The JS handles client-side rendering, filtering, sorting, theme toggle, and export (Markdown/CSV/JSON/Excel via SheetJS CDN with fallback). All sections collapsed by default except Overview tab. Windows Update Summary includes color-coded 'Managed By' badge (Blue=SCCM, Green=Intune WUFB/ESUS, Gray=WSUS/Direct).

### Standalone Viewer (DeviceDNA-Viewer.html)
A single self-contained HTML file (~7,400 lines) that renders any DeviceDNA JSON file via file picker or drag-and-drop. Embeds all CSS from Reporting.ps1 and all JS render functions inline — no external dependencies. Supports all 6 tabs, collapsible sections, expandable detail rows on config profiles, sorting, filtering, theme toggle, and export. See `docs/htmlviewer-implementation.md` for architecture details.

### Shared State
Modules communicate through `$script:` scoped variables defined in Core.ps1. Key ones:
- `$script:GraphConnected` — gates all Graph API calls
- `$script:CollectionIssues` — array of `@{ severity; phase; message }` hashtables accumulated across all modules
- `$script:GroupNameCache` — avoids redundant group name lookups

## Conventions

- **Functions:** Verb-Noun (`Get-DeviceInfo`, `Invoke-GraphRequest`)
- **Script variables:** `$script:PascalCase`
- **Logging:** `Write-DeviceDNALog -Message "..." -Component "FunctionName" -Type 1|2|3` (1=Info, 2=Warning, 3=Error)
- **User-facing output:** `Write-StatusMessage -Message "..." -Type Progress|Info|Success|Warning|Error`
- **Output files:** `DeviceDNA_<DeviceName>_<timestamp>.<ext>`
- **Module headers:** Synopsis/Description/Notes with Dependencies and Version

## Running the Script
```powershell
# Basic local collection (Windows PowerShell 5.1 only)
.\DeviceDNA.ps1

# Remote target with auto-open
.\DeviceDNA.ps1 -ComputerName "PC001" -AutoOpen

# Skip specific collections
.\DeviceDNA.ps1 -Skip GroupPolicy,IntuneApps

# Valid -Skip values: GroupPolicy, Intune, SCCM, WindowsUpdate,
#                     ConfigProfiles, ConfigProfileSettings, IntuneApps,
#                     CompliancePolicies, GroupMemberships, InstalledApps,
#                     SCCMApps, SCCMBaselines, SCCMUpdates, SCCMSettings
```

Requires `Microsoft.Graph.Authentication` module for Intune data. Device must be Azure AD or Hybrid joined for Graph API collection.
