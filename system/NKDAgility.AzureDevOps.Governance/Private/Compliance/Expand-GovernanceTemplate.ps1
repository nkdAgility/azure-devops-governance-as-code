function Expand-GovernanceTemplate {
    <#
        .SYNOPSIS
        Expands a small placeholder language against a model (ADR-014). The
        language is deliberately tiny: the program owns the wording, the engine
        owns the numbers, and nothing in between should be clever enough to
        need a debugger.

        Placeholders:
          {{path}}                         a value from the model ('.field' or
                                           'this' inside a loop; 'a.x'/'b.x' in zip)
          {{count path [where=…]}}         number of items in a list
          {{sum path field [where=…]}}     sum of a numeric field over a list
          {{words …}} / {{Words …}}        a number 0–20 as a word (capitalised)
          {{note name}}                    a section of the team's notes file
          {{#each path [limit=N] [where=…]}} … {{/each}}
                                           loop; @first, @last, @index inside
          {{#zip a=path [awhere=…] b=path [bwhere=…]}} … {{/zip}}
                                           two lists side by side; a or b is
                                           empty when its list has run out
          {{#if expr}} … {{else}} … {{/if}} / {{#unless expr}} … {{/unless}}
                                           expr is any value above, optionally
                                           followed by == N, > N or < N

        where= takes field~regex, field!~regex, field=N, field>N or field<N.

        A block tag alone on its line takes the whole line with it, so the
        template can be laid out readably without leaving blank lines behind.
        An unknown helper, an unclosed block or a path that does not exist
        throws: a report that silently drops a number is worse than no report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Model
    )

    $tokens = Split-GovernanceTemplate -Template $Template
    $pos = 0
    $tree = Read-GovernanceTemplateBlock -Tokens $tokens -Position ([ref]$pos) -Closer $null
    $sb = [System.Text.StringBuilder]::new()
    Write-GovernanceTemplateNodes -Nodes $tree.Body -Scope @(@{}) -Model $Model -Out $sb
    return $sb.ToString()
}

function Split-GovernanceTemplate {
    # Text and tag tokens. A block tag ({{#…}}, {{/…}}, {{else}}) that is the
    # only thing on its line swallows that line's indentation and newline.
    param([string]$Template)
    $Template = $Template -replace "`r`n", "`n"
    $list = [System.Collections.Generic.List[object]]::new()
    $rx = [regex]'\{\{(.*?)\}\}'
    $last = 0
    foreach ($m in $rx.Matches($Template)) {
        $inner = $m.Groups[1].Value.Trim()
        $isBlock = $inner -match '^(#|/|else$)'
        $start = $m.Index; $end = $m.Index + $m.Length
        if ($isBlock) {
            $lineStart = if ($start -eq 0) { 0 } else { $Template.LastIndexOf("`n", $start - 1) + 1 }
            $lineEnd = $Template.IndexOf("`n", $end)
            $before = $Template.Substring($lineStart, $start - $lineStart)
            $after  = if ($lineEnd -lt 0) { $Template.Substring($end) } else { $Template.Substring($end, $lineEnd - $end) }
            if ($lineStart -ge $last -and $before.Trim() -eq '' -and $after.Trim() -eq '') {
                $start = $lineStart
                $end = if ($lineEnd -lt 0) { $Template.Length } else { $lineEnd + 1 }
            }
        }
        if ($start -gt $last) { $list.Add(@{ Kind = 'text'; Value = $Template.Substring($last, $start - $last) }) }
        $list.Add(@{ Kind = 'tag'; Value = $inner })
        $last = $end
    }
    if ($last -lt $Template.Length) { $list.Add(@{ Kind = 'text'; Value = $Template.Substring($last) }) }
    return , $list
}

function Read-GovernanceTemplateBlock {
    param($Tokens, [ref]$Position, $Closer)
    $body = [System.Collections.Generic.List[object]]::new()
    $else = $null
    $current = $body
    while ($Position.Value -lt $Tokens.Count) {
        $t = $Tokens[$Position.Value]; $Position.Value++
        if ($t.Kind -eq 'text') { $current.Add(@{ Kind = 'text'; Value = $t.Value }); continue }
        $v = $t.Value
        if ($v -eq 'else') {
            if ($Closer -notin 'if', 'unless') { throw "Template: {{else}} outside an {{#if}} or {{#unless}} block" }
            $else = [System.Collections.Generic.List[object]]::new(); $current = $else; continue
        }
        if ($v.StartsWith('/')) {
            $name = $v.Substring(1).Trim()
            if ($name -ne $Closer) { throw "Template: {{/$name}} closes a block that was not opened (expected {{/$Closer}})" }
            return @{ Body = $body; Else = $else }
        }
        if ($v.StartsWith('#')) {
            $parts = $v.Substring(1).Trim() -split '\s+', 2
            $kind = $parts[0]
            if ($kind -notin 'each', 'if', 'unless', 'zip') { throw "Template: unknown block {{#$kind}}" }
            $inner = Read-GovernanceTemplateBlock -Tokens $Tokens -Position $Position -Closer $kind
            $current.Add(@{ Kind = $kind; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); Body = $inner.Body; Else = $inner.Else })
            continue
        }
        $current.Add(@{ Kind = 'var'; Value = $v })
    }
    if ($Closer) { throw "Template: {{#$Closer}} is never closed" }
    return @{ Body = $body; Else = $else }
}

function Write-GovernanceTemplateNodes {
    param($Nodes, $Scope, $Model, [System.Text.StringBuilder]$Out)
    foreach ($n in $Nodes) {
        switch ($n.Kind) {
            'text' { [void]$Out.Append($n.Value) }
            'var'  {
                $val = Get-GovernanceTemplateValue -Expr $n.Value -Scope $Scope -Model $Model
                [void]$Out.Append((Format-GovernanceTemplateScalar $val))
            }
            { $_ -in 'if', 'unless' } {
                $truth = Test-GovernanceTemplateCondition -Expr $n.Args -Scope $Scope -Model $Model
                if ($n.Kind -eq 'unless') { $truth = -not $truth }
                $branch = if ($truth) { $n.Body } else { $n.Else }
                if ($branch) { Write-GovernanceTemplateNodes -Nodes $branch -Scope $Scope -Model $Model -Out $Out }
            }
            'each' {
                $a = ConvertFrom-GovernanceTemplateArgs $n.Args
                $items = @(Select-GovernanceTemplateList -Path $a.Positional[0] -Where $a.where -Scope $Scope -Model $Model)
                if ($a.limit) { $items = @($items | Select-Object -First ([int]$a.limit)) }
                for ($i = 0; $i -lt $items.Count; $i++) {
                    $frame = @{ this = $items[$i]; '@index' = $i; '@first' = ($i -eq 0); '@last' = ($i -eq $items.Count - 1) }
                    Write-GovernanceTemplateNodes -Nodes $n.Body -Scope (@($frame) + $Scope) -Model $Model -Out $Out
                }
            }
            'zip' {
                $a = ConvertFrom-GovernanceTemplateArgs $n.Args
                if (-not $a.a -or -not $a.b) { throw "Template: {{#zip}} needs a=<list> and b=<list>" }
                $la = @(Select-GovernanceTemplateList -Path $a.a -Where $a.awhere -Scope $Scope -Model $Model)
                $lb = @(Select-GovernanceTemplateList -Path $a.b -Where $a.bwhere -Scope $Scope -Model $Model)
                $rows = [Math]::Max($la.Count, $lb.Count)
                for ($i = 0; $i -lt $rows; $i++) {
                    $frame = @{
                        a = $(if ($i -lt $la.Count) { $la[$i] } else { $null })
                        b = $(if ($i -lt $lb.Count) { $lb[$i] } else { $null })
                        '@index' = $i; '@first' = ($i -eq 0); '@last' = ($i -eq $rows - 1)
                    }
                    Write-GovernanceTemplateNodes -Nodes $n.Body -Scope (@($frame) + $Scope) -Model $Model -Out $Out
                }
            }
        }
    }
}

function ConvertFrom-GovernanceTemplateArgs {
    param([string]$Text)
    $named = @{}; $pos = [System.Collections.Generic.List[string]]::new()
    foreach ($w in ($Text.Trim() -split '\s+' | Where-Object { $_ })) {
        if ($w -match '^(limit|where|a|b|awhere|bwhere)=(.*)$') { $named[$Matches[1]] = $Matches[2] } else { $pos.Add($w) }
    }
    $named['Positional'] = $pos
    return $named
}

function Resolve-GovernanceTemplatePath {
    # A dotted path, looked up first in the loop frames then in the model.
    # '.field' and 'this.field' are the current item. Missing → throw.
    param([string]$Path, $Scope, $Model)
    if ($Path.StartsWith('.')) { $Path = "this$Path" }
    $segments = $Path -split '\.'
    $head = $segments[0]
    $found = $false; $value = $null
    foreach ($frame in $Scope) {
        if ($frame.ContainsKey($head)) { $value = $frame[$head]; $found = $true; break }
    }
    if (-not $found) {
        if (-not $Model.Contains($head)) { throw "Template: '$Path' is not in the report model" }
        $value = $Model[$head]
    }
    for ($i = 1; $i -lt $segments.Count; $i++) {
        if ($null -eq $value) { return $null }      # a/b in a zip after its list ran out
        $seg = $segments[$i]
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($seg)) {
                # contacts are keyed by the program, not the engine: absent = not recorded yet.
                if ($segments[0] -eq 'contacts') { return '' }
                throw "Template: '$Path' — no field '$seg'"
            }
            $value = $value[$seg]
        } else {
            $prop = $value.PSObject.Properties[$seg]
            if (-not $prop) { throw "Template: '$Path' — no field '$seg'" }
            $value = $prop.Value
        }
    }
    return $value
}

function Get-GovernanceTemplateField {
    param($Item, [string]$Field)
    if ($Item -is [System.Collections.IDictionary]) {
        if (-not $Item.Contains($Field)) { throw "Template: where= field '$Field' is not on the list items" }
        return $Item[$Field]
    }
    $p = $Item.PSObject.Properties[$Field]
    if (-not $p) { throw "Template: where= field '$Field' is not on the list items" }
    return $p.Value
}

function Select-GovernanceTemplateList {
    param([string]$Path, [string]$Where, $Scope, $Model)
    if (-not $Path) { throw "Template: a list path is required" }
    $list = Resolve-GovernanceTemplatePath -Path $Path -Scope $Scope -Model $Model
    if ($null -eq $list) { return @() }
    $items = @($list)
    if (-not $Where) { return $items }
    if ($Where -notmatch '^(?<f>[\w@]+)(?<op>!~|~|=|>|<)(?<v>.*)$') { throw "Template: cannot read where=$Where" }
    $f = $Matches.f; $op = $Matches.op; $v = $Matches.v
    return @($items | Where-Object {
        $x = Get-GovernanceTemplateField -Item $_ -Field $f
        switch ($op) {
            '~'  { [string]$x -match $v }
            '!~' { [string]$x -notmatch $v }
            '='  { [string]$x -eq $v }
            '>'  { [double]$x -gt [double]$v }
            '<'  { [double]$x -lt [double]$v }
        }
    })
}

function Get-GovernanceTemplateValue {
    param([string]$Expr, $Scope, $Model)
    $words = $Expr -split '\s+'
    switch -CaseSensitive ($words[0]) {
        'words' { return (ConvertTo-GovernanceNumberWord (Get-GovernanceTemplateValue ($words[1..($words.Count - 1)] -join ' ') $Scope $Model) $false) }
        'Words' { return (ConvertTo-GovernanceNumberWord (Get-GovernanceTemplateValue ($words[1..($words.Count - 1)] -join ' ') $Scope $Model) $true) }
        'count' {
            $a = ConvertFrom-GovernanceTemplateArgs ($words[1..($words.Count - 1)] -join ' ')
            return @(Select-GovernanceTemplateList -Path $a.Positional[0] -Where $a.where -Scope $Scope -Model $Model).Count
        }
        'sum' {
            $a = ConvertFrom-GovernanceTemplateArgs ($words[1..($words.Count - 1)] -join ' ')
            $field = $a.Positional[1]
            if (-not $field) { throw "Template: {{sum <list> <field>}} needs a field" }
            $total = 0
            foreach ($i in @(Select-GovernanceTemplateList -Path $a.Positional[0] -Where $a.where -Scope $Scope -Model $Model)) { $total += [double](Get-GovernanceTemplateField $i $field) }
            return $total
        }
        'note' {
            $notes = $Model['notes']
            if ($notes -and $notes.Contains($words[1])) { return $notes[$words[1]] }
            return ''
        }
    }
    if ($words.Count -gt 1) { throw "Template: unknown helper '$($words[0])' in {{$Expr}}" }
    return (Resolve-GovernanceTemplatePath -Path $Expr -Scope $Scope -Model $Model)
}

function Test-GovernanceTemplateCondition {
    param([string]$Expr, $Scope, $Model)
    $Expr = $Expr.Trim()
    $negate = $false
    if ($Expr.StartsWith('!')) { $negate = $true; $Expr = $Expr.Substring(1).Trim() }
    $result = if ($Expr -match '^(?<lhs>.+?)\s*(?<op>==|>|<)\s*(?<rhs>-?\d+)$') {
        $lhs = [double](Get-GovernanceTemplateValue $Matches.lhs.Trim() $Scope $Model)
        $rhs = [double]$Matches.rhs
        switch ($Matches.op) { '==' { $lhs -eq $rhs } '>' { $lhs -gt $rhs } '<' { $lhs -lt $rhs } }
    } else {
        $v = Get-GovernanceTemplateValue $Expr $Scope $Model
        if ($null -eq $v) { $false }
        elseif ($v -is [bool]) { $v }
        elseif ($v -is [string]) { $v -ne '' }
        elseif ($v -is [System.Collections.IDictionary]) { $v.Count -gt 0 }
        elseif ($v -is [System.Collections.IEnumerable]) { @($v).Count -gt 0 }
        elseif ($v -is [ValueType]) { [double]$v -ne 0 }
        else { $true }
    }
    if ($negate) { return -not $result } else { return [bool]$result }
}

function ConvertTo-GovernanceNumberWord {
    param($Number, [bool]$Capital)
    $n = [int]$Number
    $names = 'zero','one','two','three','four','five','six','seven','eight','nine','ten',
             'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen','twenty'
    $w = if ($n -ge 0 -and $n -le 20) { $names[$n] } else { [string]$n }
    if ($Capital -and $w.Length -gt 0) { $w = $w.Substring(0, 1).ToUpper() + $w.Substring(1) }
    return $w
}

function Format-GovernanceTemplateScalar {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [double] -and $Value -eq [Math]::Floor($Value)) { return ([long]$Value).ToString() }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { throw "Template: a list cannot be printed directly; use {{#each}} or {{count}}" }
    return [string]$Value
}
