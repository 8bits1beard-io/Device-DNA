# DeviceDNA Group Policy Data Collection Methods

## Overview
Group Policy data is collected via `gpresult.exe` (XML output). Remote targets use WinRM (`Invoke-Command`). The main orchestrator is `Get-GroupPolicyData`.

---

## GPResult XML (Applied/Denied/Filtered GPOs)
| Item | Detail |
|------|--------|
| **Function** | `Get-GPResultXml` → `ConvertFrom-GPResultXml` |
| **Command** | `gpresult.exe /X {tempfile} /SCOPE COMPUTER` |
| **Method** | Runs gpresult to generate XML report, then parses with `[xml]` |
| **Fallback** | If `/X` fails (older systems), retries with `/X {tempfile} /F` |
| **Scope** | Computer and User configuration |
| **Extracted Data** | Applied GPOs, Denied GPOs, Filtered GPOs — each with name, GUID, link location, status, security filter, WMI filter, version (AD vs SYSVOL) |
| **Settings** | Registry, scripts, and other extension data extracted per-GPO from `ExtensionData` nodes |
| **Metadata** | Domain, site name, domain controller, slow link status |

## GP Refresh
| Item | Detail |
|------|--------|
| **Function** | `Invoke-GPUpdate` |
| **Command** | `gpupdate /force` |
| **Method** | Runs before GPResult collection (optional, skippable) |
| **Timeout** | 300 seconds (configurable via `-TimeoutSeconds`) |
| **Execution** | Local: `Start-Job` with `Wait-Job -Timeout`; Remote: `Invoke-Command -AsJob` |
| **Output** | Success boolean, computer/user policy status, raw output |

## RSoP Debug Logging
| Item | Detail |
|------|--------|
| **Function** | `Set-RSoPLogging` |
| **Registry Path** | `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Diagnostics` |
| **Registry Value** | `GPSvcDebugLevel` = `0x30002` (full debug) |
| **Method** | Enables before collection, restores original value after (in `finally` block) |
| **Note** | Optional — requires admin rights, collection continues without it |

---

## Collection Flow (`Get-GroupPolicyData`)

1. **Enable RSoP logging** (optional) — `Set-RSoPLogging -Enable`
2. **Run gpupdate /force** (optional, 300s timeout) — `Invoke-GPUpdate`
3. **Collect GPResult XML** (computer scope) — `Get-GPResultXml`
4. **Parse XML** into structured GPO data — `ConvertFrom-GPResultXml`
5. **Restore RSoP logging** (in `finally` block) — `Set-RSoPLogging -OriginalValue`
