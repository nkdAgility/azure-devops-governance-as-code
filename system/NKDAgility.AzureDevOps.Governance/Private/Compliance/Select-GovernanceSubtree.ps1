function Select-GovernanceSubtree {
    <#
        .SYNOPSIS
        Slices the resolved model down to one node and everything it governs:
        the node's team plus every descendant team (codePath prefix), the area
        subtree under the node's home path, the repos those teams own, and the
        program-wide tag taxonomy (tags are program policy, so they pass
        through whole). scope:future entries are excluded, matching what apply
        and audit can see (ADR-004).

        Used by preflight to evaluate a single incoming team, and the natural
        building block for per-owner finding routing later.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Resolved,
        [Parameter(Mandatory)][string]$Code
    )

    $root = @($Resolved.teams | Where-Object { $_.codePath -eq $Code })
    if ($root.Count -eq 0) {
        $known = @($Resolved.teams | Where-Object { $_.codePath } | ForEach-Object { $_.codePath }) -join ', '
        throw "No node with code '$Code' in the resolved model. Known codes: $known"
    }
    $root = $root[0]
    if ($root.scope -eq 'future') {
        throw "Node '$Code' is scope:future — invisible to compliance (ADR-004). Remove the flag when it enters active migration."
    }

    $teams = @($Resolved.teams | Where-Object {
        $_.scope -ne 'future' -and ($_.codePath -eq $Code -or $_.codePath -like "$Code-*") })
    $teamCodes = @($teams | ForEach-Object { $_.codePath })

    $targetRoot = [string]$root.defaultAreaPath
    if (-not $targetRoot) { throw "Node '$Code' has no defaultAreaPath in the resolved model — rebuild." }

    $areaPaths = @($Resolved.areaPaths | Where-Object {
        $_.path -eq $targetRoot -or $_.path -like "$targetRoot\*" })

    $repos = @($Resolved.repos | Where-Object { $_ -and $_.owner -in $teamCodes })

    return @{
        Code       = $Code
        TargetRoot = $targetRoot
        Teams      = $teams
        AreaPaths  = $areaPaths
        Repos      = $repos
        Tags       = $Resolved.tags
    }
}
