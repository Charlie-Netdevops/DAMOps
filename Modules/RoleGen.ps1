# RoleGen.ps1 - DAMOps Role-Based Script Generator
<#
.SYNOPSIS
    New-DAMScript - Generate ready-to-run PowerShell scripts tailored to a task and role.

.DESCRIPTION
    Uses NVIDIA NIM API to generate PowerShell scripts with built-in help blocks,
    logging, and DryRun support. Scripts are scoped to the caller's role with
    hard-coded access controls that cannot be overridden by the task description.

.NOTES
    File:    RoleGen.ps1
    Module:  DAMOps
    Author:  DAMOps Team
    Version: 1.0.0
#>

function New-DAMScript {
    <#
    .SYNOPSIS
        Generate a role-scoped PowerShell script for a specific task.

    .DESCRIPTION
        Takes a plain-language task description and a role, generates a PowerShell
        script via NVIDIA NIM API, then enforces role-based access controls by
        stripping disallowed cmdlets from the output. Each generated script includes
        its own help block, logging, and dry-run support.

    .PARAMETER Task
        Plain-language description of the task the script should perform.

    .PARAMETER Role
        The role of the script author. Determines which cmdlets are allowed.
        Options: DAMAnalyst, ITAdmin, SecurityOps, HelpDesk.

    .PARAMETER DryRun
        Bake DryRun as the default behavior into the generated script.

    .PARAMETER Output
        Directory to save the generated script files. Default: ./Output.

    .PARAMETER Schedule
        Generate a Windows Task Scheduler XML file for automated execution.

    .EXAMPLE
        New-DAMScript -Task "list all stale users older than 90 days" -Role DAMAnalyst

    .EXAMPLE
        New-DAMScript -Task "disable stale users and remove licenses" -Role ITAdmin -Schedule

    .EXAMPLE
        New-DAMScript -Task "check privileged role assignments" -Role SecurityOps -DryRun
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Plain-language task description")]
        [ValidateNotNullOrEmpty()]
        [string]$Task,

        [Parameter(Mandatory = $true, HelpMessage = "Role: DAMAnalyst, ITAdmin, SecurityOps, HelpDesk")]
        [ValidateSet('DAMAnalyst', 'ITAdmin', 'SecurityOps', 'HelpDesk')]
        [string]$Role,

        [switch]$DryRun,

        [Parameter(HelpMessage = "Output directory for generated scripts")]
        [string]$Output = (Join-Path (Join-Path $PSScriptRoot '..') 'Output'),

        [switch]$Schedule
    )

    $startTime = [DateTime]::UtcNow

    # Resolve output path
    $Output = [System.IO.Path]::GetFullPath($Output)
    if (-not (Test-Path $Output)) {
        New-Item -ItemType Directory -Path $Output -Force | Out-Null
    }

    Write-Verbose "=========================================================="
    Write-Verbose "DAMOps Script Generator (RoleGen)"
    Write-Verbose "Task:     $Task"
    Write-Verbose "Role:     $Role"
    Write-Verbose "DryRun:   $DryRun"
    Write-Verbose "Schedule: $Schedule"
    Write-Verbose "=========================================================="

    # -- Role access control matrix (hard-coded - NEVER overridden) -----------
    $rolePermissions = @{
        DAMAnalyst = @{
            Description  = 'Read-only access: query, export, and report.'
            AllowedVerbs = @('Get', 'Export', 'Send', 'Select', 'Where', 'Sort', 'Format', 'Out', 'Write', 'ConvertTo', 'Import', 'Measure', 'Group', 'ForEach', 'Test')
            BlockedVerbs = @('Set', 'New', 'Remove', 'Update', 'Disable', 'Enable', 'Add', 'Revoke', 'Grant', 'Move', 'Stop', 'Start', 'Invoke')
            AllowedPatterns = @('Get-Mg*', 'Export-Csv', 'Send-MgUserMail', 'ConvertTo-*', 'Import-Csv', 'Write-*', 'Select-Object', 'Where-Object', 'Sort-Object', 'Format-*', 'Out-File', 'Measure-Object', 'Group-Object', 'ForEach-Object', 'Test-Path')
            BlockedPatterns = @('Set-Mg*', 'New-Mg*', 'Remove-Mg*', 'Update-Mg*', 'Disable-*', 'Enable-*')
        }
        ITAdmin = @{
            Description  = 'Full access: all DAMOps modules and Graph cmdlets.'
            AllowedVerbs = @('*')
            BlockedVerbs = @()
            AllowedPatterns = @('*')
            BlockedPatterns = @()
        }
        SecurityOps = @{
            Description  = 'Privileged role monitoring, anomaly detection, AI analysis.'
            AllowedVerbs = @('Get', 'Export', 'Send', 'Select', 'Where', 'Sort', 'Format', 'Out', 'Write', 'ConvertTo', 'Import', 'Measure', 'Invoke-RestMethod', 'Test')
            BlockedVerbs = @('New-MgUser', 'Remove', 'Update', 'Disable', 'Enable', 'Move', 'Grant', 'Add')
            AllowedPatterns = @('Get-Mg*', 'Get-MgDirectoryRole*', 'Get-MgRoleManagement*', 'Export-Csv', 'Invoke-RestMethod', 'ConvertTo-Json', 'Write-*')
            BlockedPatterns = @('New-MgUser', 'Remove-Mg*', 'Update-MgUser', 'Set-MgUser*')
        }
        HelpDesk = @{
            Description  = 'CSV validation only. Cannot execute JML actions directly.'
            AllowedVerbs = @('Get', 'Import', 'Export', 'Test', 'Select', 'Where', 'Sort', 'Format', 'Write', 'ConvertTo', 'Measure', 'Group', 'ForEach', 'Out')
            BlockedVerbs = @('Set', 'New', 'Remove', 'Update', 'Disable', 'Enable', 'Add', 'Revoke', 'Grant', 'Move', 'Stop', 'Start', 'Invoke', 'Send', 'Connect')
            AllowedPatterns = @('Import-Csv', 'Export-Csv', 'Test-Path', 'Write-*', 'Select-Object', 'Where-Object', 'Sort-Object', 'Format-*', 'Out-File', 'ConvertTo-*', 'Measure-Object', 'Group-Object', 'ForEach-Object')
            BlockedPatterns = @('*-Mg*', 'Connect-*', 'Invoke-*', 'Send-*')
        }
    }

    $currentRole = $rolePermissions[$Role]

    Write-Verbose "Role: $Role - $($currentRole.Description)"

    # -- Build AI prompt ------------------------------------------------------
    $dryRunInstruction = if ($DryRun) {
        "IMPORTANT: The script MUST default to DryRun mode. Include a -DryRun switch that is ON by default. In DryRun mode, show what would happen without making changes."
    }
    else {
        "Include a -DryRun switch parameter. When -DryRun is specified, show what would happen without making changes."
    }

    $systemPrompt = @"
You are a PowerShell automation expert specializing in Microsoft Entra ID and Active Directory.
Generate a production-ready PowerShell script for the following task.

ROLE: $Role - $($currentRole.Description)

ROLE RESTRICTIONS (STRICTLY ENFORCED - DO NOT VIOLATE):
$(if ($currentRole.BlockedPatterns.Count -gt 0) { "BLOCKED cmdlets: $($currentRole.BlockedPatterns -join ', ')" } else { "No restrictions - full access." })
$(if ($currentRole.AllowedPatterns.Count -gt 0 -and $currentRole.AllowedPatterns[0] -ne '*') { "ALLOWED cmdlets: $($currentRole.AllowedPatterns -join ', ')" })

REQUIREMENTS:
1. Include a comment-based help block (Synopsis, Description, Parameters, Example)
2. $dryRunInstruction
3. Use Write-Verbose for step-by-step execution trace
4. Use try/catch for error handling with meaningful messages
5. Return structured PSCustomObjects, not raw strings
6. Use Write-DAMLog for logging (Action, Result, UPN, Ticket parameters)
7. Use Join-Path for all file paths - never string concatenation
8. All date comparisons use [DateTime]::UtcNow
9. Comment every non-obvious block
10. Use Microsoft.Graph PowerShell SDK cmdlets (Get-MgUser, etc.)
11. No hardcoded credentials or tenant names
12. Include proper parameter validation

OUTPUT FORMAT: Only output the PowerShell script. No explanations before or after.
Start with #Requires -Version 7.0 and end with the function.
"@

    $userMessage = "Generate a PowerShell script for this task: $Task"

    # -- Generate script via NVIDIA API or fallback ---------------------------
    $generatedScript = $null
    $genStatus = 'UNKNOWN'

    if ([string]::IsNullOrWhiteSpace($env:NVIDIA_API_KEY)) {
        Write-Warning "NVIDIA_API_KEY not set. Generating template script..."
        $generatedScript = Get-DAMOpsTemplateScript -Task $Task -Role $Role -DryRun:$DryRun -RolePerms $currentRole
        $genStatus = 'TEMPLATE'
        Write-DAMLog -Action 'RoleGen' -Result 'SKIPPED' -Message "No API key - template generated for $Role"
    }
    else {
        try {
            Write-Verbose "Calling NVIDIA NIM API for script generation..."

            $requestBody = @{
                model       = 'meta/llama-3.3-70b-instruct'
                messages    = @(
                    @{ role = 'system'; content = $systemPrompt }
                    @{ role = 'user';   content = $userMessage }
                )
                max_tokens  = 2048
                temperature = 0.2
                top_p       = 0.9
            } | ConvertTo-Json -Depth 5

            $headers = @{
                'Authorization' = "Bearer $($env:NVIDIA_API_KEY)"
                'Content-Type'  = 'application/json'
            }

            $response = Invoke-RestMethod `
                -Uri 'https://integrate.api.nvidia.com/v1/chat/completions' `
                -Method POST `
                -Headers $headers `
                -Body $requestBody `
                -TimeoutSec 90 `
                -ErrorAction Stop

            if ($response.choices -and $response.choices[0].message.content) {
                $generatedScript = $response.choices[0].message.content
                # Strip markdown code fences if present
                $generatedScript = $generatedScript -replace '```powershell\s*', '' -replace '```\s*$', '' -replace '^```\s*', ''
                $genStatus = 'AI_GENERATED'
                Write-Verbose "  Script generated by AI"
                Write-DAMLog -Action 'RoleGen' -Result 'SUCCESS' -Message "AI generated script for $Role : $Task"
            }
            else {
                throw "API returned unexpected response format"
            }
        }
        catch {
            Write-Warning "NVIDIA API failed: $($_.Exception.Message). Using template..."
            $generatedScript = Get-DAMOpsTemplateScript -Task $Task -Role $Role -DryRun:$DryRun -RolePerms $currentRole
            $genStatus = 'TEMPLATE'
            Write-DAMLog -Action 'RoleGen' -Result 'FAILED' -Message "API error: $($_.Exception.Message)"
        }
    }

    # -- Enforce role restrictions (post-processing) --------------------------
    # Even if the AI generates disallowed cmdlets, we strip them here
    if ($Role -ne 'ITAdmin') {
        $violations = @()

        foreach ($blocked in $currentRole.BlockedPatterns) {
            # Convert wildcard to regex
            $pattern = '^[^#]*' + ($blocked -replace '\*', '.*') + '\b'

            $lines = $generatedScript -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Skip comments and empty lines
                if ($line.Trim() -match '^#' -or $line.Trim() -eq '') { continue }

                if ($line -match $pattern) {
                    $violations += "Line $($i+1): $($line.Trim()) [BLOCKED: $blocked]"
                    # Comment out the violating line and add a warning
                    $lines[$i] = "# [DAMOps ROLE RESTRICTION: $Role] $($line.TrimStart())"
                    # Insert warning after
                    $warningLine = "Write-Warning `"[ROLE: $Role] This action is not permitted. Blocked cmdlet: $blocked`""
                    $lines[$i] = $lines[$i] + "`n$warningLine"
                }
            }

            $generatedScript = $lines -join "`n"
        }

        if ($violations.Count -gt 0) {
            Write-Verbose "  Role enforcement: $($violations.Count) cmdlet(s) blocked"
            foreach ($v in $violations) {
                Write-Verbose "    x $v"
            }
        }
    }

    # -- Generate file names --------------------------------------------------
    $safeName = ($Task -replace '[^a-zA-Z0-9\s]', '' -replace '\s+', '_').ToLower()
    if ($safeName.Length -gt 50) { $safeName = $safeName.Substring(0, 50) }

    $scriptName = "damops_${Role}_${safeName}"
    $ps1Path = Join-Path $Output "$scriptName.ps1"
    $mdPath  = Join-Path $Output "$scriptName.md"

    # -- Save script file -----------------------------------------------------
    try {
        Set-Content -Path $ps1Path -Value $generatedScript -Encoding UTF8
        Write-Verbose "Script saved: $ps1Path"
    }
    catch {
        Write-Warning "Failed to save script: $($_.Exception.Message)"
    }

    # -- Generate documentation (.md) -----------------------------------------
    $documentation = @"
# DAMOps Generated Script

## Task
$Task

## Role
**$Role** - $($currentRole.Description)

## File
``$scriptName.ps1``

## Required Permissions
$(if ($Role -eq 'ITAdmin') {
"- Full Microsoft Graph API access
- Directory.ReadWrite.All
- User.ReadWrite.All
- RoleManagement.ReadWrite.Directory"
} elseif ($Role -eq 'DAMAnalyst') {
"- Microsoft Graph API read access
- User.Read.All
- Directory.Read.All
- AuditLog.Read.All"
} elseif ($Role -eq 'SecurityOps') {
"- Microsoft Graph API read access
- RoleManagement.Read.Directory
- AuditLog.Read.All
- Directory.Read.All"
} else {
"- No Microsoft Graph API access required
- Local file system read/write for CSV validation"
})

## Allowed Cmdlets
$(($currentRole.AllowedPatterns | ForEach-Object { "- ``$_``" }) -join "`n")

## Blocked Cmdlets
$(if ($currentRole.BlockedPatterns.Count -gt 0) { ($currentRole.BlockedPatterns | ForEach-Object { "- ``$_``" }) -join "`n" } else { "None - full access" })

## Expected Output
- Structured PSCustomObject with results
- Verbose trace with ``-Verbose``
- Log entries in ``Logs/damops_run.log``

## Usage

``````powershell
# Import DAMOps module first
Import-Module .\DAMOps.psd1

# Run the generated script
. .\Output\$scriptName.ps1

# Execute with DryRun
# (see script for specific function name and parameters)
``````

## Generation Info
- **Generated:** $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC
- **Source:** $genStatus
- **DAMOps Version:** 1.0.0

---

*Generated by DAMOps RoleGen v1.0.0*
"@

    try {
        Set-Content -Path $mdPath -Value $documentation -Encoding UTF8
        Write-Verbose "Documentation saved: $mdPath"
    }
    catch {
        Write-Warning "Failed to save documentation: $($_.Exception.Message)"
    }

    # -- Generate Task Scheduler XML if requested -----------------------------
    $xmlPath = $null
    if ($Schedule) {
        $xmlPath = Join-Path $Output "$scriptName.xml"
        $schedulerXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss'))</Date>
    <Author>DAMOps RoleGen</Author>
    <Description>DAMOps Scheduled Task: $Task (Role: $Role)</Description>
    <URI>\DAMOps\$scriptName</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>P1D</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$([DateTime]::UtcNow.AddDays(1).ToString('yyyy-MM-dd'))T06:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>pwsh.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$ps1Path"</Arguments>
      <WorkingDirectory>$Output</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
        try {
            Set-Content -Path $xmlPath -Value $schedulerXml -Encoding Unicode
            Write-Verbose "Task Scheduler XML saved: $xmlPath"
        }
        catch {
            Write-Warning "Failed to save scheduler XML: $($_.Exception.Message)"
        }
    }

    $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds

    # -- Display summary ------------------------------------------------------
    Write-Host ""
    Write-Host "  /======================================================\" -ForegroundColor DarkCyan
    Write-Host "  |           Script Generated                          |" -ForegroundColor DarkCyan
    Write-Host "  |======================================================|" -ForegroundColor DarkCyan
    Write-Host "  |  Task:     $Task" -ForegroundColor DarkCyan
    Write-Host "  |  Role:     $Role" -ForegroundColor DarkCyan
    Write-Host "  |  Source:   $genStatus" -ForegroundColor DarkCyan
    Write-Host "  |  Duration: $([math]::Round($elapsed, 1))s" -ForegroundColor DarkCyan
    Write-Host "  \======================================================/" -ForegroundColor DarkCyan
    Write-Host "  -> $ps1Path" -ForegroundColor Green
    Write-Host "  -> $mdPath" -ForegroundColor Green
    if ($xmlPath) {
        Write-Host "  -> $xmlPath" -ForegroundColor Green
    }
    Write-Host ""

    return [PSCustomObject]@{
        Status           = 'SUCCESS'
        Task             = $Task
        Role             = $Role
        RoleDescription  = $currentRole.Description
        GenerationSource = $genStatus
        ScriptPath       = $ps1Path
        DocumentPath     = $mdPath
        SchedulerPath    = $xmlPath
        DurationSeconds  = [math]::Round($elapsed, 1)
    }
}


# -- Template script generator (fallback when API unavailable) ----------------
function Get-DAMOpsTemplateScript {
    <#
    .SYNOPSIS
        Generate a template PowerShell script when the NVIDIA API is unavailable.
    #>
    [CmdletBinding()]
    param(
        [string]$Task,
        [string]$Role,
        [switch]$DryRun,
        [hashtable]$RolePerms
    )

    $dryRunDefault = if ($DryRun) { '$true' } else { '$false' }
    $functionName  = 'Invoke-DAMOpsTask'
    $safeTask      = $Task -replace "'", "''"

    $template = @"
#Requires -Version 7.0
<#
.SYNOPSIS
    DAMOps Generated Script - $Task

.DESCRIPTION
    Auto-generated by DAMOps RoleGen for role: $Role
    Role permissions: $($RolePerms.Description)

    Task: $Task

.PARAMETER DryRun
    Preview actions without making changes. Default: $dryRunDefault

.PARAMETER TicketRef
    ITSM ticket reference for audit logging.

.PARAMETER OutputPath
    Directory to save results. Default: ./Output

.EXAMPLE
    $functionName -DryRun -Verbose
    # Preview the task in dry-run mode with verbose output

.EXAMPLE
    $functionName -TicketRef "INC0012345"
    # Execute with ticket reference for audit trail

.NOTES
    Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC
    Role: $Role
    Generator: DAMOps RoleGen v1.0.0
#>

function $functionName {
    [CmdletBinding()]
    param(
        [switch]`$DryRun = $dryRunDefault,

        [string]`$TicketRef = '-',

        [string]`$OutputPath = '.\Output'
    )

    `$startTime = [DateTime]::UtcNow
    `$tenant = if (`$env:DAMOPS_TENANT) { `$env:DAMOPS_TENANT } else { 'UNKNOWN' }

    Write-Verbose "==============================================="
    Write-Verbose "DAMOps Task: $safeTask"
    Write-Verbose "Role: $Role | Tenant: `$tenant"
    Write-Verbose "==============================================="

    # Ensure output directory exists
    if (-not (Test-Path `$OutputPath)) {
        New-Item -ItemType Directory -Path `$OutputPath -Force | Out-Null
    }

    try {
        # -- Verify Graph connection ------------------------------
        Write-Verbose "Checking Microsoft Graph connection..."
        `$context = Get-MgContext -ErrorAction Stop
        if (-not `$context) {
            throw "Not connected to Microsoft Graph. Run Connect-DAMOps first."
        }
        Write-Verbose "Connected as: `$(`$context.Account)"

        # -- Execute task -----------------------------------------
        Write-Verbose "Executing task: $safeTask"

        if (`$DryRun) {
            Write-Host "[DRYRUN] Would execute: $safeTask" -ForegroundColor Yellow
            Write-DAMLog -Action 'GeneratedScript' -Result 'DRYRUN' -Ticket `$TicketRef ``
                -Message "Task: $safeTask"
        }
        else {
            # TODO: Implement task-specific logic here
            # Role '$Role' allows: $($RolePerms.AllowedPatterns -join ', ')
            #
            # Example for '$Role':
$(if ($Role -eq 'DAMAnalyst') {
@"
            # `$users = Get-MgUser -All -Property 'DisplayName,UserPrincipalName,SignInActivity'
            # `$results = `$users | Where-Object { ... } | Select-Object DisplayName, UserPrincipalName
            # `$results | Export-Csv -Path (Join-Path `$OutputPath 'task_results.csv') -NoTypeInformation
"@
} elseif ($Role -eq 'ITAdmin') {
@"
            # `$users = Get-MgUser -All -Property 'DisplayName,UserPrincipalName,AccountEnabled,SignInActivity'
            # foreach (`$user in `$users) {
            #     # Perform updates as needed
            #     Update-MgUser -UserId `$user.Id -BodyParameter @{ ... }
            # }
"@
} elseif ($Role -eq 'SecurityOps') {
@"
            # `$roles = Get-MgDirectoryRole -All
            # `$assignments = foreach (`$role in `$roles) { Get-MgDirectoryRoleMember -DirectoryRoleId `$role.Id }
            # # Analyze privileged access patterns
"@
} else {
@"
            # `$csvData = Import-Csv -Path 'input.csv'
            # # Validate CSV structure and data quality
            # `$csvData | ForEach-Object { # validation logic }
"@
})

            Write-Host "[SUCCESS] Task completed: $safeTask" -ForegroundColor Green
            Write-DAMLog -Action 'GeneratedScript' -Result 'SUCCESS' -Ticket `$TicketRef ``
                -Message "Task: $safeTask"
        }
    }
    catch {
        Write-Warning "Task failed: `$(`$_.Exception.Message)"
        Write-DAMLog -Action 'GeneratedScript' -Result 'FAILED' -Ticket `$TicketRef ``
            -Message "Error: `$(`$_.Exception.Message)"
        throw
    }

    `$elapsed = ([DateTime]::UtcNow - `$startTime).TotalSeconds

    return [PSCustomObject]@{
        Task     = '$safeTask'
        Role     = '$Role'
        Status   = if (`$DryRun) { 'DRYRUN' } else { 'SUCCESS' }
        Tenant   = `$tenant
        Duration = [math]::Round(`$elapsed, 1)
        Ticket   = `$TicketRef
    }
}

# Run the function
$functionName
"@

    return $template
}
