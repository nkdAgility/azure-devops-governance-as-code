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
    <# Validates and stores the PAT. Throws if the value looks like a URL (common misconfiguration). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    if ($Token -match '^https?://') {
        throw "accessToken resolved to a URL ('$Token'). The manifest.yaml accessToken should reference the env var holding the PAT, not the org URL. Check the AZDEVOPS_DEV_PAT / AZDEVOPS_DEV_ORG naming in your manifest."
    }
    $env:AZURE_DEVOPS_EXT_PAT = $Token
}

function ConvertTo-AdoOrgUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Org)
    if ($Org -match '^https?://') { return $Org }
    return "https://dev.azure.com/$Org"
}

function Test-AdoProject {
    <#
        .SYNOPSIS
        Returns $true if the project exists in the org, via a single targeted
        REST call. Only a genuine not-found returns $false; any other error
        (auth, network) re-throws so the caller never mistakes a broken call
        for a missing project.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/projects/$([Uri]::EscapeDataString($Project))" | Out-Null
        return $true
    } catch {
        if ($_ -match '404|Not Found|does not exist') { return $false }
        throw
    }
}

function New-AdoProject {
    <#
        .SYNOPSIS
        Creates a team project. Uses the az CLI because project creation is a
        long-running ADO operation and the CLI polls it to completion, so the
        project is ready for project-scoped calls when this returns.
        Process accepts any template name, including custom inherited ones.
    #>
    [CmdletBinding()]
    param(
        [string]$OrgUrl,
        [string]$Project,
        [string]$Process       = 'Agile',
        [string]$Visibility    = 'private',
        [string]$SourceControl = 'git'
    )
    az devops project create --organization $OrgUrl --name $Project `
        --process $Process --visibility $Visibility --source-control $SourceControl --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create project '$Project' (process: $Process, visibility: $Visibility, sourceControl: $SourceControl)."
    }
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
        # ADO returns either HTTP 404 or a WorkItemTrackingTreeNodeNotFoundException
        # (message: "The Area/Iteration name is not recognized") for a missing node.
        if ($_ -match '404|Not Found|is not recognized|TreeNodeNotFoundException') { return $false }
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
    <# Creates a team via REST. Returns the new team GUID.
       If the team already exists, looks it up and returns its GUID. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    try {
        $result = Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/projects/$Project/teams" `
            -Method 'POST' -Body @{ name = $Name }
        return $result.id
    } catch {
        if ($_ -notmatch 'already exists|duplicate|409') {
            throw "Failed to create team '$Name': $_"
        }
        # Already exists — look it up to return the GUID
        $json = az devops team show --organization $OrgUrl --project $Project --team $Name --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and $json) { return ($json | ConvertFrom-Json).id }
        throw "Failed to create team '$Name' and could not find existing team."
    }
}

function Set-AdoTeamName {
    <# Renames an ADO team in-place by its GUID. Used when a governance rename is detected. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$TeamId, [string]$NewName)
    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "_apis/projects/$Project/teams/$([Uri]::EscapeDataString($TeamId))" `
        -Method 'PATCH' -Body @{ name = $NewName } | Out-Null
}

# ─── REST helper ─────────────────────────────────────────────────────────────

function Resolve-AdoRequestUri {
    <#
        .SYNOPSIS
        Builds the request URI for an ADO REST call, routing resource areas that
        do not live on the core host to their own service host:
          _apis/graph/*            -> vssps.dev.azure.com  (identity/graph, SPS)
          _apis/userentitlements*  -> vsaex.dev.azure.com  (member entitlements)
        Calling these on dev.azure.com fails (404 / "controller not found") on
        every org. Legacy {org}.visualstudio.com domains get the matching
        {org}.vssps/vsaex.visualstudio.com host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Path
    )
    $service = switch -Regex ($Path) {
        '^_apis/graph(/|\?|$)'            { 'vssps'; break }
        '^_apis/userentitlements(/|\?|$)' { 'vsaex'; break }
        default                           { $null }
    }
    $effective = $OrgUrl
    if ($service) {
        $effective = $OrgUrl `
            -replace '^https://dev\.azure\.com/', "https://$service.dev.azure.com/" `
            -replace '^https://([^./]+)\.visualstudio\.com', "https://`$1.$service.visualstudio.com"
    }
    return "$($effective.TrimEnd('/'))/$Path"
}

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
    $uri     = Resolve-AdoRequestUri -OrgUrl $OrgUrl -Path $Path
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
    # Exception: DELETE returns 204 No Content; Invoke-RestMethod yields an empty string for
    # that, which is the expected success response, not an error.
    if ($response -is [string]) {
        if ($Method -ieq 'DELETE' -and [string]::IsNullOrEmpty($response)) { return $null }
        throw "ADO REST returned non-JSON (HTML/text). Check PAT is set and has the required scope. URL: $uri"
    }
    return $response
}

# ─── PAT scope verification ──────────────────────────────────────────────────

function Resolve-AdoProbeVerdict {
    <#
        .SYNOPSIS
        Classifies a scope-probe response. ADO checks the PAT scope BEFORE it
        validates the request, so an intentionally invalid write returning
        400/404/405/409 proves the scope is present (and nothing was created),
        while 401/403, a redirect to sign-in, or an HTML page proves it is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [string]$ContentType = ''
    )
    if ($StatusCode -in 401, 403)              { return 'missing' }
    if ($StatusCode -ge 300 -and $StatusCode -lt 400) { return 'missing' }   # redirect to sign-in
    if ($StatusCode -eq 203)                   { return 'missing' }          # HTML sign-in page
    if ($StatusCode -in 200, 201, 204 -and $ContentType -like '*html*') { return 'missing' }
    if ($StatusCode -in 200, 201, 204)         { return 'ok' }
    if ($StatusCode -in 400, 404, 405, 409)    { return 'ok' }               # authorized; request invalid by design
    return 'unknown'
}

function Get-AdoScopeProbeSet {
    <#
        .SYNOPSIS
        The side-effect-free probe matrix for every PAT scope family the engine
        uses. Read probes are plain GETs; write probes send intentionally
        invalid payloads (empty body / bogus descriptors) so a scoped PAT gets
        400 Bad Request and nothing is ever created or changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)
    $p = [Uri]::EscapeDataString($Project)
    @(
        @{ Family = 'Project & Team (read)';        Scope = 'vso.project';        NeededFor = 'plan, audit'; Method = 'GET';  Path = '_apis/projects' }
        @{ Family = 'Project & Team (manage)';      Scope = 'vso.project_manage'; NeededFor = 'apply (project/team create)'; Method = 'POST'; Path = '_apis/projects'; Body = @{} }
        @{ Family = 'Work items (read)';            Scope = 'vso.work';           NeededFor = 'plan, audit'; Method = 'GET';  Path = "$p/_apis/wit/classificationnodes/areas" }
        @{ Family = 'Work items (write)';           Scope = 'vso.work_write';     NeededFor = 'apply (area/iteration paths, team settings)'; Method = 'POST'; Path = "$p/_apis/wit/classificationnodes/areas"; Body = @{} }
        @{ Family = 'Code (read)';                  Scope = 'vso.code';           NeededFor = 'plan, audit'; Method = 'GET';  Path = "$p/_apis/git/repositories" }
        @{ Family = 'Code (read, write & manage)';  Scope = 'vso.code_manage';    NeededFor = 'apply (repo create)'; Method = 'POST'; Path = "$p/_apis/git/repositories"; Body = @{} }
        @{ Family = 'Build (read)';                 Scope = 'vso.build';          NeededFor = 'plan, audit'; Method = 'GET';  Path = "$p/_apis/build/folders" }
        @{ Family = 'Build (read & execute)';       Scope = 'vso.build_execute';  NeededFor = 'apply (pipeline folder create)'; Method = 'PUT'; Path = "$p/_apis/build/folders?path="; Body = @{} }
        @{ Family = 'Graph (read)';                 Scope = 'vso.graph';          NeededFor = 'plan, audit (group membership)'; Method = 'GET'; Path = '_apis/graph/groups' }
        @{ Family = 'Graph (manage)';               Scope = 'vso.graph_manage';   NeededFor = 'apply (group create, membership)'; Method = 'PUT'; Path = '_apis/graph/memberships/invalid-descriptor/invalid-descriptor' }
        @{ Family = 'Member entitlements (read)';   Scope = 'vso.memberentitlementmanagement'; NeededFor = 'apply (member UPN lookup)'; Method = 'GET'; Path = '_apis/userentitlements?top=1' }
        # A well-formed POST with an EMPTY accessControlEntries list is a no-op
        # that still exercises the WRITE permission check — a GET on the ACL
        # list passes with read-capable PATs that cannot write ACLs.
        @{ Family = 'Security (ACL manage)';        Scope = 'vso.security_manage / Full access'; NeededFor = 'apply (pipeline folder ACLs, structural authority)'; Method = 'POST'; Path = "_apis/accesscontrolentries/$script:PipelineBuildNamespaceId"; Body = @{ token = 'governance-scope-probe'; merge = $true; accessControlEntries = @() } }
    )
}

function Test-AdoAuthScope {
    <#
        .SYNOPSIS
        Runs the scope probe matrix against a live org and returns one result
        object per probe: Family, Scope, NeededFor, Verdict (ok/missing/unknown),
        StatusCode. Makes no changes to the org — see Get-AdoScopeProbeSet.
        Requires $env:AZURE_DEVOPS_EXT_PAT (via Set-AdoAuth).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Project
    )
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_EXT_PAT)"))
    $headers = @{ Authorization = "Basic $encoded"; Accept = 'application/json' }

    foreach ($probe in Get-AdoScopeProbeSet -Project $Project) {
        $uri  = Resolve-AdoRequestUri -OrgUrl $OrgUrl -Path $probe.Path
        $sep  = if ($uri.Contains('?')) { '&' } else { '?' }
        $uri += "${sep}api-version=7.1-preview.1"

        $params = @{ Uri = $uri; Method = $probe.Method; Headers = $headers;
                     SkipHttpErrorCheck = $true; MaximumRedirection = 0;
                     ErrorAction = 'SilentlyContinue'; SkipCertificateCheck = $false }
        if ($probe.ContainsKey('Body')) {
            $params['Body']        = ($probe.Body | ConvertTo-Json -Compress)
            $params['ContentType'] = 'application/json'
        }
        try {
            $resp        = Invoke-WebRequest @params
            $statusCode  = [int]$resp.StatusCode
            $contentType = [string]$resp.Headers['Content-Type']
        } catch {
            # Network-level failure (DNS, TLS, timeout) — not a scope verdict.
            $statusCode  = 0
            $contentType = ''
        }
        [pscustomobject]@{
            Family     = $probe.Family
            Scope      = $probe.Scope
            NeededFor  = $probe.NeededFor
            StatusCode = $statusCode
            Verdict    = if ($statusCode -eq 0) { 'unknown' } else {
                Resolve-AdoProbeVerdict -StatusCode $statusCode -ContentType $contentType
            }
        }
    }
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

function Initialize-AdoTeamDefaults {
    <#
        .SYNOPSIS
        Configures a newly created team with the minimum settings needed before
        teamfieldvalues PATCH will succeed (ADO throws TF400509 otherwise).

        Steps:
          1. Fetch the project root iteration node GUID.
          2. Add it to the team's iteration list (POST teamsettings/iterations).
          3. Set it as the team's default backlog iteration (PATCH teamsettings).

        No iteration paths are created — the project root always exists.
        Throws on failure so the caller sees the real error.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team)

    $iterRoot = Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/_apis/wit/classificationnodes/iterations?`$depth=0"
    if (-not $iterRoot.identifier) {
        throw "Initialize-AdoTeamDefaults: could not find root iteration node for '$Project'."
    }

    $encodedTeam = [Uri]::EscapeDataString($Team)

    # Add root iteration to the team's iteration list (idempotent — ignore if already present)
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "$Project/$encodedTeam/_apis/work/teamsettings/iterations" `
            -Method 'POST' -Body @{ id = $iterRoot.identifier } | Out-Null
    } catch {
        if ($_ -notmatch 'already exists|duplicate|400') { throw }
    }

    # Prefer year-level iteration as the backlog (e.g. \Odyssey\2026) over the root.
    # The root is too high and ADO later rejects it with TF400497.
    $backlogId = $iterRoot.identifier
    try {
        $yearNode  = Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "$Project/_apis/wit/classificationnodes/iterations/$([DateTime]::Today.Year)"
        if ($yearNode.identifier) { $backlogId = $yearNode.identifier }
    } catch { <# year node not created yet — fall back to root #> }

    # Set it as the default backlog iteration.
    # ADO requires a bare GUID string for backlogIteration — sending a nested {id:...}
    # object is silently accepted (HTTP 200) but the value is NOT updated.
    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/$encodedTeam/_apis/work/teamsettings" `
        -Method 'PATCH' -Body @{ backlogIteration = $backlogId } | Out-Null
}

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
        If ADO throws TF400509 (no backlog iteration), initialises team defaults
        and retries once automatically.

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
    $apiPath     = "$Project/$encodedTeam/_apis/work/teamsettings/teamfieldvalues"
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath -Method 'PATCH' -Body $body | Out-Null
    } catch {
        if ($_ -match 'TF400509|backlog iteration') {
            # Team is missing its default backlog iteration — initialise it and retry once.
            Initialize-AdoTeamDefaults -OrgUrl $OrgUrl -Project $Project -Team $Team
            Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath -Method 'PATCH' -Body $body | Out-Null
        } else { throw }
    }
}

# ─── Repos ────────────────────────────────────────────────────────────────────

function Get-AdoRepoSet {
    <# Returns a hashtable of existing repo name -> repo id. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set  = @{}
    $json = az repos list --organization $OrgUrl --project $Project --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }
    foreach ($repo in ($json | ConvertFrom-Json)) { $set[$repo.name] = $repo.id }
    return $set
}

function Remove-AdoRepo {
    <# Soft-deletes a repo by id (ADO keeps it in the recycle bin for ~30 days). #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$RepoId)
    az repos delete --organization $OrgUrl --project $Project --id $RepoId --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete repo '$RepoId'." }
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

function Find-AdoUserSuggestion {
    <#
        .SYNOPSIS
        Best-effort near-match lookup for a UPN that failed to resolve: splits
        the local part into name tokens and searches org entitlements for each,
        so 'alex.rivers@corp.com' can surface 'ARivers@corp.com'. Display
        only — never used for a compliance decision, so failures return empty.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Upn)
    $suggestions = @{}
    $tokens = @((($Upn -split '@')[0] -split '[._-]') | Where-Object { $_.Length -ge 3 })
    foreach ($t in $tokens) {
        try {
            $r = Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/userentitlements?`$filter=name eq '$t'" `
                -ApiVersion '7.1-preview.3'
            foreach ($m in @($r.members) + @($r.items)) {
                if ($m.user.principalName) { $suggestions[$m.user.principalName] = $m.user.displayName }
            }
        } catch { Write-Verbose "Find-AdoUserSuggestion('$t'): $_" }
    }
    return @($suggestions.GetEnumerator() | ForEach-Object { "$($_.Key) ($($_.Value))" })
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

function Remove-AdoGroupMember {
    <# Removes a member (by descriptor) from a group (by descriptor) via the graph memberships API. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$MemberDescriptor, [string]$ContainerDescriptor)
    $mEnc = [Uri]::EscapeDataString($MemberDescriptor)
    $cEnc = [Uri]::EscapeDataString($ContainerDescriptor)
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis/graph/memberships/$mEnc/$cEnc" `
        -Method 'DELETE' -ApiVersion '7.1-preview.1' | Out-Null
}

function Resolve-AdoMemberDisplay {
    <# Best-effort human-readable name (principalName) for a graph member
       descriptor, used to make findings about extra members actionable.
       Falls back to the raw descriptor — display only, never a compliance
       decision, so the fallback is safe. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Descriptor)
    try {
        $user = Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "_apis/graph/users/$([Uri]::EscapeDataString($Descriptor))" `
            -ApiVersion '7.1-preview.1'
        if ($user.principalName) { return $user.principalName }
    } catch { Write-Verbose "Resolve-AdoMemberDisplay: $_" }
    return $Descriptor
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

# ─── Pipeline folder ACLs (REST security API) ─────────────────────────────────

$script:PipelineBuildNamespaceId = '33344d9c-fc72-4d6f-aba5-fa317101a7e9'

function ConvertTo-PipelinePermissionBit {
    <#
        .SYNOPSIS
        Converts a human-readable pipeline permission string from access.yaml into
        the ADO Build-namespace allow-bit mask.

        Supported values (from access.yaml roles.*.pipelines):
          read         -> ViewBuilds(1) | ViewBuildDefinition(1024)
          'Edit, Queue'-> ViewBuilds(1) | QueueBuilds(128) | ViewBuildDefinition(1024) | EditBuildDefinition(2048)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Permission)
    switch ($Permission.Trim()) {
        'read'        { return 1025 }   # 1 + 1024
        'Edit, Queue' { return 3201 }   # 1 + 128 + 1024 + 2048
        default       { throw "Unknown pipeline permission string: '$Permission'" }
    }
}

function Get-AdoGroupIdentityDescriptor {
    <#
        .SYNOPSIS
        Converts an ADO graph subject descriptor (e.g. 'vssgp.Ym9...' from Get-AdoGroupSet)
        into a security identity descriptor (e.g. 'Microsoft.TeamFoundation.Identity;S-1-9-...')
        suitable for use in security ACL operations.
        Returns $null when the identity cannot be resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$SubjectDescriptor
    )
    $enc    = [Uri]::EscapeDataString($SubjectDescriptor)
    # Use the VSSPS host for identity resolution (different subdomain from the main org URL)
    $orgName = $OrgUrl.TrimEnd('/') -replace '^https?://dev\.azure\.com/', ''
    $vsspsUrl = "https://vssps.dev.azure.com/$orgName"
    try {
        $result = Invoke-AdoRest -OrgUrl $vsspsUrl `
            -Path "_apis/identities?subjectDescriptors=$enc&queryMembership=None"
        $identity = @($result.value)[0]
        return $identity.descriptor   # 'Microsoft.TeamFoundation.Identity;...'
    } catch {
        Write-Verbose "Get-AdoGroupIdentityDescriptor: failed for '$SubjectDescriptor': $_"
        return $null
    }
}

function Get-AdoPipelineFolderAcl {
    <#
        .SYNOPSIS
        Returns a hashtable of securityIdentityDescriptor -> allowBits for the
        named pipeline folder. Only the explicit (non-inherited) ACEs are returned.
        Returns an empty hashtable when no ACL exists or on error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$FolderPath   # e.g. '\Portal\Platform\Foundation'
    )
    $clean = $FolderPath.TrimStart('\').Replace('\', '/')
    $token = if ($clean) { "$ProjectId/$clean" } else { $ProjectId }
    $tokenEnc = [Uri]::EscapeDataString($token)
    $acl = @{}
    try {
        $result = Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "_apis/accesscontrollists/$script:PipelineBuildNamespaceId`?token=$tokenEnc&includeExtendedInfo=false&recurse=false"
        foreach ($list in @($result.value)) {
            foreach ($prop in $list.acesDictionary.PSObject.Properties) {
                $acl[$prop.Name] = [int]$prop.Value.allow
            }
        }
    } catch {
        Write-Verbose "Get-AdoPipelineFolderAcl: error reading ACL for token '$token': $_"
    }
    return $acl
}

function Set-AdoPipelineFolderAce {
    <#
        .SYNOPSIS
        Grants the specified allow-bits to a security identity on a pipeline folder.
        Uses merge=true so existing bits are OR-ed rather than replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$FolderPath,         # e.g. '\Portal\Platform\Foundation'
        [Parameter(Mandatory)][string]$IdentityDescriptor, # security identity descriptor
        [Parameter(Mandatory)][int]$AllowBits
    )
    $clean = $FolderPath.TrimStart('\').Replace('\', '/')
    $token = if ($clean) { "$ProjectId/$clean" } else { $ProjectId }
    $body = @{
        token   = $token
        merge   = $true
        accessControlEntries = @(
            @{ descriptor = $IdentityDescriptor; allow = $AllowBits; deny = 0 }
        )
    }
    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "_apis/accesscontrolentries/$script:PipelineBuildNamespaceId" `
        -Method 'POST' -Body $body | Out-Null
}

# ─── Area node security (structural authority) ────────────────────────────────
# CSS is the security namespace guarding area path nodes. Structural authority
# (Decision-0028) grants a delegated admin group edit/manage rights on a node
# subtree without making its members contributors.

$script:CssNamespaceId    = '83e28ad4-2d72-4ceb-97b0-c7726d5502c3'
$script:AreaNodeAdminBits = 7   # GENERIC_READ(1) + GENERIC_WRITE(2) + DELETE(4)

function Get-AdoAreaNodeToken {
    <#
        .SYNOPSIS
        Builds the CSS security token for an area path: the chain of node GUIDs
        from the root area node down to the target, each wrapped as
        'vstfs:///Classification/Node/<guid>' and joined with ':'.
        Throws when any node in the chain cannot be resolved.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    $segments = $ResolvedPath.TrimStart('\') -split '\\'

    $root = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/classificationnodes/areas?`$depth=0"
    if (-not $root.identifier) { throw "Get-AdoAreaNodeToken: no root area node for '$Project'." }
    $ids = [System.Collections.Generic.List[string]]::new()
    $ids.Add($root.identifier)

    for ($i = 1; $i -lt $segments.Count; $i++) {
        $sub = ($segments[1..$i] | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        $node = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/classificationnodes/areas/$sub"
        if (-not $node.identifier) { throw "Get-AdoAreaNodeToken: cannot resolve node '$($segments[$i])' in '$ResolvedPath'." }
        $ids.Add($node.identifier)
    }
    return (($ids | ForEach-Object { "vstfs:///Classification/Node/$_" }) -join ':')
}

function Get-AdoAreaNodeAcl {
    <# Returns a hashtable of securityIdentityDescriptor -> allowBits for the
       explicit (non-inherited) ACEs on an area node token. Empty on none/error. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Token)
    $tokenEnc = [Uri]::EscapeDataString($Token)
    $acl = @{}
    try {
        $result = Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "_apis\accesscontrollists\$script:CssNamespaceId`?token=$tokenEnc&includeExtendedInfo=false&recurse=false"
        foreach ($list in @($result.value)) {
            foreach ($prop in $list.acesDictionary.PSObject.Properties) {
                $acl[$prop.Name] = [int]$prop.Value.allow
            }
        }
    } catch {
        Write-Verbose "Get-AdoAreaNodeAcl: error reading ACL for token '$Token': $_"
    }
    return $acl
}

function Set-AdoAreaNodeAce {
    <# Grants allow-bits to a security identity on an area node token.
       merge=true so existing bits are OR-ed, never replaced. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$IdentityDescriptor,
        [Parameter(Mandatory)][int]$AllowBits
    )
    $body = @{
        token = $Token
        merge = $true
        accessControlEntries = @(
            @{ descriptor = $IdentityDescriptor; allow = $AllowBits; deny = 0 }
        )
    }
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "_apis\accesscontrolentries\$script:CssNamespaceId" `
        -Method 'POST' -Body $body | Out-Null
}

# NOTE (spike pending): making the admin group a Team Administrator of the
# teams under its node has no cleanly documented REST API (candidates: Identity
# namespace ACE on the team identity, or the legacy AddTeamAdmins endpoint).
# Until that spike lands, structural authority covers area node management only.

function Find-AdoGroupDescriptor {
    <# Resolves a group display name to its graph descriptor. Checks the
       project-scoped set first, then org-scoped groups. Returns $null when
       not found — callers must surface that as a finding, never swallow it. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name, [hashtable]$ProjectGroups = @{})
    if ($ProjectGroups.ContainsKey($Name)) { return $ProjectGroups[$Name] }
    $json = az devops security group list --organization $OrgUrl --scope organization --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    $parsed = $json | ConvertFrom-Json
    $groups = if ($parsed -is [array]) { $parsed }
              elseif ($null -ne $parsed.graphGroups) { $parsed.graphGroups }
              else { @() }
    foreach ($g in $groups) {
        if ($g.displayName -eq $Name) { return $g.descriptor }
    }
    return $null
}

# ─── Tags (governed taxonomy) ─────────────────────────────────────────────────

function Get-AdoTagSet {
    <# Returns a hashtable of tag name -> tag id for the project.
       NOTE: loads the full tag list — acceptable for governed projects; on a
       legacy project with build-id tag pollution this can be very large. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set  = @{}
    $data = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/tags" -ApiVersion '7.1-preview.1'
    foreach ($tag in @($data.value)) { if ($tag.name) { $set[$tag.name] = $tag.id } }
    return $set
}

function Remove-AdoTag {
    <# Deletes a work item tag by id. Removing a tag detaches it from all work items. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$TagId)
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/tags/$TagId" `
        -Method 'DELETE' -ApiVersion '7.1-preview.1' | Out-Null
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

function Remove-AdoAreaPath {
    <#
        .SYNOPSIS
        Deletes an area classification node (and its subtree). Any work items
        assigned to it are reparented to the node's parent first ($reparentTo
        takes the parent node's integer id). Refuses to delete the project root.
        Throws on failure.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    $segments = $ResolvedPath.TrimStart('\') -split '\\'
    if ($segments.Count -le 1) {
        throw "Remove-AdoAreaPath: refusing to delete the project root area path '$ResolvedPath'."
    }

    $subPath = ($segments[1..($segments.Count - 1)] |
        ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

    # Parent node id: project root when deleting a first-level node.
    $parentApiPath = if ($segments.Count -eq 2) {
        "$Project/_apis/wit/classificationnodes/areas?`$depth=0"
    } else {
        $parentSub = ($segments[1..($segments.Count - 2)] |
            ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        "$Project/_apis/wit/classificationnodes/areas/$parentSub"
    }
    $parent = Invoke-AdoRest -OrgUrl $OrgUrl -Path $parentApiPath
    if ($null -eq $parent.id) {
        throw "Remove-AdoAreaPath: could not resolve parent node for '$ResolvedPath'."
    }

    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "$Project/_apis/wit/classificationnodes/areas/${subPath}?`$reparentTo=$($parent.id)" `
        -Method 'DELETE' | Out-Null
}

function Remove-AdoTeam {
    <# Deletes a team by GUID. Deleting a team does not delete its work items. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$TeamId)
    Invoke-AdoRest -OrgUrl $OrgUrl `
        -Path "_apis/projects/$([Uri]::EscapeDataString($Project))/teams/$TeamId" `
        -Method 'DELETE' | Out-Null
}

function Get-AdoTeamList {
    <#
        .SYNOPSIS
        Returns a hashtable of teamName -> teamId for all teams in a project.
        Uses the az devops CLI (reliable auth; avoids REST org-level scope issues).
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $teams = @{}
    $json  = az devops team list --organization $OrgUrl --project $Project --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Failed to list teams for '$Project' in '$OrgUrl' (exit $LASTEXITCODE)."
    }
    foreach ($team in ($json | ConvertFrom-Json)) {
        if ($team.name) { $teams[$team.name] = $team.id }
    }
    return $teams
}

# ─── Iteration paths (REST) ───────────────────────────────────────────────────

function Test-AdoIterationPath {
    <# Returns $true if an iteration path exists. Same pattern as Test-AdoAreaPath. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    $segments = $ResolvedPath.TrimStart('\') -split '\\'
    if ($segments.Count -le 1) { return $true }
    $subPath = ($segments[1..($segments.Count - 1)] |
        ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl `
            -Path "$Project/_apis/wit/classificationnodes/iterations/$subPath" | Out-Null
        return $true
    } catch {
        if ($_ -match '404|Not Found|is not recognized|TreeNodeNotFoundException') { return $false }
        throw
    }
}

function New-AdoIterationPath {
    <#
        .SYNOPSIS
        Creates an iteration classification node at the given resolved path.
        Optionally sets startDate / endDate attributes (for sprint nodes).
        Idempotent: silently succeeds if the node already exists.
    #>
    [CmdletBinding()]
    param(
        [string]$OrgUrl,
        [string]$Project,
        [string]$ResolvedPath,   # e.g. \Odyssey\2026\S1\S1-W1
        [string]$StartDate = '', # ISO 8601 e.g. 2026-02-02T00:00:00Z
        [string]$EndDate   = ''
    )
    $segments = $ResolvedPath.TrimStart('\') -split '\\'
    if ($segments.Count -lt 2) { return }   # project root — never create

    $name       = $segments[-1]
    $parentSegs = if ($segments.Count -gt 2) { $segments[1..($segments.Count - 2)] } else { @() }
    $parentPath = if ($parentSegs.Count -gt 0) {
        ($parentSegs | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    } else { '' }

    $apiPath = if ($parentPath) {
        "$Project/_apis/wit/classificationnodes/iterations/$parentPath"
    } else {
        "$Project/_apis/wit/classificationnodes/iterations"
    }

    $body = @{ name = $name }
    if ($StartDate -and $EndDate) {
        $body['attributes'] = @{ startDate = $StartDate; finishDate = $EndDate }
    }

    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath -Method 'POST' -Body $body | Out-Null
    } catch {
        if ($_ -notmatch 'already exists|duplicate|TF201020') {
            throw "Failed to create iteration '$ResolvedPath': $_"
        }
    }
}

function Get-AdoIterationId {
    <# Returns the GUID (identifier) of an iteration classification node. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$ResolvedPath)
    $segments = $ResolvedPath.TrimStart('\') -split '\\'
    if ($segments.Count -le 1) { throw "Cannot get ID for project root iteration." }
    $subPath = ($segments[1..($segments.Count - 1)] |
        ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $node = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/classificationnodes/iterations/$subPath"
    return $node.identifier
}

function Get-AdoTeamIterationSet {
    <# Returns a hashtable of iteration GUID -> $true for a team's current iteration list.
       Re-initialises team defaults and retries if TF400497 is raised (invalid backlog path). #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team)
    $set     = @{}
    $encoded = [Uri]::EscapeDataString($Team)
    $apiPath = "$Project/$encoded/_apis/work/teamsettings/iterations"
    try {
        $data = Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath
    } catch {
        # Invoke-RestMethod puts the JSON response body in ErrorDetails.Message;
        # $_.ToString() only has the short HTTP-status line, so check both.
        $errText = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "$_" }
        if ($errText -match 'TF400497|backlog iteration') {
            # Backlog iteration is invalid — reinitialise and retry once.
            Initialize-AdoTeamDefaults -OrgUrl $OrgUrl -Project $Project -Team $Team
            $data = Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath
        } else { throw }
    }
    foreach ($i in @($data.value)) { if ($i.id) { $set[$i.id] = $true } }
    return $set
}

function Add-AdoTeamIteration {
    <# Adds an iteration (by GUID) to a team's iteration list. Idempotent.
       Re-initialises team defaults and retries if TF400497 is raised (null backlog path). #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team, [string]$IterationId)
    $encoded = [Uri]::EscapeDataString($Team)
    $apiPath = "$Project/$encoded/_apis/work/teamsettings/iterations"
    try {
        Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath -Method 'POST' -Body @{ id = $IterationId } | Out-Null
    } catch {
        $errText = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "$_" }
        if ($errText -match 'TF400497|backlog iteration') {
            # backlogIteration is null/invalid — fix it, then retry once.
            Initialize-AdoTeamDefaults -OrgUrl $OrgUrl -Project $Project -Team $Team
            Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath -Method 'POST' -Body @{ id = $IterationId } | Out-Null
        } elseif ($errText -notmatch 'already exists|duplicate') {
            throw
        }
    }
}

function Remove-AdoTeamIteration {
    <# Removes an iteration (by GUID) from a team's subscription list. The
       iteration PATH is untouched (ADR-005) — only the team's view changes. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team, [string]$IterationId)
    $encoded = [Uri]::EscapeDataString($Team)
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/$encoded/_apis/work/teamsettings/iterations/$IterationId" `
        -Method 'DELETE' | Out-Null
}

function Get-AdoIterationRootId {
    <# Returns the GUID of the project's root iteration node. Throws if missing. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $root = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/_apis/wit/classificationnodes/iterations?`$depth=0"
    if (-not $root.identifier) { throw "Get-AdoIterationRootId: no root iteration node for '$Project'." }
    return $root.identifier
}

function Get-AdoTeamBacklogLevels {
    <#
        .SYNOPSIS
        Returns the backlog levels available to a team from its process, as an
        array of @{ id = <category reference, e.g. Microsoft.RequirementCategory>;
        name = <display name, e.g. Stories> }. The task-level (iteration) backlog
        is excluded — only portfolio and requirement backlogs can be toggled.
        Throws if the API returns none — every process has at least one.
    #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team)
    $encoded = [Uri]::EscapeDataString($Team)
    $apiPath = "$Project/$encoded/_apis/work/backlogs"
    try {
        $data = Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath
    } catch {
        $errText = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "$_" }
        if ($errText -match 'TF400497|backlog iteration') {
            Initialize-AdoTeamDefaults -OrgUrl $OrgUrl -Project $Project -Team $Team
            $data = Invoke-AdoRest -OrgUrl $OrgUrl -Path $apiPath
        } else { throw }
    }
    # Exclude 'task' and 'iteration' types — ADO does not allow toggling their visibility.
    $levels  = @($data.value | Where-Object { $_.type -notin @('iteration', 'task') } |
        ForEach-Object { [ordered]@{ id = $_.id; name = $_.name } })
    if ($levels.Count -eq 0) {
        throw "Get-AdoTeamBacklogLevels: no backlog levels returned for team '$Team' in '$Project'."
    }
    return $levels
}

function Get-AdoTeamBacklogVisibilities {
    <# Returns the team's backlog visibility map as a hashtable:
       category reference (e.g. Microsoft.EpicCategory) -> bool. #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Team)
    $encoded  = [Uri]::EscapeDataString($Team)
    $settings = Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/$encoded/_apis/work/teamsettings"
    $vis = @{}
    if ($settings.backlogVisibilities) {
        foreach ($p in $settings.backlogVisibilities.PSObject.Properties) {
            $vis[$p.Name] = [bool]$p.Value
        }
    }
    return $vis
}

function Set-AdoTeamBacklogVisibilities {
    <# Replaces the team's backlog visibility map wholesale (PATCH teamsettings).
       Visibilities: hashtable of category reference -> bool. #>
    [CmdletBinding()]
    param(
        [string]$OrgUrl,
        [string]$Project,
        [string]$Team,
        [Parameter(Mandatory)][hashtable]$Visibilities
    )
    $encoded = [Uri]::EscapeDataString($Team)
    Invoke-AdoRest -OrgUrl $OrgUrl -Path "$Project/$encoded/_apis/work/teamsettings" `
        -Method 'PATCH' -Body @{ backlogVisibilities = $Visibilities } | Out-Null
}
