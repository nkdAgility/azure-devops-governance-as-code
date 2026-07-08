function Invoke-GovernanceReconcile {
    <#
        .SYNOPSIS
        Unified compliance loop. For every governed resource it:
          1. Checks the live ADO state against the resolved desired state
          2. Reports every deviation (MISSING, DRIFT, ORPHAN)
          3. In Apply mode: corrects the deviation immediately after reporting it

        This is the engine behind both 'audit' and 'apply'. There is no apply
        without audit — the check always runs first.

        Mode:
          Audit  — check + report only. Read-only, no changes made.
          Apply  — check + report + fix. Corrects drift and creates missing.
          WhatIf — check + report what would be fixed. No changes made.

        Returns an array of finding strings. Empty = fully compliant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Resolved,
        [Parameter(Mandatory)][string]$OrgUrl,
        [ValidateSet('Audit', 'Apply', 'WhatIf')]
        [string]$Mode = 'Audit'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    $project  = $Resolved.program
    $doFix    = ($Mode -eq 'Apply')

    # ── output helpers (scriptblocks to avoid polluting module scope) ─────────
    $rOk      = { param($m) Write-Host "  [ok]      $m" -ForegroundColor Green }
    $rCreated = { param($m) Write-Host "  [+]       $m  [created]" -ForegroundColor Yellow }
    $rFixed   = { param($m) Write-Host "  [~]       $m  [corrected]" -ForegroundColor Yellow }
    $rWould   = { param($m) Write-Host "  [NON-COMPLIANT] $m  (dry-run: no changes made)" -ForegroundColor Cyan }
    $rMissing = { param($m) Write-Host "  [MISSING] $m" -ForegroundColor Red }
    $rDrift   = { param($m) Write-Host "  [DRIFT]   $m" -ForegroundColor Red }
    $rOrphan  = { param($m) Write-Host "  [AUDIT EXCEPTION] $m  (exists in ADO but not in config — remove or add to config)" -ForegroundColor Magenta }
    $rError   = { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }

    # ── 1. Area paths ─────────────────────────────────────────────────────────
    Write-Host "`n--- Area paths ---" -ForegroundColor Cyan

    $liveAreas    = Get-AdoAreaPathSubtree -OrgUrl $OrgUrl -Project $project
    $desiredAreas = @($Resolved.areaPaths | Where-Object { $_.scope -ne 'future' })
    $desiredPaths = @($desiredAreas | ForEach-Object { $_.path }) |
                    Sort-Object { ($_ -split '\\').Count }   # parents before children

    foreach ($path in $desiredPaths) {
        if ($liveAreas.ContainsKey($path)) {
            & $rOk $path
        } else {
            $findings.Add("MISSING area path: $path")
            if ($doFix) {
                try {
                    New-AdoAreaPath -OrgUrl $OrgUrl -Project $project -ResolvedPath $path
                    & $rCreated "area path: $path"
                    $liveAreas[$path] = $true   # keep local state current
                } catch { & $rError "create area path '$path': $_" }
            } elseif ($Mode -eq 'WhatIf') { & $rWould "create area path: $path"
            } else                         { & $rMissing "area path: $path" }
        }
    }

    # Orphan area paths — exist in ADO but absent from the resolved model
    foreach ($livePath in ($liveAreas.Keys | Sort-Object)) {
        if ($livePath -notin $desiredPaths) {
            $findings.Add("AUDIT EXCEPTION area path: $livePath")
            & $rOrphan "area path: $livePath"
        }
    }

    # ── 2. Teams ──────────────────────────────────────────────────────────────
    Write-Host "`n--- Teams ---" -ForegroundColor Cyan

    $liveTeamNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-AdoTeamList -OrgUrl $OrgUrl -Project $project),
        [System.StringComparer]::OrdinalIgnoreCase)

    $desiredTeams = @($Resolved.teams | Where-Object {
        $_.name -ne $project -and $_.scope -ne 'future' })

    foreach ($team in $desiredTeams) {
        $exists = $liveTeamNames.Contains($team.name)

        if (-not $exists) {
            $findings.Add("MISSING team: $($team.name)")
            if ($doFix) {
                try {
                    New-AdoTeam -OrgUrl $OrgUrl -Project $project -Name $team.name
                    & $rCreated "team: $($team.name)"
                    $liveTeamNames.Add($team.name) | Out-Null
                    $exists = $true
                } catch { & $rError "create team '$($team.name)': $_" }
            } elseif ($Mode -eq 'WhatIf') { & $rWould "create team: $($team.name)"
            } else                         { & $rMissing "team: $($team.name)" }
        }

        # Area config check — runs whether team existed or was just created
        if ($exists) {
            try {
                $liveConfig  = Get-AdoTeamAreaConfig -OrgUrl $OrgUrl -Project $project -Team $team.name
                $liveSet     = @{}
                foreach ($v in @($liveConfig.values)) {
                    $liveSet["\$($v.value)"] = [bool]$v.includeChildren
                }

                $desired  = @($team.areaConfig | Where-Object { $_ })
                $configOk = $true

                foreach ($entry in $desired) {
                    if (-not $liveSet.ContainsKey($entry.path)) {
                        $findings.Add("DRIFT team '$($team.name)': area path '$($entry.path)' not configured")
                        $configOk = $false
                    } elseif ($liveSet[$entry.path] -ne [bool]$entry.includeSubAreas) {
                        $findings.Add("DRIFT team '$($team.name)': '$($entry.path)' includeSubAreas should be $($entry.includeSubAreas) but is $($liveSet[$entry.path])")
                        $configOk = $false
                    }
                }
                foreach ($livePath in $liveSet.Keys) {
                    if ($livePath -notin ($desired | ForEach-Object { $_.path })) {
                        $findings.Add("DRIFT team '$($team.name)': unexpected area path '$livePath' in config")
                        $configOk = $false
                    }
                }

                if ($configOk) {
                    & $rOk "team: $($team.name)  (area config)"
                } else {
                    if ($doFix) {
                        try {
                            Set-AdoTeamAreaConfig -OrgUrl $OrgUrl -Project $project -Team $team.name -AreaConfig $desired
                            & $rFixed "team: $($team.name)  area config"
                        } catch { & $rError "set area config '$($team.name)': $_" }
                    } elseif ($Mode -eq 'WhatIf') { & $rWould "correct area config for team: $($team.name)"
                    } else                         { & $rDrift "team: $($team.name)  area config wrong" }
                }
            } catch { & $rError "read area config '$($team.name)': $_" }
        }
    }

    # Orphan teams — exist in ADO but absent from the resolved model
    $desiredTeamNameSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($desiredTeams | ForEach-Object { $_.name }) + @($project)),
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($liveName in ($liveTeamNames | Sort-Object)) {
        if (-not $desiredTeamNameSet.Contains($liveName)) {
            $findings.Add("AUDIT EXCEPTION team: $liveName")
            & $rOrphan "team: $liveName"
        }
    }

    # ── 3. Security groups ────────────────────────────────────────────────────
    Write-Host "`n--- Security groups ---" -ForegroundColor Cyan

    $liveGroups = Get-AdoGroupSet -OrgUrl $OrgUrl -Project $project
    $seen       = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($team in ($Resolved.teams | Where-Object { $_.scope -ne 'future' })) {
        foreach ($grp in @($team.securityGroups | Where-Object { $_ })) {
            if (-not $seen.Add($grp.ado)) { continue }

            $groupExists = $liveGroups.ContainsKey($grp.ado)
            if (-not $groupExists) {
                $findings.Add("MISSING group: $($grp.ado)")
                if ($doFix) {
                    try {
                        $liveGroups[$grp.ado] = New-AdoGroup -OrgUrl $OrgUrl -Project $project -Name $grp.ado
                        & $rCreated "group: $($grp.ado)"
                        $groupExists = $true
                    } catch { & $rError "create group '$($grp.ado)': $_"; continue }
                } elseif ($Mode -eq 'WhatIf') { & $rWould "create group: $($grp.ado)"; continue
                } else                         { & $rMissing "group: $($grp.ado)"; continue }
            } else {
                & $rOk "group: $($grp.ado)"
            }

            # Membership check (email-based users only; Entra groups deferred)
            if (-not $groupExists) { continue }
            $members = @($grp.members | Where-Object { $_ -match '@' })
            if ($members.Count -eq 0) { continue }

            $descriptor = $liveGroups[$grp.ado]
            if (-not $descriptor) { continue }

            try {
                $liveMembers = Get-AdoGroupMemberSet -OrgUrl $OrgUrl -Descriptor $descriptor
                foreach ($m in $members) {
                    $mDesc = Find-AdoUserDescriptor -OrgUrl $OrgUrl -Upn $m
                    if (-not $mDesc) {
                        $findings.Add("UNRESOLVABLE member '$m' in '$($grp.ado)'")
                        & $rError "unresolvable user '$m' in '$($grp.ado)'"
                        continue
                    }
                    if (-not $liveMembers.ContainsKey($mDesc)) {
                        $findings.Add("MISSING member '$m' in '$($grp.ado)'")
                        if ($doFix) {
                            try {
                                Add-AdoGroupMember -OrgUrl $OrgUrl -MemberDescriptor $mDesc -ContainerDescriptor $descriptor
                                & $rCreated "member: $m → $($grp.ado)"
                            } catch { & $rError "add member '$m' to '$($grp.ado)': $_" }
                        } elseif ($Mode -eq 'WhatIf') { & $rWould "add member: $m → $($grp.ado)"
                        } else                         { & $rMissing "member: $m in $($grp.ado)" }
                    }
                }
            } catch { & $rError "read members of '$($grp.ado)': $_" }
        }
    }

    # ── 4. Repos ──────────────────────────────────────────────────────────────
    Write-Host "`n--- Repos ---" -ForegroundColor Cyan

    $liveRepos = Get-AdoRepoSet -OrgUrl $OrgUrl -Project $project
    foreach ($repo in @($Resolved.repos | Where-Object { $_ })) {
        if ($liveRepos.ContainsKey($repo.name)) {
            & $rOk "repo: $($repo.name)"
        } else {
            $findings.Add("MISSING repo: $($repo.name)")
            if ($doFix) {
                try {
                    New-AdoRepo -OrgUrl $OrgUrl -Project $project -Name $repo.name
                    & $rCreated "repo: $($repo.name)"
                } catch { & $rError "create repo '$($repo.name)': $_" }
            } elseif ($Mode -eq 'WhatIf') { & $rWould "create repo: $($repo.name)"
            } else                         { & $rMissing "repo: $($repo.name)" }
        }
    }

    # ── 5. Pipeline folders ───────────────────────────────────────────────────
    Write-Host "`n--- Pipeline folders ---" -ForegroundColor Cyan

    $liveFolders = Get-AdoPipelineFolderSet -OrgUrl $OrgUrl -Project $project
    foreach ($folder in @($Resolved.pipelineFolders | Where-Object { $_ })) {
        if ($liveFolders.ContainsKey($folder.path)) {
            & $rOk "folder: $($folder.path)"
            # TODO: ACL compliance check (future increment — ADR-003)
        } else {
            $findings.Add("MISSING pipeline folder: $($folder.path)")
            if ($doFix) {
                try {
                    New-AdoPipelineFolder -OrgUrl $OrgUrl -Project $project -Path $folder.path
                    & $rCreated "folder: $($folder.path)"
                } catch { & $rError "create folder '$($folder.path)': $_" }
            } elseif ($Mode -eq 'WhatIf') { & $rWould "create folder: $($folder.path)"
            } else                         { & $rMissing "folder: $($folder.path)" }
        }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ''
    if ($findings.Count -eq 0) {
        Write-Host "COMPLIANT — zero findings." -ForegroundColor Green
    } else {
        $suffix = switch ($Mode) {
            'Apply'  { 'remaining after apply' }
            'WhatIf' { 'found (dry-run — no changes made)' }
            default  { 'found' }
        }
        Write-Host "NON-COMPLIANT — $($findings.Count) finding(s) $suffix." -ForegroundColor Red
        Write-Error "Governance compliance: $($findings.Count) finding(s) $suffix."
    }

    return $findings.ToArray()
}
