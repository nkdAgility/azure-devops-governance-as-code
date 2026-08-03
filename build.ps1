#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Single entry point for Azure DevOps governance-as-code.

.DESCRIPTION
    Bootstraps dependencies, imports the in-repo AdoGovernance module, and
    dispatches a command across one or all programs under programs/.

    Each program is a folder programs/<name>/ containing:
      manifest.yaml    program identity + org + accessToken reference
      hierarchy.yaml   the authored org hierarchy
      access.yaml      roles + group catalog
      members/         membership per code key
      (resolved.yaml is written to out/<name>/, gitignored)

    Commands:
      build     Compile hierarchy -> programs/<name>/resolved.yaml (+ validate)
      validate  Schema + rules + Azure DevOps limits, no live calls
      plan      Diff resolved vs live Azure DevOps -> change set
      apply     Reconcile Azure DevOps to the resolved desired state
      audit     Read-only compliance report

.EXAMPLE
    pwsh ./build.ps1 build                        # build every program
    pwsh ./build.ps1 build    -Program odyssey # build one program
    pwsh ./build.ps1 validate
    pwsh ./build.ps1 plan  -Program odyssey -Org nkdagility-preview
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'validate', 'plan', 'apply', 'audit', 'doctor')]
    [string]$Command,

    [string]$Program,
    [string]$Org,
    [switch]$WhatIf,
    [switch]$Prune,

    # Root folder containing program definitions (programs/<name>/). Defaults to
    # this repo's programs/. Client repos point this at their own governance
    # config so this script doubles as a reusable shell around the module.
    [string]$ProgramsRoot,

    # Root folder for build artifacts (out/<name>/resolved.yaml). Defaults to
    # this repo's out/. Client repos pass their own so artifacts stay with them.
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'

# No command -> print help and exit (before any bootstrapping).
if (-not $Command) {
    Write-Host @'
build.ps1 - Azure DevOps governance-as-code

Usage:
  ./build.ps1 <command> [-Program <name>] [-Org <org>]

Commands:
  build     Compile programs/<name> -> out/<name>/resolved.yaml (+ validate)
  validate  Schema + rules + Azure DevOps limits (no live calls)
  plan      Diff resolved desired state vs live Azure DevOps
  apply     Reconcile Azure DevOps to the resolved desired state
  audit     Read-only compliance report
  doctor    Verify the PAT has every required scope (no changes made)

Options:
  -Program      Target one program under the programs root (default: all)
  -ProgramsRoot Folder containing program definitions (default: ./programs)
  -OutputRoot   Folder for build artifacts (default: ./out)
  -Org          Override the org declared in the program manifest.yaml
  -WhatIf   (apply) Show what would change without making any changes
  -Prune    (apply) DELETE resources in ADO that are not in the config
            (orphan teams, area paths, repos, extra group members).
            Never on by default; can also be set via manifest settings.prune.

Examples:
  ./build.ps1 build
  ./build.ps1 build    -Program odyssey
  ./build.ps1 validate -Program odyssey
  ./build.ps1 plan     -Program odyssey
  ./build.ps1 apply    -Program odyssey -WhatIf
  ./build.ps1 apply    -Program odyssey -WhatIf -Prune   # preview deletions
'@
    return
}

$moduleManifest = Join-Path $PSScriptRoot 'module/AdoGovernance/AdoGovernance.psd1'
$programsRoot   = if ($ProgramsRoot) { (Resolve-Path $ProgramsRoot).Path } else { Join-Path $PSScriptRoot 'programs' }
$buildRoot      = if ($OutputRoot)   { $OutputRoot }                       else { Join-Path $PSScriptRoot 'out' }

# 1. self-install external dependencies (once)
foreach ($dep in 'powershell-yaml') {
    if (-not (Get-Module -ListAvailable -Name $dep)) {
        Write-Host "Installing dependency '$dep'..." -ForegroundColor Cyan
        Install-Module $dep -Scope CurrentUser -Force -AcceptLicense -Repository PSGallery
    }
}

# 2. reference the in-repo module (imports its RequiredModules automatically)
Import-Module $moduleManifest -Force

# 3. resolve target program(s)

# This repo is the engine and ships no client programs. When a program is not
# found locally, look for it in sibling client repos (<repo>/governance/programs/)
# so the error can say exactly where to run from instead of a bare "not found".
function Find-ClientProgramPath {
    param([string]$Name)
    $parent = Split-Path $PSScriptRoot -Parent
    foreach ($dir in @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue)) {
        $candidate = Join-Path $dir.FullName "governance/programs/$Name"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$engineHint = 'This repo is the governance ENGINE and carries no client programs - ' +
              'client configuration lives in its own repo (NKDAClient-<client>/governance/). ' +
              'Run that repo''s governance/build.ps1, or pass -ProgramsRoot <path-to-programs>.'

$programPaths = if ($Program) {
    $path = Join-Path $programsRoot $Program
    if (-not (Test-Path $path)) {
        $elsewhere = Find-ClientProgramPath -Name $Program
        if ($elsewhere) {
            $clientBuild = Join-Path (Split-Path (Split-Path $elsewhere -Parent) -Parent) 'build.ps1'
            throw "Program '$Program' is not in this repo - it lives at: $elsewhere`n" +
                  "Run it from the client repo instead:`n" +
                  "  pwsh $clientBuild $Command -Program $Program"
        }
        throw "Program not found: $path`n$engineHint"
    }
    @($path)
}
else {
    @(Get-ChildItem -Path $programsRoot -Directory | Select-Object -ExpandProperty FullName)
}
if ($programPaths.Count -eq 0) { throw "No programs found under $programsRoot`n$engineHint" }

# 4. dispatch per program. resolved.yaml is a build artifact under out/ (gitignored).
foreach ($programPath in $programPaths) {
    $name         = Split-Path $programPath -Leaf
    $resolvedPath = Join-Path $buildRoot (Join-Path $name 'resolved.yaml')

    switch ($Command) {
        'build'    { Invoke-GovernanceBuild -ProgramPath $programPath -OutputPath $resolvedPath }
        'validate' { Test-Governance        -ProgramPath $programPath }
        'plan'     { Invoke-GovernancePlan   -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org }
        'apply'    { Invoke-GovernanceApply  -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org -WhatIf:$WhatIf -Prune:$Prune }
        'audit'    { Invoke-GovernanceAudit  -ProgramPath $programPath -ResolvedPath $resolvedPath -Org $Org }
        'doctor'   { Test-GovernanceAccess   -ProgramPath $programPath -Org $Org }
    }
}
