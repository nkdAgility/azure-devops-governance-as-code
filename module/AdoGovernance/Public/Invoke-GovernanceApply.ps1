function Invoke-GovernanceApply {
    <#
        .SYNOPSIS
        Reconciles the live Azure DevOps project to the resolved desired state:
        ensures the project, then creates/configures area paths, teams, team area
        config, security groups, group membership (email users), repos, and
        pipeline folders (idempotent — existing resources are skipped or matched).
        Supports -WhatIf.

        Not yet reconciled (future increments): pipeline folder ACLs,
        Entra-group membership, iteration paths.
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

    # 2. area paths (parents before children; each checked via REST to avoid loading the full tree)
    # scope:future area paths are excluded — those products are not in the current migration scope.
    $areaPaths = @($resolved.areaPaths |
            Where-Object { ($_.path -split '\\').Count -gt 2 -and $_.scope -ne 'future' } |
            ForEach-Object { $_.path }) |
        Sort-Object { ($_ -split '\\').Count }

    $areaCreated = 0
    foreach ($path in $areaPaths) {
        if (-not $projectExists) { break }
        if (Test-AdoAreaPath -OrgUrl $orgUrl -Project $project -ResolvedPath $path) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'create area path')) {
            New-AdoAreaPath -OrgUrl $orgUrl -Project $project -ResolvedPath $path
            Write-Host "  + area  $path" -ForegroundColor Green
            $areaCreated++
        }
    }

    # 3. teams (skip the project default team and scope:future products; each checked via REST)
    $teamCreated = 0
    foreach ($team in $resolved.teams) {
        if ($team.name -eq $project) { continue }
        if ($team.scope -eq 'future') { continue }
        if (-not $projectExists) { break }
        if (Test-AdoTeam -OrgUrl $orgUrl -Project $project -Name $team.name) { continue }
        if ($PSCmdlet.ShouldProcess($team.name, 'create team')) {
            New-AdoTeam -OrgUrl $orgUrl -Project $project -Name $team.name
            Write-Host "  + team  $($team.name)" -ForegroundColor Green
            $teamCreated++
        }
    }

    # 4. team area configuration
    # Each team's areaConfig (from the resolved model) is the complete desired set.
    # We always PATCH it so it's idempotent.
    $areaConfigUpdated = 0
    foreach ($team in $resolved.teams) {
        if ($team.name -eq $project) { continue }   # default team — leave as-is
        if ($team.scope -eq 'future') { continue }  # not in current migration scope
        if (-not $projectExists) { break }
        $desired = @($team.areaConfig | Where-Object { $_ })
        if ($desired.Count -eq 0) { continue }
        if ($PSCmdlet.ShouldProcess($team.name, 'configure team area paths')) {
            try {
                Set-AdoTeamAreaConfig -OrgUrl $orgUrl -Project $project `
                    -Team $team.name -AreaConfig $desired
                $areaConfigUpdated++
            }
            catch {
                Write-Warning "  ! area config for '$($team.name)': $_"
            }
        }
    }

    # 5. security groups
    $existingGroups = if ($projectExists) { Get-AdoGroupSet -OrgUrl $orgUrl -Project $project } else { @{} }
    $groupCreated   = 0
    $groupMap       = @{}    # ado-name -> descriptor

    foreach ($team in $resolved.teams) {
        if ($team.scope -eq 'future') { continue }
        foreach ($grp in @($team.securityGroups | Where-Object { $_ })) {
            if ($groupMap.ContainsKey($grp.ado)) { continue }
            if ($existingGroups.ContainsKey($grp.ado)) {
                $groupMap[$grp.ado] = $existingGroups[$grp.ado]
                continue
            }
            if ($PSCmdlet.ShouldProcess($grp.ado, 'create security group')) {
                try {
                    $descriptor = New-AdoGroup -OrgUrl $orgUrl -Project $project -Name $grp.ado
                    $groupMap[$grp.ado] = $descriptor
                    Write-Host "  + group $($grp.ado)" -ForegroundColor Green
                    $groupCreated++
                }
                catch {
                    Write-Warning "  ! create group '$($grp.ado)': $_"
                }
            }
        }
    }

    # 6. security group membership
    # Resolves email-based members; non-email entries (Entra groups) are logged
    # at Verbose and deferred to a future increment.
    foreach ($team in $resolved.teams) {
        if ($team.scope -eq 'future') { continue }
        foreach ($grp in @($team.securityGroups | Where-Object { $_ })) {
            $members = @($grp.members | Where-Object { $_ })
            if ($members.Count -eq 0) { continue }
            $descriptor = $groupMap[$grp.ado]
            if (-not $descriptor) { continue }

            $currentMembers = @{}
            try { $currentMembers = Get-AdoGroupMemberSet -OrgUrl $orgUrl -Descriptor $descriptor }
            catch { Write-Warning "  ! could not read members of '$($grp.ado)': $_"; continue }

            foreach ($member in $members) {
                if ($member -notmatch '@') {
                    Write-Verbose "  ~ skip non-email member '$member' in '$($grp.ado)' (Entra groups deferred)"
                    continue
                }
                $memberDescriptor = Find-AdoUserDescriptor -OrgUrl $orgUrl -Upn $member
                if (-not $memberDescriptor) {
                    Write-Warning "  ! could not resolve user '$member' in org"
                    continue
                }
                if ($currentMembers.ContainsKey($memberDescriptor)) { continue }
                if ($PSCmdlet.ShouldProcess("$member -> $($grp.ado)", 'add group member')) {
                    try {
                        Add-AdoGroupMember -OrgUrl $orgUrl `
                            -MemberDescriptor $memberDescriptor -ContainerDescriptor $descriptor
                        Write-Host "  + member $member -> $($grp.ado)" -ForegroundColor Green
                    }
                    catch {
                        Write-Warning "  ! add member '$member' to '$($grp.ado)': $_"
                    }
                }
            }
        }
    }

    # 7. repos
    $existingRepos = if ($projectExists) { Get-AdoRepoSet -OrgUrl $orgUrl -Project $project } else { @{} }
    $repoCreated   = 0
    foreach ($repo in @($resolved.repos | Where-Object { $_ })) {
        if ($existingRepos.ContainsKey($repo.name)) { continue }
        if ($PSCmdlet.ShouldProcess($repo.name, 'create repo')) {
            New-AdoRepo -OrgUrl $orgUrl -Project $project -Name $repo.name
            Write-Host "  + repo  $($repo.name)" -ForegroundColor Green
            $repoCreated++
        }
    }

    # 8. pipeline folders
    # ACL application is deferred to a future increment; folders are created here.
    $existingFolders = if ($projectExists) { Get-AdoPipelineFolderSet -OrgUrl $orgUrl -Project $project } else { @{} }
    $folderCreated   = 0
    foreach ($folder in @($resolved.pipelineFolders | Where-Object { $_ })) {
        if ($existingFolders.ContainsKey($folder.path)) { continue }
        if ($PSCmdlet.ShouldProcess($folder.path, 'create pipeline folder')) {
            New-AdoPipelineFolder -OrgUrl $orgUrl -Project $project -Path $folder.path
            Write-Host "  + folder $($folder.path)" -ForegroundColor Green
            $folderCreated++
        }
    }

    Write-Host ("apply complete: +$areaCreated area paths, +$teamCreated teams, " +
        "+$areaConfigUpdated area configs, +$groupCreated groups, " +
        "+$repoCreated repos, +$folderCreated pipeline folders.") -ForegroundColor Green
}
