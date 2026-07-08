function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Builds the resolved model then runs the compliance loop in Apply mode:
        every governed resource is checked, every deviation is reported, and
        every deviation is corrected in the same pass.

        Use -WhatIf to run in preview mode -- shows what would change without
        making any changes (equivalent to 'plan').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Org,
        [switch]$WhatIf
    )

    # Always build first -- ensures the resolved model is current before touching live ADO.
    Invoke-GovernanceBuild -ProgramPath $ProgramPath -OutputPath $ResolvedPath | Out-Null

    $manifest  = (Import-GovernanceSource -ProgramPath $ProgramPath).Manifest
    $targetOrg = if ($Org) { $Org } else { $manifest.org }
    $token     = Resolve-AccessToken $manifest.accessToken
    if (-not $token) {
        throw "Access token not found. Set the environment variable referenced by manifest.accessToken."
    }
    Set-AdoAuth $token

    $orgUrl   = ConvertTo-AdoOrgUrl -Org $targetOrg
    $resolved = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)
    $mode     = if ($WhatIf) { 'WhatIf' } else { 'Apply' }

    Write-Host "Applying '$($resolved.program)' in $orgUrl  [mode: $mode]" -ForegroundColor Cyan
    Invoke-GovernanceReconcile -Resolved $resolved -OrgUrl $orgUrl -Mode $mode
}
