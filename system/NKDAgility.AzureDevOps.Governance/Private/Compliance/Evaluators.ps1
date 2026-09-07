# Pure compliance evaluators.
#
# Each function compares a slice of the resolved (desired) model against an
# observed state snapshot and returns the classification — no live calls, no
# console output, no fixes. Invoke-GovernanceReconcile gathers live state and
# acts on the results; Invoke-GovernancePreflight gathers from a team's
# PRE-MIGRATION source location, projects it into target coordinates, and runs
# the very same evaluators. Keeping the rules here, and only here, is what
# guarantees audit and preflight can never disagree about what compliant means.

function Test-GovernanceAreaCompliance {
    <#
        .SYNOPSIS
        Area-path rule: every desired (non-future) path exists; observed paths
        matched against the FULL model (including scope:future placeholders,
        ADR-004) are orphans when unmatched. Orphans come back deepest-first so
        pruning a subtree removes children before parents.

        Observed input:
          LiveDesiredSet — path -> $true for each desired path that exists.
          LiveSubtree    — every observed path (hashtable or string[]); $null
                           or a bare root (<=1 entries) skips orphan detection,
                           matching the reconcile's best-effort bulk fetch.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$DesiredPaths = @(),
        [hashtable]$LiveDesiredSet = @{},
        [AllowEmptyCollection()][string[]]$ModelPaths = @(),
        [object]$LiveSubtree = $null
    )

    $missing = @($DesiredPaths | Where-Object { -not $LiveDesiredSet[$_] })

    $orphans = @()
    $livePaths = if ($LiveSubtree -is [hashtable]) { @($LiveSubtree.Keys) } else { @($LiveSubtree) }
    if ($livePaths.Count -gt 1) {
        $modelSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$ModelPaths, [System.StringComparer]::OrdinalIgnoreCase)
        $orphans = @($livePaths | Where-Object { -not $modelSet.Contains($_) } |
            Sort-Object { ($_ -split '\\').Count } -Descending)
    }

    return @{ Missing = $missing; Orphans = $orphans }
}

function Test-GovernanceRepoCompliance {
    <#
        .SYNOPSIS
        Repo rule: every desired repo exists by exact name; observed repos not
        in the desired set are orphans, except the project default repo (named
        after the project). Case-insensitive on both sides. Orphans sorted.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$DesiredNames = @(),
        [AllowEmptyCollection()][string[]]$LiveNames = @(),
        [Parameter(Mandatory)][string]$Project
    )

    $liveSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$LiveNames, [System.StringComparer]::OrdinalIgnoreCase)
    $missing = @($DesiredNames | Where-Object { -not $liveSet.Contains($_) })

    $desiredSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](@($DesiredNames) + @($Project)), [System.StringComparer]::OrdinalIgnoreCase)
    $orphans = @($LiveNames | Sort-Object | Where-Object { -not $desiredSet.Contains($_) })

    return @{ Missing = $missing; Orphans = $orphans }
}

function Test-GovernanceTagCompliance {
    <#
        .SYNOPSIS
        Tag rule (Decision-0041, ADR-006): disallowed patterns are checked
        FIRST and always win — a sanctioned name matching a disallowed pattern
        is still drift. Observed tags outside the sanctioned vocabulary are
        exceptions; sanctioned tags not observed are missing. Disallowed and
        Unsanctioned come back in sorted observed-tag order, Missing unsorted
        (callers sort for display, as the reconcile always has).

        DisallowedByPattern is the same Disallowed set keyed by the pattern
        that caught each tag (first matching pattern wins, authored order),
        so a caller can report a machine-generated family — build ids,
        session ids — as ONE finding instead of one per tag. Patterns that
        caught nothing are absent.

        BoardColumns and Retire are DISPOSITIONS for tags that are not in the
        vocabulary (ADR-011). A tag naming where work has got to — "test
        passed", "kicked off" — is a board column wearing a tag's clothes, and
        the fix is a column, not a vocabulary entry. A tag that is simply noise
        is retired. Whatever is left is Unsanctioned: in use, not sanctioned,
        and with no destination decided yet — the actual worklist.

        SanctionedPatterns covers families that are legitimately in use but
        cannot be listed by name — a per-season marker mints a new one every
        season. Matches count as OK, never as missing (apply cannot seed a
        pattern) and never as undecided. Each entry is a regex string or
        @{ pattern; note }; SanctionedByPattern groups the matches so a report
        can show the family and say why it is tolerated.

        Precedence: disallowed pattern, then sanctioned name, then sanctioned
        pattern, then board column, then retire, then undecided.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Sanctioned = @(),
        [AllowEmptyCollection()][string[]]$DisallowedPatterns = @(),
        [AllowEmptyCollection()][string[]]$LiveTagNames = @(),
        [AllowEmptyCollection()][string[]]$BoardColumns = @(),
        [AllowEmptyCollection()][string[]]$Retire = @(),
        [AllowEmptyCollection()][object[]]$SanctionedPatterns = @()
    )

    $sanctionedPatternList = @(foreach ($p in $SanctionedPatterns) {
            if ($p -is [System.Collections.IDictionary]) { [pscustomobject]@{ pattern = [string]$p.pattern; note = [string]$p.note } }
            else { [pscustomobject]@{ pattern = [string]$p; note = '' } }
        }) | Where-Object { $_.pattern }

    $liveSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$LiveTagNames, [System.StringComparer]::OrdinalIgnoreCase)
    $sanctionedSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Sanctioned, [System.StringComparer]::OrdinalIgnoreCase)
    $columnSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$BoardColumns, [System.StringComparer]::OrdinalIgnoreCase)
    $retireSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Retire, [System.StringComparer]::OrdinalIgnoreCase)

    $missing      = @($Sanctioned | Where-Object { -not $liveSet.Contains($_) })
    $disallowed   = [System.Collections.Generic.List[string]]::new()
    $byPattern    = [ordered]@{}
    $unsanctioned = [System.Collections.Generic.List[string]]::new()
    $asColumn     = [System.Collections.Generic.List[string]]::new()
    $toRetire     = [System.Collections.Generic.List[string]]::new()
    $bySanctionedPattern = [ordered]@{}
    $okCount      = 0

    foreach ($tagName in ($LiveTagNames | Sort-Object)) {
        $caughtBy = $null
        foreach ($p in $DisallowedPatterns) { if ($tagName -match $p) { $caughtBy = $p; break } }
        if ($caughtBy) {
            $disallowed.Add($tagName)
            if (-not $byPattern.Contains($caughtBy)) { $byPattern[$caughtBy] = [System.Collections.Generic.List[string]]::new() }
            $byPattern[$caughtBy].Add($tagName)
        }
        elseif ($sanctionedSet.Contains($tagName)) { $okCount++ }
        else {
            $okPattern = $null
            foreach ($sp in $sanctionedPatternList) { if ($tagName -match $sp.pattern) { $okPattern = $sp; break } }
            if ($okPattern) {
                $okCount++
                if (-not $bySanctionedPattern.Contains($okPattern.pattern)) {
                    $bySanctionedPattern[$okPattern.pattern] = [pscustomobject]@{
                        note = $okPattern.note; tags = [System.Collections.Generic.List[string]]::new() }
                }
                $bySanctionedPattern[$okPattern.pattern].tags.Add($tagName)
            }
            elseif ($columnSet.Contains($tagName)) { $asColumn.Add($tagName) }
            elseif ($retireSet.Contains($tagName)) { $toRetire.Add($tagName) }
            else                                   { $unsanctioned.Add($tagName) }
        }
    }

    $grouped = [ordered]@{}
    foreach ($p in $byPattern.Keys) { $grouped[$p] = @($byPattern[$p]) }
    $groupedOk = [ordered]@{}
    foreach ($p in $bySanctionedPattern.Keys) {
        $groupedOk[$p] = [ordered]@{ note = $bySanctionedPattern[$p].note; tags = @($bySanctionedPattern[$p].tags) }
    }

    return @{
        Missing             = $missing
        Disallowed          = @($disallowed)
        DisallowedByPattern = $grouped
        SanctionedByPattern = $groupedOk
        BoardColumns        = @($asColumn)
        Retire              = @($toRetire)
        Unsanctioned        = @($unsanctioned)
        OkCount             = $okCount
    }
}

function Test-GovernanceMemberSetCompliance {
    <#
        .SYNOPSIS
        Exact-match membership rule shared by security groups and team
        administrators: every resolved desired entry must be present, and
        every observed entry must be desired. Two deliberate protections:

          - Extras are NEVER reported while any desired entry failed to
            resolve (-AnyUnresolved): an unresolved desired member is
            indistinguishable from an extra, and acting on that guess could
            strip a group (or a team's admins) to nothing over a typo.
          - ExtraFilterPattern limits which observed descriptors are
            candidates for "extra". Security groups pass '^(aad|msa)\.' so
            nested groups (which cannot be matched to a UPN list) are never
            touched; team admins pass '' (everything is a candidate).

        Desired entries are ordered objects with at least a `descriptor` key;
        Missing preserves their order so findings read in authored order.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Desired = @(),
        [hashtable]$Live = @{},
        [bool]$AnyUnresolved = $false,
        [string]$ExtraFilterPattern = ''
    )

    $desiredDescs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $Desired) { if ($d.descriptor) { $desiredDescs.Add([string]$d.descriptor) | Out-Null } }

    $missing = @($Desired | Where-Object { $_.descriptor -and -not $Live.ContainsKey([string]$_.descriptor) })

    $extras = @()
    if (-not $AnyUnresolved) {
        $extras = @($Live.Keys | Where-Object {
            (-not $ExtraFilterPattern -or $_ -match $ExtraFilterPattern) -and
            -not $desiredDescs.Contains($_) })
    }

    return @{ Missing = $missing; Extras = $extras }
}
