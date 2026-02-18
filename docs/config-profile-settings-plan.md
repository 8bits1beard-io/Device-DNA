# Plan: Configuration Profile Settings Integration

## Goal
Show **what each configuration profile is actually configuring** — not just "which profiles are assigned and whether they succeeded." When an admin looks at the report, they should be able to expand any profile and see its individual settings and values.

---

## Current State

### What exists today
- `Get-ConfigurationProfiles` (Intune.ps1:886) collects **metadata only** from 3 Graph endpoints (deviceConfigurations, configurationPolicies, groupPolicyConfigurations)
- Reports API export job (`DeviceConfigurationPolicyStatuses`) determines **which profiles are deployed** to the device and their status
- Per-setting **error details** are collected via `ADMXSettingsByDeviceByPolicy` but only for failed profiles, and are **not rendered** in the report
- `Get-ProfileSettings` (Intune.ps1:1635-1794) **already exists** with working logic for all 3 profile types — but is **never called**
- Profile objects have a `settings = @()` field (Intune.ps1:2523) that is **always empty**
- HTML report shows: Name, Description, Type, Status, Assigned Via — **no settings**

### What the test scripts proved
- `Test-ConfigProfileSettings.ps1` — successfully collected settings from 76 legacy + Settings Catalog profiles
- `Test-RemainingProfiles.ps1` — successfully collected settings from 32 additional Settings Catalog + ADMX profiles
- Output: 66 JSON files in `tests/output/` with full settings data
- All 3 profile types work: legacy properties, Settings Catalog `/settings`, ADMX `/definitionValues`

### Key observations from test output
| Profile Type | Setting Keys | Values | Complexity |
|---|---|---|---|
| Settings Catalog | Opaque IDs (`device_vendor_msft_...`) | Enum IDs, JSON, raw values | High — some have 100+ settings, nested JSON |
| ADMX/Admin Templates | Human-readable names | Enabled/Disabled + presentation values | Medium |
| Legacy (deviceConfiguration) | Property names (camelCase) | Booleans, strings, numbers | Low-Medium |
| Certificates | Flat properties | Base64 cert data, filenames, store names | Low — but cert blobs are large |

---

## Implementation Plan

### Phase 1: Wire up `Get-ProfileSettings` in Intune.ps1

**What:** Call the existing `Get-ProfileSettings` function for each deployed profile and populate the `settings` field.

**Where:** `Intune.ps1` lines ~2505-2524, inside the profile object construction loop.

**Changes:**
1. After building the profile object, call `Get-ProfileSettings` for **deployed profiles only** (where `$state.IsDeployed -eq $true`). Skip non-deployed profiles to avoid wasting API calls.
2. Populate `settings` with the returned array instead of `@()`.
3. Add a `-Skip ConfigProfileSettings` option so users can skip this if it's too slow.

**Performance concern:** Each profile requires 1-2 additional API calls. For a device with 70 deployed profiles, that's 70-140 extra calls. Mitigations:
- Only collect for deployed profiles (not all assigned)
- `Get-ProfileSettings` already uses `Invoke-MgGraphRequest` which goes through `Invoke-GraphRequest` retry/backoff
- Actually — `Get-ProfileSettings` calls `Invoke-MgGraphRequest` **directly**, not through `Invoke-GraphRequest`. Should we change this? The direct call skips our retry/pagination wrapper. **Decision needed.**

**Settings Catalog name resolution:** The existing `Get-ProfileSettings` already uses `$expand=settingDefinitions` which resolves opaque IDs to `displayName`. This was already thought through.

**Certificate profiles:** The legacy handler will return `trustedRootCertificate` as a huge base64 blob. We should filter this out or truncate it — nobody needs a cert blob in the HTML report. Add `trustedRootCertificate` and `certContent` to the exclude list.

### Phase 2: Update `Get-ProfileSettings` reliability

**What:** Harden the existing function for production use (it was written but never battle-tested).

**Changes:**
1. **Pagination:** Settings Catalog policies with 100+ settings may paginate. The current code does `Invoke-MgGraphRequest` without following `@odata.nextLink`. Need to add pagination handling or route through `Invoke-GraphRequest`.
2. **Rate limiting:** Direct `Invoke-MgGraphRequest` calls skip our retry logic. Either:
   - (a) Rewrite to use `Invoke-GraphRequest`, OR
   - (b) Add a simple retry wrapper inside `Get-ProfileSettings`
   - **Recommendation:** (a) — use `Invoke-GraphRequest` for consistency
3. **Certificate blob filtering:** Add `trustedRootCertificate`, `certContent`, `trustedServerCertificate` to the exclude list for Device Configuration profiles.
4. **Hashtable handling:** PS 5.1 returns hashtables from `Invoke-MgGraphRequest`, not PSObjects. The Device Configuration branch uses `.PSObject.Properties` which may fail. Verify with test data and fix if needed — use `.Keys` for hashtables like the test scripts do.
5. **ADMX presentation values:** The existing function already fetches these (lines 1753-1760). Each ADMX setting needs an extra API call for presentation values — this doubles the calls for ADMX profiles. Consider making this optional or batching.

### Phase 3: Add settings display to HTML report (Reporting.ps1)

**What:** Add expandable settings detail to each configuration profile row in the report.

**UI approach:** Expandable row. Click a profile row → settings table appears below it. This keeps the main table clean while allowing drill-down.

**Changes to Reporting.ps1:**
1. **JavaScript:** Add click handler to profile rows that toggles a hidden `<tr>` containing the settings sub-table.
2. **Settings sub-table columns:**
   - **Setting Name** — `$setting.name` (human-readable for SC and ADMX, property name for legacy)
   - **Value** — `$setting.value` (decoded/friendly where possible)
   - **Type** — `$setting.dataType` (only show for Settings Catalog — "Choice", "Simple", etc.)
3. **Visual indicators:**
   - Expand/collapse chevron icon on each profile row
   - Setting count badge: "(12 settings)" next to the profile name
   - For profiles with no settings collected: "(settings not available)"
4. **Large value handling:** Truncate values > 200 chars with "Show more" toggle. This handles:
   - Defender exclusion lists (pipe-separated, can be thousands of chars)
   - Firewall rules (nested JSON)
   - Certificate filenames are fine, blobs should already be filtered in Phase 2
5. **Export integration:** Include settings in Markdown/CSV/JSON/Excel exports:
   - CSV: One row per setting (profile name repeated), columns: ProfileName, SettingName, Value
   - JSON: Nested under each profile object
   - Markdown: Sub-list under each profile
   - Excel: Separate "Profile Settings" sheet

### Phase 4: Handle `settingStates` (per-setting errors)

**What:** The `settingStates` data from `ADMXSettingsByDeviceByPolicy` is already collected for failed profiles but never displayed. Cross-reference it with the settings.

**Changes:**
1. For profiles with `deploymentState == 'Error'`, merge `settingStates` with `settings` to show which specific settings failed and their error codes.
2. In the expanded settings sub-table, add a **Status** column that shows per-setting status (Success/Error/Conflict) with error codes.
3. Highlight failed settings in red.

---

## Execution Order

1. **Phase 2 first** — Harden `Get-ProfileSettings` before wiring it up
2. **Phase 1** — Wire it into the collection pipeline
3. **Create integration test** — Run against a real device, verify settings data populates correctly
4. **Phase 3** — HTML report UI
5. **Phase 4** — Per-setting error cross-reference (can be deferred)

---

## Open Questions

1. **Performance:** 70+ extra API calls per device. Is this acceptable? Should we add a progress indicator ("Collecting profile settings [14/72]...")?
2. **Skip granularity:** Should `-Skip ConfigProfileSettings` be the control, or something more fine-grained?
3. **Settings Catalog display names:** The `$expand=settingDefinitions` resolves most names, but some Settings Catalog definitions may return null `displayName`. Fallback to the opaque ID is fine but ugly. Should we attempt a second lookup or just show the ID?
4. **ADMX presentation values:** Each ADMX setting needs an extra API call for sub-values. This could add 50+ calls for a large ADMX policy. Should we skip presentation values to save time and just show Enabled/Disabled?

---

## Files to Modify

| File | Changes |
|------|---------|
| `modules/Intune.ps1` | Phase 1: Call `Get-ProfileSettings`, populate `settings`. Phase 2: Harden function (pagination, retry, PS 5.1 compat, cert filtering) |
| `modules/Reporting.ps1` | Phase 3: Expandable settings rows, sub-table, truncation, export |
| `modules/Orchestration.ps1` | No changes needed — data flows through existing `$collectionData.intune.configurationProfiles` |
| `DeviceDNA.ps1` | Add `ConfigProfileSettings` to `-Skip` valid values if we add that option |

---

## Test Data Available
- 66 JSON files in `tests/output/` with real settings from all profile types
- Log files showing collection flow and timing
- Test scripts that can be re-run to generate fresh data

---

*Created: 2026-02-16*
*Status: DRAFT — awaiting review*
