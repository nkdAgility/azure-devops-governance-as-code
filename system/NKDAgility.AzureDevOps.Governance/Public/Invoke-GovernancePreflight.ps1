function Invoke-GovernancePreflight {
    <#
        .SYNOPSIS
        Pre-migration compliance report, per incoming team: if this team's
        current content moved into the governed target TODAY, which checks
        would fail? Gathers live state from the team's source location
        (declared in programs/<name>/sources.yaml), projects it into target
        coordinates, and evaluates it with the SAME evaluators audit uses —
        so a team can fix its findings in place, before migration, and the
        post-migration audit can never disagree with what preflight said.

        Checked per node: area subtree shape (orphans-to-be), tag usage on
        work items under the source area (disallowed + unsanctioned), repo
        naming (when sources.yaml names the team's repos), authored member
        UPNs resolvable in the TARGET org, and people working in the source
        team today who are not authored (the day-one lockout list).

        Read-only against BOTH organisations. Writes one report pair
        (preflight-<code>.txt/.json) per node next to resolved.yaml, and
        exits non-zero when findings exist (same CI contract as audit).

        Out of scope by design: work item type/state/field compatibility —
        that is the migration toolchain's validation, not governance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Code,
        [string]$Org
    )

    # Always build first — preflight must reflect the latest authored config.
    Invoke-GovernanceBuild -ProgramPath $ProgramPath -OutputPath $ResolvedPath | Out-Null

    $source  = Import-GovernanceSource -ProgramPath $ProgramPath
    if (-not $source.Sources) {
        throw "No sources.yaml in '$ProgramPath'. Preflight needs the pre-migration source location per node — see Test-GovernanceSources for the shape."
    }
    $resolved = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)

    $issues = @(Test-GovernanceSources -Sources $source.Sources -Resolved $resolved)
    if ($issues.Count -gt 0) {
        $issues | ForEach-Object { Write-Error $_ }
        throw "sources.yaml validation failed with $($issues.Count) issue(s)."
    }

    $codes = if ($Code) {
        if (-not $source.Sources.Contains($Code)) {
            throw "No sources.yaml entry for '$Code'. Declared: $(@($source.Sources.Keys | Sort-Object) -join ', ')"
        }
        @($Code)
    } else { @($source.Sources.Keys | Sort-Object) }

    $manifest      = $source.Manifest
    $targetOrg     = if ($Org) { $Org } else { $manifest.org }
    $targetOrgUrl  = ConvertTo-AdoOrgUrl -Org $targetOrg
    $targetProject = if ($resolved.project -and $resolved.project.name) { $resolved.project.name } else { $resolved.program }
    Initialize-AdoAuth -Manifest $manifest -OrgUrl $targetOrgUrl | Out-Null

    $reportDir     = Split-Path $ResolvedPath -Parent
    $totalFindings = 0

    # output helpers — same vocabulary as the reconcile
    $rOk     = { param($m) Write-Host "  [ok]      $m" -ForegroundColor Green }
    $rDrift  = { param($m) Write-Host "  [DRIFT]   $m" -ForegroundColor Red }
    $rOrphan = { param($m) Write-Host "  [AUDIT EXCEPTION] $m  (would not match config after migration)" -ForegroundColor Magenta }
    $rError  = { param($m) Write-Host "  [ERROR]   $m" -ForegroundColor Red }
    $rInfo   = { param($m) Write-Host "  [info]    $m" -ForegroundColor DarkCyan }

    foreach ($nodeCode in $codes) {
        $src       = $source.Sources[$nodeCode]
        $srcOrgUrl = ConvertTo-AdoOrgUrl -Org ([string]$src.org)
        $findings  = [System.Collections.Generic.List[string]]::new()
        $info      = [System.Collections.Generic.List[string]]::new()

        Write-Host "`nPreflighting '$nodeCode': $($src.org)/$($src.project) :: $($src.areaPath)  ->  $targetOrg/$targetProject" -ForegroundColor Cyan

        try {
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code $nodeCode

            # ── Gather from the source organisation (read-only) ───────────────
            $srcAreaRoot = '\' + [string]$src.areaPath
            $authState = Enter-AdoOrgAuth -OrgUrl $srcOrgUrl -AccessTokenRef ([string]$src.accessToken)
            try {
                $srcAreas = Get-AdoAreaPathSubtree -OrgUrl $srcOrgUrl -Project $src.project
                if (-not $srcAreas.ContainsKey($srcAreaRoot)) {
                    throw "source area path '$srcAreaRoot' does not exist in $($src.org)/$($src.project)"
                }
                $usage = Get-AdoWorkItemUsageUnderArea -OrgUrl $srcOrgUrl -Project $src.project -AreaPath ([string]$src.areaPath)
                $srcRepoSet = if ($src.repos) { Get-AdoRepoSet -OrgUrl $srcOrgUrl -Project $src.project } else { $null }
                $population = @{}   # upn -> source team it was found in
                foreach ($srcTeam in @($src.teams | Where-Object { $_ })) {
                    foreach ($upn in @((Get-AdoTeamMemberUpnSet -OrgUrl $srcOrgUrl -Project $src.project -Team $srcTeam).Keys)) {
                        $population[$upn] = $srcTeam
                    }
                }
            } finally { Exit-AdoOrgAuth -State $authState }

            # ── 1. Area subtree, projected into target coordinates ────────────
            Write-Host "`n--- Area paths ---" -ForegroundColor Cyan
            $srcSubtree = @($srcAreas.Keys | Where-Object { $_ -eq $srcAreaRoot -or $_ -like "$srcAreaRoot\*" })
            $projectedSet = @{}
            $sourceOf     = @{}   # projected target path -> source path, for actionable messages
            foreach ($srcPath in $srcSubtree) {
                $projectedPath = $slice.TargetRoot + $srcPath.Substring($srcAreaRoot.Length)
                $projectedSet[$projectedPath] = $true
                $sourceOf[$projectedPath]     = $srcPath
            }
            $desiredPaths = @($slice.AreaPaths | Where-Object { $_.scope -ne 'future' } | ForEach-Object { $_.path })
            $areaVerdict = Test-GovernanceAreaCompliance -DesiredPaths $desiredPaths `
                -LiveDesiredSet $projectedSet -ModelPaths @($slice.AreaPaths | ForEach-Object { $_.path }) `
                -LiveSubtree $projectedSet
            foreach ($p in $desiredPaths) {
                if ($projectedSet[$p]) { & $rOk $p }
            }
            foreach ($orphan in $areaVerdict.Orphans) {
                $findings.Add("AUDIT EXCEPTION area path: $orphan (today: $($sourceOf[$orphan]) — author it or move its work items before migration)")
                & $rOrphan "area path: $orphan  (today: $($sourceOf[$orphan]))"
            }
            foreach ($m in $areaVerdict.Missing) {
                $info.Add("authored area path with no source counterpart (apply creates it; decide where its work items come from): $m")
                & $rInfo "no source counterpart: $m"
            }

            # ── 2. Tags in use on work items under the source area ────────────
            if ($slice.Tags) {
                Write-Host "`n--- Tags ---" -ForegroundColor Cyan
                $tagVerdict = Test-GovernanceTagCompliance -Sanctioned @($slice.Tags.sanctioned) `
                    -DisallowedPatterns @($slice.Tags.disallowedPatterns) -LiveTagNames @($usage.Tags.Keys)
                foreach ($t in $tagVerdict.Disallowed) {
                    $findings.Add("DRIFT tag '$t': matches a disallowed pattern (in use on $($usage.Tags[$t]) work item(s) under $($src.areaPath))")
                    & $rDrift "tag: $t (disallowed pattern, $($usage.Tags[$t]) work item(s))"
                }
                foreach ($t in $tagVerdict.Unsanctioned) {
                    $findings.Add("AUDIT EXCEPTION tag: $t (in use on $($usage.Tags[$t]) work item(s) under $($src.areaPath))")
                    & $rOrphan "tag: $t ($($usage.Tags[$t]) work item(s))"
                }
                foreach ($t in ($tagVerdict.Missing | Sort-Object)) {
                    $info.Add("sanctioned tag not in use at the source (apply seeds it in the target): $t")
                }
                Write-Host "  [ok]      $($tagVerdict.OkCount) sanctioned tag(s) in use across $($usage.WorkItemCount) work item(s)" -ForegroundColor Green
            }

            # ── 3. Repo naming (only when sources.yaml names the team's repos) ─
            if ($src.repos) {
                Write-Host "`n--- Repos ---" -ForegroundColor Cyan
                $globs   = @($src.repos.include)
                $matched = @($srcRepoSet.Keys | Where-Object { $n = $_; @($globs | Where-Object { $n -like $_ }).Count -gt 0 } | Sort-Object)
                if ($matched.Count -eq 0) {
                    $info.Add("no source repos matched the include patterns ($($globs -join ', ')) — repo naming not checked")
                    & $rInfo "no source repos matched: $($globs -join ', ')"
                } else {
                    $repoVerdict = Test-GovernanceRepoCompliance -DesiredNames @($slice.Repos | ForEach-Object { $_.name }) `
                        -LiveNames $matched -Project $targetProject
                    foreach ($name in $matched) {
                        if ($name -notin $repoVerdict.Orphans) { & $rOk "repo: $name" }
                    }
                    foreach ($name in $repoVerdict.Orphans) {
                        $findings.Add("AUDIT EXCEPTION repo: $name (no authored repo with this name under '$nodeCode' — author it in hierarchy.yaml repos: or plan the rename; authored names are prefixed '$nodeCode-')")
                        & $rOrphan "repo: $name"
                    }
                    foreach ($name in $repoVerdict.Missing) {
                        $info.Add("authored repo with no source counterpart: $name")
                        & $rInfo "no source counterpart: repo $name"
                    }
                }
            }

            # ── 4. Members — resolution in the TARGET org + source population ──
            Write-Host "`n--- Members ---" -ForegroundColor Cyan
            $authoredUpns = @{}   # upn -> $true across every role list + teamAdmins
            $upnCache     = @{}   # upn -> descriptor or $null (target org lookups)
            $seenGroups   = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($team in $slice.Teams) {
                foreach ($grp in @($team.securityGroups | Where-Object { $_ })) {
                    if (-not $seenGroups.Add($grp.ado)) { continue }
                    foreach ($e in @($grp.members | Where-Object { $_ })) {
                        $upn = if ($e -is [string]) { if ($e -match '@') { $e } else { $null } }
                               elseif ($e.upn)      { [string]$e.upn }
                               else                 { $null }   # nested groups: audited post-apply, not here
                        if (-not $upn) { continue }
                        $authoredUpns[$upn] = $true
                        if (-not $upnCache.ContainsKey($upn)) {
                            $upnCache[$upn] = Find-AdoUserDescriptor -OrgUrl $targetOrgUrl -Upn $upn
                        }
                        if (-not $upnCache[$upn]) {
                            $near = @(Find-AdoUserSuggestion -OrgUrl $targetOrgUrl -Upn $upn)
                            $why  = if ($near.Count -gt 0) {
                                "no org member has this exact UPN - did you mean: $($near -join ', ')?"
                            } else {
                                "no org member matches this UPN - the user must be added to the org (Entra membership alone is not enough) before governance can grant them access"
                            }
                            $findings.Add("UNRESOLVABLE member '$upn' in '$($grp.ado)': $why")
                            & $rError "unresolvable user '$upn' in '$($grp.ado)': $why"
                        } else {
                            & $rOk "member resolves: $upn ($($grp.ado))"
                        }
                    }
                }
                foreach ($m in @($team.teamAdmins | Where-Object { $_ -and $_.upn })) {
                    $upn = [string]$m.upn
                    $authoredUpns[$upn] = $true
                    if (-not $upnCache.ContainsKey($upn)) {
                        $upnCache[$upn] = Find-AdoUserDescriptor -OrgUrl $targetOrgUrl -Upn $upn
                    }
                    if (-not $upnCache[$upn]) {
                        $near = @(Find-AdoUserSuggestion -OrgUrl $targetOrgUrl -Upn $upn)
                        $why  = if ($near.Count -gt 0) { "no org member has this exact UPN - did you mean: $($near -join ', ')?" }
                                else { "no org member matches this UPN" }
                        $findings.Add("UNRESOLVABLE team admin '$upn' for '$($team.name)': $why")
                        & $rError "unresolvable team admin '$upn' for '$($team.name)': $why"
                    }
                }
            }

            if ($population.Count -eq 0) {
                $info.Add("no source teams declared in sources.yaml — the works-there-today membership check was skipped")
                & $rInfo "no source teams declared — population check skipped"
            } else {
                foreach ($upn in ($population.Keys | Sort-Object)) {
                    if (-not $authoredUpns.ContainsKey($upn)) {
                        $findings.Add("DRIFT members '$nodeCode': '$upn' is in source team '$($population[$upn])' today but is not authored in members/$nodeCode.yaml — they lose access at migration unless added (with a reason) or deliberately left out")
                        & $rDrift "unauthored: $upn (source team '$($population[$upn])')"
                    } else {
                        & $rOk "authored: $upn"
                    }
                }
            }

            # ── 5. Migration-mapping context (never findings) ─────────────────
            $info.Add("$($usage.WorkItemCount) work item(s) under $($src.areaPath) at the source")
            foreach ($iter in ($usage.IterationPaths.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 5)) {
                $info.Add("iteration path in use at the source ($($iter.Value) work item(s)): $($iter.Key)")
            }
            $info.Add("work item type/state/field compatibility is validated by the migration toolchain, not governance")
        } catch {
            $findings.Add("ERROR preflighting '$nodeCode': $_")
            & $rError "preflight '$nodeCode': $_"
        }

        $reportPath = Join-Path $reportDir "preflight-$nodeCode.txt"
        Write-GovernanceReport -Findings $findings.ToArray() -ProgramName $resolved.program `
            -Project $targetProject -OrgUrl $targetOrgUrl -Mode 'Preflight' -ReportPath $reportPath `
            -Title 'Governance preflight report' -InfoLines $info.ToArray() -ExtraHeader @(
                "Node     : $nodeCode",
                "Source   : $($src.org)/$($src.project) :: $($src.areaPath)") | Out-Null

        $totalFindings += $findings.Count
    }

    if ($totalFindings -gt 0) {
        Write-Error "Governance preflight: $totalFindings finding(s) across $($codes.Count) node(s)."
    }
}
