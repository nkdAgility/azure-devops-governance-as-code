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

function Get-AdoAreaPathSet {
    <# Returns a hashtable of existing area paths (keys like '\Project\Node'). #>
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project)
    $set = @{}
    $json = az boards area project list --organization $OrgUrl --project $Project --depth 50 --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $set }

    $root = $json | ConvertFrom-Json
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ node = $root; prefix = '' })
    while ($stack.Count) {
        $item = $stack.Pop()
        $path = "$($item.prefix)\$($item.node.name)"
        $set[$path] = $true
        foreach ($child in @($item.node.children)) {
            $stack.Push([pscustomobject]@{ node = $child; prefix = $path })
        }
    }
    return $set
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
    [CmdletBinding()]
    param([string]$OrgUrl, [string]$Project, [string]$Name)
    az devops team create --organization $OrgUrl --project $Project --name $Name --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create team '$Name'." }
}
