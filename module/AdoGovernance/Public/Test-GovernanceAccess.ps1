function Test-GovernanceAccess {
    <#
        .SYNOPSIS
        Verifies the PAT referenced by the program manifest carries every scope
        the engine needs, using side-effect-free probes (reads, plus writes with
        intentionally invalid payloads that ADO rejects AFTER the scope check —
        nothing is ever created or changed).

        Prints one line per scope family and returns a non-terminating error
        when any scope needed is missing, so CI exits non-zero. `unknown`
        verdicts (network failure, unexpected status) are reported but do not
        fail the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [string]$Org
    )

    $source    = Import-GovernanceSource -ProgramPath $ProgramPath
    $manifest  = $source.Manifest
    $targetOrg = if ($Org) { $Org } else { $manifest.org }
    $token     = Resolve-AccessToken $manifest.accessToken
    if (-not $token) {
        throw "Access token not found. Set the environment variable referenced by manifest.accessToken."
    }
    Set-AdoAuth $token

    $orgUrl      = ConvertTo-AdoOrgUrl -Org $targetOrg
    $projectName = if ($manifest.project -and $manifest.project.name) { $manifest.project.name } else { $manifest.program }

    Write-Host "Checking PAT scopes for '$projectName' in $orgUrl" -ForegroundColor Cyan
    Write-Host "(read probes + intentionally invalid writes - no changes are made)" -ForegroundColor DarkGray

    $results = @(Test-AdoAuthScope -OrgUrl $orgUrl -Project $projectName)
    foreach ($r in $results) {
        switch ($r.Verdict) {
            'ok'      { Write-Host ("  [OK]      {0,-28} {1,-28} needed for: {2}" -f $r.Family, $r.Scope, $r.NeededFor) -ForegroundColor Green }
            'missing' { Write-Host ("  [MISSING] {0,-28} {1,-28} needed for: {2}" -f $r.Family, $r.Scope, $r.NeededFor) -ForegroundColor Red }
            default   { Write-Host ("  [?]       {0,-28} {1,-28} probe inconclusive (HTTP {3}); needed for: {2}" -f $r.Family, $r.Scope, $r.NeededFor, $r.StatusCode) -ForegroundColor Yellow }
        }
    }

    $missing = @($results | Where-Object Verdict -eq 'missing')
    if ($missing.Count -gt 0) {
        Write-Error ("PAT is missing {0} scope(s): {1}. Reissue the PAT with these scopes (or use Full access) and retry." -f
            $missing.Count, (($missing | ForEach-Object { $_.Scope }) -join ', '))
        return
    }
    Write-Host "All scope probes passed." -ForegroundColor Green
}
