# The check ids a preflight finding can carry. sources.yaml `labels:` may attach
# extra fields (an engagement's rule number, owner lane, task id) per check id;
# Test-GovernanceSources validates against this list.
$script:GovernancePreflightChecks = @(
    'area.orphan',            # source sub-area with no authored counterpart
    'tag.disallowed',         # a disallowed pattern family in use on source work items
    'tag.unsanctioned',       # a tag outside the vocabulary in use on source work items
    'repo.orphan',            # a source repo with no authored name under the node
    'member.unresolvable',    # an authored role-list UPN the target org cannot resolve
    'teamAdmin.unresolvable', # an authored team admin UPN the target org cannot resolve
    'member.unauthored',      # someone in a source team today who is not authored
    'preflight.error'         # the gather itself failed
)

function Resolve-GovernancePreflightFindings {
    <#
        .SYNOPSIS
        The ANALYSIS half of preflight (ADR-008): pure. Takes the gathered
        data document (fresh from Get-GovernancePreflightData, or read back
        from preflight-<code>.data.json) plus the node's slice of the resolved
        model, runs the SAME evaluators audit uses, and returns structured
        findings — never touching either organisation.

        Each finding is an ordered hashtable with at least:
          class    missing | drift | error | unresolvable | exception
                   (the report writer's JSON classes)
          check    one of $script:GovernancePreflightChecks
          subject  the thing the finding is about (path, tag, pattern, UPN, repo)
          message  the human line the text report prints — keeps the legacy
                   prefix (DRIFT / AUDIT EXCEPTION / UNRESOLVABLE / ERROR)
        plus check-specific fields (source, workItems, tags, examples, group,
        team, sourceTeam, suggestions) and any fields the caller's Labels map
        attaches for that check.

        Also returns Info (context lines that are never findings) and Lines
        (the console narrative, tagged by level, for the caller to print).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Data,
        [Parameter(Mandatory)][object]$Slice,
        [object]$Labels = $null
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $info     = [System.Collections.Generic.List[string]]::new()
    $lines    = [System.Collections.Generic.List[object]]::new()
    $say      = { param($level, $text) $lines.Add(@{ level = $level; text = $text }) }

    $add = {
        param($finding)   # an [ordered] dictionary — never cast to [hashtable], that drops the order
        $check = [string]$finding.check
        if ($Labels -and $Labels.Contains($check)) {
            foreach ($k in @($Labels[$check].Keys)) {
                if (-not $finding.Contains($k)) { $finding[$k] = $Labels[$check][$k] }
            }
        }
        $findings.Add($finding)
    }

    $nodeCode   = [string]$Data.node
    $srcArea    = ([string]$Data.source.areaPath).TrimStart('\')
    $tagUsage   = $Data.tags
    $tagCount   = { param($t) [int]$tagUsage[$t] }

    # ── 1. Area subtree, already projected into target coordinates ────────────
    & $say 'section' 'Area paths'
    $projectedSet = @{}
    $sourceOf     = @{}
    $usageOf      = @{}
    foreach ($a in @($Data.areas)) {
        $projectedSet[[string]$a.target] = $true
        $sourceOf[[string]$a.target]     = [string]$a.source
        $usageOf[[string]$a.target]      = [int]$a.workItems
    }
    $desiredPaths = @($Slice.AreaPaths | Where-Object { $_.scope -ne 'future' } | ForEach-Object { $_.path })
    $areaVerdict  = Test-GovernanceAreaCompliance -DesiredPaths $desiredPaths `
        -LiveDesiredSet $projectedSet -ModelPaths @($Slice.AreaPaths | ForEach-Object { $_.path }) `
        -LiveSubtree $projectedSet
    foreach ($p in $desiredPaths) { if ($projectedSet[$p]) { & $say 'ok' $p } }
    foreach ($orphan in $areaVerdict.Orphans) {
        & $add ([ordered]@{
            class     = 'exception'
            check     = 'area.orphan'
            subject   = $orphan
            source    = $sourceOf[$orphan]
            workItems = $usageOf[$orphan]
            message   = "AUDIT EXCEPTION area path: $orphan (today: $($sourceOf[$orphan]), $($usageOf[$orphan]) work item(s) directly on it — author it or fold it to a tag before migration)"
        })
        & $say 'orphan' "area path: $orphan  (today: $($sourceOf[$orphan]), $($usageOf[$orphan]) work item(s))"
    }
    foreach ($m in $areaVerdict.Missing) {
        $info.Add("authored area path with no source counterpart (apply creates it; decide where its work items come from): $m")
        & $say 'info' "no source counterpart: $m"
    }

    # ── 2. Tags in use on work items under the source area ────────────────────
    if ($Slice.Tags) {
        & $say 'section' 'Tags'
        $tagVerdict = Test-GovernanceTagCompliance -Sanctioned @($Slice.Tags.sanctioned) `
            -DisallowedPatterns @($Slice.Tags.disallowedPatterns) -LiveTagNames @($tagUsage.Keys)
        # Disallowed patterns exist to catch machine-generated families (build
        # ids, session ids) that run to thousands of distinct tags — one
        # finding per PATTERN, with usage and examples, is what a team can act
        # on; one per tag is a wall nobody reads.
        foreach ($entry in $tagVerdict.DisallowedByPattern.GetEnumerator()) {
            $names    = @($entry.Value)
            $onItems  = ($names | ForEach-Object { & $tagCount $_ } | Measure-Object -Sum).Sum
            $examples = @($names | Sort-Object { & $tagCount $_ } -Descending | Select-Object -First 5)
            & $add ([ordered]@{
                class     = 'drift'
                check     = 'tag.disallowed'
                subject   = [string]$entry.Key
                tags      = $names.Count
                workItems = [int]$onItems
                examples  = $examples
                message   = "DRIFT tag pattern '$($entry.Key)': $($names.Count) tag(s) on $onItems work item(s) under $srcArea match a disallowed pattern — e.g. $($examples -join ', ')"
            })
            & $say 'drift' "tag pattern '$($entry.Key)': $($names.Count) tag(s), $onItems work item(s) — e.g. $($examples -join ', ')"
        }
        foreach ($t in $tagVerdict.Unsanctioned) {
            $n = & $tagCount $t
            & $add ([ordered]@{
                class     = 'exception'
                check     = 'tag.unsanctioned'
                subject   = $t
                workItems = $n
                message   = "AUDIT EXCEPTION tag: $t (in use on $n work item(s) under $srcArea)"
            })
            & $say 'orphan' "tag: $t ($n work item(s))"
        }
        foreach ($t in ($tagVerdict.Missing | Sort-Object)) {
            $info.Add("sanctioned tag not in use at the source (apply seeds it in the target): $t")
        }
        & $say 'ok' "$($tagVerdict.OkCount) sanctioned tag(s) in use across $($Data.workItems.count) work item(s)"
    }

    # ── 3. Repo naming (only when sources.yaml names the team's repos) ─────────
    if ($null -ne $Data.source.repoInclude) {
        & $say 'section' 'Repos'
        $globs   = @($Data.source.repoInclude)
        $matched = @($Data.repos)
        if ($matched.Count -eq 0) {
            $info.Add("no source repos matched the include patterns ($($globs -join ', ')) — repo naming not checked")
            & $say 'info' "no source repos matched: $($globs -join ', ')"
        } else {
            $repoVerdict = Test-GovernanceRepoCompliance -DesiredNames @($Slice.Repos | ForEach-Object { $_.name }) `
                -LiveNames $matched -Project ([string]$Data.target.project)
            foreach ($name in $matched) { if ($name -notin $repoVerdict.Orphans) { & $say 'ok' "repo: $name" } }
            foreach ($name in $repoVerdict.Orphans) {
                & $add ([ordered]@{
                    class   = 'exception'
                    check   = 'repo.orphan'
                    subject = $name
                    message = "AUDIT EXCEPTION repo: $name (no authored repo with this name under '$nodeCode' — author it in hierarchy.yaml repos: or plan the rename; authored names are prefixed '$nodeCode-')"
                })
                & $say 'orphan' "repo: $name"
            }
            foreach ($name in $repoVerdict.Missing) {
                $info.Add("authored repo with no source counterpart: $name")
                & $say 'info' "no source counterpart: repo $name"
            }
        }
    }

    # ── 4. Members — resolution in the TARGET org + source population ─────────
    & $say 'section' 'Members'
    $authoredUpns = @{}
    foreach ($m in @($Data.authored.members)) {
        $upn = [string]$m.upn
        $authoredUpns[$upn] = $true
        if ($m.resolved) { & $say 'ok' "member resolves: $upn ($($m.group))"; continue }
        $near = @($m.suggestions)
        $why  = if ($near.Count -gt 0) { "no org member has this exact UPN - did you mean: $($near -join ', ')?" }
                else { "no org member matches this UPN - the user must be added to the org (Entra membership alone is not enough) before governance can grant them access" }
        & $add ([ordered]@{
            class       = 'unresolvable'
            check       = 'member.unresolvable'
            subject     = $upn
            group       = [string]$m.group
            suggestions = $near
            message     = "UNRESOLVABLE member '$upn' in '$($m.group)': $why"
        })
        & $say 'error' "unresolvable user '$upn' in '$($m.group)': $why"
    }
    foreach ($m in @($Data.authored.teamAdmins)) {
        $upn = [string]$m.upn
        $authoredUpns[$upn] = $true
        if ($m.resolved) { continue }
        $near = @($m.suggestions)
        $why  = if ($near.Count -gt 0) { "no org member has this exact UPN - did you mean: $($near -join ', ')?" }
                else { 'no org member matches this UPN' }
        & $add ([ordered]@{
            class       = 'unresolvable'
            check       = 'teamAdmin.unresolvable'
            subject     = $upn
            team        = [string]$m.team
            suggestions = $near
            message     = "UNRESOLVABLE team admin '$upn' for '$($m.team)': $why"
        })
        & $say 'error' "unresolvable team admin '$upn' for '$($m.team)': $why"
    }

    $population = $Data.population
    if (-not $population -or @($population.Keys).Count -eq 0) {
        $info.Add('no source teams declared in sources.yaml — the works-there-today membership check was skipped')
        & $say 'info' 'no source teams declared — population check skipped'
    } else {
        foreach ($upn in @($population.Keys | Sort-Object)) {
            if ($authoredUpns.ContainsKey($upn)) { & $say 'ok' "authored: $upn"; continue }
            & $add ([ordered]@{
                class      = 'drift'
                check      = 'member.unauthored'
                subject    = $upn
                sourceTeam = [string]$population[$upn]
                message    = "DRIFT members '$nodeCode': '$upn' is in source team '$($population[$upn])' today but is not authored in members/$nodeCode.yaml — they lose access at migration unless added (with a reason) or deliberately left out"
            })
            & $say 'drift' "unauthored: $upn (source team '$($population[$upn])')"
        }
    }

    # ── 5. Migration-mapping context (never findings) ─────────────────────────
    $info.Add("$($Data.workItems.count) work item(s) under $srcArea at the source")
    $iterations = $Data.iterations
    if ($iterations) {
        foreach ($k in @($iterations.Keys | Sort-Object { [int]$iterations[$_] } -Descending | Select-Object -First 5)) {
            $info.Add("iteration path in use at the source ($($iterations[$k]) work item(s)): $k")
        }
    }
    $info.Add('work item type/state/field compatibility is validated by the migration toolchain, not governance')

    return @{
        Findings = @($findings)
        Info     = @($info)
        Lines    = @($lines)
    }
}
