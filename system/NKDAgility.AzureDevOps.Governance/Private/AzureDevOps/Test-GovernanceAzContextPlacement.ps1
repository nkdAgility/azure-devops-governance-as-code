function Get-GovernanceWorkspaceRoot {
    <# The workspace a program lives in: the nearest ancestor holding
       workspace.json or .git. Returns $null when there is no such ancestor,
       which is the normal case in the engine's own tests. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgramPath)

    $dir = if (Test-Path -LiteralPath $ProgramPath -PathType Container) { (Resolve-Path -LiteralPath $ProgramPath).Path }
           else { Split-Path -Parent $ProgramPath }
    while ($dir) {
        if ((Test-Path (Join-Path $dir 'workspace.json')) -or (Test-Path (Join-Path $dir '.git'))) { return $dir }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { return $null }
        $dir = $parent
    }
    return $null
}

function Test-GovernanceAzContextPlacement {
    <#
        .SYNOPSIS
        Checks that the program's Azure CLI context is declared in the right
        file, and that nothing else on this machine is quietly competing with
        it (ADR-012). Offline: it reads files and the environment, and signs
        nothing in.

        Three ways to get this wrong, all of them silent:

          1. Nothing is declared. The program then runs against whichever
             identity the machine's default az session happens to hold — which
             works on the author's laptop and fails, or worse succeeds against
             the wrong tenant, everywhere else.
          2. AZURE_CONFIG_DIR is set somewhere outside governance — a shell
             profile, a CI step, .claude/settings.local.json. The run may well
             work, but the choice is not in source control, so nobody else
             reproduces it and the next person to change it breaks a run they
             cannot see.
          3. The profile directory is inside a repository. An Azure CLI
             profile holds refresh tokens; a token store in a working tree is
             one bad .gitignore away from being published. That one is an
             error, not advice.

        Returns advice objects { Level = error|warn|info; Message }. Empty
        means declared, uncontested and safely placed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$ProgramPath,
        # Discovered values, so the suggested snippet is one a caller can paste
        # rather than a form to fill in. Connect knows them; validate does not.
        [string]$Tenant,
        [string]$SignInAs,
        [string]$Subscription
    )

    $advice = @()
    $manifestPath = if ($ProgramPath) { Join-Path $ProgramPath 'manifest.yaml' } else { 'manifest.yaml' }
    $ctx      = Get-GovernanceAzContext -Manifest $Manifest
    $declared = [bool]($ctx -and $ctx.ProfileDir)

    if (-not $declared) {
        $name = if ($Manifest.program) { ([string]$Manifest.program).ToLowerInvariant() } else { 'this-program' }
        $snippet = @(
            'azure:'
            "  profile:      $name"
            $(if ($Tenant)       { "  tenant:       $Tenant" }       else { '  tenant:       <tenant guid>' })
            $(if ($Subscription) { "  subscription: $Subscription" } else { '  subscription: <subscription guid or name>' })
            $(if ($SignInAs)     { "  signInAs:     $SignInAs" }     else { '  signInAs:     <you>@<customer>.com' })
        ) -join "`n"

        $advice += [pscustomobject]@{ Level = 'info'; Message =
            "No azure: block in $manifestPath, so this program uses the machine's default az session and shares it with " +
            "every other terminal and scheduled task for this user. Declaring one gives it an az world of its own:`n`n$snippet" }

        if ($env:AZURE_CONFIG_DIR) {
            $advice += [pscustomobject]@{ Level = 'warn'; Message =
                "AZURE_CONFIG_DIR is set to '$env:AZURE_CONFIG_DIR' by something outside governance. The run will use it, but " +
                "nothing in this workspace records that, so nobody else reproduces it. Declare it in $manifestPath instead." }
        }
        return $advice
    }

    # Declared. Is the declaration the only one?
    $root = if ($ProgramPath) { Get-GovernanceWorkspaceRoot -ProgramPath $ProgramPath } else { $null }
    if ($root) {
        foreach ($rel in @('.claude\settings.json', '.claude\settings.local.json')) {
            $f = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $competing = $null
            try { $competing = (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).env.AZURE_CONFIG_DIR } catch { continue }
            if (-not $competing) { continue }
            if ($competing -eq $ctx.ProfileDir) { continue }
            $advice += [pscustomobject]@{ Level = 'warn'; Message =
                "$rel also sets AZURE_CONFIG_DIR, to '$competing', while $manifestPath declares '$($ctx.ProfileDir)'. " +
                "Governance enters its own profile per run so the manifest wins for governance commands - but a bare 'az' " +
                "in the same session lands in the other one, and a sign-in done there will not be found. Remove the env entry and keep the manifest." }
        }
    }

    # A profile directory inside a repository is a token store in a working tree.
    $inRepo = Get-GovernanceWorkspaceRoot -ProgramPath $ctx.ProfileDir
    if ($inRepo) {
        $advice += [pscustomobject]@{ Level = 'error'; Message =
            "azure.profile resolves to '$($ctx.ProfileDir)', which is inside the repository at '$inRepo'. An Azure CLI profile " +
            "holds refresh tokens. Use a bare name - it resolves to ~/.azure-profiles/<name>, outside every working tree." }
    }

    # And does it hold a sign-in yet? Absence is not a fault, it is the next step.
    if (-not (Test-Path -LiteralPath (Join-Path $ctx.ProfileDir 'azureProfile.json'))) {
        $advice += [pscustomobject]@{ Level = 'info'; Message =
            "Profile '$($ctx.ProfileDir)' holds no sign-in yet. Run 'connect' before any command that reaches a live organisation." }
    }

    return $advice
}

function Show-GovernanceAzContextPlacement {
    <# Prints what Test-GovernanceAzContextPlacement found, and returns $false
       when any of it was an error. Nothing is thrown: a misplaced profile is a
       finding to report, not a malfunction of the command reporting it. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$ProgramPath,
        [string]$Tenant,
        [string]$SignInAs,
        [string]$Subscription
    )

    $advice = @(Test-GovernanceAzContextPlacement -Manifest $Manifest -ProgramPath $ProgramPath `
        -Tenant $Tenant -SignInAs $SignInAs -Subscription $Subscription)
    foreach ($a in $advice) {
        $colour = switch ($a.Level) { 'error' { 'Red' } 'warn' { 'Yellow' } default { 'DarkGray' } }
        $label  = switch ($a.Level) { 'error' { '  [!] ' } 'warn' { '  [?] ' } default { '  ' } }
        Write-Host ($label + ($a.Message -replace "`n", "`n     ")) -ForegroundColor $colour
    }
    return -not @($advice | Where-Object Level -eq 'error').Count
}
