function Invoke-GovernanceBuild {
    <#
        .SYNOPSIS
        Compiles a program's authored hierarchy into its single resolved
        desired-state file (programs/<program>/resolved.yaml).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $program  = Split-Path $ProgramPath -Leaf
    $source   = Import-GovernanceSource -ProgramPath $ProgramPath
    $resolved = Resolve-Governance -Manifest $source.Manifest -Source $source.Hierarchy -Access $source.Access -Members $source.Members -SourceHash $source.Hash -Cadence $source.Cadence -Taxonomy $source.Taxonomy -Systems $source.Systems

    $issues = Test-ResolvedGovernance -Resolved $resolved
    if ($issues.Count -gt 0) {
        $issues | ForEach-Object { Write-Error $_ }
        throw "Governance validation failed for '$program' with $($issues.Count) issue(s)."
    }

    $written = Write-ResolvedGovernance -Resolved $resolved -OutputPath $OutputPath

    Write-Host "Compiled '$program' -> $written" -ForegroundColor Green
    $iterCount = if ($resolved.iterations) { $resolved.iterations.paths.Count } else { 0 }
    Write-Host ("  {0} area paths, {1} teams, {2} repos, {3} pipeline folders, {4} iteration paths" -f `
        $resolved.areaPaths.Count, $resolved.teams.Count, $resolved.repos.Count, $resolved.pipelineFolders.Count, $iterCount)

    return $written
}
