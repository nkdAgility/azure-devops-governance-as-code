function Import-GovernanceSource {
    <#
        .SYNOPSIS
        Loads and parses a program's authored governance source (hierarchy +
        access + members) from its programs/<program>/ folder, returning the raw
        model plus a source hash for provenance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProgramPath
    )

    $hierarchyPath = Join-Path $ProgramPath 'hierarchy.yaml'
    $accessPath    = Join-Path $ProgramPath 'access.yaml'

    if (-not (Test-Path $hierarchyPath)) { throw "Hierarchy file not found: $hierarchyPath" }
    if (-not (Test-Path $accessPath))    { throw "Access file not found: $accessPath" }

    $hierarchyRaw = Get-Content -Path $hierarchyPath -Raw
    $accessRaw    = Get-Content -Path $accessPath -Raw

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

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($hierarchyRaw + $accessRaw + $membersRaw)
    $stream = [System.IO.MemoryStream]::new($bytes)
    $hash   = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()

    return @{
        Hierarchy = $hierarchy
        Access    = $access
        Members   = $members
        Hash      = $hash
    }
}
