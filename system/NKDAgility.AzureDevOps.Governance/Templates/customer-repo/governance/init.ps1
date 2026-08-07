# ============================================================================
#  MANAGED FILE - DO NOT EDIT IN THE CUSTOMER WORKSPACE
#  Source: Templates\customer-repo\governance\init.ps1 inside the
#          NKDAgility.AzureDevOps.Governance module.
#  This file is overwritten from that template on every run. Edit it there.
# ============================================================================
<#
.SYNOPSIS
    Governance capability loader for a customer workspace.

.DESCRIPTION
    Dot-sourced by the workspace's root init.ps1 once it has materialised
    .system\NKDAgility.AzureDevOps.Governance. Imports that copy and reports the
    programs this workspace governs.

    A program is a folder under governance\programs\<name>\ holding:
      manifest.yaml    program identity, organisation, accessToken variable name
      hierarchy.yaml   the authored organisation hierarchy
      access.yaml      roles and group catalog
      members\         membership per code key

    Build artefacts are written under the workspace output folder, never here.

    Secrets come from the workspace contract, not from a governance-specific file:
    secrets\secrets.json names an environment variable per organisation, the root
    init.ps1 exports them, and manifest.yaml references one by name as accessToken.

.EXAMPLE
    Invoke-GovernanceBuild -ProgramPath .\governance\programs\odyssey
    Invoke-GovernancePlan  -ProgramPath .\governance\programs\odyssey
    Invoke-GovernanceAudit -ProgramPath .\governance\programs\odyssey
#>
[CmdletBinding()]
param(
    # Workspace root. The root init.ps1 passes this; it defaults to the parent of
    # this file so the capability can also be loaded on its own.
    [string]$WorkspaceRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

$moduleName = 'NKDAgility.AzureDevOps.Governance'
$modulePath = Join-Path $WorkspaceRoot (Join-Path '.system' $moduleName)
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "$moduleName is not materialised at '$modulePath'. Run the workspace's init.ps1, which copies it in from the tools clone."
}

# The module declares powershell-yaml as a requirement; importing it fails without.
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host '==> Installing powershell-yaml (required by the governance module)' -ForegroundColor Cyan
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}

Import-Module $modulePath -Force

$programsRoot = Join-Path $PSScriptRoot 'programs'
$programs = @(Get-ChildItem -LiteralPath $programsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.yaml') })

if ($programs.Count) {
    Write-Host "==> Governance: $($programs.Count) program(s) - $($programs.Name -join ', ')" -ForegroundColor Cyan
}
else {
    Write-Host "==> Governance: no programs yet. Create governance\programs\<name>\manifest.yaml to start." -ForegroundColor DarkGray
}
