function Invoke-GovernancePreflight {
    <#
        .SYNOPSIS
        Pre-migration compliance report, per incoming team: if this team's
        current content moved into the governed target TODAY, which checks
        would fail? Two steps per node (ADR-008):

          gather   Get-GovernancePreflightData reads the team's source location
                   (programs/<name>/sources.yaml) and the target org, and writes
                   the facts to preflight-<code>.data.json — no verdicts.
          analyse  Resolve-GovernancePreflightFindings reads that document,
                   projects it against the node's slice of the resolved model
                   and runs the SAME evaluators audit uses — offline, pure —
                   so a team can fix its findings in place before migration and
                   the post-migration audit can never disagree with preflight.

        -Offline skips the gather and re-analyses the last data file: change a
        tag pattern, re-run, no org is touched. -SkipFresh does the same per
        node for any node whose data file already exists (optionally younger
        than -MaxAgeHours), so a run interrupted by a sign-in expiry resumes
        with only the missing teams — and touches no org at all when nothing
        is left to gather. A gather that fails records an ERROR finding and
        leaves the previous data file in place.

        Checked per node: area subtree shape (orphans-to-be, with work items
        per path), tag usage on work items under the source area (disallowed
        pattern families bundled, unsanctioned tags individually), repo naming
        (when sources.yaml names the team's repos), authored member UPNs
        resolvable in the TARGET org, and people working in the source team
        today who are not authored (the day-one lockout list).

        Read-only against BOTH organisations. Writes preflight-<code>.data.json,
        preflight-<code>.txt and preflight-<code>.json per node next to
        resolved.yaml, and exits non-zero when findings exist (same CI contract
        as audit). Findings are objects: class, check id, subject, counts,
        examples, plus any `labels:` the program attaches per check.

        Out of scope by design: work item type/state/field compatibility —
        that is the migration toolchain's validation, not governance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Code,
        [string]$Org,
        [switch]$Offline,
        [switch]$SkipFresh,
        [int]$MaxAgeHours = 0   # with -SkipFresh: 0 = any existing data file counts as fresh
    )

    # Always build first — preflight must reflect the latest authored config.
    Invoke-GovernanceBuild -ProgramPath $ProgramPath -OutputPath $ResolvedPath | Out-Null

    $source  = Import-GovernanceSource -ProgramPath $ProgramPath
    if (-not $source.Sources) {
        throw "No sources.yaml in '$ProgramPath'. Preflight needs the pre-migration source location per node — see Test-GovernanceSources for the shape."
    }
    $resolved = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)

    $issues = @(Test-GovernanceSources -Sources $source.Sources -Resolved $resolved -Labels $source.SourceLabels -Reporting $source.SourceReporting)
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
    $reportDir     = Split-Path $ResolvedPath -Parent

    # Decide per node whether to gather or reuse, BEFORE authenticating: when
    # every node reuses, no organisation is contacted at all.
    $reuse = @{}
    foreach ($nodeCode in $codes) {
        $dataPath = Join-Path $reportDir "preflight-$nodeCode.data.json"
        $fresh = (Test-Path -LiteralPath $dataPath) -and (
            $MaxAgeHours -le 0 -or ((Get-Date) - (Get-Item -LiteralPath $dataPath).LastWriteTime).TotalHours -lt $MaxAgeHours)
        $reuse[$nodeCode] = $Offline -or ($SkipFresh -and $fresh)
    }
    if (@($reuse.Values | Where-Object { -not $_ }).Count -gt 0) {
        Initialize-AdoAuth -Manifest $manifest -OrgUrl $targetOrgUrl | Out-Null
    }

    $totalFindings = 0

    # console vocabulary — same as the reconcile
    $print = {
        param($line)
        switch ($line.level) {
            'section' { Write-Host "`n--- $($line.text) ---" -ForegroundColor Cyan }
            'ok'      { Write-Host "  [ok]      $($line.text)" -ForegroundColor Green }
            'drift'   { Write-Host "  [DRIFT]   $($line.text)" -ForegroundColor Red }
            'orphan'  { Write-Host "  [AUDIT EXCEPTION] $($line.text)  (would not match config after migration)" -ForegroundColor Magenta }
            'error'   { Write-Host "  [ERROR]   $($line.text)" -ForegroundColor Red }
            'info'    { Write-Host "  [info]    $($line.text)" -ForegroundColor DarkCyan }
        }
    }

    foreach ($nodeCode in $codes) {
        $src      = $source.Sources[$nodeCode]
        $dataPath = Join-Path $reportDir "preflight-$nodeCode.data.json"
        $findings = @()
        $info     = @()

        $reusing  = $reuse[$nodeCode]
        Write-Host "`nPreflighting '$nodeCode': $($src.org)/$($src.project) :: $($src.areaPath)  ->  $targetOrg/$targetProject$(if ($reusing) { '  [' + $(if ($Offline) { 'offline' } else { 'fresh' }) + ': re-analysing ' + (Split-Path $dataPath -Leaf) + ']' })" -ForegroundColor Cyan

        try {
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code $nodeCode

            # ── gather (or reload) ────────────────────────────────────────────
            if ($reusing) {
                if (-not (Test-Path -LiteralPath $dataPath)) {
                    throw "no data file at '$dataPath' — run preflight without -Offline first to gather it"
                }
                $data = Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
                if ([string]$data.schema -ne 'nkdagility.governance.preflight-data/1') {
                    throw "'$dataPath' is not a preflight data document this engine understands (schema '$($data.schema)')"
                }
                if ([string]$data.node -ne $nodeCode) {
                    throw "'$dataPath' was gathered for node '$($data.node)', not '$nodeCode'"
                }
                Write-Host "  [info]    data gathered $($data.gathered) from $($data.source.org)/$($data.source.project)" -ForegroundColor DarkCyan
            } else {
                $data = Get-GovernancePreflightData -Code $nodeCode -Source $src -Slice $slice `
                    -Program ([string]$resolved.program) -TargetOrgUrl $targetOrgUrl -TargetProject $targetProject
                # Only a complete gather may replace the previous data file.
                $data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $dataPath -Encoding utf8
                Write-Host "  [info]    data written to: $dataPath ($($data.workItems.count) work item(s), $(@($data.areas).Count) area path(s), $(@($data.tags.Keys).Count) tag(s))" -ForegroundColor DarkCyan
            }

            # ── analyse (pure) ────────────────────────────────────────────────
            $analysis = Resolve-GovernancePreflightFindings -Data $data -Slice $slice -Labels $source.SourceLabels
            foreach ($line in $analysis.Lines) { & $print $line }
            $findings = @($analysis.Findings)
            $info     = @($analysis.Info)
        } catch {
            $findings = @([ordered]@{
                class   = 'error'
                check   = 'preflight.error'
                subject = $nodeCode
                message = "ERROR preflighting '$nodeCode': $_"
            })
            & $print @{ level = 'error'; text = "preflight '$nodeCode': $_" }
        }

        $reportPath = Join-Path $reportDir "preflight-$nodeCode.txt"
        Write-GovernanceReport -FindingObjects $findings -ProgramName $resolved.program `
            -Project $targetProject -OrgUrl $targetOrgUrl -Mode 'Preflight' -ReportPath $reportPath `
            -Title 'Governance preflight report' -InfoLines $info -ExtraHeader @(
                "Node     : $nodeCode",
                "Source   : $($src.org)/$($src.project) :: $($src.areaPath)",
                "Data     : $(Split-Path $dataPath -Leaf)") | Out-Null

        $totalFindings += $findings.Count
    }

    if ($totalFindings -gt 0) {
        Write-Error "Governance preflight: $totalFindings finding(s) across $($codes.Count) node(s)."
    }
}
