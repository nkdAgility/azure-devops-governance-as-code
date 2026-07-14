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

        Returns a string array of remaining findings. Empty = fully compliant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Resolved,
        [Parameter(Mandatory)][string]$OrgUrl,
        [ValidateSet('Audit', 'Apply', 'WhatIf')]
        [string]$Mode = 'Audit',
        [string]$ReportPath = '',
        [hashtable]$TeamIds = @{}    # codePath -> ADO GUID; mutated in-place for caller to persist
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    $project  = $Resolved.program
    $doFix    = ($Mode -eq 'Apply')

    # output helpers
    $rOk      = { param($m) Write-Host "  [ok]      $m" -ForegroundColor Green }
    $rCreated = { param($m) Write-Host "  [+]       $m  [created]" -ForegroundColor Yellow }
    $rFixed   = { param($m) Write-Host "  [~]       $m  [corrected]" -ForegroundColor Yellow }
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

    # Audit exceptions: best-effort bulk fetch for extra paths
    try {
        $bulkAreas = Get-AdoAreaPathSubtree -OrgUrl $OrgUrl -Project $project
        if ($bulkAreas.Count -gt 1) {
            foreach ($livePath in ($bulkAreas.Keys | Sort-Object)) {
                if ($livePath -notin $desiredPaths) {
                    $findings.Add("AUDIT EXCEPTION area path: $livePath")
                    & $rOrphan "area path: $livePath"
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

    $desiredTeamNameSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(@($desiredTeams | ForEach-Object { $_.name }) + @($project) + @("$project Team")),
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
                $liveMembers = Get-AdoGroupMemberSet -OrgUrl $OrgUrl -Descriptor $descriptor
                foreach ($m in $members) {
                    $mDesc = Find-AdoUserDescriptor -OrgUrl $OrgUrl -Upn $m
                    if (-not $mDesc) {
                        $findings.Add("UNRESOLVABLE member '$m' in '$($grp.ado)'")
                        & $rError "unresolvable user '$m' in '$($grp.ado)'"
                        continue
                    }
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
            $isPortfolio = ($team.kind -eq 'portfolio' -or $team.kind -eq 'product')
            $scopePaths  = if ($isPortfolio) {
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

    # ── 5. Security groups ────────────────────────────────────────────────────
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
