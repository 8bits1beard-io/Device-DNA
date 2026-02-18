// DeviceDNA Intune Rendering Functions
// Handles client-side rendering of all Intune sections

/**
 * Helper function to get status category from status string
 * Maps status values to categories: error, warning, success, neutral
 */
function getStatusCategory(status) {
    const statusLower = (status || '').toLowerCase();

    if (statusLower.match(/denied|error|non-compliant|noncompliant|failed/)) {
        return 'error';
    } else if (statusLower.match(/warning|pending|conflict/)) {
        return 'warning';
    } else if (statusLower.match(/applied|compliant|targeted|installed|succeeded|success/)) {
        return 'success';
    } else {
        return 'neutral';
    }
}

/**
 * Helper function to generate status icon HTML
 */
function getStatusIcon(statusCategory) {
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
 * Helper function to generate status badge HTML
 */
function getIntuneStatusBadge(status) {
    const statusLower = (status || '').toLowerCase();
    let badgeClass = 'badge-muted';

    if (statusLower.match(/applied|compliant|targeted|installed|succeeded|success/)) {
        badgeClass = 'badge-success';
    } else if (statusLower.match(/warning|pending/)) {
        badgeClass = 'badge-warning';
    } else if (statusLower.match(/denied|error|non-compliant|noncompliant|failed/)) {
        badgeClass = 'badge-danger';
    } else if (statusLower.match(/conflict/)) {
        badgeClass = 'badge-warning';
    } else if (statusLower.match(/not\s*applicable|notapplicable|n\/a|unknown/)) {
        badgeClass = 'badge-muted';
    } else if (statusLower.match(/info/)) {
        badgeClass = 'badge-info';
    }

    return `<span class="badge ${badgeClass}">${escapeHtml(status || 'Unknown')}</span>`;
}

/**
 * Helper function to generate group type badge HTML
 */
function getGroupTypeBadge(groupType) {
    const groupTypeLower = (groupType || 'Assigned').toLowerCase();
    const badgeClass = groupTypeLower === 'dynamic' ? 'badge-info' : 'badge-success';
    return `<span class="badge ${badgeClass}">${escapeHtml(groupType || 'Assigned')}</span>`;
}

/**
 * Render Entra ID Device Groups table
 * Simple table with no status icons - just group data
 */
function renderDeviceGroups(data) {
    if (!data || !data.deviceGroups || data.deviceGroups.length === 0) {
        return { html: '', count: 0 };
    }

    const groups = data.deviceGroups.sort((a, b) => {
        const aName = (a.displayName || a.name || '').toLowerCase();
        const bName = (b.displayName || b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';
    groups.forEach(group => {
        const name = escapeHtml(group.displayName || group.name || 'Unknown');
        const typeBadge = getGroupTypeBadge(group.groupType || 'Assigned');
        const id = escapeHtml(group.id || '');

        html += `
            <tr>
                <td>${name}</td>
                <td>${typeBadge}</td>
                <td class="value-truncate">${id}</td>
            </tr>
        `;
    });

    return { html, count: groups.length };
}

/**
 * Render Configuration Profiles table with expandable settings rows
 * CRITICAL: Includes expandable detail rows showing configured settings
 */
function renderConfigurationProfiles(data) {
    if (!data || !data.configurationProfiles || data.configurationProfiles.length === 0) {
        return { html: '', count: 0 };
    }

    const profiles = data.configurationProfiles.sort((a, b) => {
        const aName = (a.displayName || a.name || '').toLowerCase();
        const bName = (b.displayName || b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';
    let profileRowId = 0;

    profiles.forEach(profile => {
        const name = escapeHtml(profile.displayName || profile.name || 'Unknown');
        const description = profile.description
            ? escapeHtml(profile.description)
            : '<span class="text-muted">NONE</span>';
        const type = escapeHtml(profile.policyType || 'Unknown');
        const deploymentState = profile.deploymentState || 'Unknown';
        const deploymentBadge = getIntuneStatusBadge(deploymentState);

        // Get status category and icon
        const statusCategory = getStatusCategory(deploymentState);
        const statusIcon = getStatusIcon(statusCategory);

        // Show first matched group + count in table
        let assignedVia = '<span class="text-muted">Unknown</span>';
        if (profile.targetingStatus) {
            const groups = profile.targetingStatus.split(', ');
            const firstGroup = escapeHtml(groups[0]);
            if (groups.length > 1) {
                const additionalCount = groups.length - 1;
                assignedVia = `${firstGroup} <span class="text-muted">(+${additionalCount} more)</span>`;
            } else {
                assignedVia = firstGroup;
            }
        }

        // Settings count badge and expandable row logic
        const hasSettings = profile.settings && profile.settings.length > 0;
        let settingsCountBadge = '';
        let expandableClass = '';
        let dataIdAttr = '';
        let ariaAttr = '';

        if (hasSettings) {
            settingsCountBadge = ` <span class="settings-count">(${profile.settings.length} settings)</span>`;
            expandableClass = ' expandable-row';
            dataIdAttr = ` data-id="profile-${profileRowId}"`;
            ariaAttr = ' aria-expanded="false"';
        }

        // Main row
        html += `
            <tr class="${statusCategory}${expandableClass}" data-status-category="${statusCategory}"${dataIdAttr}${ariaAttr}>
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${name}${settingsCountBadge}</td>
                <td>${description}</td>
                <td>${type}</td>
                <td>${deploymentBadge}</td>
                <td>${assignedVia}</td>
            </tr>
        `;

        // Build expandable detail row with settings sub-table
        if (hasSettings) {
            let settingsRowsHtml = '';
            profile.settings.forEach(setting => {
                const settingName = escapeHtml(setting.name || 'Unknown');
                let settingValue = escapeHtml(String(setting.value || ''));

                // Truncate long values
                if (settingValue.length > 200) {
                    const truncated = settingValue.substring(0, 200);
                    settingValue = `${truncated}<span class="text-muted">... (truncated)</span>`;
                }

                settingsRowsHtml += `
                    <tr>
                        <td>${settingName}</td>
                        <td class="setting-value">${settingValue}</td>
                    </tr>
                `;
            });

            html += `
            <tr id="detail-profile-${profileRowId}" class="detail-row">
                <td colspan="6">
                    <div class="detail-content">
                        <h4>Configured Settings</h4>
                        <table class="settings-table">
                            <thead>
                                <tr>
                                    <th>Setting</th>
                                    <th>Value</th>
                                </tr>
                            </thead>
                            <tbody>
                                ${settingsRowsHtml}
                            </tbody>
                        </table>
                    </div>
                </td>
            </tr>
            `;
        }

        profileRowId++;
    });

    return { html, count: profiles.length };
}

/**
 * Render Compliance Policies table
 */
function renderCompliancePolicies(data) {
    if (!data || !data.compliancePolicies || data.compliancePolicies.length === 0) {
        return { html: '', count: 0 };
    }

    const policies = data.compliancePolicies.sort((a, b) => {
        const aName = (a.displayName || a.name || '').toLowerCase();
        const bName = (b.displayName || b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    policies.forEach(policy => {
        const name = escapeHtml(policy.displayName || policy.name || 'Unknown');
        const platform = escapeHtml(policy.platform || 'Unknown');

        // Show first matched group + count in table
        let assignedVia = '<span class="text-muted">Unknown</span>';
        if (policy.targetingStatus) {
            const groups = policy.targetingStatus.split(', ');
            const firstGroup = escapeHtml(groups[0]);
            if (groups.length > 1) {
                const additionalCount = groups.length - 1;
                assignedVia = `${firstGroup} <span class="text-muted">(+${additionalCount} more)</span>`;
            } else {
                assignedVia = firstGroup;
            }
        }

        const complianceState = policy.complianceState || 'Unknown';
        const complianceBadge = getIntuneStatusBadge(complianceState);

        // Get status category and icon
        const statusCategory = getStatusCategory(complianceState);
        const statusIcon = getStatusIcon(statusCategory);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${name}</td>
                <td>${platform}</td>
                <td>${assignedVia}</td>
                <td>${complianceBadge}</td>
            </tr>
        `;
    });

    return { html, count: policies.length };
}

/**
 * Render Applications table
 */
function renderApplications(data) {
    if (!data || !data.applications || data.applications.length === 0) {
        return { html: '', count: 0 };
    }

    const apps = data.applications.sort((a, b) => {
        const aName = (a.displayName || a.name || '').toLowerCase();
        const bName = (b.displayName || b.name || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    apps.forEach(app => {
        const name = escapeHtml(app.displayName || app.name || 'Unknown');

        // Version handling
        let version = '<span class="text-muted">N/A</span>';
        if (app.appVersion) {
            version = escapeHtml(app.appVersion);
        } else if (app.version) {
            version = escapeHtml(app.version);
        }

        const type = escapeHtml(app.appType || 'Unknown');
        const publisher = escapeHtml(app.publisher || 'Unknown');

        // Intent badge with color coding
        let intentBadge = '<span class="badge badge-secondary">Unknown</span>';
        if (app.intent === 'Required') {
            intentBadge = '<span class="badge badge-danger">Required</span>';
        } else if (app.intent === 'Available') {
            intentBadge = '<span class="badge badge-info">Available</span>';
        } else if (app.intent === 'Uninstall') {
            intentBadge = '<span class="badge badge-warning">Uninstall</span>';
        } else if (app.intent) {
            intentBadge = `<span class="badge badge-secondary">${escapeHtml(app.intent)}</span>`;
        }

        // Show assigned groups
        const assignedVia = app.targetingStatus
            ? escapeHtml(app.targetingStatus)
            : '<span class="text-muted">Unknown</span>';

        // Install state badge with color coding
        // Note: appInstallState is populated from local IME registry (Win32 apps only)
        let installState = 'Unknown';
        if (app.appInstallState) {
            installState = app.appInstallState;
        } else if (app.installedOnDevice === true) {
            installState = 'Installed';
        }

        let installedBadge = '';
        if (installState === 'Installed') {
            installedBadge = '<span class="badge badge-success">Installed</span>';
        } else if (installState === 'Not Installed') {
            installedBadge = '<span class="badge badge-secondary">Not Installed</span>';
        } else if (installState === 'Failed') {
            installedBadge = '<span class="badge badge-danger">Failed</span>';
        } else if (installState === 'Install Pending' || installState === 'Installing') {
            installedBadge = '<span class="badge badge-info">Install Pending</span>';
        } else if (installState === 'Not Applicable') {
            installedBadge = '<span class="badge badge-secondary text-muted">Not Applicable</span>';
        } else if (installState === 'Excluded') {
            installedBadge = '<span class="badge badge-warning">Excluded</span>';
        } else if (installState === 'Unknown') {
            installedBadge = '<span class="badge badge-warning">Unknown</span>';
        } else {
            installedBadge = `<span class="badge badge-secondary">${escapeHtml(installState)}</span>`;
        }

        // Get status category for data attribute and icon
        const statusCategory = getStatusCategory(installState);
        const statusIcon = getStatusIcon(statusCategory);

        html += `
            <tr data-status-category="${statusCategory}">
                <td class="status-icon-cell">${statusIcon}</td>
                <td>${name}</td>
                <td>${version}</td>
                <td>${publisher}</td>
                <td>${type}</td>
                <td>${intentBadge}</td>
                <td>${installedBadge}</td>
                <td>${assignedVia}</td>
            </tr>
        `;
    });

    return { html, count: apps.length };
}

/**
 * Render Proactive Remediations table
 */
function renderProactiveRemediations(data) {
    if (!data || !data.proactiveRemediations || data.proactiveRemediations.length === 0) {
        return { html: '', count: 0 };
    }

    const remediations = data.proactiveRemediations.sort((a, b) => {
        const aName = (a.displayName || '').toLowerCase();
        const bName = (b.displayName || '').toLowerCase();
        return aName.localeCompare(bName);
    });

    let html = '';

    remediations.forEach(remediation => {
        const name = escapeHtml(remediation.displayName || 'Unknown');
        const runAs = escapeHtml(remediation.runAsAccount || 'N/A');
        const targetingStatus = remediation.targetingStatus || 'Unknown';
        const statusBadge = getIntuneStatusBadge(targetingStatus);

        // Device run state details
        let detectionState = 'N/A';
        let remediationState = 'N/A';
        let lastRun = 'N/A';

        if (remediation.deviceRunState) {
            detectionState = remediation.deviceRunState.detectionState || 'N/A';
            remediationState = remediation.deviceRunState.remediationState || 'N/A';
            lastRun = remediation.deviceRunState.lastStateUpdateDateTime || 'N/A';
        }

        const detectionBadge = getIntuneStatusBadge(detectionState);
        const remediationBadge = getIntuneStatusBadge(remediationState);

        html += `
            <tr>
                <td>${name}</td>
                <td>${runAs}</td>
                <td>${detectionBadge}</td>
                <td>${remediationBadge}</td>
                <td>${escapeHtml(lastRun)}</td>
                <td>${statusBadge}</td>
            </tr>
        `;
    });

    return { html, count: remediations.length };
}

/**
 * Main function to render all Intune sections
 * Call this from the main initialization to populate the template
 */
function renderAllIntuneSections(intuneData) {
    if (!intuneData) return;

    // Render Device Groups
    const deviceGroupsResult = renderDeviceGroups(intuneData);
    const deviceGroupsContainer = document.querySelector('#intune-groups-device-section tbody');
    if (deviceGroupsContainer) {
        deviceGroupsContainer.innerHTML = deviceGroupsResult.html;
        updateSectionCount('intune-groups-device-section', deviceGroupsResult.count);
    }

    // Render Configuration Profiles
    const configProfilesResult = renderConfigurationProfiles(intuneData);
    const configProfilesContainer = document.querySelector('#intune-profiles-section tbody');
    if (configProfilesContainer) {
        configProfilesContainer.innerHTML = configProfilesResult.html;
        updateSectionCount('intune-profiles-section', configProfilesResult.count);
    }

    // Render Compliance Policies
    const complianceResult = renderCompliancePolicies(intuneData);
    const complianceContainer = document.querySelector('#intune-compliance-section tbody');
    if (complianceContainer) {
        complianceContainer.innerHTML = complianceResult.html;
        updateSectionCount('intune-compliance-section', complianceResult.count);
    }

    // Render Applications
    const appsResult = renderApplications(intuneData);
    const appsContainer = document.querySelector('#intune-apps-section tbody');
    if (appsContainer) {
        appsContainer.innerHTML = appsResult.html;
        updateSectionCount('intune-apps-section', appsResult.count);
    }

    // Render Proactive Remediations
    const remediationsResult = renderProactiveRemediations(intuneData);
    const remediationsContainer = document.querySelector('#intune-scripts-section tbody');
    if (remediationsContainer) {
        remediationsContainer.innerHTML = remediationsResult.html;
        updateSectionCount('intune-scripts-section', remediationsResult.count);
    }

    // Re-initialize table functionality for newly rendered content
    if (typeof initializeTables === 'function') {
        initializeTables();
    }
    if (typeof initializeTableEnhancements === 'function') {
        initializeTableEnhancements();
    }
}

/**
 * Helper to update section count badges
 */
function updateSectionCount(sectionId, count) {
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
