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

    // Render all sections (pass policyData to render functions)
    if (typeof renderHeader === 'function') {
        renderHeader(policyData);
    }
    if (typeof renderCollectionIssues === 'function') {
        renderCollectionIssues(policyData);
    }
    if (typeof renderOverviewTab === 'function') {
        renderOverviewTab(policyData);
    }
    if (typeof renderDeviceTab === 'function') {
        renderDeviceTab(policyData);
    }
    if (typeof renderAllOtherSections === 'function') {
        renderAllOtherSections(policyData);
    }
    if (typeof renderAllIntuneSections === 'function') {
        renderAllIntuneSections(policyData.intune);
    }
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

