function Invoke-GovernancePreflightReport {
    <#
        .SYNOPSIS
        Renders the markdown fix report for every node preflight has gathered
        (or one, with -Code), from the data and findings files beside
        resolved.yaml, splicing in observations-<code>.md when it exists.
        Offline and deterministic — no organisation is touched — so it is the
        no-AI path: CI or a bare shell gets the same documents an operator
        gets, minus only the Observations section.

        Reads the program's sources.yaml for the labels map (rule / task /
        lane per check) and the optional reporting block (standard name,
        audience, candidate-tag threshold). Skips a node whose data or
        findings file is missing, says so, and throws only if nothing at all
        could be rendered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Code
    )

    $source = Import-GovernanceSource -ProgramPath $ProgramPath
    if (-not $source.Sources) {
        throw "No sources.yaml in '$ProgramPath' — nothing has been preflighted for this program."
    }
    $codes = if ($Code) { @($Code) } else { @($source.Sources.Keys | Sort-Object) }
    $dir   = [System.IO.Path]::GetDirectoryName($ResolvedPath)

    $rendered = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $codes) {
        $dataPath = Join-Path $dir "preflight-$c.data.json"
        $findPath = Join-Path $dir "preflight-$c.json"
        $obsPath  = Join-Path $dir "observations-$c.md"
        $missing  = @(foreach ($p in $dataPath, $findPath) { if (-not (Test-Path -LiteralPath $p)) { Split-Path -Leaf $p } })
        if ($missing.Count -gt 0) {
            Write-Host "  [skip]    $c — not gathered yet (missing $($missing -join ', ')); run preflight first" -ForegroundColor DarkYellow
            continue
        }
        $out = ConvertTo-GovernancePreflightReport -DataPath $dataPath -FindingsPath $findPath `
            -ObservationsPath $obsPath -Labels $source.SourceLabels -Reporting $source.SourceReporting
        $withObs = Test-Path -LiteralPath $obsPath
        Write-Host "  [ok]      $c — $out$(if ($withObs) { ' (with observations)' } else { ' (no observations yet)' })" -ForegroundColor Green
        $rendered.Add($out)
    }

    if ($rendered.Count -eq 0) {
        throw "Nothing rendered: none of $($codes -join ', ') has both a data file and a findings file in '$dir'. Run preflight first."
    }
    return @($rendered)
}
