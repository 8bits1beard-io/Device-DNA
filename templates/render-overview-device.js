// =============================================================================
// OVERVIEW TAB & DEVICE TAB RENDER FUNCTIONS
// =============================================================================
// This module contains JavaScript render functions for the Overview and Device
// tabs in the DeviceDNA report template.
//
// NOTE: renderExecutiveDashboard() and renderIssueSummary() are already
// implemented in the main JavaScript. This file documents their structure and
// provides the renderCollectionIssues() and renderDeviceInfo() functions.
//
// Dependencies:
// - Global deviceData object (parsed from embedded JSON)
// - escapeHtml() utility function
// - updateSectionCount() utility function (if available)
// =============================================================================

// =============================================================================
// OVERVIEW TAB FUNCTIONS
// =============================================================================

/**
 * Renders the executive dashboard in the Overview tab
 * ALREADY IMPLEMENTED in extracted-javascript.js as renderDeviceOverviewDashboard()
 *
 * This function:
 * - Calculates comprehensive metrics via calculateComprehensiveMetrics()
 * - Renders device identity section (hostname, OS, serial, join type, etc.)
 * - Renders health & status cards (overall health, compliance, issues, updates)
 * - Renders configuration summary with clickable rows for each domain
 * - Populates #executive-dashboard-container
 *
 * @param {Object} data - Global deviceData object
 */
function renderExecutiveDashboard(data) {
    // This function is already implemented as renderDeviceOverviewDashboard()
    // in the main JavaScript (extracted-javascript.js)
    // See lines 4387-4488 in Reporting.ps1

    if (typeof renderDeviceOverviewDashboard === 'function') {
        renderDeviceOverviewDashboard();
    }
}

/**
 * Renders the issue summary panel in the Overview tab
 * ALREADY IMPLEMENTED in extracted-javascript.js as renderIssueSummary()
 *
 * This function:
 * - Calls buildIssueSummary() to aggregate errors and warnings
 * - Groups issues by severity (critical errors, warnings)
 * - Shows affected items with jump links to sections
 * - Displays "All systems operational" if no issues
 * - Populates #issue-summary-container
 *
 * @param {Object} data - Global deviceData object
 */
function renderIssueSummaryPanel(data) {
    // This function is already implemented as renderIssueSummary()
    // in the main JavaScript (extracted-javascript.js)
    // See lines 4513-4620 in Reporting.ps1

    if (typeof renderIssueSummary === 'function') {
        renderIssueSummary();
    }
}

/**
 * Renders the collection issues section in the Overview tab
 * Shows problems that occurred during data collection
 *
 * @param {Object} data - Global deviceData object
 */
function renderCollectionIssues(data) {
    const container = document.getElementById('collection-issues');
    if (!container) return;

    const issues = data.collectionIssues || [];
    if (!issues || issues.length === 0) {
        container.innerHTML = '<div class="empty-state"><div class="empty-state-icon">✔️</div><p>No issues detected during collection</p></div>';
        return;
    }

    // Filter out irrelevant issues based on management type
    const mgmtType = (data.deviceInfo?.managementType || '').toLowerCase();
    const filtered = issues.filter(issue => {
        const phase = (issue.phase || '').toLowerCase();

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

    if (filtered.length === 0) {
        container.innerHTML = '<div class="empty-state"><div class="empty-state-icon">✔️</div><p>No relevant issues detected</p></div>';
        return;
    }

    // Icon and class mapping
    const iconMap = {
        'Error': '❌',
        'Warning': '⚠️',
        'Info': 'ℹ️'
    };
    const classMap = {
        'Error': 'alert-danger',
        'Warning': 'alert-warning',
        'Info': 'alert-info'
    };

    let html = '';
    filtered.forEach(issue => {
        const icon = iconMap[issue.severity] || 'ℹ️';
        const alertClass = classMap[issue.severity] || 'alert-info';

        html += `
            <div class="alert ${alertClass}">
                <span class="alert-icon">${icon}</span>
                <div>
                    <strong>${escapeHtml(issue.phase)}</strong>: ${escapeHtml(issue.message)}
                </div>
            </div>
        `;
    });

    container.innerHTML = html;

    // Update section count
    const section = container.closest('.section');
    if (section) {
        const countSpan = section.querySelector('.section-count');
        if (countSpan) {
            countSpan.textContent = filtered.length;
        }
    }
}

/**
 * Orchestration function: Renders all sections in the Overview tab
 * @param {Object} data - Global deviceData object
 */
function renderOverviewTab(data) {
    renderExecutiveDashboard(data);
    renderIssueSummaryPanel(data);
    renderCollectionIssues(data);
}

// =============================================================================
// DEVICE TAB FUNCTIONS
// =============================================================================

/**
 * Renders the complete device information section in the Device tab
 * Displays hardware, OS, network, security, and power information
 *
 * NOTE: The PowerShell implementation generates nested tables with <h3> headers.
 * This JavaScript version mirrors that structure.
 *
 * @param {Object} data - Global deviceData object
 */
function renderDeviceInfo(data) {
    const container = document.getElementById('device-info-content');
    if (!container) {
        // Try alternate container
        const section = document.getElementById('device-info-section');
        if (!section) return;

        const content = section.querySelector('.section-content');
        if (!content) return;

        // Use section content as container
        renderDeviceInventoryInContainer(content, data);
        return;
    }

    renderDeviceInventoryInContainer(container, data);
}

/**
 * Helper function to render device inventory into a specific container
 * @param {HTMLElement} container - Target container element
 * @param {Object} data - Global deviceData object
 */
function renderDeviceInventoryInContainer(container, data) {
    const deviceInfo = data.deviceInfo || {};
    let html = '';

    // ==========================================================================
    // PROCESSOR
    // ==========================================================================
    if (deviceInfo.Processor) {
        const proc = deviceInfo.Processor;
        html += '<h3>Processor</h3>';
        html += '<table class="nested-table"><tbody>';
        html += `<tr><td><strong>Name</strong></td><td>${escapeHtml(proc.Name || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Manufacturer</strong></td><td>${escapeHtml(proc.Manufacturer || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Cores</strong></td><td>${escapeHtml(proc.Cores || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Logical Processors</strong></td><td>${escapeHtml(proc.LogicalProcessors || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Max Clock Speed</strong></td><td>${escapeHtml(proc.MaxClockSpeed || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Architecture</strong></td><td>${escapeHtml(proc.Architecture || 'N/A')}</td></tr>`;
        html += '</tbody></table>';
    }

    // ==========================================================================
    // MEMORY
    // ==========================================================================
    if (deviceInfo.Memory) {
        const mem = deviceInfo.Memory;
        html += '<h3>Memory</h3>';
        html += '<table class="nested-table"><tbody>';
        html += `<tr><td><strong>Total Physical Memory</strong></td><td>${escapeHtml(mem.TotalPhysicalMemory || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Available Memory</strong></td><td>${escapeHtml(mem.AvailableMemory || 'N/A')}</td></tr>`;

        // Memory modules sub-table
        if (mem.MemoryModules && mem.MemoryModules.length > 0) {
            html += '<tr><td><strong>Memory Modules</strong></td><td>';
            html += '<table class="nested-table"><thead><tr>';
            html += '<th scope="col">Capacity</th>';
            html += '<th scope="col">Speed</th>';
            html += '<th scope="col">Manufacturer</th>';
            html += '<th scope="col">Part Number</th>';
            html += '</tr></thead><tbody>';

            mem.MemoryModules.forEach(module => {
                html += '<tr>';
                html += `<td>${escapeHtml(module.Capacity || 'N/A')}</td>`;
                html += `<td>${escapeHtml(module.Speed || 'N/A')}</td>`;
                html += `<td>${escapeHtml(module.Manufacturer || 'N/A')}</td>`;
                html += `<td>${escapeHtml(module.PartNumber || 'N/A')}</td>`;
                html += '</tr>';
            });

            html += '</tbody></table>';
            html += '</td></tr>';
        }

        html += '</tbody></table>';
    }

    // ==========================================================================
    // STORAGE
    // ==========================================================================
    if (deviceInfo.Storage && deviceInfo.Storage.Disks && deviceInfo.Storage.Disks.length > 0) {
        html += '<h3>Storage</h3>';
        html += '<table class="nested-table"><thead><tr>';
        html += '<th scope="col">Model</th>';
        html += '<th scope="col">Size</th>';
        html += '<th scope="col">Interface</th>';
        html += '<th scope="col">Media Type</th>';
        html += '<th scope="col">Status</th>';
        html += '</tr></thead><tbody>';

        deviceInfo.Storage.Disks.forEach(disk => {
            html += '<tr>';
            html += `<td>${escapeHtml(disk.Model || 'N/A')}</td>`;
            html += `<td>${escapeHtml(disk.Size || 'N/A')}</td>`;
            html += `<td>${escapeHtml(disk.InterfaceType || 'N/A')}</td>`;
            html += `<td>${escapeHtml(disk.MediaType || 'N/A')}</td>`;
            html += `<td>${escapeHtml(disk.Status || 'N/A')}</td>`;
            html += '</tr>';
        });

        html += '</tbody></table>';
    }

    // ==========================================================================
    // BIOS / FIRMWARE
    // ==========================================================================
    if (deviceInfo.BIOS) {
        const bios = deviceInfo.BIOS;
        html += '<h3>BIOS / Firmware</h3>';
        html += '<table class="nested-table"><tbody>';
        html += `<tr><td><strong>Manufacturer</strong></td><td>${escapeHtml(bios.Manufacturer || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Version</strong></td><td>${escapeHtml(bios.Version || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Release Date</strong></td><td>${escapeHtml(bios.ReleaseDate || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>SMBIOS Version</strong></td><td>${escapeHtml(bios.SMBIOSVersion || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Boot Mode</strong></td><td>${escapeHtml(bios.UEFIMode || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Secure Boot</strong></td><td>${escapeHtml(bios.SecureBoot || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>TPM Present</strong></td><td>${escapeHtml(bios.TPMPresent || 'N/A')}</td></tr>`;

        if (bios.TPMVersion) {
            html += `<tr><td><strong>TPM Version</strong></td><td>${escapeHtml(bios.TPMVersion)}</td></tr>`;
            html += `<tr><td><strong>TPM Enabled</strong></td><td>${escapeHtml(bios.TPMEnabled || 'N/A')}</td></tr>`;
        }

        html += '</tbody></table>';
    }

    // ==========================================================================
    // NETWORK ADAPTERS
    // ==========================================================================
    if (deviceInfo.Network && deviceInfo.Network.Adapters && deviceInfo.Network.Adapters.length > 0) {
        html += '<h3>Network Adapters</h3>';

        deviceInfo.Network.Adapters.forEach(adapter => {
            const desc = escapeHtml(adapter.Description || 'Unknown Adapter');
            html += `<h4>${desc}</h4>`;
            html += '<table class="nested-table"><tbody>';
            html += `<tr><td><strong>MAC Address</strong></td><td>${escapeHtml(adapter.MACAddress || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>IP Address</strong></td><td>${escapeHtml(adapter.IPAddress || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>Subnet Mask</strong></td><td>${escapeHtml(adapter.SubnetMask || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>Default Gateway</strong></td><td>${escapeHtml(adapter.DefaultGateway || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>DHCP Enabled</strong></td><td>${escapeHtml(adapter.DHCPEnabled || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>DHCP Server</strong></td><td>${escapeHtml(adapter.DHCPServer || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>DNS Servers</strong></td><td>${escapeHtml(adapter.DNSServers || 'N/A')}</td></tr>`;
            html += `<tr><td><strong>DNS Domain</strong></td><td>${escapeHtml(adapter.DNSDomain || 'N/A')}</td></tr>`;
            html += '</tbody></table>';
        });
    }

    // ==========================================================================
    // PROXY CONFIGURATION
    // ==========================================================================
    if (deviceInfo.Proxy) {
        const proxy = deviceInfo.Proxy;
        html += '<h3>Proxy Configuration</h3>';
        html += '<table class="nested-table"><tbody>';
        html += `<tr><td><strong>Proxy Enabled</strong></td><td>${escapeHtml(proxy.ProxyEnable || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Proxy Server</strong></td><td>${escapeHtml(proxy.ProxyServer || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Proxy Override</strong></td><td>${escapeHtml(proxy.ProxyOverride || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Auto Config URL</strong></td><td>${escapeHtml(proxy.AutoConfigURL || 'N/A')}</td></tr>`;
        html += '</tbody></table>';
    }

    // ==========================================================================
    // SECURITY STATUS
    // ==========================================================================
    if (deviceInfo.Security) {
        const sec = deviceInfo.Security;
        html += '<h3>Security Status</h3>';

        // BitLocker Volumes
        if (sec.BitLockerVolumes && sec.BitLockerVolumes.length > 0) {
            html += '<h4>BitLocker Volumes</h4>';
            html += '<table class="nested-table"><thead><tr>';
            html += '<th scope="col">Mount Point</th>';
            html += '<th scope="col">Protection Status</th>';
            html += '<th scope="col">Encryption %</th>';
            html += '</tr></thead><tbody>';

            sec.BitLockerVolumes.forEach(vol => {
                html += '<tr>';
                html += `<td>${escapeHtml(vol.MountPoint || 'N/A')}</td>`;
                html += `<td>${escapeHtml(vol.ProtectionStatus || 'N/A')}</td>`;
                html += `<td>${escapeHtml(vol.EncryptionPercentage || 'N/A')}%</td>`;
                html += '</tr>';
            });

            html += '</tbody></table>';
        }

        // Windows Defender
        if (sec.DefenderVersion) {
            html += '<h4>Windows Defender</h4>';
            html += '<table class="nested-table"><tbody>';
            html += `<tr><td><strong>Antimalware Version</strong></td><td>${escapeHtml(sec.DefenderVersion)}</td></tr>`;
            html += '</tbody></table>';
        }

        // Windows Firewall
        if (sec.FirewallStatus) {
            html += '<h4>Windows Firewall</h4>';
            html += '<table class="nested-table"><tbody>';

            for (const profile in sec.FirewallStatus) {
                const status = escapeHtml(sec.FirewallStatus[profile] || 'N/A');
                html += `<tr><td><strong>${profile} Profile</strong></td><td>${status}</td></tr>`;
            }

            html += '</tbody></table>';
        }
    }

    // ==========================================================================
    // POWER & UPTIME
    // ==========================================================================
    if (deviceInfo.Power) {
        const pwr = deviceInfo.Power;
        html += '<h3>Power & Uptime</h3>';
        html += '<table class="nested-table"><tbody>';
        html += `<tr><td><strong>Battery Present</strong></td><td>${escapeHtml(pwr.BatteryPresent || 'N/A')}</td></tr>`;

        if (pwr.BatteryStatus) {
            html += `<tr><td><strong>Battery Status</strong></td><td>${escapeHtml(pwr.BatteryStatus)}</td></tr>`;
            html += `<tr><td><strong>Battery Health</strong></td><td>${escapeHtml(pwr.BatteryHealth || 'N/A')}</td></tr>`;
        }

        html += `<tr><td><strong>Last Boot Time</strong></td><td>${escapeHtml(pwr.LastBootTime || 'N/A')}</td></tr>`;
        html += `<tr><td><strong>Uptime</strong></td><td>${escapeHtml(pwr.Uptime || 'N/A')}</td></tr>`;
        html += '</tbody></table>';
    }

    // ==========================================================================
    // FINALIZE
    // ==========================================================================
    if (html === '') {
        container.innerHTML = '<div class="empty-state"><p>No enhanced device inventory collected</p></div>';
    } else {
        container.innerHTML = html;
    }
}

/**
 * Orchestration function: Renders all sections in the Device tab
 * @param {Object} data - Global deviceData object
 */
function renderDeviceTab(data) {
    renderDeviceInfo(data);
}

// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

/**
 * Escapes HTML to prevent XSS
 * NOTE: This should already exist in the main JavaScript, but included here
 * for completeness
 *
 * @param {string} text - Text to escape
 * @returns {string} HTML-safe text
 */
function escapeHtml(text) {
    if (text === null || text === undefined) return '';
    if (typeof text !== 'string') return String(text);

    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// =============================================================================
// EXPORT FOR MODULE SYSTEMS (if needed)
// =============================================================================
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        renderOverviewTab,
        renderDeviceTab,
        renderExecutiveDashboard,
        renderIssueSummaryPanel,
        renderCollectionIssues,
        renderDeviceInfo
    };
}
