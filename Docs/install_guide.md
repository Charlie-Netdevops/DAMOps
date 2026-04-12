# DAMOps Installation Guide

## Prerequisites

| Requirement | Minimum Version | Check Command |
|---|---|---|
| PowerShell | 7.0+ | `$PSVersionTable.PSVersion` |
| Microsoft.Graph SDK | 2.0+ | `Get-Module Microsoft.Graph -ListAvailable` |
| Internet Access | — | Required for Graph API and NVIDIA NIM |
| NVIDIA API Key | — | [build.nvidia.com](https://build.nvidia.com) |

## Step 1: Install PowerShell 7+

If running Windows PowerShell 5.1, upgrade to PowerShell 7:

```powershell
winget install Microsoft.PowerShell
```

Verify:
```powershell
pwsh -Version
# Expected: PowerShell 7.x.x
```

## Step 2: Install Microsoft Graph SDK

DAMOps uses the Microsoft Graph PowerShell SDK for Entra ID interactions:

```powershell
# Install required sub-modules (lighter than the full SDK)
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Groups -Scope CurrentUser -Force

# Verify installation
Get-Module Microsoft.Graph.* -ListAvailable | Select-Object Name, Version
```

## Step 3: Get NVIDIA API Key

DAMOps uses NVIDIA NIM for AI-powered risk analysis:

1. Go to [build.nvidia.com](https://build.nvidia.com)
2. Sign up or log in
3. Navigate to **nvidia/llama-3.1-nemotron-70b-instruct**
4. Generate an API key
5. Copy the key (starts with `nvapi-`)

## Step 4: Set Environment Variables

```powershell
# Set for current session
$env:NVIDIA_API_KEY = "nvapi-your-key-here"

# Persist across sessions (user-level)
[System.Environment]::SetEnvironmentVariable('NVIDIA_API_KEY', 'nvapi-your-key-here', 'User')
```

## Step 5: Clone and Import DAMOps

```powershell
# Clone the repository
git clone https://github.com/your-org/DAMOps.git
cd DAMOps

# Import the module
Import-Module .\DAMOps.psd1 -Verbose

# Verify all functions are available
Get-Command -Module DAMOps
```

Expected output:
```
CommandType  Name                    Version
-----------  ----                    -------
Function     Connect-DAMOps         1.0.0
Function     Get-AIRiskSummary      1.0.0
Function     Invoke-AccessAudit     1.0.0
Function     New-AccessDoc          1.0.0
Function     New-DAMScript          1.0.0
Function     Start-JMLProcess       1.0.0
Function     Write-DAMLog           1.0.0
```

## Step 6: Test Connection

```powershell
# Test with DryRun first (no actual connection)
Connect-DAMOps -Tenant contoso.onmicrosoft.com -DryRun

# Connect for real
Connect-DAMOps -Tenant contoso.onmicrosoft.com
```

## Step 7: Run Demo

```powershell
# Full demo with mock data
Invoke-AccessAudit -UseMockData -Output Both -IncludeGuests
New-AccessDoc -AuditData .\Output\audit_report.csv -ReviewerName "Your Name"
Get-AIRiskSummary -AuditData .\Output\audit_report.csv -AppendToDoc .\Output\access_review*.html
```

---

## Troubleshooting

### "Microsoft.Graph module not found"
```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
```

### "NVIDIA_API_KEY not set"
```powershell
$env:NVIDIA_API_KEY = "your-key"
# Verify: $env:NVIDIA_API_KEY
```

### "Connect-MgGraph failed"
- Ensure you have the right tenant name
- Check your internet connection
- For Service Principal auth, verify ClientId and ClientSecret

### "Access Denied" in Graph queries
Ensure your account has these Entra ID permissions:
- User.Read.All
- Directory.Read.All
- AuditLog.Read.All
- RoleManagement.Read.Directory

### PowerShell Execution Policy
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Directory Structure After Install

```
DAMOps/
├── DAMOps.psm1          ← Root module
├── DAMOps.psd1          ← Module manifest
├── README.md
├── Modules/             ← All function modules
├── Templates/           ← HTML templates + sample CSV
├── Logs/                ← Auto-generated log file
│   └── damops_run.log
├── Output/              ← Default output directory
└── Docs/                ← Documentation
```
