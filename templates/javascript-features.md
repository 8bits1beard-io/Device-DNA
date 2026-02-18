# Extracted JavaScript Features

The JavaScript extracted from `modules/Reporting.ps1` (function `Get-DeviceDNAJavaScript`) contains the following features:

## Core Functionality

### Global State
- `policyData`: Stores the parsed JSON data from the report
- `sheetJSLoaded`: Tracks whether SheetJS library has been loaded for Excel export

### Initialization
- `initializeReport()`: Main initialization function that renders all sections
- DOMContentLoaded event listener that triggers all initialization functions

### UI Components Initialized
1. `initializeStickyNav()` - Sticky navigation bar
2. `initializeCollapsibles()` - Section expand/collapse functionality
3. `initializeTables()` - Table sorting, expandable rows, per-table search
4. `initializeTableEnhancements()` - Status counts, filter buttons, default sorting
5. `renderDeviceOverviewDashboard()` - Executive dashboard rendering
6. `renderIssueSummary()` - Issue summary panel
7. `initializeSearch()` - Global search with debounce
8. `initializeTheme()` - Dark/light theme toggle
9. `initializeExport()` - Export dropdown functionality
10. `initializePrintButton()` - Print button and handlers
11. `initializeTabs()` - Tab navigation system
12. `renderSummaryStrips()` - Summary strips for tables

## Feature Breakdown

### 1. Theme Toggle
- **Functions**: `initializeTheme()`, `toggleTheme()`, `updateThemeIcon()`
- **Storage**: Uses localStorage to persist theme preference
- **Themes**: Light (default) and Dark
- **Icon**: Moon (🌙) for light mode, Sun (☀️) for dark mode

### 2. Table Functionality
- **Sorting**: `sortTable()`, `sortTableByStatus()`, `applyDefaultSort()`
  - Supports numeric and string sorting
  - Status category sorting with custom order
  - Default alphabetical sort by name column
  - Visual indicators for sort direction (asc/desc)
  
- **Filtering**: `filterTable()`, `applyTableFilter()`, `clearFilters()`
  - Per-table search inputs
  - Quick filters (All, Issues only)
  - Filter buttons in table headers
  
- **Expandable Rows**: `toggleDetailRow()`
  - Click to expand detail rows
  - Associated detail rows stay with parent during sorting
  - ARIA accessibility attributes

### 3. Section Collapsible
- **Functions**: `initializeCollapsibles()`, `expandAll()`, `collapseAll()`
- **Interaction**: Click section headers to toggle
- **State**: Visual CSS class toggles

### 4. Global Search
- **Function**: `initializeSearch()`
- **Features**:
  - 250ms debounce delay
  - Searches across all sections and rows
  - Hides sections with no matches
  - Searches section headers too

### 5. Sticky Navigation
- **Function**: `initializeStickyNav()`
- **Features**:
  - Mobile menu toggle (hamburger ☰ / close ✕)
  - Smooth scroll to sections
  - Active section highlighting on scroll
  - Navigation link counts (dynamic)
  - Quick filters (All, Issues, Warnings)
  - Status indicators (error/warning counts)
  - Submenu support

### 6. Export Functions
- **Markdown**: `exportMarkdown()`
  - Device info, collection issues, GP, Intune data
  - Escaped markdown special characters
  - Includes profile settings detail
  
- **CSV**: `exportCSV()`
  - Multiple sections separated by headers
  - CSV injection prevention (tabs before =, +, -, @)
  - Profile settings as separate section
  
- **JSON**: `exportJSON()`
  - Full policyData object export
  - Pretty-printed (2-space indent)
  
- **Excel (XLSX)**: `exportXLSX()`
  - Uses SheetJS (CDN: xlsx-0.20.0)
  - Multiple worksheets (Summary, Device Info, GPOs, Groups, Profiles, Apps, Compliance, Issues)
  - Profile Settings detail sheet
  - Loading state on button
  - Graceful fallback if CDN unavailable

### 7. Print Functionality
- **Functions**: `initializePrintButton()`, `initializePrintHandlers()`
- **Features**:
  - Print button with SVG icon
  - beforeprint: Auto-expands all collapsed sections and detail rows
  - afterprint: (Optional restoration - currently left expanded)

### 8. Copy to Clipboard
- **Function**: `copyToClipboard(text, btn)`
- **Features**:
  - Uses modern Clipboard API
  - Visual feedback (✓ checkmark for 1.5s)
  - Error handling

### 9. Render Functions
- **renderHeader()**: Header rendering (mostly server-side)
- **renderCollectionIssues()**: Filters and renders collection issues based on management type
- **renderGroupPolicy()**: GP sections (server-side)
- **renderIntune()**: Intune sections (server-side)

### 10. Table Enhancements
- **Functions**:
  - `initializeTableEnhancements()`: Master init function
  - `updateAllStatusCounts()`: Count error/warning/success/neutral rows
  - `initializeFilterButtons()`: Filter button click handlers
  - `applyTableFilter()`: Apply filters to table rows
  
- **Status Categories**: error, warning, success, neutral
- **Visual Indicators**: Colored status dots in section headers

### 11. Issue Summary
- **Functions**:
  - `buildIssueSummary()`: Scans all tables for error/warning rows
  - `renderIssueSummary()`: Renders issue summary panel
  - `toggleIssueCategory()`: Expand/collapse issue categories
  - `jumpToIssue(targetId)`: Jump to specific issue row with highlight effect
  
- **Categories**:
  - Critical Issues (🔴)
  - Warnings (⚠️)
  
- **Features**:
  - Jump links to source rows
  - Auto-expand parent sections
  - Auto-switch to correct tab
  - Highlight animation on target row

### 12. Device Overview Dashboard
- **Functions**:
  - `calculateComprehensiveMetrics()`: Aggregates metrics from all sections
  - `renderDeviceOverviewDashboard()`: Renders executive dashboard
  - `renderConfigRow()`: Helper for config summary rows
  
- **Metrics Tracked**:
  - Device identity (hostname, OS, serial, join type, management, tenant ID)
  - Health & status (overall health, compliance, collection issues, updates pending)
  - Configuration summary (GP, Intune Profiles, Apps, Compliance, SCCM Baselines, Windows Update)
  
- **Health States**: good (green), warning (yellow), critical (red)

### 13. Tab Navigation System
- **Configuration**: `TAB_CONFIG` object
  - overview: Dashboard, Issues, Collection Issues
  - gp: Group Policy
  - intune: Groups, Profiles, Apps, Compliance, Scripts
  - sccm: Client, Apps, Baselines, Updates, Settings
  - wu: Windows Updates (Summary, Policy, Pending, History)
  - device: Device Info
  
- **Functions**:
  - `initializeTabs()`: Setup click handlers, keyboard nav
  - `switchTab(tabId)`: Switch active tab
  - `getInitialTab()`: Restore from URL hash or localStorage
  - `updateTabBadges()`: Update item counts and issue indicators
  
- **Features**:
  - Keyboard navigation (Arrow keys, Home, End)
  - Mobile dropdown select
  - URL hash and localStorage persistence
  - Badge counts (total items per tab)
  - Status dots (issue indicators)
  - Smooth scroll to top on tab change

### 14. Summary Strips
- **Function**: `renderSummaryStrips()`
- **Features**:
  - Shows count breakdown (Error, Warning, OK, N/A)
  - Progress bar visualization
  - Total count display
  - Auto-generated for all tables with status-categorized rows

### 15. Utility Functions
- `escapeHtml(text)`: HTML entity encoding
- `escapeMarkdown(text)`: Markdown special character escaping
- `escapeCSV(value)`: CSV escaping with injection prevention
- `getDeviceName()`: Get device name from policyData
- `getTimestamp()`: Get ISO date string (YYYY-MM-DD)
- `downloadFile(content, filename, mimeType)`: Create blob and trigger download
- `loadSheetJS()`: Dynamically load SheetJS from CDN
- `getStatusBadge(status)`: Generate HTML for status badge
- `scrollToSection(sectionId)`: Smooth scroll with tab/section awareness
- `updateActiveNavLink()`: Update active nav link based on scroll position
- `updateNavCounts()`: Update nav link item counts
- `updateNavStatusIndicators()`: Add error/warning indicators to nav links

## File Size
- **Line Count**: 2,097 lines
- **Pure JavaScript**: No PowerShell-specific syntax
- **Ready for**: Direct inclusion in HTML `<script>` tag

## Dependencies
- **External Libraries**: SheetJS (CDN, optional for Excel export)
- **Browser APIs**: Clipboard API, localStorage, History API
- **ES6 Features**: Arrow functions, template literals, const/let, Array.from, Promise

## Browser Compatibility
- Modern browsers (ES6+ required)
- No IE11 support (uses arrow functions, const/let)
- Clipboard API (HTTPS required for production)
