// Diagnostic for ALL tables (not just status-icon ones)
console.log('=== ALL TABLES Diagnostic ===\n');

const tables = document.querySelectorAll('table');
console.log(`Found ${tables.length} tables total\n`);

tables.forEach((table, tableIndex) => {
    // Get section name
    const section = table.closest('.section');
    const sectionName = section ? section.querySelector('h2')?.textContent.trim() : 'Unknown';

    console.log(`\n📊 Table ${tableIndex + 1}: ${sectionName}`);
    console.log('─'.repeat(60));

    // Get first row
    const firstDataRow = table.querySelector('tbody > tr:not(.detail-row)');
    if (!firstDataRow) {
        console.log('  No data rows');
        return;
    }

    // Measure first column only
    const firstHeader = table.querySelector('thead th');
    const firstCell = firstDataRow.querySelector('td');

    if (!firstHeader || !firstCell) {
        console.log('  Missing header or cell');
        return;
    }

    const headerRect = firstHeader.getBoundingClientRect();
    const cellRect = firstCell.getBoundingClientRect();
    const offset = Math.round(headerRect.left - cellRect.left);

    const headerStyles = window.getComputedStyle(firstHeader);
    const cellStyles = window.getComputedStyle(firstCell);

    console.log(`  First Column:`);
    console.log(`    Header classes: ${firstHeader.className || 'none'}`);
    console.log(`    Header padding-left: ${headerStyles.paddingLeft}`);
    console.log(`    Cell padding-left: ${cellStyles.paddingLeft}`);
    console.log(`    Cell border-left: ${cellStyles.borderLeftWidth} ${cellStyles.borderLeftStyle}`);
    console.log(`    Offset: ${offset}px ${Math.abs(offset) > 1 ? '❌' : '✅'}`);

    if (Math.abs(offset) > 1) {
        const currentPadding = parseInt(headerStyles.paddingLeft);
        const suggestedPadding = currentPadding - offset;
        console.log(`    💡 Fix: Change header padding-left from ${currentPadding}px to ${suggestedPadding}px`);
    }
});

console.log('\n' + '='.repeat(60));
