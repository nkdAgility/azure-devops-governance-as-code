function Invoke-GovernanceReconcile {
    <#
        .SYNOPSIS
        Unified compliance loop. For every governed resource it checks live ADO
        state against the resolved desired state.

        In Apply mode: deviations are corrected immediately. A finding is only
        recorded when a fix FAILS. Successfully applied changes are NOT findings.

        In Audit / WhatIf mode: every deviation is recorded as a finding and
        reported. No changes are made.

        Mode:
          Audit  - check + report only. Read-only. Findings signal CI failure.
          Apply  - check + fix. Findings = things that could not be fixed.
          WhatIf - check + report what would be fixed. No changes made.

        Prune (opt-in, never on by default): in Apply mode, resources that exist
        in ADO but not in the resolved model are DELETED instead of reported —
        orphan teams, orphan area paths (work items reparented to the parent
        node), orphan repos (soft-deleted to the recycle bin), and extra group
        members. scope:future placeholders, the project default team/repo, and
        iteration paths (ADR-005) are never pruned. In WhatIf mode prune shows
        what would be deleted; Audit never deletes regardless.

        Returns a string array of remaining findings. Empty = fully compliant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Resolved,
        [Parameter(Mandatory)][string]$OrgUrl,
        [ValidateSet('Audit', 'Apply', 'WhatIf')]
        [string]$Mode = 'Audit',
        [string]$ReportPath = '',
        [hashtable]$TeamIds = @{},   # codePath -> ADO GUID; mutated in-place for caller to persist
        [switch]$Prune               # delete orphans (Apply) / report would-delete (WhatIf)
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    # Target project comes from the manifest project block; fall back to the
    # program name for resolved files built before the project declaration existed.
    $project  = if ($Resolved.project -and $Resolved.project.name) { $Resolved.project.name } else { $Resolved.program }
    $doFix    = ($Mode -eq 'Apply')

    # output helpers
    $rOk      = { param($m) Write-Host "  [ok]      $m" -ForegroundColor Green }
    $rCreated = { param($m) Write-Host "  [+]       $m  [created]" -ForegroundColor Yellow }
    $rFixed   = { param($m) Write-Host "  [~]       $m  [corrected]" -ForegroundColor Yellow }
    $rDeleted = { param($m) Write-Host "  [-]       $m  [deleted]" -ForegroundColor Yellow }
    $rWould   = { param($m) Write-Host "  [NON-COMPLIANT] $m  (dry-run: no changes made)" -ForegroundColor Cyan }
    $rMissing = { param($m) Write-Host "  [MISSING] $m" -ForegroundColor Red }
    $rDrift   = { param($m) Write-Host "  [DRIFT]   $m" -ForegroundColor Red }
    $rOrphan  = { param($m) Write-Host "  [AUDIT EXCEPTION] $m  (exists in ADO but not in config)" -ForegroundColor Magenta }
    $rError   = { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }

    # ── 1. Area paths ─────────────────────────────────────────────────────────
    Write-Host "`n--- Area paths ---" -ForegroundColor Cyan

    $desiredAreas = @($Resolved.areaPaths | Where-Object { $_.scope -ne 'future' })
    $desiredPaths = @($desiredAreas | ForEach-Object { $_.path }) |
                    Sort-Object { ($_ -split '\\').Count }

    $liveAreas = @{}
    foreach ($path in $desiredPaths) {
        $exists = Test-AdoAreaPath -OrgUrl $OrgUrl -Project $project -ResolvedPath $path
        if ($exists) {
            $liveAreas[$path] = $true
            & $rOk $path
        } else {
            if ($doFix) {
                try {
                    New-AdoAreaPath -OrgUrl $OrgUrl -Project $project -ResolvedPath $path
                    & $rCreated "area path: $path"
                    $liveAreas[$path] = $true
                } catch {
                    $findings.Add("ERROR creating area path '$path': $_")
                    & $rError "create area path '$path': $_"
                }
            } else {
                $findings.Add("MISSING area path: $path")
                if ($Mode -eq 'WhatIf') { & $rWould "create area path: $path" }
                else                     { & $rMissing "area path: $path" }
            }
        }
    }

    # Audit exceptions: best-effort bulk fetch for extra paths.
    # Orphans are matched against EVERY path in the resolved model, including
    # scope:future placeholders — future products are invisible to apply/audit
    # and must never be flagged (or pruned) as orphans.
    try {
        $bulkAreas   = Get-AdoAreaPathSubtree -OrgUrl $OrgUrl -Project $project
        $orphanAreas = (Test-GovernanceAreaCompliance `
            -ModelPaths @($Resolved.areaPaths | ForEach-Object { $_.path }) `
            -LiveSubtree $bulkAreas).Orphans
        foreach ($livePath in $orphanAreas) {
            if ($Prune -and $doFix) {
                try {
                    Remove-AdoAreaPath -OrgUrl $OrgUrl -Project $project -ResolvedPath $livePath
                    & $rDeleted "area path: $livePath"
                } catch {
                    $findings.Add("ERROR deleting orphan area path '$livePath': $_")
                    & $rError "delete area path '$livePath': $_"
                }
            } else {
                $findings.Add("AUDIT EXCEPTION area path: $livePath")
                if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "delete orphan area path: $livePath" }
                else                                { & $rOrphan "area path: $livePath" }
            }
        }
    } catch { Write-Verbose "Area path audit exception check skipped: $_" }

    # ── 2. Iteration paths — must exist before teams are configured ─────────────
    if ($Resolved.iterations -and $Resolved.iterations.paths) {
        Write-Host "`n--- Iteration paths ---" -ForegroundColor Cyan

        # Compliance rule: we only check that the DESIRED paths EXIST.
        # Extra iteration paths in ADO that match the governance naming pattern
        # (\Program\YYYY\S[n]\S[n]-W[n]) are NEVER flagged as audit exceptions —
        # old sprints are expected to accumulate and are compliant by definition.

        $iterPaths = @($Resolved.iterations.paths | Sort-Object { ($_.path -split '\\').Count })
        foreach ($iter in $iterPaths) {
            $exists = Test-AdoIterationPath -OrgUrl $OrgUrl -Project $project -ResolvedPath $iter.path
            if ($exists) {
                & $rOk "iter: $($iter.path)"
            } else {
                if ($doFix) {
                    try {
                        New-AdoIterationPath -OrgUrl $OrgUrl -Project $project `
                            -ResolvedPath $iter.path -StartDate $iter.startDate -EndDate $iter.endDate
                        & $rCreated "iter: $($iter.path)"
                    } catch {
                        $findings.Add("ERROR creating iteration '$($iter.path)': $_")
                        & $rError "create iteration '$($iter.path)': $_"
                    }
                } else {
                    $findings.Add("MISSING iteration: $($iter.path)")
                    if ($Mode -eq 'WhatIf') { & $rWould "create iteration: $($iter.path)" }
                    else                     { & $rMissing "iteration: $($iter.path)" }
                }
            }
        }
    }

    # ── 3. Teams ──────────────────────────────────────────────────────────────
    Write-Host "`n--- Teams ---" -ForegroundColor Cyan

    # $liveTeams  : name -> GUID  (from ADO)
    # $reverseIds : GUID -> name  (reverse index for GUID-based lookup)
    $liveTeams  = Get-AdoTeamList -OrgUrl $OrgUrl -Project $project
    $reverseIds = @{}
    foreach ($k in $liveTeams.Keys) { if ($liveTeams[$k]) { $reverseIds[$liveTeams[$k]] = $k } }

    $liveTeamNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($liveTeams.Keys | Where-Object { $_ }),
        [System.StringComparer]::OrdinalIgnoreCase)

    $desiredTeams = @($Resolved.teams | Where-Object {
        $_.name -ne $project -and $_.scope -ne 'future' })

    foreach ($team in $desiredTeams) {
        $existingId   = $null
        $existingName = $null

        # Phase 1: find by current desired name (fast path)
        if ($liveTeams.ContainsKey($team.name)) {
            $existingId   = $liveTeams[$team.name]
            $existingName = $team.name
        }
        # Phase 2: find by stored GUID (survives a rename in the config)
        elseif ($TeamIds.ContainsKey($team.codePath)) {
            $storedId = $TeamIds[$team.codePath]
            if ($storedId -and $reverseIds.ContainsKey($storedId)) {
                $existingId   = $storedId
                $existingName = $reverseIds[$storedId]   # current ADO name (old name)
            }
        }

        $exists = $null -ne $existingId

        if (-not $exists) {
            # Team not found by name or GUID — create it
            if ($doFix) {
                try {
                    $newId = New-AdoTeam -OrgUrl $OrgUrl -Project $project -Name $team.name
                    & $rCreated "team: $($team.name)"
                    # Initialise iteration defaults immediately so area config PATCH succeeds
                    Initialize-AdoTeamDefaults -OrgUrl $OrgUrl -Project $project -Team $team.name
                    $TeamIds[$team.codePath] = $newId
                    $liveTeams[$team.name]   = $newId
                    $liveTeamNames.Add($team.name) | Out-Null
                    $exists = $true; $existingId = $newId; $existingName = $team.name
                } catch {
                    $findings.Add("ERROR creating team '$($team.name)': $_")
                    & $rError "create team '$($team.name)': $_"
                }
            } else {
                $findings.Add("MISSING team: $($team.name)")
                if ($Mode -eq 'WhatIf') { & $rWould "create team: $($team.name)" }
                else                     { & $rMissing "team: $($team.name)" }
            }
        }
        elseif ($existingName -ne $team.name) {
            # Found by GUID but name doesn't match — rename
            if ($doFix) {
                try {
                    Set-AdoTeamName -OrgUrl $OrgUrl -Project $project -TeamId $existingId -NewName $team.name
                    & $rFixed "team: renamed '$existingName' -> '$($team.name)'"
                    $liveTeams.Remove($existingName)
                    $liveTeams[$team.name] = $existingId
                    $liveTeamNames.Remove($existingName) | Out-Null
                    $liveTeamNames.Add($team.name) | Out-Null
                    $TeamIds[$team.codePath] = $existingId
                    $existingName = $team.name
                } catch {
                    $findings.Add("ERROR renaming team '$existingName' to '$($team.name)': $_")
                    & $rError "rename team '$existingName' to '$($team.name)': $_"
                }
            } else {
                $findings.Add("DRIFT team '$($team.codePath)': name should be '$($team.name)' but ADO has '$existingName'")
                if ($Mode -eq 'WhatIf') { & $rWould "rename team '$existingName' -> '$($team.name)'" }
                else                     { & $rDrift "team '$($team.codePath)': name '$existingName' should be '$($team.name)'" }
            }
        }
        else {
            # Found by name — record GUID for future renames
            $TeamIds[$team.codePath] = $existingId
        }

        if ($exists -and $existingName -eq $team.name) {
            try {
                $liveConfig = Get-AdoTeamAreaConfig -OrgUrl $OrgUrl -Project $project -Team $team.name
                $liveSet    = @{}
                foreach ($v in @($liveConfig.values)) {
                    $liveSet["\$($v.value)"] = [bool]$v.includeChildren
                }

                $desired      = @($team.areaConfig | Where-Object { $_ })
                $driftDetails = [System.Collections.Generic.List[string]]::new()

                foreach ($entry in $desired) {
                    if (-not $liveSet.ContainsKey($entry.path)) {
                        $driftDetails.Add("DRIFT team '$($team.name)': area path '$($entry.path)' not configured")
                    } elseif ($liveSet[$entry.path] -ne [bool]$entry.includeSubAreas) {
                        $driftDetails.Add("DRIFT team '$($team.name)': '$($entry.path)' includeSubAreas should be $($entry.includeSubAreas) but is $($liveSet[$entry.path])")
                    }
                }
                foreach ($livePath in $liveSet.Keys) {
                    if ($livePath -notin ($desired | ForEach-Object { $_.path })) {
                        $driftDetails.Add("DRIFT team '$($team.name)': unexpected area path '$livePath' in config")
                    }
                }

                if ($driftDetails.Count -eq 0) {
                    & $rOk "team: $($team.name)  (area config)"
                } else {
                    if ($doFix) {
                        try {
                            Set-AdoTeamAreaConfig -OrgUrl $OrgUrl -Project $project -Team $team.name -AreaConfig $desired
                            & $rFixed "team: $($team.name)  area config"
                        } catch {
                            foreach ($d in $driftDetails) { $findings.Add($d) }
                            $findings.Add("ERROR setting area config '$($team.name)': $_")
                            & $rError "set area config '$($team.name)': $_"
                        }
                    } else {
                        foreach ($d in $driftDetails) { $findings.Add($d) }
                        if ($Mode -eq 'WhatIf') { & $rWould "correct area config for team: $($team.name)" }
                        else                     { & $rDrift "team: $($team.name)  area config wrong" }
                    }
                }
            } catch { & $rError "read area config '$($team.name)': $_" }
        }
    }

    # Orphan teams: exempt the project default team and scope:future teams —
    # future products are invisible to apply/audit and must never be flagged
    # (or pruned) as orphans.
    $futureTeamNames    = @($Resolved.teams | Where-Object { $_.scope -eq 'future' } | ForEach-Object { $_.name })
    $desiredTeamNameSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($desiredTeams | ForEach-Object { $_.name }) + $futureTeamNames + @($project) + @("$project Team")),
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($liveName in ($liveTeamNames | Sort-Object)) {
        if (-not $desiredTeamNameSet.Contains($liveName)) {
            if ($Prune -and $doFix) {
                try {
                    Remove-AdoTeam -OrgUrl $OrgUrl -Project $project -TeamId $liveTeams[$liveName]
                    & $rDeleted "team: $liveName"
                } catch {
                    $findings.Add("ERROR deleting orphan team '$liveName': $_")
                    & $rError "delete team '$liveName': $_"
                }
            } else {
                $findings.Add("AUDIT EXCEPTION team: $liveName")
                if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "delete orphan team: $liveName" }
                else                                { & $rOrphan "team: $liveName" }
            }
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
                if ($doFix) {
                    try {
                        $liveGroups[$grp.ado] = New-AdoGroup -OrgUrl $OrgUrl -Project $project -Name $grp.ado
                        & $rCreated "group: $($grp.ado)"
                        $groupExists = $true
                    } catch {
                        $findings.Add("ERROR creating group '$($grp.ado)': $_")
                        & $rError "create group '$($grp.ado)': $_"
                        continue
                    }
                } else {
                    $findings.Add("MISSING group: $($grp.ado)")
                    if ($Mode -eq 'WhatIf') { & $rWould "create group: $($grp.ado)"; continue }
                    else                     { & $rMissing "group: $($grp.ado)"; continue }
                }
            } else {
                & $rOk "group: $($grp.ado)"
            }

            if (-not $groupExists) { continue }

            # Entries are objects ({upn}/{group} + reason/expires, normalized at
            # build time); legacy plain UPN strings still accepted. An EMPTY list
            # is enforced — the group must have no members, extras are drift.
            $userEntries  = [System.Collections.Generic.List[object]]::new()
            $groupEntries = [System.Collections.Generic.List[object]]::new()
            foreach ($e in @($grp.members | Where-Object { $_ })) {
                if ($e -is [string]) {
                    if ($e -match '@') { $userEntries.Add(@{ upn = $e }) }
                    continue
                }
                if ($e.upn)   { $userEntries.Add($e);  continue }
                if ($e.group) { $groupEntries.Add($e); continue }
            }

            $descriptor = $liveGroups[$grp.ado]
            if (-not $descriptor) { continue }

            try {
                $liveMembers = Get-AdoGroupMemberSet -OrgUrl $OrgUrl -Descriptor $descriptor

                # Gather: resolve every desired entry to a graph descriptor.
                # A resolution failure is a finding here AND suppresses the
                # extra-member check below (via the evaluator) — an unresolved
                # desired member is indistinguishable from an extra.
                $desiredResolved = [System.Collections.Generic.List[object]]::new()
                $unresolved      = $false

                foreach ($m in $userEntries) {
                    $upn   = [string]$m.upn
                    $mDesc = Find-AdoUserDescriptor -OrgUrl $OrgUrl -Upn $upn
                    if (-not $mDesc) {
                        # Say WHY: either the org knows a near-match (config has
                        # the wrong UPN) or the user is not in the org at all.
                        $near = @(Find-AdoUserSuggestion -OrgUrl $OrgUrl -Upn $upn)
                        $why  = if ($near.Count -gt 0) {
                            "no org member has this exact UPN - did you mean: $($near -join ', ')?"
                        } else {
                            "no org member matches this UPN - the user must be added to the org (Entra membership alone is not enough) before governance can grant them access"
                        }
                        $findings.Add("UNRESOLVABLE member '$upn' in '$($grp.ado)': $why")
                        & $rError "unresolvable user '$upn' in '$($grp.ado)': $why"
                        $unresolved = $true
                        continue
                    }
                    $desiredResolved.Add(@{ kind = 'user'; display = $upn; descriptor = $mDesc })
                }

                # Nested groups declared in config (e.g. Entra groups).
                foreach ($g in $groupEntries) {
                    $gName = [string]$g.group
                    $gDesc = Find-AdoGroupDescriptor -OrgUrl $OrgUrl -Project $project -Name $gName -ProjectGroups $liveGroups
                    if (-not $gDesc) {
                        $findings.Add("UNRESOLVABLE nested group '$gName' in '$($grp.ado)'")
                        & $rError "unresolvable nested group '$gName' in '$($grp.ado)'"
                        $unresolved = $true
                        continue
                    }
                    $desiredResolved.Add(@{ kind = 'group'; display = $gName; descriptor = $gDesc })
                }

                # Evaluate: exact-match membership. Extras are filtered to user
                # descriptors (aad./msa.) — nested Entra groups are never
                # touched — and suppressed while anything failed to resolve.
                $verdict = Test-GovernanceMemberSetCompliance -Desired @($desiredResolved) `
                    -Live $liveMembers -AnyUnresolved $unresolved -ExtraFilterPattern '^(aad|msa)\.'

                foreach ($m in $verdict.Missing) {
                    if ($m.kind -eq 'user') {
                        $upn = $m.display
                        if ($doFix) {
                            try {
                                Add-AdoGroupMember -OrgUrl $OrgUrl -MemberDescriptor $m.descriptor -ContainerDescriptor $descriptor
                                & $rCreated "member: $upn -> $($grp.ado)"
                            } catch {
                                $findings.Add("ERROR adding member '$upn' to '$($grp.ado)': $_")
                                & $rError "add member '$upn' to '$($grp.ado)': $_"
                            }
                        } else {
                            $findings.Add("MISSING member '$upn' in '$($grp.ado)'")
                            if ($Mode -eq 'WhatIf') { & $rWould "add member: $upn -> $($grp.ado)" }
                            else                     { & $rMissing "member: $upn in $($grp.ado)" }
                        }
                    } else {
                        $gName = $m.display
                        if ($doFix) {
                            try {
                                Add-AdoGroupMember -OrgUrl $OrgUrl -MemberDescriptor $m.descriptor -ContainerDescriptor $descriptor
                                & $rCreated "nested group: $gName -> $($grp.ado)"
                            } catch {
                                $findings.Add("ERROR adding nested group '$gName' to '$($grp.ado)': $_")
                                & $rError "add nested group '$gName' to '$($grp.ado)': $_"
                            }
                        } else {
                            $findings.Add("MISSING nested group '$gName' in '$($grp.ado)'")
                            if ($Mode -eq 'WhatIf') { & $rWould "add nested group: $gName -> $($grp.ado)" }
                            else                     { & $rMissing "nested group: $gName in $($grp.ado)" }
                        }
                    }
                }

                foreach ($xDesc in $verdict.Extras) {
                    $xName = Resolve-AdoMemberDisplay -OrgUrl $OrgUrl -Descriptor $xDesc
                    if ($Prune -and $doFix) {
                        try {
                            Remove-AdoGroupMember -OrgUrl $OrgUrl -MemberDescriptor $xDesc -ContainerDescriptor $descriptor
                            & $rDeleted "member: $xName <- $($grp.ado)"
                        } catch {
                            $findings.Add("ERROR removing extra member '$xName' from '$($grp.ado)': $_")
                            & $rError "remove member '$xName' from '$($grp.ado)': $_"
                        }
                    } else {
                        $findings.Add("DRIFT group '$($grp.ado)': extra member '$xName' not in config")
                        if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "remove member: $xName from $($grp.ado)" }
                        else                                { & $rDrift "group '$($grp.ado)': extra member '$xName'" }
                    }
                }
            } catch { & $rError "read members of '$($grp.ado)': $_" }
        }
    }

    # ── 6. Repos ───────────────────────────────────────────────────────────────
    Write-Host "`n--- Repos ---" -ForegroundColor Cyan

    $liveRepos = Get-AdoRepoSet -OrgUrl $OrgUrl -Project $project
    foreach ($repo in @($Resolved.repos | Where-Object { $_ })) {
        if ($liveRepos.ContainsKey($repo.name)) {
            & $rOk "repo: $($repo.name)"
        } else {
            if ($doFix) {
                try {
                    New-AdoRepo -OrgUrl $OrgUrl -Project $project -Name $repo.name
                    & $rCreated "repo: $($repo.name)"
                } catch {
                    $findings.Add("ERROR creating repo '$($repo.name)': $_")
                    & $rError "create repo '$($repo.name)': $_"
                }
            } else {
                $findings.Add("MISSING repo: $($repo.name)")
                if ($Mode -eq 'WhatIf') { & $rWould "create repo: $($repo.name)" }
                else                     { & $rMissing "repo: $($repo.name)" }
            }
        }
    }

    # Orphan repos: exist in ADO but not in the resolved model. The project
    # default repo (named after the project) is exempt. Pruning soft-deletes
    # to the recycle bin (~30 days recoverable).
    $orphanRepos = (Test-GovernanceRepoCompliance `
        -DesiredNames @($Resolved.repos | Where-Object { $_ } | ForEach-Object { $_.name }) `
        -LiveNames @($liveRepos.Keys) -Project $project).Orphans
    foreach ($liveRepoName in $orphanRepos) {
        if ($Prune -and $doFix) {
            try {
                Remove-AdoRepo -OrgUrl $OrgUrl -Project $project -RepoId $liveRepos[$liveRepoName]
                & $rDeleted "repo: $liveRepoName"
            } catch {
                $findings.Add("ERROR deleting orphan repo '$liveRepoName': $_")
                & $rError "delete repo '$liveRepoName': $_"
            }
        } else {
            $findings.Add("AUDIT EXCEPTION repo: $liveRepoName")
            if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "delete orphan repo: $liveRepoName" }
            else                                { & $rOrphan "repo: $liveRepoName" }
        }
    }

    # ── 6b. Repo ACLs ──────────────────────────────────────────────────────────
    # Everyone in the project reads; only the owning team's group writes;
    # innerOSS additionally opens branch creation + PR contribution to everyone.
    $projectId     = $null   # lazy-loaded once for ACL security token construction
    $identityCache = @{}     # subjectDescriptor -> securityIdentityDescriptor

    foreach ($repo in @($Resolved.repos | Where-Object { $_ -and $_.acl })) {
        if (-not $liveRepos.ContainsKey($repo.name)) {
            # Just-created repos need a fresh id lookup; refresh once.
            $liveRepos = Get-AdoRepoSet -OrgUrl $OrgUrl -Project $project
            if (-not $liveRepos.ContainsKey($repo.name)) { continue }   # creation failed — already reported
        }
        if (-not $projectId) {
            $projectId = Get-AdoProjectId -OrgUrl $OrgUrl -Project $project
            if (-not $projectId) {
                & $rError "could not resolve project ID — skipping repo ACL checks"
                break
            }
        }
        try {
            $liveAcl  = Get-AdoRepoAcl -OrgUrl $OrgUrl -ProjectId $projectId -RepoId $liveRepos[$repo.name]
            $aclDrift = [System.Collections.Generic.List[object]]::new()

            foreach ($ace in @($repo.acl | Where-Object { $_ })) {
                # 'project-valid-users' = the built-in everyone group.
                $groupName   = if ($ace.principal -eq 'project-valid-users') { 'Project Valid Users' } else { $ace.principal }
                $subjectDesc = $liveGroups[$groupName]
                if (-not $subjectDesc) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT repo '$($repo.name)': group '$groupName' not found in ADO"
                        identityDesc = $null; desiredBits = 0 })
                    continue
                }
                if (-not $identityCache.ContainsKey($subjectDesc)) {
                    $identityCache[$subjectDesc] = Get-AdoGroupIdentityDescriptor `
                        -OrgUrl $OrgUrl -SubjectDescriptor $subjectDesc
                }
                $identityDesc = $identityCache[$subjectDesc]
                if (-not $identityDesc) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT repo '$($repo.name)': cannot resolve security identity for '$groupName'"
                        identityDesc = $null; desiredBits = 0 })
                    continue
                }
                $desiredBits = ConvertTo-RepoPermissionBit -Permission $ace.permission
                $actualBits  = if ($liveAcl.ContainsKey($identityDesc)) { [int]$liveAcl[$identityDesc] } else { 0 }
                if (($actualBits -band $desiredBits) -ne $desiredBits) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT repo '$($repo.name)': '$groupName' ($($ace.permission)) has allow=$actualBits, need bits $desiredBits"
                        identityDesc = $identityDesc
                        desiredBits  = $desiredBits })
                }
            }

            if ($aclDrift.Count -eq 0) {
                & $rOk "repo ACL: $($repo.name)"
            } elseif ($doFix) {
                $fixFailed = $false
                foreach ($item in $aclDrift) {
                    if (-not $item.identityDesc) {
                        $findings.Add($item.message); & $rError $item.message; $fixFailed = $true; continue
                    }
                    try {
                        Set-AdoRepoAce -OrgUrl $OrgUrl -ProjectId $projectId -RepoId $liveRepos[$repo.name] `
                            -IdentityDescriptor $item.identityDesc -AllowBits $item.desiredBits
                    } catch {
                        $findings.Add("ERROR setting repo ACL on '$($repo.name)': $_")
                        & $rError "set repo ACL '$($repo.name)': $_"
                        $fixFailed = $true
                    }
                }
                if (-not $fixFailed) { & $rFixed "repo ACL: $($repo.name)" }
            } else {
                foreach ($item in $aclDrift) { $findings.Add($item.message) }
                if ($Mode -eq 'WhatIf') { & $rWould "correct repo ACL: $($repo.name)" }
                else                     { & $rDrift "repo ACL: $($repo.name)" }
            }
        } catch {
            & $rError "read repo ACL for '$($repo.name)': $_"
        }
    }

    # ── 7. Pipeline folders ────────────────────────────────────────────────────────
    Write-Host "`n--- Pipeline folders ---" -ForegroundColor Cyan

    $liveFolders   = Get-AdoPipelineFolderSet -OrgUrl $OrgUrl -Project $project

    foreach ($folder in @($Resolved.pipelineFolders | Where-Object { $_ })) {
        $folderExists = $liveFolders.ContainsKey($folder.path)

        if (-not $folderExists) {
            if ($doFix) {
                try {
                    New-AdoPipelineFolder -OrgUrl $OrgUrl -Project $project -Path $folder.path
                    & $rCreated "folder: $($folder.path)"
                    $folderExists = $true
                } catch {
                    $findings.Add("ERROR creating folder '$($folder.path)': $_")
                    & $rError "create folder '$($folder.path)': $_"
                }
            } else {
                $findings.Add("MISSING pipeline folder: $($folder.path)")
                if ($Mode -eq 'WhatIf') { & $rWould "create folder: $($folder.path)" }
                else                     { & $rMissing "folder: $($folder.path)" }
            }
        } else {
            & $rOk "folder: $($folder.path)"
        }

        # ── ACL check ─────────────────────────────────────────────────────────
        if (-not $folderExists) { continue }
        $desiredAcl = @($folder.acl | Where-Object { $_ })
        if ($desiredAcl.Count -eq 0) { continue }

        # Lazy-load the project ID needed to build the security token
        if (-not $projectId) {
            $projectId = Get-AdoProjectId -OrgUrl $OrgUrl -Project $project
            if (-not $projectId) {
                & $rError "could not resolve project ID — skipping ACL checks for pipeline folders"
                continue
            }
        }

        try {
            $liveAcl  = Get-AdoPipelineFolderAcl -OrgUrl $OrgUrl -ProjectId $projectId -FolderPath $folder.path
            $aclDrift = [System.Collections.Generic.List[object]]::new()

            foreach ($ace in $desiredAcl) {
                # Resolve the graph subject descriptor for this group name
                $subjectDesc = $liveGroups[$ace.group]
                if (-not $subjectDesc) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT pipeline folder '$($folder.path)': group '$($ace.group)' not found in ADO"
                        identityDesc = $null
                        desiredBits  = 0
                    })
                    continue
                }

                # Resolve (and cache) the security identity descriptor
                if (-not $identityCache.ContainsKey($subjectDesc)) {
                    $identityCache[$subjectDesc] = Get-AdoGroupIdentityDescriptor `
                        -OrgUrl $OrgUrl -SubjectDescriptor $subjectDesc
                }
                $identityDesc = $identityCache[$subjectDesc]
                if (-not $identityDesc) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT pipeline folder '$($folder.path)': cannot resolve security identity for '$($ace.group)'"
                        identityDesc = $null
                        desiredBits  = 0
                    })
                    continue
                }

                $desiredBits = ConvertTo-PipelinePermissionBit -Permission $ace.permission
                $actualBits  = if ($liveAcl.ContainsKey($identityDesc)) { [int]$liveAcl[$identityDesc] } else { 0 }
                if (($actualBits -band $desiredBits) -ne $desiredBits) {
                    $aclDrift.Add([ordered]@{
                        message      = "DRIFT pipeline folder '$($folder.path)': '$($ace.group)' has allow=$actualBits, need bits $desiredBits"
                        identityDesc = $identityDesc
                        desiredBits  = $desiredBits
                    })
                }
            }

            if ($aclDrift.Count -eq 0) {
                & $rOk "folder ACL: $($folder.path)"
            } elseif ($doFix) {
                $fixFailed = $false
                foreach ($item in $aclDrift) {
                    if (-not $item.identityDesc) {
                        # Unresolvable group — always a finding
                        $findings.Add($item.message)
                        & $rError $item.message
                        $fixFailed = $true
                        continue
                    }
                    try {
                        Set-AdoPipelineFolderAce -OrgUrl $OrgUrl -ProjectId $projectId `
                            -FolderPath $folder.path -IdentityDescriptor $item.identityDesc `
                            -AllowBits $item.desiredBits
                    } catch {
                        $findings.Add("ERROR setting ACL on '$($folder.path)' for identity '$($item.identityDesc)': $_")
                        & $rError "set ACL '$($folder.path)': $_"
                        $fixFailed = $true
                    }
                }
                if (-not $fixFailed) { & $rFixed "folder ACL: $($folder.path)" }
            } else {
                foreach ($item in $aclDrift) { $findings.Add($item.message) }
                if ($Mode -eq 'WhatIf') { & $rWould "correct folder ACL: $($folder.path)" }
                else                     { & $rDrift "folder ACL: $($folder.path)" }
            }
        } catch {
            & $rError "read ACL for '$($folder.path)': $_"
        }
    }

    # ── 4. Team iteration scope — runs after both teams and iteration paths exist ──
    # Exact-match: each team subscribes to precisely its in-scope window.
    # ROLLING MAINTENANCE, not compliance: the window is time-based and slides
    # daily, so keeping it current must not require an apply. Audit performs
    # the roll too (the scheduled audit keeps every team's window fresh) and
    # none of it is a finding — only real errors are. WhatIf stays dry.
    # The iteration PATHS themselves are never touched (ADR-005), only the
    # team's view of them.
    if ($Resolved.iterations -and $Resolved.iterations.config) {
        $doRoll = ($Mode -in @('Apply', 'Audit'))
        Write-Host "`n--- Team iteration scope ---" -ForegroundColor Cyan

        $itCfg   = $Resolved.iterations.config
        $progRoot = $Resolved.iterations.programRoot
        $calendar = Get-IterationCalendar -Cadence @{ iterations = $itCfg } -ProgramRoot $progRoot

        $tBack    = if ($itCfg.teamDefaults.sprints.back)         { [int]$itCfg.teamDefaults.sprints.back }         else { 10 }
        $tFwd     = if ($itCfg.teamDefaults.sprints.forward)      { [int]$itCfg.teamDefaults.sprints.forward }      else { 10 }
        $pBack    = if ($itCfg.portfolioDefaults.seasons.back)    { [int]$itCfg.portfolioDefaults.seasons.back }    else { 3 }
        $pFwd     = if ($itCfg.portfolioDefaults.seasons.forward) { [int]$itCfg.portfolioDefaults.seasons.forward } else { 3 }

        $iterIdCache = @{}
        # The root iteration subscription is set by Initialize-AdoTeamDefaults so
        # team settings PATCH calls succeed — it is never treated as an extra.
        $iterRootId  = $null
        try { $iterRootId = Get-AdoIterationRootId -OrgUrl $OrgUrl -Project $project }
        catch { & $rError "root iteration node: $_" }

        foreach ($team in ($Resolved.teams | Where-Object { $_.scope -ne 'future' -and $_.name -ne $project })) {
            # Team missing entirely — already flagged in the Teams section.
            if (-not $liveTeamNames.Contains($team.name)) { continue }

            # The team's backlog iteration must be the PROJECT ROOT — rolling
            # windows span execution years, and ADO hides every subscription
            # outside the backlog-iteration subtree. Part of the rolling
            # maintenance: corrected in apply AND audit, never a finding.
            if ($iterRootId) {
                try {
                    $currentRoot = Get-AdoTeamBacklogIterationId -OrgUrl $OrgUrl -Project $project -Team $team.name
                    if ($currentRoot -and $currentRoot -ne $iterRootId) {
                        if ($doRoll) {
                            Set-AdoTeamBacklogIteration -OrgUrl $OrgUrl -Project $project -Team $team.name -IterationId $iterRootId
                            & $rFixed "team: $($team.name)  backlog iteration -> project root"
                        } else {
                            & $rWould "set backlog iteration to project root for team: $($team.name)"
                        }
                    }
                } catch {
                    $findings.Add("ERROR checking backlog iteration for '$($team.name)': $_")
                    & $rError "backlog iteration '$($team.name)': $_"
                }
            }

            # iterationScope comes from the team's type (portfolio/structural ->
            # seasons, delivery -> sprints) or a per-node override; kind is the
            # fallback for resolved models built before team types existed.
            # 'none' means an empty desired window — everything but root is drift.
            $scope = if ($team.iterationScope) { [string]$team.iterationScope }
                     elseif ($team.kind -in @('portfolio', 'product')) { 'seasons' }
                     else { 'sprints' }
            $scopePaths = switch ($scope) {
                'none'    { @() }
                'seasons' { @(Get-InScopeSeasonPaths -Calendar $calendar -Back $pBack -Forward $pFwd) }
                default   { @(Get-InScopeSprintPaths -Calendar $calendar -Back $tBack -Forward $tFwd) }
            }

            $desiredIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($iterPath in $scopePaths) {
                $guid = if ($iterIdCache.ContainsKey($iterPath)) { $iterIdCache[$iterPath] }
                        else {
                            try { $id = Get-AdoIterationId -OrgUrl $OrgUrl -Project $project -ResolvedPath $iterPath
                                  $iterIdCache[$iterPath] = $id; $id
                            } catch { $null }   # path missing — already flagged in Iterations section
                        }
                if ($guid) { $desiredIds.Add($guid) | Out-Null }
            }

            try {
                $currentIds = Get-AdoTeamIterationSet -OrgUrl $OrgUrl -Project $project -Team $team.name
                $missingIds = @($desiredIds | Where-Object { -not $currentIds.ContainsKey($_) })
                $extraIds   = @($currentIds.Keys | Where-Object {
                    $_ -ne $iterRootId -and -not $desiredIds.Contains($_) })

                if ($missingIds.Count -eq 0 -and $extraIds.Count -eq 0) {
                    & $rOk "team: $($team.name)  (iteration scope current: $scope)"
                } elseif ($doRoll) {
                    foreach ($guid in $missingIds) {
                        Add-AdoTeamIteration -OrgUrl $OrgUrl -Project $project -Team $team.name -IterationId $guid
                    }
                    foreach ($guid in $extraIds) {
                        Remove-AdoTeamIteration -OrgUrl $OrgUrl -Project $project -Team $team.name -IterationId $guid
                    }
                    & $rFixed "team: $($team.name)  (rolled window +$($missingIds.Count)/-$($extraIds.Count) iteration subscription(s))"
                } else {
                    # WhatIf: dry run — report, never a finding (rolling maintenance).
                    & $rWould "roll iteration window for team: $($team.name) (+$($missingIds.Count)/-$($extraIds.Count))"
                }
            } catch {
                $findings.Add("ERROR reconciling iteration scope for '$($team.name)': $_")
                & $rError "iteration scope for '$($team.name)': $_"
            }
        }
    }

    # ── 5. Team backlog levels ────────────────────────────────────────────────
    # Each team's visible backlog levels must match its type exactly (e.g.
    # delivery teams see Requirements + Stories, portfolio teams Initiatives).
    # Wrong visibility in either direction is drift.
    $backlogTeams = @($desiredTeams | Where-Object { $_.backlogs })
    if ($backlogTeams.Count -gt 0) {
        Write-Host "`n--- Team backlog levels ---" -ForegroundColor Cyan

        foreach ($team in $backlogTeams) {
            # Team missing entirely — already flagged in the Teams section.
            if (-not $liveTeamNames.Contains($team.name)) { continue }
            try {
                $levels = @(Get-AdoTeamBacklogLevels -OrgUrl $OrgUrl -Project $project -Team $team.name)
                $live   = Get-AdoTeamBacklogVisibilities -OrgUrl $OrgUrl -Project $project -Team $team.name

                $levelNames = @($levels | ForEach-Object { $_.name })
                foreach ($name in @($team.backlogs)) {
                    if ($name -notin $levelNames) {
                        $findings.Add("DRIFT team '$($team.name)': configured backlog level '$name' does not exist in the process (levels: $($levelNames -join ', '))")
                        & $rError "team '$($team.name)': backlog level '$name' not in process"
                    }
                }

                # If NO configured level exists in this process, reconciling
                # visibility would hide every level — wrong, and rejected by
                # ADO (VS402489). The findings above are the real problem: the
                # config names must match the process before visibility can
                # be enforced.
                if (@($team.backlogs | Where-Object { $_ -in $levelNames }).Count -eq 0) { continue }

                $desiredVis = @{}
                $driftItems = [System.Collections.Generic.List[string]]::new()
                foreach ($lvl in $levels) {
                    $want = $lvl.name -in @($team.backlogs)
                    $desiredVis[$lvl.id] = $want
                    $have = if ($live.ContainsKey($lvl.id)) { [bool]$live[$lvl.id] } else { $null }
                    if ($have -ne $want) {
                        $haveDesc = if ($null -eq $have) { 'unknown' } elseif ($have) { 'visible' } else { 'hidden' }
                        $wantDesc = if ($want) { 'visible' } else { 'hidden' }
                        $driftItems.Add("DRIFT team '$($team.name)': backlog '$($lvl.name)' should be $wantDesc but is $haveDesc")
                    }
                }

                if ($driftItems.Count -eq 0) {
                    & $rOk "team: $($team.name)  (backlog levels)"
                } elseif ($doFix) {
                    try {
                        Set-AdoTeamBacklogVisibilities -OrgUrl $OrgUrl -Project $project `
                            -Team $team.name -Visibilities $desiredVis
                        & $rFixed "team: $($team.name)  backlog levels"
                    } catch {
                        # ADO REST errors carry a JSON body; surface just the
                        # message, not the whole serialized exception object.
                        $msg = "$_"
                        try { $msg = ("$_" | ConvertFrom-Json).message } catch {}
                        foreach ($d in $driftItems) { $findings.Add($d) }
                        $findings.Add("ERROR setting backlog levels for '$($team.name)': $msg")
                        & $rError "set backlog levels '$($team.name)': $msg"
                    }
                } else {
                    foreach ($d in $driftItems) { $findings.Add($d) }
                    if ($Mode -eq 'WhatIf') { & $rWould "correct backlog levels for team: $($team.name)" }
                    else                     { & $rDrift "team: $($team.name)  backlog levels wrong" }
                }
            } catch {
                $findings.Add("ERROR reading backlog levels for '$($team.name)': $_")
                & $rError "read backlog levels for '$($team.name)': $_"
            }
        }
    }

    # ── 5c. Team administrators ───────────────────────────────────────────────
    # members/<code>.yaml `teamAdmins:` governs the ADO Team Administrator role
    # exactly: empty (or absent) list = the team must have NO administrators.
    # Missing and extra admins are both findings; apply corrects both.
    Write-Host "`n--- Team administrators ---" -ForegroundColor Cyan
    foreach ($team in @($Resolved.teams | Where-Object { $_.scope -ne 'future' })) {
        if (-not $liveTeamNames.Contains($team.name)) { continue }
        $teamId = $liveTeams[$team.name]
        if (-not $teamId) { continue }
        if (-not $projectId) {
            $projectId = Get-AdoProjectId -OrgUrl $OrgUrl -Project $project
            if (-not $projectId) { & $rError "could not resolve project ID — skipping team administrator checks"; break }
        }
        try {
            # Gather: resolve each entry (upn or governance group) to a
            # security identity descriptor.
            $desiredAdmins = [System.Collections.Generic.List[object]]::new()
            $unresolvedAdmin = $false
            foreach ($m in @($team.teamAdmins | Where-Object { $_ })) {
                $subjectDesc = $null
                $display     = $null
                if ($m.upn) {
                    $display     = [string]$m.upn
                    $subjectDesc = Find-AdoUserDescriptor -OrgUrl $OrgUrl -Upn $display
                    if (-not $subjectDesc) {
                        $near = @(Find-AdoUserSuggestion -OrgUrl $OrgUrl -Upn $display)
                        $why  = if ($near.Count -gt 0) { "no org member has this exact UPN - did you mean: $($near -join ', ')?" }
                                else { "no org member matches this UPN" }
                        $findings.Add("UNRESOLVABLE team admin '$display' for '$($team.name)': $why")
                        & $rError "unresolvable team admin '$display' for '$($team.name)': $why"
                        $unresolvedAdmin = $true
                        continue
                    }
                } elseif ($m.group) {
                    $display     = [string]$m.group
                    $subjectDesc = $liveGroups[$display]
                    if (-not $subjectDesc) {
                        $findings.Add("UNRESOLVABLE team admin group '$display' for '$($team.name)': no such group in ADO")
                        & $rError "unresolvable team admin group '$display' for '$($team.name)'"
                        $unresolvedAdmin = $true
                        continue
                    }
                } else { continue }
                if (-not $identityCache.ContainsKey($subjectDesc)) {
                    $identityCache[$subjectDesc] = Get-AdoGroupIdentityDescriptor -OrgUrl $OrgUrl -SubjectDescriptor $subjectDesc
                }
                if ($identityCache[$subjectDesc]) { $desiredAdmins.Add(@{ descriptor = $identityCache[$subjectDesc]; display = $display }) }
                else {
                    $findings.Add("UNRESOLVABLE team admin '$display' for '$($team.name)': cannot resolve security identity")
                    & $rError "unresolvable team admin '$display' for '$($team.name)': cannot resolve security identity"
                    $unresolvedAdmin = $true
                }
            }

            # Evaluate: exact-match role membership. The evaluator never
            # reports extras while any desired entry failed to resolve — a
            # typo must not strip a team of every administrator.
            $liveAdmins = Get-AdoTeamAdminSet -OrgUrl $OrgUrl -ProjectId $projectId -TeamId $teamId
            $adminVerdict = Test-GovernanceMemberSetCompliance -Desired @($desiredAdmins) `
                -Live $liveAdmins -AnyUnresolved $unresolvedAdmin
            $missing = @($adminVerdict.Missing)
            $extra   = @($adminVerdict.Extras)

            if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
                & $rOk "team admins: $($team.name)  ($($desiredAdmins.Count) admin(s))"
            } elseif ($doFix) {
                foreach ($d in $missing) {
                    try {
                        Add-AdoTeamAdmin -OrgUrl $OrgUrl -ProjectId $projectId -TeamId $teamId -IdentityDescriptor $d.descriptor
                        & $rCreated "team admin: $($d.display) -> $($team.name)"
                    } catch {
                        $findings.Add("ERROR adding team admin '$($d.display)' to '$($team.name)': $_")
                        & $rError "add team admin '$($d.display)' to '$($team.name)': $_"
                    }
                }
                foreach ($d in $extra) {
                    $xName = Resolve-AdoMemberDisplay -OrgUrl $OrgUrl -Descriptor $d
                    try {
                        Remove-AdoTeamAdmin -OrgUrl $OrgUrl -ProjectId $projectId -TeamId $teamId -IdentityDescriptor $d
                        & $rDeleted "team admin: $xName <- $($team.name)"
                    } catch {
                        $findings.Add("ERROR removing extra team admin '$xName' from '$($team.name)': $_")
                        & $rError "remove team admin '$xName' from '$($team.name)': $_"
                    }
                }
            } else {
                foreach ($d in $missing) { $findings.Add("MISSING team admin '$($d.display)' on '$($team.name)'") }
                foreach ($d in $extra)   { $findings.Add("DRIFT team '$($team.name)': extra team admin not in config") }
                if ($Mode -eq 'WhatIf') { & $rWould "correct team admins for: $($team.name) (+$($missing.Count)/-$($extra.Count))" }
                else                     { & $rDrift "team admins: $($team.name)  (+$($missing.Count)/-$($extra.Count))" }
            }
        } catch {
            $findings.Add("ERROR reconciling team admins for '$($team.name)': $_")
            & $rError "team admins for '$($team.name)': $_"
        }
    }

    # ── 6. Structural authority (area node ACLs) ──────────────────────────────
    # Each {key}-Admins group must hold node-admin bits (read/write/delete) on
    # every area path its team governs (Decision-0028 delegated ownership).
    $authorityEntries = @($Resolved.structuralAuthority | Where-Object { $_ })
    if ($authorityEntries.Count -gt 0) {
        Write-Host "`n--- Structural authority ---" -ForegroundColor Cyan

        $authIdentity = @{}   # subjectDescriptor -> securityIdentityDescriptor
        $authTokens   = @{}   # area path -> CSS token
        foreach ($entry in $authorityEntries) {
            $subjectDesc = $liveGroups[$entry.group]
            if (-not $subjectDesc) { continue }   # group missing — flagged in the groups section

            if (-not $authIdentity.ContainsKey($subjectDesc)) {
                $authIdentity[$subjectDesc] = Get-AdoGroupIdentityDescriptor -OrgUrl $OrgUrl -SubjectDescriptor $subjectDesc
            }
            $identityDesc = $authIdentity[$subjectDesc]
            if (-not $identityDesc) {
                $findings.Add("DRIFT structural authority: cannot resolve security identity for '$($entry.group)'")
                & $rError "structural authority: identity for '$($entry.group)'"
                continue
            }

            foreach ($path in @($entry.paths)) {
                if (-not $liveAreas.ContainsKey($path)) { continue }   # area missing — already flagged
                try {
                    if (-not $authTokens.ContainsKey($path)) {
                        $authTokens[$path] = Get-AdoAreaNodeToken -OrgUrl $OrgUrl -Project $project -ResolvedPath $path
                    }
                    $token  = $authTokens[$path]
                    $acl    = Get-AdoAreaNodeAcl -OrgUrl $OrgUrl -Token $token
                    $actual = if ($acl.ContainsKey($identityDesc)) { [int]$acl[$identityDesc] } else { 0 }
                    if (($actual -band $script:AreaNodeAdminBits) -eq $script:AreaNodeAdminBits) {
                        & $rOk "authority: $($entry.group) on $path"
                    } elseif ($doFix) {
                        try {
                            Set-AdoAreaNodeAce -OrgUrl $OrgUrl -Token $token `
                                -IdentityDescriptor $identityDesc -AllowBits $script:AreaNodeAdminBits
                            & $rFixed "authority: $($entry.group) on $path"
                        } catch {
                            $findings.Add("ERROR granting structural authority to '$($entry.group)' on '$path': $_")
                            & $rError "grant authority '$($entry.group)' on '$path': $_"
                        }
                    } else {
                        $findings.Add("DRIFT structural authority: '$($entry.group)' lacks node-admin rights on '$path' (allow=$actual, need $script:AreaNodeAdminBits)")
                        if ($Mode -eq 'WhatIf') { & $rWould "grant node-admin to $($entry.group) on $path" }
                        else                     { & $rDrift "authority: $($entry.group) on $path" }
                    }
                } catch {
                    $findings.Add("ERROR reading node ACL for '$path': $_")
                    & $rError "node ACL for '$path': $_"
                }
            }
        }
    }

    # ── 7. Tags — governed taxonomy (Decision-0041, ADR-006) ──────────────────
    # Disallowed patterns (build-id shaped) are ALWAYS drift; tags outside the
    # sanctioned vocabulary are audit exceptions; sanctioned tags that do not
    # exist are MISSING. ADO has no create-tag API and purges tags no work item
    # references, so apply makes a sanctioned tag exist the only way ADO allows:
    # by holding the whole vocabulary on one governed anchor work item.
    if ($Resolved.tags) {
        Write-Host "`n--- Tags ---" -ForegroundColor Cyan
        try {
            $liveTags   = Get-AdoTagSet -OrgUrl $OrgUrl -Project $project
            $sanctionedList = @($Resolved.tags.sanctioned)
            $patterns       = @($Resolved.tags.disallowedPatterns)

            # ── 7a. Anchor: make the sanctioned vocabulary exist ──────────────
            # A resolved.yaml built before ADR-006 has no anchor block; treat that
            # as disabled rather than writing a work item off a stale model.
            $anchor  = $Resolved.tags.anchor
            $seeding = ($anchor -and $anchor.enabled -and $sanctionedList.Count -gt 0)
            $missing = (Test-GovernanceTagCompliance -Sanctioned $sanctionedList -LiveTagNames @($liveTags.Keys)).Missing

            if ($seeding -and ($missing.Count -gt 0 -or $doFix)) {
                if ($doFix) {
                    try {
                        $wiTypes = Get-AdoWorkItemTypeName -OrgUrl $OrgUrl -Project $project
                        if ($anchor.workItemType -notin $wiTypes) {
                            throw ("work item type '$($anchor.workItemType)' does not exist in '$project'. " +
                                   "Set taxonomy.yaml tags.anchor.workItemType to one of: $($wiTypes -join ', ')")
                        }
                        $anchorId = Find-AdoTagAnchor -OrgUrl $OrgUrl -Project $project -Title $anchor.title
                        if (-not $anchorId) {
                            $anchorId = New-AdoTagAnchor -OrgUrl $OrgUrl -Project $project `
                                -Title $anchor.title -WorkItemType $anchor.workItemType `
                                -Tags $sanctionedList -AreaPath $anchor.areaPath -State $anchor.state
                            & $rCreated "tag anchor: work item #$anchorId"
                            foreach ($t in ($missing | Sort-Object)) { & $rCreated "tag: $t  [seeded]" }
                        } else {
                            # Corrective (ADR-003): the anchor must carry exactly the
                            # sanctioned set — no more (extras would read as orphan
                            # tags), no less (gaps would read as missing tags).
                            # HashSet, not Compare-Object: Compare-Object rejects an
                            # empty -ReferenceObject, and an anchor stripped of its
                            # tags is exactly the case that most needs correcting.
                            $onAnchor = [System.Collections.Generic.HashSet[string]]::new(
                                [string[]]@(Get-AdoWorkItemTag -OrgUrl $OrgUrl -Project $project -Id $anchorId),
                                [System.StringComparer]::OrdinalIgnoreCase)
                            if (-not $onAnchor.SetEquals([string[]]$sanctionedList)) {
                                Set-AdoTagAnchorTag -OrgUrl $OrgUrl -Project $project -Id $anchorId -Tags $sanctionedList
                                & $rFixed "tag anchor: work item #$anchorId"
                                foreach ($t in ($missing | Sort-Object)) { & $rCreated "tag: $t  [seeded]" }
                            } else {
                                & $rOk "tag anchor: work item #$anchorId"
                            }
                        }
                        # Re-read: seeding changed the live vocabulary.
                        $liveTags = Get-AdoTagSet -OrgUrl $OrgUrl -Project $project
                        $missing  = (Test-GovernanceTagCompliance -Sanctioned $sanctionedList -LiveTagNames @($liveTags.Keys)).Missing
                        foreach ($t in ($missing | Sort-Object)) {
                            $findings.Add("MISSING tag: $t (still absent after seeding the anchor work item)")
                            & $rMissing "tag: $t"
                        }
                    } catch {
                        $findings.Add("ERROR seeding tag anchor: $_")
                        & $rError "seed tag anchor: $_"
                    }
                } else {
                    foreach ($t in ($missing | Sort-Object)) {
                        $findings.Add("MISSING tag: $t (sanctioned but not in use)")
                        if ($Mode -eq 'WhatIf') { & $rWould "seed tag: $t (via anchor work item)" }
                        else                     { & $rMissing "tag: $t (sanctioned but not in use)" }
                    }
                }
            } elseif ($missing.Count -gt 0) {
                # Seeding disabled: report, and say plainly that apply cannot fix it.
                $why = if ($anchor) { 'tags.anchor.enabled is false' } else { 'resolved.yaml predates the tag anchor — rebuild' }
                foreach ($t in ($missing | Sort-Object)) {
                    $findings.Add("MISSING tag: $t (sanctioned but not in use; apply cannot create it — $why)")
                    & $rMissing "tag: $t (sanctioned but not in use)"
                }
            }

            $tagVerdict = Test-GovernanceTagCompliance -Sanctioned $sanctionedList `
                -DisallowedPatterns $patterns -LiveTagNames @($liveTags.Keys)

            foreach ($tagName in $tagVerdict.Disallowed) {
                if ($Prune -and $doFix) {
                    try {
                        Remove-AdoTag -OrgUrl $OrgUrl -Project $project -TagId $liveTags[$tagName]
                        & $rDeleted "tag: $tagName"
                    } catch {
                        $findings.Add("ERROR deleting disallowed tag '$tagName': $_")
                        & $rError "delete tag '$tagName': $_"
                    }
                } else {
                    $findings.Add("DRIFT tag '$tagName': matches a disallowed pattern")
                    if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "delete disallowed tag: $tagName" }
                    else                                { & $rDrift "tag: $tagName (disallowed pattern)" }
                }
            }
            foreach ($tagName in $tagVerdict.Unsanctioned) {
                if ($Prune -and $doFix) {
                    try {
                        Remove-AdoTag -OrgUrl $OrgUrl -Project $project -TagId $liveTags[$tagName]
                        & $rDeleted "tag: $tagName"
                    } catch {
                        $findings.Add("ERROR deleting unsanctioned tag '$tagName': $_")
                        & $rError "delete tag '$tagName': $_"
                    }
                } else {
                    $findings.Add("AUDIT EXCEPTION tag: $tagName")
                    if ($Prune -and $Mode -eq 'WhatIf') { & $rWould "delete unsanctioned tag: $tagName" }
                    else                                { & $rOrphan "tag: $tagName" }
                }
            }
            $okCount = $tagVerdict.OkCount
            Write-Host "  [ok]      $okCount sanctioned tag(s) in use ($($liveTags.Count) live total)" -ForegroundColor Green
        } catch {
            # A read failure means the taxonomy was never checked — that must be a
            # finding, not just a console line, or the run reports a false green.
            $findings.Add("ERROR reading tags: $_")
            & $rError "read tags: $_"
        }
    }

    # ── Findings summary + report files (shared with preflight) ───────────────
    $suffix = Write-GovernanceReport -Findings $findings.ToArray() -ProgramName $Resolved.program `
        -Project $project -OrgUrl $OrgUrl -Mode $Mode -ReportPath $ReportPath

    if ($findings.Count -gt 0 -and $Mode -eq 'Audit') {
        Write-Error "Governance compliance: $($findings.Count) finding(s) $suffix."
    }

    return $findings.ToArray()
}

function Resolve-GovernanceErrorReason {
    <#
        .SYNOPSIS
        Maps an ERROR/UNRESOLVABLE finding to its known root cause, so the
        summary can print "here is WHY" instead of a bare failure. Returns
        $null for signatures not yet diagnosed — when you diagnose a new one,
        add its pattern here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Finding)

    if ($Finding -match '401|Unauthorized|requires user authentication') {
        if ($Finding -match 'ACL|structural authority') {
            return "no usable credential can WRITE security ACLs. vso.security_manage is not selectable in the PAT UI; 'az login' enables the Entra route - but if the org rejects Entra tokens (forced sign-out), Conditional Access is blocking this device: use an org-managed device or VPN. Verify with 'doctor'."
        }
        return "the PAT is missing a scope for this resource family - run 'doctor' to identify which."
    }
    if ($Finding -match 'did you mean:') {
        return "the configured UPN does not exist in the org, but a near-match does - fix the UPN in members/<code>.yaml."
    }
    if ($Finding -like 'UNRESOLVABLE member*') {
        return "no org member matches this UPN - the user must be added to the Azure DevOps org before governance can grant access."
    }
    if ($Finding -like 'UNRESOLVABLE nested group*') {
        return "no ADO group with this name exists in the project - an Entra group must be surfaced in ADO (added to any group once) before it can be nested by governance."
    }
    if ($Finding -match 'does not exist in the process' -or $Finding -match 'not in process') {
        return "cadence.yaml teamTypes backlogs must use THIS process's backlog level names - the finding lists the valid names."
    }
    if ($Finding -match 'VS402489') {
        return "none of the configured backlog levels exist in the process, so reconcile would hide every level and ADO refuses - fix the names in cadence.yaml."
    }
    if ($Finding -match 'controller for path|does not implement IController') {
        return "the REST call went to the wrong service host - this is an engine bug in host routing (Resolve-AdoRequestUri); report it."
    }
    return $null
}
