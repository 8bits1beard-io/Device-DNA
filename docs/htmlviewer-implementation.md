# DeviceDNA-Viewer.html — Standalone JSON Viewer

**Last Updated:** 2026-02-17

## Overview

`output/DeviceDNA-Viewer.html` is a single self-contained HTML file (~7,400 lines, ~247KB) that renders DeviceDNA JSON data files into an interactive report. It has no external dependencies — all CSS and JavaScript are embedded inline.

## How to Use

1. Open `output/DeviceDNA-Viewer.html` in any modern browser
2. Click "Select JSON File" or drag-and-drop a `.json` file onto the page
3. The report renders with all tabs, sections, and interactive features

## Architecture

```
DeviceDNA-Viewer.html (single file)
├── <style>
│   └── Full CSS from Reporting.ps1 Get-DeviceDNACSS (~2,700 lines)
│       Includes: dark/light themes, responsive layout, print styles,
│       table alignment fixes (box-shadow, no position:relative)
├── <body>
│   ├── File picker overlay (with drag-and-drop)
│   ├── Report container (hidden until JSON loaded)
│   │   ├── Sticky nav with tab bar (6 tabs)
│   │   ├── Header info grid
│   │   ├── Toolbar (search, expand/collapse, export, theme toggle)
│   │   └── Tab panels with section containers
└── <script>
    ├── Core UI (from extracted-javascript.js ~2,100 lines)
    │   Tabs, collapsibles, sorting, filtering, search, theme,
    │   export (MD/CSV/JSON/XLSX), dashboard, summary strips
    ├── Intune rendering (from render-intune.js ~500 lines)
    │   Device groups, config profiles, compliance, apps, remediations
    ├── GP/SCCM/WU rendering (from render-other-sections.js ~760 lines)
    │   GPOs, SCCM apps/baselines/updates/settings, WU summary/policy/pending/history
    ├── Overview/Device rendering (from render-overview-device.js ~450 lines)
    │   Executive dashboard, issue summary, collection issues, device info
    └── Viewer-specific JS (~150 lines)
        File picker, drag-and-drop, renderReport() orchestrator,
        renderReportHeader(), renderGPSettingsSection(), renderSCCMClientInfoSection()
```

## Tab → Section Mapping

| Tab | Sections |
|-----|----------|
| Overview | executive-dashboard-container, issue-summary-container, collection-issues-section |
| Group Policy | gp-computer-section, gp-user-section, gp-settings-section |
| Intune | intune-groups-device-section, intune-profiles-section, intune-compliance-section, intune-apps-section, intune-scripts-section |
| SCCM | sccm-client-section, sccm-apps-section, sccm-baselines-section, sccm-updates-section, sccm-settings-section |
| Windows Updates | wu-summary-section, wu-policy-section, wu-pending-section, wu-history-section |
| Device | device-info-section |

## Render Order (renderReport function)

1. Hide file picker, show report container
2. `renderReportHeader(data)` — header info grid
3. `renderAllIntuneSections(data.intune)` — all Intune tables
4. `renderAllOtherSections(data)` — GP, SCCM, WU tables
5. `renderGPSettingsSection(data)` — GP settings (not called by renderAllOtherSections)
6. `renderSCCMClientInfoSection(data)` — SCCM client key-value pairs
7. `renderDeviceInfo(data)` — device inventory
8. `renderCollectionIssues(data)` — issue list
9. UI initialization: collapsibles, tables, search, export, print, tabs
10. `renderDeviceOverviewDashboard()` — reads DOM, must be after data render
11. `renderIssueSummary()` — reads DOM
12. `initializeTableEnhancements()` — status counts, filter buttons, default sort
13. `renderSummaryStrips()` + `updateTabBadges()`

## Key Design Decisions

- **Single init pass:** `initializeTables()` is called only once from `renderReport()`, NOT from within `renderAllIntuneSections`. Duplicate handlers cause expandable rows to toggle open+close instantly.
- **Section IDs match render functions:** e.g., `intune-profiles-section` (not `config-profiles-section` as in the Reporting.ps1 generated HTML). The render JS targets these IDs.
- **`policyData` → `deviceData`:** All JS uses `deviceData` as the global variable name.
- **Data paths:** `deviceInfo.name` (not `.hostname`), `deviceInfo.osName` (not `.os.name`), `deviceInfo.tenantId` (not `intune.tenantId`).
- **Duplicate functions resolved by ordering:** `escapeHtml` and `renderCollectionIssues` are defined in both core JS and render-overview-device.js. The later (better) versions from render-overview-device.js win due to JS function hoisting.

## Source Files

The viewer was assembled from these proven source files:

| Component | Source | Lines |
|-----------|--------|-------|
| CSS | `modules/Reporting.ps1` Get-DeviceDNACSS | ~2,700 |
| Core JS | `output/LEUS82516223531/extracted-javascript.js` | ~2,100 |
| Intune render | `output/LEUS82516223531/render-intune.js` | ~500 |
| GP/SCCM/WU render | `output/LEUS82516223531/render-other-sections.js` | ~760 |
| Overview/Device render | `output/LEUS82516223531/render-overview-device.js` | ~450 |

## Updating the Viewer

When Reporting.ps1 CSS or JS changes:
1. Extract updated CSS/JS from a freshly generated report
2. Rebuild the viewer using the same assembly approach (Python script or manual)
3. Verify section IDs still match between HTML template and render functions
4. Test: load JSON, check all tabs, expand config profile rows, sort columns
