#Requires -Modules Pester
# ADR-014: templated preflight reports — the placeholder language, the model,
# and the document markers. Offline; anonymised data only.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.Governance/NKDAgility.AzureDevOps.Governance.psd1') -Force
}

Describe 'Expand-GovernanceTemplate' {
    It 'fills values, counts, sums and number words' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ team = [ordered]@{ name = 'Delta' }; items = @(
                [ordered]@{ name = 'a'; n = 3 }, [ordered]@{ name = 'b'; n = 0 }, [ordered]@{ name = 'c'; n = 0 }) }
            Expand-GovernanceTemplate -Template '{{team.name}}: {{count items}} items, {{sum items n}} total, {{Words count items where=n=0}} empty' -Model $m |
                Should -Be 'Delta: 3 items, 3 total, Two empty'
        }
    }

    It 'loops with limit, where and @first/@last' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ items = @([ordered]@{ p = 'Proj\2027' }, [ordered]@{ p = 'Proj\2027\S1' }, [ordered]@{ p = 'Proj\2026' }) }
            Expand-GovernanceTemplate -Template '{{#each items where=p~^Proj\\\d{4}$}}{{#unless @first}}, {{/unless}}{{.p}}{{/each}}' -Model $m |
                Should -Be 'Proj\2027, Proj\2026'
            Expand-GovernanceTemplate -Template '{{#each items limit=1}}{{.p}}{{/each}}' -Model $m | Should -Be 'Proj\2027'
        }
    }

    It 'takes a block tag alone on its line with the line' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ items = @([ordered]@{ n = 1 }, [ordered]@{ n = 2 }) }
            $t = "before`n{{#each items}}`n- {{.n}}`n{{/each}}`nafter"
            Expand-GovernanceTemplate -Template $t -Model $m | Should -Be "before`n- 1`n- 2`nafter"
        }
    }

    It 'branches on truthiness and comparisons' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ n = 1; empty = @(); s = '' }
            Expand-GovernanceTemplate -Template '{{#if n == 1}}one{{else}}many{{/if}}|{{#if empty}}x{{else}}none{{/if}}|{{#unless s}}blank{{/unless}}' -Model $m |
                Should -Be 'one|none|blank'
        }
    }

    It 'zips two lists, leaving the shorter side empty' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ t = @([ordered]@{ n = 5; k = 'x' }, [ordered]@{ n = 1; k = 'y' }, [ordered]@{ n = 1; k = 'z' }) }
            $t = "{{#zip a=t awhere=n>1 b=t bwhere=n=1}}`n|{{#if a}} {{a.k}} |{{else}} |{{/if}} {{b.k}} |`n{{/zip}}"
            Expand-GovernanceTemplate -Template $t -Model $m | Should -Be "| x | y |`n| | z |`n"
        }
    }

    It 'reads notes, and an absent note is empty' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ notes = @{ B7 = 'A candidate.' } }
            Expand-GovernanceTemplate -Template '[{{note B7}}][{{note B8}}]' -Model $m | Should -Be '[A candidate.][]'
        }
    }

    It 'treats an unrecorded contact as empty but throws on any other missing field' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ contacts = [ordered]@{}; team = [ordered]@{ name = 'Delta' } }
            Expand-GovernanceTemplate -Template '[{{contacts.dataOwner}}]' -Model $m | Should -Be '[]'
            { Expand-GovernanceTemplate -Template '{{team.nmae}}' -Model $m } | Should -Throw '*no field*'
            { Expand-GovernanceTemplate -Template '{{nope}}' -Model $m } | Should -Throw '*not in the report model*'
        }
    }

    It 'throws on unclosed blocks, stray closers and unknown helpers' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $m = [ordered]@{ x = 1 }
            { Expand-GovernanceTemplate -Template '{{#if x}}open' -Model $m } | Should -Throw '*never closed*'
            { Expand-GovernanceTemplate -Template '{{/each}}' -Model $m } | Should -Throw '*not opened*'
            { Expand-GovernanceTemplate -Template '{{frobnicate x}}' -Model $m } | Should -Throw '*unknown helper*'
        }
    }
}

Describe 'ConvertTo-GovernancePreflightTemplateReport' {
    BeforeAll {
        $script:dir = Join-Path $TestDrive 'tpl'
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $data = [ordered]@{
            schema = 'nkdagility.governance.preflight-data/1'; gathered = '2026-01-15T10:00:00Z'; program = 'Odyssey'; node = 'ODY-NAV'
            target = [ordered]@{ org = 'https://dev.azure.com/target-org'; project = 'Odyssey'; root = '\Odyssey\Fleet\Navigation' }
            source = [ordered]@{ org = 'https://dev.azure.com/legacy-org'; project = 'Legacy'; areaPath = '\Legacy\Navigation'; teams = @(); repoInclude = $null }
            scope = [ordered]@{ query = 'SELECT [System.Id] FROM WorkItems'; label = 'open navigation work' }
            workItems = [ordered]@{ count = 42 }
            areas = @(
                [ordered]@{ source = '\Legacy\Navigation'; target = '\Odyssey\Fleet\Navigation'; workItems = 20 },
                [ordered]@{ source = '\Legacy\Navigation\Charts'; target = '\Odyssey\Fleet\Navigation\Charts'; workItems = 15 },
                [ordered]@{ source = '\Legacy\Navigation\Old'; target = '\Odyssey\Fleet\Navigation\Old'; workItems = 0 })
            unmappedAreas = @()
            tags = [ordered]@{ alpha = 5; beta = 1 }
            iterations = [ordered]@{ 'Legacy\2026\S1' = 30; 'Legacy\2027' = 12 }
            repos = @(); population = [ordered]@{}
            authored = [ordered]@{ members = @([ordered]@{ upn = 'pilot@example.com'; resolved = $true }); teamAdmins = @() }
        }
        $findings = [ordered]@{ mode = 'Preflight'; findings = @(
            [ordered]@{ class = 'exception'; check = 'area.orphan'; subject = '\Odyssey\Fleet\Navigation\Charts'; source = '\Legacy\Navigation\Charts'; workItems = 15 },
            [ordered]@{ class = 'exception'; check = 'area.orphan'; subject = '\Odyssey\Fleet\Navigation\Old'; source = '\Legacy\Navigation\Old'; workItems = 0 },
            [ordered]@{ class = 'exception'; check = 'tag.unsanctioned'; subject = 'alpha'; workItems = 5 }); info = @() }
        $script:dataPath = Join-Path $script:dir 'odyssey-preflight-ODY-NAV-data.json'
        $script:finPath  = Join-Path $script:dir 'odyssey-preflight-ODY-NAV-findings.json'
        $data | ConvertTo-Json -Depth 10 | Set-Content $script:dataPath
        $findings | ConvertTo-Json -Depth 10 | Set-Content $script:finPath
        $script:docPath = Join-Path $script:dir 'standard.md'
        @(
            '---', 'title: "The standard"', '---', '',
            '<!-- team:replace header -->', '', '| In | general |', '', '<!-- team:end -->', '',
            '## Steps', '',
            'Intro sentence. <!-- team:slot note -->', '',
            '<!-- team:column hdr sep row -->', '',
            '| Step | What |', '|-|---|', '| 1 | Fold |', '| 2 | Tags |', '',
            '![diagram](assets/d.svg)', '',
            '- [ ] Every path is recorded. <!-- team:check c1 -->', '- [ ] Owners named. <!-- team:check c2 -->', '',
            '<!-- team:fill 3 trk -->', '', '| Step | What | Notes |', '|-|-|-|', '| 1 | Fold | |', '| 2 | Tags | |', '',
            '<!-- team:slot detail -->', '',
            '--- End ---'
        ) | Set-Content $script:docPath
        $script:slotsPath = Join-Path $script:dir 'slots.md'
        @(
            '<!-- slot: header -->', '| Team | {{team.name}} (`{{team.code}}`) |', '',
            '<!-- slot: note -->', '{{team.name}} data from {{gathered}}.', '',
            '<!-- slot: hdr -->', '{{team.name}} today', '',
            '<!-- slot: sep -->', '|-|---|---|', '',
            '<!-- slot: row.1 -->', '{{count areas.orphans}} of {{areas.subCount}} to record', '',
            '<!-- slot: row.2 -->', '{{count tags.undecided}} to decide', '',
            '<!-- slot: c1 -->', '{{#if count areas.orphans}}[ ] **{{team.name}}:** {{count areas.orphans}} to record.{{else}}[x]{{/if}}', '',
            '<!-- slot: c2 -->', '[x] *Self-check.*', '',
            '<!-- slot: trk.1 -->', '{{count areas.orphans}} to record', '',
            '<!-- slot: trk.2 -->', 'done', '',
            '<!-- slot: detail -->', '{{#each areas.orphans}}', '- `{{.rel}}` ({{.workItems}}){{#if @first}} {{note first}}{{/if}}', '{{/each}}'
        ) | Set-Content $script:slotsPath
    }

    It 'fills the markers and leaves the rest of the document as written' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ d = $script:dataPath; f = $script:finPath; doc = $script:docPath; s = $script:slotsPath; dir = $script:dir } {
            $notes = Join-Path $dir 'notes.md'
            Start-Sleep -Milliseconds 20
            "<!-- note: first -->`nLargest." | Set-Content $notes
            $out = ConvertTo-GovernancePreflightTemplateReport -DataPath $d -FindingsPath $f -DocumentPath $doc -SlotsPath $s -NotesPath $notes -AssetPrefix '../std/' -OutputPath (Join-Path $dir 'out.md')
            $text = (Get-Content $out -Raw) -replace "`r`n", "`n"
            $text | Should -Match '\| Team \| Navigation \(`ODY-NAV`\) \|'
            $text | Should -Not -Match '\| In \| general \|'
            $text | Should -Match 'Intro sentence\. Navigation data from 15 January 2026\.'
            $text | Should -Match '\| Step \| What \| Navigation today \|\n\|-\|---\|---\|\n\| 1 \| Fold \| 2 of 2 to record \|\n\| 2 \| Tags \| 1 to decide \|'
            $text | Should -Match '!\[diagram\]\(\.\./std/assets/d\.svg\)'
            $text | Should -Match '- `Charts` \(15\) Largest\.\n- `Old` \(0\)\n\n--- End ---'
            $text | Should -Match '- \[ \] Every path is recorded\. \*\*Navigation:\*\* 2 to record\.\n- \[x\] Owners named\. \*Self-check\.\*'
            $text | Should -Match '\| 1 \| Fold \| 2 to record \|\n\| 2 \| Tags \| done \|'
            $text | Should -Not -Match 'team:'
        }
    }

    It 'withholds notes older than the findings' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ d = $script:dataPath; f = $script:finPath; doc = $script:docPath; s = $script:slotsPath; dir = $script:dir } {
            $notes = Join-Path $dir 'notes.md'
            "<!-- note: first -->`nLargest." | Set-Content $notes
            (Get-Item $notes).LastWriteTimeUtc = (Get-Item $f).LastWriteTimeUtc.AddMinutes(-5)
            $out = ConvertTo-GovernancePreflightTemplateReport -DataPath $d -FindingsPath $f -DocumentPath $doc -SlotsPath $s -NotesPath $notes -OutputPath (Join-Path $dir 'out2.md') -WarningAction SilentlyContinue
            (Get-Content $out -Raw) | Should -Not -Match 'Largest'
        }
    }

    It 'throws when a marker names a slot the slots file does not have' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ d = $script:dataPath; f = $script:finPath; s = $script:slotsPath; dir = $script:dir } {
            $doc = Join-Path $dir 'bad.md'
            "Text`n<!-- team:slot missing -->" | Set-Content $doc
            { ConvertTo-GovernancePreflightTemplateReport -DataPath $d -FindingsPath $f -DocumentPath $doc -SlotsPath $s -OutputPath (Join-Path $dir 'out3.md') } |
                Should -Throw "*no slot 'missing'*"
        }
    }

    It 'throws when a check slot does not start with a box' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ d = $script:dataPath; f = $script:finPath; dir = $script:dir } {
            $doc = Join-Path $dir 'chk.md'; '- [ ] Item. <!-- team:check bad -->' | Set-Content $doc
            $sl = Join-Path $dir 'chk-slots.md'; "<!-- slot: bad -->`nno box" | Set-Content $sl
            { ConvertTo-GovernancePreflightTemplateReport -DataPath $d -FindingsPath $f -DocumentPath $doc -SlotsPath $sl -OutputPath (Join-Path $dir 'out4.md') } | Should -Throw '*must start with*'
        }
    }
}

Describe 'sources.yaml reporting.template contract' {
    It 'accepts document, slots and assetPrefix and rejects anything else' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $resolved = [pscustomobject]@{ teams = @() }
            $ok = @{ template = @{ document = 'std.md'; slots = 'slots.md'; assetPrefix = '../std/' } }
            @(Test-GovernanceSources -Resolved $resolved -Reporting $ok) | Should -BeNullOrEmpty
            $bad = @{ template = @{ document = 'std.md'; extra = 'x' } }
            $issues = @(Test-GovernanceSources -Resolved $resolved -Reporting $bad)
            ($issues -join "`n") | Should -Match "template 'extra' is not a template field"
            ($issues -join "`n") | Should -Match "template is missing 'slots'"
        }
    }
}
