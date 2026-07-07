function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Reconciles the live Azure DevOps project to the resolved desired state
        (idempotent, resumable). (Not yet implemented in v0.1.)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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

    Write-Warning "apply: not yet implemented. Would reconcile org '$targetOrg' to '$ResolvedPath' (token: $tokenState)."
}
