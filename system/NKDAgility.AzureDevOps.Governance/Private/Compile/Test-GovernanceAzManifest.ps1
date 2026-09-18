function Test-GovernanceAzManifest {
    <#
        .SYNOPSIS
        Validates the optional manifest.yaml `azure:` block (ADR-012) offline.
        Returns an issue string per problem; empty = valid.

          azure:
            profile:      contoso                # its own az world
            tenant:       <guid>                    # else discovered from the org
            subscription: <guid or subscription name>
            signInAs:     someone@customer.com      # a UPN, never a secret

        A typo here is expensive in a way most config typos are not: the run
        still works, against the wrong identity or the wrong az profile, and
        only fails later with an Entra error that reads like a permissions
        fault. So every key is checked and unknown keys are rejected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest)

    $issues = @()
    $az = $Manifest.azure
    if (-not $az) { return $issues }

    if ($az -isnot [System.Collections.IDictionary]) {
        return @("manifest.yaml azure must be a map of profile / tenant / subscription / signInAs")
    }

    $known = @('profile', 'tenant', 'subscription', 'signInAs')
    foreach ($k in @($az.Keys)) {
        if ($k -notin $known) { $issues += "manifest.yaml azure '$k' is not an azure field. Known: $($known -join ', ')" }
    }

    foreach ($k in $known) {
        if ($az.Contains($k) -and $az[$k] -isnot [string]) { $issues += "manifest.yaml azure '$k' must be a string" }
    }

    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    if ($az.tenant -and ([string]$az.tenant) -notmatch $guid) {
        $issues += "manifest.yaml azure tenant must be a GUID, got '$($az.tenant)'"
    }
    # subscription accepts a name as well as an id, so only a GUID-ish value is checked.
    if ($az.signInAs -and ([string]$az.signInAs) -notmatch '@') {
        $issues += "manifest.yaml azure signInAs must be a UPN (it is an identity, never a secret), got '$($az.signInAs)'"
    }
    if ($az.profile -and ([string]$az.profile).Trim() -eq '') {
        $issues += "manifest.yaml azure profile is empty - omit it for the machine default, or name a profile"
    }

    return $issues
}
