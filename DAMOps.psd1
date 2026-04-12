#
# Module manifest for module 'DAMOps'
# Domain Access Management Operations Toolkit
# Generated: 2026-04-12
#

@{

    # Script module or binary associated with this manifest
    RootModule        = 'DAMOps.psm1'

    # Version number
    ModuleVersion     = '1.0.0'

    # Unique module ID
    GUID              = 'a3f1c8e7-5d2b-4a96-b8e3-1f7c9d4e6a2b'

    # Author
    Author            = 'DAMOps Team'

    # Company
    CompanyName       = 'DAMOps'

    # Copyright
    Copyright         = '(c) 2026 DAMOps. All rights reserved.'

    # Module description
    Description       = 'DAMOps — Domain Access Management Operations Toolkit. A modular, CLI-based automation toolkit for Microsoft Entra ID and Active Directory access reviews, JML lifecycle processing, AI-powered risk analysis, and role-based script generation.'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Required modules — users must install these before importing DAMOps
    # RequiredModules = @(
    #     @{ ModuleName = 'Microsoft.Graph.Authentication';            ModuleVersion = '2.0.0' }
    #     @{ ModuleName = 'Microsoft.Graph.Users';                     ModuleVersion = '2.0.0' }
    #     @{ ModuleName = 'Microsoft.Graph.Identity.DirectoryManagement'; ModuleVersion = '2.0.0' }
    # )

    # Functions to export — only these are visible to the user after Import-Module
    FunctionsToExport = @(
        'Connect-DAMOps'
        'Invoke-AccessAudit'
        'New-AccessDoc'
        'Start-JMLProcess'
        'Get-AIRiskSummary'
        'New-DAMScript'
        'Write-DAMLog'
    )

    # Cmdlets to export — none, we only use functions
    CmdletsToExport   = @()

    # Variables to export
    VariablesToExport  = @()

    # Aliases to export
    AliasesToExport    = @()

    # Private data — metadata and tags for PSGallery
    PrivateData       = @{
        PSData = @{
            Tags         = @('EntraID', 'ActiveDirectory', 'IAM', 'AccessReview', 'Automation', 'NVIDIA', 'AI')
            LicenseUri   = ''
            ProjectUri   = ''
            ReleaseNotes = 'v1.0.0 — Initial release with full audit, documentation, JML, AI risk, and script generation modules.'
        }
    }

}
