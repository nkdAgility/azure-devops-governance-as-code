#Requires -Modules Pester

# Preflight building blocks: the pure evaluators shared with the reconcile,
# the sources.yaml contract, and the per-node model slicer. Everything here is
# offline — the evaluators are pure by design, and the slicer runs against the
# compiled odyssey fixture.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.Governance/NKDAgility.AzureDevOps.Governance.psd1') -Force

    $programPath = Join-Path $PSScriptRoot 'fixtures/programs/odyssey'
    $outputPath  = Join-Path $repoRoot 'out/test-fixture-odyssey/resolved.yaml'
    $script:outputPath  = Invoke-GovernanceBuild -ProgramPath $programPath -OutputPath $outputPath
    $script:resolved    = ConvertFrom-Yaml (Get-Content $script:outputPath -Raw)
    $script:programPath = $programPath
}

Describe 'Test-GovernanceAreaCompliance' {

    It 'reports desired paths absent from the observed set as missing, in order' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceAreaCompliance `
                -DesiredPaths @('\P\A', '\P\A\B', '\P\C') `
                -LiveDesiredSet @{ '\P\A' = $true } `
                -ModelPaths @('\P\A', '\P\A\B', '\P\C')
            $r.Missing | Should -Be @('\P\A\B', '\P\C')
        }
    }

    It 'reports observed paths outside the FULL model as orphans, deepest-first' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceAreaCompliance `
                -DesiredPaths @('\P\A') -LiveDesiredSet @{ '\P\A' = $true } `
                -ModelPaths @('\P', '\P\A', '\P\Future') `
                -LiveSubtree @{ '\P' = $true; '\P\A' = $true; '\P\X' = $true; '\P\X\Deep' = $true }
            $r.Orphans | Should -Be @('\P\X\Deep', '\P\X')
        }
    }

    It 'never flags scope:future model paths as orphans (ADR-004)' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceAreaCompliance `
                -DesiredPaths @('\P\A') -LiveDesiredSet @{ '\P\A' = $true } `
                -ModelPaths @('\P', '\P\A', '\P\Future') `
                -LiveSubtree @{ '\P' = $true; '\P\A' = $true; '\P\Future' = $true }
            $r.Orphans | Should -BeNullOrEmpty
        }
    }

    It 'skips orphan detection for a bare-root observed set (best-effort bulk fetch contract)' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceAreaCompliance -DesiredPaths @('\P\A') `
                -LiveDesiredSet @{} -ModelPaths @('\P\A') -LiveSubtree @{ '\P' = $true }
            $r.Orphans | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-GovernanceRepoCompliance' {

    It 'classifies missing and orphan repos, exempting the project default repo' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceRepoCompliance `
                -DesiredNames @('PTL-FND-Core', 'PTL-FND-Kit') `
                -LiveNames @('Odyssey', 'PTL-FND-Core', 'RogueRepo') -Project 'Odyssey'
            $r.Missing | Should -Be @('PTL-FND-Kit')
            $r.Orphans | Should -Be @('RogueRepo')
        }
    }

    It 'matches names case-insensitively in both directions' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceRepoCompliance `
                -DesiredNames @('PTL-FND-Core') -LiveNames @('ptl-fnd-core') -Project 'Odyssey'
            $r.Missing | Should -BeNullOrEmpty
            $r.Orphans | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-GovernanceTagCompliance' {

    It 'classifies disallowed, unsanctioned, missing and ok tags' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceTagCompliance `
                -Sanctioned @('Backlog', 'Triage', 'QBS') `
                -DisallowedPatterns @('^\d+$', '^(build|bld)[-_ ]') `
                -LiveTagNames @('Backlog', '12345', 'build-77', 'Rogue', 'triage')
            $r.Disallowed   | Should -Be @('12345', 'build-77')
            $r.Unsanctioned | Should -Be @('Rogue')
            $r.Missing      | Should -Be @('QBS')
            $r.OkCount      | Should -Be 2   # Backlog + triage (case-insensitive)
        }
    }

    It 'groups disallowed tags by the first pattern that caught them, in authored pattern order' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceTagCompliance -Sanctioned @('Backlog') `
                -DisallowedPatterns @('^\d+$', '^P\d{4}(_\d+)*-I\d+', '^never-matches$') `
                -LiveTagNames @('P2026_1_0-I23215', '7', 'Backlog', 'P2021_2_1-I13812', '42')
            @($r.DisallowedByPattern.Keys) | Should -Be @('^\d+$', '^P\d{4}(_\d+)*-I\d+')
            $r.DisallowedByPattern['^\d+$']               | Should -Be @('42', '7')
            $r.DisallowedByPattern['^P\d{4}(_\d+)*-I\d+'] | Should -Be @('P2021_2_1-I13812', 'P2026_1_0-I23215')
            $r.Disallowed.Count | Should -Be 4   # the flat list is unchanged
        }
    }

    It 'returns an empty pattern map when nothing is disallowed' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceTagCompliance -DisallowedPatterns @('^\d+$') -LiveTagNames @('Rogue')
            $r.DisallowedByPattern.Count | Should -Be 0
            $r.Unsanctioned | Should -Be @('Rogue')
        }
    }

    It 'disallowed patterns win over the sanctioned list' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceTagCompliance -Sanctioned @('123') `
                -DisallowedPatterns @('^\d+$') -LiveTagNames @('123')
            $r.Disallowed | Should -Be @('123')
            $r.OkCount    | Should -Be 0
        }
    }
}

Describe 'Test-GovernanceMemberSetCompliance' {

    It 'reports missing members in authored order and extras filtered to the pattern' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceMemberSetCompliance `
                -Desired @(
                    @{ kind = 'user'; display = 'b@x.com'; descriptor = 'aad.B' },
                    @{ kind = 'user'; display = 'a@x.com'; descriptor = 'aad.A' }) `
                -Live @{ 'aad.A' = $true; 'aad.Extra' = $true; 'vssgp.Nested' = $true } `
                -ExtraFilterPattern '^(aad|msa)\.'
            @($r.Missing | ForEach-Object { $_.display }) | Should -Be @('b@x.com')
            $r.Extras | Should -Be @('aad.Extra')   # the nested group is never an extra
        }
    }

    It 'suppresses extras entirely while any desired entry failed to resolve' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceMemberSetCompliance `
                -Desired @(@{ display = 'a@x.com'; descriptor = 'aad.A' }) `
                -Live @{ 'aad.A' = $true; 'aad.Extra' = $true } `
                -AnyUnresolved $true -ExtraFilterPattern '^(aad|msa)\.'
            $r.Extras | Should -BeNullOrEmpty
        }
    }

    It 'treats an empty desired list as enforced-empty: everything eligible is an extra' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $r = Test-GovernanceMemberSetCompliance -Desired @() `
                -Live @{ 'aad.Extra' = $true }
            $r.Extras | Should -Be @('aad.Extra')
        }
    }
}

Describe 'Select-GovernanceSubtree' {

    It 'slices one node: its teams, home-area subtree, owned repos, program-wide tags' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL-FND'
            $slice.TargetRoot | Should -Be '\Odyssey\Portal\Platform\Foundation'
            @($slice.Teams | ForEach-Object { $_.codePath }) | Should -Contain 'PTL-FND'
            @($slice.AreaPaths | ForEach-Object { $_.path }) | Should -Contain '\Odyssey\Portal\Platform\Foundation\Inbox'
            @($slice.AreaPaths | ForEach-Object { $_.path }) | Should -Not -Contain '\Odyssey\Portal\Platform\Graphics Pipeline'
            @($slice.Repos | ForEach-Object { $_.owner }) | Should -Not -Contain 'PTL-GPI'
            $slice.Tags.sanctioned | Should -Contain 'Backlog'
        }
    }

    It 'includes descendant teams by codePath prefix' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL'
            @($slice.Teams | ForEach-Object { $_.codePath }) | Should -Contain 'PTL-FND'
            @($slice.Teams | ForEach-Object { $_.codePath }) | Should -Not -Contain 'PDS'
        }
    }

    It 'throws for an unknown code, listing the known ones' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            { Select-GovernanceSubtree -Resolved $resolved -Code 'NOPE' } | Should -Throw '*Known codes*'
        }
    }
}

Describe 'sources.yaml contract' {

    It 'loads the fixture sources.yaml keyed by codePath' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ programPath = $script:programPath } {
            param($programPath)
            $source = Import-GovernanceSource -ProgramPath $programPath
            $source.Sources.Keys | Should -Contain 'PTL-FND'
            $source.Sources['PTL-FND'].areaPath | Should -Be 'LegacyPortal\Foundation'
        }
    }

    It 'accepts the fixture sources against the resolved model' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ programPath = $script:programPath; resolved = $script:resolved } {
            param($programPath, $resolved)
            $source = Import-GovernanceSource -ProgramPath $programPath
            Test-GovernanceSources -Sources $source.Sources -Resolved $resolved | Should -BeNullOrEmpty
        }
    }

    It 'rejects an unknown code, a rootless areaPath, and a literal token' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            $bad = @{
                'NOPE'    = @{ org = 'o'; project = 'p'; areaPath = 'p\x' }
                'PTL-FND' = @{ org = 'o'; project = 'p'; areaPath = '\p\x'; accessToken = 'pat-in-the-clear' }
                'PTL-GPI' = @{ org = 'o'; project = 'p'; areaPath = 'other\x' }
            }
            $issues = @(Test-GovernanceSources -Sources $bad -Resolved $resolved)
            @($issues | Where-Object { $_ -like "*'NOPE'*codePath*" }).Count           | Should -Be 1
            @($issues | Where-Object { $_ -like "*leading*" }).Count                    | Should -Be 1
            @($issues | Where-Object { $_ -like "*never a literal token*" }).Count      | Should -Be 1
            @($issues | Where-Object { $_ -like "*must start with the source project*" }).Count | Should -Be 1
        }
    }

    It 'is a no-op for a program without sources.yaml' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            Test-GovernanceSources -Sources $null -Resolved $resolved | Should -BeNullOrEmpty
        }
    }
}

Describe 'sources.yaml labels' {

    It 'loads the fixture labels keyed by check id' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ programPath = $script:programPath } {
            param($programPath)
            $source = Import-GovernanceSource -ProgramPath $programPath
            $source.SourceLabels.Keys | Should -Contain 'area.orphan'
            $source.SourceLabels['area.orphan'].rule | Should -Be 'A2'
        }
    }

    It 'accepts the fixture labels and rejects unknown check ids, nested values and engine fields' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ programPath = $script:programPath; resolved = $script:resolved } {
            param($programPath, $resolved)
            $source = Import-GovernanceSource -ProgramPath $programPath
            Test-GovernanceSources -Sources $source.Sources -Resolved $resolved -Labels $source.SourceLabels | Should -BeNullOrEmpty

            $bad = @{
                'area.orphan'   = @{ rule = 'A2'; message = 'nope' }
                'not.a.check'   = @{ rule = 'Z9' }
                'tag.disallowed' = @{ owners = @('a', 'b') }
            }
            $issues = @(Test-GovernanceSources -Sources $null -Resolved $resolved -Labels $bad)
            @($issues | Where-Object { $_ -like "*'not.a.check' is not a preflight check id*" }).Count | Should -Be 1
            @($issues | Where-Object { $_ -like "*may not override the engine field 'message'*" }).Count | Should -Be 1
            @($issues | Where-Object { $_ -like "*'tag.disallowed'.'owners' must be a scalar*" }).Count | Should -Be 1
        }
    }
}

Describe 'Resolve-GovernancePreflightFindings' {

    BeforeAll {
        # A synthetic gathered document for the fixture's PTL-FND node: two
        # source sub-areas (one authored as Inbox, one not), a build-id tag
        # family, one rogue tag, one sanctioned tag, an unresolvable admin and
        # a source population with one unauthored person.
        $script:fndData = [ordered]@{
            schema     = 'nkdagility.governance.preflight-data/1'
            gathered   = '2026-09-04T10:00:00Z'
            program    = 'Odyssey'
            node       = 'PTL-FND'
            target     = [ordered]@{ org = 'https://dev.azure.com/x'; project = 'Odyssey'; root = '\Odyssey\Portal\Platform\Foundation' }
            source     = [ordered]@{ org = 'https://dev.azure.com/legacy'; project = 'LegacyPortal'; areaPath = '\LegacyPortal\Foundation'; teams = @('Foundation Crew'); repoInclude = @('Foundation*') }
            workItems  = [ordered]@{ count = 12 }
            areas      = @(
                [ordered]@{ source = '\LegacyPortal\Foundation';          target = '\Odyssey\Portal\Platform\Foundation';          workItems = 5 },
                [ordered]@{ source = '\LegacyPortal\Foundation\Inbox';    target = '\Odyssey\Portal\Platform\Foundation\Inbox';    workItems = 3 },
                [ordered]@{ source = '\LegacyPortal\Foundation\Plotting'; target = '\Odyssey\Portal\Platform\Foundation\Plotting'; workItems = 4 }
            )
            tags       = [ordered]@{ 'Backlog' = 2; 'P2026_1_0-I23215' = 3; 'P2025_1_0-I3800' = 1; 'Rogue' = 7 }
            iterations = [ordered]@{ 'LegacyPortal\2025' = 12 }
            repos      = @('Foundation-Core')
            population = [ordered]@{ 'nobody@example.com' = 'Foundation Crew' }
            authored   = [ordered]@{
                members    = @([ordered]@{ upn = 'alex@example.com'; group = 'PTL-FND-Contributors'; resolved = $true; suggestions = @() })
                teamAdmins = @([ordered]@{ upn = 'ghost@example.com'; team = 'Foundation'; resolved = $false; suggestions = @('ghosting@example.com') })
            }
        }
    }

    It 'turns the data document into structured findings with check ids and counts' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved; data = $script:fndData } {
            param($resolved, $data)
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL-FND'
            $slice.Tags = @{ sanctioned = @('Backlog', 'Triage'); disallowedPatterns = @('^P\d{4}(_\d+)*-I\d+') }
            $r = Resolve-GovernancePreflightFindings -Data $data -Slice $slice

            $byCheck = @{}
            foreach ($f in $r.Findings) {
                if (-not $byCheck.ContainsKey($f.check)) { $byCheck[$f.check] = @() }
                $byCheck[$f.check] += @($f)
            }

            $orphan = $byCheck['area.orphan'][0]
            $orphan.class     | Should -Be 'exception'
            $orphan.subject   | Should -Be '\Odyssey\Portal\Platform\Foundation\Plotting'
            $orphan.source    | Should -Be '\LegacyPortal\Foundation\Plotting'
            $orphan.workItems | Should -Be 4
            $orphan.message   | Should -Match '^AUDIT EXCEPTION area path'

            $family = $byCheck['tag.disallowed'][0]
            $family.class     | Should -Be 'drift'
            $family.tags      | Should -Be 2
            $family.workItems | Should -Be 4
            $family.examples  | Should -Be @('P2026_1_0-I23215', 'P2025_1_0-I3800')
            @($byCheck['tag.disallowed']).Count | Should -Be 1   # one finding per pattern, not per tag

            $byCheck['tag.unsanctioned'][0].subject   | Should -Be 'Rogue'
            $byCheck['tag.unsanctioned'][0].workItems | Should -Be 7
            $byCheck['teamAdmin.unresolvable'][0].suggestions | Should -Be @('ghosting@example.com')
            $byCheck['member.unauthored'][0].subject    | Should -Be 'nobody@example.com'
            $byCheck['member.unauthored'][0].sourceTeam | Should -Be 'Foundation Crew'
            $byCheck.Keys | Should -Not -Contain 'member.unresolvable'

            $r.Info | Should -Contain 'sanctioned tag not in use at the source (apply seeds it in the target): Triage'
            $r.Info | Should -Contain '12 work item(s) under LegacyPortal\Foundation at the source'
            @($r.Lines | Where-Object { $_.level -eq 'section' }).Count | Should -Be 4
        }
    }

    It 'attaches label fields per check id without overriding engine fields' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved; data = $script:fndData } {
            param($resolved, $data)
            $slice  = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL-FND'
            $labels = @{ 'area.orphan' = @{ rule = 'A2'; lane = 'PM'; subject = 'must-not-win' } }
            $r = Resolve-GovernancePreflightFindings -Data $data -Slice $slice -Labels $labels
            $orphan = @($r.Findings | Where-Object { $_.check -eq 'area.orphan' })[0]
            $orphan.rule    | Should -Be 'A2'
            $orphan.lane    | Should -Be 'PM'
            $orphan.subject | Should -Be '\Odyssey\Portal\Platform\Foundation\Plotting'
            @($r.Findings | Where-Object { $_.check -eq 'tag.unsanctioned' })[0].Keys | Should -Not -Contain 'rule'
        }
    }

    It 'gives the same verdicts from a document round-tripped through JSON' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved; data = $script:fndData } {
            param($resolved, $data)
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL-FND'
            $fresh    = Resolve-GovernancePreflightFindings -Data $data -Slice $slice
            $reloaded = Resolve-GovernancePreflightFindings -Slice $slice `
                -Data ($data | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20)
            @($reloaded.Findings | ForEach-Object { $_.message }) | Should -Be @($fresh.Findings | ForEach-Object { $_.message })
            $reloaded.Info | Should -Be $fresh.Info
        }
    }
}

Describe 'sources.yaml reporting' {

    It 'loads the fixture reporting block and accepts it' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ programPath = $script:programPath; resolved = $script:resolved } {
            param($programPath, $resolved)
            $source = Import-GovernanceSource -ProgramPath $programPath
            $source.SourceReporting.candidateTagMinUses | Should -Be 5
            Test-GovernanceSources -Sources $source.Sources -Resolved $resolved -Labels $source.SourceLabels -Reporting $source.SourceReporting | Should -BeNullOrEmpty
        }
    }

    It 'rejects unknown fields and a non-positive threshold' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved } {
            param($resolved)
            $issues = @(Test-GovernanceSources -Sources $null -Resolved $resolved -Reporting @{ colour = 'blue'; candidateTagMinUses = 0 })
            @($issues | Where-Object { $_ -like "*'colour' is not a reporting field*" }).Count | Should -Be 1
            @($issues | Where-Object { $_ -like "*'candidateTagMinUses' must be a positive integer*" }).Count | Should -Be 1
        }
    }
}

Describe 'ConvertTo-GovernancePreflightReport' {

    BeforeAll {
        # Real data + findings files, produced by the real analysis and the real
        # report writer, so the renderer is tested against the shapes it will meet.
        $script:renderDir = Join-Path ([System.IO.Path]::GetTempPath()) "gov-render-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:renderDir | Out-Null
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ resolved = $script:resolved; data = $script:fndData; dir = $script:renderDir } {
            param($resolved, $data, $dir)
            $slice = Select-GovernanceSubtree -Resolved $resolved -Code 'PTL-FND'
            $slice.Tags = @{ sanctioned = @('Backlog', 'Triage'); disallowedPatterns = @('^P\d{4}(_\d+)*-I\d+') }
            $labels = @{ 'area.orphan' = @{ rule = 'A2'; task = 2; lane = 'PM' }; 'tag.unsanctioned' = @{ rule = 'B4'; task = 6; lane = 'Eng' } }
            $r = Resolve-GovernancePreflightFindings -Data $data -Slice $slice -Labels $labels
            $data | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $dir 'preflight-PTL-FND.data.json') -Encoding utf8
            Write-GovernanceReport -FindingObjects $r.Findings -InfoLines $r.Info -ProgramName 'Odyssey' -Project 'Odyssey' `
                -OrgUrl 'https://dev.azure.com/x' -Mode 'Preflight' -ReportPath (Join-Path $dir 'preflight-PTL-FND.txt') 6>$null | Out-Null
        }
        $script:renderData = Join-Path $script:renderDir 'preflight-PTL-FND.data.json'
        $script:renderFind = Join-Path $script:renderDir 'preflight-PTL-FND.json'
    }
    AfterAll { Remove-Item $script:renderDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'renders every count from the inputs, with label columns, and the threshold it was given' {
        $out = ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $script:renderFind `
            -Reporting @{ standard = 'Fixture Standard'; candidateTagMinUses = 5 }
        $md = Get-Content $out -Raw
        $md | Should -Match '\| 4 \| Plotting \| not authored \|'
        $md | Should -Match '\| 3 \| Inbox \| authored \|'
        $md | Should -Match '\| 5 \| \*\(root\)\* \| root \|'
        $md | Should -Match '\| Area paths not authored in the target \| 1 of 2 sub-areas \| A2 \| 2 \| PM \|'
        $md | Should -Match '1 families, 2 tags on 4 work items'
        $md | Should -Match 'more than 5 work items'
        $md | Should -Match '\| 7 \| Rogue \|'
        $md | Should -Match 'Fixture Standard'
        $md | Should -Match 'Sanctioned tags not yet in use here.*Triage'
        $md | Should -Match 'Repositories not authored \| 1 of 1 repos'
        $md | Should -Match '1 people work here today and are not authored'
        $md | Should -Match '_No observations were generated for this report\._'
        $md | Should -Match '- \*\*Area paths not authored in the target\*\* — 1 · Task 2 · rule A2 · PM'
    }

    It 'is byte-identical on a second run' {
        $out = ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $script:renderFind
        $first = [System.IO.File]::ReadAllBytes($out)
        ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $script:renderFind | Out-Null
        [System.IO.File]::ReadAllBytes($out) | Should -Be $first
    }

    It 'splices an observations fragment between the markers and leaves every table byte unchanged' {
        $plain = Get-Content (ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $script:renderFind) -Raw
        $frag  = Join-Path $script:renderDir 'observations-PTL-FND.md'
        Set-Content $frag "- **One thing.** It means something.`r`n- **Another.** It means more."
        $with = Get-Content (ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $script:renderFind -ObservationsPath $frag) -Raw
        $with | Should -Match "(?s)<!-- observations:begin -->\n- \*\*One thing\.\*\*.*\n- \*\*Another\.\*\*.*\n<!-- observations:end -->"
        $with | Should -Not -Match 'No observations were generated'
        # everything outside the observations block is identical
        $strip = { param($s) [regex]::Replace($s, '(?s)<!-- observations:begin -->.*<!-- observations:end -->', 'X') }
        (& $strip $with) | Should -Be (& $strip $plain)
    }

    It 'refuses a findings document that is not a preflight report' {
        $audit = Join-Path $script:renderDir 'audit.json'
        Set-Content $audit '{"mode":"Audit","findings":[]}'
        { ConvertTo-GovernancePreflightReport -DataPath $script:renderData -FindingsPath $audit } | Should -Throw "*not a preflight findings document*"
    }
}

Describe 'Invoke-GovernancePreflight -SkipFresh' {

    It 'reuses an existing data file and writes the report without contacting any organisation' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "gov-skipfresh-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $dataPath = Join-Path $dir 'preflight-PTL-FND.data.json'
            $script:fndData | ConvertTo-Json -Depth 20 | Set-Content $dataPath -Encoding utf8
            $stamp = (Get-Item $dataPath).LastWriteTimeUtc
            # No az session or PAT is arranged for this test: if the gather were
            # attempted, Initialize-AdoAuth would be the thing that fails.
            Invoke-GovernancePreflight -ProgramPath $script:programPath -ResolvedPath (Join-Path $dir 'resolved.yaml') `
                -Code PTL-FND -SkipFresh -ErrorAction SilentlyContinue 6>$null 2>$null
            (Get-Item $dataPath).LastWriteTimeUtc | Should -Be $stamp
            $json = Get-Content (Join-Path $dir 'preflight-PTL-FND.json') -Raw | ConvertFrom-Json
            $json.findingCount | Should -BeGreaterThan 0
            @($json.findings | Where-Object check -eq 'preflight.error').Count | Should -Be 0
            (Get-Content (Join-Path $dir 'preflight-PTL-FND.txt') -Raw) | Should -Match 'Data     : preflight-PTL-FND.data.json'
        } finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Write-GovernanceReport' {

    It 'writes finding objects whole into the JSON twin and their messages into the text report' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "gov-report-test-$([guid]::NewGuid()).txt"
            try {
                Write-GovernanceReport -FindingObjects @(
                        [ordered]@{ class = 'exception'; check = 'area.orphan'; subject = '\P\X'; workItems = 4; rule = 'A2'; message = 'AUDIT EXCEPTION area path: \P\X' },
                        [ordered]@{ class = 'unresolvable'; check = 'teamAdmin.unresolvable'; subject = 'g@x.com'; message = "UNRESOLVABLE team admin 'g@x.com' for 'T': no org member matches this UPN" }) `
                    -ProgramName 'Odyssey' -Project 'Odyssey' -OrgUrl 'https://dev.azure.com/x' `
                    -Mode 'Preflight' -ReportPath $path -Title 'Governance preflight report' 6>$null | Out-Null
                $text = Get-Content $path -Raw
                $text | Should -Match 'AUDIT FAILURES \(exist in ADO but not in config\) \(1\):'
                $text | Should -Match ([regex]::Escape('  - AUDIT EXCEPTION area path: \P\X'))
                $text | Should -Match 'ERRORS AND WHY \(2\):'   # the WHY line plus the one unresolvable
                $json = Get-Content ([System.IO.Path]::ChangeExtension($path, 'json')) -Raw | ConvertFrom-Json
                $json.findingCount | Should -Be 2
                $json.findings[0].PSObject.Properties.Name[0] | Should -Be 'class'
                $json.findings[0].check     | Should -Be 'area.orphan'
                $json.findings[0].workItems | Should -Be 4
                $json.findings[0].rule      | Should -Be 'A2'
                $json.findings[1].class     | Should -Be 'unresolvable'
                $json.findings[1].PSObject.Properties.Name | Should -Contain 'why'
            } finally {
                Remove-Item $path, ([System.IO.Path]::ChangeExtension($path, 'json')) -ErrorAction SilentlyContinue
            }
        }
    }

    It 'refuses a finding object without class or message, and refuses both forms at once' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            { Write-GovernanceReport -FindingObjects @(@{ check = 'x' }) -ProgramName 'O' -Project 'O' -OrgUrl 'u' -Mode 'Preflight' 6>$null } |
                Should -Throw "*needs 'class' and 'message'*"
            { Write-GovernanceReport -Findings @('DRIFT x') -FindingObjects @(@{ class = 'drift'; message = 'DRIFT y' }) -ProgramName 'O' -Project 'O' -OrgUrl 'u' -Mode 'Preflight' 6>$null } |
                Should -Throw '*not both*'
        }
    }

    It 'writes the text report and JSON twin with prefix-classified findings' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "gov-report-test-$([guid]::NewGuid()).txt"
            try {
                $suffix = Write-GovernanceReport -Findings @(
                        'MISSING tag: QBS (sanctioned but not in use)',
                        "DRIFT tag 'build-1': matches a disallowed pattern",
                        'AUDIT EXCEPTION repo: RogueRepo') `
                    -ProgramName 'Odyssey' -Project 'Odyssey' -OrgUrl 'https://dev.azure.com/x' `
                    -Mode 'Preflight' -ReportPath $path -Title 'Governance preflight report' `
                    -InfoLines @('42 work item(s) at the source') 6>$null
                $suffix | Should -Be 'found'
                $text = Get-Content $path -Raw
                $text | Should -Match 'Governance preflight report'
                $text | Should -Match 'NON-COMPLIANT'
                $text | Should -Match 'INFO \(not findings\) \(1\):'
                $json = Get-Content ([System.IO.Path]::ChangeExtension($path, 'json')) -Raw | ConvertFrom-Json
                $json.findingCount | Should -Be 3
                @($json.findings | Where-Object class -eq 'exception').Count | Should -Be 1
                $json.info | Should -Be @('42 work item(s) at the source')
            } finally {
                Remove-Item $path, ([System.IO.Path]::ChangeExtension($path, 'json')) -ErrorAction SilentlyContinue
            }
        }
    }

    It 'keeps the audit report format unchanged when no info lines are passed' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "gov-report-test-$([guid]::NewGuid()).txt"
            try {
                Write-GovernanceReport -Findings @() -ProgramName 'Odyssey' -Project 'Odyssey' `
                    -OrgUrl 'https://dev.azure.com/x' -Mode 'Audit' -ReportPath $path 6>$null | Out-Null
                $text = Get-Content $path -Raw
                $text | Should -Match 'Governance audit report'
                $text | Should -Match 'COMPLIANT'
                $text | Should -Not -Match 'INFO'
                $json = Get-Content ([System.IO.Path]::ChangeExtension($path, 'json')) -Raw | ConvertFrom-Json
                $json.PSObject.Properties.Name | Should -Not -Contain 'info'
            } finally {
                Remove-Item $path, ([System.IO.Path]::ChangeExtension($path, 'json')) -ErrorAction SilentlyContinue
            }
        }
    }
}
