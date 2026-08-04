# Compile stage — projects the authored hierarchy into the resolved desired state.
# The hierarchy is the product; teams, area paths, repos, pipelines, and permissions
# are all derived here.
#
# Node kinds:
#   team (delivery/structural/portfolio)  — real ADO team created
#   sideload   — `sideload: <code>` (or a list): area path ONLY — added to the
#                listed teams' boards. ZERO security: structural authority
#                always stays with the team's home area. (`owner:` removed.)
#   area       — `team: none`: governed structure attached to nothing
# A node with `sideload:` AND an explicit `type:` is BOTH: its own team, plus
# board visibility for the listed teams.

# Team types drive planning behaviour: area sub-tree visibility, backlog levels,
# and iteration scope. Position in the tree supplies the default type; nodes in
# hierarchy.yaml may override with `type:` and `iterations:`. cadence.yaml
# `teamTypes:` overrides these built-in settings per type.
$script:TeamTypeNames       = @('portfolio', 'structural', 'delivery')
$script:IterationScopeNames = @('sprints', 'seasons', 'none')
$script:DefaultTeamTypes = @{
    portfolio  = @{ includeSubAreas = $true;  backlogs = @('Initiatives');                 iterationScope = 'seasons' }
    structural = @{ includeSubAreas = $true;  backlogs = @('Initiatives', 'Requirements'); iterationScope = 'seasons' }
    delivery   = @{ includeSubAreas = $false; backlogs = @('Requirements', 'Stories');     iterationScope = 'sprints' }
}

function Get-TeamTypeDefs {
    <# Merges cadence.yaml teamTypes over the built-in defaults. Throws on
       unknown type names or iteration scope values — config errors must fail
       the build, not silently fall back. #>
    [CmdletBinding()]
    param([object]$Cadence)

    $defs = @{}
    foreach ($t in $script:TeamTypeNames) {
        $defs[$t] = @{
            includeSubAreas = $script:DefaultTeamTypes[$t].includeSubAreas
            backlogs        = @($script:DefaultTeamTypes[$t].backlogs)
            iterationScope  = $script:DefaultTeamTypes[$t].iterationScope
        }
    }
    if ($Cadence -and $Cadence.teamTypes) {
        foreach ($key in @($Cadence.teamTypes.Keys)) {
            if ($key -notin $script:TeamTypeNames) {
                throw "cadence.yaml teamTypes: unknown team type '$key' (expected one of: $($script:TeamTypeNames -join ', '))."
            }
            $spec = $Cadence.teamTypes[$key]
            if ($null -ne $spec.includeSubAreas) { $defs[$key].includeSubAreas = [bool]$spec.includeSubAreas }
            if ($spec.backlogs)                  { $defs[$key].backlogs = @($spec.backlogs) }
            if ($spec.iterations)                { $defs[$key].iterationScope = [string]$spec.iterations }
            if ($defs[$key].iterationScope -notin $script:IterationScopeNames) {
                throw "cadence.yaml teamTypes.${key}: unknown iterations value '$($defs[$key].iterationScope)' (expected: $($script:IterationScopeNames -join ', '))."
            }
        }
    }
    return $defs
}

function Add-SideloadEntry {
    <# Records that a node's area path is SIDELOADED onto a team's board —
       area path visibility ONLY, no structural authority. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Path,
        [bool]$IncludeSubAreas
    )
    if (-not $Ctx.Sideloaded.ContainsKey($Key)) {
        $Ctx.Sideloaded[$Key] = [System.Collections.Generic.List[object]]::new()
    }
    $Ctx.Sideloaded[$Key].Add([ordered]@{ path = $Path; includeSubAreas = [bool]$IncludeSubAreas })
}

function Get-NodeKeyList {
    <# Normalizes a team-code reference value (string or list) to a string array. #>
    [CmdletBinding()]
    param($Value)
    return @(@($Value) | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Add-NodeRepos {
    <# Collects a node's declared repos. Entries are bare names (string or
       { name, innerOSS }); the resolved repo name is ALWAYS prefixed with the
       node's hierarchy code so repos sort under their node:
       'My Repo' on PTL-FND -> 'PTL-FND-My-Repo' (spaces become dashes).
       Each repo is owned by the node's own team, or by its first sideloader
       when the node has no team. ACLs (everyone reads, owner writes, innerOSS
       opens branch/PR contribution) are attached later, once groups exist. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$OwnerKey,
        [AllowNull()][AllowEmptyString()][string]$NodeCode
    )
    $prefix = if ($NodeCode) { $NodeCode } else { $OwnerKey }
    foreach ($r in @($Node.repos | Where-Object { $_ })) {
        $bare = if ($r -is [string]) { $r } else { [string]$r.name }
        if (-not $bare) {
            throw "hierarchy.yaml: node '$($Node.name)' has a repo entry without a name."
        }
        if (-not $OwnerKey) {
            throw "hierarchy.yaml: node '$($Node.name)' declares repos but has no owning team - give it its own team or a sideload:."
        }
        $Ctx.Repos.Add([ordered]@{
            name     = "$prefix-$($bare.Trim() -replace '\s+', '-')"
            areaPath = $Path
            owner    = $OwnerKey
            innerOSS = if ($r -is [string]) { $false } else { [bool]$r.innerOSS }
        })
    }
}

function Add-TeamNode {
    <# Recursively projects a team node (and its nested sub-teams) under a band.
       Only first-level teams get a pipeline folder; sub-teams share the parent's. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$ParentTeamName,
        [Parameter(Mandatory)][string]$QualifiedParentName,
        [Parameter(Mandatory)][string]$ParentCodePath,
        [Parameter(Mandatory)][bool]$IsFirstLevel,
        [Parameter(Mandatory)][string]$ProgramRoot,
        [Parameter(Mandatory)][hashtable]$Ctx
    )

    $path           = "$ParentPath\$($Node.name)"
    $codePath       = "$ParentCodePath-$($Node.short)"
    $qualifiedName  = "$QualifiedParentName · $($Node.name)"   # e.g. 'Portal · Foundation'
    $children       = @($Node.teams | Where-Object { $null -ne $_ })
    $hasChildren    = $children.Count -gt 0

    if ($null -ne $Node.owner) {
        throw "hierarchy.yaml: node '$($Node.name)' uses 'owner:', which has been removed. Use 'sideload:' - it attaches the area path to the listed teams' boards and carries NO security."
    }
    $sideloaders    = @(Get-NodeKeyList $Node.sideload)
    $isTeamless     = ("$($Node.team)" -eq 'none')
    # sideload WITHOUT an explicit type = area only; WITH a type = team too.
    $isAreaOnly     = (-not $isTeamless) -and $sideloaders.Count -gt 0 -and -not $Node.type

    $kind = if ($isTeamless) { 'area' } elseif ($isAreaOnly) { 'sideload' } else { 'team' }
    $area = [ordered]@{ path = $path; kind = $kind }
    if ($Node.short) { $area.short = $Node.short; $area.code = $codePath }
    if ($sideloaders.Count -gt 0) { $area.sideload = $sideloaders }
    $Ctx.AreaPaths.Add($area)

    # Repo ownership: the node's own team, else its first sideloader.
    $nodeCode = if ($Node.short) { $codePath } else { $null }

    if ($isTeamless) {
        # Governed structure attached to nothing — no team, no consumer.
        Add-NodeRepos -Ctx $Ctx -Node $Node -Path $path -OwnerKey $null -NodeCode $null
    }
    elseif ($isAreaOnly) {
        foreach ($s in $sideloaders) { Add-SideloadEntry -Ctx $Ctx -Key $s -Path $path -IncludeSubAreas $hasChildren }
        Add-NodeRepos -Ctx $Ctx -Node $Node -Path $path -OwnerKey $sideloaders[0] -NodeCode $nodeCode
    }
    else {
        $type = if ($Node.type) { [string]$Node.type }
                elseif ($hasChildren) { 'structural' }
                else { 'delivery' }
        if ($type -notin $script:TeamTypeNames) {
            throw "hierarchy.yaml: node '$($Node.name)' has unknown type '$type' (expected one of: $($script:TeamTypeNames -join ', '))."
        }
        $typeDef   = $Ctx.TypeDefs[$type]
        $iterScope = if ($Node.iterations) { [string]$Node.iterations } else { $typeDef.iterationScope }
        if ($iterScope -notin $script:IterationScopeNames) {
            throw "hierarchy.yaml: node '$($Node.name)' has unknown iterations value '$iterScope' (expected: $($script:IterationScopeNames -join ', '))."
        }

        # A team only gets a pipeline folder when it declares it has builds of
        # its own: `pipelineFolder: true` in hierarchy.yaml. Default: no folder.
        $folder = if ($IsFirstLevel -and [bool]$Node.pipelineFolder) { $path.Substring($ProgramRoot.Length) } else { $null }
        $Ctx.Teams.Add([ordered]@{
            name            = $qualifiedName
            short           = $Node.short
            kind            = 'team'
            type            = $type
            parent          = $ParentTeamName
            codePath        = $codePath
            defaultAreaPath = $path
            includeSubAreas = $typeDef.includeSubAreas
            iterationScope  = $iterScope
            backlogs        = @($typeDef.backlogs)
            pipelineFolder  = $folder
        })
        # Team + sideload combo: the team exists AND the listed teams see the
        # path on their boards (board scope only, never authority).
        foreach ($s in $sideloaders) { Add-SideloadEntry -Ctx $Ctx -Key $s -Path $path -IncludeSubAreas $hasChildren }
        Add-NodeRepos -Ctx $Ctx -Node $Node -Path $path -OwnerKey $codePath -NodeCode $codePath
    }

    foreach ($child in $children) {
        Add-TeamNode -Node $child -ParentPath $path -ParentTeamName $qualifiedName -QualifiedParentName $qualifiedName -ParentCodePath $codePath -IsFirstLevel $false -ProgramRoot $ProgramRoot -Ctx $Ctx
    }
}

function Resolve-Governance {
    <#
        .SYNOPSIS
        Projects the authored hierarchy + access convention into the resolved
        desired-state model consumed by plan / apply / audit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Source,
        [Parameter(Mandatory)][object]$Access,
        [Parameter(Mandatory)][string]$SourceHash,
        [hashtable]$Members = @{},
        [object]$Cadence    = $null   # optional cadence.yaml content for iteration generation
    )

    $typeDefs     = Get-TeamTypeDefs -Cadence $Cadence
    $portfolioDef = $typeDefs['portfolio']

    $ctx = @{
        AreaPaths       = [System.Collections.Generic.List[object]]::new()
        Teams           = [System.Collections.Generic.List[object]]::new()
        Repos           = [System.Collections.Generic.List[object]]::new()
        PipelineFolders = [System.Collections.Generic.List[object]]::new()
        Sideloaded      = @{}   # code -> paths SIDELOADED onto that team (board only, zero security)
        TypeDefs        = $typeDefs
    }

    $program = $Manifest.program
    $root    = "\$program"

    $ctx.AreaPaths.Add([ordered]@{ path = $root; kind = 'portfolio' })
    $ctx.Teams.Add([ordered]@{
        name            = $program
        short           = $null
        kind            = 'portfolio'
        type            = 'portfolio'
        parent          = $null
        codePath        = $program
        defaultAreaPath = $root
        includeSubAreas = $portfolioDef.includeSubAreas
        iterationScope  = $portfolioDef.iterationScope
        backlogs        = @($portfolioDef.backlogs)
        pipelineFolder  = $null
    })

    foreach ($product in @($Source.products)) {
        $productPath = "$root\$($product.name)"

        if ($null -ne $product.owner) {
            throw "hierarchy.yaml: product '$($product.name)' uses 'owner:', which has been removed. Use 'sideload:' - it attaches the area path to the listed teams' boards and carries NO security."
        }
        $sideloaders    = @(Get-NodeKeyList $product.sideload)
        $isTeamless     = ("$($product.team)" -eq 'none')
        # sideload WITHOUT an explicit type = area only; WITH a type = team too.
        $isAreaOnly     = (-not $isTeamless) -and $sideloaders.Count -gt 0 -and -not $product.type

        $kind = if ($isTeamless) { 'area' } elseif ($isAreaOnly) { 'sideload' } else { 'product' }
        $area = [ordered]@{ path = $productPath; kind = $kind }
        if ($product.short) { $area.short = $product.short; $area.code = $product.short }
        if ($null -ne $product.dpm) { $area.dpm = $product.dpm }
        if ($product.scope) { $area.scope = $product.scope }
        if ($sideloaders.Count -gt 0) { $area.sideload = $sideloaders }
        $ctx.AreaPaths.Add($area)

        if ($isTeamless) {
            Add-NodeRepos -Ctx $ctx -Node $product -Path $productPath -OwnerKey $null -NodeCode $null
        }
        elseif ($isAreaOnly) {
            foreach ($s in $sideloaders) { Add-SideloadEntry -Ctx $ctx -Key $s -Path $productPath -IncludeSubAreas $true }
            Add-NodeRepos -Ctx $ctx -Node $product -Path $productPath -OwnerKey $sideloaders[0] -NodeCode $product.short
        }
        else {
            # Products opt in the same way teams do: `pipelineFolder: true`
            # when the product has builds of its own. Default: no folder.
            $productHasBuilds = [bool]$product.pipelineFolder
            $teamObj = [ordered]@{
                name            = "$($product.name) (portfolio)"
                short           = $product.short
                kind            = 'product'
                type            = 'portfolio'
                parent          = $program
                codePath        = $product.short
                defaultAreaPath = $productPath
                includeSubAreas = $portfolioDef.includeSubAreas
                iterationScope  = $portfolioDef.iterationScope
                backlogs        = @($portfolioDef.backlogs)
                pipelineFolder  = if ($productHasBuilds) { $productPath.Substring($root.Length) } else { $null }
            }
            if ($product.scope) { $teamObj.scope = $product.scope }
            $ctx.Teams.Add($teamObj)
            foreach ($s in $sideloaders) { Add-SideloadEntry -Ctx $ctx -Key $s -Path $productPath -IncludeSubAreas $true }
            Add-NodeRepos -Ctx $ctx -Node $product -Path $productPath -OwnerKey $product.short -NodeCode $product.short
        }

        # Free-form bands: each section is { name: <display name>, items: [...] }.
        # Display names may contain any characters (parentheses etc.). Items are
        # teams, sideload: areas, or team: none placeholders — all band-agnostic.
        foreach ($section in @($product.sections | Where-Object { $null -ne $_ })) {
            if ($section -is [string]) {
                throw "hierarchy.yaml: product '$($product.name)' uses the legacy section keyword '$section'. Sections are now objects: - name: <display name> / items: [...]."
            }
            $bandName = [string]$section.name
            if (-not $bandName) {
                throw "hierarchy.yaml: product '$($product.name)' has a section without a name."
            }
            $bandPath = "$productPath\$bandName"
            $ctx.AreaPaths.Add([ordered]@{ path = $bandPath; kind = 'band' })

            foreach ($node in @($section.items | Where-Object { $null -ne $_ })) {
                Add-TeamNode -Node $node -ParentPath $bandPath -ParentTeamName $product.name -QualifiedParentName $product.name -ParentCodePath $product.short -IsFirstLevel $true -ProgramRoot $root -Ctx $ctx
            }
        }
    }

    # Attach sideloaded area paths + derive security groups per team.
    # sideload is area-path visibility ONLY: it joins the team's areaConfig
    # (board scope) but never its authorityPaths (structural authority stays
    # with the team's home area alone).
    # Membership governance activates once ANY members file exists: from then on
    # every active (non-future) team must have one, and an empty role list means
    # "this group must have no members" — extras become drift, not noise.
    $membershipGoverned = ($Members.Count -gt 0)
    $today              = (Get-Date).Date

    foreach ($team in $ctx.Teams) {
        $areaConfig = [System.Collections.Generic.List[object]]::new()
        $areaConfig.Add([ordered]@{ path = $team.defaultAreaPath; includeSubAreas = $team.includeSubAreas })
        if ($team.codePath -and $ctx.Sideloaded.ContainsKey($team.codePath)) {
            foreach ($entry in $ctx.Sideloaded[$team.codePath]) { $areaConfig.Add($entry) }
        }
        $team.areaConfig     = $areaConfig
        $team.authorityPaths = @($team.defaultAreaPath)

        $groupSpecs = if ($team.kind -eq 'team') { $Access.teamGroups } else { $Access.containerGroups }
        $memberKey  = $team.codePath
        if ($membershipGoverned -and $team.scope -ne 'future' -and -not $Members.ContainsKey($memberKey)) {
            throw "members file missing for team '$($team.name)': programs/<program>/members/$memberKey.yaml is required once membership governance is active."
        }
        $memberSet  = if ($Members.ContainsKey($memberKey)) { $Members[$memberKey] } else { $null }
        $groups = [System.Collections.Generic.List[object]]::new()
        foreach ($spec in @($groupSpecs)) {
            # Entries: plain UPN string (legacy) or object with upn:/group: plus
            # reason (access grants must carry a recorded reason) and optional
            # expires (past-dated entries leave the desired state — time-boxed
            # guest access falls out of this).
            $roleMembers = [System.Collections.Generic.List[object]]::new()
            if ($memberSet -and $memberSet.ContainsKey($spec.role)) {
                foreach ($entry in @($memberSet[$spec.role] | Where-Object { $_ })) {
                    if ($entry -is [string]) {
                        $roleMembers.Add([ordered]@{ upn = $entry })
                        continue
                    }
                    $norm = if ($entry.upn)   { [ordered]@{ upn = [string]$entry.upn } }
                            elseif ($entry.group) { [ordered]@{ group = [string]$entry.group } }
                            else { throw "members/$memberKey.yaml role '$($spec.role)': entry must be a UPN string or an object with upn: or group:." }
                    if ($entry.reason) { $norm.reason = [string]$entry.reason }
                    if ($entry.expires) {
                        $exp = [datetime]$entry.expires
                        if ($exp.Date -lt $today) { continue }   # expired -> no longer desired
                        $norm.expires = $exp.ToString('yyyy-MM-dd')
                    }
                    $roleMembers.Add($norm)
                }
            }
            $groups.Add([ordered]@{
                role    = $spec.role
                ado     = ($spec.ado -replace '\{key\}', $team.codePath)
                members = $roleMembers
            })
        }
        $team.securityGroups = $groups
    }

    # Repo ACLs: everyone in the project reads; only the owning team's
    # contributor group writes; innerOSS additionally opens branch creation and
    # PR contribution to everyone (fork/PR flow without direct push).
    $teamByCode = @{}
    foreach ($team in $ctx.Teams) {
        if ($team.codePath) { $teamByCode[$team.codePath] = $team }
    }
    foreach ($repo in $ctx.Repos) {
        $ownerTeam = $teamByCode[$repo.owner]
        if (-not $ownerTeam) {
            throw "hierarchy.yaml: repo '$($repo.name)' is owned by '$($repo.owner)', which does not resolve to any team."
        }
        $writeGroup = @($ownerTeam.securityGroups | Where-Object { $_.role -eq 'contributor' })
        if ($writeGroup.Count -eq 0) { $writeGroup = @($ownerTeam.securityGroups | Where-Object { $_.role -eq 'admin' }) }
        $acl = [System.Collections.Generic.List[object]]::new()
        $acl.Add([ordered]@{ principal = 'project-valid-users'; permission = 'read' })
        if ($writeGroup.Count -gt 0) {
            $acl.Add([ordered]@{ principal = $writeGroup[0].ado; permission = 'write' })
        }
        if ($repo.innerOSS) {
            $acl.Add([ordered]@{ principal = 'project-valid-users'; permission = 'innersource' })
        }
        $repo.acl = $acl
    }

    # Pipeline folders: the folder structure (mirroring the area path, truncated
    # at the first-level team) plus the owning team's permissions from the roles
    # catalog. Governance owns the folder + ACL; teams create the definitions.
    foreach ($team in $ctx.Teams) {
        if (-not $team.pipelineFolder) { continue }
        if ($team.scope -eq 'future') { continue }   # scope:future products are invisible
        $acl = [System.Collections.Generic.List[object]]::new()
        foreach ($group in $team.securityGroups) {
            $roleDef = $Access.roles[[string]$group.role]
            $permission = if ($roleDef) { $roleDef.pipelines } else { $null }
            if (-not $permission) { continue }
            $acl.Add([ordered]@{ group = $group.ado; permission = $permission })
        }
        $ctx.PipelineFolders.Add([ordered]@{
            path = $team.pipelineFolder
            team = $team.name
            acl  = $acl
        })
    }

    # Structural authority: each {key}-Admins group gets node-management rights
    # over the team's HOME area only (delegated ownership — structural
    # permission, not membership). Sideloaded paths carry ZERO security:
    # board visibility never grants authority.
    $authority = [System.Collections.Generic.List[object]]::new()
    foreach ($team in $ctx.Teams) {
        if ($team.scope -eq 'future') { continue }
        $adminGroup = @($team.securityGroups | Where-Object { $_.role -eq 'admin' }) | Select-Object -First 1
        if (-not $adminGroup) { continue }
        $authority.Add([ordered]@{
            group = $adminGroup.ado
            team  = $team.name
            paths = @($team.authorityPaths)
        })
    }

    # Project identity: manifest project block with defaults. name defaults to
    # the program name; process/visibility/sourceControl only apply at creation.
    $projectSpec = $Manifest.project
    $projectDecl = [ordered]@{
        name          = if ($projectSpec.name)          { [string]$projectSpec.name }          else { $program }
        process       = if ($projectSpec.process)       { [string]$projectSpec.process }       else { 'Agile' }
        visibility    = if ($projectSpec.visibility)    { [string]$projectSpec.visibility }    else { 'private' }
        sourceControl = if ($projectSpec.sourceControl) { [string]$projectSpec.sourceControl } else { 'git' }
    }

    $resolved = [ordered]@{
        program         = $program
        project         = $projectDecl
        org             = $Manifest.org
        generated       = (Get-Date).ToUniversalTime().ToString('o')
        sourceHash      = "sha256:$SourceHash"
        areaPaths       = $ctx.AreaPaths
        teams           = $ctx.Teams
        repos           = $ctx.Repos
        pipelineFolders = $ctx.PipelineFolders
        structuralAuthority = $authority
        stakeholders    = [ordered]@{
            accessLevel = $Access.stakeholders.accessLevel
            ado         = $Access.stakeholders.ado
            scope       = $Access.stakeholders.scope
        }
    }

    # Governed tag taxonomy (optional — hierarchy.yaml `tags:` block).
    # Decision-0041: everything that is not a team becomes a tag, so the
    # sanctioned vocabulary is structural config, not free-form user data.
    if ($Source.tags) {
        $resolved['tags'] = [ordered]@{
            sanctioned         = @($Source.tags.sanctioned | Where-Object { $_ })
            disallowedPatterns = @($Source.tags.disallowedPatterns | Where-Object { $_ })
        }
    }

    # Iteration calendar (optional — only if cadence.yaml is present)
    if ($Cadence -and $Cadence.iterations) {
        $calendar = Get-IterationCalendar -Cadence $Cadence -ProgramRoot $root
        $resolved['iterations'] = [ordered]@{
            programRoot = $root
            config      = $Cadence.iterations
            paths       = ConvertTo-FlatIterationPaths -Calendar $calendar
        }
    }

    return $resolved
}
