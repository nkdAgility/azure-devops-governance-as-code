function Test-GovernanceSources {
    <#
        .SYNOPSIS
        Validates a program's sources.yaml (pre-migration source locations,
        consumed by preflight) against the resolved model. Returns an issue
        string per problem; empty = valid. Offline — no live calls.

        Entry shape, keyed by codePath:

          sources:
            PTL-FND:
              org:      legacy-org           # source organisation (name or URL)
              project:  LegacyProject        # source team project
              areaPath: LegacyProject\Node   # project-rooted, no leading '\'
              teams:    ['Old Team Name']    # optional: source teams whose
                                             #   membership is "works there today"
              repos:                         # optional: which source repos are
                include: ['Node*']           #   this team's (wildcard globs)
              accessToken: $Env:NAME         # optional PAT fallback reference —
                                             #   an env-var reference, NEVER a token
    #>
    [CmdletBinding()]
    param(
        [object]$Sources,
        [Parameter(Mandatory)][object]$Resolved
    )

    $issues = @()
    if (-not $Sources) { return $issues }

    $teamCodes = @($Resolved.teams | Where-Object { $_.codePath } | ForEach-Object { $_.codePath })
    $futureCodes = @($Resolved.teams | Where-Object { $_.scope -eq 'future' } | ForEach-Object { $_.codePath })

    foreach ($code in @($Sources.Keys)) {
        $src = $Sources[$code]
        $at  = "sources.yaml '$code'"

        if ($code -notin $teamCodes) {
            $issues += "$at does not resolve to a team codePath in the resolved model"
            continue
        }
        if ($code -in $futureCodes) {
            $issues += "$at is scope:future — invisible to compliance, remove the flag before preflighting it"
        }
        if (-not $src.org)     { $issues += "$at is missing 'org' (the source organisation)" }
        if (-not $src.project) { $issues += "$at is missing 'project' (the source team project)" }

        $area = [string]$src.areaPath
        if (-not $area) {
            $issues += "$at is missing 'areaPath' (the source area subtree, project-rooted)"
        } else {
            if ($area.StartsWith('\')) {
                $issues += "$at areaPath must be project-rooted without a leading '\' (e.g. 'Project\Node'), got '$area'"
            } elseif ($src.project -and (($area -split '\\')[0] -ne [string]$src.project)) {
                $issues += "$at areaPath must start with the source project segment '$($src.project)', got '$area'"
            }
        }

        if ($src.teams -and @($src.teams | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            $issues += "$at teams must be a list of source team names"
        }
        if ($src.repos -and -not $src.repos.include) {
            $issues += "$at repos must carry an 'include' list of wildcard patterns (omit 'repos' entirely to skip repo checks)"
        }

        # The same never-a-literal-token rule as manifest accessToken: a value
        # that is not an $Env: reference would end up committed.
        $tokenRef = [string]$src.accessToken
        if ($tokenRef -and $tokenRef -notmatch '^\$\{?Env:') {
            $issues += "$at accessToken must be an environment-variable reference ('`$Env:NAME'), never a literal token"
        }
    }

    return $issues
}
