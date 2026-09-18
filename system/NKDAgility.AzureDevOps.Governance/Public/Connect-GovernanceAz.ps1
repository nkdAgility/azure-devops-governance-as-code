function Connect-GovernanceAz {
    <#
        .SYNOPSIS
        Signs the operator in to every Azure DevOps organisation a program
        touches — the target from manifest.yaml, and each source declared in
        sources.yaml — as the identity those organisations actually accept.

        The engine's own error messages could only ever say
        "az login --tenant <org tenant>", because nothing discovered the
        tenant. This does: it asks each organisation which Entra tenant it
        authenticates against, reports whether the current session can already
        reach it, and runs the sign-in for the ones that cannot, pinned to the
        right tenant and scoped to Azure DevOps.

        It ALWAYS reports which az profile directory it is signing in to.
        Azure CLI keeps its whole state — accounts, active subscription, token
        cache — in AZURE_CONFIG_DIR, so a workspace that sets it has an az
        world of its own, and a sign-in performed in a shell without it lands
        somewhere this workspace will never read. Getting that wrong is silent
        and costs an hour, so it is stated every run.

        Read-only against every organisation apart from the sign-in itself.
        -WhatIf prints the commands and changes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProgramPath,
        [string]$Code,
        [string]$Org
    )

    $source   = Import-GovernanceSource -ProgramPath $ProgramPath
    $manifest = $source.Manifest

    # Every organisation this program touches, target first.
    $targets = [ordered]@{}
    $targetOrg = if ($Org) { $Org } else { [string]$manifest.org }
    if ($targetOrg) { $targets[(ConvertTo-AdoOrgUrl -Org $targetOrg)] = 'target' }
    foreach ($c in @($source.Sources.Keys | Sort-Object)) {
        if ($Code -and $c -ne $Code) { continue }
        $u = ConvertTo-AdoOrgUrl -Org ([string]$source.Sources[$c].org)
        if ($targets.Contains($u)) { $targets[$u] = "$($targets[$u]) + source ($c)" } else { $targets[$u] = "source ($c)" }
    }
    if ($targets.Count -eq 0) { throw "No organisations to connect: '$ProgramPath' has no manifest org and no sources.yaml entries." }

    $profileDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
    Write-Host "`nAzure CLI profile: $profileDir" -ForegroundColor Cyan
    Write-Host ("  " + $(if ($env:AZURE_CONFIG_DIR) {
                'AZURE_CONFIG_DIR is set, so this is an az world of its own — a sign-in done in a shell WITHOUT that variable will not be seen here.'
            } else {
                'the machine default — this sign-in affects every other az session for this user.'
            })) -ForegroundColor DarkGray

    $current = (az account show --query 'user.name' -o tsv 2>$null)
    Write-Host "  signed in as: $(if ($current) { $current } else { '(nobody)' })" -ForegroundColor DarkGray

    # Probe each organisation: which tenant, and can we reach it already?
    Write-Host "`nOrganisations" -ForegroundColor Cyan
    $needed = [ordered]@{}
    $entra  = Get-AdoEntraToken -Optional
    foreach ($orgUrl in $targets.Keys) {
        $tenant = Get-AdoOrgTenant -OrgUrl $orgUrl
        $ok     = $entra -and (Test-AdoEntraSession -OrgUrl $orgUrl -Token $entra)
        $state  = if ($ok) { 'reachable now' }
                  elseif (-not $tenant) { 'no Entra tenant advertised - use a PAT (sources.yaml accessToken)' }
                  else { 'SIGN-IN NEEDED' }
        $colour = if ($ok) { 'Green' } elseif ($tenant) { 'Yellow' } else { 'DarkYellow' }
        Write-Host ("  {0,-42} {1,-22} {2}" -f $orgUrl, $targets[$orgUrl], $state) -ForegroundColor $colour
        if ($tenant) { Write-Host "      tenant $tenant" -ForegroundColor DarkGray }
        if (-not $ok -and $tenant) {
            # @($needed[$tenant]) on a missing key yields @($null), which would
            # put a phantom empty organisation at the head of the list.
            if (-not $needed.Contains($tenant)) { $needed[$tenant] = [System.Collections.Generic.List[string]]::new() }
            $needed[$tenant].Add($orgUrl)
        }
    }

    if ($needed.Count -eq 0) {
        Write-Host "`nNothing to do - every organisation is reachable with the current sign-in." -ForegroundColor Green
        return
    }
    if ($needed.Count -gt 1) {
        Write-Warning ("This program spans $($needed.Count) Entra tenants. One az profile holds one ACTIVE account, and the engine mints tokens for whichever that is, " +
            "so signing in to the second will not keep the first usable. Give each organisation its own PAT (sources.yaml accessToken), or run the program's commands one tenant at a time.")
    }

    # 499b84ac-... is the Azure DevOps resource id; the scope pins the sign-in
    # to a token this engine can actually use.
    foreach ($tenant in $needed.Keys) {
        $orgs = @($needed[$tenant]) -join ', '
        $cmd  = "az login --tenant `"$tenant`" --scope `"499b84ac-1321-427f-aa17-267ca6975798/.default`""
        if (-not $PSCmdlet.ShouldProcess("$orgs (tenant $tenant)", 'az login')) {
            Write-Host "`nWould run: $cmd" -ForegroundColor Yellow
            continue
        }
        Write-Host "`nSigning in for $orgs" -ForegroundColor Cyan
        Write-Host "  $cmd" -ForegroundColor DarkGray
        az login --tenant $tenant --scope '499b84ac-1321-427f-aa17-267ca6975798/.default' --output none
        if ($LASTEXITCODE -ne 0) {
            throw ("Sign-in failed for tenant $tenant. On a headless host an interactive sign-in has no window to open: " +
                "add --use-device-code to the command above and complete it in a browser elsewhere.")
        }
        Write-Host "  signed in as: $(az account show --query 'user.name' -o tsv 2>$null)" -ForegroundColor Green
    }

    Write-Host "`nA sign-in lasts as long as the organisation's Conditional Access policy allows - a sign-in frequency of a few hours is common, and the engine reports a rejected token as such. Re-run this when that happens." -ForegroundColor DarkGray
}
