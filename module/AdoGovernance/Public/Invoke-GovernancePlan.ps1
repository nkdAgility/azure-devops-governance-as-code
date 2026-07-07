function Invoke-GovernancePlan {
    <#
        .SYNOPSIS
        Diffs the resolved desired state against the live Azure DevOps project
        and emits a change set. (Read-only. Not yet implemented in v0.1.)
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

    Write-Warning "plan: not yet implemented. Would diff '$ResolvedPath' against org '$targetOrg' (token: $tokenState)."
}
