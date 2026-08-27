function Test-Governance {
    <#
        .SYNOPSIS
        Validates the authored governance source — schema, unique short codes,
        resolvable owner references, and Azure DevOps area-path limits — without
        writing the resolved file or making any live calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath
    )

    $program  = Split-Path $ProgramPath -Leaf
    $source   = Import-GovernanceSource -ProgramPath $ProgramPath
    $resolved = Resolve-Governance -Manifest $source.Manifest -Source $source.Hierarchy -Access $source.Access -Members $source.Members -SourceHash $source.Hash -Systems $source.Systems

    $issues = Test-ResolvedGovernance -Resolved $resolved

    # Owner references must resolve to a real team's product-qualified code (e.g. PTL-FND).
    $teamKeys = @($resolved.teams | Where-Object { $_.codePath } | ForEach-Object { $_.codePath })
    foreach ($area in $resolved.areaPaths) {
        if ($area.owner -and $area.owner -notin $teamKeys) {
            $issues += "Owner '$($area.owner)' on '$($area.path)' does not resolve to a team"
        }
    }

    if ($issues.Count -gt 0) {
        $issues | ForEach-Object { Write-Error $_ }
        throw "Governance validation failed for '$program' with $($issues.Count) issue(s)."
    }

    Write-Host "Governance '$program' is valid." -ForegroundColor Green
    return $true
}
