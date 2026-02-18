# render-other-sections.js

Client-side JavaScript rendering functions for Group Policy, SCCM, and Windows Update sections in DeviceDNA HTML reports.

## Overview

This module provides JavaScript functions that mirror the server-side PowerShell rendering in `modules/Reporting.ps1`. It enables dynamic rendering of non-Intune sections from JSON data, supporting future migration to a fully client-side rendered report.

## Functions

### Helper Functions

#### `getOtherStatusCategory(status)`
Maps status strings to categories: `error`, `warning`, `success`, `neutral`

**Parameters:**
- `status` (string) - Status value to categorize

**Returns:** String category

**Examples:**
```javascript
getOtherStatusCategory('Applied')      // 'success'
getOtherStatusCategory('Error')        // 'error'
getOtherStatusCategory('Pending')      // 'warning'
getOtherStatusCategory('Unknown')      // 'neutral'
```

#### `getOtherStatusIcon(statusCategory)`
Generates status icon HTML for table rows

**Parameters:**
- `statusCategory` (string) - One of: `error`, `warning`, `success`, `neutral`

**Returns:** HTML string with status icon

#### `getOtherStatusBadge(status)`
Generates color-coded badge HTML for status values

**Parameters:**
- `status` (string) - Status value

**Returns:** HTML string with badge

**Badge Colors:**
- `badge-success` - Applied, Compliant, Installed, Success
- `badge-danger` - Error, Failed, Denied
- `badge-warning` - Warning, Pending, Conflict
- `badge-info` - Info, Download, Install (in progress)
- `badge-muted` - Unknown, N/A, Available

#### `updateOtherSectionCount(sectionId, count)`
Updates section count badge in section header

**Parameters:**
- `sectionId` (string) - HTML element ID of section
- `count` (number) - Item count to display

---

### Group Policy Functions

#### `renderGroupPolicyObjects(data, scope)`
Renders Group Policy Objects table for computer or user scope

**Parameters:**
- `data` (object) - Full DeviceDNA data object
- `scope` (string) - Either `'computerScope'` or `'userScope'`

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Name
- Link Location
- Status (badge)

**Features:**
- Expandable rows for future GPO settings integration
- No status icons (GP uses badges only)
- Sorted by GPO name

**Data Structure Expected:**
```javascript
data.groupPolicy.computerScope.appliedGPOs = [
    {
        name: "Domain Security Policy",
        linkLocation: "example.com",
        status: "Applied"
    }
]
```

#### `renderGroupPolicySettings(data)`
Renders Group Policy Settings table (can be very large - 1000+ rows)

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Setting Name
- Value
- Source GPO
- Key Path

**Features:**
- No status icons
- Sorted by setting name
- Relies on existing table search/filter for performance on large datasets

**Data Structure Expected:**
```javascript
data.groupPolicy.settings = [
    {
        name: "MinimumPasswordLength",
        value: "14",
        sourceGPO: "Domain Security Policy",
        keyPath: "HKLM\\Software\\Policies\\..."
    }
]
```

**Note:** Pagination is handled by existing table infrastructure (search/filter), not by this function.

---

### SCCM Functions

#### `renderSCCMApplications(data)`
Renders SCCM Applications table with install state tracking

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Status Icon
- Name
- Version
- Publisher
- Deployment (Required/Available badge)
- Install State (badge)
- Eval State (badge)

**Status Icons:**
- Based on `InstallState` value
- Red = error, Yellow = warning, Green = success, Gray = neutral

**Data Structure Expected:**
```javascript
data.sccm.applications = [
    {
        Name: "7-Zip",
        Version: "23.01",
        Publisher: "Igor Pavlov",
        InstallState: "Installed",
        EvaluationState: "InstallComplete",
        IsRequired: false
    }
]
```

#### `renderSCCMBaselines(data)`
Renders SCCM Compliance Baselines table

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Status Icon
- Name
- Version
- Compliance State (badge)
- Last Evaluated

**Data Structure Expected:**
```javascript
data.sccm.baselines = [
    {
        Name: "Windows 10 Security Baseline",
        Version: "1.0",
        ComplianceState: "Compliant",
        LastEvaluated: "2026-02-17 14:30:00"
    }
]
```

#### `renderSCCMUpdates(data)`
Renders SCCM Software Updates table

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Status Icon
- Article ID
- Name
- Eval State (badge)
- Required (badge)
- Deadline

**Data Structure Expected:**
```javascript
data.sccm.softwareUpdates = [
    {
        ArticleID: "KB5034441",
        Name: "2024-01 Cumulative Update for Windows 10",
        EvaluationState: "InstallComplete",
        IsRequired: true,
        Deadline: "2026-03-01 00:00:00"
    }
]
```

#### `renderSCCMSettings(data)`
Renders SCCM Client Settings grouped by policy category

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }` (count = number of categories)

**Layout:**
- Key-value pairs grouped by category
- Uses `info-group` / `info-row` CSS classes (not table)

**Data Structure Expected:**
```javascript
data.sccm.clientSettings = [
    {
        Category: "Hardware Inventory",
        Settings: {
            "Enable hardware inventory": "True",
            "Schedule": "Every 7 days"
        }
    }
]
```

---

### Windows Update Functions

#### `renderWUSummary(data)`
Renders Windows Update Summary with management source badge

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Layout:**
- Summary grid with 4 info groups:
  1. Update Management (Managed By badge, Update Source, Source Priority)
  2. Service Status (Service State, Reboot Status, Pending Updates)
  3. Scan History (Last Scan Time, Last Scan Success)
  4. Delivery Optimization (Download Mode)

**Managed By Badge Colors:**
- **Blue** (`badge-info`) - SCCM
- **Green** (`badge-success`) - Intune (WUFB or ESUS)
- **Gray** (`badge-muted`) - WSUS or Windows Update (direct)

**Data Structure Expected:**
```javascript
data.windowsUpdate.summary = {
    updateManagement: "SCCM",
    updateSource: "SCCM Software Update Point",
    sourcePriority: "SCCM > ESUS > WUFB > WSUS > Windows Update",
    serviceState: "Running",
    rebootPending: false,
    pendingCount: 0,
    lastScanTime: "2026-02-17 10:00:00",
    lastScanSuccess: "2026-02-17 10:00:00"
}
data.windowsUpdate.deliveryOptimization = {
    DODownloadMode: {
        Decoded: "LAN (1)"
    }
}
```

#### `renderWUPolicy(data)`
Renders Windows Update Policy Settings table, grouped by registry hive

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Setting (with optional "Extra" badge for non-standard settings)
- Value
- Decoded (human-readable interpretation)

**Features:**
- Settings grouped by registry hive (group header rows)
- "Extra" badge for non-standard registry settings
- Setting descriptions shown below setting name (if available)

**Data Structure Expected:**
```javascript
data.windowsUpdate.registryPolicy = {
    "NoAutoUpdate": {
        Hive: "Windows Update Policies",
        Setting: "NoAutoUpdate",
        Value: 0,
        Decoded: "Auto-update enabled",
        Known: true,
        Description: "Configures automatic updating"
    }
}
```

#### `renderWUPending(data)`
Renders pending Windows Updates table

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Status Icon (always warning)
- Title
- KB Article
- Severity (badge: Critical=red, Important=yellow, Moderate=blue)
- Download Status (badge)

**Data Structure Expected:**
```javascript
data.windowsUpdate.pendingUpdates = [
    {
        Title: "2026-02 Cumulative Update for Windows 10",
        KBArticleIDs: "KB5034441",
        MsrcSeverity: "Important",
        IsDownloaded: true
    }
]
```

#### `renderWUHistory(data)`
Renders Windows Update history table

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** `{ html: string, count: number }`

**Table Columns:**
- Status Icon (success/error/warning based on result)
- Title
- Date
- Operation
- Result (badge)
- HResult (error code)

**Data Structure Expected:**
```javascript
data.windowsUpdate.updateHistory = [
    {
        Title: "2026-01 Cumulative Update for Windows 10",
        Date: "2026-01-15 14:30:00",
        Operation: "Installation",
        Result: "Succeeded",
        HResult: "0x00000000"
    }
]
```

---

### Orchestration Function

#### `renderAllOtherSections(data)`
Renders all Group Policy, SCCM, and Windows Update sections at once

**Parameters:**
- `data` (object) - Full DeviceDNA data object

**Returns:** None (updates DOM directly)

**What It Does:**
1. Calls all render functions above
2. Injects HTML into corresponding section `<tbody>` or container elements
3. Updates section count badges
4. Calls `updateAllStatusCounts()` to refresh status icon counts

**Usage:**
```javascript
// After loading JSON data
const deviceData = JSON.parse(document.getElementById('deviceData').textContent);
renderAllOtherSections(deviceData);
```

**Sections Updated:**
- `#gp-computer-section` - Computer GPOs
- `#gp-user-section` - User GPOs
- `#sccm-apps-section` - SCCM Applications
- `#sccm-baselines-section` - SCCM Baselines
- `#sccm-updates-section` - SCCM Updates
- `#sccm-settings-section` - SCCM Client Settings
- `#wu-summary-section` - Windows Update Summary
- `#wu-policy-section` - Windows Update Policy
- `#wu-pending-section` - Pending Updates
- `#wu-history-section` - Update History

---

## Integration with DeviceDNA Report

### Current PowerShell Rendering
Server-side rendering in `modules/Reporting.ps1` (lines 5096-5812):
- Generates static HTML from data
- Embeds HTML strings directly into report template
- No client-side rendering needed

### Future JavaScript Rendering
This module enables:
- Loading raw JSON data into `<script id="deviceData">` tag
- Rendering all sections client-side on page load
- Dynamic updates without regenerating entire report
- Easier testing and debugging of rendering logic

### Migration Path
1. **Phase 1 (Current):** PowerShell renders all HTML server-side
2. **Phase 2 (This Module):** JavaScript functions available but not yet used
3. **Phase 3 (Future):** Embed JSON only, render everything client-side
4. **Phase 4 (Future):** Add real-time updates, filtering, drill-downs

---

## Dependencies

### Required Global Functions
These must be available in the main JavaScript context:

- `escapeHtml(text)` - HTML entity encoding (from `extracted-javascript.js`)
- `updateAllStatusCounts()` - Aggregates status icon counts (from `extracted-javascript.js`)

### CSS Classes Used
From `extracted-css.css`:

**Status Icons:**
- `.status-icon-cell` - Table cell for status icon
- `.status-icon.error` - Red dot
- `.status-icon.warning` - Yellow dot
- `.status-icon.success` - Green dot
- `.status-icon.neutral` - Gray dot

**Badges:**
- `.badge.badge-success` - Green badge
- `.badge.badge-danger` - Red badge
- `.badge.badge-warning` - Yellow badge
- `.badge.badge-info` - Blue badge
- `.badge.badge-muted` - Gray badge
- `.badge.badge-secondary` - Default gray badge

**Layout:**
- `.device-info-grid` - Summary grid container
- `.info-group` - Card group for key-value pairs
- `.info-row` - Single key-value row
- `.info-label` / `.info-value` - Key/value spans
- `.table-container` - Table wrapper
- `.section-content` - Section content container
- `.section-count` - Count badge in section header
- `.expandable-row` - Clickable row to expand details
- `.detail-row` - Hidden detail content row
- `.settings-table` - Nested table for settings

---

## Testing

### Manual Testing
1. Open a DeviceDNA HTML report
2. Open browser console
3. Load this script: `<script src="render-other-sections.js"></script>`
4. Call orchestration function:
   ```javascript
   const data = JSON.parse(document.getElementById('deviceData').textContent);
   renderAllOtherSections(data);
   ```

### Automated Testing
Create test HTML with mock data:
```html
<script id="deviceData" type="application/json">
{
    "sccm": {
        "applications": [
            { "Name": "Test App", "Version": "1.0", "Publisher": "Test", "InstallState": "Installed", "EvaluationState": "InstallComplete", "IsRequired": false }
        ]
    }
}
</script>
<div id="sccm-apps-section">
    <div class="section-count">0</div>
    <table><tbody></tbody></table>
</div>
<script>
    const data = JSON.parse(document.getElementById('deviceData').textContent);
    renderAllOtherSections(data);
    console.log('SCCM Apps Count:', document.querySelector('#sccm-apps-section .section-count').textContent); // Should be "1"
</script>
```

---

## Notes

### Performance Considerations
- **Group Policy Settings:** Can contain 1000+ rows. Use table search/filter to paginate client-side.
- **Windows Update History:** Typically 50-200 entries. No pagination needed.
- **Status Icon Aggregation:** `updateAllStatusCounts()` scans all rows. Called once after all sections render.

### PowerShell Parity
All functions mirror the PowerShell rendering logic in `modules/Reporting.ps1`:
- Same badge color mappings
- Same status categorization rules
- Same HTML structure (table rows, badges, icons)
- Same sorting (alphabetical by name)

### Future Enhancements
- Add pagination controls for large tables
- Add column sorting controls
- Add expandable detail rows for GP settings
- Add real-time filtering across all sections
- Add export to CSV/Excel from rendered tables

---

## Version History

- **v1.0.0** (2026-02-17) - Initial release
  - Group Policy: GPO objects, settings
  - SCCM: Applications, baselines, updates, client settings
  - Windows Update: Summary, policy, pending, history
  - Orchestration function for one-call rendering
