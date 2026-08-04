function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Builds the resolved model then runs the compliance loop in Apply mode:
        every governed resource is checked, every deviation is reported, and
        every deviation is corrected in the same pass.

        Use -WhatIf to run in preview mode -- shows what would change without
        making any changes (equivalent to 'plan').

        Use -Prune (or manifest settings.prune: true) to DELETE resources that
        exist in ADO but not in the resolved model. Never on by default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Org,
        [switch]$WhatIf,
        [switch]$Prune
    )

    # Always build first -- ensures the resolved model is current before touching live ADO.
    Invoke-GovernanceBuild -ProgramPath $ProgramPath -OutputPath $ResolvedPath | Out-Null

    $source    = Import-GovernanceSource -ProgramPath $ProgramPath
    $manifest  = $source.Manifest
    $teamIds   = $source.TeamIds      # codePath -> GUID; mutated by reconcile, written back below
    $targetOrg = if ($Org) { $Org } else { $manifest.org }
    Initialize-AdoAuth -Manifest $manifest | Out-Null

    $orgUrl   = ConvertTo-AdoOrgUrl -Org $targetOrg
    $resolved = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)
    $mode     = if ($WhatIf) { 'WhatIf' } else { 'Apply' }

    # Prune is opt-in: the -Prune switch or manifest settings.prune enables it.
    $pruneEnabled = $Prune.IsPresent -or ($manifest.settings -and [bool]$manifest.settings.prune)
    $modeLabel    = if ($pruneEnabled) { "$mode + prune" } else { $mode }

    Write-Host "Applying '$($resolved.program)' in $orgUrl  [mode: $modeLabel]" -ForegroundColor Cyan

    # The target project must exist before any project-scoped reconcile call.
    $projectDecl = $resolved.project
    $projectName = if ($projectDecl -and $projectDecl.name) { $projectDecl.name } else { $resolved.program }
    if (-not (Test-AdoProject -OrgUrl $orgUrl -Project $projectName)) {
        $creationSpec = "process: $($projectDecl.process), visibility: $($projectDecl.visibility), sourceControl: $($projectDecl.sourceControl)"
        if ($mode -eq 'Apply') {
            New-AdoProject -OrgUrl $orgUrl -Project $projectName -Process $projectDecl.process `
                -Visibility $projectDecl.visibility -SourceControl $projectDecl.sourceControl
            Write-Host "  [+]       project: $projectName ($creationSpec)  [created]" -ForegroundColor Yellow
        } else {
            # WhatIf: every governed resource lives inside the project, so there
            # is nothing meaningful to diff until it exists — report and stop.
            Write-Host "  [NON-COMPLIANT] create project: $projectName ($creationSpec)  (dry-run: no changes made)" -ForegroundColor Cyan
            Write-Host "Project '$projectName' does not exist in $orgUrl. Apply would create it and then create every resource in the resolved model." -ForegroundColor Cyan
            return
        }
    }

    Invoke-GovernanceReconcile -Resolved $resolved -OrgUrl $orgUrl -Mode $mode -TeamIds $teamIds -Prune:$pruneEnabled | Out-Null

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
