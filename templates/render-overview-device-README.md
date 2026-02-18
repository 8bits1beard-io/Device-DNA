# Overview & Device Tab Render Functions

This document describes the JavaScript render functions for the **Overview** and **Device** tabs in the DeviceDNA HTML report template.

## File Location

`templates/render-overview-device.js`

## Dependencies

- **Global Data Object**: `policyData` (parsed from embedded JSON in the HTML report)
- **Utility Functions**: `escapeHtml()` (for XSS protection)
- **Existing Functions**: `renderDeviceOverviewDashboard()`, `renderIssueSummary()`, `buildIssueSummary()`, `calculateComprehensiveMetrics()` (already in main JS)

## Overview Tab Functions

### 1. `renderExecutiveDashboard(data)`

**Status**: ✅ ALREADY IMPLEMENTED (as `renderDeviceOverviewDashboard()` in main JS)

Renders the executive summary dashboard at the top of the Overview tab.

#### Populated Container
- `#executive-dashboard-container`

#### Sections Rendered
1. **Device Identity**
   - Hostname
   - Operating System (name, version, build)
   - Serial Number
   - Join Type
   - Management Type
   - Tenant ID
   - Last Intune Sync
   - Collection Time

2. **Health & Status Cards**
   - Overall Health (good/warning/critical)
   - Compliance Status (compliant/non-compliant)
   - Collection Issues Count
   - Updates Pending (with management source)

3. **Configuration Summary**
   - Group Policy (total, errors, warnings, success)
   - Intune Profiles
   - Applications (combined Intune + SCCM)
   - Compliance Policies
   - SCCM Baselines
   - Windows Update

#### Features
- Color-coded health cards (green=success, yellow=warning, red=error)
- Clickable config rows that switch to respective tabs
- Counts calculated from DOM via `calculateComprehensiveMetrics()`
- Empty rows hidden if no data

#### CSS Classes Used
```css
.device-overview-dashboard
.dashboard-section
.device-identity
.identity-grid
.identity-item
.health-status
.health-grid
.health-card (with .status-success, .status-warning, .status-error)
.config-summary
.config-list
.config-row (clickable, with onclick="switchTab()")
.stat-badge (.error, .warning, .success)
```

---

### 2. `renderIssueSummaryPanel(data)`

**Status**: ✅ ALREADY IMPLEMENTED (as `renderIssueSummary()` in main JS)

Aggregates and displays errors and warnings across all domains.

#### Populated Container
- `#issue-summary-container`

#### Data Source
- Calls `buildIssueSummary()` which scans all table rows with `data-status-category="error"` or `data-status-category="warning"`

#### Sections Rendered
1. **Critical Issues** (errors)
   - Application installation failures
   - Configuration profile deployment errors
   - Compliance policy violations

2. **Warnings**
   - Pending installations
   - Available-but-not-installed apps
   - Conflict states

#### Features
- Collapsible issue categories
- Jump links to affected items (via `jumpToIssue()`)
- Empty state: "All systems operational" if no issues
- Counts shown in headers

#### CSS Classes Used
```css
.issue-summary
.issue-summary-header
.issue-summary-body
.issue-category
.issue-category-header (.critical, .warning)
.issue-category-items
.issue-item
.issue-item-icon
.issue-item-content
.issue-item-name
.issue-item-description
.issue-item-action
.jump-link
.issue-empty-state
```

---

### 3. `renderCollectionIssues(data)`

**Status**: ✅ NEWLY IMPLEMENTED

Renders problems that occurred during data collection (Phase 0-3 in Orchestration.ps1).

#### Populated Container
- `#collection-issues`

#### Data Source
- `data.collectionIssues[]`
  - `severity`: "Error" | "Warning" | "Info"
  - `phase`: "Setup" | "Group Policy" | "Intune" | "SCCM" | "Windows Update"
  - `message`: Description of the issue

#### Filtering Logic
Issues are filtered based on device management type:

| Management Type | Filter Logic |
|-----------------|--------------|
| Cloud-only / Azure AD joined | Suppress GP-related info/warnings (errors still shown) |
| On-prem / Hybrid | Suppress Intune-related info/warnings (errors still shown) |

**Rationale**: Cloud-only devices don't have Group Policy, so "GP not available" warnings are noise. Similarly, on-prem-only devices without Intune shouldn't show Intune warnings.

#### Features
- Color-coded alerts (red=error, yellow=warning, blue=info)
- Icon badges (❌, ⚠️, ℹ️)
- Empty state if no issues
- Section count updated automatically

#### CSS Classes Used
```css
.alert (.alert-danger, .alert-warning, .alert-info)
.alert-icon
.empty-state
.empty-state-icon
```

#### Example Output
```html
<div class="alert alert-danger">
    <span class="alert-icon">❌</span>
    <div>
        <strong>Intune</strong>: Failed to connect to Microsoft Graph API. Check network connectivity.
    </div>
</div>
```

---

### 4. `renderOverviewTab(data)`

**Status**: ✅ NEWLY IMPLEMENTED

Orchestration function that renders all Overview tab sections.

#### Execution Order
1. `renderExecutiveDashboard(data)` → Executive Dashboard
2. `renderIssueSummaryPanel(data)` → Issue Summary
3. `renderCollectionIssues(data)` → Collection Issues

#### Usage
```javascript
document.addEventListener('DOMContentLoaded', function() {
    const dataElement = document.getElementById('policy-data');
    const deviceData = JSON.parse(dataElement.textContent);
    renderOverviewTab(deviceData);
});
```

---

## Device Tab Functions

### 5. `renderDeviceInfo(data)`

**Status**: ✅ NEWLY IMPLEMENTED

Renders comprehensive device inventory with hardware, OS, network, security, and power details.

#### Populated Container
- `#device-info-content` (primary)
- Falls back to `.section-content` inside `#device-info-section`

#### Data Source
- `data.deviceInfo.*` (collected by DeviceInfo.ps1)

#### Sections Rendered

| Section | Data Structure | Display Format |
|---------|----------------|----------------|
| **Processor** | `deviceInfo.Processor` | 2-column nested table |
| **Memory** | `deviceInfo.Memory` | 2-column table + sub-table for modules |
| **Storage** | `deviceInfo.Storage.Disks[]` | Multi-row table (Model, Size, Interface, Media Type, Status) |
| **BIOS / Firmware** | `deviceInfo.BIOS` | 2-column nested table |
| **Network Adapters** | `deviceInfo.Network.Adapters[]` | Per-adapter 2-column tables (with `<h4>` headers) |
| **Proxy Configuration** | `deviceInfo.Proxy` | 2-column nested table |
| **Security Status** | `deviceInfo.Security` | Multi-subsection:<br>- BitLocker Volumes<br>- Windows Defender<br>- Windows Firewall |
| **Power & Uptime** | `deviceInfo.Power` | 2-column nested table |

#### HTML Structure
The PowerShell implementation generates nested tables with `<h3>` section headers. This JavaScript version mirrors that structure:

```html
<h3>Processor</h3>
<table class="nested-table">
  <tbody>
    <tr><td><strong>Name</strong></td><td>Intel Core i7-10700</td></tr>
    <tr><td><strong>Cores</strong></td><td>8</td></tr>
    ...
  </tbody>
</table>

<h3>Memory</h3>
<table class="nested-table">
  <tbody>
    <tr><td><strong>Total Physical Memory</strong></td><td>16 GB</td></tr>
    <tr>
      <td><strong>Memory Modules</strong></td>
      <td>
        <table class="nested-table">
          <thead>
            <tr><th>Capacity</th><th>Speed</th><th>Manufacturer</th><th>Part Number</th></tr>
          </thead>
          <tbody>
            <tr><td>8 GB</td><td>2666 MHz</td><td>Samsung</td><td>M471A1K43...</td></tr>
            ...
          </tbody>
        </table>
      </td>
    </tr>
  </tbody>
</table>
```

#### Features
- **Dynamic Sections**: Only renders sections with available data
- **Nested Tables**: Memory modules, network adapters, BitLocker volumes use sub-tables
- **Empty State**: Shows "No enhanced device inventory collected" if no data
- **HTML Escaping**: All text values escaped via `escapeHtml()`

#### CSS Classes Used
```css
.nested-table (2-column key-value tables)
.empty-state
```

---

### 6. `renderDeviceTab(data)`

**Status**: ✅ NEWLY IMPLEMENTED

Orchestration function that renders all Device tab sections.

#### Execution Order
1. `renderDeviceInfo(data)` → Device Inventory

#### Usage
```javascript
// When switching to Device tab
function switchTab(tabId) {
    if (tabId === 'device') {
        renderDeviceTab(deviceData);
    }
}
```

---

## Data Schema

### Overview Tab Data

#### `data.collectionIssues[]`
```javascript
[
  {
    "severity": "Error",         // "Error" | "Warning" | "Info"
    "phase": "Intune",           // "Setup" | "Group Policy" | "Intune" | "SCCM" | "Windows Update"
    "message": "Failed to connect to Microsoft Graph API"
  }
]
```

#### `data.deviceInfo`
```javascript
{
  "hostname": "PC-001",
  "managementType": "Cloud-only",  // Used for issue filtering
  "joinType": "Azure AD Joined",
  "serialNumber": "ABC123XYZ",
  // ... (see Device Tab Data below)
}
```

#### `data.intune`
```javascript
{
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "lastSync": "2026-02-17T10:30:00Z",
  "compliancePolicies": [],
  "configurationProfiles": [],
  "applications": []
}
```

#### `data.metadata`
```javascript
{
  "collectionTime": "2026-02-17T10:35:42Z",
  "version": "0.2.0"
}
```

---

### Device Tab Data

#### `data.deviceInfo.Processor`
```javascript
{
  "Name": "Intel(R) Core(TM) i7-10700 CPU @ 2.90GHz",
  "Manufacturer": "GenuineIntel",
  "Cores": "8",
  "LogicalProcessors": "16",
  "MaxClockSpeed": "2904 MHz",
  "Architecture": "x64"
}
```

#### `data.deviceInfo.Memory`
```javascript
{
  "TotalPhysicalMemory": "16 GB",
  "AvailableMemory": "8.2 GB",
  "MemoryModules": [
    {
      "Capacity": "8 GB",
      "Speed": "2666 MHz",
      "Manufacturer": "Samsung",
      "PartNumber": "M471A1K43CB1-CTD"
    }
  ]
}
```

#### `data.deviceInfo.Storage.Disks[]`
```javascript
[
  {
    "Model": "Samsung SSD 970 EVO Plus 500GB",
    "Size": "465.76 GB",
    "InterfaceType": "NVMe",
    "MediaType": "SSD",
    "Status": "OK"
  }
]
```

#### `data.deviceInfo.BIOS`
```javascript
{
  "Manufacturer": "Dell Inc.",
  "Version": "1.15.0",
  "ReleaseDate": "2023-08-15",
  "SMBIOSVersion": "3.2",
  "UEFIMode": "UEFI",
  "SecureBoot": "Enabled",
  "TPMPresent": "True",
  "TPMVersion": "2.0",
  "TPMEnabled": "True"
}
```

#### `data.deviceInfo.Network.Adapters[]`
```javascript
[
  {
    "Description": "Intel(R) Ethernet Connection I219-V",
    "MACAddress": "00:1A:2B:3C:4D:5E",
    "IPAddress": "192.168.1.100",
    "SubnetMask": "255.255.255.0",
    "DefaultGateway": "192.168.1.1",
    "DHCPEnabled": "True",
    "DHCPServer": "192.168.1.1",
    "DNSServers": "8.8.8.8, 8.8.4.4",
    "DNSDomain": "example.com"
  }
]
```

#### `data.deviceInfo.Proxy`
```javascript
{
  "ProxyEnable": "False",
  "ProxyServer": "",
  "ProxyOverride": "",
  "AutoConfigURL": ""
}
```

#### `data.deviceInfo.Security`
```javascript
{
  "BitLockerVolumes": [
    {
      "MountPoint": "C:",
      "ProtectionStatus": "On",
      "EncryptionPercentage": "100"
    }
  ],
  "DefenderVersion": "4.18.23110.2009",
  "FirewallStatus": {
    "Domain": "Enabled",
    "Private": "Enabled",
    "Public": "Enabled"
  }
}
```

#### `data.deviceInfo.Power`
```javascript
{
  "BatteryPresent": "False",
  "BatteryStatus": null,
  "BatteryHealth": null,
  "LastBootTime": "2026-02-10 08:30:15",
  "Uptime": "7 days, 2 hours, 5 minutes"
}
```

---

## Integration Guide

### Step 1: Include Script in HTML Template

Add to the `<head>` section of the DeviceDNA report template:

```html
<script src="templates/render-overview-device.js"></script>
```

Or inline the script in the PowerShell template generation.

### Step 2: Update DOMContentLoaded Event

```javascript
document.addEventListener('DOMContentLoaded', function() {
    // Parse embedded data
    const dataElement = document.getElementById('policy-data');
    if (dataElement) {
        try {
            policyData = JSON.parse(dataElement.textContent);

            // Render Overview tab (default active tab)
            renderOverviewTab(policyData);

            // Initialize other components
            initializeStickyNav();
            initializeCollapsibles();
            initializeTables();
            initializeTheme();
            // ...
        } catch (e) {
            console.error('Failed to parse policy data:', e);
        }
    }
});
```

### Step 3: Lazy Render Device Tab on Switch

To optimize initial load time, render the Device tab only when the user switches to it:

```javascript
function switchTab(tabId) {
    // ... existing tab switching logic ...

    // Lazy render Device tab
    if (tabId === 'device') {
        const deviceContent = document.querySelector('[data-tab="device"] .section-content');
        if (deviceContent && !deviceContent.dataset.rendered) {
            renderDeviceTab(policyData);
            deviceContent.dataset.rendered = 'true';
        }
    }
}
```

---

## Testing Checklist

### Overview Tab

- [ ] Executive Dashboard renders with correct device identity
- [ ] Health cards show correct status colors
- [ ] Configuration summary shows accurate counts
- [ ] Config rows are clickable and switch to correct tabs
- [ ] Issue Summary aggregates errors and warnings
- [ ] Jump links scroll to correct items
- [ ] Collection Issues filters by management type
- [ ] Empty states display when no data

### Device Tab

- [ ] Processor section renders with all fields
- [ ] Memory section shows total/available + modules sub-table
- [ ] Storage section shows all disks
- [ ] BIOS section shows firmware details + TPM info
- [ ] Network adapters section shows all adapters
- [ ] Proxy configuration renders
- [ ] Security section shows BitLocker, Defender, Firewall
- [ ] Power section shows battery (if present) + uptime
- [ ] Empty state displays if no inventory collected
- [ ] All text is HTML-escaped (no XSS vulnerabilities)

---

## Performance Considerations

### Initial Load
- **Executive Dashboard**: Scans DOM to count items → O(n) where n = total rows
- **Issue Summary**: Scans DOM to find errors/warnings → O(n)
- **Collection Issues**: Filters array → O(m) where m = issue count

### Optimization Tips
1. **Lazy Rendering**: Render Device tab only when accessed (not on page load)
2. **Caching**: Store `calculateComprehensiveMetrics()` results to avoid re-scanning DOM
3. **Virtual Scrolling**: For large device inventories (100+ network adapters), consider virtualization

---

## Browser Compatibility

All functions use ES6 features:
- Arrow functions (`=>`)
- Template literals (`` `${}` ``)
- `const`/`let`
- `forEach()`

**Minimum Browser Versions**:
- Chrome 51+
- Firefox 54+
- Safari 10+
- Edge 15+

For IE11 support, transpile with Babel.

---

## Maintenance Notes

### When Adding New Device Inventory Fields

1. Update `DeviceInfo.ps1` to collect new data
2. Add new section to `renderDeviceInventoryInContainer()` in this file
3. Update "Data Schema" section in this README
4. Test with `Test-DeviceInfo.ps1`

### When Adding New Collection Phases

1. Update `Orchestration.ps1` to emit new `$script:CollectionIssues` entries
2. Update phase filtering logic in `renderCollectionIssues()` if needed
3. Update "Data Schema" section for `collectionIssues[]`

---

## Related Files

| File | Purpose |
|------|---------|
| `modules/Reporting.ps1` | PowerShell implementation (source of truth) |
| `templates/extracted-javascript.js` | Main JS (contains `renderDeviceOverviewDashboard()`, `renderIssueSummary()`) |
| `templates/render-intune.js` | Intune tab render functions |
| `templates/render-other-sections.js` | GP, SCCM, WU render functions |
| `modules/DeviceInfo.ps1` | Device inventory collection logic |
| `modules/Orchestration.ps1` | Collection phase orchestration + issue tracking |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-17 | Initial implementation of `renderCollectionIssues()` and `renderDeviceInfo()` |

---

## Contact

For issues or questions about these render functions, see the main DeviceDNA project documentation.
