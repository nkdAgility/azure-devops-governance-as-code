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

    $source    = Import-GovernanceSource -ProgramPath $ProgramPath
    $manifest  = $source.Manifest
    $teamIds   = $source.TeamIds      # codePath -> GUID; mutated by reconcile, written back below
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
    Invoke-GovernanceReconcile -Resolved $resolved -OrgUrl $orgUrl -Mode $mode -TeamIds $teamIds | Out-Null

    # Persist discovered/created team GUIDs back to team-ids.yaml (Apply mode only)
    if ($mode -eq 'Apply' -and $teamIds.Count -gt 0) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('# Auto-maintained by governance apply. Do not edit by hand.')
        $lines.Add('# Maps codePath -> ADO team GUID so teams can be found after a rename.')
        $lines.Add('teams:')
        foreach ($k in ($teamIds.Keys | Sort-Object)) { $lines.Add("  ${k}: $($teamIds[$k])") }
        Set-Content -Path $source.TeamIdsPath -Value $lines -Encoding utf8
        Write-Host "Team state written: $($source.TeamIdsPath)" -ForegroundColor DarkCyan
    }
}
