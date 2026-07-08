# AzureDevOps stage — thin wrappers over the `az devops` CLI + REST used by
# plan / apply / audit. Stubbed for v0.1: the read/reconcile calls land here.

function Get-AdoConnectionArgs {
    <# Builds the shared --org / --project arguments for az devops calls. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$Project
    )
    $orgUrl = if ($Org -match '^https?://') { $Org } else { "https://dev.azure.com/$Org" }
    return @('--organization', $orgUrl, '--project', $Project)
}

function Test-AdoCli {
    <# Verifies the az CLI + devops extension are available. #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') not found. Install it and the 'azure-devops' extension to use plan/apply/audit."
    }
}

function Resolve-AccessToken {
    <#
        .SYNOPSIS
        Resolves an accessToken reference from hierarchy.yaml into an actual PAT.
        A reference of the form '$Env:NAME' or '${Env:NAME}' reads the named
        environment variable; any other value is treated as a literal token.
        Returns $null when unset. The token is never written to the resolved file.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) { return $null }
    $ref = $Reference.Trim()

    if ($ref -match '^\$\{Env:(.+)\}$' -or $ref -match '^\$Env:(.+)$') {
        return [Environment]::GetEnvironmentVariable($Matches[1])
    }
    return $ref
}

function Set-AdoAuth {
    <# Makes the PAT available to the az CLI via its standard env var. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    $env:AZURE_DEVOPS_EXT_PAT = $Token
}

function ConvertTo-AdoOrgUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Org)
    if ($Org -match '^https?://') { return $Org }
    return "https://dev.azure.com/$Org"
}

function Test-AdoProject {
    <# Returns $true if the project exists in the org. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    az devops project show --organization $OrgUrl --project $Project --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-AdoProject {
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    az devops project create --organization $OrgUrl --name $Project --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create project '$Project'." }
}

function Test-AdoAreaPath {
    <#
        .SYNOPSIS
        Returns $true if an area path already exists via a single targeted REST call.
        Avoids loading the full classification tree (which causes OOM on large projects).
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    # '\Odyssey\Portal\Platform' -> API sub-path 'Portal/Platform'
    $segments = $ResolvedPath.TrimStart('\') -split '\\'
    if ($segments.Count -le 1) { return $true }   # project root always exists
    $apiSubPath = ($segments[1..($segments.Count - 1)] |
        ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "$Project/_apis/wit/classificationnodes/areas/$apiSubPath" | Out-Null
        return $true
    } catch {
        # Only treat a genuine 404 as 'not found' — re-throw anything else (auth failure, HTML
        # response, network error) so the caller sees the real problem.
        if ($_ -match '404|Not Found') { return $false }
        throw
    }
}

function New-AdoAreaPath {
    <# Creates one classification node from a resolved area path '\Project\A\B'. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    $segments = $ResolvedPath.Trim('\') -split '\\'
    $name     = $segments[-1]
    $middle   = if ($segments.Count -gt 2) { $segments[1..($segments.Count - 2)] } else { @() }
    $azParent = "\$Project\Area" + (($middle | ForEach-Object { "\$_" }) -join '')

    az boards area project create --organization $OrgUrl --project $Project --name $name --path $azParent --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create area path '$ResolvedPath'." }
}

function Test-AdoTeam {
    <#
        .SYNOPSIS
        Returns $true if a team exists via a single targeted REST call.
        Avoids loading all teams (which can be large on busy projects).
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    $encoded = [Uri]::EscapeDataString($Name)
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/projects/$Project/teams/$encoded" | Out-Null
        return $true
    } catch {
        # Only treat a genuine 404 as 'not found'; any other error re-throws so
        # the caller isn't tricked into creating a team that actually exists.
        if ($_ -match '404|Not Found') { return $false }
        throw
    }
}

function Get-AdoTeamSet {
    <# Returns a hashtable of existing team names. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set = @{}
    $json = az devops team list --organization $OrgUrl --project $Project --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }
    foreach ($team in ($json | ConvertFrom-Json)) { $set[$team.name] = $true }
    return $set
}

function New-AdoTeam {
    <# Creates a team via REST. Idempotent: treats 'already exists' responses as success. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/projects/$Project/teams" `
            -Method 'POST' -Body @{ name = $Name } | Out-Null
    } catch {
        if ($_ -notmatch 'already exists|duplicate|409') {
            throw "Failed to create team '$Name': $_"
        }
    }
}

# ─── REST helper ─────────────────────────────────────────────────────────────

function Invoke-AdoRest {
    <#
        .SYNOPSIS
        Generic REST helper for Azure DevOps API calls.
        Requires $env:AZURE_DEVOPS_EXT_PAT to be set (via Set-AdoAuth).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Path,
        [string]$Method     = 'GET',
        [object]$Body       = $null,
        [string]$ApiVersion = '7.1'
    )
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_EXT_PAT)"))
    # Accept: application/json is required — without it ADO returns an HTML page (HTTP 203).
    $headers = @{ Authorization = "Basic $encoded"; Accept = 'application/json' }
    $uri     = "$($OrgUrl.TrimEnd('/'))/$Path"
    $sep     = if ($uri.Contains('?')) { '&' } else { '?' }
    $uri    += "${sep}api-version=$ApiVersion"

    $params = @{ Uri = $uri; Method = $Method; Headers = $headers; ErrorAction = 'Stop';
                 PreserveAuthorizationOnRedirect = $true }
    if ($null -ne $Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params['ContentType'] = 'application/json'
    }
    $response = Invoke-RestMethod @params
    # ADO returns an HTML sign-in page (HTTP 203) when auth fails or the PAT lacks scope.
    # A string response here is always wrong — fail loudly rather than silently returning null.
    if ($response -is [string]) {
        throw "ADO REST returned non-JSON (HTML/text). Check PAT is set and has the required scope. URL: $uri"
    }
    return $response
}

# ─── Project identity ─────────────────────────────────────────────────────────

function Get-AdoProjectId {
    <# Returns the project GUID, or $null if not found. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $result = az devops project show --organization $OrgUrl --project $Project `
        --query id --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $result.Trim()
}

# ─── Team area configuration (REST) ──────────────────────────────────────────

function Get-AdoTeamAreaConfig {
    <# Returns the current team area configuration via the work settings REST API. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team)
    $encodedTeam = [Uri]::EscapeDataString($Team)
    return Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/$encodedTeam/_apis/work/teamsettings/teamfieldvalues"
}

function Set-AdoTeamAreaConfig {
    <#
        .SYNOPSIS
        Replaces a team's area path configuration wholesale via REST.

        AreaConfig: array of objects with 'path' (\Project\...) and 'includeSubAreas' ($bool).
        REST API paths are sent without the leading backslash.
    #>
    [CmdletBinding()]
    param(
        [string]$OrgUrl,
        [string]$Project,
        [string]$Team,
        [object[]]$AreaConfig
    )
    $values = @($AreaConfig | ForEach-Object {
        [ordered]@{ value = $_.path.TrimStart('\'); includeChildren = [bool]$_.includeSubAreas }
    })
    $body = [ordered]@{
        defaultValue = $AreaConfig[0].path.TrimStart('\')
        values       = $values
    }
    $encodedTeam = [Uri]::EscapeDataString($Team)
    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/$encodedTeam/_apis/work/teamsettings/teamfieldvalues" `
        -Method 'PATCH' -Body $body | Out-Null
}

# ─── Repos ────────────────────────────────────────────────────────────────────

function Get-AdoRepoSet {
    <# Returns a hashtable of existing repo names. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set  = @{}
    $json = az repos list --organization $OrgUrl --project $Project --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }
    foreach ($repo in ($json | ConvertFrom-Json)) { $set[$repo.name] = $true }
    return $set
}

function New-AdoRepo {
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    az repos create --organization $OrgUrl --project $Project --name $Name --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create repo '$Name'." }
}

# ─── Security groups (CLI) ────────────────────────────────────────────────────

function Get-AdoGroupSet {
    <# Returns a hashtable of displayName -> descriptor for project-scoped groups. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set    = @{}
    $json   = az devops security group list --organization $OrgUrl --project $Project `
        --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }
    $parsed = $json | ConvertFrom-Json
    # The CLI may return an array directly or a wrapped object.
    $groups = if ($parsed -is [array])             { $parsed }
              elseif ($null -ne $parsed.graphGroups) { $parsed.graphGroups }
              elseif ($null -ne $parsed.value)       { $parsed.value }
              else                                   { @() }
    foreach ($g in $groups) { $set[$g.displayName] = $g.descriptor }
    return $set
}

function New-AdoGroup {
    <# Creates a project-scoped security group and returns its descriptor. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    $json = az devops security group create --organization $OrgUrl --project $Project `
        --name $Name --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to create group '$Name': $json" }
    return ($json | ConvertFrom-Json).descriptor
}

# ─── Group membership (REST graph API) ────────────────────────────────────────

function Get-AdoGroupMemberSet {
    <# Returns a hashtable of memberDescriptor -> $true for all direct members of a group. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Descriptor)
    $set  = @{}
    $data = Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "_apis/graph/memberships/$([Uri]::EscapeDataString($Descriptor))?direction=Down" `
        -ApiVersion '7.1-preview.1'
    foreach ($m in @($data.value)) { if ($m.memberDescriptor) { $set[$m.memberDescriptor] = $true } }
    return $set
}

function Find-AdoUserDescriptor {
    <# Looks up an ADO user by UPN/email and returns the graph descriptor, or $null. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Upn)
    $json = az devops user show --organization $OrgUrl --user $Upn --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    $user = ($json | ConvertFrom-Json).user
    return $user.subjectDescriptor ?? $user.descriptor
}

function Add-AdoGroupMember {
    <# Adds a member (by descriptor) to a group (by descriptor) via the graph memberships API. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$MemberDescriptor, [string]$ContainerDescriptor)
    $mEnc = [Uri]::EscapeDataString($MemberDescriptor)
    $cEnc = [Uri]::EscapeDataString($ContainerDescriptor)
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/graph/memberships/$mEnc/$cEnc" `
        -Method 'PUT' -ApiVersion '7.1-preview.1' | Out-Null
}

# ─── Pipeline folders (CLI) ───────────────────────────────────────────────────

function Get-AdoPipelineFolderSet {
    <# Returns a hashtable of existing pipeline folder paths (e.g. '\Portal\Platform\Foundation'). #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set  = @{}
    $json = az pipelines folder list --organization $OrgUrl --project $Project `
        --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }
    foreach ($folder in ($json | ConvertFrom-Json)) { $set[$folder.path] = $true }
    return $set
}

function New-AdoPipelineFolder {
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Path)
    az pipelines folder create --organization $OrgUrl --project $Project `
        --path $Path --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create pipeline folder '$Path'." }
}

# ─── Bulk read helpers (used by audit) ───────────────────────────────────────

function Get-AdoAreaPathSubtree {
    <#
        .SYNOPSIS
        Returns a hashtable of every area path in the governance-owned project tree.
        Uses a targeted REST call scoped to the project (bounded response, no OOM).
        Paths match the resolved model format: '\Project\Node\...'.

        The REST root node for the area tree may have an empty or platform-specific
        name, so we inject '\Project' directly as the root anchor rather than
        trusting the root node's 'name' property.
    #>
    [CmdletBinding()]
    param(
        [string]$OrgUrl,
        [string]$Project,
        [int]$Depth = 10
    )
    $set  = @{}
    $root = "\$Project"
    $set[$root] = $true

    $data = Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/_apis/wit/classificationnodes/areas?`$depth=$Depth"

    # Walk children only — the root node itself is anchored as \Project above.
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ node = $data; prefix = $root })
    while ($stack.Count) {
        $item = $stack.Pop()
        foreach ($child in @($item.node.children)) {
            if ($null -ne $child -and $child.name) {
                $path = "$($item.prefix)\$($child.name)"
                $set[$path] = $true
                $stack.Push([pscustomobject]@{ node = $child; prefix = $path })
            }
        }
    }
    return $set
}

function Get-AdoTeamList {
    <#
        .SYNOPSIS
        Returns a list of all team names for a project via the az devops CLI.
        Uses CLI (not REST) because the org-level projects REST API requires a
        broader PAT scope than the project-scoped APIs used elsewhere.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $names = [System.Collections.Generic.List[string]]::new()
    $json  = az devops team list --organization $OrgUrl --project $Project --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Failed to list teams for '$Project' in '$OrgUrl' (exit $LASTEXITCODE)."
    }
    foreach ($team in ($json | ConvertFrom-Json)) {
        if ($team.name) { $names.Add($team.name) }
    }
    return $names
}
