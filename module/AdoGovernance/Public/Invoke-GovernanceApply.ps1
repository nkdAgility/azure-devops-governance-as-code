function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Reconciles the live Azure DevOps project to the resolved desired state
        (idempotent, resumable). (Not yet implemented in v0.1.)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$Org
    )

    if (-not (Test-Path $ResolvedPath)) {
        throw "No resolved file at $ResolvedPath. Run 'build.ps1 build' first."
    }

    Write-Warning "apply: not yet implemented. Would reconcile org '$Org' to '$ResolvedPath'."
}
