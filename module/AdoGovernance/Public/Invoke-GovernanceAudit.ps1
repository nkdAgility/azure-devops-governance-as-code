function Invoke-GovernanceAudit {
    <#
        .SYNOPSIS
        Builds the resolved model then runs the compliance loop in Audit mode:
        every governed resource is checked and every deviation is reported.
        No changes are made to the live Azure DevOps organisation.

        Returns a non-terminating error and exits non-zero when findings exist,
        so CI pipelines can detect non-compliance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Org
    )

    # Always build first — audit must reflect the latest authored config.
    Invoke-GovernanceBuild -ProgramPath $ProgramPath -OutputPath $ResolvedPath | Out-Null

    $source    = Import-GovernanceSource -ProgramPath $ProgramPath
    $manifest  = $source.Manifest
    $teamIds   = $source.TeamIds   # read-only in audit; not written back
    $targetOrg = if ($Org) { $Org } else { $manifest.org }
    $token     = Resolve-AccessToken $manifest.accessToken
    if (-not $token) {
        throw "Access token not found. Set the environment variable referenced by manifest.accessToken."
    }
    Set-AdoAuth $token

    $orgUrl     = ConvertTo-AdoOrgUrl -Org $targetOrg
    $resolved   = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)
    $reportPath = Join-Path (Split-Path $ResolvedPath -Parent) 'audit-report.txt'

    Write-Host "Auditing '$($resolved.program)' in $orgUrl" -ForegroundColor Cyan
    Invoke-GovernanceReconcile -Resolved $resolved -OrgUrl $orgUrl -Mode 'Audit' -ReportPath $reportPath -TeamIds $teamIds | Out-Null
}
