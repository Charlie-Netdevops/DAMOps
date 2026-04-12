# AccessAudit.ps1 - DAMOps Access Audit Module
<#
.SYNOPSIS
    Invoke-AccessAudit - Pull stale accounts, inactive guests, and privileged role
    holders from Microsoft Entra ID for access review.

.DESCRIPTION
    Core audit function for DAMOps. Queries Entra ID for:
      - Stale user accounts (no sign-in within threshold)
      - Inactive guest/B2B accounts
      - Privileged role holders (active + PIM eligible)
    Applies risk flagging logic and exports results to CSV and/or HTML.
    All other modules consume this function's output.

.NOTES
    File:    AccessAudit.ps1
    Module:  DAMOps
    Author:  DAMOps Team
    Version: 1.0.0
#>

function Invoke-AccessAudit {
    <#
    .SYNOPSIS
        Audit stale accounts, inactive guests, and privileged role holders.

    .DESCRIPTION
        Pulls user data from Entra ID, applies risk flagging (HIGH/MEDIUM/LOW/INFO),
        and exports a structured CSV and/or HTML report. Supports mock data for
        demo/testing without a live tenant.

    .PARAMETER StaleThreshold
        Number of days since last sign-in to consider an account stale. Default: 90.

    .PARAMETER Output
        Output format: CSV, HTML, or Both. Default: CSV.

    .PARAMETER OutputPath
        Directory to save output files. Default: ./Output.

    .PARAMETER IncludeGuests
        Include B2B guest accounts in the stale account check.

    .PARAMETER TicketRef
        Optional ITSM ticket reference number for audit trail.

    .PARAMETER UseMockData
        Use built-in mock data for demo/testing without a live Entra ID tenant.

    .PARAMETER DryRun
        Show what the audit would do without pulling real data.

    .EXAMPLE
        Invoke-AccessAudit -StaleThreshold 90 -IncludeGuests -Output Both

    .EXAMPLE
        Invoke-AccessAudit -UseMockData -Output Both
        # Demo mode with 25 sample users

    .EXAMPLE
        Invoke-AccessAudit -DryRun -Verbose
        # Preview audit parameters
    #>
    [CmdletBinding()]
    param(
        [Parameter(HelpMessage = "Days since last sign-in to flag as stale")]
        [ValidateRange(1, 365)]
        [int]$StaleThreshold = 90,

        [Parameter(HelpMessage = "Output format: CSV, HTML, or Both")]
        [ValidateSet('CSV', 'HTML', 'Both')]
        [string]$Output = 'CSV',

        [Parameter(HelpMessage = "Output directory path")]
        [string]$OutputPath = (Join-Path (Join-Path $PSScriptRoot '..') 'Output'),

        [switch]$IncludeGuests,

        [Parameter(HelpMessage = "ITSM ticket reference")]
        [string]$TicketRef = '-',

        [switch]$UseMockData,

        [switch]$DryRun
    )

    $startTime = [DateTime]::UtcNow
    $tenant    = if ($env:DAMOPS_TENANT) { $env:DAMOPS_TENANT } else { 'UNKNOWN' }
    $runDate   = $startTime.ToString('yyyy-MM-dd')

    # Resolve output path
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    Write-Verbose "=========================================================="
    Write-Verbose "DAMOps Access Audit Starting"
    Write-Verbose "Tenant:           $tenant"
    Write-Verbose "Stale Threshold:  $StaleThreshold days"
    Write-Verbose "Include Guests:   $IncludeGuests"
    Write-Verbose "Output Format:    $Output"
    Write-Verbose "Output Path:      $OutputPath"
    Write-Verbose "=========================================================="

    # -- DryRun - preview parameters and exit ---------------------------------
    if ($DryRun) {
        Write-Host "`n  [DRYRUN] Access Audit Plan:" -ForegroundColor Cyan
        Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Tenant:            $tenant" -ForegroundColor White
        Write-Host "  Stale Threshold:   $StaleThreshold days" -ForegroundColor White
        Write-Host "  Include Guests:    $IncludeGuests" -ForegroundColor White
        Write-Host "  Output Format:     $Output" -ForegroundColor White
        Write-Host "  Output Path:       $OutputPath" -ForegroundColor White
        Write-Host "  Ticket:            $TicketRef" -ForegroundColor White
        Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Would query:" -ForegroundColor Yellow
        Write-Host "    - All enabled users (sign-in < $StaleThreshold days)" -ForegroundColor White
        if ($IncludeGuests) {
            Write-Host "    - Guest/B2B users (sign-in < 60 days)" -ForegroundColor White
        }
        Write-Host "    - Privileged role assignments (active + PIM eligible)" -ForegroundColor White
        Write-Host "  [DRYRUN] No data pulled.`n" -ForegroundColor Yellow

        Write-DAMLog -Action 'AccessAudit' -Result 'DRYRUN' -Ticket $TicketRef -Message "Threshold=$StaleThreshold"
        return [PSCustomObject]@{
            Status     = 'DRYRUN'
            Tenant     = $tenant
            Threshold  = $StaleThreshold
            TotalUsers = 0
        }
    }

    # -- Pull audit data ------------------------------------------------------
    $auditResults = @()

    if ($UseMockData) {
        Write-Verbose "Using mock data for demo/testing..."
        $auditResults = Get-DAMOpsMockData -StaleThreshold $StaleThreshold -IncludeGuests:$IncludeGuests
        Write-DAMLog -Action 'AccessAudit' -Result 'SUCCESS' -Ticket $TicketRef -Message "MockData, $($auditResults.Count) users"
    }
    else {
        # -- Live Entra ID query ------------------------------------------
        try {
            # Verify Graph connection
            $context = Get-MgContext -ErrorAction Stop
            if (-not $context) {
                throw "Not connected to Microsoft Graph. Run Connect-DAMOps first."
            }
            Write-Verbose "Graph context: $($context.Account)"

            # -- Step 1: Pull all enabled users ---------------------------
            Write-Verbose "Step 1/4: Querying enabled users..."
            $userProperties = @(
                'Id', 'DisplayName', 'UserPrincipalName', 'UserType', 'Department',
                'AccountEnabled', 'SignInActivity', 'CreatedDateTime'
            )

            $allUsers = Get-MgUser -All `
                -Property ($userProperties -join ',') `
                -Filter "accountEnabled eq true" `
                -ErrorAction Stop

            Write-Verbose "  Found $($allUsers.Count) enabled users"

            # -- Step 2: Pull guest users if requested --------------------
            $guestUsers = @()
            if ($IncludeGuests) {
                Write-Verbose "Step 2/4: Querying guest accounts..."
                $guestUsers = Get-MgUser -All `
                    -Property ($userProperties -join ',') `
                    -Filter "userType eq 'Guest'" `
                    -ErrorAction Stop
                Write-Verbose "  Found $($guestUsers.Count) guest users"
            }

            # -- Step 3: Pull privileged role assignments -----------------
            Write-Verbose "Step 3/4: Querying privileged role assignments..."
            $privilegedRoles = @(
                'Global Administrator'
                'Privileged Role Administrator'
                'Exchange Administrator'
                'SharePoint Administrator'
                'Security Administrator'
                'User Administrator'
            )

            # Get active role assignments
            $roleAssignments = @{}
            try {
                $directoryRoles = Get-MgDirectoryRole -All -ErrorAction Stop
                foreach ($role in $directoryRoles) {
                    if ($role.DisplayName -in $privilegedRoles) {
                        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -ErrorAction SilentlyContinue
                        foreach ($member in $members) {
                            if (-not $roleAssignments.ContainsKey($member.Id)) {
                                $roleAssignments[$member.Id] = @()
                            }
                            $roleAssignments[$member.Id] += "$($role.DisplayName) (Active)"
                        }
                    }
                }
            }
            catch {
                Write-Warning "Could not query directory roles: $($_.Exception.Message)"
            }

            # Get PIM eligible assignments
            try {
                $pimEligible = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -All -ErrorAction Stop
                foreach ($assignment in $pimEligible) {
                    $roleDefinition = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId -ErrorAction SilentlyContinue
                    if ($roleDefinition.DisplayName -in $privilegedRoles) {
                        $principalId = $assignment.PrincipalId
                        if (-not $roleAssignments.ContainsKey($principalId)) {
                            $roleAssignments[$principalId] = @()
                        }
                        $roleAssignments[$principalId] += "$($roleDefinition.DisplayName) (PIM Eligible)"
                    }
                }
            }
            catch {
                Write-Verbose "PIM eligible query not available or failed: $($_.Exception.Message)"
            }

            Write-Verbose "  Found $($roleAssignments.Count) users with privileged roles"

            # -- Step 4: Build audit result objects ------------------------
            Write-Verbose "Step 4/4: Building audit results with risk flags..."

            # Process regular users
            foreach ($user in $allUsers) {
                $lastSignIn = $null
                $daysSince  = $null

                if ($user.SignInActivity -and $user.SignInActivity.LastSignInDateTime) {
                    $lastSignIn = $user.SignInActivity.LastSignInDateTime
                    $daysSince  = ([DateTime]::UtcNow - $lastSignIn).Days
                }
                else {
                    # No sign-in recorded - treat as very stale
                    $daysSince = 999
                }

                # Skip if within threshold
                if ($daysSince -lt $StaleThreshold -and -not $roleAssignments.ContainsKey($user.Id)) {
                    continue
                }

                # Determine manager
                $managerName = '-'
                try {
                    $manager = Get-MgUserManager -UserId $user.Id -ErrorAction SilentlyContinue
                    if ($manager) {
                        $managerName = $manager.AdditionalProperties.displayName
                    }
                }
                catch { }

                # Check privileged status
                $isPrivileged   = $roleAssignments.ContainsKey($user.Id)
                $privRoles      = if ($isPrivileged) { $roleAssignments[$user.Id] -join '; ' } else { '-' }

                # Get group count
                $groupCount = 0
                try {
                    $groups = Get-MgUserMemberOf -UserId $user.Id -ErrorAction SilentlyContinue
                    $groupCount = ($groups | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }).Count
                }
                catch { }

                # Apply risk flagging
                $riskFlag = Get-DAMOpsRiskFlag -DaysSinceSignIn $daysSince `
                    -IsPrivileged $isPrivileged `
                    -UserType $user.UserType `
                    -GroupCount $groupCount

                $auditResults += [PSCustomObject]@{
                    DisplayName      = $user.DisplayName
                    UPN              = $user.UserPrincipalName
                    UserType         = if ($user.UserType) { $user.UserType } else { 'Member' }
                    Department       = if ($user.Department) { $user.Department } else { '-' }
                    Manager          = $managerName
                    LastSignIn       = if ($lastSignIn) { $lastSignIn.ToString('yyyy-MM-dd') } else { 'Never' }
                    DaysSinceSignIn  = $daysSince
                    AssignedGroups   = $groupCount
                    IsPrivileged     = $isPrivileged
                    PrivilegedRoles  = $privRoles
                    RiskFlag         = $riskFlag
                    Tenant           = $tenant
                    RunDate          = $runDate
                }
            }

            # Process guest users
            if ($IncludeGuests -and $guestUsers.Count -gt 0) {
                foreach ($guest in $guestUsers) {
                    $lastSignIn = $null
                    $daysSince  = $null

                    if ($guest.SignInActivity -and $guest.SignInActivity.LastSignInDateTime) {
                        $lastSignIn = $guest.SignInActivity.LastSignInDateTime
                        $daysSince  = ([DateTime]::UtcNow - $lastSignIn).Days
                    }
                    else {
                        $daysSince = 999
                    }

                    # Guests use 60-day threshold
                    if ($daysSince -lt 60) { continue }

                    $riskFlag = Get-DAMOpsRiskFlag -DaysSinceSignIn $daysSince `
                        -IsPrivileged $false `
                        -UserType 'Guest' `
                        -GroupCount 0

                    $auditResults += [PSCustomObject]@{
                        DisplayName      = $guest.DisplayName
                        UPN              = $guest.UserPrincipalName
                        UserType         = 'Guest'
                        Department       = if ($guest.Department) { $guest.Department } else { '-' }
                        Manager          = '-'
                        LastSignIn       = if ($lastSignIn) { $lastSignIn.ToString('yyyy-MM-dd') } else { 'Never' }
                        DaysSinceSignIn  = $daysSince
                        AssignedGroups   = 0
                        IsPrivileged     = $false
                        PrivilegedRoles  = '-'
                        RiskFlag         = $riskFlag
                        Tenant           = $tenant
                        RunDate          = $runDate
                    }
                }
            }

            Write-DAMLog -Action 'AccessAudit' -Result 'SUCCESS' -Ticket $TicketRef `
                -Message "LiveData, $($auditResults.Count) users flagged"
        }
        catch {
            Write-DAMLog -Action 'AccessAudit' -Result 'FAILED' -Ticket $TicketRef `
                -Message $_.Exception.Message
            throw "Access audit failed: $($_.Exception.Message)"
        }
    }

    # -- Export results -------------------------------------------------------
    $csvPath  = Join-Path $OutputPath 'audit_report.csv'
    $htmlPath = Join-Path $OutputPath 'audit_report.html'
    $exportedFiles = @()

    if ($Output -in @('CSV', 'Both')) {
        Write-Verbose "Exporting CSV to: $csvPath"
        $auditResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        $exportedFiles += $csvPath
        Write-DAMLog -Action 'ExportCSV' -Result 'SUCCESS' -Ticket $TicketRef -Message "Path=$csvPath"
    }

    if ($Output -in @('HTML', 'Both')) {
        Write-Verbose "Exporting HTML to: $htmlPath"
        $htmlContent = Export-DAMOpsAuditHTML -AuditData $auditResults -Tenant $tenant -RunDate $runDate
        Set-Content -Path $htmlPath -Value $htmlContent -Encoding UTF8
        $exportedFiles += $htmlPath
        Write-DAMLog -Action 'ExportHTML' -Result 'SUCCESS' -Ticket $TicketRef -Message "Path=$htmlPath"
    }

    # -- Build summary statistics ---------------------------------------------
    $highCount   = ($auditResults | Where-Object { $_.RiskFlag -eq 'HIGH' }).Count
    $mediumCount = ($auditResults | Where-Object { $_.RiskFlag -eq 'MEDIUM' }).Count
    $lowCount    = ($auditResults | Where-Object { $_.RiskFlag -eq 'LOW' }).Count
    $infoCount   = ($auditResults | Where-Object { $_.RiskFlag -eq 'INFO' }).Count
    $guestCount  = ($auditResults | Where-Object { $_.UserType -eq 'Guest' }).Count
    $privCount   = ($auditResults | Where-Object { $_.IsPrivileged -eq $true }).Count

    $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds

    # Display summary
    Write-Host ""
    Write-Host "  /======================================================\" -ForegroundColor DarkCyan
    Write-Host "  |           Access Audit Complete                     |" -ForegroundColor DarkCyan
    Write-Host "  |======================================================|" -ForegroundColor DarkCyan
    Write-Host "  |  Total Flagged:   " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$($auditResults.Count)" -ForegroundColor White
    Write-Host "  |  HIGH Risk:       " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$highCount" -ForegroundColor Red
    Write-Host "  |  MEDIUM Risk:     " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$mediumCount" -ForegroundColor Yellow
    Write-Host "  |  LOW Risk:        " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$lowCount" -ForegroundColor Cyan
    Write-Host "  |  INFO:            " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$infoCount" -ForegroundColor Gray
    Write-Host "  |  Guests:          " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$guestCount" -ForegroundColor White
    Write-Host "  |  Privileged:      " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$privCount" -ForegroundColor Magenta
    Write-Host "  |  Duration:        " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$([math]::Round($elapsed, 1))s" -ForegroundColor White
    Write-Host "  \======================================================/" -ForegroundColor DarkCyan

    foreach ($file in $exportedFiles) {
        Write-Host "  -> $file" -ForegroundColor Green
    }
    Write-Host ""

    # Return structured summary
    return [PSCustomObject]@{
        Status         = 'SUCCESS'
        Tenant         = $tenant
        Threshold      = $StaleThreshold
        TotalUsers     = $auditResults.Count
        HighRisk       = $highCount
        MediumRisk     = $mediumCount
        LowRisk        = $lowCount
        InfoCount      = $infoCount
        GuestCount     = $guestCount
        PrivilegedCount = $privCount
        ExportedFiles  = $exportedFiles
        DurationSeconds = [math]::Round($elapsed, 1)
        RunDate        = $runDate
    }
}


# -- Helper: Risk flag calculation ------------------------------------------------
function Get-DAMOpsRiskFlag {
    <#
    .SYNOPSIS
        Calculate the risk flag for a user based on inactivity and privilege status.
    #>
    [CmdletBinding()]
    param(
        [int]$DaysSinceSignIn,
        [bool]$IsPrivileged,
        [string]$UserType,
        [int]$GroupCount
    )

    # HIGH - Privileged role holder, inactive 30+ days
    if ($IsPrivileged -and $DaysSinceSignIn -ge 30) {
        return 'HIGH'
    }

    # MEDIUM - Regular user, inactive 60-90 days, member of sensitive groups (5+)
    if ($UserType -ne 'Guest' -and $DaysSinceSignIn -ge 60 -and $DaysSinceSignIn -le 90 -and $GroupCount -ge 5) {
        return 'MEDIUM'
    }

    # MEDIUM - Any privileged user regardless of inactivity
    if ($IsPrivileged) {
        return 'MEDIUM'
    }

    # LOW - Guest inactive 30-60 days, no sensitive group membership
    if ($UserType -eq 'Guest' -and $DaysSinceSignIn -ge 30 -and $DaysSinceSignIn -le 60) {
        return 'LOW'
    }

    # LOW - Regular user, very stale (90+ days)
    if ($DaysSinceSignIn -ge 90) {
        return 'LOW'
    }

    # INFO - everything else
    return 'INFO'
}


# -- Helper: Generate mock data for demo/testing ---------------------------------
function Get-DAMOpsMockData {
    <#
    .SYNOPSIS
        Generate 25 realistic mock user records for demo/testing without a live tenant.
    #>
    [CmdletBinding()]
    param(
        [int]$StaleThreshold = 90,
        [switch]$IncludeGuests
    )

    $tenant  = if ($env:DAMOPS_TENANT) { $env:DAMOPS_TENANT } else { 'contoso.onmicrosoft.com' }
    $runDate = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $now     = [DateTime]::UtcNow

    $mockUsers = @(
        # -- HIGH RISK: Privileged + Stale --------------------------------
        [PSCustomObject]@{
            DisplayName='Marcus Chen'; UPN='mchen@contoso.com'; UserType='Member'
            Department='IT Security'; Manager='Sarah Kim'
            LastSignIn=($now.AddDays(-95)).ToString('yyyy-MM-dd'); DaysSinceSignIn=95
            AssignedGroups=12; IsPrivileged=$true
            PrivilegedRoles='Global Administrator (Active)'; RiskFlag='HIGH'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Diana Reyes'; UPN='dreyes@contoso.com'; UserType='Member'
            Department='IT Operations'; Manager='James Wright'
            LastSignIn=($now.AddDays(-47)).ToString('yyyy-MM-dd'); DaysSinceSignIn=47
            AssignedGroups=8; IsPrivileged=$true
            PrivilegedRoles='Privileged Role Administrator (Active); Security Administrator (Active)'; RiskFlag='HIGH'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Robert Okafor'; UPN='rokafor@contoso.com'; UserType='Member'
            Department='Engineering'; Manager='Lisa Park'
            LastSignIn=($now.AddDays(-122)).ToString('yyyy-MM-dd'); DaysSinceSignIn=122
            AssignedGroups=15; IsPrivileged=$true
            PrivilegedRoles='Exchange Administrator (Active); User Administrator (PIM Eligible)'; RiskFlag='HIGH'
            Tenant=$tenant; RunDate=$runDate
        },

        # -- MEDIUM RISK: Inactive with group memberships -----------------
        [PSCustomObject]@{
            DisplayName='Jennifer Liu'; UPN='jliu@contoso.com'; UserType='Member'
            Department='Finance'; Manager='Thomas Brown'
            LastSignIn=($now.AddDays(-72)).ToString('yyyy-MM-dd'); DaysSinceSignIn=72
            AssignedGroups=7; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='MEDIUM'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Amit Patel'; UPN='apatel@contoso.com'; UserType='Member'
            Department='Human Resources'; Manager='Nicole Adams'
            LastSignIn=($now.AddDays(-65)).ToString('yyyy-MM-dd'); DaysSinceSignIn=65
            AssignedGroups=9; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='MEDIUM'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Sarah Kim'; UPN='skim@contoso.com'; UserType='Member'
            Department='IT Security'; Manager='James Wright'
            LastSignIn=($now.AddDays(-5)).ToString('yyyy-MM-dd'); DaysSinceSignIn=5
            AssignedGroups=14; IsPrivileged=$true
            PrivilegedRoles='Security Administrator (Active)'; RiskFlag='MEDIUM'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Carlos Mendez'; UPN='cmendez@contoso.com'; UserType='Member'
            Department='Legal'; Manager='Patricia Wong'
            LastSignIn=($now.AddDays(-78)).ToString('yyyy-MM-dd'); DaysSinceSignIn=78
            AssignedGroups=6; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='MEDIUM'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Priya Sharma'; UPN='psharma@contoso.com'; UserType='Member'
            Department='Compliance'; Manager='Thomas Brown'
            LastSignIn=($now.AddDays(-88)).ToString('yyyy-MM-dd'); DaysSinceSignIn=88
            AssignedGroups=11; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='MEDIUM'
            Tenant=$tenant; RunDate=$runDate
        },

        # -- LOW RISK: Stale or guest accounts ----------------------------
        [PSCustomObject]@{
            DisplayName='Kevin O''Reilly'; UPN='koreilly@contoso.com'; UserType='Member'
            Department='Marketing'; Manager='Rachel Green'
            LastSignIn=($now.AddDays(-105)).ToString('yyyy-MM-dd'); DaysSinceSignIn=105
            AssignedGroups=3; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='LOW'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Fatima Al-Hassan'; UPN='falhassan@contoso.com'; UserType='Member'
            Department='Research'; Manager='David Miller'
            LastSignIn=($now.AddDays(-143)).ToString('yyyy-MM-dd'); DaysSinceSignIn=143
            AssignedGroups=2; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='LOW'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Brian Walsh'; UPN='bwalsh@contoso.com'; UserType='Member'
            Department='Facilities'; Manager='Nicole Adams'
            LastSignIn=($now.AddDays(-201)).ToString('yyyy-MM-dd'); DaysSinceSignIn=201
            AssignedGroups=1; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='LOW'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Emily Tanaka'; UPN='etanaka@contoso.com'; UserType='Member'
            Department='Customer Support'; Manager='Rachel Green'
            LastSignIn=($now.AddDays(-97)).ToString('yyyy-MM-dd'); DaysSinceSignIn=97
            AssignedGroups=4; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='LOW'
            Tenant=$tenant; RunDate=$runDate
        },

        # -- INFO: Active or recently active ------------------------------
        [PSCustomObject]@{
            DisplayName='James Wright'; UPN='jwright@contoso.com'; UserType='Member'
            Department='IT Operations'; Manager='VP IT'
            LastSignIn=($now.AddDays(-1)).ToString('yyyy-MM-dd'); DaysSinceSignIn=1
            AssignedGroups=18; IsPrivileged=$true
            PrivilegedRoles='Global Administrator (Active); User Administrator (Active)'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Lisa Park'; UPN='lpark@contoso.com'; UserType='Member'
            Department='Engineering'; Manager='James Wright'
            LastSignIn=($now.AddDays(-3)).ToString('yyyy-MM-dd'); DaysSinceSignIn=3
            AssignedGroups=10; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Thomas Brown'; UPN='tbrown@contoso.com'; UserType='Member'
            Department='Finance'; Manager='CFO'
            LastSignIn=($now.AddDays(-7)).ToString('yyyy-MM-dd'); DaysSinceSignIn=7
            AssignedGroups=8; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Nicole Adams'; UPN='nadams@contoso.com'; UserType='Member'
            Department='Human Resources'; Manager='VP HR'
            LastSignIn=($now.AddDays(-2)).ToString('yyyy-MM-dd'); DaysSinceSignIn=2
            AssignedGroups=6; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='David Miller'; UPN='dmiller@contoso.com'; UserType='Member'
            Department='Research'; Manager='VP R&D'
            LastSignIn=($now.AddDays(-14)).ToString('yyyy-MM-dd'); DaysSinceSignIn=14
            AssignedGroups=5; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Rachel Green'; UPN='rgreen@contoso.com'; UserType='Member'
            Department='Marketing'; Manager='VP Marketing'
            LastSignIn=($now.AddDays(-8)).ToString('yyyy-MM-dd'); DaysSinceSignIn=8
            AssignedGroups=7; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        },
        [PSCustomObject]@{
            DisplayName='Patricia Wong'; UPN='pwong@contoso.com'; UserType='Member'
            Department='Legal'; Manager='General Counsel'
            LastSignIn=($now.AddDays(-4)).ToString('yyyy-MM-dd'); DaysSinceSignIn=4
            AssignedGroups=4; IsPrivileged=$false
            PrivilegedRoles='-'; RiskFlag='INFO'
            Tenant=$tenant; RunDate=$runDate
        }
    )

    # -- Guest accounts (added when -IncludeGuests specified) -------------
    if ($IncludeGuests) {
        $guestMockUsers = @(
            [PSCustomObject]@{
                DisplayName='External Auditor - PwC'; UPN='ext_auditor_pwc@contoso.com'; UserType='Guest'
                Department='External'; Manager='-'
                LastSignIn=($now.AddDays(-45)).ToString('yyyy-MM-dd'); DaysSinceSignIn=45
                AssignedGroups=2; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='LOW'
                Tenant=$tenant; RunDate=$runDate
            },
            [PSCustomObject]@{
                DisplayName='Vendor - Acme Corp'; UPN='vendor_acme@contoso.com'; UserType='Guest'
                Department='External'; Manager='-'
                LastSignIn=($now.AddDays(-89)).ToString('yyyy-MM-dd'); DaysSinceSignIn=89
                AssignedGroups=1; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='LOW'
                Tenant=$tenant; RunDate=$runDate
            },
            [PSCustomObject]@{
                DisplayName='Contractor - TechStaff'; UPN='contractor_techstaff@contoso.com'; UserType='Guest'
                Department='External'; Manager='James Wright'
                LastSignIn=($now.AddDays(-156)).ToString('yyyy-MM-dd'); DaysSinceSignIn=156
                AssignedGroups=4; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='LOW'
                Tenant=$tenant; RunDate=$runDate
            },
            [PSCustomObject]@{
                DisplayName='Partner - GovSecure LLC'; UPN='partner_govsecure@contoso.com'; UserType='Guest'
                Department='External'; Manager='-'
                LastSignIn=($now.AddDays(-32)).ToString('yyyy-MM-dd'); DaysSinceSignIn=32
                AssignedGroups=3; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='LOW'
                Tenant=$tenant; RunDate=$runDate
            },
            [PSCustomObject]@{
                DisplayName='Intern - Summer 2025'; UPN='intern_summer2025@contoso.com'; UserType='Guest'
                Department='External'; Manager='Lisa Park'
                LastSignIn=($now.AddDays(-220)).ToString('yyyy-MM-dd'); DaysSinceSignIn=220
                AssignedGroups=1; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='LOW'
                Tenant=$tenant; RunDate=$runDate
            },
            [PSCustomObject]@{
                DisplayName='Consultant - Deloitte'; UPN='consultant_deloitte@contoso.com'; UserType='Guest'
                Department='External'; Manager='-'
                LastSignIn=($now.AddDays(-15)).ToString('yyyy-MM-dd'); DaysSinceSignIn=15
                AssignedGroups=2; IsPrivileged=$false
                PrivilegedRoles='-'; RiskFlag='INFO'
                Tenant=$tenant; RunDate=$runDate
            }
        )
        $mockUsers += $guestMockUsers
    }

    return $mockUsers
}


# -- Helper: Export audit data to HTML --------------------------------------------
function Export-DAMOpsAuditHTML {
    <#
    .SYNOPSIS
        Generate a styled HTML report from audit data for quick browser viewing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$AuditData,

        [string]$Tenant = 'Unknown',
        [string]$RunDate = (Get-Date -Format 'yyyy-MM-dd')
    )

    $highCount   = ($AuditData | Where-Object { $_.RiskFlag -eq 'HIGH' }).Count
    $mediumCount = ($AuditData | Where-Object { $_.RiskFlag -eq 'MEDIUM' }).Count
    $lowCount    = ($AuditData | Where-Object { $_.RiskFlag -eq 'LOW' }).Count
    $infoCount   = ($AuditData | Where-Object { $_.RiskFlag -eq 'INFO' }).Count

    # Build table rows
    $tableRows = ""
    foreach ($user in ($AuditData | Sort-Object @{Expression='RiskFlag'; Ascending=$true})) {
        $riskClass = switch ($user.RiskFlag) {
            'HIGH'   { 'risk-high' }
            'MEDIUM' { 'risk-medium' }
            'LOW'    { 'risk-low' }
            default  { 'risk-info' }
        }
        $tableRows += @"
        <tr class="$riskClass">
            <td>$($user.DisplayName)</td>
            <td>$($user.UPN)</td>
            <td>$($user.UserType)</td>
            <td>$($user.Department)</td>
            <td>$($user.Manager)</td>
            <td>$($user.LastSignIn)</td>
            <td>$($user.DaysSinceSignIn)</td>
            <td>$($user.AssignedGroups)</td>
            <td>$($user.IsPrivileged)</td>
            <td>$($user.PrivilegedRoles)</td>
            <td><span class="badge $riskClass">$($user.RiskFlag)</span></td>
        </tr>
`n
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DAMOps Access Audit Report - $Tenant</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #0f1117;
            color: #e1e4e8;
            padding: 2rem;
        }
        .header {
            background: linear-gradient(135deg, #1a1f36 0%, #0d1117 100%);
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 2rem;
            margin-bottom: 2rem;
            text-align: center;
        }
        .header h1 {
            font-size: 1.8rem;
            color: #58a6ff;
            margin-bottom: 0.5rem;
        }
        .header .subtitle {
            color: #8b949e;
            font-size: 0.95rem;
        }
        .stats {
            display: flex;
            gap: 1rem;
            margin-bottom: 2rem;
            flex-wrap: wrap;
        }
        .stat-card {
            flex: 1;
            min-width: 150px;
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 10px;
            padding: 1.2rem;
            text-align: center;
        }
        .stat-card .value {
            font-size: 2rem;
            font-weight: 700;
        }
        .stat-card .label {
            color: #8b949e;
            font-size: 0.85rem;
            margin-top: 0.3rem;
        }
        .stat-card.high .value { color: #f85149; }
        .stat-card.medium .value { color: #d29922; }
        .stat-card.low .value { color: #58a6ff; }
        .stat-card.info .value { color: #8b949e; }
        .stat-card.total .value { color: #e1e4e8; }
        table {
            width: 100%;
            border-collapse: collapse;
            background: #161b22;
            border-radius: 10px;
            overflow: hidden;
            border: 1px solid #30363d;
        }
        thead th {
            background: #1a1f36;
            color: #58a6ff;
            padding: 0.8rem 0.6rem;
            text-align: left;
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            border-bottom: 2px solid #30363d;
            white-space: nowrap;
        }
        tbody td {
            padding: 0.6rem;
            border-bottom: 1px solid #21262d;
            font-size: 0.85rem;
        }
        tbody tr:hover { background: #1c2128; }
        .risk-high { border-left: 3px solid #f85149; }
        .risk-medium { border-left: 3px solid #d29922; }
        .risk-low { border-left: 3px solid #58a6ff; }
        .risk-info { border-left: 3px solid #484f58; }
        .badge {
            padding: 0.2rem 0.6rem;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .badge.risk-high { background: rgba(248,81,73,0.15); color: #f85149; }
        .badge.risk-medium { background: rgba(210,153,34,0.15); color: #d29922; }
        .badge.risk-low { background: rgba(88,166,255,0.15); color: #58a6ff; }
        .badge.risk-info { background: rgba(139,148,158,0.15); color: #8b949e; }
        .footer {
            margin-top: 2rem;
            text-align: center;
            color: #484f58;
            font-size: 0.8rem;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>DAMOps Access Audit Report</h1>
        <div class="subtitle">Tenant: $Tenant | Run Date: $RunDate | Total: $($AuditData.Count) accounts flagged</div>
    </div>

    <div class="stats">
        <div class="stat-card total">
            <div class="value">$($AuditData.Count)</div>
            <div class="label">Total Flagged</div>
        </div>
        <div class="stat-card high">
            <div class="value">$highCount</div>
            <div class="label">HIGH Risk</div>
        </div>
        <div class="stat-card medium">
            <div class="value">$mediumCount</div>
            <div class="label">MEDIUM Risk</div>
        </div>
        <div class="stat-card low">
            <div class="value">$lowCount</div>
            <div class="label">LOW Risk</div>
        </div>
        <div class="stat-card info">
            <div class="value">$infoCount</div>
            <div class="label">INFO</div>
        </div>
    </div>

    <table>
        <thead>
            <tr>
                <th>Name</th>
                <th>UPN</th>
                <th>Type</th>
                <th>Dept</th>
                <th>Manager</th>
                <th>Last Sign-In</th>
                <th>Days Stale</th>
                <th>Groups</th>
                <th>Privileged</th>
                <th>Roles</th>
                <th>Risk</th>
            </tr>
        </thead>
        <tbody>
$tableRows
        </tbody>
    </table>

    <div class="footer">
        Generated by DAMOps v1.0.0 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC
    </div>
</body>
</html>
"@

    return $html
}

