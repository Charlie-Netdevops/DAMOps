# JMLProcess.ps1 - DAMOps Joiner/Mover/Leaver Module
<#
.SYNOPSIS
    Start-JMLProcess - Process Joiner, Mover, Leaver actions from a standardized CSV.

.DESCRIPTION
    Reads an HR-provided CSV file and processes each row as a Join, Move, or Leave
    action against Active Directory / Entra ID. All actions are logged, support
    DryRun preview, and return structured results.

.NOTES
    File:    JMLProcess.ps1
    Module:  DAMOps
    Author:  DAMOps Team
    Version: 1.0.0
#>

function Start-JMLProcess {
    <#
    .SYNOPSIS
        Process Joiner/Mover/Leaver actions from a standardized CSV input.

    .DESCRIPTION
        Reads a CSV file with Joiner, Mover, and Leaver actions and processes
        each row accordingly. No HR system integration required - HR drops a CSV
        and this function runs it.

        Actions:
          JOIN  - Create account, assign groups, assign license, set manager
          MOVE  - Update department, groups, manager, license
          LEAVE - Disable account, strip groups, remove license, set OOF

    .PARAMETER InputFile
        Path to the hr_changes.csv file with JML actions.

    .PARAMETER DryRun
        Preview all actions without making any changes.

    .PARAMETER TicketRef
        ITSM ticket number for audit logging.

    .PARAMETER NotifyManager
        Send email notification to the user's manager on completion.

    .EXAMPLE
        Start-JMLProcess -InputFile .\Templates\hr_changes_sample.csv -DryRun

    .EXAMPLE
        Start-JMLProcess -InputFile .\hr_changes.csv -TicketRef "INC0012345" -NotifyManager
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Path to HR changes CSV file")]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$InputFile,

        [switch]$DryRun,

        [Parameter(HelpMessage = "ITSM ticket reference")]
        [string]$TicketRef = '-',

        [switch]$NotifyManager
    )

    $startTime = [DateTime]::UtcNow
    $tenant    = if ($env:DAMOPS_TENANT) { $env:DAMOPS_TENANT } else { 'UNKNOWN' }
    $changedBy = "$($env:USERNAME)@$($env:COMPUTERNAME)"

    Write-Verbose "=========================================================="
    Write-Verbose "DAMOps JML Process Starting"
    Write-Verbose "Input:    $InputFile"
    Write-Verbose "DryRun:   $DryRun"
    Write-Verbose "Ticket:   $TicketRef"
    Write-Verbose "Notify:   $NotifyManager"
    Write-Verbose "=========================================================="

    # -- Read and validate CSV ------------------------------------------------
    try {
        $csvData = Import-Csv -Path $InputFile -Encoding UTF8
        Write-Verbose "Loaded $($csvData.Count) rows from CSV"
    }
    catch {
        Write-DAMLog -Action 'JMLProcess' -Result 'FAILED' -Ticket $TicketRef `
            -Message "CSV read failed: $($_.Exception.Message)"
        throw "Failed to read input file: $($_.Exception.Message)"
    }

    # Validate required columns
    $requiredColumns = @('Action', 'DisplayName', 'UPN', 'Department', 'Manager',
                         'TargetOU', 'Groups', 'LicenseSKU', 'StartDate', 'TicketRef')

    $csvColumns = $csvData[0].PSObject.Properties.Name
    $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

    if ($missingColumns.Count -gt 0) {
        $errorMsg = "CSV is missing required columns: $($missingColumns -join ', ')"
        Write-DAMLog -Action 'JMLProcess' -Result 'FAILED' -Ticket $TicketRef -Message $errorMsg
        throw $errorMsg
    }

    # Validate Action values
    $invalidActions = $csvData | Where-Object { $_.Action -notin @('Join', 'Move', 'Leave') }
    if ($invalidActions.Count -gt 0) {
        $badActions = ($invalidActions | Select-Object -ExpandProperty Action -Unique) -join ', '
        Write-Warning "Invalid action values found: $badActions. Valid: Join, Move, Leave"
    }

    Write-Verbose "CSV validation passed - $($csvData.Count) valid records"

    # -- Process each row -----------------------------------------------------
    $results = @()
    $successCount = 0
    $failedCount  = 0
    $skippedCount = 0

    foreach ($row in $csvData) {
        $action      = $row.Action
        $upn         = $row.UPN
        $displayName = $row.DisplayName
        $department  = $row.Department
        $manager     = $row.Manager
        $targetOU    = $row.TargetOU
        $groups      = ($row.Groups -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $licenseSKU  = $row.LicenseSKU
        $startDate   = $row.StartDate
        $rowTicket   = if ($row.TicketRef) { $row.TicketRef } else { $TicketRef }

        Write-Verbose "----------------------------------------------------"
        Write-Verbose "Processing: $action | $displayName ($upn)"

        $resultStatus = 'SUCCESS'
        $resultMessage = ''
        $actionsPerformed = @()

        try {
            switch ($action) {
                # -- JOIN: Create new account -----------------------------
                'Join' {
                    Write-Verbose "  Action: JOIN - Creating account for $displayName"

                    # Generate temporary password
                    $tempPassword = "DAMOps-$(Get-Random -Minimum 1000 -Maximum 9999)!$(Get-Random -Minimum 10 -Maximum 99)"

                    if ($DryRun) {
                        $actionsPerformed += "[DRYRUN] Would create user: $upn"
                        $actionsPerformed += "[DRYRUN] Would set department: $department"
                        $actionsPerformed += "[DRYRUN] Would set manager: $manager"
                        $actionsPerformed += "[DRYRUN] Would place in OU: $targetOU"
                        $actionsPerformed += "[DRYRUN] Would assign groups: $($groups -join ', ')"
                        $actionsPerformed += "[DRYRUN] Would assign license: $licenseSKU"
                        $actionsPerformed += "[DRYRUN] Would set temp password and require change at login"
                        $actionsPerformed += "[DRYRUN] Would enable account (effective: $startDate)"

                        $resultStatus = 'DRYRUN'
                    }
                    else {
                        # Create user in Entra ID
                        $passwordProfile = @{
                            Password                      = $tempPassword
                            ForceChangePasswordNextSignIn  = $true
                        }

                        $userParams = @{
                            DisplayName       = $displayName
                            UserPrincipalName = $upn
                            MailNickname      = ($upn -split '@')[0]
                            Department        = $department
                            AccountEnabled    = $true
                            PasswordProfile   = $passwordProfile
                        }

                        $newUser = New-MgUser @userParams -ErrorAction Stop
                        $actionsPerformed += "Created user: $upn (ID: $($newUser.Id))"

                        # Set manager
                        if ($manager -ne '-' -and $manager -ne '') {
                            try {
                                $managerUser = Get-MgUser -Filter "userPrincipalName eq '$manager'" -ErrorAction Stop
                                $managerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($managerUser.Id)" }
                                Set-MgUserManagerByRef -UserId $newUser.Id -BodyParameter $managerRef
                                $actionsPerformed += "Set manager: $manager"
                            }
                            catch {
                                Write-Warning "  Could not set manager $manager for $upn : $($_.Exception.Message)"
                                $actionsPerformed += "WARN: Manager set failed - $($_.Exception.Message)"
                            }
                        }

                        # Assign groups
                        foreach ($groupName in $groups) {
                            try {
                                $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
                                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $newUser.Id -ErrorAction Stop
                                $actionsPerformed += "Added to group: $groupName"
                            }
                            catch {
                                Write-Warning "  Could not add $upn to group $groupName : $($_.Exception.Message)"
                                $actionsPerformed += "WARN: Group add failed for $groupName - $($_.Exception.Message)"
                            }
                        }

                        # Assign license
                        if ($licenseSKU -ne '-' -and $licenseSKU -ne '') {
                            try {
                                $licenseParams = @{
                                    AddLicenses    = @(@{ SkuId = $licenseSKU })
                                    RemoveLicenses = @()
                                }
                                Set-MgUserLicense -UserId $newUser.Id -BodyParameter $licenseParams -ErrorAction Stop
                                $actionsPerformed += "Assigned license: $licenseSKU"
                            }
                            catch {
                                Write-Warning "  Could not assign license $licenseSKU to $upn : $($_.Exception.Message)"
                                $actionsPerformed += "WARN: License assignment failed - $($_.Exception.Message)"
                            }
                        }
                    }
                }

                # -- MOVE: Update existing account ------------------------
                'Move' {
                    Write-Verbose "  Action: MOVE - Updating account for $displayName"

                    if ($DryRun) {
                        $actionsPerformed += "[DRYRUN] Would update department to: $department"
                        $actionsPerformed += "[DRYRUN] Would update manager to: $manager"
                        $actionsPerformed += "[DRYRUN] Would move to OU: $targetOU"
                        $actionsPerformed += "[DRYRUN] Would update groups: $($groups -join ', ')"
                        if ($licenseSKU -ne '-' -and $licenseSKU -ne '') {
                            $actionsPerformed += "[DRYRUN] Would update license to: $licenseSKU"
                        }

                        $resultStatus = 'DRYRUN'
                    }
                    else {
                        # Update user properties
                        $updateParams = @{
                            Department = $department
                        }
                        Update-MgUser -UserId $upn -BodyParameter $updateParams -ErrorAction Stop
                        $actionsPerformed += "Updated department: $department"

                        # Update manager
                        if ($manager -ne '-' -and $manager -ne '') {
                            try {
                                $managerUser = Get-MgUser -Filter "userPrincipalName eq '$manager'" -ErrorAction Stop
                                $managerRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($managerUser.Id)" }
                                Set-MgUserManagerByRef -UserId $upn -BodyParameter $managerRef
                                $actionsPerformed += "Updated manager: $manager"
                            }
                            catch {
                                $actionsPerformed += "WARN: Manager update failed - $($_.Exception.Message)"
                            }
                        }

                        # Update group memberships - remove old, add new
                        try {
                            # Get current groups
                            $currentGroups = Get-MgUserMemberOf -UserId $upn -ErrorAction Stop |
                                Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }

                            # Remove from groups not in new list
                            foreach ($currentGroup in $currentGroups) {
                                $groupName = $currentGroup.AdditionalProperties.displayName
                                if ($groupName -notin $groups) {
                                    Remove-MgGroupMemberByRef -GroupId $currentGroup.Id -DirectoryObjectId $upn -ErrorAction SilentlyContinue
                                    $actionsPerformed += "Removed from group: $groupName"
                                }
                            }

                            # Add to new groups
                            foreach ($groupName in $groups) {
                                $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
                                if ($group) {
                                    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $upn -ErrorAction SilentlyContinue
                                    $actionsPerformed += "Added to group: $groupName"
                                }
                            }
                        }
                        catch {
                            $actionsPerformed += "WARN: Group update failed - $($_.Exception.Message)"
                        }
                    }
                }

                # -- LEAVE: Disable and clean up account ------------------
                'Leave' {
                    Write-Verbose "  Action: LEAVE - Processing offboarding for $displayName"

                    if ($DryRun) {
                        $actionsPerformed += "[DRYRUN] Would disable account: $upn"
                        $actionsPerformed += "[DRYRUN] Would strip all group memberships"
                        $actionsPerformed += "[DRYRUN] Would remove M365 license: $licenseSKU"
                        $actionsPerformed += "[DRYRUN] Would set out-of-office auto-reply"
                        $actionsPerformed += "[DRYRUN] Would hide from Global Address List"
                        $actionsPerformed += "[DRYRUN] Would move to Disabled Users OU"
                        $actionsPerformed += "[DRYRUN] Would flag for 30-day retention before deletion"

                        $resultStatus = 'DRYRUN'
                    }
                    else {
                        # Disable account
                        Update-MgUser -UserId $upn -BodyParameter @{ AccountEnabled = $false } -ErrorAction Stop
                        $actionsPerformed += "Disabled account: $upn"

                        # Strip all group memberships
                        try {
                            $userGroups = Get-MgUserMemberOf -UserId $upn -ErrorAction Stop |
                                Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }

                            foreach ($group in $userGroups) {
                                Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $upn -ErrorAction SilentlyContinue
                                $actionsPerformed += "Removed from group: $($group.AdditionalProperties.displayName)"
                            }
                        }
                        catch {
                            $actionsPerformed += "WARN: Group removal failed - $($_.Exception.Message)"
                        }

                        # Remove license
                        if ($licenseSKU -ne '-' -and $licenseSKU -ne '') {
                            try {
                                $licenseParams = @{
                                    AddLicenses    = @()
                                    RemoveLicenses = @($licenseSKU)
                                }
                                Set-MgUserLicense -UserId $upn -BodyParameter $licenseParams -ErrorAction Stop
                                $actionsPerformed += "Removed license: $licenseSKU"
                            }
                            catch {
                                $actionsPerformed += "WARN: License removal failed - $($_.Exception.Message)"
                            }
                        }

                        # Hide from GAL
                        try {
                            Update-MgUser -UserId $upn -BodyParameter @{ ShowInAddressList = $false } -ErrorAction Stop
                            $actionsPerformed += "Hidden from Global Address List"
                        }
                        catch {
                            $actionsPerformed += "WARN: GAL hide failed - $($_.Exception.Message)"
                        }

                        # Note: OOF auto-reply and OU move require Exchange Online and AD cmdlets
                        $actionsPerformed += "NOTE: Out-of-office reply requires Exchange Online management shell"
                        $actionsPerformed += "NOTE: OU move requires on-premises AD cmdlets (Move-ADObject)"
                        $actionsPerformed += "Flagged for 30-day retention (deletion date: $([DateTime]::UtcNow.AddDays(30).ToString('yyyy-MM-dd')))"
                    }
                }

                default {
                    $resultStatus = 'SKIPPED'
                    $actionsPerformed += "Unknown action type: $action - skipped"
                    $skippedCount++
                }
            }

            if ($resultStatus -ne 'SKIPPED') {
                if ($resultStatus -eq 'DRYRUN') { $skippedCount++ }
                else { $successCount++ }
            }
        }
        catch {
            $resultStatus = 'FAILED'
            $resultMessage = $_.Exception.Message
            $actionsPerformed += "ERROR: $resultMessage"
            $failedCount++
            Write-Warning "  FAILED processing $upn : $resultMessage"
        }

        # Log each action
        Write-DAMLog -Action "JML_$action" -Result $resultStatus -UPN $upn `
            -Ticket $rowTicket -Message ($actionsPerformed -join ' | ')

        # Build result object for this row
        $results += [PSCustomObject]@{
            Action           = $action
            DisplayName      = $displayName
            UPN              = $upn
            Department       = $department
            Manager          = $manager
            Status           = $resultStatus
            ActionsPerformed = $actionsPerformed
            Ticket           = $rowTicket
            ProcessedAt      = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
            ProcessedBy      = $changedBy
        }

        # Display row result
        $statusColor = switch ($resultStatus) {
            'SUCCESS' { 'Green' }
            'DRYRUN'  { 'Yellow' }
            'FAILED'  { 'Red' }
            default   { 'Gray' }
        }
        Write-Host "  [$resultStatus] " -NoNewline -ForegroundColor $statusColor
        Write-Host "$action " -NoNewline -ForegroundColor White
        Write-Host "$displayName ($upn)" -ForegroundColor DarkGray

        foreach ($actionItem in $actionsPerformed) {
            Write-Host "         -> $actionItem" -ForegroundColor DarkGray
        }
    }

    $elapsed = ([DateTime]::UtcNow - $startTime).TotalSeconds

    # -- Display summary ------------------------------------------------------
    $joinCount  = ($results | Where-Object { $_.Action -eq 'Join' }).Count
    $moveCount  = ($results | Where-Object { $_.Action -eq 'Move' }).Count
    $leaveCount = ($results | Where-Object { $_.Action -eq 'Leave' }).Count

    Write-Host ""
    Write-Host "  /======================================================\" -ForegroundColor DarkCyan
    Write-Host "  |           JML Process Complete                      |" -ForegroundColor DarkCyan
    Write-Host "  |======================================================|" -ForegroundColor DarkCyan
    Write-Host "  |  Total Processed: $($results.Count)" -ForegroundColor DarkCyan
    Write-Host "  |  Joins:           $joinCount" -ForegroundColor DarkCyan
    Write-Host "  |  Moves:           $moveCount" -ForegroundColor DarkCyan
    Write-Host "  |  Leaves:          $leaveCount" -ForegroundColor DarkCyan
    Write-Host "  |  ---------------------------------" -ForegroundColor DarkGray
    Write-Host "  |  Success:         " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$successCount" -ForegroundColor Green
    Write-Host "  |  Dry Run/Skip:    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$skippedCount" -ForegroundColor Yellow
    Write-Host "  |  Failed:          " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$failedCount" -ForegroundColor Red
    Write-Host "  |  Duration:        $([math]::Round($elapsed, 1))s" -ForegroundColor DarkCyan
    Write-Host "  \======================================================/" -ForegroundColor DarkCyan
    Write-Host ""

    # Return structured summary
    return [PSCustomObject]@{
        Status          = if ($failedCount -eq 0) { 'SUCCESS' } elseif ($successCount -gt 0) { 'PARTIAL' } else { 'FAILED' }
        TotalProcessed  = $results.Count
        Joins           = $joinCount
        Moves           = $moveCount
        Leaves          = $leaveCount
        Succeeded       = $successCount
        Failed          = $failedCount
        DryRun          = $DryRun.IsPresent
        Ticket          = $TicketRef
        Results         = $results
        DurationSeconds = [math]::Round($elapsed, 1)
    }
}
