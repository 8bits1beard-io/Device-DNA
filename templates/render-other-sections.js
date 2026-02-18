// DeviceDNA Other Sections Rendering Functions
// Handles client-side rendering of Group Policy, SCCM, and Windows Update sections

/**
 * Helper function to get status category from status string
 * Maps status values to categories: error, warning, success, neutral
 */
function getOtherStatusCategory(status) {
    const statusLower = (status || '').toLowerCase();

    if (statusLower.match(/denied|error|non-compliant|noncompliant|failed/)) {
        return 'error';
    } else if (statusLower.match(/warning|pending|conflict/)) {
        return 'warning';
    } else if (statusLower.match(/applied|compliant|targeted|installed|succeeded|success|installcomplete/)) {
        return 'success';
    } else {
        return 'neutral';
    }
}

/**
 * Helper function to generate status icon HTML
 */
function getOtherStatusIcon(statusCategory) {
    switch (statusCategory) {
        case 'error':
            return '<span class="status-icon error" aria-label="Error">●</span>';
        case 'warning':
            return '<span class="status-icon warning" aria-label="Warning">●</span>';
        case 'success':
            return '<span class="status-icon success" aria-label="Success">●</span>';
        default:
            return '<span class="status-icon neutral" aria-label="Not applicable">●</span>';
    }
}

/**
 * Helper function to generate status badge HTML for other sections
 */
function getOtherStatusBadge(status) {
    const statusLower = (status || '').toLowerCase();
    let badgeClass = 'badge-muted';

    if (statusLower.match(/applied|compliant|installed|succeeded|success|installcomplete/)) {
        badgeClass = 'badge-success';
    } else if (statusLower.match(/warning|pending/)) {
        badgeClass = 'badge-warning';
    } else if (statusLower.match(/denied|error|failed/)) {
        badgeClass = 'badge-danger';
    } else if (statusLower.match(/conflict/)) {
        badgeClass = 'badge-warning';
    } else if (statusLower.match(/not\s*applicable|notapplicable|n\/a|unknown|available|none/)) {
        badgeClass = 'badge-muted';
    } else if (statusLower.match(/info|download|install/)) {
        badgeClass = 'badge-info';
    }

    return `<span class="badge ${badgeClass}">${escapeHtml(status || 'Unknown')}</span>`;
}

/**
 * Helper function to update section count badge
 */
function updateOtherSectionCount(sectionId, count) {
    const section = document.getElementById(sectionId);
    if (!section) return;

    const countBadge = section.querySelector('.section-count');
    if (countBadge) {
        countBadge.textContent = count;
    }

    // Update navigation count if exists
    const navLink = document.querySelector(`[data-section="${sectionId}"] .nav-link-count`);
    if (navLink) {
        if (count > 0) {
            navLink.textContent = count;
            navLink.style.display = '';
        } else {
            navLink.style.display = 'none';
        }
    }
}

// ============================================================================
// GROUP POLICY FUNCTIONS
// ============================================================================

/**
 * Render Group Policy Objects table
 * Shows GPO metadata without status icons
 */
function renderGroupPolicyObjects(data, scope) {
    if (!data || !data.groupPolicy || !data.groupPolicy[scope] || !data.groupPolicy[scope].appliedGPOs) {
        return { html: '', count: 0 };
    }

    const gpos = data.groupPolicy[scope].appliedGPOs.sort((a, b) => {
        const aName = (a.name || '').toLowerCase();
        const bName = (b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';
    let rowId = 0;

    gpos.forEach(gpo => {
        const name = escapeHtml(gpo.name || 'Unknown');
        const link = escapeHtml(gpo.linkLocation || '');
        const status = gpo.status || 'Applied';
        const statusBadge = getOtherStatusBadge(status);

        html += `
            <tr class="expandable-row" data-id="${scope}-gpo-${rowId}" aria-expanded="false">
                <td>${name}</td>
                <td>${link}</td>
                <td>${statusBadge}</td>
            </tr>
            <tr id="detail-${scope}-gpo-${rowId}" class="detail-row">
                <td colspan="3">
                    <div class="detail-content">
                        <h4>GPO Settings</h4>
                        <p class="text-muted">Settings details would appear here when available.</p>
                    </div>
                </td>
            </tr>
        `;
        rowId++;
    });

    return { html, count: gpos.length };
}

/**
 * Render Group Policy Settings table
 * This can be a LARGE table (1000+ rows), so pagination is recommended
 * Note: Pagination logic is handled by existing table search/filter infrastructure
 */
function renderGroupPolicySettings(data) {
    if (!data || !data.groupPolicy || !data.groupPolicy.settings || data.groupPolicy.settings.length === 0) {
        return { html: '', count: 0 };
    }

    const settings = data.groupPolicy.settings.sort((a, b) => {
        const aName = (a.name || '').toLowerCase();
        const bName = (b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    settings.forEach(setting => {
        const name = escapeHtml(setting.name || 'Unknown');
        const value = escapeHtml(String(setting.value || ''));
        const sourceGPO = escapeHtml(setting.sourceGPO || 'Unknown');
        const keyPath = escapeHtml(setting.keyPath || '');

        html += `
            <tr>
                <td>${name}</td>
                <td class="setting-value">${value}</td>
                <td>${sourceGPO}</td>
                <td class="value-truncate">${keyPath}</td>
            </tr>
        `;
    });

    return { html, count: settings.length };
}

// ============================================================================
// SCCM FUNCTIONS
// ============================================================================

/**
 * Render SCCM Applications table
 * Includes status icons for install state tracking
 */
function renderSCCMApplications(data) {
    if (!data || !data.sccm || !data.sccm.applications || data.sccm.applications.length === 0) {
        return { html: '', count: 0 };
    }

    const apps = data.sccm.applications.sort((a, b) => {
        const aName = (a.Name || '').toLowerCase();
        const bName = (b.Name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    apps.forEach(app => {
        const name = escapeHtml(app.Name || 'Unknown');
        const version = escapeHtml(app.Version || '');
        const publisher = escapeHtml(app.Publisher || '');
        const installState = app.InstallState || 'Unknown';
        const evalState = app.EvaluationState || 'Unknown';

        // Install state badge
        const installBadge = getOtherStatusBadge(installState);

        // Evaluation state badge
        let evalBadge;
        if (evalState === 'InstallComplete') {
            evalBadge = '<span class="badge badge-success">Installed</span>';
        } else if (evalState.match(/Error/)) {
            evalBadge = '<span class="badge badge-danger">Error</span>';
        } else if (evalState.match(/Install|Download/)) {
            evalBadge = `<span class="badge badge-info">${escapeHtml(evalState)}</span>`;
        } else if (evalState === 'Available' || evalState === 'None') {
            evalBadge = `<span class="badge badge-muted">${escapeHtml(evalState)}</span>`;
        } else {
            evalBadge = `<span class="badge badge-secondary">${escapeHtml(evalState)}</span>`;
        }

        // Required badge
        const requiredBadge = app.IsRequired
            ? '<span class="badge badge-danger">Required</span>'
            : '<span class="badge badge-info">Available</span>';

        // Status category for row filtering
        const statusCategory = getOtherStatusCategory(installState);
        const statusIcon = getOtherStatusIcon(statusCategory);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${name}</td>
                <td>${version}</td>
                <td>${publisher}</td>
                <td>${requiredBadge}</td>
                <td>${installBadge}</td>
                <td>${evalBadge}</td>
            </tr>
        `;
    });

    return { html, count: apps.length };
}

/**
 * Render SCCM Compliance Baselines table
 * Includes status icons for compliance state tracking
 */
function renderSCCMBaselines(data) {
    if (!data || !data.sccm || !data.sccm.baselines || data.sccm.baselines.length === 0) {
        return { html: '', count: 0 };
    }

    const baselines = data.sccm.baselines.sort((a, b) => {
        const aName = (a.Name || '').toLowerCase();
        const bName = (b.Name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    baselines.forEach(baseline => {
        const name = escapeHtml(baseline.Name || 'Unknown');
        const version = escapeHtml(baseline.Version || '');
        const complianceState = baseline.ComplianceState || 'Unknown';
        const lastEval = escapeHtml(baseline.LastEvaluated || 'N/A');

        const complianceBadge = getOtherStatusBadge(complianceState);

        const statusCategory = getOtherStatusCategory(complianceState);
        const statusIcon = getOtherStatusIcon(statusCategory);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${name}</td>
                <td>${version}</td>
                <td>${complianceBadge}</td>
                <td>${lastEval}</td>
            </tr>
        `;
    });

    return { html, count: baselines.length };
}

/**
 * Render SCCM Software Updates table
 * Includes status icons for update installation tracking
 */
function renderSCCMUpdates(data) {
    if (!data || !data.sccm || !data.sccm.softwareUpdates || data.sccm.softwareUpdates.length === 0) {
        return { html: '', count: 0 };
    }

    const updates = data.sccm.softwareUpdates.sort((a, b) => {
        const aName = (a.Name || '').toLowerCase();
        const bName = (b.Name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    updates.forEach(update => {
        const articleId = escapeHtml(update.ArticleID || '');
        const name = escapeHtml(update.Name || 'Unknown');
        const evalState = update.EvaluationState || 'Unknown';
        const deadline = escapeHtml(update.Deadline || 'N/A');

        // Evaluation state badge
        let evalBadge;
        if (evalState === 'InstallComplete') {
            evalBadge = '<span class="badge badge-success">Installed</span>';
        } else if (evalState.match(/Error/)) {
            evalBadge = '<span class="badge badge-danger">Error</span>';
        } else if (evalState.match(/Install|Download/)) {
            evalBadge = `<span class="badge badge-info">${escapeHtml(evalState)}</span>`;
        } else {
            evalBadge = `<span class="badge badge-secondary">${escapeHtml(evalState)}</span>`;
        }

        // Required badge
        const requiredBadge = update.IsRequired
            ? '<span class="badge badge-danger">Required</span>'
            : '<span class="badge badge-muted">Not Required</span>';

        // Status category
        let statusCategory;
        if (evalState.match(/Error/)) {
            statusCategory = 'error';
        } else if (evalState.match(/Install|Download|Pending/)) {
            statusCategory = 'warning';
        } else if (evalState === 'InstallComplete') {
            statusCategory = 'success';
        } else {
            statusCategory = 'neutral';
        }

        const statusIcon = getOtherStatusIcon(statusCategory);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${articleId}</td>
                <td>${name}</td>
                <td>${evalBadge}</td>
                <td>${requiredBadge}</td>
                <td>${deadline}</td>
            </tr>
        `;
    });

    return { html, count: updates.length };
}

/**
 * Render SCCM Client Settings
 * Grouped by policy category with expandable key-value pairs
 */
function renderSCCMSettings(data) {
    if (!data || !data.sccm || !data.sccm.clientSettings || data.sccm.clientSettings.length === 0) {
        return { html: '', count: 0 };
    }

    const categories = data.sccm.clientSettings.sort((a, b) => {
        const aName = (a.Category || '').toLowerCase();
        const bName = (b.Category || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    categories.forEach(category => {
        const catName = escapeHtml(category.Category || 'Unknown');
        let settingsRows = '';

        if (category.Settings) {
            const sortedKeys = Object.keys(category.Settings).sort();
            sortedKeys.forEach(key => {
                const val = category.Settings[key];
                const valStr = val === null || val === undefined ? 'N/A' : String(val);
                settingsRows += `
                    <div class="info-row">
                        <span class="info-label">${escapeHtml(key)}</span>
                        <span class="info-value">${escapeHtml(valStr)}</span>
                    </div>
                `;
            });
        }

        html += `
            <div class="info-group">
                <h3>${catName}</h3>
                ${settingsRows}
            </div>
        `;
    });

    return { html, count: categories.length };
}

// ============================================================================
// WINDOWS UPDATE FUNCTIONS
// ============================================================================

/**
 * Render Windows Update Summary
 * Summary grid with "Managed By" badge (SCCM/Intune WUFB/Intune ESUS/WSUS/Direct)
 */
function renderWUSummary(data) {
    if (!data || !data.windowsUpdate || !data.windowsUpdate.summary) {
        return { html: '', count: 0 };
    }

    const wuSum = data.windowsUpdate.summary;

    // Reboot badge
    const rebootBadge = wuSum.rebootPending
        ? '<span class="badge badge-warning">Reboot Pending</span>'
        : '<span class="badge badge-success">No Reboot Pending</span>';

    // Service state badge
    let svcBadge;
    if (wuSum.serviceState === 'Running') {
        svcBadge = '<span class="badge badge-success">Running</span>';
    } else if (wuSum.serviceState === 'Stopped') {
        svcBadge = '<span class="badge badge-muted">Stopped</span>';
    } else {
        svcBadge = `<span class="badge badge-secondary">${escapeHtml(wuSum.serviceState || 'Unknown')}</span>`;
    }

    // Pending updates badge
    const pendingBadge = wuSum.pendingCount > 0
        ? `<span class="badge badge-warning">${wuSum.pendingCount} Pending</span>`
        : '<span class="badge badge-success">0 Pending</span>';

    // Delivery Optimization mode
    let doModeStr = 'Not configured (default)';
    if (data.windowsUpdate.deliveryOptimization && data.windowsUpdate.deliveryOptimization.DODownloadMode) {
        doModeStr = data.windowsUpdate.deliveryOptimization.DODownloadMode.Decoded || 'Unknown';
    }

    // Build management badge for prominent display
    // Color-coded: Blue=SCCM, Green=Intune, Gray=WSUS/Direct
    let mgmtBadge = '<span class="badge badge-secondary">Unknown</span>';
    const mgmtText = wuSum.updateManagement || 'None';

    if (mgmtText.match(/SCCM/)) {
        mgmtBadge = '<span class="badge badge-info">SCCM</span>';
    } else if (mgmtText.match(/Intune.*WUFB/)) {
        mgmtBadge = '<span class="badge badge-success">Intune (WUFB)</span>';
    } else if (mgmtText.match(/Intune.*ESUS/)) {
        mgmtBadge = '<span class="badge badge-success">Intune (ESUS)</span>';
    } else if (mgmtText.match(/WSUS/)) {
        mgmtBadge = '<span class="badge badge-muted">WSUS</span>';
    } else if (mgmtText === 'None') {
        mgmtBadge = '<span class="badge badge-muted">Windows Update (direct)</span>';
    }

    const html = `
        <div class="device-info-grid">
            <div class="info-group">
                <h3>Update Management</h3>
                <div class="info-row"><span class="info-label">Managed By</span><span class="info-value">${mgmtBadge}</span></div>
                <div class="info-row"><span class="info-label">Update Source</span><span class="info-value">${escapeHtml(wuSum.updateSource || 'Unknown')}</span></div>
                <div class="info-row"><span class="info-label">Source Priority</span><span class="info-value">${escapeHtml(wuSum.sourcePriority || 'Unknown')}</span></div>
            </div>
            <div class="info-group">
                <h3>Service Status</h3>
                <div class="info-row"><span class="info-label">Service State</span><span class="info-value">${svcBadge}</span></div>
                <div class="info-row"><span class="info-label">Reboot Status</span><span class="info-value">${rebootBadge}</span></div>
                <div class="info-row"><span class="info-label">Pending Updates</span><span class="info-value">${pendingBadge}</span></div>
            </div>
            <div class="info-group">
                <h3>Scan History</h3>
                <div class="info-row"><span class="info-label">Last Scan Time</span><span class="info-value">${escapeHtml(wuSum.lastScanTime || 'Unknown')}</span></div>
                <div class="info-row"><span class="info-label">Last Scan Success</span><span class="info-value">${escapeHtml(wuSum.lastScanSuccess || 'Unknown')}</span></div>
            </div>
            <div class="info-group">
                <h3>Delivery Optimization</h3>
                <div class="info-row"><span class="info-label">Download Mode</span><span class="info-value">${escapeHtml(doModeStr)}</span></div>
            </div>
        </div>
    `;

    return { html, count: 1 };
}

/**
 * Render Windows Update Policy Settings table
 * Registry hive sources grouped by hive name
 */
function renderWUPolicy(data) {
    if (!data || !data.windowsUpdate || !data.windowsUpdate.registryPolicy || Object.keys(data.windowsUpdate.registryPolicy).length === 0) {
        return { html: '', count: 0 };
    }

    // Group by hive name
    const hiveGroups = {};
    Object.entries(data.windowsUpdate.registryPolicy).forEach(([key, entry]) => {
        const hiveName = entry.Hive || 'Unknown';
        if (!hiveGroups[hiveName]) {
            hiveGroups[hiveName] = [];
        }
        hiveGroups[hiveName].push(entry);
    });

    let html = '';
    let totalCount = 0;
    const sortedHives = Object.keys(hiveGroups).sort();

    sortedHives.forEach(hiveName => {
        html += `<tr class="group-header-row"><td colspan="3"><strong>${escapeHtml(hiveName)}</strong></td></tr>\n`;

        const sortedSettings = hiveGroups[hiveName].sort((a, b) => {
            const aName = (a.Setting || '').toLowerCase();
            const bName = (b.Setting || '').toLowerCase();
            return aName.localeCompare(bName);
        });

        sortedSettings.forEach(setting => {
            const knownMarker = setting.Known ? '' : ' <span class="badge badge-muted">Extra</span>';
            const descHtml = setting.Description
                ? `<br><span class="setting-desc">${escapeHtml(setting.Description)}</span>`
                : '';

            html += `
                <tr>
                    <td>${escapeHtml(setting.Setting || '')}${knownMarker}${descHtml}</td>
                    <td>${escapeHtml(String(setting.Value || ''))}</td>
                    <td>${escapeHtml(setting.Decoded || '')}</td>
                </tr>
            `;
            totalCount++;
        });
    });

    return { html, count: totalCount };
}

/**
 * Render Windows Update Pending Updates table
 * Shows updates awaiting installation
 */
function renderWUPending(data) {
    if (!data || !data.windowsUpdate || !data.windowsUpdate.pendingUpdates || data.windowsUpdate.pendingUpdates.length === 0) {
        return { html: '', count: 0 };
    }

    const updates = data.windowsUpdate.pendingUpdates;
    let html = '';

    updates.forEach(update => {
        const title = escapeHtml(update.Title || 'Unknown');
        const kb = escapeHtml(update.KBArticleIDs || '');
        const severity = update.MsrcSeverity || 'Unspecified';

        // Severity badge
        let severityBadge;
        if (severity === 'Critical') {
            severityBadge = '<span class="badge badge-danger">Critical</span>';
        } else if (severity === 'Important') {
            severityBadge = '<span class="badge badge-warning">Important</span>';
        } else if (severity === 'Moderate') {
            severityBadge = '<span class="badge badge-info">Moderate</span>';
        } else {
            severityBadge = `<span class="badge badge-muted">${escapeHtml(severity)}</span>`;
        }

        // Download badge
        const dlBadge = update.IsDownloaded
            ? '<span class="badge badge-success">Downloaded</span>'
            : '<span class="badge badge-muted">Not Downloaded</span>';

        html += `
            <tr data-status-category="warning">
                <td class="status-icon-cell"><span class="status-icon warning" aria-label="Pending">●</span></td>
                <td>${title}</td>
                <td>${kb}</td>
                <td>${severityBadge}</td>
                <td>${dlBadge}</td>
            </tr>
        `;
    });

    return { html, count: updates.length };
}

/**
 * Render Windows Update History table
 * Shows past update installation attempts
 */
function renderWUHistory(data) {
    if (!data || !data.windowsUpdate || !data.windowsUpdate.updateHistory || data.windowsUpdate.updateHistory.length === 0) {
        return { html: '', count: 0 };
    }

    const history = data.windowsUpdate.updateHistory;
    let html = '';

    history.forEach(entry => {
        const title = escapeHtml(entry.Title || 'Unknown');
        const date = escapeHtml(entry.Date || 'N/A');
        const op = escapeHtml(entry.Operation || 'Unknown');
        const result = entry.Result || 'Unknown';
        const hResult = entry.HResult ? escapeHtml(entry.HResult) : '';

        // Status category
        let statusCategory;
        if (result.match(/Succeeded/)) {
            statusCategory = 'success';
        } else if (result === 'Failed') {
            statusCategory = 'error';
        } else if (result === 'Aborted') {
            statusCategory = 'warning';
        } else {
            statusCategory = 'neutral';
        }

        const statusIcon = getOtherStatusIcon(statusCategory);
        const resultBadge = getOtherStatusBadge(result);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${title}</td>
                <td>${date}</td>
                <td>${op}</td>
                <td>${resultBadge}</td>
                <td>${hResult}</td>
            </tr>
        `;
    });

    return { html, count: history.length };
}

// ============================================================================
// ORCHESTRATION FUNCTION
// ============================================================================

/**
 * Render all non-Intune sections (Group Policy, SCCM, Windows Update)
 * Call this after data is loaded to populate the report
 */
function renderAllOtherSections(data) {
    if (!data) return;

    // Group Policy - Computer Scope
    if (data.groupPolicy && data.groupPolicy.computerScope) {
        const computerGPOsResult = renderGroupPolicyObjects(data, 'computerScope');
        const computerGPOsSection = document.getElementById('gp-computer-section');
        if (computerGPOsSection) {
            const tbody = computerGPOsSection.querySelector('table tbody');
            if (tbody && computerGPOsResult.html) {
                tbody.innerHTML = computerGPOsResult.html;
                updateOtherSectionCount('gp-computer-section', computerGPOsResult.count);
            }
        }
    }

    // Group Policy - User Scope
    if (data.groupPolicy && data.groupPolicy.userScope) {
        const userGPOsResult = renderGroupPolicyObjects(data, 'userScope');
        const userGPOsSection = document.getElementById('gp-user-section');
        if (userGPOsSection) {
            const tbody = userGPOsSection.querySelector('table tbody');
            if (tbody && userGPOsResult.html) {
                tbody.innerHTML = userGPOsResult.html;
                updateOtherSectionCount('gp-user-section', userGPOsResult.count);
            }
        }
    }

    // SCCM - Applications
    const sccmAppsResult = renderSCCMApplications(data);
    const sccmAppsSection = document.getElementById('sccm-apps-section');
    if (sccmAppsSection) {
        const tbody = sccmAppsSection.querySelector('table tbody');
        if (tbody && sccmAppsResult.html) {
            tbody.innerHTML = sccmAppsResult.html;
            updateOtherSectionCount('sccm-apps-section', sccmAppsResult.count);
        }
    }

    // SCCM - Baselines
    const sccmBaselinesResult = renderSCCMBaselines(data);
    const sccmBaselinesSection = document.getElementById('sccm-baselines-section');
    if (sccmBaselinesSection) {
        const tbody = sccmBaselinesSection.querySelector('table tbody');
        if (tbody && sccmBaselinesResult.html) {
            tbody.innerHTML = sccmBaselinesResult.html;
            updateOtherSectionCount('sccm-baselines-section', sccmBaselinesResult.count);
        }
    }

    // SCCM - Updates
    const sccmUpdatesResult = renderSCCMUpdates(data);
    const sccmUpdatesSection = document.getElementById('sccm-updates-section');
    if (sccmUpdatesSection) {
        const tbody = sccmUpdatesSection.querySelector('table tbody');
        if (tbody && sccmUpdatesResult.html) {
            tbody.innerHTML = sccmUpdatesResult.html;
            updateOtherSectionCount('sccm-updates-section', sccmUpdatesResult.count);
        }
    }

    // SCCM - Client Settings
    const sccmSettingsResult = renderSCCMSettings(data);
    const sccmSettingsSection = document.getElementById('sccm-settings-section');
    if (sccmSettingsSection) {
        const container = sccmSettingsSection.querySelector('.device-info-grid');
        if (container && sccmSettingsResult.html) {
            container.innerHTML = sccmSettingsResult.html;
            updateOtherSectionCount('sccm-settings-section', sccmSettingsResult.count);
        }
    }

    // Windows Update - Summary
    const wuSummaryResult = renderWUSummary(data);
    const wuSummarySection = document.getElementById('wu-summary-section');
    if (wuSummarySection) {
        const container = wuSummarySection.querySelector('.section-content');
        if (container && wuSummaryResult.html) {
            container.innerHTML = wuSummaryResult.html;
        }
    }

    // Windows Update - Policy
    const wuPolicyResult = renderWUPolicy(data);
    const wuPolicySection = document.getElementById('wu-policy-section');
    if (wuPolicySection) {
        const tbody = wuPolicySection.querySelector('table tbody');
        if (tbody && wuPolicyResult.html) {
            tbody.innerHTML = wuPolicyResult.html;
            updateOtherSectionCount('wu-policy-section', wuPolicyResult.count);
        }
    }

    // Windows Update - Pending Updates
    const wuPendingResult = renderWUPending(data);
    const wuPendingSection = document.getElementById('wu-pending-section');
    if (wuPendingSection) {
        const tbody = wuPendingSection.querySelector('table tbody');
        if (tbody && wuPendingResult.html) {
            tbody.innerHTML = wuPendingResult.html;
            updateOtherSectionCount('wu-pending-section', wuPendingResult.count);
        }
    }

    // Windows Update - History
    const wuHistoryResult = renderWUHistory(data);
    const wuHistorySection = document.getElementById('wu-history-section');
    if (wuHistorySection) {
        const tbody = wuHistorySection.querySelector('table tbody');
        if (tbody && wuHistoryResult.html) {
            tbody.innerHTML = wuHistoryResult.html;
            updateOtherSectionCount('wu-history-section', wuHistoryResult.count);
        }
    }

    // Update all status counts after rendering
    if (typeof updateAllStatusCounts === 'function') {
        updateAllStatusCounts();
    }
}
