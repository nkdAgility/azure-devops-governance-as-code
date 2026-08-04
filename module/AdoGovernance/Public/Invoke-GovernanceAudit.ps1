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
    Initialize-AdoAuth -Manifest $manifest | Out-Null

    $orgUrl     = ConvertTo-AdoOrgUrl -Org $targetOrg
    $resolved   = ConvertFrom-Yaml (Get-Content $ResolvedPath -Raw)
    $reportPath = Join-Path (Split-Path $ResolvedPath -Parent) 'audit-report.txt'

    Write-Host "Auditing '$($resolved.program)' in $orgUrl" -ForegroundColor Cyan

    # The target project is itself a governed resource: if it is missing, every
    # downstream check would fail with noise, so report the one real finding.
    $projectDecl = $resolved.project
    $projectName = if ($projectDecl -and $projectDecl.name) { $projectDecl.name } else { $resolved.program }
    if (-not (Test-AdoProject -OrgUrl $orgUrl -Project $projectName)) {
        Write-Host "  [MISSING] project: $projectName" -ForegroundColor Red
        Write-Error "Governance compliance: project '$projectName' does not exist in $orgUrl — every governed resource is missing."
        return
    }

    Invoke-GovernanceReconcile -Resolved $resolved -OrgUrl $orgUrl -Mode 'Audit' -ReportPath $reportPath -TeamIds $teamIds | Out-Null
}
