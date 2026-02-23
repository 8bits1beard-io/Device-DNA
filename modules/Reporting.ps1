<#
.SYNOPSIS
    Device DNA - Reporting Module
.DESCRIPTION
    HTML report generation with embedded CSS and JavaScript.
    Includes JSON serialization, styling, interactive components,
    and self-contained HTML output with client-side export capabilities.
.NOTES
    Module: Reporting.ps1
    Dependencies: Core.ps1, Logging.ps1
    Version: 0.2.0
#>

#region HTML Report Generation
<#
.SYNOPSIS
    HTML Report Generation for DeviceDNA
.DESCRIPTION
    Creates self-contained interactive HTML reports for Group Policy and Intune data
#>

function ConvertTo-SafeJson {
    <#
    .SYNOPSIS
        Safely converts data to JSON for embedding in HTML/JavaScript
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Data
    )

    if ($null -eq $Data) {
        return 'null'
    }

    # Convert to JSON with proper escaping
    $json = $Data | ConvertTo-Json -Depth 20 -Compress

    # Escape characters that could break HTML/JS context
    $json = $json -replace '<', '\u003c'
    $json = $json -replace '>', '\u003e'
    $json = $json -replace '&', '\u0026'
    $json = $json -replace "'", '\u0027'

    # Escape script closing tags
    $json = $json -replace '</script>', '\u003c/script\u003e'

    return $json
}

function Get-DeviceDNACSS {
    <#
    .SYNOPSIS
        Returns the CSS styles for the HTML report
    #>
    [CmdletBinding()]
    param()

    return @'
:root {
    --color-success: #28a745;
    --color-warning: #ffc107;
    --color-danger: #dc3545;
    --color-info: #007bff;
    --color-muted: #6c757d;
    --color-bg: #ffffff;
    --color-bg-alt: #f8f9fa;
    --color-bg-dark: #343a40;
    --color-text: #212529;
    --color-text-muted: #6c757d;
    --color-border: #dee2e6;
    --color-header-bg: #e9ecef;
    --shadow-sm: 0 1px 2px rgba(0,0,0,0.05);
    --shadow: 0 2px 4px rgba(0,0,0,0.1);
    --shadow-lg: 0 4px 8px rgba(0,0,0,0.15);
    --radius: 6px;
    --radius-lg: 10px;
    --transition: 0.2s ease;
}

[data-theme="dark"] {
    --color-bg: #1a1a2e;
    --color-bg-alt: #16213e;
    --color-bg-dark: #0f0f1a;
    --color-text: #e8e8e8;
    --color-text-muted: #adb5bd;
    --color-border: #404040;
    --color-header-bg: #252545;
}

*, *::before, *::after {
    box-sizing: border-box;
}

html {
    font-size: 14px;
    scroll-behavior: smooth;
}

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
    line-height: 1.6;
    color: var(--color-text);
    background-color: var(--color-bg);
    margin: 0;
    padding: 0;
    transition: background-color var(--transition), color var(--transition);
}

/* Accessibility - Screen reader only */
.sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border-width: 0;
}

/* Sticky Navigation Bar */
.sticky-nav {
    position: sticky;
    top: 0;
    z-index: 1000;
    background: var(--color-bg);
    border-bottom: 2px solid var(--color-border);
    box-shadow: 0 2px 8px rgba(0,0,0,0.1);
    margin-bottom: 20px;
}

[data-theme="dark"] .sticky-nav {
    background: var(--color-bg-dark);
    box-shadow: 0 2px 8px rgba(0,0,0,0.3);
}

.nav-container {
    max-width: 1400px;
    margin: 0 auto;
    padding: 0 20px;
}

.nav-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 0;
    gap: 20px;
}

.nav-brand {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--color-text);
    text-decoration: none;
    white-space: nowrap;
}

.nav-brand-icon {
    font-size: 1.5rem;
}

.nav-search {
    flex: 1;
    max-width: 500px;
    position: relative;
}

.nav-search input {
    width: 100%;
    padding: 8px 15px 8px 35px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    font-size: 0.9rem;
    background: var(--color-bg-alt);
    color: var(--color-text);
    transition: all var(--transition);
}

.nav-search input:focus {
    outline: none;
    border-color: var(--color-info);
    background: var(--color-bg);
    box-shadow: 0 0 0 3px rgba(0,123,255,0.15);
}

.nav-search::before {
    content: '\1F50D';
    position: absolute;
    left: 10px;
    top: 50%;
    transform: translateY(-50%);
    opacity: 0.5;
    font-size: 0.9rem;
}

.nav-filters {
    display: flex;
    gap: 8px;
}

.filter-btn {
    padding: 6px 12px;
    border: 1px solid var(--color-border);
    background: var(--color-bg);
    color: var(--color-text);
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 500;
    transition: all var(--transition);
    white-space: nowrap;
}

.filter-btn:hover {
    background: var(--color-bg-alt);
    border-color: var(--color-info);
}

.filter-btn.active {
    background: var(--color-info);
    color: white;
    border-color: var(--color-info);
}

.filter-btn.filter-issues.active {
    background: var(--color-danger);
    border-color: var(--color-danger);
}

.filter-btn.filter-warnings.active {
    background: var(--color-warning);
    border-color: var(--color-warning);
    color: #856404;
}

.mobile-menu-toggle {
    display: none;
    background: transparent;
    border: 1px solid var(--color-border);
    padding: 8px 12px;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 1.25rem;
}

.nav-links {
    display: flex;
    gap: 5px;
    padding: 8px 0;
    border-top: 1px solid var(--color-border);
    overflow-x: auto;
}

.nav-link {
    padding: 8px 16px;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 0.9rem;
    font-weight: 500;
    color: var(--color-text);
    text-decoration: none;
    transition: all var(--transition);
    white-space: nowrap;
    display: flex;
    align-items: center;
    gap: 6px;
    position: relative;
}

.nav-link:hover {
    background: var(--color-bg-alt);
    color: var(--color-info);
}

.nav-link.active {
    background: var(--color-info);
    color: white;
}

.nav-link-icon {
    font-size: 1rem;
}

.nav-link-count {
    background: rgba(0,123,255,0.2);
    color: var(--color-info);
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
}

.nav-link.active .nav-link-count {
    background: rgba(255,255,255,0.25);
    color: white;
}

.nav-link-status {
    margin-left: 4px;
    font-size: 0.75rem;
}

.nav-submenu {
    display: none;
    position: absolute;
    top: 100%;
    left: 0;
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    box-shadow: var(--shadow-lg);
    min-width: 200px;
    margin-top: 4px;
    z-index: 1001;
}

[data-theme="dark"] .nav-submenu {
    background: var(--color-bg-dark);
}

.nav-link:hover .nav-submenu,
.nav-submenu:hover {
    display: block;
}

.nav-submenu-item {
    padding: 10px 16px;
    cursor: pointer;
    transition: background-color var(--transition);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
}

.nav-submenu-item:first-child {
    border-top-left-radius: var(--radius);
    border-top-right-radius: var(--radius);
}

.nav-submenu-item:last-child {
    border-bottom-left-radius: var(--radius);
    border-bottom-right-radius: var(--radius);
}

.nav-submenu-item:hover {
    background: var(--color-bg-alt);
}

/* Mobile responsive */
@media (max-width: 768px) {
    .mobile-menu-toggle {
        display: block;
    }

    .nav-top {
        flex-wrap: wrap;
    }

    .nav-search {
        order: 3;
        flex: 1 1 100%;
        max-width: none;
    }

    .nav-filters {
        flex-wrap: wrap;
    }

    .filter-btn {
        font-size: 0.75rem;
        padding: 4px 8px;
    }

    .nav-links {
        display: none;
        flex-direction: column;
        gap: 2px;
    }

    .nav-links.mobile-open {
        display: flex;
    }

    .nav-submenu {
        position: static;
        display: none;
        border: none;
        box-shadow: none;
        padding-left: 20px;
        margin-top: 0;
    }

    .nav-link.submenu-open .nav-submenu {
        display: block;
    }

    .nav-link:hover .nav-submenu {
        display: none;
    }
}

/* Layout */
.container {
    max-width: 1400px;
    margin: 0 auto;
    padding: 20px;
}

/* Header */
.header {
    background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
    color: white;
    padding: 30px;
    margin-bottom: 20px;
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
}

[data-theme="dark"] .header {
    background: linear-gradient(135deg, #0f2027 0%, #203a43 50%, #2c5364 100%);
}

.header-title-container {
    display: flex;
    align-items: center;
    gap: 20px;
    margin-bottom: 10px;
}

/* Logo styles removed - using emoji instead */

.header h1 {
    margin: 0;
    font-size: 2rem;
    font-weight: 600;
}

.header-info {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 15px;
    margin-top: 20px;
}

.header-info-item {
    background: rgba(255,255,255,0.15);
    padding: 12px 16px;
    border-radius: var(--radius);
    backdrop-filter: blur(5px);
}

.header-info-item label {
    display: block;
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    opacity: 0.8;
    margin-bottom: 4px;
}

.header-info-item span {
    font-weight: 500;
    font-size: 1rem;
}

/* Toolbar */
.toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    padding: 15px;
    background: var(--color-bg-alt);
    border-radius: var(--radius);
    margin-bottom: 20px;
    box-shadow: var(--shadow-sm);
}

.search-box {
    flex: 1;
    min-width: 250px;
    position: relative;
}

.search-box input {
    width: 100%;
    padding: 10px 15px 10px 40px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    font-size: 1rem;
    background: var(--color-bg);
    color: var(--color-text);
    transition: border-color var(--transition), box-shadow var(--transition);
}

.search-box input:focus {
    outline: none;
    border-color: var(--color-info);
    box-shadow: 0 0 0 3px rgba(0,123,255,0.15);
}

.search-box::before {
    content: '\1F50D';
    position: absolute;
    left: 12px;
    top: 50%;
    transform: translateY(-50%);
    opacity: 0.5;
    font-size: 1rem;
}

.btn-group {
    display: flex;
    gap: 5px;
}

.btn {
    padding: 8px 16px;
    border: none;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 0.875rem;
    font-weight: 500;
    transition: all var(--transition);
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.btn-primary {
    background: var(--color-info);
    color: white;
}

.btn-primary:hover {
    background: #0056b3;
    transform: translateY(-1px);
}

.btn-secondary {
    background: var(--color-bg);
    color: var(--color-text);
    border: 1px solid var(--color-border);
}

.btn-secondary:hover {
    background: var(--color-bg-alt);
}

.btn-success {
    background: var(--color-success);
    color: white;
}

.btn-success:hover {
    background: #218838;
}

.btn-warning {
    background: var(--color-warning);
    color: #212529;
}

.btn-warning:hover {
    background: #e0a800;
}

/* Dark mode toggle */
.theme-toggle {
    background: transparent;
    border: 1px solid var(--color-border);
    padding: 8px 12px;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 1.1rem;
    transition: all var(--transition);
}

.theme-toggle:hover {
    background: var(--color-bg-alt);
}

/* Sections */
.section {
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-left: 4px solid var(--color-border);
    border-radius: var(--radius-lg);
    margin-bottom: 20px;
    overflow: hidden;
    box-shadow: var(--shadow-sm);
    transition: box-shadow var(--transition), border-color var(--transition);
}

/* Domain color accents */
.section[data-domain="gp"] { border-left-color: #2563EB; }
.section[data-domain="intune"] { border-left-color: #7C3AED; }
.section[data-domain="sccm"] { border-left-color: #0D9488; }
.section[data-domain="wu"] { border-left-color: #EA580C; }
.section[data-domain="device"] { border-left-color: #64748B; }
.section[data-domain="issues"] { border-left-color: var(--color-warning); }

.section-header {
    background: var(--color-header-bg);
    padding: 15px 20px;
    cursor: pointer;
    display: flex;
    justify-content: space-between;
    align-items: center;
    user-select: none;
    transition: background-color var(--transition);
}

.section-header:hover {
    background: var(--color-border);
}

.section-header h2 {
    margin: 0;
    font-size: 1.25rem;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 10px;
}

.section-header .toggle-icon {
    font-size: 1.2rem;
    transition: transform var(--transition);
}

.section.collapsed .toggle-icon {
    transform: rotate(-90deg);
}

.section-content {
    padding: 20px;
    transition: max-height 0.3s ease-out, opacity 0.2s ease;
}

.section.collapsed .section-content {
    display: none;
}

.section-count {
    background: var(--color-info);
    color: white;
    padding: 2px 10px;
    border-radius: 20px;
    font-size: 0.8rem;
    font-weight: 500;
}

/* Alert boxes */
.alert {
    padding: 15px 20px;
    border-radius: var(--radius);
    margin-bottom: 15px;
    display: flex;
    align-items: flex-start;
    gap: 12px;
}

.alert-warning {
    background: rgba(255, 193, 7, 0.15);
    border: 1px solid var(--color-warning);
    color: #856404;
}

[data-theme="dark"] .alert-warning {
    color: #ffc107;
}

.alert-danger {
    background: rgba(220, 53, 69, 0.1);
    border: 1px solid var(--color-danger);
    color: #721c24;
}

[data-theme="dark"] .alert-danger {
    color: #f8d7da;
}

.alert-info {
    background: rgba(0, 123, 255, 0.1);
    border: 1px solid var(--color-info);
    color: #004085;
}

[data-theme="dark"] .alert-info {
    color: #b8daff;
}

.alert-icon {
    font-size: 1.2rem;
    flex-shrink: 0;
}

/* Device/WU/SCCM info grid layout */
.device-info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 20px;
    margin: 10px 0;
}

.info-group {
    background: var(--color-bg-alt);
    border-radius: var(--radius);
    padding: 15px;
    border: 1px solid var(--color-border);
}

.info-group h3 {
    margin: 0 0 12px 0;
    font-size: 0.9rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.03em;
    color: var(--color-text-muted);
    padding-bottom: 8px;
    border-bottom: 1px solid var(--color-border);
}

.info-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    padding: 6px 0;
    gap: 12px;
    border-bottom: 1px solid rgba(0,0,0,0.04);
}

.info-row:last-child {
    border-bottom: none;
}

[data-theme="dark"] .info-row {
    border-bottom-color: rgba(255,255,255,0.04);
}

[data-theme="dark"] .info-row:last-child {
    border-bottom: none;
}

.info-label {
    font-weight: 600;
    color: var(--color-text-muted);
    font-size: 0.85rem;
    white-space: nowrap;
    flex-shrink: 0;
}

.info-value {
    text-align: right;
    word-break: break-word;
    color: var(--color-text);
}

/* Setting description subtitle (WU policy table) */
.setting-desc {
    display: inline-block;
    font-size: 0.8rem;
    color: var(--color-text-muted);
    font-weight: 400;
    line-height: 1.3;
    margin-top: 2px;
}

/* Tables */
.table-container {
    overflow-x: auto;
    margin: 10px 0;
}

.table-search {
    margin-bottom: 10px;
}

.table-search input {
    padding: 8px 12px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    font-size: 0.875rem;
    background: var(--color-bg);
    color: var(--color-text);
    width: 250px;
    max-width: 100%;
}

table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
    font-size: 0.9rem;
}

thead th {
    background: var(--color-header-bg);
    padding: 12px 15px;
    text-align: left;
    font-weight: 600;
    border-bottom: 2px solid var(--color-border);
    cursor: pointer;
    white-space: nowrap;
    position: sticky;
    top: 0;
    z-index: 10;
}

thead th:hover {
    background: var(--color-border);
}

thead th.sorted-asc::after {
    content: ' \25B2';
    font-size: 0.7rem;
}

thead th.sorted-desc::after {
    content: ' \25BC';
    font-size: 0.7rem;
}

tbody tr {
    border-bottom: 1px solid var(--color-border);
    transition: background-color var(--transition);
}

tbody tr:nth-child(even) {
    background: var(--color-bg-alt);
}

tbody tr:hover {
    background: rgba(0, 123, 255, 0.05);
}

tbody td {
    padding: 12px 15px;
    vertical-align: top;
    word-break: break-word;
    overflow-wrap: break-word;
}

/* Expandable rows */
.expandable-row {
    cursor: pointer;
}

.expandable-row td:first-child::before {
    content: '\25B6';
    margin-right: 8px;
    font-size: 0.7rem;
    transition: transform var(--transition);
    display: inline-block;
}

.expandable-row.expanded td:first-child::before {
    transform: rotate(90deg);
}

.detail-row {
    display: none;
    background: var(--color-bg-alt);
}

.detail-row.visible {
    display: table-row;
}

.detail-content {
    padding: 20px;
    background: var(--color-bg);
    border-left: 4px solid var(--color-info);
    margin: 10px;
    border-radius: var(--radius);
}

/* Settings sub-table inside detail rows */
.settings-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.85rem;
    margin-top: 8px;
}
.settings-table th {
    text-align: left;
    padding: 6px 10px;
    font-weight: 600;
    border-bottom: 2px solid var(--color-border);
    color: var(--color-text-secondary);
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.3px;
}
.settings-table td {
    padding: 5px 10px;
    border-bottom: 1px solid var(--color-border);
    vertical-align: top;
}
.settings-table td.setting-value {
    max-width: 500px;
    overflow-wrap: break-word;
    word-break: break-all;
}
.settings-count {
    font-size: 0.75rem;
    color: var(--color-text-secondary);
    font-weight: normal;
    margin-left: 6px;
}

/* Status badges */
.badge {
    display: inline-flex;
    align-items: center;
    padding: 4px 10px;
    border-radius: 20px;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.3px;
}

.badge-success {
    background: rgba(40, 167, 69, 0.15);
    color: var(--color-success);
}

.badge-warning {
    background: rgba(255, 193, 7, 0.2);
    color: #856404;
}

[data-theme="dark"] .badge-warning {
    color: #ffc107;
}

.badge-danger {
    background: rgba(220, 53, 69, 0.15);
    color: var(--color-danger);
}

.badge-info {
    background: rgba(0, 123, 255, 0.15);
    color: var(--color-info);
}

.badge-muted {
    background: rgba(108, 117, 125, 0.15);
    color: var(--color-muted);
}

/* Copy button */
.copy-btn {
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 2px 6px;
    font-size: 0.8rem;
    opacity: 0.5;
    transition: opacity var(--transition);
    border-radius: var(--radius);
}

.copy-btn:hover {
    opacity: 1;
    background: var(--color-bg-alt);
}

.copy-btn.copied {
    color: var(--color-success);
}

/* Value display */
.value-with-copy {
    display: inline-flex;
    align-items: center;
    gap: 5px;
}

.value-truncate {
    max-width: 300px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* Key-value pairs */
.kv-list {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 10px;
}

.kv-item {
    display: flex;
    gap: 10px;
    padding: 8px 12px;
    background: var(--color-bg-alt);
    border-radius: var(--radius);
}

.kv-item .key {
    font-weight: 600;
    color: var(--color-text-muted);
    min-width: 120px;
}

.kv-item .value {
    word-break: break-word;
}

/* Settings list in detail rows */
.settings-list {
    list-style: none;
    padding: 0;
    margin: 0;
}

.settings-list li {
    padding: 8px 0;
    border-bottom: 1px solid var(--color-border);
    display: flex;
    justify-content: space-between;
    gap: 20px;
}

.settings-list li:last-child {
    border-bottom: none;
}

.setting-name {
    font-weight: 500;
}

.setting-value {
    color: var(--color-text-muted);
    text-align: right;
}

/* Subsection */
.subsection {
    margin-top: 20px;
    padding-top: 15px;
    border-top: 1px solid var(--color-border);
}

.subsection h3 {
    margin: 0 0 15px 0;
    font-size: 1.1rem;
    color: var(--color-text-muted);
}

/* Empty state */
.empty-state {
    text-align: center;
    padding: 40px 20px;
    color: var(--color-text-muted);
}

.empty-state-icon {
    font-size: 3rem;
    opacity: 0.3;
    margin-bottom: 10px;
}

/* Footer */
.footer {
    text-align: center;
    padding: 20px;
    color: var(--color-text-muted);
    font-size: 0.85rem;
    border-top: 1px solid var(--color-border);
    margin-top: 30px;
}

/* Export dropdown */
.export-dropdown {
    position: relative;
    display: inline-block;
}

.export-dropdown-content {
    display: none;
    position: absolute;
    right: 0;
    top: 100%;
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    box-shadow: var(--shadow-lg);
    min-width: 160px;
    z-index: 100;
    margin-top: 5px;
}

.export-dropdown.open .export-dropdown-content {
    display: block;
}

.export-dropdown-content button {
    display: block;
    width: 100%;
    padding: 10px 15px;
    border: none;
    background: none;
    text-align: left;
    cursor: pointer;
    font-size: 0.9rem;
    color: var(--color-text);
    transition: background-color var(--transition);
}

.export-dropdown-content button:hover {
    background: var(--color-bg-alt);
}

.export-dropdown-content button:first-child {
    border-radius: var(--radius) var(--radius) 0 0;
}

.export-dropdown-content button:last-child {
    border-radius: 0 0 var(--radius) var(--radius);
}

/* Loading indicator */
.loading {
    display: inline-flex;
    align-items: center;
    gap: 8px;
}

.loading::after {
    content: '';
    width: 14px;
    height: 14px;
    border: 2px solid var(--color-border);
    border-top-color: var(--color-info);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
}

@keyframes spin {
    to { transform: rotate(360deg); }
}

/* Print styles */
/* ===== ACCESSIBILITY ===== */

/* Focus indicators for keyboard navigation */
*:focus {
    outline: 2px solid var(--color-info);
    outline-offset: 2px;
}

button:focus, a:focus, input:focus, select:focus {
    outline: 2px solid var(--color-info);
    outline-offset: 2px;
}

/* High contrast mode support */
@media (prefers-contrast: high) {
    :root {
        --color-border: #000000;
        --color-text: #000000;
        --color-bg: #ffffff;
    }

    [data-theme="dark"] {
        --color-border: #ffffff;
        --color-text: #ffffff;
        --color-bg: #000000;
    }

    .btn {
        border: 2px solid currentColor !important;
    }

    .badge {
        border: 2px solid currentColor !important;
    }
}

/* Reduced motion support for users with vestibular disorders */
@media (prefers-reduced-motion: reduce) {
    *,
    *::before,
    *::after {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
        scroll-behavior: auto !important;
    }
}

/* ===== PRINT STYLES ===== */

@media print {
    /* Reset all elements to print-friendly colors */
    * {
        background: transparent !important;
        color: #000 !important;
        box-shadow: none !important;
        text-shadow: none !important;
    }

    body {
        background: white !important;
        color: black !important;
        font-size: 10pt;
        line-height: 1.4;
        margin: 0;
        padding: 0;
    }

    /* Hide all interactive UI elements */
    .toolbar,
    .theme-toggle,
    .export-dropdown,
    .copy-btn,
    .btn,
    .search-box,
    .btn-group,
    .toggle-icon,
    .expandable-row td:first-child::before,
    .sticky-nav,
    .nav-container,
    .nav-menu,
    .nav-actions,
    .print-btn,
    .table-controls,
    .filter-btn {
        display: none !important;
    }

    /* Preserve header with brand colors */
    .header {
        background: #1e3c72 !important;
        color: white !important;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        page-break-after: avoid;
        padding: 15pt !important;
        margin-bottom: 10pt !important;
    }

    .header h1 {
        font-size: 18pt !important;
        color: white !important;
    }

    /* Logo styles removed - using emoji instead */

    .header-info-item {
        background: rgba(255,255,255,0.2) !important;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }

    .header-info-item label,
    .header-info-item span {
        color: white !important;
    }

    /* Section handling with page breaks */
    .section {
        page-break-inside: avoid;
        border: 1pt solid #000 !important;
        margin-bottom: 10pt;
        box-shadow: none !important;
    }

    /* Force all collapsed sections to expand */
    .section.collapsed .section-content {
        display: block !important;
    }

    .section-header {
        background: #f0f0f0 !important;
        border-bottom: 1pt solid #000 !important;
        padding: 8pt !important;
        page-break-after: avoid;
    }

    .section-header h2 {
        font-size: 12pt !important;
    }

    .section-content {
        padding: 10pt !important;
    }

    /* Expand all detail rows for comprehensive printing */
    .detail-row {
        display: table-row !important;
    }

    .detail-content {
        border-left: 2pt solid #000 !important;
        background: #f9f9f9 !important;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }

    /* Table printing optimizations */
    table {
        border-collapse: collapse !important;
        width: 100%;
        font-size: 9pt;
    }

    /* Ensure table headers repeat on each page */
    thead {
        display: table-header-group;
    }

    tbody {
        display: table-row-group;
    }

    thead th {
        background: #e0e0e0 !important;
        border: 1pt solid #000 !important;
        padding: 6pt !important;
        font-weight: bold;
        text-align: left;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }

    tbody tr {
        page-break-inside: avoid;
        border-bottom: 1pt solid #ccc !important;
    }

    tbody td {
        border: 1pt solid #ddd !important;
        padding: 6pt !important;
    }

    /* Preserve badge colors with visible borders */
    .badge {
        border: 1pt solid currentColor !important;
        padding: 2pt 6pt !important;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
    }

    .badge-success {
        background: #e8f5e9 !important;
        color: #2e7d32 !important;
    }

    .badge-warning {
        background: #fff3e0 !important;
        color: #ef6c00 !important;
    }

    .badge-danger {
        background: #ffebee !important;
        color: #c62828 !important;
    }

    .badge-info {
        background: #e3f2fd !important;
        color: #1565c0 !important;
    }

    /* Alert boxes */
    .alert {
        border: 1pt solid #000 !important;
        padding: 8pt !important;
        page-break-inside: avoid;
    }

    /* Link handling - show URLs in print */
    a {
        text-decoration: underline;
        color: #000 !important;
    }

    a[href^="http"]::after {
        content: " (" attr(href) ")";
        font-size: 8pt;
        font-style: italic;
    }

    /* Footer */
    .footer {
        page-break-before: avoid;
        border-top: 1pt solid #000 !important;
        padding: 10pt 0 !important;
        margin-top: 20pt;
    }

    /* Prevent page breaks after headings */
    h1, h2, h3 {
        page-break-after: avoid;
    }

    /* Hide decorative elements */
    .empty-state-icon {
        display: none;
    }
}

/* ===== PRINT BUTTON ===== */

.print-btn {
    position: fixed;
    bottom: 20px;
    right: 20px;
    background: var(--color-info);
    color: white;
    border: none;
    padding: 12px 20px;
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    cursor: pointer;
    font-weight: 600;
    z-index: 1000;
    display: flex;
    align-items: center;
    gap: 8px;
    transition: all var(--transition);
}

.print-btn:hover {
    background: #0056b3;
    transform: translateY(-2px);
    box-shadow: 0 6px 12px rgba(0,0,0,0.2);
}

@media print {
    .print-btn {
        display: none !important;
    }
}

/* ===== RESPONSIVE BREAKPOINTS ===== */

/* Tablet (768px - 1199px) - 2 column grid */
@media (min-width: 768px) and (max-width: 1199px) {
    .container {
        max-width: 100%;
        padding: 15px;
    }

    .header h1 {
        font-size: 1.75rem;
    }

    .header-info {
        grid-template-columns: repeat(2, 1fr);
    }

    .kv-list {
        grid-template-columns: repeat(2, 1fr);
    }

    table {
        font-size: 0.85rem;
    }

    /* Hide less critical table columns on tablet */
    .hide-tablet {
        display: none;
    }
}

/* Mobile (<768px) - 1 column stack */
@media (max-width: 767px) {
    html {
        font-size: 13px;
    }

    .container {
        padding: 10px;
    }

    .header {
        padding: 15px;
        margin-bottom: 15px;
    }

    .header h1 {
        font-size: 1.5rem;
    }

    /* Logo styles removed - using emoji instead */

    .header-title-container {
        gap: 12px;
    }

    .header-info {
        grid-template-columns: 1fr;
        gap: 10px;
    }

    .header-info-item {
        padding: 10px 12px;
    }

    /* Toolbar mobile layout */
    .toolbar {
        flex-direction: column;
        align-items: stretch;
        padding: 12px;
        gap: 8px;
    }

    .search-box {
        min-width: 100%;
    }

    .btn-group {
        flex-wrap: wrap;
        justify-content: center;
        gap: 8px;
    }

    .btn {
        padding: 10px 14px;
        font-size: 0.9rem;
    }

    /* Section adjustments */
    .section {
        margin-bottom: 15px;
    }

    .section-header {
        padding: 12px 15px;
    }

    .section-header h2 {
        font-size: 1.1rem;
    }

    .section-content {
        padding: 15px;
    }

    /* Mobile-friendly tables with horizontal scroll */
    .table-container {
        overflow-x: auto;
        -webkit-overflow-scrolling: touch;
    }

    table {
        font-size: 0.8rem;
        min-width: 600px; /* Force horizontal scroll instead of squashing */
    }

    thead th,
    tbody td {
        padding: 8px 10px;
    }

    /* Hide non-critical columns on mobile */
    .hide-mobile {
        display: none;
    }

    /* Card-style layout for key-value pairs */
    .kv-list {
        grid-template-columns: 1fr;
    }

    .kv-item {
        flex-direction: column;
        gap: 5px;
    }

    .kv-item .key {
        min-width: auto;
        font-size: 0.85rem;
    }

    /* Alert mobile */
    .alert {
        padding: 12px 15px;
        font-size: 0.9rem;
    }

    /* Settings list mobile */
    .settings-list li {
        flex-direction: column;
        align-items: flex-start;
        gap: 5px;
    }

    .setting-value {
        text-align: left;
    }

    /* Detail rows */
    .detail-content {
        padding: 15px;
        margin: 5px;
    }

    /* Footer */
    .footer {
        font-size: 0.8rem;
        padding: 15px 10px;
    }

    /* Value truncation on mobile */
    .value-truncate {
        max-width: 200px;
    }

    /* Print button mobile position */
    .print-btn {
        bottom: 15px;
        right: 15px;
        padding: 10px 16px;
        font-size: 0.9rem;
    }

    /* Sticky nav mobile (if present) */
    .sticky-nav {
        margin-bottom: 15px;
    }

    .nav-container {
        padding: 0 10px;
    }

    .nav-top {
        flex-wrap: wrap;
        padding: 10px 0;
        gap: 10px;
    }

    .nav-brand {
        font-size: 1.1rem;
    }

    /* Collapse navigation menu on mobile */
    .nav-menu {
        display: none;
    }

    .nav-menu.open {
        display: flex;
    }
}

/* Desktop Large (1200px+) - 4 column grid */
@media (min-width: 1200px) {
    .container {
        max-width: 1400px;
    }

    .header-info {
        grid-template-columns: repeat(4, 1fr);
    }

    .kv-list {
        grid-template-columns: repeat(2, 1fr);
    }
}

/* Desktop Extra Large (1600px+) - expanded grid */
@media (min-width: 1600px) {
    .container {
        max-width: 1600px;
    }

    .header-info {
        grid-template-columns: repeat(5, 1fr);
    }

    .kv-list {
        grid-template-columns: repeat(3, 1fr);
    }
}

/* Mobile landscape orientation */
@media (max-width: 767px) and (orientation: landscape) {
    .header {
        padding: 12px 15px;
    }

    .header-info {
        grid-template-columns: repeat(2, 1fr);
    }
}

/* ===== TOUCH DEVICE OPTIMIZATIONS ===== */

@media (hover: none) and (pointer: coarse) {
    /* Larger tap targets for touch - minimum 44x44px (Apple HIG) */
    .btn {
        min-height: 44px;
        padding: 12px 18px;
    }

    .section-header {
        min-height: 50px;
        padding: 15px 20px;
    }

    thead th {
        padding: 15px;
    }

    .expandable-row {
        min-height: 44px;
    }

    /* Remove hover effects on touch devices */
    .btn:hover,
    .section-header:hover,
    thead th:hover,
    tbody tr:hover {
        transform: none;
    }
}

/* ===== TABLE ENHANCEMENTS ===== */

/* Status icon column */
.status-icon-col {
    width: 40px;
    text-align: center;
    padding: 8px !important;
    font-size: 1.2rem;
}

.status-icon-cell {
    text-align: center;
    padding: 12px 8px !important;
}

.status-icon {
    font-size: 1.3rem;
    line-height: 1;
    display: inline-block;
}

.status-icon.error { color: var(--color-danger); }
.status-icon.warning { color: var(--color-warning); }
.status-icon.success { color: var(--color-success); }
.status-icon.neutral { color: var(--color-muted); }

/* Color-coded row indicators — uses box-shadow instead of border-left to avoid
   column misalignment with border-collapse: collapse */
table tbody td:first-child {
    box-shadow: none;
    transition: box-shadow var(--transition);
}

table tbody tr.group-header-row {
    background-color: var(--color-header-bg);
}
table tbody tr.group-header-row td {
    padding: 10px 16px 6px;
    font-size: 0.82rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text-secondary);
}

table tbody tr[data-status-category="error"] td:first-child {
    box-shadow: inset 4px 0 0 var(--color-danger);
}

table tbody tr[data-status-category="warning"] td:first-child {
    box-shadow: inset 4px 0 0 var(--color-warning);
}

table tbody tr[data-status-category="success"] td:first-child {
    box-shadow: inset 4px 0 0 var(--color-success);
}

table tbody tr[data-status-category="neutral"] td:first-child {
    box-shadow: inset 4px 0 0 var(--color-border);
}

/* Detail rows inherit parent indicator color */
tr.expandable-row[data-status-category="error"] + tr.detail-row td:first-child {
    box-shadow: inset 4px 0 0 var(--color-danger);
}

tr.expandable-row[data-status-category="warning"] + tr.detail-row td:first-child {
    box-shadow: inset 4px 0 0 var(--color-warning);
}

tr.expandable-row[data-status-category="success"] + tr.detail-row td:first-child {
    box-shadow: inset 4px 0 0 var(--color-success);
}

tr.expandable-row[data-status-category="neutral"] + tr.detail-row td:first-child {
    box-shadow: inset 4px 0 0 var(--color-border);
}

/* Larger badge sizing */
.badge {
    padding: 5px 12px;
    font-size: 0.85rem;
    font-weight: 700;
    min-width: 90px;
    text-align: center;
    justify-content: center;
}

/* Section header enhancements */
.section-header-main {
    display: flex;
    align-items: center;
    gap: 20px;
    flex: 1;
}

.section-status-counts {
    display: flex;
    gap: 12px;
    align-items: center;
    font-size: 0.9rem;
}

.status-count {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 8px;
    border-radius: var(--radius);
    background: var(--color-bg-alt);
    font-weight: 600;
    opacity: 0.8;
}

.status-count[data-count="0"] { opacity: 0.3; }
.status-count.error { color: var(--color-danger); }
.status-count.warning { color: var(--color-warning); }
.status-count.success { color: var(--color-success); }

/* Table controls layout */
.table-controls {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 15px;
    margin-bottom: 15px;
    flex-wrap: wrap;
}

.table-filters {
    display: flex;
    gap: 8px;
}

.filter-btn {
    padding: 8px 16px;
    border: 1px solid var(--color-border);
    background: var(--color-bg);
    color: var(--color-text);
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 0.875rem;
    font-weight: 600;
    transition: all var(--transition);
}

.filter-btn:hover {
    background: var(--color-bg-alt);
}

.filter-btn.active {
    background: var(--color-info);
    color: white;
    border-color: var(--color-info);
}

/* Responsive adjustments */
@media (max-width: 768px) {
    .section-header-main {
        flex-direction: column;
        align-items: flex-start;
        gap: 10px;
    }

    .table-controls {
        flex-direction: column;
        align-items: stretch;
    }

    .filter-btn {
        flex: 1;
    }
}

/* Dark theme adjustments */
[data-theme="dark"] .status-count {
    background: var(--color-bg-dark);
}

[data-theme="dark"] .filter-btn {
    background: var(--color-bg-dark);
}

/* ===== ISSUE SUMMARY SECTION ===== */

.issue-summary {
    margin: 2rem 0;
    background: var(--color-bg);
    border-radius: 8px;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
    overflow: hidden;
}

.issue-summary-header {
    padding: 1.5rem;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    color: #ffffff;
    border-bottom: 3px solid rgba(255, 255, 255, 0.2);
}

.issue-summary-header h2 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 0.75rem;
}

.issue-summary-header .summary-count {
    font-size: 0.875rem;
    opacity: 0.9;
    margin-top: 0.5rem;
}

.issue-summary-body {
    padding: 1.5rem;
}

.issue-empty-state {
    text-align: center;
    padding: 3rem 2rem;
    color: var(--color-success);
    font-size: 1.125rem;
    font-weight: 500;
}

.issue-empty-state::before {
    content: "✓";
    display: block;
    font-size: 3rem;
    margin-bottom: 1rem;
    color: var(--color-success);
}

.issue-category {
    margin-bottom: 1.5rem;
}

.issue-category:last-child {
    margin-bottom: 0;
}

.issue-category-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 1rem 1.25rem;
    background: var(--color-bg-alt);
    border: 2px solid var(--color-border);
    border-radius: 6px;
    cursor: pointer;
    transition: all 0.2s ease;
    user-select: none;
}

.issue-category-header:hover {
    background: var(--color-bg);
    border-color: var(--color-muted);
}

.issue-category-header.critical {
    background: #fef2f2;
    border-color: #fecaca;
}

.issue-category-header.critical:hover {
    background: #fee2e2;
    border-color: #fca5a5;
}

.issue-category-header.warning {
    background: #fffbeb;
    border-color: #fde68a;
}

.issue-category-header.warning:hover {
    background: #fef3c7;
    border-color: #fcd34d;
}

[data-theme="dark"] .issue-category-header.critical {
    background: rgba(220, 38, 38, 0.1);
    border-color: rgba(220, 38, 38, 0.3);
}

[data-theme="dark"] .issue-category-header.warning {
    background: rgba(245, 158, 11, 0.1);
    border-color: rgba(245, 158, 11, 0.3);
}

.issue-category-title {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    font-weight: 600;
    font-size: 1rem;
}

.issue-category-title .icon {
    font-size: 1.25rem;
}

.issue-category-count {
    display: inline-block;
    min-width: 1.5rem;
    height: 1.5rem;
    line-height: 1.5rem;
    text-align: center;
    background: var(--color-bg);
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 700;
    padding: 0 0.5rem;
}

.issue-category-header.critical .issue-category-count {
    background: var(--color-danger);
    color: white;
}

.issue-category-header.warning .issue-category-count {
    background: var(--color-warning);
    color: white;
}

.issue-category-toggle {
    font-size: 0.875rem;
    color: var(--color-muted);
    transition: transform 0.2s ease;
}

.issue-category-header.collapsed .issue-category-toggle {
    transform: rotate(-90deg);
}

.issue-category-items {
    margin-top: 0.75rem;
    display: none;
}

.issue-category-header:not(.collapsed) + .issue-category-items {
    display: block;
}

.issue-item {
    display: flex;
    align-items: flex-start;
    gap: 1rem;
    padding: 1rem;
    background: var(--color-bg);
    border: 1px solid var(--color-border);
    border-radius: 6px;
    margin-bottom: 0.75rem;
    transition: all 0.15s ease;
}

.issue-item:last-child {
    margin-bottom: 0;
}

.issue-item:hover {
    border-color: var(--color-info);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.05);
}

.issue-item-icon {
    font-size: 1.5rem;
    line-height: 1;
    flex-shrink: 0;
}

.issue-item-content {
    flex: 1;
    min-width: 0;
}

.issue-item-name {
    font-weight: 600;
    color: var(--color-text);
    margin-bottom: 0.25rem;
    word-wrap: break-word;
}

.issue-item-description {
    color: var(--color-muted);
    font-size: 0.875rem;
    line-height: 1.5;
    margin-bottom: 0.5rem;
}

.issue-item-action {
    flex-shrink: 0;
}

.jump-link {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.375rem 0.75rem;
    background: var(--color-bg-alt);
    color: var(--color-text);
    text-decoration: none;
    border-radius: 4px;
    font-size: 0.8125rem;
    font-weight: 500;
    transition: all 0.15s ease;
    white-space: nowrap;
}

.jump-link:hover {
    background: var(--color-info);
    color: white;
    transform: translateX(2px);
}

.jump-link::after {
    content: "→";
    font-size: 1rem;
}

@media (max-width: 768px) {
    .issue-item {
        flex-direction: column;
        gap: 0.75rem;
    }

    .issue-item-action {
        align-self: flex-start;
    }

    .issue-summary-header h2 {
        font-size: 1.25rem;
    }
}

/* ===== Comprehensive Device Overview Dashboard ===== */
.device-overview-dashboard {
    margin: 2rem 0;
    padding: 0;
}

.dashboard-section {
    background: var(--color-bg);
    border-radius: 8px;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
    border-left: 4px solid var(--color-info);
}

.dashboard-section-title {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--color-text);
    margin: 0 0 1.25rem 0;
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.section-icon {
    font-size: 1.75rem;
}

.dashboard-subsection-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--color-text);
    margin: 0 0 1rem 0;
}

/* Device Identity Grid */
.identity-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem;
}

.identity-item {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
}

.identity-item label {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
}

.identity-item span {
    font-size: 0.9375rem;
    color: var(--color-text);
    font-weight: 500;
}

.identity-item small {
    font-size: 0.8125rem;
    color: var(--color-muted);
}

.value-truncate {
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* Health Status Grid */
.health-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 1rem;
}

.health-card {
    background: var(--color-bg);
    border-radius: 6px;
    padding: 1rem;
    border: 2px solid var(--color-border);
    text-align: center;
    transition: all 0.2s ease;
}

.health-card:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
}

.health-card.status-error {
    border-color: var(--color-error);
    background: linear-gradient(135deg, var(--color-bg) 0%, #fef2f2 100%);
}

.health-card.status-warning {
    border-color: var(--color-warning);
    background: linear-gradient(135deg, var(--color-bg) 0%, #fffbeb 100%);
}

.health-card.status-success {
    border-color: var(--color-success);
    background: linear-gradient(135deg, var(--color-bg) 0%, #f0fdf4 100%);
}

.health-card.status-neutral {
    border-color: var(--color-info);
    background: linear-gradient(135deg, var(--color-bg) 0%, #eff6ff 100%);
}

.health-icon {
    font-size: 2rem;
    margin-bottom: 0.5rem;
}

.health-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 0.5rem;
}

.health-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: var(--color-text);
    margin-bottom: 0.25rem;
}

.health-source {
    font-size: 0.75rem;
    color: var(--color-muted);
    margin-top: 0.5rem;
}

/* Configuration Summary List */
.config-list {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.config-row {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 1rem;
    background: var(--color-bg);
    border-radius: 6px;
    border: 1px solid var(--color-border);
    cursor: pointer;
    transition: all 0.2s ease;
}

.config-row:hover {
    background: #f9fafb;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
    transform: translateX(4px);
}

.config-row.status-error {
    border-left: 4px solid var(--color-error);
}

.config-row.status-warning {
    border-left: 4px solid var(--color-warning);
}

.config-row.status-success {
    border-left: 4px solid var(--color-success);
}

.config-icon {
    font-size: 1.5rem;
    flex-shrink: 0;
}

.config-info {
    flex: 1;
    min-width: 0;
}

.config-title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--color-text);
    margin-bottom: 0.25rem;
}

.config-stats {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
}

.stat-badge {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    padding: 0.125rem 0.5rem;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
}

.stat-badge.error {
    background: #fef2f2;
    color: var(--color-error);
}

.stat-badge.warning {
    background: #fffbeb;
    color: var(--color-warning);
}

.stat-badge.success {
    background: #f0fdf4;
    color: var(--color-success);
}

.config-total {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--color-text);
    min-width: 40px;
    text-align: right;
}

.config-arrow {
    font-size: 1.5rem;
    color: var(--color-muted);
    flex-shrink: 0;
}

@media (max-width: 768px) {
    .identity-grid {
        grid-template-columns: 1fr;
    }

    .health-grid {
        grid-template-columns: 1fr;
    }

    .config-row {
        padding: 0.75rem;
        gap: 0.75rem;
    }

    .config-icon {
        font-size: 1.25rem;
    }

    .config-total {
        font-size: 1rem;
    }
}

@media print {
    .device-overview-dashboard {
        page-break-inside: avoid;
    }

    .dashboard-section {
        box-shadow: none;
        border: 1px solid var(--color-border);
    }

    .config-row:hover {
        transform: none;
    }
}

/* ============================================================
   VISUAL POLISH — Premium SaaS Dashboard Effects
   ============================================================ */

/* Extended CSS Variables */
:root {
    --shadow-xs: 0 1px 2px rgba(0,0,0,0.04);
    --shadow-md: 0 6px 12px -2px rgba(0,0,0,0.08), 0 3px 6px -3px rgba(0,0,0,0.06);
    --shadow-xl: 0 20px 40px -8px rgba(0,0,0,0.12), 0 8px 16px -8px rgba(0,0,0,0.08);
    --glass-bg: rgba(255,255,255,0.72);
    --glass-border: rgba(255,255,255,0.3);
    --glass-blur: 16px;
    --accent-gp: #2563EB;
    --accent-intune: #7C3AED;
    --accent-sccm: #0D9488;
    --accent-wu: #EA580C;
    --accent-device: #64748B;
    --scrollbar-track: transparent;
    --scrollbar-thumb: rgba(0,0,0,0.15);
    --scrollbar-thumb-hover: rgba(0,0,0,0.28);
}

[data-theme="dark"] {
    --shadow-xs: 0 1px 2px rgba(0,0,0,0.2);
    --shadow-md: 0 6px 12px -2px rgba(0,0,0,0.35), 0 3px 6px -3px rgba(0,0,0,0.3);
    --shadow-xl: 0 20px 40px -8px rgba(0,0,0,0.5), 0 8px 16px -8px rgba(0,0,0,0.35);
    --glass-bg: rgba(15,15,26,0.72);
    --glass-border: rgba(255,255,255,0.08);
    --scrollbar-thumb: rgba(255,255,255,0.15);
    --scrollbar-thumb-hover: rgba(255,255,255,0.28);
}

/* 1. Frosted Glass Nav */
.sticky-nav {
    background: var(--glass-bg) !important;
    -webkit-backdrop-filter: blur(var(--glass-blur)) saturate(1.4);
    backdrop-filter: blur(var(--glass-blur)) saturate(1.4);
    border-bottom: 1px solid var(--glass-border);
}

/* 2. Card Hover — lift + shadow */
.dashboard-card {
    transition: transform 0.25s cubic-bezier(0.22,1,0.36,1), box-shadow 0.25s cubic-bezier(0.22,1,0.36,1);
    will-change: transform;
    cursor: pointer;
}
.dashboard-card:hover {
    transform: translateY(-3px) scale(1.005);
    box-shadow: var(--shadow-lg);
}
.dashboard-card:active {
    transform: translateY(-1px);
    box-shadow: var(--shadow-md);
}

/* 3. Table Row Hover — left accent via box-shadow (not ::before, which requires
   position:relative on tr and breaks alignment in border-collapse:collapse tables) */
[data-domain="gp"] table tbody tr:hover { background-color: rgba(37,99,235,0.04); box-shadow: inset 3px 0 0 var(--accent-gp); }
[data-domain="intune"] table tbody tr:hover { background-color: rgba(124,58,237,0.04); box-shadow: inset 3px 0 0 var(--accent-intune); }
[data-domain="sccm"] table tbody tr:hover { background-color: rgba(13,148,136,0.04); box-shadow: inset 3px 0 0 var(--accent-sccm); }
[data-domain="wu"] table tbody tr:hover { background-color: rgba(234,88,12,0.04); box-shadow: inset 3px 0 0 var(--accent-wu); }
[data-domain="device"] table tbody tr:hover { background-color: rgba(100,116,139,0.04); box-shadow: inset 3px 0 0 var(--accent-device); }
[data-theme="dark"] [data-domain="gp"] table tbody tr:hover { background-color: rgba(37,99,235,0.1); }
[data-theme="dark"] [data-domain="intune"] table tbody tr:hover { background-color: rgba(124,58,237,0.1); }
[data-theme="dark"] [data-domain="sccm"] table tbody tr:hover { background-color: rgba(13,148,136,0.1); }
[data-theme="dark"] [data-domain="wu"] table tbody tr:hover { background-color: rgba(234,88,12,0.1); }
[data-theme="dark"] [data-domain="device"] table tbody tr:hover { background-color: rgba(100,116,139,0.1); }

/* 4. Badge Animations */
@keyframes badge-pulse {
    0%, 100% { box-shadow: 0 0 0 0 rgba(220,53,69,0.35); }
    50% { box-shadow: 0 0 0 5px rgba(220,53,69,0); }
}
@keyframes badge-glow {
    0%, 100% { box-shadow: 0 0 4px rgba(40,167,69,0.15); }
    50% { box-shadow: 0 0 10px rgba(40,167,69,0.25); }
}
.badge-danger { animation: badge-pulse 2.2s ease-in-out infinite; }
.badge-success { animation: badge-glow 3s ease-in-out infinite; }

/* 5. Section Entrance Animation */
@keyframes section-enter {
    from { opacity: 0; transform: translateY(12px); }
    to { opacity: 1; transform: translateY(0); }
}
.tab-panel.active .section {
    animation: section-enter 0.35s cubic-bezier(0.22,1,0.36,1) both;
}
.tab-panel.active .section:nth-child(2) { animation-delay: 0.05s; }
.tab-panel.active .section:nth-child(3) { animation-delay: 0.10s; }
.tab-panel.active .section:nth-child(4) { animation-delay: 0.15s; }
.tab-panel.active .section:nth-child(5) { animation-delay: 0.20s; }
.tab-panel.active .section:nth-child(n+6) { animation-delay: 0.25s; }

/* 6. Progress Bar Component */
.progress-bar {
    display: flex;
    width: 100%;
    height: 8px;
    border-radius: 999px;
    overflow: hidden;
    background: var(--color-border);
    box-shadow: inset 0 1px 2px rgba(0,0,0,0.06);
}
.progress-bar-sm { height: 5px; }
.progress-bar-segment {
    height: 100%;
    transition: width 0.6s cubic-bezier(0.22,1,0.36,1);
    min-width: 0;
}
.progress-bar-segment:first-child { border-radius: 999px 0 0 999px; }
.progress-bar-segment:last-child { border-radius: 0 999px 999px 0; }
.progress-bar-segment:only-child { border-radius: 999px; }
.progress-bar-segment.success { background: var(--color-success); }
.progress-bar-segment.warning { background: var(--color-warning); }
.progress-bar-segment.danger { background: var(--color-danger); }
.progress-bar-segment.neutral { background: var(--color-muted); }

/* 7. Summary Strip Component */
.summary-strip {
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 16px;
    background: var(--color-bg-alt);
    border: 1px solid var(--color-border);
    border-radius: var(--radius-lg);
    margin-bottom: 12px;
    flex-wrap: wrap;
    box-shadow: var(--shadow-xs);
}
.summary-strip-total {
    font-size: 0.9rem;
    font-weight: 700;
    color: var(--color-text);
    white-space: nowrap;
    padding-right: 12px;
    border-right: 1px solid var(--color-border);
}
.summary-strip-total .count { font-size: 1.15rem; }
.summary-strip-stats {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
}
.summary-strip-stat {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.8rem;
    font-weight: 500;
    color: var(--color-text-muted);
    white-space: nowrap;
}
.summary-strip-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
}
.summary-strip-dot.success { background: var(--color-success); }
.summary-strip-dot.warning { background: var(--color-warning); }
.summary-strip-dot.danger { background: var(--color-danger); }
.summary-strip-dot.neutral { background: var(--color-muted); }
.summary-strip-progress {
    flex: 1;
    min-width: 80px;
    max-width: 220px;
}
[data-theme="dark"] .summary-strip {
    background: rgba(255,255,255,0.03);
    border-color: rgba(255,255,255,0.08);
}

/* 8. Custom Scrollbars */
::-webkit-scrollbar { width: 8px; height: 8px; }
::-webkit-scrollbar-track { background: var(--scrollbar-track); }
::-webkit-scrollbar-thumb {
    background: var(--scrollbar-thumb);
    border-radius: 999px;
    border: 2px solid transparent;
    background-clip: padding-box;
}
::-webkit-scrollbar-thumb:hover { background: var(--scrollbar-thumb-hover); border: 2px solid transparent; background-clip: padding-box; }
* { scrollbar-width: thin; scrollbar-color: var(--scrollbar-thumb) var(--scrollbar-track); }

/* ============================================================
   TAB NAVIGATION SYSTEM
   ============================================================ */
.tab-bar {
    display: flex;
    gap: 2px;
    padding: 8px 0 0 0;
    border-top: 1px solid var(--color-border);
    overflow-x: auto;
    scrollbar-width: none;
    -ms-overflow-style: none;
}
.tab-bar::-webkit-scrollbar { display: none; }

.tab-btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 10px 20px;
    border: none;
    border-bottom: 3px solid transparent;
    background: transparent;
    color: var(--color-text-muted);
    font-size: 0.9rem;
    font-weight: 500;
    cursor: pointer;
    white-space: nowrap;
    transition: color var(--transition), border-color var(--transition), background var(--transition);
    position: relative;
    border-radius: var(--radius) var(--radius) 0 0;
}
.tab-btn:hover {
    color: var(--color-text);
    background: var(--color-bg-alt);
}
.tab-btn.active {
    color: var(--color-info);
    border-bottom-color: var(--color-info);
    font-weight: 600;
}
.tab-btn-icon { font-size: 1rem; }
.tab-badge {
    background: rgba(0,123,255,0.15);
    color: var(--color-info);
    padding: 1px 7px;
    border-radius: 12px;
    font-size: 0.7rem;
    font-weight: 700;
    min-width: 20px;
    text-align: center;
}
.tab-btn.active .tab-badge {
    background: var(--color-info);
    color: white;
}
.tab-badge.has-errors { background: rgba(220,53,69,0.15); color: var(--color-danger); }
.tab-btn.active .tab-badge.has-errors { background: var(--color-danger); color: white; }
.tab-badge.has-warnings { background: rgba(255,193,7,0.15); color: #856404; }
.tab-status-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    position: absolute;
    top: 8px;
    right: 8px;
}
.tab-status-dot.error { background: var(--color-danger); }
.tab-status-dot.warning { background: var(--color-warning); }

/* Tab Panels */
.tab-panels { position: relative; }
.tab-panel {
    display: none;
    opacity: 0;
    transform: translateY(4px);
    transition: opacity 0.25s ease, transform 0.25s ease;
}
.tab-panel.active {
    display: block;
}
.tab-panel.visible {
    opacity: 1;
    transform: translateY(0);
}

/* Per-tab toolbar */
.tab-panel-toolbar {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    padding: 15px;
    background: var(--color-bg-alt);
    border-radius: var(--radius);
    margin-bottom: 20px;
    box-shadow: var(--shadow-sm);
}

/* Mobile tab dropdown */
.tab-mobile-select {
    display: none;
    width: 100%;
    padding: 10px 15px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius);
    font-size: 0.9rem;
    background: var(--color-bg);
    color: var(--color-text);
    margin-top: 8px;
}

@media (max-width: 768px) {
    .tab-bar { display: none; }
    .tab-mobile-select { display: block; }
}

/* Tab system print styles */
@media print {
    .tab-bar, .tab-mobile-select, .tab-panel-toolbar { display: none !important; }
    .tab-panel {
        display: block !important;
        opacity: 1 !important;
        transform: none !important;
    }
    .tab-panel::before {
        content: attr(data-tab-title);
        display: block;
        font-size: 16pt;
        font-weight: bold;
        margin: 20pt 0 10pt;
        padding-bottom: 5pt;
        border-bottom: 2pt solid #000;
    }
}


'@
}

function Get-DeviceDNAJavaScript {
    <#
    .SYNOPSIS
        Returns the JavaScript code for the HTML report
    #>
    [CmdletBinding()]
    param()

    return @'
// DeviceDNA Report JavaScript

// Global state
let policyData = null;
let sheetJSLoaded = false;

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', function() {
    // Parse embedded data
    const dataElement = document.getElementById('policy-data');
    if (dataElement) {
        try {
            policyData = JSON.parse(dataElement.textContent);
            initializeReport();
        } catch (e) {
            console.error('Failed to parse policy data:', e);
        }
    }

    // Initialize UI components
    initializeStickyNav();
    initializeCollapsibles();
    initializeTables();
    initializeTableEnhancements();
    renderDeviceOverviewDashboard();
    renderIssueSummary();
    initializeSearch();
    initializeTheme();
    initializeExport();
    initializePrintButton();
    initializePrintHandlers();
    initializeTabs();
    renderSummaryStrips();
});

function initializeReport() {
    if (!policyData) return;

    // Render all sections
    renderHeader();
    renderCollectionIssues();
    renderGroupPolicy();
    renderIntune();
}

// Collapsible sections
function initializeCollapsibles() {
    document.querySelectorAll('.section-header').forEach(header => {
        header.addEventListener('click', () => {
            const section = header.parentElement;
            section.classList.toggle('collapsed');
        });
    });
}

function expandAll() {
    // Scope to active tab panel if tabs are present
    const activePanel = document.querySelector('.tab-panel.active');
    const scope = activePanel || document;
    scope.querySelectorAll('.section').forEach(section => {
        section.classList.remove('collapsed');
    });
}

function collapseAll() {
    const activePanel = document.querySelector('.tab-panel.active');
    const scope = activePanel || document;
    scope.querySelectorAll('.section').forEach(section => {
        section.classList.add('collapsed');
    });
}

// Table functionality
function initializeTables() {
    // Sortable columns
    document.querySelectorAll('table thead th[data-sort]').forEach(th => {
        th.addEventListener('click', () => sortTable(th));
    });

    // Expandable rows
    document.querySelectorAll('.expandable-row').forEach(row => {
        row.addEventListener('click', (e) => {
            if (e.target.closest('.copy-btn')) return;
            toggleDetailRow(row);
        });
    });

    // Per-table search
    document.querySelectorAll('.table-search input').forEach(input => {
        input.addEventListener('input', (e) => {
            filterTable(e.target);
        });
    });
}

function sortTable(th) {
    // Handle status category sorting specially
    if (th.dataset.sort === 'statusCategory') {
        sortTableByStatus(th);
        return;
    }

    const table = th.closest('table');
    const tbody = table.querySelector('tbody');
    const rows = Array.from(tbody.querySelectorAll(':scope > tr:not(.detail-row)'));
    const colIndex = Array.from(th.parentElement.children).indexOf(th);
    const isAsc = th.classList.contains('sorted-asc');

    // Remove sort classes from all headers
    th.parentElement.querySelectorAll('th').forEach(h => {
        h.classList.remove('sorted-asc', 'sorted-desc');
    });

    // Sort rows
    rows.sort((a, b) => {
        const aVal = a.children[colIndex]?.textContent.trim() || '';
        const bVal = b.children[colIndex]?.textContent.trim() || '';

        // Try numeric sort first
        const aNum = parseFloat(aVal);
        const bNum = parseFloat(bVal);
        if (!isNaN(aNum) && !isNaN(bNum)) {
            return isAsc ? bNum - aNum : aNum - bNum;
        }

        // String sort
        return isAsc ? bVal.localeCompare(aVal) : aVal.localeCompare(bVal);
    });

    // Update class
    th.classList.add(isAsc ? 'sorted-desc' : 'sorted-asc');

    // Reorder rows (keeping detail rows with their parent)
    rows.forEach(row => {
        tbody.appendChild(row);
        const detailRow = document.getElementById('detail-' + row.dataset.id);
        if (detailRow) {
            tbody.appendChild(detailRow);
        }
    });
}

function toggleDetailRow(row) {
    const detailRow = document.getElementById('detail-' + row.dataset.id);
    if (detailRow) {
        const isExpanded = row.classList.toggle('expanded');
        detailRow.classList.toggle('visible');
        // Update ARIA attribute for accessibility
        row.setAttribute('aria-expanded', isExpanded);
    }
}

function filterTable(input) {
    const searchText = input.value.toLowerCase();
    const table = input.closest('.table-container').querySelector('table');
    const rows = table.querySelectorAll('tbody > tr:not(.detail-row)');

    rows.forEach(row => {
        const text = row.textContent.toLowerCase();
        const visible = text.includes(searchText);
        row.style.display = visible ? '' : 'none';

        // Also hide associated detail row
        const detailRow = document.getElementById('detail-' + row.dataset.id);
        if (detailRow) {
            detailRow.style.display = visible ? '' : 'none';
            if (!visible) {
                row.classList.remove('expanded');
                detailRow.classList.remove('visible');
            }
        }
    });
}

// Global search with debounce
function initializeSearch() {
    const globalSearch = document.getElementById('global-search');
    if (globalSearch) {
        let debounceTimer;
        globalSearch.addEventListener('input', (e) => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                const searchText = e.target.value.toLowerCase();

                document.querySelectorAll('.section').forEach(section => {
                    if (!searchText) {
                        section.style.display = '';
                        section.querySelectorAll('tbody > tr').forEach(row => {
                            row.style.display = '';
                        });
                        return;
                    }

                    let hasMatch = false;
                    section.querySelectorAll('tbody > tr:not(.detail-row)').forEach(row => {
                        const text = row.textContent.toLowerCase();
                        const visible = text.includes(searchText);
                        row.style.display = visible ? '' : 'none';
                        if (visible) hasMatch = true;

                        const detailRow = document.getElementById('detail-' + row.dataset.id);
                        if (detailRow) {
                            detailRow.style.display = visible ? '' : 'none';
                        }
                    });

                    // Check section header too
                    const headerText = section.querySelector('.section-header')?.textContent.toLowerCase() || '';
                    if (headerText.includes(searchText)) hasMatch = true;

                    section.style.display = hasMatch ? '' : 'none';
                });
            }, 250); // 250ms debounce delay
        });
    }
}

// Sticky Navigation
function initializeStickyNav() {
    // Mobile menu toggle
    const mobileToggle = document.getElementById('mobile-menu-toggle');
    const navLinks = document.querySelector('.nav-links');
    if (mobileToggle && navLinks) {
        mobileToggle.addEventListener('click', () => {
            navLinks.classList.toggle('mobile-open');
            const isOpen = navLinks.classList.contains('mobile-open');
            mobileToggle.textContent = isOpen ? '\u2715' : '\u2630';
        });
    }

    // Navigation links - smooth scroll
    document.querySelectorAll('.nav-link[data-section]').forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            const sectionId = link.dataset.section;
            scrollToSection(sectionId);

            // Close mobile menu
            if (navLinks) {
                navLinks.classList.remove('mobile-open');
                if (mobileToggle) mobileToggle.textContent = '\u2630';
            }
        });
    });

    // Submenu items
    document.querySelectorAll('.nav-submenu-item[data-section]').forEach(item => {
        item.addEventListener('click', (e) => {
            e.preventDefault();
            const sectionId = item.dataset.section;
            scrollToSection(sectionId);
        });
    });

    // Mobile submenu toggle
    if (window.innerWidth <= 768) {
        document.querySelectorAll('.nav-link.has-submenu').forEach(link => {
            link.addEventListener('click', (e) => {
                if (window.innerWidth <= 768) {
                    e.preventDefault();
                    link.classList.toggle('submenu-open');
                }
            });
        });
    }

    // Nav search (use existing global search logic)
    const navSearch = document.getElementById('nav-search');
    const globalSearch = document.getElementById('global-search');
    if (navSearch && globalSearch) {
        navSearch.addEventListener('input', (e) => {
            globalSearch.value = e.target.value;
            globalSearch.dispatchEvent(new Event('input'));
        });
    }

    // Quick filters
    const filterAll = document.getElementById('filter-all');
    const filterIssues = document.getElementById('filter-issues');
    const filterWarnings = document.getElementById('filter-warnings');

    if (filterAll) {
        filterAll.addEventListener('click', () => {
            clearFilters();
            filterAll.classList.add('active');
            filterIssues.classList.remove('active');
            filterWarnings.classList.remove('active');
        });
    }

    if (filterIssues) {
        filterIssues.addEventListener('click', () => {
            applyFilter('issues');
            filterAll.classList.remove('active');
            filterIssues.classList.add('active');
            filterWarnings.classList.remove('active');
        });
    }

    if (filterWarnings) {
        filterWarnings.addEventListener('click', () => {
            applyFilter('warnings');
            filterAll.classList.remove('active');
            filterIssues.classList.remove('active');
            filterWarnings.classList.add('active');
        });
    }

    // Update nav counts
    updateNavCounts();

    // Highlight active section on scroll
    let scrollTimeout;
    window.addEventListener('scroll', () => {
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(updateActiveNavLink, 100);
    });
}

function scrollToSection(sectionId) {
    const section = document.getElementById(sectionId);
    if (section) {
        // Switch to the correct tab if section is inside a tab panel
        const tabPanel = section.closest('.tab-panel');
        if (tabPanel && tabPanel.dataset.tab) {
            switchTab(tabPanel.dataset.tab);
        }

        // Expand section if collapsed
        section.classList.remove('collapsed');

        // Calculate offset for sticky nav
        const navHeight = document.querySelector('.sticky-nav') ? document.querySelector('.sticky-nav').offsetHeight : 0;
        const offset = section.offsetTop - navHeight - 10;

        setTimeout(() => {
            window.scrollTo({
                top: offset,
                behavior: 'smooth'
            });
        }, 50);
    }
}

function updateActiveNavLink() {
    const navHeight = document.querySelector('.sticky-nav')?.offsetHeight || 0;
    const scrollPos = window.scrollY + navHeight + 50;

    const sections = document.querySelectorAll('.section[id]');
    let activeSection = null;

    sections.forEach(section => {
        if (section.offsetTop <= scrollPos) {
            activeSection = section.id;
        }
    });

    // Update active nav link
    document.querySelectorAll('.nav-link[data-section]').forEach(link => {
        if (link.dataset.section === activeSection) {
            link.classList.add('active');
        } else {
            link.classList.remove('active');
        }
    });
}

function updateNavCounts() {
    if (!policyData) return;

    // Update counts in navigation
    const sections = {
        'device-info-section': 1,
        'gp-computer-section': policyData.groupPolicy?.computerScope?.appliedGPOs?.length || 0,
        'intune-groups-device-section': policyData.intune?.deviceGroups?.length || 0,
        'intune-profiles-section': policyData.intune?.configurationProfiles?.length || 0,
        'intune-apps-section': policyData.intune?.applications?.length || 0,
        'intune-compliance-section': policyData.intune?.compliancePolicies?.length || 0,
        'intune-scripts-section': policyData.intune?.proactiveRemediations?.length || 0
    };

    Object.keys(sections).forEach(sectionId => {
        const countElement = document.querySelector(`[data-section="${sectionId}"] .nav-link-count`);
        if (countElement) {
            const count = sections[sectionId];
            if (count > 0) {
                countElement.textContent = count;
            } else {
                countElement.style.display = 'none';
            }
        }
    });

    // Add error/warning indicators
    updateNavStatusIndicators();
}

function updateNavStatusIndicators() {
    if (!policyData) return;

    // Count issues and warnings in each section
    const indicators = {};

    // Collection issues (filtered by management type)
    if (policyData.collectionIssues?.length > 0) {
        const mgmtType = (policyData.deviceInfo?.managementType || '').toLowerCase();
        const relevantIssues = policyData.collectionIssues.filter(issue => {
            const phase = (issue.phase || '').toLowerCase();
            if (mgmtType === 'cloud-only' || mgmtType === 'azure ad joined') {
                if (phase === 'group policy' && issue.severity !== 'Error') return false;
            }
            if (mgmtType.startsWith('on-prem')) {
                if ((phase === 'intune' || phase === 'local intune') && issue.severity !== 'Error') return false;
            }
            return true;
        });
        const errors = relevantIssues.filter(i => i.severity === 'Error').length;
        const warnings = relevantIssues.filter(i => i.severity === 'Warning').length;
        if (errors > 0 || warnings > 0) {
            indicators['collection-issues-section'] = { errors, warnings };
        }
    }

    // Intune apps
    if (policyData.intune?.applications?.length > 0) {
        let errors = 0;
        let warnings = 0;
        policyData.intune.applications.forEach(app => {
            const status = (app.installState || '').toLowerCase();
            if (status.includes('failed') || status.includes('error')) errors++;
            else if (status.includes('pending') || status.includes('available')) warnings++;
        });
        if (errors > 0 || warnings > 0) {
            indicators['intune-apps-section'] = { errors, warnings };
        }
    }

    // Intune compliance
    if (policyData.intune?.compliancePolicies?.length > 0) {
        let errors = 0;
        let warnings = 0;
        policyData.intune.compliancePolicies.forEach(policy => {
            const status = (policy.complianceState || '').toLowerCase();
            if (status.includes('noncompliant') || status.includes('error')) errors++;
            else if (status.includes('conflict')) warnings++;
        });
        if (errors > 0 || warnings > 0) {
            indicators['intune-compliance-section'] = { errors, warnings };
        }
    }

    // Add indicators to nav links
    Object.keys(indicators).forEach(sectionId => {
        const link = document.querySelector(`[data-section="${sectionId}"]`);
        if (link) {
            let statusHtml = '<span class="nav-link-status">';
            if (indicators[sectionId].errors > 0) {
                statusHtml += `<span title="${indicators[sectionId].errors} errors" style="color:var(--color-danger)">\u{1F534} ${indicators[sectionId].errors}</span>`;
            }
            if (indicators[sectionId].warnings > 0) {
                statusHtml += ` <span title="${indicators[sectionId].warnings} warnings" style="color:var(--color-warning)">\u{1F7E1} ${indicators[sectionId].warnings}</span>`;
            }
            statusHtml += '</span>';

            const existing = link.querySelector('.nav-link-status');
            if (existing) {
                existing.remove();
            }
            link.insertAdjacentHTML('beforeend', statusHtml);
        }
    });
}

function applyFilter(filterType) {
    // Clear search
    const globalSearch = document.getElementById('global-search');
    const navSearch = document.getElementById('nav-search');
    if (globalSearch) globalSearch.value = '';
    if (navSearch) navSearch.value = '';

    document.querySelectorAll('.section').forEach(section => {
        section.style.display = '';

        let hasVisibleRows = false;
        section.querySelectorAll('tbody > tr:not(.detail-row)').forEach(row => {
            const badges = row.querySelectorAll('.badge');
            let visible = false;

            if (filterType === 'issues') {
                // Show rows with error/danger badges
                badges.forEach(badge => {
                    if (badge.classList.contains('badge-danger') ||
                        badge.textContent.toLowerCase().includes('failed') ||
                        badge.textContent.toLowerCase().includes('error') ||
                        badge.textContent.toLowerCase().includes('noncompliant')) {
                        visible = true;
                    }
                });
            } else if (filterType === 'warnings') {
                // Show rows with warning badges
                badges.forEach(badge => {
                    if (badge.classList.contains('badge-warning') ||
                        badge.textContent.toLowerCase().includes('pending') ||
                        badge.textContent.toLowerCase().includes('conflict')) {
                        visible = true;
                    }
                });
            }

            row.style.display = visible ? '' : 'none';
            if (visible) hasVisibleRows = true;

            // Hide detail row if parent hidden
            const detailRow = document.getElementById('detail-' + row.dataset.id);
            if (detailRow && !visible) {
                detailRow.style.display = 'none';
                row.classList.remove('expanded');
                detailRow.classList.remove('visible');
            }
        });

        // Hide section if no visible rows
        if (!hasVisibleRows && section.querySelector('table')) {
            section.style.display = 'none';
        }
    });
}

function clearFilters() {
    // Clear search
    const globalSearch = document.getElementById('global-search');
    const navSearch = document.getElementById('nav-search');
    if (globalSearch) globalSearch.value = '';
    if (navSearch) navSearch.value = '';

    // Show all sections and rows
    document.querySelectorAll('.section').forEach(section => {
        section.style.display = '';
        section.querySelectorAll('tbody > tr').forEach(row => {
            row.style.display = '';
        });
    });
}

// Theme toggle
function initializeTheme() {
    const savedTheme = localStorage.getItem('devicedna-theme');
    if (savedTheme === 'dark') {
        document.documentElement.setAttribute('data-theme', 'dark');
        updateThemeIcon();
    }
}

function toggleTheme() {
    const currentTheme = document.documentElement.getAttribute('data-theme');
    const newTheme = currentTheme === 'dark' ? 'light' : 'dark';

    if (newTheme === 'dark') {
        document.documentElement.setAttribute('data-theme', 'dark');
    } else {
        document.documentElement.removeAttribute('data-theme');
    }

    localStorage.setItem('devicedna-theme', newTheme);
    updateThemeIcon();
}

function updateThemeIcon() {
    const btn = document.querySelector('.theme-toggle');
    if (btn) {
        const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
        btn.textContent = isDark ? '\u2600\uFE0F' : '\uD83C\uDF19';
    }
}

// Copy to clipboard
function copyToClipboard(text, btn) {
    navigator.clipboard.writeText(text).then(() => {
        btn.classList.add('copied');
        const originalText = btn.textContent;
        btn.textContent = '\u2713';
        setTimeout(() => {
            btn.textContent = originalText;
            btn.classList.remove('copied');
        }, 1500);
    }).catch(err => {
        console.error('Copy failed:', err);
    });
}

// Export functionality
function initializeExport() {
    const exportBtn = document.querySelector('.export-dropdown .btn');
    const dropdown = document.querySelector('.export-dropdown');

    if (exportBtn && dropdown) {
        exportBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            dropdown.classList.toggle('open');
        });

        document.addEventListener('click', () => {
            dropdown.classList.remove('open');
        });
    }
}

// Print functionality
function initializePrintButton() {
    const printBtn = document.createElement('button');
    printBtn.className = 'print-btn';
    printBtn.setAttribute('aria-label', 'Print report');
    printBtn.setAttribute('title', 'Print this report');
    printBtn.innerHTML = `
        <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
            <path d="M11 0H5a2 2 0 0 0-2 2v3H1.5A1.5 1.5 0 0 0 0 6.5v4A1.5 1.5 0 0 0 1.5 12H3v2a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2v-2h1.5a1.5 1.5 0 0 0 1.5-1.5v-4A1.5 1.5 0 0 0 14.5 5H13V2a2 2 0 0 0-2-2zM5 1h6a1 1 0 0 1 1 1v3H4V2a1 1 0 0 1 1-1zm7 13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-3h8v3zm1-4H3V6.5a.5.5 0 0 1 .5-.5h9a.5.5 0 0 1 .5.5V10z"/>
        </svg>
        <span>Print</span>
    `;

    printBtn.addEventListener('click', function() {
        window.print();
    });

    document.body.appendChild(printBtn);
}

function initializePrintHandlers() {
    window.addEventListener('beforeprint', function() {
        // Expand all collapsed sections
        document.querySelectorAll('.section.collapsed').forEach(section => {
            section.classList.remove('collapsed');
            section.setAttribute('data-was-collapsed', 'true');
        });

        // Show all detail rows
        document.querySelectorAll('.detail-row').forEach(row => {
            if (!row.classList.contains('visible')) {
                row.classList.add('visible');
                row.setAttribute('data-was-hidden', 'true');
            }
        });
    });

    window.addEventListener('afterprint', function() {
        // Optionally restore collapsed state
        // Left empty for now - users may want to keep sections expanded after printing
    });
}

function getDeviceName() {
    return policyData?.deviceInfo?.name || 'Device';
}

function getTimestamp() {
    const date = new Date();
    return date.toISOString().slice(0, 10);
}

// Export to Markdown
function exportMarkdown() {
    if (!policyData) return;

    let md = `# DeviceDNA Report: ${escapeMarkdown(getDeviceName())}\n\n`;
    md += `**Generated:** ${policyData.metadata?.collectionTime || new Date().toISOString()}\n\n`;

    // Device Info
    const device = policyData.deviceInfo || {};
    md += `## Device Information\n\n`;
    md += `| Property | Value |\n|----------|-------|\n`;
    md += `| Name | ${escapeMarkdown(device.name || 'N/A')} |\n`;
    md += `| FQDN | ${escapeMarkdown(device.fqdn || 'N/A')} |\n`;
    md += `| OS | ${escapeMarkdown(device.osName || 'N/A')} ${escapeMarkdown(device.osVersion || '')} |\n`;
    md += `| Serial | ${escapeMarkdown(device.serialNumber || 'N/A')} |\n`;
    md += `| Join Type | ${escapeMarkdown(device.joinType || 'N/A')} |\n`;
    md += `| Management | ${escapeMarkdown(device.managementType || 'N/A')} |\n`;
    md += `| Tenant ID | ${escapeMarkdown(device.tenantId || 'N/A')} |\n\n`;

    // Collection Issues
    if (policyData.collectionIssues?.length > 0) {
        md += `## Collection Issues\n\n`;
        policyData.collectionIssues.forEach(issue => {
            md += `- **${escapeMarkdown(issue.severity)}** (${escapeMarkdown(issue.phase)}): ${escapeMarkdown(issue.message)}\n`;
        });
        md += '\n';
    }

    // Group Policy
    const gp = policyData.groupPolicy || {};
    if (gp.computerScope?.appliedGPOs?.length > 0) {
        md += `## Group Policy - Computer Scope\n\n`;
        md += `| Name | Link | Status |\n|------|------|--------|\n`;
        gp.computerScope.appliedGPOs.forEach(gpo => {
            md += `| ${escapeMarkdown(gpo.name || 'N/A')} | ${escapeMarkdown(gpo.link || 'N/A')} | ${escapeMarkdown(gpo.status || 'Applied')} |\n`;
        });
        md += '\n';
    }

    // Intune
    const intune = policyData.intune || {};

    if (intune.deviceGroups?.length > 0) {
        md += `## Entra ID - Device Groups\n\n`;
        md += `| Group Name | Type |\n|------------|------|\n`;
        intune.deviceGroups.forEach(g => {
            md += `| ${escapeMarkdown(g.displayName || g.name || 'N/A')} | ${escapeMarkdown(g.groupType || 'Security')} |\n`;
        });
        md += '\n';
    }

    if (intune.configurationProfiles?.length > 0) {
        md += `## Intune - Configuration Profiles\n\n`;
        md += `| Name | Type | Platform | Status |\n|------|------|----------|--------|\n`;
        intune.configurationProfiles.forEach(p => {
            md += `| ${escapeMarkdown(p.displayName || p.name || 'N/A')} | ${escapeMarkdown(p.profileType || p.policyType || 'N/A')} | ${escapeMarkdown(p.platform || 'N/A')} | ${escapeMarkdown(p.deploymentState || p.targetingStatus || 'N/A')} |\n`;
        });
        md += '\n';

        // Include settings for profiles that have them
        const profilesWithSettings = intune.configurationProfiles.filter(p => p.settings?.length > 0);
        if (profilesWithSettings.length > 0) {
            md += `### Profile Settings Detail\n\n`;
            profilesWithSettings.forEach(p => {
                md += `**${escapeMarkdown(p.displayName || p.name)}** (${p.settings.length} settings)\n\n`;
                md += `| Setting | Value |\n|---------|-------|\n`;
                p.settings.forEach(s => {
                    const val = String(s.value || '').substring(0, 200);
                    md += `| ${escapeMarkdown(s.name || 'Unknown')} | ${escapeMarkdown(val)} |\n`;
                });
                md += '\n';
            });
        }
    }

    if (intune.applications?.length > 0) {
        md += `## Intune - Applications\n\n`;
        md += `| Name | Type | Publisher | Intent | Installed |\n|------|------|-----------|--------|----------|\n`;
        intune.applications.forEach(a => {
            md += `| ${escapeMarkdown(a.displayName || a.name || 'N/A')} | ${escapeMarkdown(a.appType || 'N/A')} | ${escapeMarkdown(a.publisher || 'N/A')} | ${escapeMarkdown(a.intent || 'N/A')} | ${escapeMarkdown(a.appInstallState || 'Unknown')} |\n`;
        });
        md += '\n';
    }

    if (intune.compliancePolicies?.length > 0) {
        md += `## Intune - Compliance Policies\n\n`;
        md += `| Name | Platform | Status | State |\n|------|----------|--------|-------|\n`;
        intune.compliancePolicies.forEach(c => {
            md += `| ${escapeMarkdown(c.displayName || c.name || 'N/A')} | ${escapeMarkdown(c.platform || 'N/A')} | ${escapeMarkdown(c.targetingStatus || 'N/A')} | ${escapeMarkdown(c.complianceState || 'N/A')} |\n`;
        });
        md += '\n';
    }

    downloadFile(md, `DeviceDNA_${getDeviceName()}_${getTimestamp()}.md`, 'text/markdown');
}

function escapeMarkdown(text) {
    if (!text) return '';
    return String(text).replace(/[|\\`*_{}[\]()#+\-.!]/g, '\\$&');
}

// Export to CSV
function exportCSV() {
    if (!policyData) return;

    const sections = [];

    // Device Info
    const device = policyData.deviceInfo || {};
    sections.push({
        name: 'DeviceInfo',
        data: [{
            Name: device.name,
            FQDN: device.fqdn,
            OS: device.osName,
            OSVersion: device.osVersion,
            Serial: device.serialNumber,
            JoinType: device.joinType,
            Management: device.managementType,
            TenantID: device.tenantId,
            CurrentUser: device.currentUser
        }]
    });

    // Computer GPOs
    const gp = policyData.groupPolicy || {};
    if (gp.computerScope?.appliedGPOs?.length > 0) {
        sections.push({
            name: 'ComputerGPOs',
            data: gp.computerScope.appliedGPOs.map(g => ({
                Name: g.name,
                Link: g.link,
                Status: g.status || 'Applied',
                Order: g.order
            }))
        });
    }

    // Intune data
    const intune = policyData.intune || {};

    if (intune.deviceGroups?.length > 0) {
        sections.push({
            name: 'DeviceGroups',
            data: intune.deviceGroups.map(g => ({
                Name: g.displayName || g.name,
                Type: g.groupType,
                ID: g.id
            }))
        });
    }

    if (intune.configurationProfiles?.length > 0) {
        sections.push({
            name: 'ConfigProfiles',
            data: intune.configurationProfiles.map(p => ({
                Name: p.displayName || p.name,
                Type: p.profileType || p.policyType,
                Platform: p.platform,
                Status: p.deploymentState || p.targetingStatus,
                TargetGroups: (p.targetGroups || []).join('; '),
                SettingsCount: p.settings?.length || 0
            }))
        });

        // Separate sheet/section for profile settings detail
        const settingsRows = [];
        intune.configurationProfiles.forEach(p => {
            if (p.settings?.length > 0) {
                p.settings.forEach(s => {
                    settingsRows.push({
                        ProfileName: p.displayName || p.name,
                        ProfileType: p.profileType || p.policyType,
                        SettingName: s.name || 'Unknown',
                        Value: String(s.value || '').substring(0, 500)
                    });
                });
            }
        });
        if (settingsRows.length > 0) {
            sections.push({
                name: 'ProfileSettings',
                data: settingsRows
            });
        }
    }

    if (intune.applications?.length > 0) {
        sections.push({
            name: 'Applications',
            data: intune.applications.map(a => ({
                Name: a.displayName || a.name,
                Type: a.appType,
                Publisher: a.publisher,
                Intent: a.intent,
                TargetingStatus: a.targetingStatus,
                Installed: a.appInstallState || 'Unknown'
            }))
        });
    }

    if (intune.compliancePolicies?.length > 0) {
        sections.push({
            name: 'CompliancePolicies',
            data: intune.compliancePolicies.map(c => ({
                Name: c.displayName || c.name,
                Platform: c.platform,
                TargetingStatus: c.targetingStatus,
                ComplianceState: c.complianceState
            }))
        });
    }

    // Generate combined CSV with section headers
    let csv = '';
    sections.forEach(section => {
        if (section.data.length === 0) return;

        csv += `\n=== ${section.name} ===\n`;
        const headers = Object.keys(section.data[0]);
        csv += headers.map(h => escapeCSV(h)).join(',') + '\n';
        section.data.forEach(row => {
            csv += headers.map(h => escapeCSV(row[h])).join(',') + '\n';
        });
    });

    downloadFile(csv, `DeviceDNA_${getDeviceName()}_${getTimestamp()}.csv`, 'text/csv');
}

function escapeCSV(value) {
    if (value === null || value === undefined) return '';
    let str = String(value);

    // Prevent CSV formula injection - prefix cells starting with =, +, -, @ with a tab character
    if (str.length > 0 && /^[=+\-@]/.test(str)) {
        str = '\t' + str;
    }

    if (str.includes(',') || str.includes('"') || str.includes('\n')) {
        return '"' + str.replace(/"/g, '""') + '"';
    }
    return str;
}

// Export to JSON
function exportJSON() {
    if (!policyData) return;

    const json = JSON.stringify(policyData, null, 2);
    downloadFile(json, `DeviceDNA_${getDeviceName()}_${getTimestamp()}.json`, 'application/json');
}

// Export to XLSX using SheetJS
async function exportXLSX() {
    if (!policyData) return;

    const btn = document.querySelector('[onclick="exportXLSX()"]');
    if (btn) {
        btn.classList.add('loading');
        btn.disabled = true;
    }

    try {
        // Load SheetJS if not already loaded
        if (!sheetJSLoaded) {
            await loadSheetJS();
        }

        // Create workbook
        const wb = XLSX.utils.book_new();

        // Summary sheet
        const summaryData = [
            ['DeviceDNA Report'],
            [''],
            ['Device Name', policyData.deviceInfo?.name || 'N/A'],
            ['Collection Time', policyData.metadata?.collectionTime || 'N/A'],
            ['Collected By', policyData.metadata?.collectedBy || 'N/A'],
            ['Version', policyData.metadata?.version || 'N/A'],
            [''],
            ['Tenant ID', policyData.deviceInfo?.tenantId || 'N/A'],
            ['OS', (policyData.deviceInfo?.osName || '') + ' ' + (policyData.deviceInfo?.osVersion || '')],
            ['Join Type', policyData.deviceInfo?.joinType || 'N/A'],
            ['Management', policyData.deviceInfo?.managementType || 'N/A']
        ];
        const summarySheet = XLSX.utils.aoa_to_sheet(summaryData);
        XLSX.utils.book_append_sheet(wb, summarySheet, 'Summary');

        // Device Info sheet
        const device = policyData.deviceInfo || {};
        const deviceData = [
            ['Property', 'Value'],
            ['Name', device.name],
            ['FQDN', device.fqdn],
            ['OS Name', device.osName],
            ['OS Version', device.osVersion],
            ['Serial Number', device.serialNumber],
            ['Join Type', device.joinType],
            ['Management', device.managementType],
            ['Tenant ID', device.tenantId],
            ['Current User', device.currentUser]
        ];
        const deviceSheet = XLSX.utils.aoa_to_sheet(deviceData);
        XLSX.utils.book_append_sheet(wb, deviceSheet, 'Device Info');

        // Computer GPOs
        const gp = policyData.groupPolicy || {};
        if (gp.computerScope?.appliedGPOs?.length > 0) {
            const gpoData = [['Name', 'Link', 'Status', 'Order']];
            gp.computerScope.appliedGPOs.forEach(g => {
                gpoData.push([g.name, g.link, g.status || 'Applied', g.order]);
            });
            const gpoSheet = XLSX.utils.aoa_to_sheet(gpoData);
            XLSX.utils.book_append_sheet(wb, gpoSheet, 'Computer GPOs');
        }

        // Intune data
        const intune = policyData.intune || {};

        // Entra ID Device Groups
        if (intune.deviceGroups?.length > 0) {
            const groupData = [['Name', 'Type', 'ID']];
            intune.deviceGroups.forEach(g => {
                groupData.push([g.displayName || g.name, g.groupType, g.id]);
            });
            const groupSheet = XLSX.utils.aoa_to_sheet(groupData);
            XLSX.utils.book_append_sheet(wb, groupSheet, 'Entra ID Device Groups');
        }

        // Configuration Profiles
        if (intune.configurationProfiles?.length > 0) {
            const profileData = [['Name', 'Type', 'Platform', 'Assigned Via', 'Status', 'Settings Count', 'Target Groups']];
            intune.configurationProfiles.forEach(p => {
                profileData.push([
                    p.displayName || p.name,
                    p.policyType,
                    p.platform,
                    p.targetingStatus,
                    p.deploymentState || 'Unknown',
                    p.settings?.length || 0,
                    (p.targetGroups || []).join(', ')
                ]);
            });
            const profileSheet = XLSX.utils.aoa_to_sheet(profileData);
            XLSX.utils.book_append_sheet(wb, profileSheet, 'Config Profiles');

            // Profile Settings detail sheet
            const settingsData = [['Profile Name', 'Profile Type', 'Setting Name', 'Value']];
            intune.configurationProfiles.forEach(p => {
                if (p.settings?.length > 0) {
                    p.settings.forEach(s => {
                        settingsData.push([
                            p.displayName || p.name,
                            p.policyType,
                            s.name || 'Unknown',
                            String(s.value || '').substring(0, 500)
                        ]);
                    });
                }
            });
            if (settingsData.length > 1) {
                const settingsSheet = XLSX.utils.aoa_to_sheet(settingsData);
                XLSX.utils.book_append_sheet(wb, settingsSheet, 'Profile Settings');
            }
        }

        // Applications
        if (intune.applications?.length > 0) {
            const appData = [['Name', 'Version', 'Publisher', 'Type', 'Intent', 'Installed', 'Assigned Via']];
            intune.applications.forEach(a => {
                appData.push([
                    a.displayName || a.name,
                    a.appVersion || 'N/A',
                    a.publisher,
                    a.appType,
                    a.intent,
                    a.appInstallState || (a.installedOnDevice ? 'Installed' : 'Not Installed'),
                    a.targetingStatus
                ]);
            });
            const appSheet = XLSX.utils.aoa_to_sheet(appData);
            XLSX.utils.book_append_sheet(wb, appSheet, 'Applications');
        }

        // Compliance Policies
        if (intune.compliancePolicies?.length > 0) {
            const complianceData = [['Name', 'Platform', 'Assigned Via', 'Compliance State']];
            intune.compliancePolicies.forEach(c => {
                complianceData.push([
                    c.displayName || c.name,
                    c.platform,
                    c.targetingStatus,
                    c.complianceState
                ]);
            });
            const complianceSheet = XLSX.utils.aoa_to_sheet(complianceData);
            XLSX.utils.book_append_sheet(wb, complianceSheet, 'Compliance Policies');
        }

        // Collection Issues
        if (policyData.collectionIssues?.length > 0) {
            const issueData = [['Severity', 'Phase', 'Message']];
            policyData.collectionIssues.forEach(i => {
                issueData.push([i.severity, i.phase, i.message]);
            });
            const issueSheet = XLSX.utils.aoa_to_sheet(issueData);
            XLSX.utils.book_append_sheet(wb, issueSheet, 'Collection Issues');
        }

        // Download
        XLSX.writeFile(wb, `DeviceDNA_${getDeviceName()}_${getTimestamp()}.xlsx`);

    } catch (error) {
        console.error('XLSX export failed:', error);
        alert('Failed to export XLSX. Please try again or use another format.');
    } finally {
        if (btn) {
            btn.classList.remove('loading');
            btn.disabled = false;
        }
    }
}

function loadSheetJS() {
    return new Promise((resolve, reject) => {
        if (typeof XLSX !== 'undefined') {
            sheetJSLoaded = true;
            resolve();
            return;
        }

        const script = document.createElement('script');
        script.src = 'https://cdn.sheetjs.com/xlsx-0.20.0/package/dist/xlsx.mini.min.js';
        script.onload = () => {
            sheetJSLoaded = true;
            resolve();
        };
        script.onerror = () => {
            // Hide XLSX export button and show tooltip when CDN is unreachable
            const xlsxBtn = document.querySelector('.export-dropdown a[onclick*="exportXLSX"]');
            if (xlsxBtn) {
                xlsxBtn.style.display = 'none';
            }
            reject(new Error('Failed to load SheetJS library (CDN unreachable or offline)'));
        };
        document.head.appendChild(script);
    });
}

// Helper function to download file
function downloadFile(content, filename, mimeType) {
    const blob = new Blob([content], { type: mimeType });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// Render functions
function renderHeader() {
    // Header is rendered server-side, but we can update dynamic values here
}

function renderCollectionIssues() {
    const container = document.getElementById('collection-issues');
    if (!container || !policyData.collectionIssues?.length) {
        if (container) container.style.display = 'none';
        return;
    }

    // Filter out irrelevant issues based on management type
    const mgmtType = (policyData.deviceInfo?.managementType || '').toLowerCase();
    const filtered = policyData.collectionIssues.filter(issue => {
        const phase = (issue.phase || '').toLowerCase();
        const msg = (issue.message || '').toLowerCase();
        // Cloud-only: suppress GP-related info/warnings (no AD)
        if (mgmtType === 'cloud-only' || mgmtType === 'azure ad joined') {
            if (phase === 'group policy' && issue.severity !== 'Error') return false;
        }
        // On-prem only: suppress Intune-related info/warnings
        if (mgmtType.startsWith('on-prem')) {
            if ((phase === 'intune' || phase === 'local intune') && issue.severity !== 'Error') return false;
        }
        return true;
    });

    if (!filtered.length) {
        container.style.display = 'none';
        return;
    }

    let html = '';
    filtered.forEach(issue => {
        const iconMap = { Error: '\u274C', Warning: '\u26A0\uFE0F', Info: '\u2139\uFE0F' };
        const classMap = { Error: 'alert-danger', Warning: 'alert-warning', Info: 'alert-info' };

        html += `
            <div class="alert ${classMap[issue.severity] || 'alert-info'}">
                <span class="alert-icon">${iconMap[issue.severity] || '\u2139\uFE0F'}</span>
                <div>
                    <strong>${escapeHtml(issue.phase)}</strong>: ${escapeHtml(issue.message)}
                </div>
            </div>
        `;
    });

    container.innerHTML = html;
}

function renderGroupPolicy() {
    // GP sections are rendered server-side for better initial load
}

function renderIntune() {
    // Intune sections are rendered server-side for better initial load
}

// Utility function to escape HTML
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Get status badge HTML
function getStatusBadge(status) {
    const statusLower = (status || '').toLowerCase();
    let badgeClass = 'badge-muted';

    if (statusLower.includes('applied') || statusLower.includes('compliant') ||
        statusLower.includes('targeted') || statusLower.includes('installed') ||
        statusLower.includes('success')) {
        badgeClass = 'badge-success';
    } else if (statusLower.includes('warning') || statusLower.includes('pending')) {
        badgeClass = 'badge-warning';
    } else if (statusLower.includes('denied') || statusLower.includes('error') ||
               statusLower.includes('non-compliant') || statusLower.includes('failed')) {
        badgeClass = 'badge-danger';
    } else if (statusLower.includes('info')) {
        badgeClass = 'badge-info';
    }

    return `<span class="badge ${badgeClass}">${escapeHtml(status || 'Unknown')}</span>`;
}

// ===== TABLE ENHANCEMENTS =====

function initializeTableEnhancements() {
    updateAllStatusCounts();
    initializeFilterButtons();
    applyDefaultSort();
}

function updateAllStatusCounts() {
    document.querySelectorAll('.section-status-counts').forEach(countsEl => {
        const sectionName = countsEl.dataset.section;
        const tableContainer = document.querySelector(`.table-container[data-section="${sectionName}"]`);
        if (!tableContainer) return;

        const table = tableContainer.querySelector('table tbody');
        if (!table) return;

        const counts = { error: 0, warning: 0, success: 0, neutral: 0 };
        table.querySelectorAll(':scope > tr[data-status-category]:not(.detail-row)').forEach(row => {
            const category = row.dataset.statusCategory;
            if (counts.hasOwnProperty(category)) {
                counts[category]++;
            }
        });

        // Update error count (with null check)
        const errorEl = countsEl.querySelector('.status-count.error');
        if (errorEl) {
            errorEl.dataset.count = counts.error;
            const errorCountEl = errorEl.querySelector('.count');
            if (errorCountEl) errorCountEl.textContent = counts.error;
        }

        // Update warning count (with null check)
        const warningEl = countsEl.querySelector('.status-count.warning');
        if (warningEl) {
            warningEl.dataset.count = counts.warning;
            const warningCountEl = warningEl.querySelector('.count');
            if (warningCountEl) warningCountEl.textContent = counts.warning;
        }

        // Update success count (with null check)
        const successEl = countsEl.querySelector('.status-count.success');
        if (successEl) {
            successEl.dataset.count = counts.success;
            const successCountEl = successEl.querySelector('.count');
            if (successCountEl) successCountEl.textContent = counts.success;
        }
    });
}

function initializeFilterButtons() {
    document.querySelectorAll('.filter-btn').forEach(btn => {
        btn.addEventListener('click', function() {
            const container = this.closest('.table-container');
            const filter = this.dataset.filter;

            container.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
            this.classList.add('active');

            applyTableFilter(container, filter);
        });
    });
}

function applyTableFilter(container, filter) {
    const table = container.querySelector('table tbody');
    if (!table) return;

    table.querySelectorAll(':scope > tr:not(.detail-row)').forEach(row => {
        const category = row.dataset.statusCategory;
        let visible = (filter === 'all') || (filter === 'issues' && (category === 'error' || category === 'warning'));

        row.style.display = visible ? '' : 'none';

        const detailRow = document.getElementById('detail-' + row.dataset.id);
        if (detailRow) {
            detailRow.style.display = visible ? '' : 'none';
            if (!visible) {
                row.classList.remove('expanded');
                detailRow.classList.remove('visible');
            }
        }
    });
}

function applyDefaultSort() {
    // Sort all tables alphabetically by name column by default
    document.querySelectorAll('table thead th[data-sort="name"]').forEach(th => {
        const table = th.closest('table');
        const tbody = table.querySelector('tbody');
        const rows = Array.from(tbody.querySelectorAll(':scope > tr:not(.detail-row)'));

        // Sort alphabetically by name (case-insensitive)
        rows.sort((a, b) => {
            const aCell = a.querySelector('td:nth-child(' + (th.cellIndex + 1) + ')');
            const bCell = b.querySelector('td:nth-child(' + (th.cellIndex + 1) + ')');
            const aText = aCell?.textContent.trim() || '';
            const bText = bCell?.textContent.trim() || '';
            return aText.localeCompare(bText, undefined, { sensitivity: 'base' });
        });

        // Apply sorted-asc class to name header
        th.parentElement.querySelectorAll('th').forEach(h => {
            h.classList.remove('sorted-asc', 'sorted-desc');
        });
        th.classList.add('sorted-asc');

        // Reorder rows in DOM
        rows.forEach(row => {
            tbody.appendChild(row);
            const detailRow = document.getElementById('detail-' + row.dataset.id);
            if (detailRow) {
                tbody.appendChild(detailRow);
            }
        });
    });
}

function sortTableByStatus(th) {
    const table = th.closest('table');
    const tbody = table.querySelector('tbody');
    const rows = Array.from(tbody.querySelectorAll(':scope > tr:not(.detail-row)'));

    const statusOrder = { error: 1, warning: 2, success: 3, neutral: 4 };

    rows.sort((a, b) => {
        const aCategory = a.dataset.statusCategory || 'neutral';
        const bCategory = b.dataset.statusCategory || 'neutral';
        const aOrder = statusOrder[aCategory] || 999;
        const bOrder = statusOrder[bCategory] || 999;

        if (aOrder !== bOrder) {
            return aOrder - bOrder;
        }

        const aName = a.children[1]?.textContent.trim() || '';
        const bName = b.children[1]?.textContent.trim() || '';
        return aName.localeCompare(bName);
    });

    th.parentElement.querySelectorAll('th').forEach(h => {
        h.classList.remove('sorted-asc', 'sorted-desc');
    });
    th.classList.add('sorted-asc');

    rows.forEach(row => {
        tbody.appendChild(row);
        const detailRow = document.getElementById('detail-' + row.dataset.id);
        if (detailRow) {
            tbody.appendChild(detailRow);
        }
    });
}

// ===== ISSUE SUMMARY =====

function buildIssueSummary() {
    const issues = { critical: [], warnings: [] };

    // Scan all tables for issues
    document.querySelectorAll('table tbody > tr[data-status-category]').forEach(row => {
        const category = row.dataset.statusCategory;
        if (category !== 'error' && category !== 'warning') return;

        const cells = row.querySelectorAll('td');
        if (cells.length < 2) return;

        // Extract name (usually second column after status icon)
        const name = cells[1]?.textContent.trim() || 'Unknown';

        // Determine type from section
        const section = row.closest('.section');
        const sectionHeader = section?.querySelector('.section-header h2')?.textContent.trim() || '';
        let type = 'Item';
        let description = '';

        if (sectionHeader.includes('Applications')) {
            type = 'Application';
            // Get install state from badge
            const badge = row.querySelector('.badge');
            description = badge ? `Status: ${badge.textContent.trim()}` : 'Installation issue';
        } else if (sectionHeader.includes('Configuration Profiles')) {
            type = 'Configuration Profile';
            const badge = row.querySelector('.badge');
            description = badge ? `Deployment: ${badge.textContent.trim()}` : 'Deployment issue';
        } else if (sectionHeader.includes('Compliance')) {
            type = 'Compliance Policy';
            const badge = row.querySelector('.badge');
            description = badge ? `State: ${badge.textContent.trim()}` : 'Compliance issue';
        }

        // Get row ID for jump link
        const rowId = row.dataset.id || row.id || null;

        const issue = {
            name: name,
            type: type,
            description: description,
            targetId: rowId,
            category: category
        };

        if (category === 'error') {
            issues.critical.push(issue);
        } else if (category === 'warning') {
            issues.warnings.push(issue);
        }
    });

    return issues;
}

// Comprehensive Device Overview Dashboard Functions
function calculateComprehensiveMetrics() {
    const metrics = {
        // Device identity
        device: {
            hostname: policyData.deviceInfo?.hostname || 'Unknown',
            os: policyData.deviceInfo?.os?.name || 'Unknown',
            osVersion: policyData.deviceInfo?.os?.version || '',
            osBuild: policyData.deviceInfo?.os?.build || '',
            serial: policyData.deviceInfo?.serialNumber || 'Unknown',
            joinType: policyData.deviceInfo?.joinType || 'Unknown',
            managementType: policyData.deviceInfo?.managementType || 'Unknown',
            tenantId: policyData.intune?.tenantId || 'N/A',
            lastSync: policyData.intune?.lastSync || 'Never',
            collectionTime: policyData.metadata?.collectionTime || 'Unknown'
        },

        // Health & status
        health: {
            overall: 'good', // calculated below
            overallColor: 'success',
            complianceStatus: 'Unknown',
            complianceColor: 'neutral',
            issuesCount: 0,
            issuesColor: 'success',
            updatesPending: 0,
            updateSource: 'Unknown'
        },

        // Configuration categories
        groupPolicy: { total: 0, errors: 0, warnings: 0, success: 0 },
        intuneProfiles: { total: 0, errors: 0, warnings: 0, success: 0 },
        intuneApps: { total: 0, errors: 0, warnings: 0, success: 0 },
        compliance: { total: 0, errors: 0, warnings: 0, success: 0 },
        sccmBaselines: { total: 0, errors: 0, warnings: 0, success: 0 },
        sccmApps: { total: 0, errors: 0, warnings: 0, success: 0 },
        sccmUpdates: { total: 0, errors: 0, warnings: 0, success: 0 },
        windowsUpdate: { total: 0, pending: 0, failed: 0, installed: 0 }
    };

    // Count items from all sections
    document.querySelectorAll('table tbody > tr[data-status-category]').forEach(row => {
        const category = row.dataset.statusCategory;
        const section = row.closest('.section');
        const sectionId = section ? section.id : '';

        // Group Policy
        if (sectionId === 'gp-computer-section') {
            metrics.groupPolicy.total++;
            if (category === 'error') metrics.groupPolicy.errors++;
            else if (category === 'warning') metrics.groupPolicy.warnings++;
            else if (category === 'success') metrics.groupPolicy.success++;
        }
        // Intune Profiles
        else if (sectionId === 'intune-profiles-section') {
            metrics.intuneProfiles.total++;
            if (category === 'error') metrics.intuneProfiles.errors++;
            else if (category === 'warning') metrics.intuneProfiles.warnings++;
            else if (category === 'success') metrics.intuneProfiles.success++;
        }
        // Intune Apps
        else if (sectionId === 'intune-apps-section') {
            metrics.intuneApps.total++;
            if (category === 'error') metrics.intuneApps.errors++;
            else if (category === 'warning') metrics.intuneApps.warnings++;
            else if (category === 'success') metrics.intuneApps.success++;
        }
        // Compliance
        else if (sectionId === 'intune-compliance-section') {
            metrics.compliance.total++;
            if (category === 'error') metrics.compliance.errors++;
            else if (category === 'warning') metrics.compliance.warnings++;
            else if (category === 'success') metrics.compliance.success++;
        }
        // SCCM Baselines
        else if (sectionId === 'sccm-baselines-section') {
            metrics.sccmBaselines.total++;
            if (category === 'error') metrics.sccmBaselines.errors++;
            else if (category === 'warning') metrics.sccmBaselines.warnings++;
            else if (category === 'success') metrics.sccmBaselines.success++;
        }
        // SCCM Apps
        else if (sectionId === 'sccm-apps-section') {
            metrics.sccmApps.total++;
            if (category === 'error') metrics.sccmApps.errors++;
            else if (category === 'warning') metrics.sccmApps.warnings++;
            else if (category === 'success') metrics.sccmApps.success++;
        }
        // SCCM Updates
        else if (sectionId === 'sccm-updates-section') {
            metrics.sccmUpdates.total++;
            if (category === 'error') metrics.sccmUpdates.errors++;
            else if (category === 'warning') metrics.sccmUpdates.warnings++;
            else if (category === 'success') metrics.sccmUpdates.success++;
        }
    });

    // Windows Update data
    if (policyData.windowsUpdate?.summary) {
        metrics.windowsUpdate.pending = policyData.windowsUpdate.summary.pendingCount || 0;
        metrics.windowsUpdate.total = metrics.windowsUpdate.pending;
        metrics.health.updatesPending = metrics.windowsUpdate.pending;
        metrics.health.updateSource = policyData.windowsUpdate.summary.updateManagement || 'Unknown';
    }

    // Collection issues
    if (policyData.collectionIssues) {
        metrics.health.issuesCount = policyData.collectionIssues.length;
        const hasErrors = policyData.collectionIssues.some(i => i.severity === 'Error');
        const hasWarnings = policyData.collectionIssues.some(i => i.severity === 'Warning');
        if (hasErrors) metrics.health.issuesColor = 'error';
        else if (hasWarnings) metrics.health.issuesColor = 'warning';
    }

    // Compliance status
    if (policyData.intune?.compliancePolicies) {
        const policies = policyData.intune.compliancePolicies;
        const hasNonCompliant = policies.some(p => p.state && p.state.match(/nonCompliant|error/i));
        if (hasNonCompliant) {
            metrics.health.complianceStatus = 'Non-Compliant';
            metrics.health.complianceColor = 'error';
        } else if (policies.length > 0) {
            metrics.health.complianceStatus = 'Compliant';
            metrics.health.complianceColor = 'success';
        }
    }

    // Calculate overall health
    const totalErrors = metrics.groupPolicy.errors + metrics.intuneProfiles.errors +
                       metrics.intuneApps.errors + metrics.compliance.errors +
                       metrics.sccmBaselines.errors + metrics.sccmApps.errors + metrics.sccmUpdates.errors;
    const totalWarnings = metrics.groupPolicy.warnings + metrics.intuneProfiles.warnings +
                         metrics.intuneApps.warnings + metrics.compliance.warnings +
                         metrics.sccmBaselines.warnings + metrics.sccmApps.warnings + metrics.sccmUpdates.warnings;

    if (totalErrors > 0) {
        metrics.health.overall = 'critical';
        metrics.health.overallColor = 'error';
    } else if (totalWarnings > 0) {
        metrics.health.overall = 'warning';
        metrics.health.overallColor = 'warning';
    } else {
        metrics.health.overall = 'good';
        metrics.health.overallColor = 'success';
    }

    return metrics;
}

function renderDeviceOverviewDashboard() {
    const container = document.getElementById('executive-dashboard-container');
    if (!container) return;

    const m = calculateComprehensiveMetrics();

    const html = `
        <div class="device-overview-dashboard">
            <!-- Device Identity -->
            <div class="dashboard-section device-identity">
                <h2 class="dashboard-section-title">
                    <span class="section-icon">🧬</span>
                    Device DNA Report - ${m.device.hostname}
                </h2>
                <div class="identity-grid">
                    <div class="identity-item">
                        <label>Operating System</label>
                        <span>${m.device.os} ${m.device.osVersion}</span>
                        <small>Build ${m.device.osBuild}</small>
                    </div>
                    <div class="identity-item">
                        <label>Serial Number</label>
                        <span>${m.device.serial}</span>
                    </div>
                    <div class="identity-item">
                        <label>Join Type</label>
                        <span>${m.device.joinType}</span>
                    </div>
                    <div class="identity-item">
                        <label>Management</label>
                        <span>${m.device.managementType}</span>
                    </div>
                    <div class="identity-item">
                        <label>Tenant ID</label>
                        <span class="value-truncate">${m.device.tenantId}</span>
                    </div>
                    <div class="identity-item">
                        <label>Last Intune Sync</label>
                        <span>${m.device.lastSync}</span>
                    </div>
                    <div class="identity-item">
                        <label>Collection Time</label>
                        <span>${m.device.collectionTime}</span>
                    </div>
                </div>
            </div>

            <!-- Health & Status -->
            <div class="dashboard-section health-status">
                <h3 class="dashboard-subsection-title">Health & Status</h3>
                <div class="health-grid">
                    <div class="health-card status-${m.health.overallColor}">
                        <div class="health-icon">💚</div>
                        <div class="health-label">Overall Health</div>
                        <div class="health-value">${m.health.overall}</div>
                    </div>
                    <div class="health-card status-${m.health.complianceColor}">
                        <div class="health-icon">✓</div>
                        <div class="health-label">Compliance</div>
                        <div class="health-value">${m.health.complianceStatus}</div>
                    </div>
                    <div class="health-card status-${m.health.issuesColor}">
                        <div class="health-icon">⚠️</div>
                        <div class="health-label">Collection Issues</div>
                        <div class="health-value">${m.health.issuesCount}</div>
                    </div>
                    <div class="health-card status-${m.health.updatesPending > 0 ? 'warning' : 'success'}">
                        <div class="health-icon">🔄</div>
                        <div class="health-label">Updates Pending</div>
                        <div class="health-value">${m.health.updatesPending}</div>
                        <div class="health-source">Source: ${m.health.updateSource}</div>
                    </div>
                </div>
            </div>

            <!-- Configuration Summary -->
            <div class="dashboard-section config-summary">
                <h3 class="dashboard-subsection-title">Configuration Summary</h3>
                <div class="config-list">
                    ${renderConfigRow('📋', 'Group Policy', m.groupPolicy, 'gp')}
                    ${renderConfigRow('⚙️', 'Intune Profiles', m.intuneProfiles, 'intune')}
                    ${renderConfigRow('📦', 'Applications', {
                        total: m.intuneApps.total + m.sccmApps.total,
                        errors: m.intuneApps.errors + m.sccmApps.errors,
                        warnings: m.intuneApps.warnings + m.sccmApps.warnings,
                        success: m.intuneApps.success + m.sccmApps.success
                    }, 'intune')}
                    ${renderConfigRow('✓', 'Compliance Policies', m.compliance, 'intune')}
                    ${renderConfigRow('🛡️', 'SCCM Baselines', m.sccmBaselines, 'sccm')}
                    ${renderConfigRow('🔄', 'Windows Update', {
                        total: m.windowsUpdate.total,
                        errors: 0,
                        warnings: m.windowsUpdate.pending,
                        success: 0
                    }, 'wu')}
                </div>
            </div>
        </div>
    `;

    container.innerHTML = html;
}

function renderConfigRow(icon, title, metrics, tabId) {
    const total = metrics.total || 0;
    if (total === 0) return ''; // Don't show if no data

    const statusClass = metrics.errors > 0 ? 'error' : metrics.warnings > 0 ? 'warning' : 'success';

    return `
        <div class="config-row status-${statusClass}" data-tab="${tabId}" onclick="if(typeof switchTab === 'function') switchTab('${tabId}')">
            <div class="config-icon">${icon}</div>
            <div class="config-info">
                <div class="config-title">${title}</div>
                <div class="config-stats">
                    ${metrics.errors > 0 ? `<span class="stat-badge error">● ${metrics.errors} error${metrics.errors !== 1 ? 's' : ''}</span>` : ''}
                    ${metrics.warnings > 0 ? `<span class="stat-badge warning">● ${metrics.warnings} warning${metrics.warnings !== 1 ? 's' : ''}</span>` : ''}
                    ${metrics.success > 0 ? `<span class="stat-badge success">● ${metrics.success} applied</span>` : ''}
                </div>
            </div>
            <div class="config-total">${total}</div>
            <div class="config-arrow">›</div>
        </div>
    `;
}

function renderIssueSummary() {
    const container = document.getElementById('issue-summary-container');
    if (!container) return;

    const issues = buildIssueSummary();
    const totalIssues = issues.critical.length + issues.warnings.length;

    if (totalIssues === 0) {
        container.innerHTML = `
            <div class="issue-summary">
                <div class="issue-summary-header">
                    <h2>⚡ Issue Summary</h2>
                    <div class="summary-count">All systems operational</div>
                </div>
                <div class="issue-summary-body">
                    <div class="issue-empty-state">No issues found</div>
                </div>
            </div>
        `;
        return;
    }

    let html = `
        <div class="issue-summary">
            <div class="issue-summary-header">
                <h2>⚡ Issue Summary</h2>
                <div class="summary-count">Found ${issues.critical.length} critical issue${issues.critical.length !== 1 ? 's' : ''} and ${issues.warnings.length} warning${issues.warnings.length !== 1 ? 's' : ''}</div>
            </div>
            <div class="issue-summary-body">
    `;

    // Critical issues
    if (issues.critical.length > 0) {
        html += `
            <div class="issue-category">
                <div class="issue-category-header critical" onclick="toggleIssueCategory(this)">
                    <div class="issue-category-title">
                        <span class="icon">🔴</span>
                        <span>Critical Issues</span>
                        <span class="issue-category-count">${issues.critical.length}</span>
                    </div>
                    <span class="issue-category-toggle">▼</span>
                </div>
                <div class="issue-category-items">
        `;

        issues.critical.forEach(issue => {
            const jumpLink = issue.targetId ? `<a href="#" class="jump-link" onclick="jumpToIssue('${issue.targetId}'); return false;">View details</a>` : '';
            html += `
                <div class="issue-item">
                    <div class="issue-item-icon">🔴</div>
                    <div class="issue-item-content">
                        <div class="issue-item-name">${escapeHtml(issue.name)}</div>
                        <div class="issue-item-description">${issue.type} • ${escapeHtml(issue.description)}</div>
                    </div>
                    <div class="issue-item-action">${jumpLink}</div>
                </div>
            `;
        });

        html += `
                </div>
            </div>
        `;
    }

    // Warnings
    if (issues.warnings.length > 0) {
        html += `
            <div class="issue-category">
                <div class="issue-category-header warning" onclick="toggleIssueCategory(this)">
                    <div class="issue-category-title">
                        <span class="icon">⚠️</span>
                        <span>Warnings</span>
                        <span class="issue-category-count">${issues.warnings.length}</span>
                    </div>
                    <span class="issue-category-toggle">▼</span>
                </div>
                <div class="issue-category-items">
        `;

        issues.warnings.forEach(issue => {
            const jumpLink = issue.targetId ? `<a href="#" class="jump-link" onclick="jumpToIssue('${issue.targetId}'); return false;">View details</a>` : '';
            html += `
                <div class="issue-item">
                    <div class="issue-item-icon">⚠️</div>
                    <div class="issue-item-content">
                        <div class="issue-item-name">${escapeHtml(issue.name)}</div>
                        <div class="issue-item-description">${issue.type} • ${escapeHtml(issue.description)}</div>
                    </div>
                    <div class="issue-item-action">${jumpLink}</div>
                </div>
            `;
        });

        html += `
                </div>
            </div>
        `;
    }

    html += `
            </div>
        </div>
    `;

    container.innerHTML = html;
}

function toggleIssueCategory(header) {
    header.classList.toggle('collapsed');
}

function jumpToIssue(targetId) {
    const target = document.getElementById(targetId) || document.querySelector(`[data-id="${targetId}"]`);
    if (!target) return;

    // Switch to the correct tab if target is inside a tab panel
    const tabPanel = target.closest('.tab-panel');
    if (tabPanel && tabPanel.dataset.tab) {
        switchTab(tabPanel.dataset.tab);
    }

    // Expand parent section if collapsed
    const section = target.closest('.section');
    if (section) section.classList.remove('collapsed');

    // Small delay to let tab switch render, then scroll
    setTimeout(() => {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });

        // Expand if it's an expandable row
        if (target.classList.contains('expandable-row') && !target.classList.contains('expanded')) {
            target.click();
        }

        // Highlight effect
        target.style.transition = 'background-color 0.3s ease';
        const originalBg = target.style.backgroundColor;
        target.style.backgroundColor = 'rgba(102, 126, 234, 0.2)';
        setTimeout(() => {
            target.style.backgroundColor = originalBg;
        }, 2000);
    }, 100);
}

// =============================================================================
// TAB NAVIGATION SYSTEM
// =============================================================================

const TAB_CONFIG = {
    overview: {
        label: 'Overview',
        icon: '\u{1F4CA}',
        sections: ['executive-dashboard-container', 'issue-summary-container', 'collection-issues-section']
    },
    gp: {
        label: 'Group Policy',
        icon: '\u{1F4BB}',
        sections: ['gp-computer-section']
    },
    intune: {
        label: 'Intune',
        icon: '\u2699\uFE0F',
        sections: ['intune-groups-device-section', 'intune-profiles-section', 'intune-apps-section', 'intune-compliance-section', 'intune-scripts-section']
    },
    sccm: {
        label: 'SCCM',
        icon: '\u2699',
        sections: ['sccm-client-section', 'sccm-apps-section', 'sccm-baselines-section', 'sccm-updates-section', 'sccm-settings-section']
    },
    wu: {
        label: 'Windows Updates',
        icon: '\u{1F504}',
        sections: ['wu-summary-section', 'wu-policy-section', 'wu-pending-section', 'wu-history-section']
    },
    device: {
        label: 'Device',
        icon: '\u{1F4F1}',
        sections: ['device-info-section']
    }
};

let activeTab = 'overview';

function initializeTabs() {
    const tabBar = document.querySelector('.tab-bar');
    if (!tabBar) return;

    // Click handlers for tab buttons
    tabBar.querySelectorAll('.tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const tabId = btn.dataset.tab;
            if (tabId) switchTab(tabId);
        });
    });

    // Keyboard navigation (arrow keys within tab bar)
    tabBar.addEventListener('keydown', (e) => {
        const tabs = Array.from(tabBar.querySelectorAll('.tab-btn'));
        const current = tabs.findIndex(t => t.classList.contains('active'));
        let next = -1;

        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            next = (current + 1) % tabs.length;
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            next = (current - 1 + tabs.length) % tabs.length;
        } else if (e.key === 'Home') {
            next = 0;
        } else if (e.key === 'End') {
            next = tabs.length - 1;
        }

        if (next >= 0) {
            e.preventDefault();
            tabs[next].focus();
            switchTab(tabs[next].dataset.tab);
        }
    });

    // Mobile tab select handler
    const mobileSelect = document.getElementById('tab-mobile-select');
    if (mobileSelect) {
        mobileSelect.addEventListener('change', (e) => {
            switchTab(e.target.value);
        });
    }

    // Determine initial tab from URL hash or localStorage
    const initialTab = getInitialTab();
    switchTab(initialTab, false);

    // Update badge counts after data is loaded
    updateTabBadges();
}

function switchTab(tabId, updateHistory) {
    if (!TAB_CONFIG[tabId]) return;
    if (updateHistory === undefined) updateHistory = true;

    activeTab = tabId;

    // Update tab buttons
    document.querySelectorAll('.tab-btn').forEach(btn => {
        const isActive = btn.dataset.tab === tabId;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-selected', isActive);
        btn.setAttribute('tabindex', isActive ? '0' : '-1');
    });

    // Show/hide tab panels
    document.querySelectorAll('.tab-panel').forEach(panel => {
        const isActive = panel.dataset.tab === tabId;
        panel.classList.toggle('active', isActive);
        panel.classList.toggle('visible', isActive);
        panel.hidden = !isActive;
    });

    // Update mobile select
    const mobileSelect = document.getElementById('tab-mobile-select');
    if (mobileSelect) mobileSelect.value = tabId;

    // Persist to URL hash and localStorage
    if (updateHistory) {
        history.replaceState(null, '', '#' + tabId);
    }
    try { localStorage.setItem('devicedna-active-tab', tabId); } catch(e) {}

    // Scroll to top of content area
    const container = document.querySelector('.container');
    if (container && updateHistory) {
        window.scrollTo({ top: container.offsetTop - 60, behavior: 'smooth' });
    }
}

function getInitialTab() {
    // Check URL hash first
    const hash = window.location.hash.replace('#', '');
    if (hash && TAB_CONFIG[hash]) return hash;

    // Then localStorage
    try {
        const saved = localStorage.getItem('devicedna-active-tab');
        if (saved && TAB_CONFIG[saved]) return saved;
    } catch(e) {}

    return 'overview';
}

function updateTabBadges() {
    document.querySelectorAll('.tab-btn').forEach(btn => {
        const tabId = btn.dataset.tab;
        const config = TAB_CONFIG[tabId];
        if (!config) return;

        let totalItems = 0;
        let hasIssues = false;

        config.sections.forEach(sectionId => {
            const section = document.getElementById(sectionId);
            if (!section) return;

            // Count table rows (scope to main table only, not nested sub-tables)
            const mainTable = section.querySelector('.table-container > table');
            if (mainTable) {
                const mainTbody = mainTable.querySelector('tbody');
                if (mainTbody) {
                    const rows = mainTbody.querySelectorAll(':scope > tr:not(.detail-row)');
                    totalItems += rows.length;
                }
            }

            // Check for error/warning status
            const errorRows = section.querySelectorAll('tr[data-status-category="error"]');
            const warningRows = section.querySelectorAll('tr[data-status-category="warning"]');
            if (errorRows.length > 0 || warningRows.length > 0) hasIssues = true;

            // Check for collection issues (overview tab)
            const alerts = section.querySelectorAll('.alert-danger, .alert-warning');
            if (alerts.length > 0) hasIssues = true;
        });

        // Update badge
        const badge = btn.querySelector('.tab-badge');
        if (badge && totalItems > 0) {
            badge.textContent = totalItems;
            badge.style.display = '';
        } else if (badge) {
            badge.style.display = 'none';
        }

        // Update status dot
        const dot = btn.querySelector('.tab-status-dot');
        if (dot) {
            dot.className = 'tab-status-dot' + (hasIssues ? ' has-issues' : '');
        }
    });
}


// =============================================================================
// SUMMARY STRIPS
// =============================================================================

function renderSummaryStrips() {
    // Find all table containers with data-section attributes that have status-categorized rows
    document.querySelectorAll('.table-container[data-section]').forEach(container => {
        const rows = container.querySelectorAll('tbody > tr[data-status-category]');
        if (rows.length === 0) return;

        // Count statuses
        let counts = { error: 0, warning: 0, success: 0, neutral: 0 };
        rows.forEach(row => {
            const cat = row.dataset.statusCategory || 'neutral';
            if (counts[cat] !== undefined) counts[cat]++;
        });

        const total = rows.length;

        // Build the strip
        const strip = document.createElement('div');
        strip.className = 'summary-strip';

        let statsHtml = '';
        if (counts.error > 0) {
            statsHtml += '<span class="summary-strip-stat"><span class="summary-strip-dot danger"></span>' + counts.error + ' Error' + (counts.error !== 1 ? 's' : '') + '</span>';
        }
        if (counts.warning > 0) {
            statsHtml += '<span class="summary-strip-stat"><span class="summary-strip-dot warning"></span>' + counts.warning + ' Warning' + (counts.warning !== 1 ? 's' : '') + '</span>';
        }
        if (counts.success > 0) {
            statsHtml += '<span class="summary-strip-stat"><span class="summary-strip-dot success"></span>' + counts.success + ' OK</span>';
        }
        if (counts.neutral > 0) {
            statsHtml += '<span class="summary-strip-stat"><span class="summary-strip-dot neutral"></span>' + counts.neutral + ' N/A</span>';
        }

        // Build progress bar segments
        let progressHtml = '<div class="progress-bar progress-bar-sm">';
        if (total > 0) {
            if (counts.success > 0) progressHtml += '<div class="progress-bar-segment success" style="width:' + (counts.success / total * 100) + '%"></div>';
            if (counts.warning > 0) progressHtml += '<div class="progress-bar-segment warning" style="width:' + (counts.warning / total * 100) + '%"></div>';
            if (counts.error > 0) progressHtml += '<div class="progress-bar-segment danger" style="width:' + (counts.error / total * 100) + '%"></div>';
            if (counts.neutral > 0) progressHtml += '<div class="progress-bar-segment neutral" style="width:' + (counts.neutral / total * 100) + '%"></div>';
        }
        progressHtml += '</div>';

        strip.innerHTML =
            '<div class="summary-strip-total"><span class="count">' + total + '</span> total</div>' +
            '<div class="summary-strip-stats">' + statsHtml + '</div>' +
            '<div class="summary-strip-progress">' + progressHtml + '</div>';

        // Insert before the table
        const table = container.querySelector('table');
        if (table) {
            container.insertBefore(strip, table);
        }
    });
}

'@
}

function Get-StatusCategory {
    <#
    .SYNOPSIS
        Determines status category for sorting and visual indicators
    .PARAMETER Status
        Status string to categorize
    .OUTPUTS
        String: 'error', 'warning', 'success', or 'neutral'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Status
    )

    $statusLower = (Coalesce $Status '').ToLower()

    if ($statusLower -match 'denied|error|non-compliant|noncompliant|failed') {
        return 'error'
    } elseif ($statusLower -match 'warning|pending|conflict') {
        return 'warning'
    } elseif ($statusLower -match 'applied|compliant|targeted|installed|succeeded|success') {
        return 'success'
    } else {
        return 'neutral'
    }
}

function Export-DeviceDNAJson {
    <#
    .SYNOPSIS
        Exports DeviceDNA data to JSON format for use with the template
    .DESCRIPTION
        Converts the collected DeviceDNA data hashtable to JSON and saves it to a file.
        The JSON structure matches what the client-side render functions expect.
    .PARAMETER Data
        Hashtable containing all collected DeviceDNA data
    .PARAMETER OutputPath
        Directory path where the JSON file will be saved
    .PARAMETER DeviceName
        Device name used in the filename
    .EXAMPLE
        $jsonPath = Export-DeviceDNAJson -Data $collectedData -OutputPath "C:\Reports" -DeviceName "PC001"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # Generate filename with timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $sanitizedDeviceName = $DeviceName -replace '[^\w\-]', '_'
    $filename = "DeviceDNA_${sanitizedDeviceName}_${timestamp}.json"
    $fullPath = Join-Path -Path $OutputPath -ChildPath $filename

    # Add export metadata
    $jsonData = @{
        exportDate = Get-Date -Format "o"
        version = "0.2.0"
        deviceInfo = $Data.deviceInfo
        summary = $Data.summary
        metadata = $Data.metadata
        intune = $Data.intune
        groupPolicy = $Data.groupPolicy
        sccm = $Data.sccm
        windowsUpdate = $Data.windowsUpdate
        collectionIssues = $Data.collectionIssues
    }

    # Convert to JSON with deep nesting support
    try {
        $json = ConvertTo-SafeJson -Data $jsonData
        $json | Out-File -FilePath $fullPath -Encoding UTF8 -Force
        Write-DeviceDNALog -Message "JSON data exported to: $fullPath" -Component "Export-DeviceDNAJson" -Type 1
        return $fullPath
    } catch {
        Write-DeviceDNALog -Message "Failed to export JSON: $_" -Component "Export-DeviceDNAJson" -Type 3
        throw
    }
}

function Copy-DeviceDNATemplate {
    <#
    .SYNOPSIS
        Returns the path to the DeviceDNA HTML viewer in the repo/base output directory.
    .DESCRIPTION
        Locates DeviceDNA-Viewer.html in the base output directory (parent of the output folder).
        The viewer is committed to the repo root and shared by all devices.
    .PARAMETER OutputPath
        Device-specific output directory path (e.g., "C:\output\PC001")
    .EXAMPLE
        $templatePath = Copy-DeviceDNATemplate -OutputPath "C:\Reports\PC001"
        # Returns "C:\Reports\DeviceDNA-Viewer.html"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    # Ensure output directory exists (device folder)
    if (-not (Test-Path -Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # Get output root and base output directory
    # OutputPath is typically <base>\output\<DeviceName>
    $outputRoot = Split-Path -Parent $OutputPath
    $baseOutputRoot = Split-Path -Parent $outputRoot

    # Viewer is committed at the repo/base output root
    $viewerFileName = "DeviceDNA-Viewer.html"
    $viewerPath = Join-Path -Path $baseOutputRoot -ChildPath $viewerFileName

    if (-not (Test-Path -Path $viewerPath)) {
        Write-DeviceDNALog -Message "HTML viewer not found at: $viewerPath" -Component "Copy-DeviceDNATemplate" -Type 2
    } else {
        Write-DeviceDNALog -Message "HTML viewer found: $viewerFileName" -Component "Copy-DeviceDNATemplate" -Type 1
    }

    return $viewerPath
}

function New-DeviceDNAReport {
    <#
    .SYNOPSIS
        Generates DeviceDNA report using template + JSON architecture
    .DESCRIPTION
        Exports DeviceDNA data to JSON format and copies the report template files to the output directory.
        The report is rendered client-side in the browser by loading the JSON data into the template.

        NOTE: This function was completely rewritten for v0.2.0 to use a separate template + JSON
        architecture instead of embedded HTML generation. The old ~2000 line implementation that
        generated embedded HTML has been replaced with this ~50 line version that just exports
        JSON and copies template files.
    .PARAMETER Data
        Hashtable containing all collected DeviceDNA data
    .PARAMETER OutputPath
        Directory path where the report files will be saved
    .PARAMETER DeviceName
        Device name used in the filename
    .EXAMPLE
        $result = New-DeviceDNAReport -Data $collectedData -OutputPath "C:\Reports\PC001" -DeviceName "PC001"
        # Returns hashtable: @{ JsonPath = "..."; TemplatePath = "..."; ReportUrl = "..." }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    Write-DeviceDNALog -Message "Generating DeviceDNA report using template + JSON architecture" -Component "New-DeviceDNAReport" -Type 1

    # Export JSON data
    try {
        Write-StatusMessage "Exporting JSON data..." -Type Progress
        $jsonPath = Export-DeviceDNAJson -Data $Data -OutputPath $OutputPath -DeviceName $DeviceName
        Write-StatusMessage "JSON exported: $(Split-Path -Leaf $jsonPath)" -Type Success
    } catch {
        Write-DeviceDNALog -Message "JSON export failed: $_" -Component "New-DeviceDNAReport" -Type 3
        throw
    }

    # Copy template files
    try {
        Write-StatusMessage "Copying report template..." -Type Progress
        $templatePath = Copy-DeviceDNATemplate -OutputPath $OutputPath
        Write-StatusMessage "Template copied: $(Split-Path -Leaf $templatePath)" -Type Success
    } catch {
        Write-DeviceDNALog -Message "Template copy failed: $_" -Component "New-DeviceDNAReport" -Type 3
        throw
    }

    # Construct report URL (viewer is in base dir, data is in output/device subfolder)
    $jsonFileName = Split-Path -Leaf $jsonPath
    $deviceFolderName = Split-Path -Leaf $OutputPath
    $reportUrl = "../../DeviceDNA-Viewer.html?data=output/$deviceFolderName/$jsonFileName"

    Write-DeviceDNALog -Message "Report generated successfully: $reportUrl" -Component "New-DeviceDNAReport" -Type 1

    # Return hashtable with all paths (for backward compatibility, also return templatePath as string)
    # When cast to string (e.g., in "if ($reportPath)"), the hashtable will be truthy
    $result = @{
        JsonPath = $jsonPath
        TemplatePath = $templatePath
        ReportUrl = $reportUrl
        # For backward compatibility with code that expects a string path
        ToString = { $this.TemplatePath }
    }

    # Add ScriptMethod to make it behave like a string when needed
    $result.PSObject.TypeNames.Insert(0, 'DeviceDNA.ReportResult')

    return $result
}

# OLD IMPLEMENTATION NOTE:
# The previous implementation (~2000 lines) generated embedded HTML with all CSS, JavaScript,
# and data inline. It has been replaced with the above ~50 line implementation that uses
# a separate template + JSON architecture for better maintainability and faster iteration.
# If needed for reference, see git history before this commit.

function New-DeviceDNAReadme {
    <#
    .SYNOPSIS
        Generates a README.md file for the Device DNA scan output
    .DESCRIPTION
        Creates a markdown README with device info, collection summary, and links to reports.
        This README displays by default when the output folder is viewed in GitHub/repos.
    .PARAMETER Data
        Hashtable containing all collected DeviceDNA data
    .PARAMETER OutputPath
        Directory path where the README will be saved
    .PARAMETER DeviceName
        Device name for the report
    .PARAMETER HtmlFileName
        Name of the HTML report file (for linking)
    .PARAMETER JsonFileName
        Name of the JSON data file (for linking)
    .PARAMETER LogFileName
        Name of the log file (for linking)
    .EXAMPLE
        New-DeviceDNAReadme -Data $collectionData -OutputPath $deviceOutputPath -DeviceName $hostname -HtmlFileName "report.html"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$DeviceName,

        [Parameter()]
        [string]$HtmlFileName,

        [Parameter()]
        [string]$JsonFileName,

        [Parameter()]
        [string]$LogFileName
    )

    # Extract data
    $deviceInfo = $Data.deviceInfo
    $metadata = $Data.metadata
    $collectionIssues = $Data.collectionIssues
    $gp = $Data.groupPolicy
    $intune = $Data.intune
    $sccm = $Data.sccm
    $wu = $Data.windowsUpdate

    # Determine compliance status
    $complianceStatus = "Unknown"
    $complianceColor = "gray"
    if ($intune.compliancePolicies) {
        $complianceStates = @($intune.compliancePolicies | Where-Object { $_.state -ne $null })
        if ($complianceStates.Count -gt 0) {
            $hasError = $complianceStates | Where-Object { $_.state -match 'nonCompliant|error' }
            if ($hasError) {
                $complianceStatus = "❌ Non-Compliant"
            } else {
                $complianceStatus = "✅ Compliant"
            }
        }
    }

    # Count items
    $gpCount = if ($gp.computerScope.appliedGPOs) { $gp.computerScope.appliedGPOs.Count } else { 0 }
    $intuneProfileCount = if ($intune.configurationProfiles) { $intune.configurationProfiles.Count } else { 0 }
    $intuneAppCount = if ($intune.applications) { $intune.applications.Count } else { 0 }
    $remediationCount = if ($intune.proactiveRemediations) { $intune.proactiveRemediations.Count } else { 0 }
    $sccmAppCount = if ($sccm.applications) { $sccm.applications.Count } else { 0 }
    $sccmBaselineCount = if ($sccm.baselines) { $sccm.baselines.Count } else { 0 }
    $sccmUpdateCount = if ($sccm.softwareUpdates) { $sccm.softwareUpdates.Count } else { 0 }
    $wuPendingCount = if ($wu.summary.pendingCount) { $wu.summary.pendingCount } else { 0 }
    $issuesCount = if ($collectionIssues) { $collectionIssues.Count } else { 0 }

    # Build markdown
    $markdown = @"
# 🧬 Device DNA Report - $DeviceName

> Collected on **$($metadata.collectionTime)**
> Device DNA Version: **$($metadata.version)**

---

## 📊 Device Information

| Property | Value |
|----------|-------|
| **Hostname** | $($deviceInfo.hostname) |
| **Operating System** | $($deviceInfo.os.name) $($deviceInfo.os.version) ($($deviceInfo.os.build)) |
| **Serial Number** | $($deviceInfo.serialNumber) |
| **Join Type** | $($deviceInfo.joinType) |
| **Management Type** | $($deviceInfo.managementType) |
| **Compliance Status** | $complianceStatus |
| **Last Intune Sync** | $($intune.lastSync) |

---

## 📋 Collection Summary

### Group Policy
- **Applied GPOs (Computer)**: $gpCount

### Microsoft Intune
- **Configuration Profiles**: $intuneProfileCount
- **Applications**: $intuneAppCount
- **Proactive Remediations**: $remediationCount

### SCCM / Configuration Manager
- **Deployed Applications**: $sccmAppCount
- **Compliance Baselines**: $sccmBaselineCount
- **Software Updates**: $sccmUpdateCount

### Windows Update
- **Management Source**: $($wu.summary.updateManagement)
- **Pending Updates**: $wuPendingCount

---

## 🔍 Collection Issues

"@

    if ($issuesCount -gt 0) {
        $markdown += "**$issuesCount issue(s) detected during collection**`n`n"
        $markdown += "| Severity | Phase | Message |`n"
        $markdown += "|----------|-------|---------|`n"
        foreach ($issue in $collectionIssues) {
            $severity = $issue.severity
            $icon = switch ($severity) {
                "Error" { "❌" }
                "Warning" { "⚠️" }
                default { "ℹ️" }
            }
            $markdown += "| $icon $severity | $($issue.phase) | $($issue.message) |`n"
        }
        $markdown += "`n"
    } else {
        $markdown += "✅ **No issues detected**`n`n"
    }

    $markdown += "---`n`n"

    # Files section
    $markdown += "## 📁 Output Files`n`n"

    if ($HtmlFileName) {
        $markdown += "### 📄 [Interactive HTML Report]($HtmlFileName)`n"
        $markdown += "Self-contained interactive report with filtering, search, and export capabilities.`n`n"
    }

    if ($JsonFileName) {
        $markdown += "### 📊 [Raw JSON Data]($JsonFileName)`n"
        $markdown += "Complete collected data in JSON format for programmatic analysis.`n`n"
    }

    if ($LogFileName) {
        $markdown += "### 📋 [CMTrace Log File]($LogFileName)`n"
        $markdown += "Detailed collection log in CMTrace/OneTrace compatible format.`n`n"
    }

    $markdown += "---`n`n"

    # Footer
    $markdown += "## ℹ️ About Device DNA`n`n"
    $markdown += "Device DNA collects Group Policy, Microsoft Intune, and SCCM/ConfigMgr configuration data from Windows devices and generates comprehensive reports.`n`n"
    $markdown += "**Repository**: [Device DNA on GitHub](https://github.com/8bits1beard-io/Device-DNA)`n`n"
    $markdown += "**Author**: Joshua Walderbach`n`n"
    $markdown += "---`n`n"
    $markdown += "*Generated by Device DNA v$($metadata.version)*`n"

    # Write to file
    $readmePath = Join-Path -Path $OutputPath -ChildPath "README.md"
    $markdown | Out-File -FilePath $readmePath -Encoding UTF8 -Force

    Write-DeviceDNALog -Message "README.md generated: $readmePath" -Component "New-DeviceDNAReadme" -Type 1

    return $readmePath
}

#endregion
