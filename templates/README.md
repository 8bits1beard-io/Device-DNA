# DeviceDNA Report Templates

This directory contains extracted components from the DeviceDNA PowerShell reporting module for use in building standalone HTML templates.

## Files

### extracted-css.css
Complete CSS stylesheet extracted from `Get-DeviceDNAStyles` function in `modules/Reporting.ps1`.

**Size**: ~57 KB (1,493 lines)

**Features**:
- CSS custom properties (variables) for theming
- Light and dark theme support
- Responsive design (mobile-first)
- Print styles (@media print)
- Component styles (badges, buttons, tables, cards, alerts, etc.)
- Layout styles (sticky nav, tabs, collapsibles)
- Status indicators and progress bars
- Export dropdown and print button

### extracted-javascript.js
Complete JavaScript code extracted from `Get-DeviceDNAJavaScript` function in `modules/Reporting.ps1`.

**Size**: ~78 KB (2,097 lines)

**Key Features**:
1. **Theme Toggle** - Light/dark mode with localStorage persistence
2. **Table Functionality** - Sorting, filtering, expandable rows
3. **Section Collapsible** - Expand/collapse sections
4. **Global Search** - 250ms debounced search across all content
5. **Sticky Navigation** - Mobile menu, smooth scroll, active highlighting
6. **Export Functions** - Markdown, CSV, JSON, Excel (XLSX via SheetJS CDN)
7. **Print Functionality** - Auto-expand sections, print button
8. **Copy to Clipboard** - Modern Clipboard API with visual feedback
9. **Table Enhancements** - Status counts, filter buttons, default sorting
10. **Issue Summary** - Aggregated error/warning panel with jump links
11. **Device Overview Dashboard** - Executive summary with health metrics
12. **Tab Navigation** - 6-tab system with keyboard nav, badges, URL persistence
13. **Summary Strips** - Visual status breakdown for tables
14. **Utility Functions** - HTML/Markdown/CSV escaping, downloads, etc.

**Dependencies**:
- SheetJS (CDN, optional for Excel export): `https://cdn.sheetjs.com/xlsx-0.20.0/package/dist/xlsx.mini.min.js`
- Modern browser with ES6+ support
- Clipboard API (HTTPS required)

### javascript-features.md
Comprehensive documentation of all JavaScript functions and features.

## Usage

These files are ready to be included in an HTML template:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DeviceDNA Report</title>
    <link rel="stylesheet" href="extracted-css.css">
</head>
<body>
    <!-- Report content here -->

    <!-- Embedded data -->
    <script id="policy-data" type="application/json">
    {
        "deviceInfo": { ... },
        "groupPolicy": { ... },
        "intune": { ... },
        "sccm": { ... },
        "windowsUpdate": { ... },
        "collectionIssues": [ ... ],
        "metadata": { ... }
    }
    </script>

    <!-- JavaScript -->
    <script src="extracted-javascript.js"></script>
</body>
</html>
```

## Data Structure

The JavaScript expects a JSON object with the following structure in a `<script id="policy-data">` element:

```javascript
{
    "deviceInfo": {
        "hostname": "string",
        "name": "string",
        "fqdn": "string",
        "osName": "string",
        "osVersion": "string",
        "serialNumber": "string",
        "joinType": "string",
        "managementType": "string",
        "tenantId": "string",
        "currentUser": "string"
    },
    "groupPolicy": {
        "computerScope": {
            "appliedGPOs": [
                {
                    "name": "string",
                    "link": "string",
                    "status": "string",
                    "order": "number"
                }
            ]
        }
    },
    "intune": {
        "deviceGroups": [ ... ],
        "configurationProfiles": [ ... ],
        "applications": [ ... ],
        "compliancePolicies": [ ... ],
        "proactiveRemediations": [ ... ],
        "tenantId": "string",
        "lastSync": "string"
    },
    "sccm": {
        "clientInfo": { ... },
        "applications": [ ... ],
        "baselines": [ ... ],
        "updates": [ ... ],
        "settings": [ ... ]
    },
    "windowsUpdate": {
        "summary": {
            "pendingCount": "number",
            "updateManagement": "string"
        },
        "policy": [ ... ],
        "pending": [ ... ],
        "history": [ ... ]
    },
    "collectionIssues": [
        {
            "severity": "Error|Warning|Info",
            "phase": "string",
            "message": "string"
        }
    ],
    "metadata": {
        "collectionTime": "ISO 8601 timestamp",
        "collectedBy": "string",
        "version": "string"
    }
}
```

## Next Steps

To build a complete template:
1. Create HTML structure with sections and tables
2. Include extracted-css.css
3. Embed JSON data in `<script id="policy-data">` element
4. Include extracted-javascript.js
5. Ensure all section IDs match those referenced in TAB_CONFIG

## Source

Extracted from: `/modules/Reporting.ps1`
- CSS: Function `Get-DeviceDNAStyles` (lines 2615-4105)
- JavaScript: Function `Get-DeviceDNAJavaScript` (lines 2807-4913)

## Extraction Date

2026-02-17
