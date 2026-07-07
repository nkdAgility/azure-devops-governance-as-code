function Invoke-GovernancePlan {
    <#
        .SYNOPSIS
        Diffs the resolved desired state against the live Azure DevOps project
        and emits a change set. (Read-only. Not yet implemented in v0.1.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$Org
    )

    if (-not (Test-Path $ResolvedPath)) {
        throw "No resolved file at $ResolvedPath. Run 'build.ps1 build' first."
    }

    Write-Warning "plan: not yet implemented. Would diff '$ResolvedPath' against org '$Org'."
}
