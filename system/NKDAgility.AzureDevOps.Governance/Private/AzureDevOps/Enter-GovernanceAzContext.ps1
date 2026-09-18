function Get-GovernanceAzContext {
    <#
        .SYNOPSIS
        The program's declared Azure CLI context, from manifest.yaml `azure:`
        (ADR-012). Every field is optional; a program that declares none gets
        the machine default and behaves exactly as it always did.

          azure:
            profile:      contoso                # an az world of its own
            tenant:       <guid>                    # else discovered from the org
            subscription: <guid or name>            # made active after sign-in
            signInAs:     someone@customer.com      # which identity, not a secret

        `profile` is the isolation. A bare name resolves to
        ~/.azure-profiles/<name>; an absolute or ~-rooted path is used as
        given. It is deliberately OUTSIDE the repository: an Azure CLI profile
        directory holds refresh tokens, and a token store inside a git
        working tree is one bad .gitignore away from being published.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $az = $Manifest.azure
    if (-not $az) { return $null }

    $profileDir = $null
    if ($az.profile) {
        $p = [string]$az.profile
        $profileDir = if ($p.StartsWith('~')) { Join-Path $HOME $p.TrimStart('~', '/', '\') }
                      elseif ([System.IO.Path]::IsPathRooted($p)) { $p }
                      else { Join-Path (Join-Path $HOME '.azure-profiles') $p }
    }
    return [ordered]@{
        ProfileDir   = $profileDir
        Tenant       = [string]$az.tenant
        Subscription = [string]$az.subscription
        SignInAs     = [string]$az.signInAs
    }
}

function Enter-GovernanceAzContext {
    <#
        .SYNOPSIS
        Points Azure CLI at the profile this program declares, for the rest of
        this PROCESS, and reports what it did (ADR-012).

        Azure CLI keeps its whole state — accounts, active subscription, token
        cache — in AZURE_CONFIG_DIR. Setting it per process is what lets a
        governance run hold a customer's identity without touching the identity
        every other terminal, script and scheduled task on the machine is
        using. Other processes are unaffected because an environment variable
        does not travel upwards.

        Within THIS process it is not scoped any tighter than the process, and
        that is deliberate: preflight authenticates against two organisations
        in one run, so the profile has to outlive any single call. It is
        announced every time rather than applied silently, because an az
        command typed into the same shell afterwards will use it too.

        Returns a state object for Exit-GovernanceAzContext; pass -Quiet from
        callers that announce it themselves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [switch]$Quiet
    )

    $state = @{ Previous = $env:AZURE_CONFIG_DIR; Changed = $false; Context = $null }
    $ctx = Get-GovernanceAzContext -Manifest $Manifest
    $state.Context = $ctx
    if (-not $ctx -or -not $ctx.ProfileDir) { return $state }

    if ($env:AZURE_CONFIG_DIR -ne $ctx.ProfileDir) {
        New-Item -ItemType Directory -Path $ctx.ProfileDir -Force | Out-Null
        $env:AZURE_CONFIG_DIR = $ctx.ProfileDir
        $state.Changed = $true
    }
    if (-not $Quiet) {
        Write-Host "Azure CLI profile: $($ctx.ProfileDir)" -ForegroundColor DarkCyan
        Write-Host "  declared by this program, so this run cannot disturb the machine's default az session." -ForegroundColor DarkGray
    }
    return $state
}

function Exit-GovernanceAzContext {
    <# Restores whatever AZURE_CONFIG_DIR was before. Always call from a
       finally block; leaving a program's profile active would hand the next
       command in the same shell the wrong identity. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if (-not $State.Changed) { return }
    if ($null -ne $State.Previous) { $env:AZURE_CONFIG_DIR = $State.Previous }
    else { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
}

function Confirm-GovernanceAzAccount {
    <#
        .SYNOPSIS
        Checks the active az account against what the program declared, and
        makes the declared subscription active.

        This exists because of a real hour lost: az reported
        AADSTS50020 "user account does not exist in tenant", which reads like a
        permissions problem and is actually the wrong account being active.
        The declared signInAs turns that into one clear sentence, before any
        token is requested.

        Never throws — a mismatch is reported and the caller decides. Returns
        $true when the active account matches everything declared.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [switch]$Quiet)

    if (-not $Context) { return $true }
    $who = az account show --query 'user.name' -o tsv 2>$null
    if (-not $who) {
        if (-not $Quiet) { Write-Host "  no az account signed in to this profile — run 'connect'." -ForegroundColor Yellow }
        return $false
    }

    $ok = $true
    if ($Context.SignInAs -and $who -ne $Context.SignInAs) {
        Write-Host ("  signed in as '$who', but this program declares signInAs '$($Context.SignInAs)'. " +
            "Azure DevOps will reject the wrong identity with AADSTS50020 ('does not exist in tenant'), which reads like a permissions fault and is not one. Run 'connect'.") -ForegroundColor Yellow
        $ok = $false
    }
    if ($Context.Subscription) {
        $active = az account show --query 'id' -o tsv 2>$null
        $activeName = az account show --query 'name' -o tsv 2>$null
        if ($active -ne $Context.Subscription -and $activeName -ne $Context.Subscription) {
            az account set --subscription $Context.Subscription 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if (-not $Quiet) { Write-Host "  active subscription set to $($Context.Subscription)" -ForegroundColor DarkGray }
            }
            else {
                Write-Host "  could not make subscription '$($Context.Subscription)' active in this profile — sign in to it with 'connect'." -ForegroundColor Yellow
                $ok = $false
            }
        }
    }
    return $ok
}
