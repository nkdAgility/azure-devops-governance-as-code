function Get-GovernancePreflightModel {
    <#
        .SYNOPSIS
        The facts a templated preflight report may quote (ADR-014), built from
        the same data and findings documents the fixed renderer reads. Every
        list is sorted here, once, so a template never decides an order and
        re-rendering unchanged inputs produces unchanged bytes.

        Lists are sorted largest first by work items, then by name (culture,
        case-insensitive — the order a reader expects).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Findings,
        [object]$Source = $null,          # this node's sources.yaml entry (for contacts)
        [System.Collections.IDictionary]$Notes = @{}
    )

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $byCheck = @{}
    foreach ($f in @($Findings.findings)) {
        $k = [string]$f.check
        if (-not $byCheck.ContainsKey($k)) { $byCheck[$k] = [System.Collections.Generic.List[object]]::new() }
        $byCheck[$k].Add($f)
    }
    $of = { param($check) @(if ($byCheck.ContainsKey($check)) { $byCheck[$check] }) }
    $orgName = { param($url) ([string]$url).TrimEnd('/') -replace '^.*/', '' }

    $srcRoot = [string]$Data.source.areaPath
    $parent  = $srcRoot.Substring(0, [Math]::Max(0, $srcRoot.LastIndexOf('\')))
    $rel     = { param($p) $p = [string]$p; if ($p -eq $srcRoot) { '' } elseif ($p.StartsWith("$srcRoot\")) { $p.Substring($srcRoot.Length + 1) } else { $p } }
    $short   = { param($p) $p = [string]$p; if ($parent -and $p.StartsWith("$parent\")) { $p.Substring($parent.Length + 1) } else { $p.TrimStart('\') } }
    $row     = { param($a) [ordered]@{ source = [string]$a.source; target = [string]$a.target; workItems = [long]$a.workItems; rel = (& $rel $a.source); short = (& $short $a.source) } }

    $areas   = @($Data.areas | ForEach-Object { & $row $_ })
    $orphanSources = @{}; foreach ($f in (& $of 'area.orphan')) { $orphanSources[[string]$f.source] = $true }
    $byWork  = { param($items, $name) @($items | Sort-Object @{ Expression = { $_.workItems }; Descending = $true }, @{ Expression = { $_[$name] } }) }

    $gathered = if ($Data.gathered -is [datetime]) { ([datetime]$Data.gathered).ToUniversalTime() }
                else { $t = [datetime]::MinValue; [void][datetime]::TryParse([string]$Data.gathered, $inv, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$t); $t }

    $contacts = [ordered]@{}
    if ($Source -and $Source.contacts) { foreach ($k in @($Source.contacts.Keys)) { $contacts[[string]$k] = if ($null -eq $Source.contacts[$k]) { '' } else { [string]$Source.contacts[$k] } } }

    $tagRows = @(foreach ($k in @($Data.tags.Keys)) { [ordered]@{ name = [string]$k; workItems = [long]$Data.tags[$k] } })
    $iterRows = @(foreach ($k in @($Data.iterations.Keys)) { [ordered]@{ path = [string]$k; leaf = ([string]$k -replace '^.*\\', ''); workItems = [long]$Data.iterations[$k] } })

    return [ordered]@{
        team = [ordered]@{
            code          = [string]$Data.node
            name          = ($srcRoot -replace '^.*\\', '')
            areaPath      = $srcRoot
            sourceOrg     = (& $orgName $Data.source.org)
            sourceProject = [string]$Data.source.project
            targetOrg     = (& $orgName $Data.target.org)
            targetProject = [string]$Data.target.project
            targetRoot    = [string]$Data.target.root
        }
        gathered  = $gathered.ToString('d MMMM yyyy', $inv)
        scope     = [ordered]@{ label = [string]$Data.scope.label; query = [string]$Data.scope.query }
        workItems = [long]$Data.workItems.count
        contacts  = $contacts
        areas     = [ordered]@{
            all      = $areas
            subCount = @($areas | Where-Object { $_.source -ne $srcRoot }).Count
            inPlace  = @($areas | Where-Object { -not $orphanSources.ContainsKey($_.source) } | Sort-Object { $_.short })
            orphans  = (& $byWork @($areas | Where-Object { $orphanSources.ContainsKey($_.source) }) 'source')
            unmapped = @((& $of 'area.unmapped') | ForEach-Object { [ordered]@{ source = [string]$_.source; workItems = [long]$_.workItems } })
        }
        tags = [ordered]@{
            inUse        = (& $byWork $tagRows 'name')
            undecided    = (& $byWork @((& $of 'tag.unsanctioned') | ForEach-Object { [ordered]@{ name = [string]$_.subject; workItems = [long]$_.workItems } }) 'name')
            families     = @((& $of 'tag.disallowed') | ForEach-Object { [ordered]@{ pattern = [string]$_.subject; tags = [long]$_.tags; workItems = [long]$_.workItems } })
            boardColumns = @((& $of 'tag.boardColumn') | ForEach-Object { [ordered]@{ name = [string]$_.subject; workItems = [long]$_.workItems } })
            retire       = @((& $of 'tag.retire') | ForEach-Object { [ordered]@{ name = [string]$_.subject; workItems = [long]$_.workItems } })
        }
        iterations = (& $byWork $iterRows 'path')
        members = [ordered]@{
            authored            = @($Data.authored.members).Count + @($Data.authored.teamAdmins).Count
            unresolvable        = @(@(& $of 'member.unresolvable') + @(& $of 'teamAdmin.unresolvable') | ForEach-Object { [ordered]@{ name = [string]$_.subject } })
            unauthored          = @((& $of 'member.unauthored') | ForEach-Object { [ordered]@{ name = [string]$_.subject } })
            sourceTeamsDeclared = (@($Data.source.teams | Where-Object { $_ }).Count -gt 0)
        }
        repos = [ordered]@{
            declared = ($null -ne $Data.source.repoInclude)
            orphans  = @((& $of 'repo.orphan') | ForEach-Object { [ordered]@{ name = [string]$_.subject } })
        }
        notes = $Notes
    }
}

function Read-GovernanceTemplateSections {
    # '<!-- <kind>: name -->' starts a section; it runs to the next marker or
    # the end. Leading/trailing blank lines are trimmed, so sections can be
    # spaced out in the file without the spacing reaching the report.
    param([string]$Text, [string]$Kind)
    $Text = $Text -replace "`r`n", "`n"
    $out = [ordered]@{}
    $rx = [regex]"(?m)^<!--\s*$($Kind):\s*([\w.\-]+)\s*-->[ \t]*\n?"
    $ms = $rx.Matches($Text)
    for ($i = 0; $i -lt $ms.Count; $i++) {
        $start = $ms[$i].Index + $ms[$i].Length
        $end = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $Text.Length }
        $name = $ms[$i].Groups[1].Value
        if ($out.Contains($name)) { throw "Duplicate $Kind '$name'" }
        $out[$name] = ($Text.Substring($start, $end - $start) -replace '^(\s*\n)+', '').TrimEnd()
    }
    return $out
}

function ConvertTo-GovernancePreflightTemplateReport {
    <#
        .SYNOPSIS
        Renders a team's preflight report by filling the program's own document
        with that team's facts (ADR-014). The document (a team-facing standard,
        say) carries markers; the program's slots file says, in the placeholder
        language of Expand-GovernanceTemplate, what goes at each marker; this
        function supplies the numbers. Nothing program-specific lives here.

        Markers in the document, invisible when the document is published
        on its own:
          <!-- team:replace NAME --> … <!-- team:end -->
                 the lines between are replaced by slot NAME
          <!-- team:slot NAME -->
                 replaced by slot NAME — inline if it shares a line with text,
                 as whole lines if it is alone on its line
          <!-- team:check NAME -->   (at the end of a '- [ ]' checklist item)
                 slot NAME starts with [x] or [ ], which sets the box; the
                 rest follows the item's text, further lines follow the item
          <!-- team:fill COLUMN ROWPREFIX -->
                 in the table that follows, cell COLUMN (1-based) of each body
                 row becomes slot ROWPREFIX.<first cell>
          <!-- team:column HEADER SEPARATOR ROWPREFIX -->
                 the table that follows gains a column: slot HEADER is its
                 heading, slot SEPARATOR replaces the separator row, and each
                 body row gets slot ROWPREFIX.<first cell>

        Notes (the team's observations file, sections '<!-- note: NAME -->')
        are available as {{note NAME}}. Notes older than the findings are
        withheld, exactly as the fixed renderer withholds stale observations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$DocumentPath,
        [Parameter(Mandatory)][string]$SlotsPath,
        [string]$NotesPath = '',
        [string]$OutputPath = '',
        [string]$AssetPrefix = '',
        [object]$Source = $null,
        [object]$Reporting = $null
    )

    foreach ($p in $DataPath, $FindingsPath, $DocumentPath, $SlotsPath) {
        if (-not (Test-Path -LiteralPath $p)) { throw "ConvertTo-GovernancePreflightTemplateReport: input not found: $p" }
    }
    $data = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    $fin  = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if ([string]$data.schema -ne 'nkdagility.governance.preflight-data/1') { throw "'$DataPath' is not a preflight data document this engine understands (schema '$($data.schema)')." }
    if ([string]$fin.mode -ne 'Preflight') { throw "'$FindingsPath' is a '$($fin.mode)' report, not a preflight findings document." }

    $notes = @{}
    if ($NotesPath -and (Test-Path -LiteralPath $NotesPath)) {
        $stale = (Get-Item -LiteralPath $NotesPath).LastWriteTimeUtc -lt (Get-Item -LiteralPath $FindingsPath).LastWriteTimeUtc
        if ($stale) { Write-Warning "Notes withheld: '$(Split-Path -Leaf $NotesPath)' was written before the current analysis." }
        else { $notes = Read-GovernanceTemplateSections -Text (Get-Content -LiteralPath $NotesPath -Raw) -Kind 'note' }
    }
    $model = Get-GovernancePreflightModel -Data $data -Findings $fin -Source $Source -Notes $notes
    $slots = Read-GovernanceTemplateSections -Text (Get-Content -LiteralPath $SlotsPath -Raw) -Kind 'slot'
    $slot  = {
        param($name)
        if (-not $slots.Contains($name)) { throw "Slots file '$SlotsPath' has no slot '$name'" }
        (Expand-GovernanceTemplate -Template $slots[$name] -Model $model).TrimEnd("`n")
    }

    $doc = (Get-Content -LiteralPath $DocumentPath -Raw) -replace "`r`n", "`n"
    $doc = $doc -replace '^(?s)---\n.*?\n---\n', ''
    $lines = $doc -split "`n"
    $out = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -match '^\s*<!--\s*team:replace\s+([\w.\-]+)\s*-->\s*$') {
            $name = $Matches[1]
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\s*<!--\s*team:end\s*-->\s*$') { $j++ }
            if ($j -ge $lines.Count) { throw "Document '$DocumentPath': team:replace $name has no team:end" }
            foreach ($l in ((& $slot $name) -split "`n")) { $out.Add($l) }
            $i = $j + 1; continue
        }
        if ($line -match '^\s*<!--\s*team:column\s+([\w.\-]+)\s+([\w.\-]+)\s+([\w.\-]+)\s*-->\s*$') {
            $hdr = & $slot $Matches[1]; $sep = & $slot $Matches[2]; $prefix = $Matches[3]
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\|') {
                if ($lines[$j].Trim()) { throw "Document '$DocumentPath': team:column must be followed by its table" }
                $j++
            }
            if ($j -ge $lines.Count) { throw "Document '$DocumentPath': team:column is not followed by a table" }
            $out.Add("$($lines[$j]) $hdr |"); $j++
            $out.Add($sep); $j++
            while ($j -lt $lines.Count -and $lines[$j] -match '^\|') {
                $key = ($lines[$j] -split '\|')[1].Trim()
                $out.Add("$($lines[$j]) $(& $slot "$prefix.$key") |"); $j++
            }
            $i = $j; continue
        }
        if ($line -match '^\s*<!--\s*team:fill\s+(\d+)\s+([\w.\-]+)\s*-->\s*$') {
            $col = [int]$Matches[1]; $prefix = $Matches[2]
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\|') {
                if ($lines[$j].Trim()) { throw "Document '$DocumentPath': team:fill must be followed by its table" }
                $j++
            }
            if ($j + 1 -ge $lines.Count) { throw "Document '$DocumentPath': team:fill is not followed by a table" }
            $out.Add($lines[$j]); $out.Add($lines[$j + 1]); $j += 2
            while ($j -lt $lines.Count -and $lines[$j] -match '^\|') {
                $cells = $lines[$j] -split '\|'
                if ($col -lt 1 -or $col -ge $cells.Count - 1) { throw "Document '$DocumentPath': team:fill column $col is outside the table" }
                $cells[$col] = " $(& $slot "$prefix.$($cells[1].Trim())") "
                $out.Add($cells -join '|'); $j++
            }
            $i = $j; continue
        }
        if ($line -match '^(?<lead>\s*[-*] )\[[ xX]\] (?<text>.*?)\s*<!--\s*team:check\s+(?<name>[\w.\-]+)\s*-->\s*$') {
            # A checklist item: the slot's first line starts with [x] or [ ],
            # which sets the box; the rest of that line follows the item's
            # text, and any further lines follow the item.
            $lead = $Matches.lead; $text = $Matches.text; $name = $Matches.name
            $exp = (& $slot $name) -split "`n"
            if ($exp[0] -notmatch '^\[(?<box>[ x])\]\s?(?<rest>.*)$') { throw "Slot '$name' must start with [x] or [ ] (it sets a checklist box)" }
            $first = "$lead[$($Matches.box)] $text"
            if ($Matches.rest) { $first += " $($Matches.rest)" }
            $out.Add($first)
            for ($k = 1; $k -lt $exp.Count; $k++) { $out.Add($exp[$k]) }
            $i++; continue
        }
        if ($line -match '^\s*<!--\s*team:slot\s+([\w.\-]+)\s*-->\s*$') {
            foreach ($l in ((& $slot $Matches[1]) -split "`n")) { $out.Add($l) }
            $i++; continue
        }
        $line = [regex]::Replace($line, '\s*<!--\s*team:slot\s+([\w.\-]+)\s*-->', { param($m) ' ' + (& $slot $m.Groups[1].Value) })
        if ($AssetPrefix) { $line = $line.Replace('](assets/', "]($($AssetPrefix)assets/") }
        $out.Add($line)
        $i++
    }
    $body = ($out -join "`n") -replace '^\n+', ''
    $leftover = [regex]::Match($body, '<!--\s*team:[^>]*-->')
    if ($leftover.Success) { throw "Document '$DocumentPath': unrecognised team marker '$($leftover.Value)'" }

    # Frontmatter, as the fixed renderer emits it (ADR-009): reporting.frontmatter
    # with {code} filled in, keys in ordinal order, date = the data's date.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $fmLines = [System.Collections.Generic.List[string]]::new()
    $fm = if ($Reporting) { $Reporting.frontmatter } else { $null }
    if ($fm) {
        $code = [string]$data.node
        $fmKeys = [string[]]@($fm.Keys); [array]::Sort($fmKeys, [System.StringComparer]::Ordinal)
        $fmLines.Add('---')
        foreach ($k in $fmKeys) {
            $v = $fm[$k]
            $s = if ($v -is [bool]) { if ($v) { 'true' } else { 'false' } }
                 elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { [string]$v }
                 else { '"' + ([string]$v).Replace('{code}', $code).Replace('\', '\\').Replace('"', '\"') + '"' }
            $fmLines.Add("$($k): $s")
        }
        if ('date' -notin $fmKeys) {
            $g = if ($data.gathered -is [datetime]) { ([datetime]$data.gathered).ToUniversalTime() } else { [datetime]::Parse([string]$data.gathered, $inv) }
            $fmLines.Add("date: $($g.ToString('yyyy-MM-dd', $inv))")
        }
        $fmLines.Add('---')
        $fmLines.Add('')
    }

    if (-not $OutputPath) {
        $stem = [System.IO.Path]::GetFileName($DataPath) -replace '[-.]?data\.json$', ''
        $OutputPath = Join-Path ([System.IO.Path]::GetDirectoryName($DataPath)) "$stem-report.md"
    }
    $text = (($fmLines -join "`n") + $(if ($fmLines.Count) { "`n" } else { '' }) + $body)
    [System.IO.File]::WriteAllText($OutputPath, $text, [System.Text.UTF8Encoding]::new($false))
    return $OutputPath
}
