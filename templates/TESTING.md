# DeviceDNA Template Testing Guide

## Quick Test (Local Files)

### Option 1: Open with URL Parameter

1. **Start a local web server** (required due to CORS restrictions):
   ```bash
   cd templates/
   python3 -m http.server 8000
   ```

2. **Open in browser**:
   ```
   http://localhost:8000/DeviceDNA-Report.html?data=test-data.json
   ```

### Option 2: Embed Test Data

1. **Edit DeviceDNA-Report.html** - Replace the empty JSON in `<script id="policy-data">` with contents of `test-data.json`

2. **Open directly** in browser:
   ```bash
   open DeviceDNA-Report.html
   # or
   start DeviceDNA-Report.html
   ```

---

## Files in Templates Directory

```
templates/
├── DeviceDNA-Report.html           # Main template (HTML structure)
├── extracted-css.css               # All CSS styling (2,740 lines)
├── extracted-javascript.js         # Core interactive features (2,097 lines)
├── render-intune.js               # Intune section rendering (466 lines)
├── render-other-sections.js       # GP/SCCM/WU rendering (763 lines)
├── render-overview-device.js      # Overview/Device rendering (544 lines)
├── test-data.json                 # Sample test data
└── TESTING.md                     # This file
```

---

## Expected Behavior

When you load the template with test data, you should see:

### Header
- **Device Name:** TEST-PC-001
- **Operating System:** Microsoft Windows 11 Pro 23H2
- **Serial Number:** ABC123XYZ789
- **Join Type:** Azure AD Joined
- **Management:** Microsoft Intune

### Tab Navigation
Six tabs should be visible:
- **Overview** ✅ (active by default)
- **Group Policy** (empty - cloud-only device)
- **Intune** ✅ (has data)
- **SCCM** (empty - no SCCM client)
- **Windows Updates** ✅ (has data)
- **Device** ✅ (has device info)

### Overview Tab
Should render:
1. **Executive Dashboard** - Device health cards
2. **Issue Summary** - No critical issues
3. **Collection Issues** - 1 info message ("SCCM client not detected")

### Intune Tab
Should render 5 sections (all collapsed):
1. **Entra ID - Device Groups** (4 groups)
2. **Configuration Profiles** (3 profiles)
   - First profile should have "(3 settings)" badge
   - Click to expand and see settings
   - Third profile should have error status (red dot)
3. **Compliance Policies** (2 policies, both compliant)
4. **Applications** (5 apps)
5. **Proactive Remediations** (1 remediation)

### Windows Update Tab
Should render 4 sections (all collapsed):
1. **Windows Update Summary**
   - "Managed By" badge: **Intune - Windows Update for Business** (green)
   - Service State: Running
   - Last Scan: recent date
2. **Update Policy Settings** (2 settings)
3. **Pending Updates** (2 updates)
4. **Update History** (2 successful installations)

### Device Tab
Should render:
1. **Device Information** - Hardware specs

---

## Testing Checklist

### Visual Alignment ✅ **CRITICAL**
- [ ] **Device Groups table** - Headers align with data
  - Group Name column should be directly above group names
  - Type column should be directly above types
  - ID column should be directly above IDs
- [ ] **Configuration Profiles table** - Headers align with data
- [ ] **Compliance Policies table** - Headers align with data
- [ ] **Applications table** - Headers align with data
- [ ] **Windows Update tables** - Headers align with data
- [ ] Run browser console: `copy(diagnoseAllTables())` (if diagnostic script loaded)
  - All offsets should be 0px ✅

### Interactive Features
- [ ] **Section collapse/expand** - Click section headers
- [ ] **Config profile expand** - Click profile row to see settings
- [ ] **Table sorting** - Click column headers to sort
- [ ] **Table filtering** - Type in search boxes
- [ ] **Theme toggle** - Click moon icon (top right)
- [ ] **Export dropdown** - Click "Export" button
  - [ ] Markdown export
  - [ ] CSV export
  - [ ] JSON export
  - [ ] Excel export (requires SheetJS CDN)

### Tab Navigation
- [ ] **Click tabs** - Switch between Overview/GP/Intune/SCCM/WU/Device
- [ ] **Mobile dropdown** - Resize to mobile and test dropdown selector
- [ ] **Keyboard nav** - Tab key navigation works

### Status Icons & Badges
- [ ] **Configuration Profiles** - Red dot on "Windows - Defender Antivirus"
- [ ] **Compliance Policies** - Green checkmark on both policies
- [ ] **Applications** - Green/yellow/gray dots based on install state
- [ ] **Windows Update Summary** - Green "Managed By" badge

### Empty States
- [ ] **Group Policy** - Shows empty state (cloud-only device)
- [ ] **SCCM** - Shows empty state (no client)

### Data Rendering
- [ ] All section counts match actual items
- [ ] Navigation badges show correct counts
- [ ] Settings expandable rows show correct settings
- [ ] Dates formatted correctly (locale-specific)

---

## Browser Console Checks

Open DevTools (F12) and check for:

### No Errors ✅
```javascript
// Should see:
"Rendering report with data: ..."
"renderOverview called"
"renderIntune called"
// etc.

// Should NOT see any red errors
```

### Data Loaded ✅
```javascript
console.log(deviceData);
// Should output full JSON object
```

### Sections Rendered ✅
```javascript
// Check if sections have content
document.querySelectorAll('.section').length  // Should be > 0
document.querySelectorAll('table tbody tr').length  // Should be > 0
```

---

## Troubleshooting

### "Failed to load data file"
**Cause:** CORS restrictions on `file://` protocol
**Solution:** Use local web server (see Option 1 above)

### "No data source found"
**Cause:** No `?data=` parameter and no embedded data
**Solution:** Add `?data=test-data.json` or embed JSON in template

### Sections empty but no errors
**Cause:** Render functions not loaded
**Solution:** Check browser console for script load errors

### Column headers misaligned
**Cause:** CSS padding compensation issue
**Solution:** Check browser console, run diagnostic:
```javascript
// Paste diagnose-all-tables.js code into console
```

### Theme toggle not working
**Cause:** `extracted-javascript.js` not loaded
**Solution:** Verify file path and script tag

### Export buttons not working
**Cause:** Functions not defined
**Solution:** Verify `extracted-javascript.js` loaded

---

## Next Steps After Testing

1. ✅ **Verify column alignment** - Most critical issue to fix
2. ✅ **Test all interactive features**
3. ✅ **Test with real DeviceDNA JSON** (from actual collection)
4. ⏳ **Integrate with Reporting.ps1** (Phase 2)
5. ⏳ **Test end-to-end workflow**

---

## Performance Notes

### Expected Load Time
- **Initial load:** < 1 second
- **JSON parsing:** < 100ms (even for large datasets)
- **Rendering:** < 500ms for typical device

### Large Dataset Handling
- **Group Policy Settings:** 1000+ rows may take 1-2 seconds to render
- **SCCM Updates:** 500+ rows may take 500ms-1s to render
- **Recommendation:** Keep tables collapsed by default (already implemented)

---

## Diagnostic Commands

Paste these into browser console to debug issues:

### Check All Tables
```javascript
document.querySelectorAll('table').forEach((t, i) => {
    const section = t.closest('.section')?.querySelector('h2')?.textContent || 'Unknown';
    const rows = t.querySelectorAll('tbody tr').length;
    console.log(`Table ${i+1}: ${section} - ${rows} rows`);
});
```

### Check Section Counts
```javascript
document.querySelectorAll('.section-count').forEach(el => {
    console.log(`${el.closest('.section-header')?.querySelector('h2')?.textContent}: ${el.textContent}`);
});
```

### Check Data Structure
```javascript
console.log('Device Groups:', deviceData.intune?.deviceGroups?.length || 0);
console.log('Config Profiles:', deviceData.intune?.configurationProfiles?.length || 0);
console.log('Applications:', deviceData.intune?.applications?.length || 0);
```

### Verify Render Functions Loaded
```javascript
console.log('renderAllIntuneSections:', typeof renderAllIntuneSections);
console.log('renderAllOtherSections:', typeof renderAllOtherSections);
console.log('renderOverviewTab:', typeof renderOverviewTab);
console.log('renderDeviceTab:', typeof renderDeviceTab);
```

---

## Known Limitations (Current Phase)

- ⚠️ **No live data updates** - Refresh page to reload data
- ⚠️ **CORS on file:///** - Must use local server or embedded data
- ⚠️ **Large tables** - No virtual scrolling (may be slow with 5000+ rows)
- ⚠️ **Excel export** - Requires CDN access to SheetJS

---

## Success Criteria

Template is ready for Phase 2 integration when:

- ✅ All sections render correctly
- ✅ All column headers align with data
- ✅ All interactive features work
- ✅ Theme toggle works
- ✅ Export functions work
- ✅ No console errors
- ✅ Expandable config profile settings work
- ✅ Mobile responsive design works
