# Intune Rendering Functions - Implementation Guide

## Overview

This file (`render-intune.js`) contains JavaScript functions that render all Intune sections in the DeviceDNA HTML report. The functions match the existing PowerShell rendering logic in `modules/Reporting.ps1` (lines 5137-5417).

## File Location

```
/Users/joshua/Documents/GitHub/Policy-Lens/templates/render-intune.js
```

## Functions Included

### Helper Functions

1. **getStatusCategory(status)**
   - Maps status strings to categories: `error`, `warning`, `success`, `neutral`
   - Used for color coding and filtering
   - Matches `Get-StatusCategory` in Reporting.ps1

2. **getStatusIcon(statusCategory)**
   - Returns HTML for status icon bullets (●)
   - Color varies by category: red (error), yellow (warning), green (success), gray (neutral)

3. **getIntuneStatusBadge(status)**
   - Returns HTML for status badges with appropriate color classes
   - Matches `Get-StatusBadgeHtml` in Reporting.ps1

4. **getGroupTypeBadge(groupType)**
   - Returns HTML for group type badges (Dynamic/Assigned)
   - Matches `Get-GroupTypeBadgeHtml` in Reporting.ps1

### Main Render Functions

1. **renderDeviceGroups(data)**
   - Renders Entra ID Device Groups table
   - **Structure:** Name | Type | ID
   - **No status icons** - simple data table
   - Returns: `{ html: string, count: number }`

2. **renderConfigurationProfiles(data)**
   - Renders Configuration Profiles table **WITH expandable rows**
   - **Structure:** Status | Name | Description | Type | Status | Assigned Via
   - **CRITICAL FEATURE:** Expandable detail rows showing configured settings
   - Settings count badge displayed in name column: `(N settings)`
   - Detail row contains nested `settings-table` with Setting | Value columns
   - Returns: `{ html: string, count: number }`

3. **renderCompliancePolicies(data)**
   - Renders Compliance Policies table
   - **Structure:** Status | Name | Platform | Assigned Via | Compliance State
   - Status icon indicates compliant/non-compliant state
   - Returns: `{ html: string, count: number }`

4. **renderApplications(data)**
   - Renders Applications table
   - **Structure:** Status | Name | Version | Publisher | Type | Intent | Installed | Assigned Via
   - Intent badges: Required (red), Available (blue), Uninstall (yellow)
   - Install state badges: Installed (green), Failed (red), Pending (blue), Unknown (yellow)
   - **Note:** Install state from local IME registry (Win32 apps only)
   - Returns: `{ html: string, count: number }`

5. **renderProactiveRemediations(data)**
   - Renders Proactive Remediations table
   - **Structure:** Name | Run As | Detection Status | Remediation Status | Last Run | Targeting Status
   - No status icon column (plain table)
   - Returns: `{ html: string, count: number }`

### Orchestration Function

**renderAllIntuneSections(intuneData)**
- Main entry point to render all Intune sections
- Calls all render functions and updates DOM
- Updates section count badges
- Re-initializes table functionality (sorting, filtering, expandable rows)

### Utility Function

**updateSectionCount(sectionId, count)**
- Updates count badges in section headers
- Updates navigation link counts
- Hides count badges when count is 0

## Data Structure Expected

The functions expect data in this structure:

```javascript
{
    deviceGroups: [
        { displayName: string, name: string, groupType: string, id: string }
    ],
    configurationProfiles: [
        {
            displayName: string,
            name: string,
            description: string,
            policyType: string,
            deploymentState: string,
            targetingStatus: string,
            settings: [
                { name: string, value: string|number|boolean }
            ]
        }
    ],
    compliancePolicies: [
        { displayName: string, name: string, platform: string, targetingStatus: string, complianceState: string }
    ],
    applications: [
        {
            displayName: string,
            name: string,
            appVersion: string,
            version: string,
            appType: string,
            publisher: string,
            intent: string,
            appInstallState: string,
            installedOnDevice: boolean,
            targetingStatus: string
        }
    ],
    proactiveRemediations: [
        {
            displayName: string,
            runAsAccount: string,
            targetingStatus: string,
            deviceRunState: {
                detectionState: string,
                remediationState: string,
                lastStateUpdateDateTime: string
            }
        }
    ]
}
```

## HTML Structure Required

Each section needs a table container with this structure:

```html
<section id="intune-profiles-section" class="section collapsed">
    <div class="section-header">
        <h2>Configuration Profiles <span class="section-count">0</span></h2>
    </div>
    <div class="section-content">
        <div class="table-container" data-section="intune-profiles-section">
            <table>
                <thead>
                    <tr>
                        <th class="status-icon-header" data-sort="statusCategory">Status</th>
                        <th data-sort="name">Name</th>
                        <th>Description</th>
                        <th>Type</th>
                        <th>Status</th>
                        <th>Assigned Via</th>
                    </tr>
                </thead>
                <tbody>
                    <!-- Rendered content inserted here -->
                </tbody>
            </table>
        </div>
    </div>
</section>
```

## CSS Classes Used

### Table Structure
- `.status-icon-cell` - Cell containing status icon
- `.status-icon` - The icon span (colored bullet)
- `.expandable-row` - Row that can be clicked to show detail
- `.detail-row` - Hidden detail row (toggled by click)
- `.detail-content` - Container for detail row content
- `.settings-table` - Nested table showing settings
- `.setting-value` - Cell for setting values
- `.value-truncate` - Text truncation for long values
- `.text-muted` - Grayed out text
- `.settings-count` - Badge showing number of settings

### Status Categories (data-status-category attribute)
- `error` - Red icon/background
- `warning` - Yellow icon/background
- `success` - Green icon/background
- `neutral` - Gray icon/background

### Badge Classes
- `.badge` - Base badge class
- `.badge-success` - Green badge
- `.badge-warning` - Yellow badge
- `.badge-danger` - Red badge
- `.badge-info` - Blue badge
- `.badge-secondary` - Gray badge
- `.badge-muted` - Light gray badge

## Integration Steps

1. **Include the script in the HTML template:**
   ```html
   <script src="templates/render-intune.js"></script>
   ```

2. **Call from main initialization:**
   ```javascript
   document.addEventListener('DOMContentLoaded', function() {
       const dataElement = document.getElementById('policy-data');
       if (dataElement) {
           const policyData = JSON.parse(dataElement.textContent);
           renderAllIntuneSections(policyData.intune);
       }
   });
   ```

3. **Ensure dependencies are loaded:**
   - `escapeHtml()` function from extracted-javascript.js
   - `initializeTables()` function from extracted-javascript.js
   - `initializeTableEnhancements()` function from extracted-javascript.js

## Key Features

### Expandable Configuration Profile Settings
The most complex feature is the expandable settings rows for configuration profiles:

- Main row shows profile name with settings count badge
- Click to expand shows nested table with all configured settings
- Settings are truncated at 200 characters with "... (truncated)" indicator
- Detail rows have unique IDs: `detail-profile-0`, `detail-profile-1`, etc.
- Expandable rows have `data-id` attribute linking to detail row

### Status-Based Styling
All rows with status tracking have:
- `data-status-category` attribute for filtering
- Status icon in first column
- CSS class matching status category for row coloring
- Can be filtered using the status filter buttons

### Assigned Via Display
Shows group assignment with smart truncation:
- Single group: Shows full name
- Multiple groups: Shows first group + "(+N more)" indicator
- Matches PowerShell implementation exactly

## Testing

To test these functions:

1. **Create test HTML page with empty tables**
2. **Load sample JSON data**
3. **Call `renderAllIntuneSections(testData.intune)`**
4. **Verify:**
   - All tables populate correctly
   - Expandable rows work (click to show/hide settings)
   - Status icons display with correct colors
   - Badges show correct classes and colors
   - Counts update in section headers
   - Filtering and sorting work after rendering

## Notes

- All functions use `escapeHtml()` for XSS prevention
- Sorting is alphabetical by name (case-insensitive)
- Functions return both HTML and count for flexibility
- All HTML matches the PowerShell template exactly
- Expandable rows require click handler from `initializeTables()`
- Status categories match PowerShell `Get-StatusCategory` function
- Badge classes match PowerShell `Get-StatusBadgeHtml` function

## Future Enhancements

When integrating config profile settings from the test scripts:
1. Update data structure to include settings array for each profile
2. Settings are already handled in `renderConfigurationProfiles()`
3. No code changes needed - just populate the `settings` property
4. Test scripts proven: `Test-ConfigProfileSettings.ps1` and `Test-RemainingProfiles.ps1`
