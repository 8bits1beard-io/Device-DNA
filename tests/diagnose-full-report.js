// Diagnostic script to run in browser console on the FULL Device DNA report
// Copy this entire script, open DevTools on the report, paste in console, press Enter

console.log('=== Device DNA Column Alignment Diagnostic ===\n');

// Find all tables with status-icon-col
const tables = document.querySelectorAll('table');
console.log(`Found ${tables.length} tables total\n`);

tables.forEach((table, tableIndex) => {
    const statusIconHeader = table.querySelector('thead th.status-icon-col');

    if (!statusIconHeader) {
        return; // Skip tables without status icon column
    }

    // Get section name from parent
    const section = table.closest('.section');
    const sectionName = section ? section.querySelector('h2')?.textContent.trim() : 'Unknown Section';

    console.log(`\n📊 Table ${tableIndex + 1}: ${sectionName}`);
    console.log('─'.repeat(60));

    // Get first row
    const firstDataRow = table.querySelector('tbody > tr:not(.detail-row)');
    if (!firstDataRow) {
        console.log('  ⚠️  No data rows found');
        return;
    }

    // Measure all columns
    const headers = Array.from(table.querySelectorAll('thead th'));
    const cells = Array.from(firstDataRow.querySelectorAll('td'));

    if (headers.length !== cells.length) {
        console.log(`  ⚠️  Column mismatch: ${headers.length} headers, ${cells.length} cells`);
    }

    // Check each column alignment
    let hasIssues = false;
    headers.forEach((header, i) => {
        const cell = cells[i];
        if (!cell) return;

        const headerRect = header.getBoundingClientRect();
        const cellRect = cell.getBoundingClientRect();
        const offset = Math.round(headerRect.left - cellRect.left);

        const headerStyles = window.getComputedStyle(header);
        const cellStyles = window.getComputedStyle(cell);

        if (i === 0) {
            // First column - status icon
            console.log(`  Column ${i} (status-icon):`);
            console.log(`    Header padding-left: ${headerStyles.paddingLeft}`);
            console.log(`    Cell padding-left: ${cellStyles.paddingLeft}`);
            console.log(`    Cell border-left: ${cellStyles.borderLeft}`);
            console.log(`    Offset: ${offset}px ${offset !== 0 ? '❌ MISALIGNED' : '✅'}`);

            if (offset !== 0) {
                hasIssues = true;
                // Show what would fix it
                const currentPadding = parseInt(headerStyles.paddingLeft);
                const suggestedPadding = currentPadding + offset;
                console.log(`    💡 Suggestion: Set header padding-left to ${suggestedPadding}px`);
            }
        } else {
            // Other columns
            if (Math.abs(offset) > 1) { // Allow 1px rounding error
                console.log(`  Column ${i}: offset = ${offset}px ❌`);
                hasIssues = true;
            }
        }
    });

    if (!hasIssues) {
        console.log('  ✅ All columns aligned correctly!');
    }

    // Check for CSS overrides
    const headerPaddingLeft = window.getComputedStyle(statusIconHeader).paddingLeft;
    console.log(`\n  Applied padding-left on .status-icon-col: ${headerPaddingLeft}`);

    // Check if there are any inline styles
    if (statusIconHeader.style.paddingLeft) {
        console.log(`  ⚠️  Inline style found: padding-left = ${statusIconHeader.style.paddingLeft}`);
    }

    // Check CSS specificity issues
    const allStyles = [];
    for (let sheet of document.styleSheets) {
        try {
            for (let rule of sheet.cssRules) {
                if (rule.selectorText && rule.selectorText.includes('status-icon-col')) {
                    allStyles.push({
                        selector: rule.selectorText,
                        paddingLeft: rule.style.paddingLeft || 'not set'
                    });
                }
            }
        } catch (e) {
            // Skip CORS-protected stylesheets
        }
    }

    if (allStyles.length > 0) {
        console.log(`\n  📋 All .status-icon-col CSS rules found:`);
        allStyles.forEach(style => {
            console.log(`    ${style.selector} → padding-left: ${style.paddingLeft}`);
        });
    }
});

console.log('\n' + '='.repeat(60));
console.log('Diagnostic complete. Look for ❌ MISALIGNED markers above.');
console.log('='.repeat(60));
