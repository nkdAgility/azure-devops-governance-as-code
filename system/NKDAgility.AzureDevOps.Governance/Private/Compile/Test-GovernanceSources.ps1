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

        Optional top-level `labels:` (ADR-008) attaches engagement vocabulary
        to preflight findings, keyed by check id — e.g. the rule number, owner
        lane and task id from the team-facing standard the findings feed:

          labels:
            area.orphan:      { rule: A2, lane: PM, task: 2 }
            tag.unsanctioned: { rule: B4, lane: Eng, task: 6 }

        Keys must be known check ids ($script:GovernancePreflightChecks);
        values must be flat maps of scalars.

        Optional top-level `reporting:` (ADR-009) frames the rendered markdown
        fix report — all fields optional:

          reporting:
            standard:            "the team-facing standard these labels refer to"
            audience:            "who the report is written for"
            candidateTagMinUses: 20    # tags used on more than this many work items
                                       # are listed as vocabulary candidates
            iterationTop:        7     # iteration paths shown for migration context
            title:               "Pre-migration readiness check"
    #>
    [CmdletBinding()]
    param(
        [object]$Sources,
        [Parameter(Mandatory)][object]$Resolved,
        [object]$Labels = $null,
        [object]$Reporting = $null
    )

    $issues = @()

    if ($Reporting) {
        if ($Reporting -isnot [System.Collections.IDictionary]) {
            $issues += "sources.yaml reporting must be a map"
        } else {
            $known = @('standard', 'audience', 'candidateTagMinUses', 'iterationTop', 'title')
            foreach ($k in @($Reporting.Keys)) {
                if ($k -notin $known) { $issues += "sources.yaml reporting '$k' is not a reporting field. Known: $($known -join ', ')" }
            }
            foreach ($k in 'candidateTagMinUses', 'iterationTop') {
                if ($Reporting.Contains($k)) {
                    $v = $Reporting[$k]
                    if (-not ($v -is [int] -or $v -is [long]) -or [long]$v -lt 1) { $issues += "sources.yaml reporting '$k' must be a positive integer, got '$v'" }
                }
            }
            foreach ($k in 'standard', 'audience', 'title') {
                if ($Reporting.Contains($k) -and $Reporting[$k] -isnot [string]) { $issues += "sources.yaml reporting '$k' must be a string" }
            }
        }
    }

    if ($Labels) {
        if ($Labels -isnot [System.Collections.IDictionary]) {
            $issues += "sources.yaml labels must be a map keyed by preflight check id"
        } else {
            foreach ($check in @($Labels.Keys)) {
                if ($check -notin $script:GovernancePreflightChecks) {
                    $issues += "sources.yaml labels '$check' is not a preflight check id. Known: $($script:GovernancePreflightChecks -join ', ')"
                    continue
                }
                $fields = $Labels[$check]
                if ($fields -isnot [System.Collections.IDictionary]) {
                    $issues += "sources.yaml labels '$check' must be a map of fields to attach (e.g. { rule: A2, lane: PM })"
                    continue
                }
                foreach ($k in @($fields.Keys)) {
                    if ($k -in 'class', 'check', 'subject', 'message') {
                        $issues += "sources.yaml labels '$check' may not override the engine field '$k'"
                    }
                    if ($fields[$k] -is [System.Collections.IDictionary] -or ($fields[$k] -is [array])) {
                        $issues += "sources.yaml labels '$check'.'$k' must be a scalar"
                    }
                }
            }
        }
    }

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
