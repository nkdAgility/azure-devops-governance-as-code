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
    $resolved = Resolve-Governance -Source $source.Hierarchy -Access $source.Access -Members $source.Members -SourceHash $source.Hash

    $issues = Test-ResolvedGovernance -Resolved $resolved
    if ($issues.Count -gt 0) {
        $issues | ForEach-Object { Write-Error $_ }
        throw "Governance validation failed for '$program' with $($issues.Count) issue(s)."
    }

    $written = Write-ResolvedGovernance -Resolved $resolved -OutputPath $OutputPath

    Write-Host "Compiled '$program' -> $written" -ForegroundColor Green
    Write-Host ("  {0} area paths, {1} teams, {2} repos, {3} pipeline folders" -f `
        $resolved.areaPaths.Count, $resolved.teams.Count, $resolved.repos.Count, $resolved.pipelineFolders.Count)

    return $written
}
