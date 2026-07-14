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
    $project  = $Resolved.program
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
        $modelPaths = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($Resolved.areaPaths | ForEach-Object { $_.path }),
            [System.StringComparer]::OrdinalIgnoreCase)
        $bulkAreas = Get-AdoAreaPathSubtree -OrgUrl $OrgUrl -Project $project
        if ($bulkAreas.Count -gt 1) {
            # Deepest-first so pruning a subtree removes children before parents.
            $orphanAreas = @($bulkAreas.Keys | Where-Object { -not $modelPaths.Contains($_) } |
                Sort-Object { ($_ -split '\\').Count } -Descending)
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
            $members = @($grp.members | Where-Object { $_ -match '@' })
            if ($members.Count -eq 0) { continue }

            $descriptor = $liveGroups[$grp.ado]
            if (-not $descriptor) { continue }

            try {
                $liveMembers  = Get-AdoGroupMemberSet -OrgUrl $OrgUrl -Descriptor $descriptor
                $desiredDescs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $unresolved   = $false

                foreach ($m in $members) {
                    $mDesc = Find-AdoUserDescriptor -OrgUrl $OrgUrl -Upn $m
                    if (-not $mDesc) {
                        $findings.Add("UNRESOLVABLE member '$m' in '$($grp.ado)'")
                        & $rError "unresolvable user '$m' in '$($grp.ado)'"
                        $unresolved = $true
                        continue
                    }
                    $desiredDescs.Add($mDesc) | Out-Null
                    if (-not $liveMembers.ContainsKey($mDesc)) {
                        if ($doFix) {
                            try {
                                Add-AdoGroupMember -OrgUrl $OrgUrl -MemberDescriptor $mDesc -ContainerDescriptor $descriptor
                                & $rCreated "member: $m -> $($grp.ado)"
                            } catch {
                                $findings.Add("ERROR adding member '$m' to '$($grp.ado)': $_")
                                & $rError "add member '$m' to '$($grp.ado)': $_"
                            }
                        } else {
                            $findings.Add("MISSING member '$m' in '$($grp.ado)'")
                            if ($Mode -eq 'WhatIf') { & $rWould "add member: $m -> $($grp.ado)" }
                            else                     { & $rMissing "member: $m in $($grp.ado)" }
                        }
                    }
                }

                # Extra members: user descriptors (aad./msa.) in the live group but
                # not in config. Nested groups are never touched — access.yaml allows
                # Entra groups to be nested and they can't be matched to the UPN list.
                # Skipped entirely if any desired member failed to resolve, because
                # an unresolved desired member is indistinguishable from an extra.
                if (-not $unresolved) {
                    $extras = @($liveMembers.Keys | Where-Object {
                        $_ -match '^(aad|msa)\.' -and -not $desiredDescs.Contains($_) })
                    foreach ($xDesc in $extras) {
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
    $desiredRepoNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($Resolved.repos | Where-Object { $_ } | ForEach-Object { $_.name }) + @($project)),
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($liveRepoName in ($liveRepos.Keys | Sort-Object)) {
        if (-not $desiredRepoNames.Contains($liveRepoName)) {
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
    }

    # ── 7. Pipeline folders ────────────────────────────────────────────────────────
    Write-Host "`n--- Pipeline folders ---" -ForegroundColor Cyan

    $liveFolders   = Get-AdoPipelineFolderSet -OrgUrl $OrgUrl -Project $project
    $projectId     = $null   # lazy-loaded once for ACL security token construction
    $identityCache = @{}     # subjectDescriptor -> securityIdentityDescriptor

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
    if ($Resolved.iterations -and $Resolved.iterations.config -and $doFix) {
        Write-Host "`n--- Team iteration scope ---" -ForegroundColor Cyan

        $itCfg   = $Resolved.iterations.config
        $progRoot = $Resolved.iterations.programRoot
        $calendar = Get-IterationCalendar -Cadence @{ iterations = $itCfg } -ProgramRoot $progRoot

        $tBack    = if ($itCfg.teamDefaults.sprints.back)         { [int]$itCfg.teamDefaults.sprints.back }         else { 10 }
        $tFwd     = if ($itCfg.teamDefaults.sprints.forward)      { [int]$itCfg.teamDefaults.sprints.forward }      else { 10 }
        $pBack    = if ($itCfg.portfolioDefaults.seasons.back)    { [int]$itCfg.portfolioDefaults.seasons.back }    else { 3 }
        $pFwd     = if ($itCfg.portfolioDefaults.seasons.forward) { [int]$itCfg.portfolioDefaults.seasons.forward } else { 3 }

        $iterIdCache = @{}

        foreach ($team in ($Resolved.teams | Where-Object { $_.scope -ne 'future' -and $_.name -ne $project })) {
            # iterationScope comes from the team's type (portfolio/structural ->
            # seasons, delivery -> sprints) or a per-node override; kind is the
            # fallback for resolved models built before team types existed.
            $scope = if ($team.iterationScope) { [string]$team.iterationScope }
                     elseif ($team.kind -in @('portfolio', 'product')) { 'seasons' }
                     else { 'sprints' }
            if ($scope -eq 'none') {
                & $rOk "team: $($team.name)  (iteration scope: none)"
                continue
            }
            $scopePaths = if ($scope -eq 'seasons') {
                Get-InScopeSeasonPaths -Calendar $calendar -Back $pBack -Forward $pFwd
            } else {
                Get-InScopeSprintPaths -Calendar $calendar -Back $tBack -Forward $tFwd
            }
            if ($scopePaths.Count -eq 0) { continue }

            try {
                $currentIds = Get-AdoTeamIterationSet -OrgUrl $OrgUrl -Project $project -Team $team.name
                $added = 0
                foreach ($iterPath in $scopePaths) {
                    $guid = if ($iterIdCache.ContainsKey($iterPath)) { $iterIdCache[$iterPath] }
                            else {
                                try { $id = Get-AdoIterationId -OrgUrl $OrgUrl -Project $project -ResolvedPath $iterPath
                                      $iterIdCache[$iterPath] = $id; $id
                                } catch { $null }
                            }
                    if (-not $guid) { continue }
                    if (-not $currentIds.ContainsKey($guid)) {
                        Add-AdoTeamIteration -OrgUrl $OrgUrl -Project $project -Team $team.name -IterationId $guid
                        $added++
                    }
                }
                if ($added -gt 0) { & $rFixed "team: $($team.name)  ($added iteration(s) added to scope)" }
                else               { & $rOk    "team: $($team.name)  (iteration scope current)" }
            } catch {
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
                        foreach ($d in $driftItems) { $findings.Add($d) }
                        $findings.Add("ERROR setting backlog levels for '$($team.name)': $_")
                        & $rError "set backlog levels '$($team.name)': $_"
                    }
                } else {
                    foreach ($d in $driftItems) { $findings.Add($d) }
                    if ($Mode -eq 'WhatIf') { & $rWould "correct backlog levels for team: $($team.name)" }
                    else                     { & $rDrift "team: $($team.name)  backlog levels wrong" }
                }
            } catch { & $rError "read backlog levels for '$($team.name)': $_" }
        }
    }

    # ── Findings summary ──────────────────────────────────────────────────────
    $exceptions = @($findings | Where-Object { $_ -like 'AUDIT EXCEPTION*' })
    $missing    = @($findings | Where-Object { $_ -like 'MISSING*' })
    $drift      = @($findings | Where-Object { $_ -notlike 'AUDIT EXCEPTION*' -and $_ -notlike 'MISSING*' })

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
        if ($missing.Count -gt 0) {
            Write-Host "`n  Missing ($($missing.Count)):" -ForegroundColor Red
            $missing | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
        }
        if ($drift.Count -gt 0) {
            Write-Host "`n  Drift ($($drift.Count)):" -ForegroundColor Red
            $drift | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
        }
        if ($exceptions.Count -gt 0) {
            Write-Host "`n  Audit exceptions — exist in ADO but not in config ($($exceptions.Count)):" -ForegroundColor Magenta
            $exceptions | ForEach-Object { Write-Host "    * $_" -ForegroundColor Magenta }
        }
    }

    # ── Write report file ─────────────────────────────────────────────────────
    if ($ReportPath) {
        $reportDir = Split-Path $ReportPath -Parent
        if ($reportDir -and -not (Test-Path $reportDir)) {
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Governance audit report")
        $lines.Add("Program  : $project")
        $lines.Add("Org      : $OrgUrl")
        $lines.Add("Mode     : $Mode")
        $lines.Add("Generated: $(Get-Date -Format 'o')")
        $lines.Add("Findings : $($findings.Count)")
        $lines.Add('')
        foreach ($section in @(
            @{ label = 'MISSING'; items = $missing },
            @{ label = 'DRIFT';   items = $drift },
            @{ label = 'AUDIT EXCEPTIONS (exist in ADO but not in config)'; items = $exceptions }
        )) {
            if ($section.items.Count -eq 0) { continue }
            $lines.Add("$($section.label) ($($section.items.Count)):")
            $section.items | ForEach-Object { $lines.Add("  - $_") }
            $lines.Add('')
        }
        if ($findings.Count -eq 0) { $lines.Add('COMPLIANT') } else { $lines.Add('NON-COMPLIANT') }
        Set-Content -Path $ReportPath -Value $lines -Encoding utf8
        Write-Host "`nReport written to: $ReportPath" -ForegroundColor Cyan
    }

    if ($findings.Count -gt 0 -and $Mode -eq 'Audit') {
        Write-Error "Governance compliance: $($findings.Count) finding(s) $suffix."
    }

    return $findings.ToArray()
}
