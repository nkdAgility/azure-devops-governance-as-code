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

Describe 'Write-GovernanceReport' {

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
