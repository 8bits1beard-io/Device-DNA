# DeviceDNA Intune Data Collection Methods

## Overview
All Graph API calls go through `Invoke-GraphRequest` which handles auto-pagination (`@odata.nextLink`), 429 throttling retry, and 5xx exponential backoff (max 3 retries).

---

## Device Discovery
| Item | Detail |
|------|--------|
| **Function** | `Find-AzureADDevice` → `Get-IntuneDevice` |
| **Endpoints** | `GET /v1.0/devices?$filter=displayName eq '{name}'` → `GET /beta/deviceManagement/managedDevices?$filter=azureADDeviceId eq '{id}'` |
| **Method** | Two sequential GETs — resolves Azure AD object, then finds Intune managed device |
| **Disambiguation** | When multiple Azure AD devices share the same displayName (e.g. stale/orphaned records): 1) If `DeviceId` parameter provided, exact match by hardware GUID. 2) Otherwise prefer device with `isManaged=True`. 3) If still ambiguous, pick most recent `approximateLastSignInDateTime`. |
| **Fallback** | If Azure AD ID lookup fails, falls back to device name search |

## Device Group Memberships
| Item | Detail |
|------|--------|
| **Function** | `Get-DeviceGroupMemberships` |
| **Endpoint** | `GET /v1.0/devices/{ObjectId}/transitiveMemberOf?$top=999` |
| **Method** | Single GET with transitive membership (includes nested groups) |
| **Caching** | Group names cached in `$script:GroupNameCache` via `Resolve-GroupDisplayNames` |

## Configuration Profiles (4 policy types)
| Item | Detail |
|------|--------|
| **Function** | `Get-ConfigurationProfiles` |
| **Endpoints** | `GET /beta/deviceManagement/deviceConfigurations?$expand=assignments&$top=999` (Device Config) |
| | `GET /beta/deviceManagement/configurationPolicies?$expand=assignments&$top=999` (Settings Catalog) |
| | `GET /beta/deviceManagement/groupPolicyConfigurations?$expand=assignments&$top=999` (Admin Templates) |
| | `GET /beta/deviceManagement/intents?$expand=assignments&$top=999` (Endpoint Security) |
| **Method** | Four separate GETs, all with `$expand=assignments` for inline assignment data |

## Configuration Profile Settings Detail
| Item | Detail |
|------|--------|
| **Function** | `Get-ProfileSettings` |
| **Endpoints** | Settings Catalog: `GET /beta/.../configurationPolicies/{id}/settings?$expand=settingDefinitions` |
| | Device Config: `GET /beta/.../deviceConfigurations/{id}` |
| | Admin Templates: `GET /beta/.../groupPolicyConfigurations/{id}/definitionValues?$expand=definition` + per-definition `GET .../presentationValues` |
| **Note** | Settings Catalog and Device Config are single calls; Admin Templates require N+1 for presentation values |

## Configuration Profile Per-Device Status
| Item | Detail |
|------|--------|
| **Function** | Part of `Get-IntuneData` (Step 5) |
| **Endpoint** | `POST /beta/deviceManagement/reports/exportJobs` |
| **Method** | Async Reports API: POST to create job → poll via `Wait-ExportJobCompletion` → download CSV from Azure Blob → `Import-Csv` |
| **Timing** | ~30s for 70 profiles |

## Applications
| Item | Detail |
|------|--------|
| **Function** | `Get-IntuneApplications` |
| **Endpoint** | `GET /beta/deviceAppManagement/mobileApps?$expand=assignments&$top=999` |
| **Method** | Single GET, auto-paginated |
| **Types** | Win32, MSI, Web, Office Suite, Store — detected from `@odata.type` |

## App Install Status
| Item | Detail |
|------|--------|
| **Function** | `Get-LocalIntuneApplications` (LocalIntune.ps1) |
| **Source** | Registry: `HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps` |
| **Method** | Local registry read via `Invoke-Command` — reads ComplianceState + EnforcementState |
| **Timing** | ~50ms (replaced Reports API that took ~2-3 min) |
| **Mapping** | EnforcementState: 1000=Installed, 2000-2999=Pending, 3000-3999=NotApplicable, 4000+=Failed |
| **Limitation** | Win32 apps only — non-Win32 show "Unknown" |

> **Note:** App install status and other local Intune data (MDM diagnostics, MDM configuration, local compliance state) are collected from the device registry, not Graph API. See [device-collection-methods.md](device-collection-methods.md) for full details.

## Compliance Policies
| Item | Detail |
|------|--------|
| **Function** | `Get-CompliancePolicies` + `Get-DeviceCompliancePolicyStates` |
| **Endpoints** | `GET /beta/.../deviceCompliancePolicies?$expand=assignments&$top=999` (definitions) |
| | `POST /beta/.../reports/getDevicePoliciesComplianceReport` (per-device status) |
| **Method** | GET for definitions + synchronous POST for device-specific state |
| **POST Body** | `{ filter: "(DeviceId eq '{IntuneDeviceId}')", select: [...], top: 50 }` |
| **Note** | Sync Reports API — returns inline JSON with Schema/Values (no polling) |

## Proactive Remediations
| Item | Detail |
|------|--------|
| **Function** | `Get-ProactiveRemediations` + device states in `Get-IntuneData` Step 7 |
| **Endpoints** | `GET /beta/.../deviceHealthScripts?$expand=assignments&$top=999` (definitions) |
| | `GET /beta/.../managedDevices/{id}/deviceHealthScriptStates` (per-device states) |
| **Method** | Two GETs — definitions with assignments, then all run states for target device in one call |
| **Timing** | ~460ms for 29 remediations |

## Assignment Filters
| Item | Detail |
|------|--------|
| **Function** | `Get-AssignmentFilters` |
| **Endpoint** | `GET /beta/deviceManagement/assignmentFilters?$top=999` |
| **Method** | Single GET |

---

## Infrastructure Patterns

| Pattern | Detail |
|---------|--------|
| **Graph Wrapper** | `Invoke-GraphRequest` — auto-pagination, 429/5xx retry (3 attempts, exponential backoff) |
| **Reports API (async)** | POST export job → `Wait-ExportJobCompletion` (500ms→4s backoff, 60s max) → download CSV → `Import-Csv` |
| **Reports API (sync)** | POST with filter/select → inline Schema/Values JSON response |
| **Group Name Cache** | `$script:GroupNameCache` avoids redundant per-group API calls |
| **Error Tracking** | All issues accumulated in `$script:CollectionIssues` array |
