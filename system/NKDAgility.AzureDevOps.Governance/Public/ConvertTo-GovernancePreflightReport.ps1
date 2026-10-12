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
        [object]$Reporting = $null    # @{ standard; audience; candidateTagMinUses; iterationTop; title;
                                      #    preamble; scopeNote; glossary; observationsLead; labelColumns }
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

    # Label columns: whatever the program attached, in `reporting.labelColumns`
    # order when declared, else rule/task/lane first.
    $engineFields = @('class', 'check', 'subject', 'message', 'source', 'workItems', 'tags', 'examples', 'group', 'team', 'sourceTeam', 'suggestions', 'why')
    $labelKeys = [System.Collections.Generic.List[string]]::new()
    $prefKeys  = if ($Reporting -and $Reporting.labelColumns) { @($Reporting.labelColumns | ForEach-Object { [string]$_ }) } else { @('rule', 'task', 'lane') }
    foreach ($pref in $prefKeys) { $labelKeys.Add($pref) }
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
    $unmappedAreas = @($data.unmappedAreas | Where-Object { $_ })
    $srcRoot    = [string]$data.source.areaPath
    $subAreas   = @($areas | Where-Object { [string]$_.source -ne $srcRoot })
    $orphanSet  = @{}; foreach ($f in @(if ($byCheck.ContainsKey('area.orphan')) { $byCheck['area.orphan'] })) { $orphanSet[[string]$f.source] = $true }
    $families   = @(if ($byCheck.ContainsKey('tag.disallowed')) { $byCheck['tag.disallowed'] })
    $unsanct    = @(if ($byCheck.ContainsKey('tag.unsanctioned')) { $byCheck['tag.unsanctioned'] })
    $asColumn   = @(if ($byCheck.ContainsKey('tag.boardColumn')) { $byCheck['tag.boardColumn'] })
    $toRetire   = @(if ($byCheck.ContainsKey('tag.retire')) { $byCheck['tag.retire'] })
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
    # Optional YAML frontmatter. A publishing system (engage-system, say) will
    # not accept a deliverable without it: brand, designation, kind. Emitting it
    # HERE is what keeps the rendered report a valid deliverable source, so
    # publishing stays a copy and never becomes an edit — the same reason no
    # other line of this document is written by hand. A report that has to be
    # hand-topped before it can ship is a report that goes stale the first time
    # anyone re-runs the analysis.
    #
    # Values come from `sources.yaml reporting.frontmatter:`; {code} and {title}
    # are substituted so one declaration covers every team. `date` defaults to
    # the date the DATA was gathered, not today, so re-rendering unchanged data
    # produces unchanged bytes.
    $fm = if ($Reporting) { $Reporting.frontmatter } else { $null }
    if ($fm) {
        $yamlScalar = {
            param($v)
            if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return [string]$v }
            $s = ([string]$v).Replace('{code}', $code).Replace('{title}', $title)
            '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"'
        }
        # Ordinal sort, because the YAML reader hands back an unordered map and
        # PowerShell does not promise a stable enumeration order for one. Authored
        # order is unrecoverable here, so the alternative to sorting is a document
        # whose first ten lines shuffle between runs — which would break the
        # byte-for-byte determinism the rest of this renderer is built on.
        $fmKeys = [string[]]@($fm.Keys)
        [array]::Sort($fmKeys, [System.StringComparer]::Ordinal)
        $L.Add('---')
        foreach ($k in $fmKeys) { $L.Add("$([string]$k): $(& $yamlScalar $fm[$k])") }
        if ('date' -notin $fmKeys) {
            $d = if ($data.gathered -is [datetime]) { ([datetime]$data.gathered).ToUniversalTime().ToString('yyyy-MM-dd', $inv) }
                 else { $t = [datetime]::MinValue
                        if ([datetime]::TryParse([string]$data.gathered, $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t)) { $t.ToString('yyyy-MM-dd', $inv) } else { '' } }
            if ($d) { $L.Add("date: $d") }
        }
        $L.Add('---')
        $L.Add('')
    }

    $L.Add("# $code — $title")
    $L.Add('')
    # Framing notes (preamble, scope note, glossary, observations lead) are
    # program prose from `reporting:`, maintained by hand there. The engine
    # renders them verbatim and puts no number in them except {label}/{date}.
    $gatheredDate = if ($data.gathered -is [datetime]) { ([datetime]$data.gathered).ToUniversalTime().ToString('d MMMM yyyy', $inv) } else { [string]$data.gathered }
    $prose = { param($s) ([string]$s).Trim().Replace('{code}', $code).Replace('{date}', $gatheredDate).Replace('{label}', [string]$data.scope.label) }
    if ($Reporting -and $Reporting.preamble) {
        foreach ($line in ((& $prose $Reporting.preamble) -split "`r?`n")) { $L.Add("> $line".TrimEnd()) }
        $L.Add('')
    }
    $head = [System.Collections.Generic.List[object]]::new()
    $head.Add(@('**Team**', "``$code``"))
    $head.Add(@('**Today**', "``$($data.source.org)`` / ``$($data.source.project)`` / ``$srcRoot`` — $(& $n $data.workItems.count) work items"))
    $head.Add(@('**Destination**', "``$($data.target.org)`` / ``$($data.target.project)`` / ``$($data.target.root)``"))
    # ConvertFrom-Json turns the ISO string back into a DateTime; render it
    # invariantly so the document is the same bytes on every machine.
    $gathered = if ($data.gathered -is [datetime]) { ([datetime]$data.gathered).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'", $inv) } else { [string]$data.gathered }
    $head.Add(@('**Data gathered**', $gathered))
    # Never let a reader guess which work items these counts cover. An
    # unscoped run includes archive nobody will migrate, and saying so is the
    # prompt that gets the migration query written.
    # The query itself is in the appendix; the cell says what it selects and,
    # via `reporting.scopeNote`, how that compares with the program's own scope.
    $hasQuery  = $data.scope -and $data.scope.query
    $scopeCell = if ($hasQuery) {
        $lbl = [string]$data.scope.label
        $s = "$(if ($lbl) { "$lbl " })(query in Appendix A)."
        if ($Reporting -and $Reporting.scopeNote) { $s += ' ' + (& $prose $Reporting.scopeNote) } else { $s += " Taken on $gatheredDate." }
        $s
    } else {
        '**every work item under the area, archive included** — no migration query declared'
    }
    $head.Add(@('**Work items checked**', $scopeCell))
    if ($Reporting -and $Reporting.standard) { $head.Add(@('**Measured against**', [string]$Reporting.standard)) }
    if ($Reporting -and $Reporting.audience) { $head.Add(@('**Audience**', [string]$Reporting.audience)) }
    # Checks that could not run count in the headline: a gap of zero with two
    # checks skipped is not a team at the target.
    $notChecked = @(@{ off = -not $teamsDecl; what = 'source-team' }, @{ off = -not $reposDecl; what = 'repository' } | Where-Object { $_.off })
    $ncText = if ($notChecked.Count) { ", plus $($notChecked.Count) not checked.** A full readiness picture needs the $(@($notChecked.what) -join ' and ') declaration$(if ($notChecked.Count -gt 1) { 's' }) below." } else { '.**' }
    $result = if ($errors.Count -gt 0) { "**ERROR** — the gather did not complete; see Errors" }
              elseif ($findings.Count -eq 0 -and $notChecked.Count -eq 0) { '**Matches the proposed target** — no gaps found' }
              else { "**Gap to the proposed target: $(& $n $findings.Count) item$(if ($findings.Count -ne 1) { 's' })$ncText" }
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
        @{ check = 'area.orphan';            label = 'Area paths not authored in the target';      result = { $c = & $count 'area.orphan'; if ($c) { "$(& $n $c) of $(& $n $subAreas.Count) sub-areas differ" } else { "$(& $n $subAreas.Count) sub-areas — matches" } } },
        @{ check = 'area.unmapped';          label = 'Selected source areas without target placement'; result = { if ($unmappedAreas.Count) { "$(& $n $unmappedAreas.Count) area$(if ($unmappedAreas.Count -ne 1) { 's' }) differ" } else { '0 areas — matches' } } },
        @{ check = 'tag.disallowed';         label = 'Tags: machine-generated families';           result = { if ($families.Count) { "$($families.Count) families, $(& $n $famTags) tags on $(& $n $famItems) work items" } else { 'none — matches' } } },
        @{ check = 'tag.boardColumn';        label = 'Tags that become board columns';             result = { if ($asColumn.Count) { "$(& $n $asColumn.Count) tags" } else { 'none declared yet' } } },
        @{ check = 'tag.retire';             label = 'Tags to retire outright';                    result = { if ($toRetire.Count) { "$(& $n $toRetire.Count) tags" } else { 'none declared yet' } } },
        @{ check = 'tag.unsanctioned';       label = 'Tags with no destination decided';           result = { if ($unsanct.Count) { "$(& $n $unsanct.Count) tags" } else { 'none — matches' } } },
        @{ check = 'repo.orphan';            label = 'Repositories not authored';                  result = { if (-not $reposDecl) { 'not checked — no repository filter declared' } elseif ($repoOrph.Count) { "$(& $n $repoOrph.Count) of $(& $n @($data.repos).Count) repos differ" } else { "matches — $(& $n @($data.repos).Count) repos, all authored" } } },
        @{ check = 'member.unresolvable';    label = 'Authored people the target cannot resolve';  result = { if ($unresolved.Count) { "$(& $n $unresolved.Count) of $(& $n $authoredN) differ" } elseif ($authoredN -eq 1) { 'matches — 1 authored, resolves' } else { "matches — $(& $n $authoredN) authored, all resolve" } } },
        @{ check = 'member.unauthored';      label = 'People in the source team today, not authored'; result = { if (-not $teamsDecl) { 'not checked — no source teams declared' } elseif ($unauth.Count) { "$(& $n $unauth.Count) of $(& $n @($data.population.Keys).Count) differ" } else { "matches — $(& $n @($data.population.Keys).Count) people, all authored" } } }
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
    if ($Reporting -and $Reporting.glossary) { $L.Add((& $prose $Reporting.glossary)); $L.Add('') }
    if ($notChecked.Count) {
        $decl = @(if (-not $teamsDecl) { "the team's source team(s)" }; if (-not $reposDecl) { 'its repository filter' })
        $L.Add("To run the check$(if ($notChecked.Count -gt 1) { 's' }) marked ""not checked"", declare $($decl -join ' and ')."); $L.Add('')
    }

    # 1. Area paths
    $L.Add("## 1. Area paths that fold to tags — $(& $n (& $count 'area.orphan')) of $(& $n $subAreas.Count) sub-areas"); $L.Add('')
    $L.Add('In the proposed target, an area path means one thing: who answers for the work. A sub-area that is authored has a node to land on; one that is not folds — to a tag, or to nothing. Work items are those sitting directly on each path.'); $L.Add('')
    $areaRows = foreach ($a in ($areas | Sort-Object { -[long]$_.workItems }, { [string]$_.source })) {
        $src = [string]$a.source
        $st  = if ($src -eq $srcRoot)            { 'the team root' }
               elseif ($orphanSet.ContainsKey($src)) { 'folds — not authored' }
               else                              { "authored as ``$([string]$a.target)``" }
        , @((& $n $a.workItems), "``$src``", $st)
    }
    $areaRows += @(foreach ($a in ($unmappedAreas | Sort-Object { -[long]$_.workItems }, { [string]$_.source })) {
        , @((& $n $a.workItems), "``$($a.source)``", 'outside source root — target placement required')
    })
    & $table @('Work items', 'Area path today', 'In the target') @($areaRows)

    # 2. Tags
    $L.Add("## 2. Tags — $(& $n @($data.tags.Keys).Count) distinct tags in use"); $L.Add('')
    # Sub-sections are lettered as they appear, so an empty one leaves no gap.
    $sub = [ref][int][char]'a'
    $next = { $c = [char]$sub.Value; $sub.Value++; "2$c" }
    $L.Add("### $(& $next). Machine-generated families"); $L.Add('')
    if ($families.Count -eq 0) { $L.Add('None matched a disallowed pattern.'); $L.Add('') }
    else {
        $L.Add('Each row is one disallowed pattern. These are reported as families because no one applied them by hand, and the programme removes them as families.'); $L.Add('')
        # @() keeps a single family as one row; a bare assignment unrolls it into cells.
        $famRows = @(foreach ($f in ($families | Sort-Object { -[long]$_.tags })) { , @("``$($f.subject)``", (& $n $f.tags), (& $n $f.workItems), (@($f.examples | Select-Object -First 3) -join ', ')) })
        & $table @('Pattern', 'Distinct tags', 'Work items', 'Examples') @($famRows)
    }
    if ($asColumn.Count -gt 0) {
        $L.Add("### $(& $next). Tags that become board columns — $(& $n $asColumn.Count)"); $L.Add('')
        $L.Add('These name where work has got to, not what it is. A board column carries that, and the tag stops being applied once the column exists — so this is a board change, not a vocabulary decision.'); $L.Add('')
        & $table @('Uses', 'Tag') @(foreach ($t in ($asColumn | Sort-Object { -[long]$_.workItems }, { [string]$_.subject })) { , @((& $n $t.workItems), $t.subject) })
    }
    if ($toRetire.Count -gt 0) {
        $L.Add("### $(& $next). Tags to retire outright — $(& $n $toRetire.Count)"); $L.Add('')
        $L.Add('Declared for removal with no replacement. Nothing depends on them.'); $L.Add('')
        & $table @('Uses', 'Tag') @(foreach ($t in ($toRetire | Sort-Object { -[long]$_.workItems }, { [string]$_.subject })) { , @((& $n $t.workItems), $t.subject) })
    }
    $L.Add("### $(& $next). Tags with no destination decided — $(& $n $unsanct.Count)"); $L.Add('')
    $none = if ($asColumn.Count -eq 0 -and $toRetire.Count -eq 0) { ' No tags have yet been declared as board columns or for retirement.' } else { '' }
    $L.Add("Each of these needs one of three answers: **sanction** it into the vocabulary, make it a **board column**, or **retire** it. Anything still undecided at migration shows up on the target's audit from day one, so it is worth deciding first.$none"); $L.Add('')
    if ($unsanct.Count -gt 0) {
        $buckets = [ordered]@{ '1 work item' = 0; '2 to 5' = 0; '6 to 20' = 0; '21 to 50' = 0; 'more than 50' = 0 }
        foreach ($t in $unsanct) {
            $w = [long]$t.workItems
            $k = if ($w -le 1) { '1 work item' } elseif ($w -le 5) { '2 to 5' } elseif ($w -le 20) { '6 to 20' } elseif ($w -le 50) { '21 to 50' } else { 'more than 50' }
            $buckets[$k]++
        }
        & $table @('Used on', 'Distinct tags') @(foreach ($k in $buckets.Keys) { , @($k, (& $n $buckets[$k])) })
        $cands = @($unsanct | Where-Object { [long]$_.workItems -gt $threshold } | Sort-Object { -[long]$_.workItems }, { [string]$_.subject })
        $L.Add("Tags used on more than $(& $n $threshold) work items — we suggest deciding these first ($(& $n $cands.Count)):"); $L.Add('')
        if ($cands.Count -gt 0) { & $table @('Uses', 'Tag') @(foreach ($t in $cands) { , @((& $n $t.workItems), $t.subject) }) }
        else { $L.Add('None.'); $L.Add('') }
    }
    if ($sanctionedUnused.Count -gt 0) {
        $L.Add("Sanctioned tags not yet in use here, created in the target automatically: $(($sanctionedUnused | Sort-Object) -join ', ').")
        $L.Add('')
    }

    # 3. People
    $L.Add('## 3. People'); $L.Add('')
    if ($unresolved.Count -eq 0) {
        if ($authoredN -eq 1) { $L.Add('The 1 authored person (including team admins) resolves in the target organisation.') }
        else { $L.Add("All $(& $n $authoredN) authored people (including team admins) resolve in the target organisation.") }
    }
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
        $L.Add('Context for the migration mapping, not a gap.'); $L.Add('')
        # Backticked like every other path in this document. Not cosmetic: an
    # iteration path is full of backslashes, and a bare `Petrel\2026\S2\W6` in a
    # markdown table becomes `\S2` and `\W6` — undefined control sequences — the
    # moment anyone renders this to PDF through pandoc/LaTeX. Code spans pass
    # through verbatim.
    & $table @('Work items', 'Iteration path') @(foreach ($i in $iters) { , @((& $n $data.iterations[$i]), "``$i``") })
    }

    # 6. Observations (the only section anyone other than this function writes)
    $L.Add('## 6. Observations'); $L.Add('')
    if ($Reporting -and $Reporting.observationsLead) { $L.Add((& $prose $Reporting.observationsLead)); $L.Add('') }
    $L.Add('<!-- observations:begin -->')
    # Observations comment on a specific analysis. If the findings have been
    # regenerated since the fragment was written, the commentary may contradict
    # the tables above it - which is exactly how a report ends up arguing with
    # itself - so it is WITHHELD rather than spliced. Modification time is the
    # test on purpose: a confused writer cannot forge it the way it could forge
    # a stamp inside the file.
    $obsStale = $false
    if ($ObservationsPath -and (Test-Path -LiteralPath $ObservationsPath)) {
        $obsStale = (Get-Item -LiteralPath $ObservationsPath).LastWriteTimeUtc -lt (Get-Item -LiteralPath $FindingsPath).LastWriteTimeUtc
    }
    if ($ObservationsPath -and (Test-Path -LiteralPath $ObservationsPath) -and -not $obsStale) {
        $frag = (Get-Content -LiteralPath $ObservationsPath -Raw) -replace "`r`n", "`n"
        foreach ($line in ($frag.Trim() -split "`n")) { $L.Add($line) }
    } elseif ($obsStale) {
        $L.Add("_Observations withheld: ``$(Split-Path -Leaf $ObservationsPath)`` was written before the current analysis, so it may contradict the tables above. Re-run the observation step, or delete the file._")
    } else {
        $L.Add('_No observations were generated for this report._')
    }
    $L.Add('<!-- observations:end -->')
    $L.Add('')

    # The per-check "what this team owes" list was dropped: it repeated the
    # Summary table row for row, with the same labels.

    # Appendix A. The exact selection and patterns, so the tables above can be
    # reproduced. Kept out of the header because a WIQL block is not a sentence.
    if ($hasQuery -or $families.Count -gt 0) {
        $L.Add('## Appendix A — Query and tag patterns'); $L.Add('')
        if ($hasQuery) {
            $L.Add("**Query (WIQL)** used for this check, as run on $($gatheredDate):"); $L.Add('')
            $L.Add('```sql')
            foreach ($line in (([string]$data.scope.query).Trim() -split "`r?`n")) { $L.Add($line.TrimEnd()) }
            $L.Add('```'); $L.Add('')
        }
        if ($families.Count -gt 0) {
            $L.Add('**Machine-generated tag patterns:**'); $L.Add('')
            & $table @('Pattern') @(foreach ($f in ($families | Sort-Object { -[long]$_.tags })) { , @("``$($f.subject)``") })
        }
    }

    $L.Add('---')
    $L.Add("_Rendered by NKDAgility.AzureDevOps.Governance from ``$(Split-Path -Leaf $DataPath)`` and ``$(Split-Path -Leaf $FindingsPath)``. Every number above is copied from those files; the framing notes are maintained by hand in the program's reporting settings, and they and the Observations section are the only prose written by anyone else._")
    $L.Add('')

    $outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutputPath, ($L -join "`n"), [System.Text.UTF8Encoding]::new($false))
    return $OutputPath
}
