# Connect.ps1 - DAMOps Authentication Module
<#
.SYNOPSIS
    Connect-DAMOps - Authenticate to Microsoft Entra ID and validate NVIDIA API.

.DESCRIPTION
    Establishes a session with Microsoft Graph and validates the NVIDIA NIM API key.
    This function MUST be called before any other DAMOps module. It:
      1. Connects to Microsoft Graph with required scopes
      2. Validates the NVIDIA API key environment variable
      3. Tests the NVIDIA API with a lightweight ping call
      4. Stores the tenant name for downstream module use

.NOTES
    File:    Connect.ps1
    Module:  DAMOps
    Author:  DAMOps Team
    Version: 1.0.0
#>

function Connect-DAMOps {
    <#
    .SYNOPSIS
        Authenticate to Entra ID and validate NVIDIA API key.

    .DESCRIPTION
        Must be called first in every DAMOps session. Establishes Microsoft Graph
        connection with the required scopes for access auditing and directory reads,
        then validates the NVIDIA NIM API key for AI-powered risk analysis.

    .PARAMETER Tenant
        The Entra ID tenant domain (e.g. contoso.onmicrosoft.com).

    .PARAMETER AuthMethod
        Authentication flow. DeviceCode (default) for interactive use,
        ServicePrincipal for automated/scheduled runs.

    .PARAMETER ClientId
        Application (client) ID for ServicePrincipal authentication.

    .PARAMETER ClientSecret
        Client secret value for ServicePrincipal authentication.

    .PARAMETER DryRun
        Show what connections would be established without actually connecting.

    .EXAMPLE
        Connect-DAMOps -Tenant contoso.onmicrosoft.com
        # Interactive device code flow

    .EXAMPLE
        Connect-DAMOps -Tenant contoso.onmicrosoft.com -AuthMethod ServicePrincipal -ClientId "abc" -ClientSecret "xyz"
        # Service principal flow for automation

    .EXAMPLE
        Connect-DAMOps -Tenant contoso.onmicrosoft.com -DryRun
        # Preview connection parameters without connecting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Entra ID tenant domain (e.g. contoso.onmicrosoft.com)")]
        [ValidateNotNullOrEmpty()]
        [string]$Tenant,

        [Parameter(HelpMessage = "Auth method: DeviceCode or ServicePrincipal")]
        [ValidateSet('DeviceCode', 'ServicePrincipal')]
        [string]$AuthMethod = 'DeviceCode',

        [Parameter(HelpMessage = "Application (client) ID for ServicePrincipal auth")]
        [string]$ClientId,

        [Parameter(HelpMessage = "Client secret for ServicePrincipal auth")]
        [string]$ClientSecret,

        [switch]$DryRun
    )

    # -- Define required Graph scopes -----------------------------------------
    $requiredScopes = @(
        'User.Read.All'
        'Directory.Read.All'
        'AuditLog.Read.All'
        'RoleManagement.Read.Directory'
    )

    Write-Verbose "------------------------------------------------------------"
    Write-Verbose "DAMOps Connect - Starting authentication sequence"
    Write-Verbose "Tenant:     $Tenant"
    Write-Verbose "AuthMethod: $AuthMethod"
    Write-Verbose "Scopes:     $($requiredScopes -join ', ')"
    Write-Verbose "------------------------------------------------------------"

    # -- Validate ServicePrincipal parameters ---------------------------------
    if ($AuthMethod -eq 'ServicePrincipal') {
        if ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)) {
            $errorMsg = "ServicePrincipal auth requires both -ClientId and -ClientSecret parameters."
            Write-DAMLog -Action 'ConnectGraph' -Result 'FAILED' -Message $errorMsg
            throw $errorMsg
        }
    }

    # -- DryRun - show plan and exit ------------------------------------------
    if ($DryRun) {
        Write-Host "`n  [DRYRUN] Connection Plan:" -ForegroundColor Cyan
        Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  Tenant:      $Tenant" -ForegroundColor White
        Write-Host "  Auth Method: $AuthMethod" -ForegroundColor White
        Write-Host "  Scopes:      $($requiredScopes -join ', ')" -ForegroundColor White
        Write-Host "  NVIDIA API:  Would validate `$env:NVIDIA_API_KEY" -ForegroundColor White
        Write-Host "  Env var:     `$env:DAMOPS_TENANT = $Tenant" -ForegroundColor White
        Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  [DRYRUN] No connections established.`n" -ForegroundColor Yellow

        Write-DAMLog -Action 'ConnectGraph' -Result 'DRYRUN' -Message "Tenant=$Tenant, Method=$AuthMethod"

        return [PSCustomObject]@{
            Tenant      = $Tenant
            AuthMethod  = $AuthMethod
            GraphScopes = $requiredScopes
            GraphStatus = 'DRYRUN'
            AIStatus    = 'DRYRUN'
            ConnectedAt = [DateTime]::UtcNow
            DryRun      = $true
        }
    }

    # -- Step 1: Connect to Microsoft Graph -----------------------------------
    $graphStatus = 'DISCONNECTED'

    try {
        Write-Verbose "Step 1/4: Connecting to Microsoft Graph..."

        # Check if Microsoft.Graph module is available
        if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
            Write-Warning "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser"
            Write-Warning "Continuing in limited mode - Graph commands will not be available."
            $graphStatus = 'UNAVAILABLE'
            Write-DAMLog -Action 'ConnectGraph' -Result 'SKIPPED' -Message "Microsoft.Graph module not installed"
        }
        else {
            $connectParams = @{
                TenantId = $Tenant
                Scopes   = $requiredScopes
            }

            # ServicePrincipal uses client credential flow
            if ($AuthMethod -eq 'ServicePrincipal') {
                $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
                $credential   = New-Object System.Management.Automation.PSCredential($ClientId, $secureSecret)
                $connectParams['ClientSecretCredential'] = $credential
            }

            Connect-MgGraph @connectParams -ErrorAction Stop
            $graphStatus = 'CONNECTED'

            # Verify connection
            $context = Get-MgContext
            Write-Verbose "  Graph connected: $($context.Account) | Scopes: $($context.Scopes -join ', ')"
            Write-DAMLog -Action 'ConnectGraph' -Result 'SUCCESS' -Message "Tenant=$Tenant, Method=$AuthMethod"
        }
    }
    catch {
        $graphStatus = 'FAILED'
        Write-Warning "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        Write-DAMLog -Action 'ConnectGraph' -Result 'FAILED' -Message $_.Exception.Message
    }

    # -- Step 2: Store tenant name --------------------------------------------
    Write-Verbose "Step 2/4: Setting tenant environment variable..."
    $env:DAMOPS_TENANT = $Tenant
    Write-Verbose "  `$env:DAMOPS_TENANT = $Tenant"

    # -- Step 3: Validate NVIDIA API key --------------------------------------
    $aiStatus = 'UNKNOWN'

    Write-Verbose "Step 3/4: Validating NVIDIA API key..."

    if ([string]::IsNullOrWhiteSpace($env:NVIDIA_API_KEY)) {
        Write-Warning "NVIDIA_API_KEY environment variable is not set. AI features will be unavailable."
        Write-Warning "Set it with: `$env:NVIDIA_API_KEY = 'your-key-here'"
        $aiStatus = 'NO_API_KEY'
        Write-DAMLog -Action 'ValidateNVIDIA' -Result 'FAILED' -Message "NVIDIA_API_KEY not set"
    }
    else {
        Write-Verbose "  API key found (starts with: $($env:NVIDIA_API_KEY.Substring(0, [Math]::Min(10, $env:NVIDIA_API_KEY.Length)))...)"

        # -- Step 4: Test NVIDIA API with lightweight ping ----------------
        Write-Verbose "Step 4/4: Testing NVIDIA API connectivity..."

        try {
            $testBody = @{
                model      = 'meta/llama-3.3-70b-instruct'
                messages   = @(
                    @{ role = 'user'; content = 'Reply with OK' }
                )
                max_tokens = 5
            } | ConvertTo-Json -Depth 5

            $testHeaders = @{
                'Authorization' = "Bearer $($env:NVIDIA_API_KEY)"
                'Content-Type'  = 'application/json'
            }

            $response = Invoke-RestMethod `
                -Uri 'https://integrate.api.nvidia.com/v1/chat/completions' `
                -Method POST `
                -Headers $testHeaders `
                -Body $testBody `
                -TimeoutSec 15 `
                -ErrorAction Stop

            if ($response.choices) {
                $aiStatus = 'CONNECTED'
                Write-Verbose "  NVIDIA API: OK - Model responded successfully"
                Write-DAMLog -Action 'ValidateNVIDIA' -Result 'SUCCESS' -Message "API test passed"
            }
            else {
                $aiStatus = 'UNEXPECTED_RESPONSE'
                Write-Warning "NVIDIA API returned unexpected response format."
                Write-DAMLog -Action 'ValidateNVIDIA' -Result 'FAILED' -Message "Unexpected response format"
            }
        }
        catch {
            $aiStatus = 'FAILED'
            Write-Warning "NVIDIA API test failed: $($_.Exception.Message)"
            Write-DAMLog -Action 'ValidateNVIDIA' -Result 'FAILED' -Message $_.Exception.Message
        }
    }

    # -- Output connection summary --------------------------------------------
    $summary = [PSCustomObject]@{
        Tenant      = $Tenant
        AuthMethod  = $AuthMethod
        GraphScopes = $requiredScopes -join ', '
        GraphStatus = $graphStatus
        AIStatus    = $aiStatus
        ConnectedAt = [DateTime]::UtcNow
        DryRun      = $false
    }

    # Display formatted summary
    Write-Host ""
    Write-Host "  /======================================================\" -ForegroundColor DarkCyan
    Write-Host "  |           DAMOps Connection Summary                 |" -ForegroundColor DarkCyan
    Write-Host "  |======================================================|" -ForegroundColor DarkCyan

    # Graph status with color coding
    $graphColor = switch ($graphStatus) {
        'CONNECTED'   { 'Green' }
        'UNAVAILABLE' { 'Yellow' }
        default       { 'Red' }
    }
    Write-Host "  |  Tenant:       " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$Tenant" -ForegroundColor White
    Write-Host "  |  Auth Method:  " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$AuthMethod" -ForegroundColor White
    Write-Host "  |  Graph:        " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$graphStatus" -ForegroundColor $graphColor
    Write-Host "  |  Scopes:       " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$($requiredScopes.Count) requested" -ForegroundColor White

    # AI status with color coding
    $aiColor = switch ($aiStatus) {
        'CONNECTED' { 'Green' }
        'NO_API_KEY' { 'Yellow' }
        default      { 'Red' }
    }
    Write-Host "  |  NVIDIA AI:    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$aiStatus" -ForegroundColor $aiColor

    Write-Host "  |  Time:         " -NoNewline -ForegroundColor DarkCyan
    Write-Host "$([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC" -ForegroundColor White
    Write-Host "  \======================================================/" -ForegroundColor DarkCyan
    Write-Host ""

    return $summary
}
