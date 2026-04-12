# DAMOps Module Reference

Complete parameter reference for every DAMOps function.

---

## Connect-DAMOps

**Module:** Connect.ps1
**Purpose:** Authenticate to Microsoft Entra ID and validate NVIDIA API key.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Tenant` | String | ✅ | — | Entra ID tenant domain (e.g. contoso.onmicrosoft.com) |
| `-AuthMethod` | String | ❌ | `DeviceCode` | Auth flow: `DeviceCode` or `ServicePrincipal` |
| `-ClientId` | String | ❌ | — | App registration client ID (ServicePrincipal only) |
| `-ClientSecret` | String | ❌ | — | Client secret value (ServicePrincipal only) |
| `-DryRun` | Switch | ❌ | — | Preview connection parameters without connecting |

**Returns:** `PSCustomObject` with Tenant, AuthMethod, GraphScopes, GraphStatus, AIStatus, ConnectedAt

```powershell
# Interactive login
Connect-DAMOps -Tenant contoso.onmicrosoft.com

# Service Principal (automated)
Connect-DAMOps -Tenant contoso.onmicrosoft.com -AuthMethod ServicePrincipal `
    -ClientId "abc-123" -ClientSecret "secret"

# Preview only
Connect-DAMOps -Tenant contoso.onmicrosoft.com -DryRun
```

---

## Invoke-AccessAudit

**Module:** AccessAudit.ps1
**Purpose:** Audit stale accounts, inactive guests, and privileged role holders.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-StaleThreshold` | Int | ❌ | `90` | Days since last sign-in to flag as stale (1-365) |
| `-Output` | String | ❌ | `CSV` | Output format: `CSV`, `HTML`, or `Both` |
| `-OutputPath` | String | ❌ | `./Output` | Directory for output files |
| `-IncludeGuests` | Switch | ❌ | — | Include B2B guest accounts in audit |
| `-TicketRef` | String | ❌ | `-` | ITSM ticket reference for logging |
| `-UseMockData` | Switch | ❌ | — | Use 25 built-in demo records |
| `-DryRun` | Switch | ❌ | — | Preview audit parameters |

**Returns:** `PSCustomObject` with TotalUsers, HighRisk, MediumRisk, LowRisk, ExportedFiles

**Output CSV Columns:**
DisplayName, UPN, UserType, Department, Manager, LastSignIn, DaysSinceSignIn,
AssignedGroups, IsPrivileged, PrivilegedRoles, RiskFlag, Tenant, RunDate

**Risk Flag Logic:**
| Flag | Criteria |
|---|---|
| HIGH | Privileged role holder + inactive 30+ days |
| MEDIUM | Regular user, inactive 60-90 days, 5+ group memberships |
| LOW | Guest inactive 30-60 days; regular user 90+ days stale |
| INFO | All others |

```powershell
Invoke-AccessAudit -StaleThreshold 90 -IncludeGuests -Output Both
Invoke-AccessAudit -UseMockData -Output Both  # Demo mode
```

---

## New-AccessDoc

**Module:** AccessDoc.ps1
**Purpose:** Generate audit-ready HTML/Word document from audit CSV.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-AuditData` | String | ✅ | — | Path to CSV from Invoke-AccessAudit |
| `-Format` | String | ❌ | `HTML` | Output format: `HTML` or `Word` |
| `-OutputPath` | String | ❌ | `./Output` | Directory for output document |
| `-Tenant` | String | ❌ | `$env:DAMOPS_TENANT` | Tenant name for document header |
| `-ReviewerName` | String | ❌ | `Not Specified` | Reviewer name for signature block |
| `-DryRun` | Switch | ❌ | — | Preview document plan |

**Returns:** `PSCustomObject` with DocumentPath, TotalRecords, risk counts

**Document Sections:**
1. Cover Page (title, tenant, date, reviewer)
2. Executive Summary (counts by risk tier)
3. HIGH Risk Findings (full data table)
4. MEDIUM Risk Findings (full data table)
5. Guest Account Summary (count, oldest, avg days)
6. Privileged Role Assignments (active vs PIM)
7. Recommendations (auto-generated)
8. Appendix (full data + run metadata)

```powershell
New-AccessDoc -AuditData .\Output\audit_report.csv -ReviewerName "Patel, K."
New-AccessDoc -AuditData .\Output\audit_report.csv -Format Word
```

---

## Start-JMLProcess

**Module:** JMLProcess.ps1
**Purpose:** Process Joiner/Mover/Leaver actions from HR CSV.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-InputFile` | String | ✅ | — | Path to HR changes CSV |
| `-DryRun` | Switch | ❌ | — | Preview all actions without executing |
| `-TicketRef` | String | ❌ | `-` | ITSM ticket reference |
| `-NotifyManager` | Switch | ❌ | — | Email notification to manager |

**Returns:** `PSCustomObject` with TotalProcessed, Joins, Moves, Leaves, Results array

**Required CSV Columns:**
Action, DisplayName, UPN, Department, Manager, TargetOU, Groups, LicenseSKU, StartDate, TicketRef

**Action Behaviors:**
| Action | What It Does |
|---|---|
| Join | Create account, assign groups/license, set manager, enable |
| Move | Update department/manager, adjust groups, update license |
| Leave | Disable, strip groups, remove license, hide from GAL, flag for deletion |

```powershell
Start-JMLProcess -InputFile .\Templates\hr_changes_sample.csv -DryRun
Start-JMLProcess -InputFile .\hr_changes.csv -TicketRef "INC0012345"
```

---

## Get-AIRiskSummary

**Module:** AIRiskSummary.ps1
**Purpose:** AI-powered risk analysis via NVIDIA NIM API.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-AuditData` | String | ✅ | — | Path to audit CSV |
| `-AppendToDoc` | String | ❌ | — | Path to HTML doc (injects AI section) |
| `-OutputPath` | String | ❌ | `./Output` | Directory for ai_risk_summary.md |
| `-MaxTokens` | Int | ❌ | `1024` | Max tokens for AI response (256-4096) |
| `-DryRun` | Switch | ❌ | — | Preview API call without sending |

**Returns:** `PSCustomObject` with Status, Summary, SummaryPath, AppendedToDoc

**API Details:**
- Endpoint: `https://integrate.api.nvidia.com/v1/chat/completions`
- Model: `nvidia/llama-3.1-nemotron-70b-instruct`
- Temperature: 0.3 (focused, deterministic)
- Fallback: Generates structured summary if API unavailable

```powershell
Get-AIRiskSummary -AuditData .\Output\audit_report.csv
Get-AIRiskSummary -AuditData .\Output\audit_report.csv -AppendToDoc .\Output\report.html
```

---

## New-DAMScript

**Module:** RoleGen.ps1
**Purpose:** Generate role-scoped PowerShell scripts via AI.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Task` | String | ✅ | — | Plain-language task description |
| `-Role` | String | ✅ | — | Role: `DAMAnalyst`, `ITAdmin`, `SecurityOps`, `HelpDesk` |
| `-DryRun` | Switch | ❌ | — | Bake DryRun as default into generated script |
| `-Output` | String | ❌ | `./Output` | Output directory |
| `-Schedule` | Switch | ❌ | — | Generate Task Scheduler XML |

**Returns:** `PSCustomObject` with ScriptPath, DocumentPath, SchedulerPath

**Role Access Matrix:**
| Role | Allowed | Blocked |
|---|---|---|
| DAMAnalyst | `Get-Mg*`, `Export-Csv`, `Send-*` | `Set-*`, `New-*`, `Remove-*` |
| ITAdmin | All cmdlets | None |
| SecurityOps | `Get-Mg*`, priv roles, AI | `New-MgUser`, `Remove-*` |
| HelpDesk | CSV validation only | All Graph operations |

**Generated Files:**
- `script.ps1` — Executable script with help block + logging
- `script.md` — Documentation with permissions + usage
- `script.xml` — Task Scheduler config (with `-Schedule`)

```powershell
New-DAMScript -Task "list stale users older than 90 days" -Role DAMAnalyst
New-DAMScript -Task "disable inactive accounts" -Role ITAdmin -Schedule
```

---

## Write-DAMLog

**Module:** DAMOps.psm1 (shared utility)
**Purpose:** Write structured log entries to `Logs/damops_run.log`.

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Action` | String | ✅ | — | Action performed (e.g. ConnectGraph, DisableUser) |
| `-Result` | String | ✅ | — | Outcome: `SUCCESS`, `FAILED`, `SKIPPED`, `DRYRUN` |
| `-UPN` | String | ❌ | `-` | Target user principal name |
| `-Ticket` | String | ❌ | `-` | ITSM ticket reference |
| `-Message` | String | ❌ | — | Free-text detail |

**Log Format (tab-delimited):**
`TIMESTAMP  ACTION  RESULT  UPN  TENANT  TICKET  CHANGED_BY  MESSAGE`

```powershell
Write-DAMLog -Action 'DisableUser' -Result 'SUCCESS' -UPN 'jdoe@contoso.com' -Ticket 'INC001'
```
