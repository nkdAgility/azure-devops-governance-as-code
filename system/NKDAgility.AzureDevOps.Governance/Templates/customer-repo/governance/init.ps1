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
    Invoke-Governance build     odyssey
    Invoke-Governance plan      odyssey
    Invoke-Governance audit     odyssey
    Invoke-Governance preflight odyssey -Code PTL-FND
    Invoke-Governance preflight odyssey -Code PTL-FND -Offline   # re-analyse, no live calls
    Invoke-Governance preflight odyssey -SkipFresh               # only teams with no data file yet
    Invoke-Governance preflight-report odyssey                   # render every team's fix report (offline)
    Invoke-Governance apply     odyssey -WhatIf

    Invoke-Governance resolves the program and resolved.yaml paths from this folder and
    the workspace output folder. The module's own commands remain available if you want
    to be explicit about both.
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

# --- Register this capability's safety hook --------------------------------
# .claude\hooks\deny-governance-apply.ps1 is shipped and refreshed by this
# engine, but the file that ACTIVATES it - .claude\settings.json - is a seed
# owned by the workspace (scaffolded by the automation tools). A hook that
# ships and is never wired up is not a control, so register it here, on every
# session, idempotently: add exactly one PreToolUse entry, never remove or
# reorder anything else, and warn rather than throw if the file cannot be read.
$hookRelative = '.claude/hooks/deny-governance-apply.ps1'
$hookFile = Join-Path $WorkspaceRoot ($hookRelative -replace '/', '\')
if (Test-Path -LiteralPath $hookFile) {
    $settingsPath = Join-Path $WorkspaceRoot '.claude\settings.json'
    $hookCommand = 'pwsh -NoProfile -File "$CLAUDE_PROJECT_DIR/' + $hookRelative + '"'
    try {
        $settings = if (Test-Path -LiteralPath $settingsPath) {
            Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        }
        else { [pscustomobject]@{} }

        if (-not $settings.PSObject.Properties['hooks']) {
            $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
        }
        if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
            $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue @()
        }

        $already = @($settings.hooks.PreToolUse | Where-Object {
                @($_.hooks | Where-Object { [string]$_.command -like "*deny-governance-apply.ps1*" }).Count -gt 0
            }).Count -gt 0

        if (-not $already) {
            $entry = [pscustomobject]@{
                matcher = 'PowerShell|Bash'
                hooks   = @([pscustomobject]@{ type = 'command'; command = $hookCommand })
            }
            $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $entry
            New-Item -Path (Split-Path -Parent $settingsPath) -ItemType Directory -Force | Out-Null
            $settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $settingsPath
            Write-Host "==> Governance: registered the deny-apply hook in .claude\settings.json" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Warning ("Could not register the governance deny-apply hook in '$settingsPath': $_. " +
            "Add a PreToolUse entry with matcher 'PowerShell|Bash' running '$hookRelative' by hand, " +
            'or agents in this workspace will not be blocked from running a governance apply.')
    }
}

$programsRoot = Join-Path $PSScriptRoot 'programs'
# Invoke-Governance is global so it outlives this script, so it cannot close over a
# script-scoped variable - by the time anyone calls it, this scope is gone. The roots go
# in globals it can still reach.
$Global:NkdaGovernanceProgramsRoot = $programsRoot
$Global:NkdaGovernanceFallbackOut = Join-Path $PSScriptRoot 'out'

# Resolve a program name to the two paths every governance command needs, so runbooks and
# CI say 'odyssey' rather than repeating both. This is workspace glue, deliberately not
# engine code: the module's commands stay explicit about what they read and write.
function Global:Invoke-Governance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('build', 'validate', 'plan', 'apply', 'audit', 'preflight', 'preflight-report')]
        [string]$Command,

        [Parameter(Mandatory, Position = 1)]
        [string]$Program,

        [string]$Org,
        [string]$Code,
        [switch]$WhatIf,
        [switch]$Prune,
        [switch]$Offline,    # preflight: re-analyse the last gathered data file, touch no org
        [switch]$SkipFresh   # preflight: gather only nodes with no data file yet; reuse the rest
    )

    $programPath = Join-Path $Global:NkdaGovernanceProgramsRoot $Program
    if (-not (Test-Path -LiteralPath (Join-Path $programPath 'manifest.yaml'))) {
        throw "No governance program '$Program' at '$programPath' (expected a manifest.yaml)."
    }

    $outputRoot = try { Join-Path (Get-AutomationWorkspace).OutputFolder 'governance' }
    catch { $Global:NkdaGovernanceFallbackOut }
    $resolvedPath = Join-Path (Join-Path $outputRoot $Program) 'resolved.yaml'
    New-Item -Path (Split-Path -Parent $resolvedPath) -ItemType Directory -Force | Out-Null

    switch ($Command) {
        'build' { Invoke-GovernanceBuild -ProgramPath $programPath -OutputPath $resolvedPath }
        'validate' { Test-Governance -ProgramPath $programPath }
        'plan' { Invoke-GovernancePlan -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org }
        'audit' { Invoke-GovernanceAudit -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org }
        'preflight' { Invoke-GovernancePreflight -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org -Code $Code -Offline:$Offline -SkipFresh:$SkipFresh }
        'preflight-report' { Invoke-GovernancePreflightReport -ProgramPath $programPath -ResolvedPath $resolvedPath -Code $Code }
        'apply' { Invoke-GovernanceApply -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org -WhatIf:$WhatIf -Prune:$Prune }
    }
}

$programs = @(Get-ChildItem -LiteralPath $programsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.yaml') })

if ($programs.Count) {
    Write-Host "==> Governance: $($programs.Count) program(s) - $($programs.Name -join ', ')" -ForegroundColor Cyan
}
else {
    Write-Host "==> Governance: no programs yet. Create governance\programs\<name>\manifest.yaml to start." -ForegroundColor DarkGray
}
