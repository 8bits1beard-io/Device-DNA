# Phase 3 Testing Guide

**Status:** Ready for testing
**Date:** 2026-02-17

---

## Quick Start

### Option 1: Automated PowerShell Test (Windows)
```powershell
# Run all tests
.\tests\Test-Phase3-EndToEnd.ps1

# Skip collection, just validate files
.\tests\Test-Phase3-EndToEnd.ps1 -SkipCollection

# Run collection and open report
.\tests\Test-Phase3-EndToEnd.ps1 -OpenReport
```

### Option 2: Browser-Based Template Test
```powershell
# Start local web server
cd templates/
python -m http.server 8000

# Open in browser:
# http://localhost:8000/Test-Template-Browser.html
```

### Option 3: Manual End-to-End Test
```powershell
# Run DeviceDNA collection
.\DeviceDNA.ps1 -AutoOpen

# Or remote
.\DeviceDNA.ps1 -ComputerName "PC001" -AutoOpen
```

---

## Test Scripts Created

### 1. **Test-Phase3-EndToEnd.ps1** (PowerShell)
**Location:** `tests/Test-Phase3-EndToEnd.ps1`

**What it tests:**
- ✅ File structure (templates directory, all required files)
- ✅ PowerShell functions (Export-DeviceDNAJson, Copy-DeviceDNATemplate)
- ✅ Template rendering (valid JSON, data structure)
- ✅ DeviceDNA collection (optional, can skip)
- ✅ Code reduction (Reporting.ps1 ~5300 lines)
- ℹ️ Alignment test instructions (manual browser check)

**Usage:**
```powershell
# Run all tests
.\tests\Test-Phase3-EndToEnd.ps1

# Output:
# =============================================
#   Phase 3: End-to-End Test
#   DeviceDNA Template Migration
# =============================================
#
# [1/6] Validating File Structure...
#   ✅ Templates directory exists
#   ✅ Template file: DeviceDNA-Report.html
#   ...
#
# [2/6] Validating PowerShell Functions...
#   ✅ Reporting.ps1 exists
#   ✅ Export-DeviceDNAJson function exists
#   ...
#
# Passed: 15
# Failed: 0
#
# ✅ All tests passed! Phase 3 looks good.
```

### 2. **Test-Template-Browser.html** (Browser)
**Location:** `tests/Test-Template-Browser.html`

**What it tests:**
- ✅ Template file loading
- ✅ Test data parsing
- ✅ Column alignment check (with console script)
- ✅ Interactive features checklist
- ✅ Visual preview in iframe

**Usage:**
```bash
# Start web server
cd templates/
python -m http.server 8000

# Open in browser
http://localhost:8000/Test-Template-Browser.html
```

**Features:**
- **Test 1:** Load template files and validate test data
- **Test 2:** Column alignment check with console script
- **Test 3:** Interactive features checklist
- **Test 4:** Visual preview in iframe

---

## Critical Tests

### 🎯 Test #1: Column Alignment (MOST IMPORTANT)

This is the original bug we're fixing - headers were shifted too far left.

**Steps:**
1. Open template with test data in browser
2. Navigate to **Intune → Entra ID - Device Groups**
3. Open browser DevTools (F12)
4. Paste this into console:

```javascript
const table = document.querySelector('#device-groups-content table');
if (table) {
    const firstHeader = table.querySelector('thead th');
    const firstCell = table.querySelector('tbody tr td');
    const offset = Math.round(firstHeader.getBoundingClientRect().left - firstCell.getBoundingClientRect().left);
    console.log('Offset:', offset, offset === 0 ? '✅ ALIGNED' : '❌ MISALIGNED');
} else {
    console.log('❌ Table not found');
}
```

**Expected:** `Offset: 0 ✅ ALIGNED`

**If misaligned:**
- Offset > 0 means header too far right
- Offset < 0 means header too far left (this was the original bug)

**Test all tables:**
```javascript
document.querySelectorAll('table').forEach((t, i) => {
    const section = t.closest('.section')?.querySelector('h2')?.textContent || 'Unknown';
    const firstHeader = t.querySelector('thead th');
    const firstCell = t.querySelector('tbody tr td');
    if (firstHeader && firstCell) {
        const offset = Math.round(firstHeader.getBoundingClientRect().left - firstCell.getBoundingClientRect().left);
        console.log(`Table ${i+1} (${section}): Offset ${offset}px ${Math.abs(offset) > 1 ? '❌' : '✅'}`);
    }
});
```

### 🎯 Test #2: Expandable Configuration Profiles

This feature broke alignment in the original implementation.

**Steps:**
1. Open template
2. Navigate to **Intune → Configuration Profiles**
3. Find "Windows - Security Baseline" row
4. Look for **(3 settings)** badge in the name column
5. Click the row to expand
6. Verify nested settings table appears with 3 rows

**Expected:**
- Row expands smoothly
- Settings table shows: Setting | Value
- 3 settings visible:
  - Allow Camera → Block
  - Allow Cortana → Block
  - BitLocker - Require Device Encryption → Enabled

### 🎯 Test #3: Windows Update "Managed By" Badge

This was added in Phase 1.

**Steps:**
1. Open template
2. Navigate to **Windows Updates → Windows Update Summary**
3. Find "Managed By" field

**Expected:**
- Badge shows: **Intune - Windows Update for Business**
- Badge color: Green (success)

### 🎯 Test #4: Theme Toggle

**Steps:**
1. Click moon icon (top right toolbar)
2. Verify dark theme applied
3. Refresh page
4. Verify theme persists

**Expected:**
- Smooth transition to dark theme
- All text readable
- Theme persists after refresh (stored in localStorage)

### 🎯 Test #5: Export Functions

**Steps:**
1. Click "Export ▼" dropdown
2. Try each export format:
   - Markdown (.md)
   - CSV (.csv)
   - JSON (.json)
   - Excel (.xlsx) - requires internet for SheetJS CDN

**Expected:**
- Each format downloads correctly
- Files open in appropriate applications
- Data is complete and properly formatted

---

## Full Test Checklist

### File Structure
- [ ] `templates/` directory exists
- [ ] All 7 template files present (HTML + 6 JS/CSS)
- [ ] `test-data.json` exists and is valid JSON
- [ ] `modules/Reporting.ps1` is ~5300 lines (down from 7207)
- [ ] `modules/Orchestration.ps1` updated

### PowerShell Functions
- [ ] `Export-DeviceDNAJson` function exists in Reporting.ps1
- [ ] `Copy-DeviceDNATemplate` function exists in Reporting.ps1
- [ ] `New-DeviceDNAReport` function calls new functions
- [ ] Orchestration.ps1 handles hashtable return value

### Template Rendering
- [ ] Template loads without errors
- [ ] Test data parses correctly
- [ ] All sections present (Overview, GP, Intune, SCCM, WU, Device)
- [ ] Header shows device info correctly
- [ ] Navigation tabs work
- [ ] Mobile responsive (resize window)

### Data Display
- [ ] Device Groups table shows 4 groups
- [ ] Configuration Profiles table shows 3 profiles
- [ ] Compliance Policies table shows 2 policies
- [ ] Applications table shows 5 apps
- [ ] Proactive Remediations table shows 1 remediation
- [ ] Windows Update shows "Managed By" badge

### Interactive Features
- [ ] **Column alignment perfect on ALL tables** ⭐
- [ ] Table sorting works (click headers)
- [ ] Table filtering works (search boxes)
- [ ] **Expandable rows work** (config profiles)
- [ ] Section collapse/expand works
- [ ] All sections start collapsed except Overview
- [ ] Theme toggle works
- [ ] Export dropdown works (4 formats)

### End-to-End Collection
- [ ] `.\DeviceDNA.ps1` runs without errors
- [ ] JSON file created in output directory
- [ ] Template files copied to output directory
- [ ] 6 render module files copied
- [ ] Log file created
- [ ] README.md created
- [ ] AutoOpen works (if specified)
- [ ] Browser opens correct URL with `?data=` parameter

### Edge Cases
- [ ] Empty sections display properly (GP, SCCM)
- [ ] Large datasets render (simulate 1000+ GP settings)
- [ ] Special characters in names don't break display
- [ ] Null/undefined values handled gracefully

---

## Known Issues & Workarounds

### Issue: Browser CORS Error
**Symptom:** "Access to fetch at 'file://...' from origin 'null' has been blocked by CORS policy"

**Cause:** Some browsers block local file access via fetch() when using file:// protocol

**Workaround:**
```bash
# Use local web server instead
cd output/<device>/
python -m http.server 8000

# Open in browser
http://localhost:8000/DeviceDNA-Report.html?data=<jsonfile>.json
```

### Issue: AutoOpen Doesn't Open Browser
**Symptom:** Collection completes but browser doesn't open

**Cause:** file:// URL format or browser association

**Workaround:**
```powershell
# Manually open the template
cd output/<device>/
$template = Get-ChildItem "DeviceDNA-Report.html"
$json = Get-ChildItem "*.json"
Start-Process "file:///$($template.FullName)?data=$($json.Name)"
```

### Issue: SheetJS Excel Export Not Working
**Symptom:** Excel export button does nothing or shows error

**Cause:** CDN not accessible or blocked by network

**Workaround:**
- Ensure internet connectivity
- Check if `cdn.sheetjs.com` is accessible
- Use CSV export instead

---

## Troubleshooting

### Problem: Test data shows "Unknown" values
**Solution:** Check test-data.json has all required fields

### Problem: Sections show "No data" or empty
**Solution:** Verify test data structure matches expected format (see test-data.json)

### Problem: JavaScript errors in browser console
**Solution:**
1. Check all JS files loaded (Network tab)
2. Verify file paths are correct
3. Check for CORS errors

### Problem: Alignment still broken
**Solution:**
1. Run alignment diagnostic (see Test #1 above)
2. Check if extracted-css.css loaded correctly
3. Verify padding compensation in CSS:
   - Non-status-icon tables: 19px
   - Status-icon tables: 12px

---

## Success Criteria

Phase 3 passes when:

- ✅ All automated tests pass (Test-Phase3-EndToEnd.ps1)
- ✅ **Column alignment perfect on ALL tables** (offset = 0px)
- ✅ Expandable config profiles work
- ✅ Theme toggle works
- ✅ Export functions work
- ✅ End-to-end collection creates all files
- ✅ AutoOpen works
- ✅ No console errors
- ✅ All sections render correctly

---

## After Testing

### If All Tests Pass:
1. Commit changes with message: "Complete template migration - Phase 3 tested"
2. Proceed to Phase 4 (Documentation & Cleanup)

### If Tests Fail:
1. Document failures in GitHub issue
2. Run diagnostics to identify root cause
3. Fix issues and re-test
4. Do NOT proceed to Phase 4 until all tests pass

---

## Test Results Template

Copy this to report results:

```
## Phase 3 Test Results

**Date:** YYYY-MM-DD
**Tester:** Your Name
**Environment:** Windows 10/11, PowerShell 5.1/7.x, Browser Name/Version

### Automated Tests (Test-Phase3-EndToEnd.ps1)
- Passed: X
- Failed: Y
- Details: (paste summary)

### Manual Tests
- Column Alignment: ✅ / ❌ (offset: Xpx)
- Expandable Rows: ✅ / ❌
- Theme Toggle: ✅ / ❌
- Export Functions: ✅ / ❌
- End-to-End Collection: ✅ / ❌

### Issues Found
1. (list any issues)

### Screenshots
(attach screenshots of alignment test, report rendering, etc.)

### Overall: PASS / FAIL
```

---

**Questions?** See:
- `templates/PHASE1-COMPLETE.md` - Template architecture
- `templates/PHASE2-COMPLETE.md` - PowerShell integration
- `templates/TESTING.md` - Template testing guide
