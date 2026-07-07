function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Reconciles the live Azure DevOps project to the resolved desired state:
        ensures the project, then creates the area-path tree and the teams
        (idempotent — existing resources are skipped). Supports -WhatIf.

        Not yet reconciled (future increments): team area configuration,
        repos, pipeline folders + ACLs, security groups + membership.
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

    Test-AdoCli

    $manifest  = (Import-GovernanceSource -ProgramPath $ProgramPath).Manifest
    $targetOrg = if ($Org) { $Org } else { $manifest.org }
    $token     = Resolve-AccessToken $manifest.accessToken
    if (-not $token) {
        throw "Access token not found. Set the environment variable referenced by manifest.accessToken."
    }
    Set-AdoAuth $token

    $orgUrl   = ConvertTo-AdoOrgUrl -Org $targetOrg
    $resolved = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)
    $project  = $resolved.program

    Write-Host "Reconciling '$project' in $orgUrl ..." -ForegroundColor Cyan

    # 1. project (the container)
    $projectExists = Test-AdoProject -OrgUrl $orgUrl -Project $project
    if (-not $projectExists) {
        if ($PSCmdlet.ShouldProcess("$targetOrg/$project", 'create project')) {
            New-AdoProject -OrgUrl $orgUrl -Project $project
            Write-Host "  + project '$project'" -ForegroundColor Green
            $projectExists = $true
        }
    }

    # 2. area paths (parents before children; skip existing)
    $existingAreas = if ($projectExists) { Get-AdoAreaPathSet -OrgUrl $orgUrl -Project $project } else { @{} }
    $areaPaths = @($resolved.areaPaths | ForEach-Object { $_.path } |
            Where-Object { ($_ -split '\\').Count -gt 2 }) |
        Sort-Object { ($_ -split '\\').Count }

    $areaCreated = 0
    foreach ($path in $areaPaths) {
        if ($existingAreas.ContainsKey($path)) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'create area path')) {
            New-AdoAreaPath -OrgUrl $orgUrl -Project $project -ResolvedPath $path
            Write-Host "  + area  $path" -ForegroundColor Green
            $areaCreated++
        }
    }

    # 3. teams (skip the project default team and existing teams)
    $existingTeams = if ($projectExists) { Get-AdoTeamSet -OrgUrl $orgUrl -Project $project } else { @{} }
    $teamCreated = 0
    foreach ($team in $resolved.teams) {
        if ($team.name -eq $project) { continue }
        if ($existingTeams.ContainsKey($team.name)) { continue }
        if ($PSCmdlet.ShouldProcess($team.name, 'create team')) {
            New-AdoTeam -OrgUrl $orgUrl -Project $project -Name $team.name
            Write-Host "  + team  $($team.name)" -ForegroundColor Green
            $teamCreated++
        }
    }

    Write-Host "apply complete: +$areaCreated area paths, +$teamCreated teams." -ForegroundColor Green
}
