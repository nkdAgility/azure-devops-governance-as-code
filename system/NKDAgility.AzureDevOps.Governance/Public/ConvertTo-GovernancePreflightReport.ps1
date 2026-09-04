function ConvertTo-GovernancePreflightReport {
    <#
        .SYNOPSIS
        Renders one team's preflight fix report as markdown from the two files
        preflight already wrote — the data document (facts) and the findings
        document (verdicts) — plus, when present, an observations fragment
        written separately (by a person, or by the preflight-report skill).

        This function OWNS the document (ADR-009). Every count, table and
        label in it is copied from the inputs; nothing is computed by anyone
        who might get it wrong. The fragment is inserted between two markers
        in one bounded section and can never reach a table. Idempotent: the
        same inputs produce the same bytes, and re-running after the fragment
        appears produces the same document plus that section.

        Engagement vocabulary (rule numbers, task ids, owner lanes) comes from
        the finding objects and the optional -Labels map; the name of the
        standard they refer to and the candidate-tag threshold come from
        -Reporting. The engine itself names no customer document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$FindingsPath,
        [string]$ObservationsPath = '',
        [string]$OutputPath = '',
        [object]$Labels = $null,      # check id -> @{ rule; task; lane; ... }
        [object]$Reporting = $null    # @{ standard; audience; candidateTagMinUses; iterationTop; title }
    )

    foreach ($p in $DataPath, $FindingsPath) {
        if (-not (Test-Path -LiteralPath $p)) { throw "ConvertTo-GovernancePreflightReport: input not found: $p" }
    }
    $data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    $fin  = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if ([string]$data.schema -ne 'nkdagility.governance.preflight-data/1') {
        throw "'$DataPath' is not a preflight data document this engine understands (schema '$($data.schema)')."
    }
    if ([string]$fin.mode -ne 'Preflight') {
        throw "'$FindingsPath' is a '$($fin.mode)' report, not a preflight findings document."
    }

    $code      = [string]$data.node
    $threshold = if ($Reporting -and $Reporting.candidateTagMinUses) { [int]$Reporting.candidateTagMinUses } else { 20 }
    $iterTop   = if ($Reporting -and $Reporting.iterationTop)        { [int]$Reporting.iterationTop }        else { 7 }
    $title     = if ($Reporting -and $Reporting.title)               { [string]$Reporting.title }            else { 'Pre-migration readiness check' }
    # Default beside the inputs, carrying the same self-describing stem the
    # data file has ('<program>-preflight-<CODE>-data.json' -> '…-report.md'),
    # so a report lifted out of the folder still says what it is.
    if (-not $OutputPath) {
        $stem = [System.IO.Path]::GetFileName($DataPath) -replace '[-.]?data\.json$', ''
        $name = if ($stem) { "$stem-report.md" } else { "preflight-$code-report.md" }
        $OutputPath = Join-Path ([System.IO.Path]::GetDirectoryName($DataPath)) $name
    }

    # ── helpers ────────────────────────────────────────────────────────────
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $n   = { param($v) ([long]$v).ToString('N0', $inv) }
    $esc = { param($s) ([string]$s) -replace '\|', '\|' -replace "`r?`n", ' ' }
    $L   = [System.Collections.Generic.List[string]]::new()
    $table = {
        param([string[]]$header, [object[]]$rows)
        $L.Add('| ' + (($header | ForEach-Object { & $esc $_ }) -join ' | ') + ' |')
        $L.Add('|' + (($header | ForEach-Object { ' --- ' }) -join '|') + '|')
        foreach ($r in $rows) { $L.Add('| ' + ((@($r) | ForEach-Object { & $esc $_ }) -join ' | ') + ' |') }
        $L.Add('')
    }
    $findings = @($fin.findings)
    $byCheck  = @{}
    foreach ($f in $findings) {
        $k = [string]$f.check
        if (-not $byCheck.ContainsKey($k)) { $byCheck[$k] = [System.Collections.Generic.List[object]]::new() }
        $byCheck[$k].Add($f)
    }
    $count = { param($check) if ($byCheck.ContainsKey($check)) { $byCheck[$check].Count } else { 0 } }

    # Label columns: whatever the program attached, rule/task/lane first.
    $engineFields = @('class', 'check', 'subject', 'message', 'source', 'workItems', 'tags', 'examples', 'group', 'team', 'sourceTeam', 'suggestions', 'why')
    $labelKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($pref in 'rule', 'task', 'lane') { $labelKeys.Add($pref) }
    if ($Labels) { foreach ($c in @($Labels.Keys)) { foreach ($k in @($Labels[$c].Keys)) { if ($k -notin $labelKeys) { $labelKeys.Add([string]$k) } } } }
    foreach ($f in $findings) { foreach ($k in @($f.Keys)) { if ($k -notin $engineFields -and $k -notin $labelKeys) { $labelKeys.Add([string]$k) } } }
    $labelsFor = {
        param($check)
        $out = [ordered]@{}
        if ($Labels -and $Labels.Contains($check)) { foreach ($k in @($Labels[$check].Keys)) { $out[[string]$k] = [string]$Labels[$check][$k] } }
        if ($byCheck.ContainsKey($check)) {
            $first = $byCheck[$check][0]
            foreach ($k in $labelKeys) { if (-not $out.Contains($k) -and $first.Contains($k)) { $out[$k] = [string]$first[$k] } }
        }
        $out
    }
    $anyLabels = $false
    foreach ($c in @($byCheck.Keys) + @(if ($Labels) { $Labels.Keys })) { if ((& $labelsFor $c).Count -gt 0) { $anyLabels = $true; break } }
    $usedLabelKeys = @($labelKeys | Where-Object { $k = $_; @(@($byCheck.Keys) + @(if ($Labels) { $Labels.Keys }) | Where-Object { (& $labelsFor $_).Contains($k) }).Count -gt 0 })
    $titleCase = { param($s) ([string]$s).Substring(0, 1).ToUpperInvariant() + ([string]$s).Substring(1) }

    # ── facts ─────────────────────────────────────────────────────────────
    $areas      = @($data.areas)
    $srcRoot    = [string]$data.source.areaPath
    $subAreas   = @($areas | Where-Object { [string]$_.source -ne $srcRoot })
    $orphanSet  = @{}; foreach ($f in @(if ($byCheck.ContainsKey('area.orphan')) { $byCheck['area.orphan'] })) { $orphanSet[[string]$f.source] = $true }
    $families   = @(if ($byCheck.ContainsKey('tag.disallowed')) { $byCheck['tag.disallowed'] })
    $unsanct    = @(if ($byCheck.ContainsKey('tag.unsanctioned')) { $byCheck['tag.unsanctioned'] })
    $famTags    = ($families | ForEach-Object { [long]$_.tags }      | Measure-Object -Sum).Sum
    $famItems   = ($families | ForEach-Object { [long]$_.workItems } | Measure-Object -Sum).Sum
    $teamsDecl  = @($data.source.teams | Where-Object { $_ }).Count -gt 0
    $reposDecl  = $null -ne $data.source.repoInclude
    $authoredN  = @($data.authored.members).Count + @($data.authored.teamAdmins).Count
    $unresolved = @(if ($byCheck.ContainsKey('member.unresolvable')) { $byCheck['member.unresolvable'] }) + @(if ($byCheck.ContainsKey('teamAdmin.unresolvable')) { $byCheck['teamAdmin.unresolvable'] })
    $unauth     = @(if ($byCheck.ContainsKey('member.unauthored')) { $byCheck['member.unauthored'] })
    $repoOrph   = @(if ($byCheck.ContainsKey('repo.orphan')) { $byCheck['repo.orphan'] })
    $errors     = @(if ($byCheck.ContainsKey('preflight.error')) { $byCheck['preflight.error'] })
    $infoLines  = @($fin.info)
    $sanctionedUnused = @($infoLines | ForEach-Object { if ($_ -match '^sanctioned tag not in use at the source \(apply seeds it in the target\): (.+)$') { $Matches[1] } })

    # ── document ──────────────────────────────────────────────────────────
    $L.Add("# $code — $title")
    $L.Add('')
    $head = [System.Collections.Generic.List[object]]::new()
    $head.Add(@('**Team**', "``$code``"))
    $head.Add(@('**Today**', "``$($data.source.org)`` / ``$($data.source.project)`` / ``$srcRoot`` — $(& $n $data.workItems.count) work items"))
    $head.Add(@('**Destination**', "``$($data.target.org)`` / ``$($data.target.project)`` / ``$($data.target.root)``"))
    # ConvertFrom-Json turns the ISO string back into a DateTime; render it
    # invariantly so the document is the same bytes on every machine.
    $gathered = if ($data.gathered -is [datetime]) { ([datetime]$data.gathered).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'", $inv) } else { [string]$data.gathered }
    $head.Add(@('**Data gathered**', $gathered))
    if ($Reporting -and $Reporting.standard) { $head.Add(@('**Standard**', [string]$Reporting.standard)) }
    if ($Reporting -and $Reporting.audience) { $head.Add(@('**Audience**', [string]$Reporting.audience)) }
    $result = if ($errors.Count -gt 0) { "**ERROR** — the gather did not complete; see Errors" }
              elseif ($findings.Count -eq 0) { '**COMPLIANT** — zero findings' }
              else { "**NOT YET READY** — $(& $n $findings.Count) finding(s) across $($byCheck.Keys.Count) check(s)" }
    $head.Add(@('**Result**', $result))
    & $table @('', '') $head

    if ($errors.Count -gt 0) {
        $L.Add('## Errors'); $L.Add('')
        foreach ($e in $errors) { $L.Add("- $($e.message)"); if ($e.why) { $L.Add("  - **Why:** $($e.why)") } }
        $L.Add('')
    }

    # Summary
    $L.Add('## Summary'); $L.Add('')
    $catalogue = @(
        @{ check = 'area.orphan';            label = 'Area paths not authored in the target';      result = { "$(& $n (& $count 'area.orphan')) of $(& $n $subAreas.Count) sub-areas" } },
        @{ check = 'tag.disallowed';         label = 'Tags: machine-generated families';           result = { if ($families.Count) { "$($families.Count) families, $(& $n $famTags) tags on $(& $n $famItems) work items" } else { 'none' } } },
        @{ check = 'tag.unsanctioned';       label = 'Tags outside the vocabulary';                result = { "$(& $n $unsanct.Count) tags" } },
        @{ check = 'repo.orphan';            label = 'Repositories not authored';                  result = { if (-not $reposDecl) { 'not checked — no repository filter declared' } else { "$(& $n $repoOrph.Count) of $(& $n @($data.repos).Count) repos" } } },
        @{ check = 'member.unresolvable';    label = 'Authored people the target cannot resolve';  result = { if ($unresolved.Count) { "$(& $n $unresolved.Count) of $(& $n $authoredN)" } else { "pass — $(& $n $authoredN) authored, all resolve" } } },
        @{ check = 'member.unauthored';      label = 'People in the source team today, not authored'; result = { if (-not $teamsDecl) { 'not checked — no source teams declared' } elseif ($unauth.Count) { "$(& $n $unauth.Count) of $(& $n @($data.population.Keys).Count)" } else { "pass — $(& $n @($data.population.Keys).Count) people, all authored" } } }
    )
    $hdr = @('Check', 'Result') + @($usedLabelKeys | ForEach-Object { & $titleCase $_ })
    # Rows are emitted with a leading comma throughout this function: a bare
    # array coming out of a foreach statement unrolls into single cells.
    $rows = foreach ($c in $catalogue) {
        $lab = & $labelsFor $c.check
        if ($c.check -eq 'member.unresolvable' -and $lab.Count -eq 0) { $lab = & $labelsFor 'teamAdmin.unresolvable' }
        , (@($c.label, (& $c.result)) + @($usedLabelKeys | ForEach-Object { if ($lab.Contains($_)) { $lab[$_] } else { '' } }))
    }
    & $table $hdr @($rows)

    # 1. Area paths
    $L.Add("## 1. Area paths — $(& $n $subAreas.Count) sub-areas, $(& $n (& $count 'area.orphan')) not authored"); $L.Add('')
    $L.Add('Work items are those sitting directly on each path. A sub-area that is not authored in the target has no node to land on.'); $L.Add('')
    $areaRows = foreach ($a in ($areas | Sort-Object { -[long]$_.workItems }, { [string]$_.source })) {
        $src  = [string]$a.source
        $name = if ($src -eq $srcRoot) { '*(root)*' } else { $src.Substring($srcRoot.Length + 1) }
        $st   = if ($src -eq $srcRoot) { 'root' } elseif ($orphanSet.ContainsKey($src)) { 'not authored' } else { 'authored' }
        , @((& $n $a.workItems), $name, $st)
    }
    & $table @('Work items', 'Sub-area', 'Target') @($areaRows)

    # 2. Tags
    $L.Add("## 2. Tags — $(& $n @($data.tags.Keys).Count) distinct tags in use"); $L.Add('')
    $L.Add('### 2a. Machine-generated families'); $L.Add('')
    if ($families.Count -eq 0) { $L.Add('None matched a disallowed pattern.'); $L.Add('') }
    else {
        $L.Add('Each row is one disallowed pattern. These are reported as families because no one applied them by hand, and they are removed as families.'); $L.Add('')
        $famRows = foreach ($f in ($families | Sort-Object { -[long]$_.tags })) { , @("``$($f.subject)``", (& $n $f.tags), (& $n $f.workItems), (@($f.examples | Select-Object -First 3) -join ', ')) }
        & $table @('Pattern', 'Distinct tags', 'Work items', 'Examples') @($famRows)
    }
    $L.Add("### 2b. Tags outside the vocabulary — $(& $n $unsanct.Count)"); $L.Add('')
    if ($unsanct.Count -gt 0) {
        $buckets = [ordered]@{ '1 work item' = 0; '2 to 5' = 0; '6 to 20' = 0; '21 to 50' = 0; 'more than 50' = 0 }
        foreach ($t in $unsanct) {
            $w = [long]$t.workItems
            $k = if ($w -le 1) { '1 work item' } elseif ($w -le 5) { '2 to 5' } elseif ($w -le 20) { '6 to 20' } elseif ($w -le 50) { '21 to 50' } else { 'more than 50' }
            $buckets[$k]++
        }
        & $table @('Used on', 'Distinct tags') @(foreach ($k in $buckets.Keys) { , @($k, (& $n $buckets[$k])) })
        $cands = @($unsanct | Where-Object { [long]$_.workItems -gt $threshold } | Sort-Object { -[long]$_.workItems }, { [string]$_.subject })
        $L.Add("Tags used on more than $(& $n $threshold) work items — the candidates for the vocabulary ($(& $n $cands.Count)):"); $L.Add('')
        if ($cands.Count -gt 0) { & $table @('Uses', 'Tag') @(foreach ($t in $cands) { , @((& $n $t.workItems), $t.subject) }) }
        else { $L.Add('None.'); $L.Add('') }
    }
    if ($sanctionedUnused.Count -gt 0) {
        $L.Add("Sanctioned tags not yet in use here, created in the target automatically: $(($sanctionedUnused | Sort-Object) -join ', ').")
        $L.Add('')
    }

    # 3. People
    $L.Add('## 3. People'); $L.Add('')
    if ($unresolved.Count -eq 0) { $L.Add("All $(& $n $authoredN) authored people and team admins resolve in the target organisation.") }
    else {
        $L.Add("$(& $n $unresolved.Count) authored entries do not resolve in the target organisation:"); $L.Add('')
        & $table @('UPN', 'Where', 'Did you mean') @(foreach ($u in $unresolved) { , @($u.subject, $(if ($u.group) { $u.group } else { $u.team }), (@($u.suggestions) -join ', ')) })
    }
    $L.Add('')
    if (-not $teamsDecl) { $L.Add('**Not checked:** no source teams are declared, so whether anyone working here today is missing from the authored list is unknown. Declaring the source team(s) enables this check.') }
    elseif ($unauth.Count -eq 0) { $L.Add("Everyone in the declared source team(s) ($(& $n @($data.population.Keys).Count) people) is authored.") }
    else {
        $L.Add("$(& $n $unauth.Count) people work here today and are not authored — they lose access at migration unless added or deliberately left out:"); $L.Add('')
        & $table @('UPN', 'Source team') @(foreach ($u in $unauth) { , @($u.subject, $u.sourceTeam) })
    }
    $L.Add('')

    # 4. Repositories
    $L.Add('## 4. Repositories'); $L.Add('')
    if (-not $reposDecl) { $L.Add('**Not checked:** no repository filter is declared for this team. Declaring one enables the naming check.') }
    elseif ($repoOrph.Count -eq 0) { $L.Add("All $(& $n @($data.repos).Count) matched repositories have an authored name.") }
    else {
        $L.Add("$(& $n $repoOrph.Count) of $(& $n @($data.repos).Count) matched repositories have no authored name:"); $L.Add('')
        & $table @('Repository') @(foreach ($r in $repoOrph) { , @($r.subject) })
    }
    $L.Add('')

    # 5. Iterations
    $iters = @($data.iterations.Keys | Sort-Object { -[long]$data.iterations[$_] }, { $_ } | Select-Object -First $iterTop)
    if ($iters.Count -gt 0) {
        $L.Add("## 5. Iteration paths in use — top $(& $n $iters.Count) of $(& $n @($data.iterations.Keys).Count)"); $L.Add('')
        $L.Add('Context for the migration mapping, not a finding.'); $L.Add('')
        & $table @('Work items', 'Iteration path') @(foreach ($i in $iters) { , @((& $n $data.iterations[$i]), $i) })
    }

    # 6. Observations (the only section anyone other than this function writes)
    $L.Add('## 6. Observations'); $L.Add('')
    $L.Add('<!-- observations:begin -->')
    if ($ObservationsPath -and (Test-Path -LiteralPath $ObservationsPath)) {
        $frag = (Get-Content -LiteralPath $ObservationsPath -Raw) -replace "`r`n", "`n"
        foreach ($line in ($frag.Trim() -split "`n")) { $L.Add($line) }
    } else {
        $L.Add('_No observations were generated for this report._')
    }
    $L.Add('<!-- observations:end -->')
    $L.Add('')

    # 7. Returns
    $L.Add('## 7. What this team owes'); $L.Add('')
    $owed = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $catalogue) {
        $hits = & $count $c.check
        if ($c.check -eq 'member.unresolvable') { $hits += & $count 'teamAdmin.unresolvable' }
        if ($hits -eq 0) { continue }
        $lab = & $labelsFor $c.check
        $tag = @(); if ($lab.Contains('task')) { $tag += "Task $($lab['task'])" }; if ($lab.Contains('rule')) { $tag += "rule $($lab['rule'])" }; if ($lab.Contains('lane')) { $tag += $lab['lane'] }
        $owed.Add("- **$($c.label)** — $(& $n $hits)$(if ($tag.Count) { ' · ' + ($tag -join ' · ') })")
    }
    if (-not $teamsDecl) { $owed.Add('- **Declare the source team(s)** so the missing-people check can run') }
    if (-not $reposDecl) { $owed.Add('- **Declare the repository filter** so the naming check can run') }
    if ($owed.Count -eq 0) { $L.Add('Nothing. This team is at the bar.') } else { foreach ($o in $owed) { $L.Add($o) } }
    $L.Add('')
    $L.Add('---')
    $L.Add("_Rendered by NKDAgility.AzureDevOps.Governance from ``$(Split-Path -Leaf $DataPath)`` and ``$(Split-Path -Leaf $FindingsPath)``. Every number above is copied from those files; the Observations section is the only prose written by anyone else._")
    $L.Add('')

    $outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutputPath, ($L -join "`n"), [System.Text.UTF8Encoding]::new($false))
    return $OutputPath
}
