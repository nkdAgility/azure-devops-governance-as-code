function Write-GovernanceReport {
    <#
        .SYNOPSIS
        Findings summary + report files, shared by the reconcile (audit /
        apply / WhatIf) and preflight. Prints the console summary, and when
        ReportPath is set writes the text report plus its machine-readable
        JSON twin (findings classified by prefix — consumed by scheduled runs
        and, eventually, the compliance dashboard).

        Findings are the prefix-classified strings the whole engine emits:
        MISSING / DRIFT (no prefix) / ERROR / UNRESOLVABLE / AUDIT EXCEPTION.
        InfoLines are context that is NOT a finding (preflight uses them for
        mapping guidance); they never affect the finding count or CI exit.

        Returns the mode's finding-count suffix ('found', 'remaining after
        apply', …) so the caller can word its terminating error identically.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Findings = @(),
        [Parameter(Mandatory)][string]$ProgramName,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Mode,
        [string]$ReportPath = '',
        [string]$Title = 'Governance audit report',
        [AllowEmptyCollection()][string[]]$ExtraHeader = @(),
        [AllowEmptyCollection()][string[]]$InfoLines = @()
    )

    $exceptions = @($Findings | Where-Object { $_ -like 'AUDIT EXCEPTION*' })
    $missing    = @($Findings | Where-Object { $_ -like 'MISSING*' })
    $errors     = @($Findings | Where-Object { $_ -like 'ERROR*' -or $_ -like 'UNRESOLVABLE*' })
    $drift      = @($Findings | Where-Object {
        $_ -notlike 'AUDIT EXCEPTION*' -and $_ -notlike 'MISSING*' -and
        $_ -notlike 'ERROR*' -and $_ -notlike 'UNRESOLVABLE*' })

    # Group each error under its diagnosed root cause so the summary reads as
    # "here is what failed and WHY", not a wall of identical stack noise.
    $errorsByWhy = [ordered]@{}
    foreach ($e in $errors) {
        $why = Resolve-GovernanceErrorReason -Finding $e
        if (-not $why) { $why = 'cause not yet diagnosed - investigate, then teach Resolve-GovernanceErrorReason the signature' }
        if (-not $errorsByWhy.Contains($why)) { $errorsByWhy[$why] = [System.Collections.Generic.List[string]]::new() }
        $errorsByWhy[$why].Add($e)
    }

    $suffix = switch ($Mode) {
        'Apply'  { 'remaining after apply' }
        'WhatIf' { 'found (dry-run — no changes made)' }
        default  { 'found' }
    }

    Write-Host ''
    if ($Findings.Count -eq 0) {
        Write-Host "COMPLIANT — zero findings." -ForegroundColor Green
    } else {
        Write-Host "NON-COMPLIANT — $($Findings.Count) finding(s) $suffix." -ForegroundColor Red
        if ($missing.Count -gt 0) {
            Write-Host "`n  Missing ($($missing.Count)):" -ForegroundColor Red
            $missing | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
        }
        if ($drift.Count -gt 0) {
            Write-Host "`n  Drift ($($drift.Count)):" -ForegroundColor Red
            $drift | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
        }
        if ($errors.Count -gt 0) {
            Write-Host "`n  Errors and why ($($errors.Count)):" -ForegroundColor Red
            foreach ($why in $errorsByWhy.Keys) {
                Write-Host "    WHY: $why" -ForegroundColor Yellow
                foreach ($e in $errorsByWhy[$why]) { Write-Host "      * $e" -ForegroundColor Red }
            }
        }
        if ($exceptions.Count -gt 0) {
            Write-Host "`n  Audit failures — exist in ADO but not in config ($($exceptions.Count)):" -ForegroundColor Magenta
            $exceptions | ForEach-Object { Write-Host "    * $_" -ForegroundColor Magenta }
        }
    }
    if ($InfoLines.Count -gt 0) {
        Write-Host "`n  Info — not findings ($($InfoLines.Count)):" -ForegroundColor DarkCyan
        $InfoLines | ForEach-Object { Write-Host "    * $_" -ForegroundColor DarkCyan }
    }

    if ($ReportPath) {
        $reportDir = Split-Path $ReportPath -Parent
        if ($reportDir -and -not (Test-Path $reportDir)) {
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($Title)
        $lines.Add("Program  : $Project")
        $lines.Add("Org      : $OrgUrl")
        foreach ($h in $ExtraHeader) { $lines.Add($h) }
        $lines.Add("Mode     : $Mode")
        $lines.Add("Generated: $(Get-Date -Format 'o')")
        $lines.Add("Findings : $($Findings.Count)")
        $lines.Add('')
        $errorReportItems = @(foreach ($why in $errorsByWhy.Keys) {
            "WHY: $why"
            foreach ($e in $errorsByWhy[$why]) { "  - $e" }
        })
        foreach ($section in @(
            @{ label = 'MISSING'; items = $missing },
            @{ label = 'DRIFT';   items = $drift },
            @{ label = 'ERRORS AND WHY'; items = $errorReportItems },
            @{ label = 'AUDIT FAILURES (exist in ADO but not in config)'; items = $exceptions },
            @{ label = 'INFO (not findings)'; items = $InfoLines }
        )) {
            if ($section.items.Count -eq 0) { continue }
            $lines.Add("$($section.label) ($($section.items.Count)):")
            $section.items | ForEach-Object { $lines.Add("  - $_") }
            $lines.Add('')
        }
        if ($Findings.Count -eq 0) { $lines.Add('COMPLIANT') } else { $lines.Add('NON-COMPLIANT') }
        Set-Content -Path $ReportPath -Value $lines -Encoding utf8
        Write-Host "`nReport written to: $ReportPath" -ForegroundColor Cyan

        $jsonPath   = [System.IO.Path]::ChangeExtension($ReportPath, 'json')
        $classified = @($Findings | ForEach-Object {
            $class = if ($_ -like 'MISSING*')              { 'missing' }
                     elseif ($_ -like 'AUDIT EXCEPTION*')  { 'exception' }
                     elseif ($_ -like 'UNRESOLVABLE*')     { 'unresolvable' }
                     elseif ($_ -like 'ERROR*')            { 'error' }
                     else                                  { 'drift' }
            $entry = [ordered]@{ class = $class; message = $_ }
            if ($class -in 'error', 'unresolvable') {
                $entry['why'] = Resolve-GovernanceErrorReason -Finding $_
            }
            $entry
        })
        $doc = [ordered]@{
            program      = $ProgramName
            project      = $Project
            org          = $OrgUrl
            mode         = $Mode
            generated    = (Get-Date).ToUniversalTime().ToString('o')
            compliant    = ($Findings.Count -eq 0)
            findingCount = $Findings.Count
            findings     = $classified
        }
        if ($InfoLines.Count -gt 0) { $doc['info'] = @($InfoLines) }
        $doc | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding utf8
        Write-Host "JSON report written to: $jsonPath" -ForegroundColor Cyan
    }

    return $suffix
}
