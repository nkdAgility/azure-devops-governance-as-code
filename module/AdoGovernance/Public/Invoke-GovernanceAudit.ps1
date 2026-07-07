function Invoke-GovernanceAudit {
    <#
        .SYNOPSIS
        Read-only compliance report — naming violations, drift, orphan teams /
        repos, and direct (non-group) permission grants. (Not yet implemented in v0.1.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$Org
    )

    if (-not (Test-Path $ResolvedPath)) {
        throw "No resolved file at $ResolvedPath. Run 'build.ps1 build' first."
    }

    Write-Warning "audit: not yet implemented. Would audit org '$Org' against '$ResolvedPath'."
}
