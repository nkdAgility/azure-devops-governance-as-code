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

function Get-SystemDefs {
    <# Normalizes the optional systems.yaml `systems:` map. A system is a named,
       reusable set of governed sub-elements stamped onto a team via `systems:`
       in hierarchy.yaml. v1 supports `areas:` — child area paths under the
       team's home area, surfaced on the team's own board (visibility only,
       zero security). Unknown keys throw: config errors must fail the build. #>
    [CmdletBinding()]
    param([object]$Systems)

    $defs = @{}
    if (-not $Systems -or -not $Systems.systems) { return $defs }
    foreach ($name in @($Systems.systems.Keys)) {
        $spec = $Systems.systems[$name]
        if (-not $spec) { throw "systems.yaml: system '$name' is empty." }
        foreach ($key in @($spec.Keys)) {
            if ($key -ne 'areas') {
                throw "systems.yaml: system '$name' has unknown key '$key' (expected: areas)."
            }
        }
        $areas = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($spec.areas | Where-Object { $_ })) {
            $areaName = if ($entry -is [string]) { $entry } else {
                foreach ($key in @($entry.Keys)) {
                    if ($key -ne 'name') {
                        throw "systems.yaml: system '$name' area entry has unknown key '$key' (expected: name)."
                    }
                }
                [string]$entry.name
            }
            if ([string]::IsNullOrWhiteSpace($areaName)) {
                throw "systems.yaml: system '$name' has an area entry without a name."
            }
            $areas.Add($areaName.Trim())
        }
        if ($areas.Count -eq 0) { throw "systems.yaml: system '$name' declares no areas." }
        $defs[$name] = @{ areas = @($areas) }
    }
    return $defs
}

function Add-NodeSystems {
    <# Expands a team node's `systems:` list. Each named system stamps its child
       areas under the team's HOME area and — for teams that do not already see
       sub-areas (includeSubAreas false) — sideloads them onto the team's own
       board. Board visibility only: structural authority stays with the home
       area, no new team, no groups, no members file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CodePath,
        [Parameter(Mandatory)][bool]$IncludeSubAreas,
        [AllowEmptyCollection()][string[]]$ReservedNames = @(),
        [AllowNull()][AllowEmptyString()][string]$Scope
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $ReservedNames) { [void]$seen.Add($r) }
    foreach ($sysName in @(Get-NodeKeyList $Node.systems)) {
        if (-not $Ctx.SystemDefs.ContainsKey($sysName)) {
            $known = if ($Ctx.SystemDefs.Count -gt 0) { $Ctx.SystemDefs.Keys -join ', ' } else { 'none - add a systems.yaml' }
            throw "hierarchy.yaml: node '$($Node.name)' applies unknown system '$sysName' (known systems: $known)."
        }
        foreach ($areaName in $Ctx.SystemDefs[$sysName].areas) {
            if (-not $seen.Add($areaName)) {
                throw "hierarchy.yaml: node '$($Node.name)': system '$sysName' area '$areaName' collides with an existing child of the node."
            }
            $childPath = "$Path\$areaName"
            $area = [ordered]@{ path = $childPath; kind = 'system'; system = $sysName }
            if ($Scope) { $area.scope = $Scope }
            if (-not $IncludeSubAreas) {
                # The team's board does not include sub-areas, so the system
                # area must be sideloaded onto it explicitly. Teams that DO
                # include sub-areas already see it — a sideload entry there
                # would duplicate the areaConfig entry and read as drift.
                $area.sideload = @($CodePath)
                Add-SideloadEntry -Ctx $Ctx -Key $CodePath -Path $childPath -IncludeSubAreas $false
            }
            $Ctx.AreaPaths.Add($area)
        }
    }
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

function ConvertTo-MemberEntryList {
    <#
        .SYNOPSIS
        Normalizes a members-file entry list. Entries: plain UPN string
        (legacy) or object with upn:/group: plus reason (access grants must
        carry a recorded reason) and optional expires — past-dated entries
        leave the desired state (time-boxed guest access falls out of this).
    #>
    [CmdletBinding()]
    param(
        $Entries,
        [Parameter(Mandatory)][datetime]$Today,
        [Parameter(Mandatory)][string]$Context
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Entries | Where-Object { $_ })) {
        if ($entry -is [string]) {
            $out.Add([ordered]@{ upn = $entry })
            continue
        }
        $norm = if ($entry.upn)   { [ordered]@{ upn = [string]$entry.upn } }
                elseif ($entry.group) { [ordered]@{ group = [string]$entry.group } }
                else { throw "${Context}: entry must be a UPN string or an object with upn: or group:." }
        if ($entry.reason) { $norm.reason = [string]$entry.reason }
        if ($entry.expires) {
            $exp = [datetime]$entry.expires
            if ($exp.Date -lt $Today) { continue }   # expired -> no longer desired
            $norm.expires = $exp.ToString('yyyy-MM-dd')
        }
        $out.Add($norm)
    }
    # Comma operator: return the list AS a list — PowerShell would otherwise
    # enumerate it, collapsing empty to $null and one entry to a bare object.
    return , $out
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
    <# Recursively projects a team node (and its nested sub-teams) under a structural node.
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

    # systems attach sub-elements to a team's own board — a node with no team
    # of its own has no board for them to land on.
    if (@(Get-NodeKeyList $Node.systems).Count -gt 0 -and ($isTeamless -or $isAreaOnly)) {
        throw "hierarchy.yaml: node '$($Node.name)' applies systems: but has no team of its own - systems attach to a team's board."
    }

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
        Add-NodeSystems -Ctx $Ctx -Node $Node -Path $path -CodePath $codePath `
            -IncludeSubAreas $typeDef.includeSubAreas -ReservedNames @($children | ForEach-Object { [string]$_.name })
    }

    foreach ($child in $children) {
        Add-TeamNode -Node $child -ParentPath $path -ParentTeamName $qualifiedName -QualifiedParentName $qualifiedName -ParentCodePath $codePath -IsFirstLevel $false -ProgramRoot $ProgramRoot -Ctx $Ctx
    }
}

# Default identity of the tag anchor work item. ADO has no create-tag API
# (POST /_apis/wit/tags returns 405) and purges tags that no work item
# references, so the ONLY way to make a sanctioned tag exist is to hold it on a
# work item. Apply maintains exactly one such item per project (ADR-006).
# Plain ASCII in the title: it round-trips through a WIQL string literal.
$script:TagAnchorDefaults = @{
    enabled      = $true
    title        = '[Governance] Tag taxonomy anchor - do not delete'
    workItemType = 'Task'
    areaPath     = ''   # empty = project root
    state        = ''   # empty = process default for a new work item
}

function Resolve-TagAnchor {
    <# Normalizes the optional taxonomy.yaml `tags.anchor` block over the
       built-in defaults. Config errors fail the build — a typo here would
       otherwise surface mid-apply against a live project. #>
    [CmdletBinding()]
    param([object]$Anchor)

    $out = [ordered]@{}
    foreach ($k in @('enabled', 'title', 'workItemType', 'areaPath', 'state')) {
        $out[$k] = $script:TagAnchorDefaults[$k]
    }
    if (-not $Anchor) { return $out }

    foreach ($key in @($Anchor.Keys)) {
        if ($key -notin $out.Keys) {
            throw "taxonomy.yaml tags.anchor: unknown key '$key' (expected one of: $($out.Keys -join ', '))."
        }
    }
    if ($null -ne $Anchor.enabled) { $out['enabled'] = [bool]$Anchor.enabled }
    foreach ($key in @('title', 'workItemType', 'areaPath', 'state')) {
        if ($null -ne $Anchor.$key) { $out[$key] = [string]$Anchor.$key }
    }
    if ($out['enabled']) {
        if ([string]::IsNullOrWhiteSpace($out['title']))        { throw "taxonomy.yaml tags.anchor.title: must not be empty." }
        if ([string]::IsNullOrWhiteSpace($out['workItemType'])) { throw "taxonomy.yaml tags.anchor.workItemType: must not be empty." }
    }
    return $out
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
        [object]$Cadence    = $null,  # optional cadence.yaml content for iteration generation
        [object]$Taxonomy   = $null,  # optional taxonomy.yaml content for governed vocabularies
        [object]$Systems    = $null   # optional systems.yaml content for reusable team systems
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
        SystemDefs      = Get-SystemDefs -Systems $Systems
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

        if (@(Get-NodeKeyList $product.systems).Count -gt 0 -and ($isTeamless -or $isAreaOnly)) {
            throw "hierarchy.yaml: product '$($product.name)' applies systems: but has no team of its own - systems attach to a team's board."
        }

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
            Add-NodeSystems -Ctx $ctx -Node $product -Path $productPath -CodePath $product.short `
                -IncludeSubAreas $portfolioDef.includeSubAreas -Scope $product.scope `
                -ReservedNames @(@($product.sections | Where-Object { $null -ne $_ }) | ForEach-Object { [string]$_.name })
        }

        # Free-form structural nodes: each section is { name: <display name>, items: [...] }.
        # Display names may contain any characters (parentheses etc.). Items are
        # teams, sideload: areas, or team: none placeholders — all structure-agnostic.
        foreach ($section in @($product.sections | Where-Object { $null -ne $_ })) {
            if ($section -is [string]) {
                throw "hierarchy.yaml: product '$($product.name)' uses the legacy section keyword '$section'. Sections are now objects: - name: <display name> / items: [...]."
            }
            $structuralName = [string]$section.name
            if (-not $structuralName) {
                throw "hierarchy.yaml: product '$($product.name)' has a section without a name."
            }
            $structuralPath = "$productPath\$structuralName"
            $ctx.AreaPaths.Add([ordered]@{ path = $structuralPath; kind = 'structural' })

            foreach ($node in @($section.items | Where-Object { $null -ne $_ })) {
                Add-TeamNode -Node $node -ParentPath $structuralPath -ParentTeamName $product.name -QualifiedParentName $product.name -ParentCodePath $product.short -IsFirstLevel $true -ProgramRoot $root -Ctx $ctx
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
            $entries = if ($memberSet -and $memberSet.ContainsKey($spec.role)) { $memberSet[$spec.role] } else { @() }
            $groups.Add([ordered]@{
                role    = $spec.role
                ado     = ($spec.ado -replace '\{key\}', $team.codePath)
                members = (ConvertTo-MemberEntryList -Entries $entries -Today $today -Context "members/$memberKey.yaml role '$($spec.role)'")
            })
        }
        $team.securityGroups = $groups

        # teamAdmins: governs the ADO Team Administrator role on the team
        # itself — exact-match like group membership: an empty (or absent)
        # list means the team must have NO administrators.
        $adminEntries = if ($memberSet -and $memberSet.ContainsKey('teamAdmins')) { $memberSet['teamAdmins'] } else { @() }
        $team.teamAdmins = (ConvertTo-MemberEntryList -Entries $adminEntries -Today $today -Context "members/$memberKey.yaml teamAdmins")
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

    # Governed tag taxonomy (optional — taxonomy.yaml `tags:` block).
    # Decision-0041: everything that is not a team becomes a tag, so the
    # sanctioned vocabulary is structural config, not free-form user data.
    # The taxonomy moved out of hierarchy.yaml — a flat list of allowed strings
    # is not part of the product/team tree. Fail loudly rather than silently
    # ignoring a taxonomy left behind in the old location.
    if ($Source.tags) {
        throw ("hierarchy.yaml: the 'tags:' block has moved to taxonomy.yaml. " +
               "Move it to programs/<program>/taxonomy.yaml unchanged (same 'tags:' key, " +
               "same 'sanctioned:' and 'disallowedPatterns:' lists) and remove it from hierarchy.yaml.")
    }
    if ($Taxonomy -and $Taxonomy.tags) {
        $resolved['tags'] = [ordered]@{
            sanctioned         = @($Taxonomy.tags.sanctioned | Where-Object { $_ })
            disallowedPatterns = @($Taxonomy.tags.disallowedPatterns | Where-Object { $_ })
            anchor             = Resolve-TagAnchor -Anchor $Taxonomy.tags.anchor
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
