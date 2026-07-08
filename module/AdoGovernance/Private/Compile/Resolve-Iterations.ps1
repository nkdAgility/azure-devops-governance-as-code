# Compile stage — derives the Year → Season → Sprint iteration calendar from cadence config.

function Get-IterationCalendar {
    <#
        .SYNOPSIS
        Computes the Year/Season/Sprint iteration calendar from a cadence config object.
        Generates from the current execution year through yearHorizon years ahead.

        Execution year starts on the first Monday of February.
        Standard sprint: N working weeks (Mon-Fri), defaulting to 3 (19 calendar days).
        Some final season sprints may be shortened for boundary alignment.

        Returns an array of year objects, each containing seasons containing sprints.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Cadence,
        [Parameter(Mandatory)][string]$ProgramRoot
    )

    $cfg        = $Cadence.iterations
    $horizon    = if ($cfg.yearHorizon)         { [int]$cfg.yearHorizon }         else { 2 }
    $defWeeks   = if ($cfg.defaultSprintWeeks)  { [int]$cfg.defaultSprintWeeks }  else { 3 }
    $seasonDefs = @($cfg.seasons | Where-Object { $_ })

    # Start generation from the execution year containing today.
    # S3 runs into January of the next calendar year, so if today is in January
    # the active execution year started the previous February.
    $today     = [DateTime]::Today
    $execStart = if ($today.Month -le 1) { $today.Year - 1 } else { $today.Year }

    $calendar = [System.Collections.Generic.List[object]]::new()

    for ($y = $execStart; $y -le ($execStart + $horizon); $y++) {
        # First Monday of February in year $y
        $feb1      = [DateTime]::new($y, 2, 1)
        $daysToMon = (8 - [int]$feb1.DayOfWeek) % 7   # 0 if already Monday
        $seasonCursor = $feb1.AddDays($daysToMon)

        $yearNode = [ordered]@{
            name    = "$y"
            path    = "$ProgramRoot\$y"
            seasons = [System.Collections.Generic.List[object]]::new()
        }

        foreach ($sDef in $seasonDefs) {
            $sId        = $sDef.id
            $numSprints = if ($sDef.sprints)           { [int]$sDef.sprints }           else { 6 }
            $finalWks   = if ($null -ne $sDef.finalSprintWeeks) { [int]$sDef.finalSprintWeeks } else { $defWeeks }

            $seasonNode = [ordered]@{
                name    = $sId
                path    = "$ProgramRoot\$y\$sId"
                sprints = [System.Collections.Generic.List[object]]::new()
            }

            $sprintCursor = $seasonCursor
            for ($w = 1; $w -le $numSprints; $w++) {
                $weeks   = if ($w -eq $numSprints) { $finalWks } else { $defWeeks }
                # Mon-Fri over $weeks working weeks = ($weeks * 7 - 2) calendar days inclusive
                $calDays = $weeks * 7 - 2
                $sprintEnd = $sprintCursor.AddDays($calDays - 1)   # inclusive end date
                $sprintId  = "$sId-W$w"

                $seasonNode.sprints.Add([ordered]@{
                    name      = $sprintId
                    path      = "$ProgramRoot\$y\$sId\$sprintId"
                    startDate = $sprintCursor.ToString('yyyy-MM-ddT00:00:00Z')
                    endDate   = $sprintEnd.ToString('yyyy-MM-ddT00:00:00Z')
                })

                # Next sprint starts the Monday after this sprint ends (Fri + 3 = Mon)
                $sprintCursor = $sprintEnd.AddDays(3)
            }

            $seasonNode['startDate'] = $seasonNode.sprints[0].startDate
            $seasonNode['endDate']   = $seasonNode.sprints[$numSprints - 1].endDate
            $yearNode.seasons.Add($seasonNode)

            # Next season starts the Monday after this season ends
            $seasonCursor = ([DateTime]$seasonNode['endDate'].Substring(0, 10)).AddDays(3)
        }

        $yearNode['startDate'] = $yearNode.seasons[0].startDate
        $yearNode['endDate']   = $yearNode.seasons[$yearNode.seasons.Count - 1].endDate
        $calendar.Add($yearNode)
    }

    return $calendar
}

function ConvertTo-FlatIterationPaths {
    <#
        .SYNOPSIS
        Flattens the nested calendar into a sorted list of iteration path objects
        suitable for storing in the resolved model and creating in ADO.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Calendar)

    $paths = [System.Collections.Generic.List[object]]::new()
    foreach ($year in $Calendar) {
        $paths.Add([ordered]@{ path = $year.path; kind = 'year' })
        foreach ($season in $year.seasons) {
            $paths.Add([ordered]@{
                path      = $season.path
                kind      = 'season'
                startDate = $season.startDate
                endDate   = $season.endDate
            })
            foreach ($sprint in $season.sprints) {
                $paths.Add([ordered]@{
                    path      = $sprint.path
                    kind      = 'sprint'
                    startDate = $sprint.startDate
                    endDate   = $sprint.endDate
                })
            }
        }
    }
    return $paths
}

function Get-InScopeSprintPaths {
    <#
        .SYNOPSIS
        Returns the sprint paths that a delivery team should track, based on
        the number of sprints back/forward from the current sprint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Calendar,
        [int]$Back    = 10,
        [int]$Forward = 10
    )
    $allSprints = @($Calendar | ForEach-Object { $_.seasons | ForEach-Object { $_.sprints } } | Where-Object { $_ })
    $today      = [DateTime]::Today
    $idx        = -1

    # Find current sprint (contains today)
    for ($i = 0; $i -lt $allSprints.Count; $i++) {
        $s = [DateTime]$allSprints[$i].startDate.Substring(0, 10)
        $e = [DateTime]$allSprints[$i].endDate.Substring(0, 10)
        if ($today -ge $s -and $today -le $e) { $idx = $i; break }
    }
    # If between sprints, use next upcoming
    if ($idx -lt 0) {
        for ($i = 0; $i -lt $allSprints.Count; $i++) {
            if ([DateTime]$allSprints[$i].startDate.Substring(0, 10) -gt $today) { $idx = $i; break }
        }
    }
    if ($idx -lt 0) { return @() }

    $from = [Math]::Max(0, $idx - $Back)
    $to   = [Math]::Min($allSprints.Count - 1, $idx + $Forward)
    return @($allSprints[$from..$to] | ForEach-Object { $_.path })
}

function Get-InScopeSeasonPaths {
    <#
        .SYNOPSIS
        Returns the season paths that a portfolio team should track, based on
        the number of seasons back/forward from the current season.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Calendar,
        [int]$Back    = 3,
        [int]$Forward = 3
    )
    $allSeasons = @($Calendar | ForEach-Object { $_.seasons } | Where-Object { $_ })
    $today      = [DateTime]::Today
    $idx        = -1

    for ($i = 0; $i -lt $allSeasons.Count; $i++) {
        $s = [DateTime]$allSeasons[$i].startDate.Substring(0, 10)
        $e = [DateTime]$allSeasons[$i].endDate.Substring(0, 10)
        if ($today -ge $s -and $today -le $e) { $idx = $i; break }
    }
    if ($idx -lt 0) {
        for ($i = 0; $i -lt $allSeasons.Count; $i++) {
            if ([DateTime]$allSeasons[$i].startDate.Substring(0, 10) -gt $today) { $idx = $i; break }
        }
    }
    if ($idx -lt 0) { return @() }

    $from = [Math]::Max(0, $idx - $Back)
    $to   = [Math]::Min($allSeasons.Count - 1, $idx + $Forward)
    return @($allSeasons[$from..$to] | ForEach-Object { $_.path })
}
