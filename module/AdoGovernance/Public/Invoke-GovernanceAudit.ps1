function Invoke-GovernanceAudit {
    <#
        .SYNOPSIS
        Read-only compliance report — naming violations, drift, orphan teams /
        repos, and direct (non-group) permission grants. (Not yet implemented in v0.1.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Org
    )

    if (-not (Test-Path $ResolvedPath)) {
        throw "No resolved file at $ResolvedPath. Run 'build.ps1 build' first."
    }

    $manifest   = (Import-GovernanceSource -ProgramPath $ProgramPath).Manifest
    $targetOrg  = if ($Org) { $Org } else { $manifest.org }
    $token      = Resolve-AccessToken $manifest.accessToken
    $tokenState = if ($token) { 'present' } else { 'MISSING' }

    Write-Warning "audit: not yet implemented. Would audit org '$targetOrg' against '$ResolvedPath' (token: $tokenState)."
}
