function Get-GovernancePreflightData {
    <#
        .SYNOPSIS
        The GATHER half of preflight (ADR-008): reads one incoming team's
        pre-migration state from its source organisation, and the target-org
        facts the analysis needs (authored UPN resolution), and returns them
        as a plain data document — facts only, no verdicts. The caller writes
        it to preflight-<code>.data.json; Resolve-GovernancePreflightFindings
        turns it into findings offline.

        Read-only against BOTH organisations. Throws on any read failure: a
        half-gathered source must never be analysed as if it were whole.

        Every area path in the document is rooted ('\Project\Node') to match
        the resolved model; source and projected target paths are paired so
        the analysis needs no knowledge of how the projection was made.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][object]$Source,       # the sources.yaml entry for this code
        [Parameter(Mandatory)][object]$Slice,        # Select-GovernanceSubtree output
        [Parameter(Mandatory)][string]$Program,
        [Parameter(Mandatory)][string]$TargetOrgUrl,
        [Parameter(Mandatory)][string]$TargetProject
    )

    $srcOrgUrl   = ConvertTo-AdoOrgUrl -Org ([string]$Source.org)
    $srcProject  = [string]$Source.project
    $srcAreaRoot = '\' + [string]$Source.areaPath
    $srcTeams    = @($Source.teams | Where-Object { $_ })
    $repoInclude = if ($Source.repos) { @($Source.repos.include) } else { $null }

    # ── Source organisation ──────────────────────────────────────────────────
    $authState = Enter-AdoOrgAuth -OrgUrl $srcOrgUrl -AccessTokenRef ([string]$Source.accessToken)
    try {
        try {
            $srcAreas = Get-AdoAreaPathSubtree -OrgUrl $srcOrgUrl -Project $srcProject
        } catch {
            # The first read is where a wrong credential surfaces. Name the route
            # so the report can say WHY, not just "401".
            $route = switch ($authState.Route) {
                'entra'      { 'the signed-in Entra identity' }
                'source-pat' { "the sources.yaml accessToken PAT" }
                'target-pat' { 'the TARGET org PAT as a fallback (it is not valid for the source org unless created for all accessible organisations)' }
                default      { 'an unknown route' }
            }
            $why = if ($authState.Why) { " Entra was not used: $($authState.Why)." } else { '' }
            throw "source organisation $srcOrgUrl refused the read using $route`: $(([string]$_).TrimEnd('.')).$why"
        }
        if (-not $srcAreas.ContainsKey($srcAreaRoot)) {
            throw "source area path '$srcAreaRoot' does not exist in $($Source.org)/$srcProject"
        }
        $usage = Get-AdoWorkItemUsageUnderArea -OrgUrl $srcOrgUrl -Project $srcProject -AreaPath ([string]$Source.areaPath)

        $repos = $null
        if ($null -ne $repoInclude) {
            $all   = Get-AdoRepoSet -OrgUrl $srcOrgUrl -Project $srcProject
            $repos = @($all.Keys | Where-Object { $n = $_; @($repoInclude | Where-Object { $n -like $_ }).Count -gt 0 } | Sort-Object)
        }

        $population = [ordered]@{}   # upn -> source team it was found in
        foreach ($srcTeam in $srcTeams) {
            foreach ($upn in @((Get-AdoTeamMemberUpnSet -OrgUrl $srcOrgUrl -Project $srcProject -Team $srcTeam).Keys | Sort-Object)) {
                $population[$upn] = $srcTeam
            }
        }
    } finally { Exit-AdoOrgAuth -State $authState }

    # ── Projection: source subtree -> target coordinates, with usage per path ─
    $areas = foreach ($srcPath in @($srcAreas.Keys | Where-Object { $_ -eq $srcAreaRoot -or $_ -like "$srcAreaRoot\*" } | Sort-Object)) {
        [ordered]@{
            source    = $srcPath
            target    = $Slice.TargetRoot + $srcPath.Substring($srcAreaRoot.Length)
            workItems = [int]$usage.AreaPaths[$srcPath.TrimStart('\')]
        }
    }

    # ── Target organisation: can every authored person be granted access? ────
    $upnCache   = @{}   # upn -> @{ resolved; suggestions }
    $lookup = {
        param($upn)
        if (-not $upnCache.ContainsKey($upn)) {
            $descriptor  = Find-AdoUserDescriptor -OrgUrl $TargetOrgUrl -Upn $upn
            $suggestions = if ($descriptor) { @() } else { @(Find-AdoUserSuggestion -OrgUrl $TargetOrgUrl -Upn $upn) }
            $upnCache[$upn] = @{ resolved = [bool]$descriptor; suggestions = $suggestions }
        }
        $upnCache[$upn]
    }

    $members    = [System.Collections.Generic.List[object]]::new()
    $teamAdmins = [System.Collections.Generic.List[object]]::new()
    $seenGroups = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($team in $Slice.Teams) {
        foreach ($grp in @($team.securityGroups | Where-Object { $_ })) {
            if (-not $seenGroups.Add($grp.ado)) { continue }
            foreach ($e in @($grp.members | Where-Object { $_ })) {
                $upn = if ($e -is [string]) { if ($e -match '@') { $e } else { $null } }
                       elseif ($e.upn)      { [string]$e.upn }
                       else                 { $null }   # nested groups: audited post-apply, not here
                if (-not $upn) { continue }
                $r = & $lookup $upn
                $members.Add([ordered]@{ upn = $upn; group = [string]$grp.ado; resolved = $r.resolved; suggestions = @($r.suggestions) })
            }
        }
        foreach ($m in @($team.teamAdmins | Where-Object { $_ -and $_.upn })) {
            $upn = [string]$m.upn
            $r = & $lookup $upn
            $teamAdmins.Add([ordered]@{ upn = $upn; team = [string]$team.name; resolved = $r.resolved; suggestions = @($r.suggestions) })
        }
    }

    $tags = [ordered]@{}
    foreach ($k in ($usage.Tags.Keys | Sort-Object)) { $tags[$k] = [int]$usage.Tags[$k] }
    $iterations = [ordered]@{}
    foreach ($k in ($usage.IterationPaths.Keys | Sort-Object)) { $iterations[$k] = [int]$usage.IterationPaths[$k] }

    return [ordered]@{
        schema     = 'nkdagility.governance.preflight-data/1'
        gathered   = (Get-Date).ToUniversalTime().ToString('o')
        program    = $Program
        node       = $Code
        target     = [ordered]@{ org = $TargetOrgUrl; project = $TargetProject; root = [string]$Slice.TargetRoot }
        source     = [ordered]@{
            org         = $srcOrgUrl
            project     = $srcProject
            areaPath    = $srcAreaRoot
            teams       = @($srcTeams)
            repoInclude = $repoInclude
        }
        workItems  = [ordered]@{ count = [int]$usage.WorkItemCount }
        areas      = @($areas)
        tags       = $tags
        iterations = $iterations
        repos      = $repos
        population = $population
        authored   = [ordered]@{ members = @($members); teamAdmins = @($teamAdmins) }
    }
}
