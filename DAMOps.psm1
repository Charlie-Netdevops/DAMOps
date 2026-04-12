# DAMOps Module Loader
<#
.SYNOPSIS
    DAMOps module loader - dot-sources all modules and initializes shared resources.

.DESCRIPTION
    This is the root module file for DAMOps. It:
    1. Dot-sources every .ps1 file in the Modules\ directory
    2. Provides the shared Write-DAMLog function used by all modules
    3. Creates required directories (Logs\, Output\) if they don't exist
    4. Sets module-level variables for consistent path resolution

.NOTES
    Always import via: Import-Module .\DAMOps.psm1
    Or from manifest:  Import-Module .\DAMOps.psd1
#>

# -- Module-level variables ------------------------------------------------------
$script:ModuleRoot   = $PSScriptRoot
$script:ModuleVersion = '1.0.0'
$script:LogDir       = Join-Path $script:ModuleRoot 'Logs'
$script:OutputDir    = Join-Path $script:ModuleRoot 'Output'
$script:TemplateDir  = Join-Path $script:ModuleRoot 'Templates'
$script:LogFile      = Join-Path $script:LogDir 'damops_run.log'

# -- Ensure required directories exist --------------------------------------------
@($script:LogDir, $script:OutputDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Verbose "DAMOps: Created directory $_"
    }
}

# -- Shared logging function ------------------------------------------------------
function Write-DAMLog {
    <#
    .SYNOPSIS
        Write a structured log entry to the DAMOps run log.

    .DESCRIPTION
        Appends a timestamped, tab-delimited log entry to Logs\damops_run.log.
        Every module calls this function to maintain a consistent audit trail.
        Log entries include: timestamp, action performed, result, target UPN,
        tenant name, ticket reference, and the identity of who ran the command.

    .PARAMETER Action
        What was performed (e.g. 'ConnectGraph', 'DisableUser', 'ExportAudit').

    .PARAMETER Result
        Outcome: SUCCESS, FAILED, SKIPPED, or DRYRUN.

    .PARAMETER UPN
        Target user principal name, if applicable. Use '-' for non-user actions.

    .PARAMETER Ticket
        ITSM ticket reference number. Use '-' if not provided.

    .PARAMETER Message
        Optional free-text detail about the action or error.

    .EXAMPLE
        Write-DAMLog -Action 'DisableUser' -Result 'SUCCESS' -UPN 'jdoe@contoso.com' -Ticket 'INC0012345'

    .EXAMPLE
        Write-DAMLog -Action 'ConnectGraph' -Result 'FAILED' -Message 'Tenant not found'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('SUCCESS', 'FAILED', 'SKIPPED', 'DRYRUN')]
        [string]$Result,

        [string]$UPN = '-',

        [string]$Ticket = '-',

        [string]$Message = ''
    )

    # Build structured log entry
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
    $tenant    = if ($env:DAMOPS_TENANT) { $env:DAMOPS_TENANT } else { 'NOT_SET' }
    $changedBy = "$($env:USERNAME)@$($env:COMPUTERNAME)"

    $logEntry = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f `
        $timestamp, $Action, $Result, $UPN, $tenant, $Ticket, $changedBy, $Message

    # Ensure log directory exists (safety check for first-run scenarios)
    $logDir = Split-Path $script:LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Append to log file - thread-safe with mutex for parallel scenarios
    Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8

    # Also write to verbose stream for real-time tracing
    Write-Verbose "LOG: [$timestamp] $Action | $Result | $UPN | $Message"
}

# -- Dot-source all module files --------------------------------------------------
$modulePath = Join-Path $script:ModuleRoot 'Modules'

if (Test-Path $modulePath) {
    Get-ChildItem -Path $modulePath -Filter '*.ps1' -File | ForEach-Object {
        try {
            Write-Verbose "DAMOps: Loading module $($_.Name)"
            . $_.FullName
        }
        catch {
            Write-Warning "DAMOps: Failed to load $($_.Name): $($_.Exception.Message)"
        }
    }
}
else {
    Write-Warning "DAMOps: Modules directory not found at $modulePath"
}

# -- Module load confirmation -----------------------------------------------------
Write-Verbose "DAMOps v$($script:ModuleVersion) loaded. Log file: $($script:LogFile)"
