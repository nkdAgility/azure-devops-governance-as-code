function Import-GovernanceSource {
    <#
        .SYNOPSIS
        Loads and parses a program's authored governance source (hierarchy +
        access + members + taxonomy + systems) from its programs/<program>/ folder,
        returning the raw model plus a source hash for provenance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath
    )

    $manifestPath  = Join-Path $ProgramPath 'manifest.yaml'
    $hierarchyPath = Join-Path $ProgramPath 'hierarchy.yaml'
    $accessPath    = Join-Path $ProgramPath 'access.yaml'

    if (-not (Test-Path $manifestPath))  { throw "Manifest file not found: $manifestPath" }
    if (-not (Test-Path $hierarchyPath)) { throw "Hierarchy file not found: $hierarchyPath" }
    if (-not (Test-Path $accessPath))    { throw "Access file not found: $accessPath" }

    $manifestRaw  = Get-Content -Path $manifestPath -Raw
    $hierarchyRaw = Get-Content -Path $hierarchyPath -Raw
    $accessRaw    = Get-Content -Path $accessPath -Raw

    $manifest  = ConvertFrom-Yaml $manifestRaw
    $hierarchy = ConvertFrom-Yaml $hierarchyRaw
    $access    = ConvertFrom-Yaml $accessRaw

    # Membership: programs/<program>/members/<short>.yaml, keyed by file base name.
    $membersDir = Join-Path $ProgramPath 'members'
    $members    = @{}
    $membersRaw = ''
    if (Test-Path $membersDir) {
        foreach ($file in Get-ChildItem -Path $membersDir -Filter '*.yaml' -File) {
            $raw = Get-Content -Path $file.FullName -Raw
            $membersRaw += $raw
            $members[$file.BaseName] = ConvertFrom-Yaml $raw
        }
    }

    # taxonomy.yaml: optional governed vocabularies (tags today; other controlled
    # value lists later). Separate from hierarchy.yaml because it is a flat list
    # of allowed strings, not part of the product/team tree.
    $taxonomyPath = Join-Path $ProgramPath 'taxonomy.yaml'
    $taxonomyRaw  = ''
    $taxonomy     = $null
    if (Test-Path $taxonomyPath) {
        $taxonomyRaw = Get-Content -Path $taxonomyPath -Raw
        $taxonomy    = ConvertFrom-Yaml $taxonomyRaw
    }

    # systems.yaml: optional reusable systems — named sets of governed
    # sub-elements stamped onto teams via `systems:` in hierarchy.yaml.
    $systemsPath = Join-Path $ProgramPath 'systems.yaml'
    $systemsRaw  = ''
    $systems     = $null
    if (Test-Path $systemsPath) {
        $systemsRaw = Get-Content -Path $systemsPath -Raw
        $systems    = ConvertFrom-Yaml $systemsRaw
    }

    # sources.yaml: optional pre-migration source locations per codePath —
    # where each incoming team lives TODAY, consumed only by preflight. The
    # raw text joins the hash last so programs without one keep their hash.
    $sourcesPath = Join-Path $ProgramPath 'sources.yaml'
    $sourcesRaw  = ''
    $sources     = $null
    if (Test-Path $sourcesPath) {
        $sourcesRaw = Get-Content -Path $sourcesPath -Raw
        $parsed     = ConvertFrom-Yaml $sourcesRaw
        if ($parsed -and $parsed.sources) { $sources = $parsed.sources }
    }

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($manifestRaw + $hierarchyRaw + $accessRaw + $membersRaw + $taxonomyRaw + $systemsRaw + $sourcesRaw)
    $stream = [System.IO.MemoryStream]::new($bytes)
    $hash   = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()

    # cadence.yaml: optional iteration cadence config.
    $cadencePath = Join-Path $ProgramPath 'cadence.yaml'
    $cadence     = $null
    if (Test-Path $cadencePath) {
        $cadence = ConvertFrom-Yaml (Get-Content -Path $cadencePath -Raw)
    }

    # team-ids.yaml: auto-maintained state file mapping codePath -> ADO team GUID.
    # Allows teams to be found by stable codePath even after a rename.
    $teamIdsPath = Join-Path $ProgramPath 'team-ids.yaml'
    $teamIds     = @{}
    if (Test-Path $teamIdsPath) {
        $parsed = ConvertFrom-Yaml (Get-Content -Path $teamIdsPath -Raw)
        if ($parsed -and $parsed.teams) {
            foreach ($k in $parsed.teams.Keys) { $teamIds[$k] = $parsed.teams[$k] }
        }
    }

    return @{
        Manifest     = $manifest
        Hierarchy    = $hierarchy
        Access       = $access
        Members      = $members
        Hash         = $hash
        Cadence      = $cadence
        Taxonomy     = $taxonomy
        Systems      = $systems
        Sources      = $sources
        TeamIds      = $teamIds
        TeamIdsPath  = $teamIdsPath
    }
}
