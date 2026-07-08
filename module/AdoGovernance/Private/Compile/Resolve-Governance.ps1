# Compile stage — projects the authored hierarchy into the resolved desired state.
# The hierarchy is the product; teams, area paths, repos, pipelines, and permissions
# are all derived here.

$script:BandDisplayName = @{
    platform = 'Platform'
    plugins  = 'Plugins'
    peng     = 'Platform Engineering'
}

function Add-OwnedEntry {
    <# Records that a node's area path is managed by another team (owner back-reference).
       Keyed by the owner's product-qualified code (e.g. PTL-FND), not the bare leaf. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Path,
        [bool]$IncludeSubAreas
    )
    if (-not $Ctx.Owned.ContainsKey($Key)) {
        $Ctx.Owned[$Key] = [System.Collections.Generic.List[object]]::new()
    }
    $Ctx.Owned[$Key].Add([ordered]@{ path = $Path; includeSubAreas = [bool]$IncludeSubAreas })
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

    $area = [ordered]@{ path = $path; kind = 'team' }
    if ($Node.short) { $area.short = $Node.short; $area.code = $codePath }
    $Ctx.AreaPaths.Add($area)

    if ($Node.owner) {
        Add-OwnedEntry -Ctx $Ctx -Key $Node.owner -Path $path -IncludeSubAreas $true
    }
    else {
        $folder = if ($IsFirstLevel) { $path.Substring($ProgramRoot.Length) } else { $null }
        $Ctx.Teams.Add([ordered]@{
            name            = $qualifiedName
            short           = $Node.short
            kind            = 'team'
            parent          = $ParentTeamName
            codePath        = $codePath
            defaultAreaPath = $path
            includeSubAreas = $hasChildren
            pipelineFolder  = $folder
        })
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

    $ctx = @{
        AreaPaths       = [System.Collections.Generic.List[object]]::new()
        Teams           = [System.Collections.Generic.List[object]]::new()
        Repos           = [System.Collections.Generic.List[object]]::new()
        PipelineFolders = [System.Collections.Generic.List[object]]::new()
        Owned           = @{}
    }

    $program = $Manifest.program
    $root    = "\$program"

    $ctx.AreaPaths.Add([ordered]@{ path = $root; kind = 'portfolio' })
    $ctx.Teams.Add([ordered]@{
        name            = $program
        short           = $null
        kind            = 'portfolio'
        parent          = $null
        codePath        = $program
        defaultAreaPath = $root
        includeSubAreas = $true
        pipelineFolder  = $null
    })

    foreach ($product in @($Source.products)) {
        $productPath = "$root\$($product.name)"

        $area = [ordered]@{ path = $productPath; kind = 'product' }
        if ($product.short) { $area.short = $product.short; $area.code = $product.short }
        if ($null -ne $product.dpm) { $area.dpm = $product.dpm }
        if ($product.scope) { $area.scope = $product.scope }
        $ctx.AreaPaths.Add($area)

        if ($product.owner) {
            Add-OwnedEntry -Ctx $ctx -Key $product.owner -Path $productPath -IncludeSubAreas $true
        }
        else {
            $teamObj = [ordered]@{
                name            = "$($product.name) (portfolio)"
                short           = $product.short
                kind            = 'product'
                parent          = $program
                codePath        = $product.short
                defaultAreaPath = $productPath
                includeSubAreas = $true
                pipelineFolder  = $productPath.Substring($root.Length)
            }
            if ($product.scope) { $teamObj.scope = $product.scope }
            $ctx.Teams.Add($teamObj)
        }

        foreach ($section in @($product.sections | Where-Object { $null -ne $_ })) {
            $bandName = $script:BandDisplayName[$section]
            if (-not $bandName) { continue }

            $bandPath = "$productPath\$bandName"
            $ctx.AreaPaths.Add([ordered]@{ path = $bandPath; kind = 'band'; section = $section })

            $items = @($product[$section]) | Where-Object { $null -ne $_ }
            if ($items.Count -eq 0) { continue }

            if ($section -eq 'plugins') {
                foreach ($plugin in $items) {
                    $pluginPath = "$bandPath\$($plugin.name)"

                    $pArea = [ordered]@{ path = $pluginPath; kind = 'entity' }
                    if ($plugin.short) { $pArea.short = $plugin.short; $pArea.code = "$($product.short)-$($plugin.short)" }
                    if ($plugin.owner) { $pArea.owner = $plugin.owner }
                    $ctx.AreaPaths.Add($pArea)

                    $repoName = "$($product.short)-$($plugin.short)-$(ConvertTo-Kebab $plugin.name)"
                    $ctx.Repos.Add([ordered]@{ name = $repoName; areaPath = $pluginPath; owner = $plugin.owner })

                    if ($plugin.owner) {
                        Add-OwnedEntry -Ctx $ctx -Key $plugin.owner -Path $pluginPath -IncludeSubAreas $false
                    }
                }
            }
            else {
                foreach ($node in $items) {
                    Add-TeamNode -Node $node -ParentPath $bandPath -ParentTeamName $product.name -QualifiedParentName $product.name -ParentCodePath $product.short -IsFirstLevel $true -ProgramRoot $root -Ctx $ctx
                }
            }
        }
    }

    # Attach owned area paths + derive security groups per team.
    foreach ($team in $ctx.Teams) {
        $areaConfig = [System.Collections.Generic.List[object]]::new()
        $areaConfig.Add([ordered]@{ path = $team.defaultAreaPath; includeSubAreas = $team.includeSubAreas })
        if ($team.codePath -and $ctx.Owned.ContainsKey($team.codePath)) {
            foreach ($entry in $ctx.Owned[$team.codePath]) { $areaConfig.Add($entry) }
        }
        $team.areaConfig = $areaConfig

        $groupSpecs = if ($team.kind -eq 'team') { $Access.teamGroups } else { $Access.containerGroups }
        $memberKey  = $team.codePath
        $memberSet  = if ($Members.ContainsKey($memberKey)) { $Members[$memberKey] } else { $null }
        $groups = [System.Collections.Generic.List[object]]::new()
        foreach ($spec in @($groupSpecs)) {
            $roleMembers = @()
            if ($memberSet -and $memberSet.ContainsKey($spec.role)) {
                $roleMembers = @($memberSet[$spec.role] | Where-Object { $_ })
            }
            $groups.Add([ordered]@{
                role    = $spec.role
                ado     = ($spec.ado -replace '\{key\}', $team.codePath)
                members = $roleMembers
            })
        }
        $team.securityGroups = $groups
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

    $resolved = [ordered]@{
        program         = $program
        org             = $Manifest.org
        generated       = (Get-Date).ToUniversalTime().ToString('o')
        sourceHash      = "sha256:$SourceHash"
        areaPaths       = $ctx.AreaPaths
        teams           = $ctx.Teams
        repos           = $ctx.Repos
        pipelineFolders = $ctx.PipelineFolders
        stakeholders    = [ordered]@{
            accessLevel = $Access.stakeholders.accessLevel
            ado         = $Access.stakeholders.ado
            scope       = $Access.stakeholders.scope
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
