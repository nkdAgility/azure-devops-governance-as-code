#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'module/AdoGovernance/AdoGovernance.psd1') -Force

    $programPath = Join-Path $repoRoot 'programs/odyssey'
    $outputPath  = Join-Path $repoRoot 'out/odyssey/resolved.yaml'
    $script:outputPath = Invoke-GovernanceBuild -ProgramPath $programPath -OutputPath $outputPath
    $script:resolved = ConvertFrom-Yaml (Get-Content $script:outputPath -Raw)
}

Describe 'Compile stage' {

    It 'writes the resolved file' {
        $script:outputPath | Should -Exist
    }

    It 'emits the program root area path' {
        $script:resolved.areaPaths.path | Should -Contain '\Odyssey'
    }

    It 'registers all three Portal bands from sections' {
        $script:resolved.areaPaths.path | Should -Contain '\Odyssey\Portal\Platform'
        $script:resolved.areaPaths.path | Should -Contain '\Odyssey\Portal\Plugins'
        $script:resolved.areaPaths.path | Should -Contain '\Odyssey\Portal\Platform Engineering'
    }

    It 'creates a team per owning node (Foundation)' {
        ($script:resolved.teams | Where-Object name -eq 'Portal · Foundation') | Should -Not -BeNullOrEmpty
    }

    It 'nests sub-teams (Open API under Foundation)' {
        $openApi = $script:resolved.teams | Where-Object name -eq 'Portal · Foundation · Open API'
        $openApi.parent | Should -Be 'Portal · Foundation'
        $openApi.defaultAreaPath | Should -Be '\Odyssey\Portal\Platform\Foundation\Open API'
    }

    It 'routes Colors ownership into the Graphics Pipeline (GPI) area config' {
        $gpi = $script:resolved.teams | Where-Object short -eq 'GPI'
        $gpi.areaConfig.path | Should -Contain '\Odyssey\Colors'
    }

    It 'does not create a separate Colors team' {
        ($script:resolved.teams | Where-Object name -eq 'Colors') | Should -BeNullOrEmpty
    }

    It 'adds owned plugin paths to the owning team area config' {
        $fnd = $script:resolved.teams | Where-Object short -eq 'FND'
        $fnd.areaConfig.path | Should -Contain '\Odyssey\Portal\Plugins\Plugin A'
    }

    It 'derives a repo for each plugin' {
        ($script:resolved.repos | Where-Object name -eq 'PTL-PLGA-plugin-a') | Should -Not -BeNullOrEmpty
    }

    It 'creates a pipeline folder mirroring the area path, with the team ACL' {
        $fnd = $script:resolved.pipelineFolders | Where-Object path -eq '\Portal\Platform\Foundation'
        $fnd | Should -Not -BeNullOrEmpty
        ($fnd.acl | Where-Object group -eq 'PTL-FND-Contributors').permission | Should -Be 'Edit, Queue'
    }

    It 'does not create pipeline folders below the first-level team' {
        ($script:resolved.pipelineFolders.path) | Should -Not -Contain '\Portal\Platform\Foundation\Open API'
    }

    It 'exposes a members collection on each group (reconciliation target)' {
        $root = $script:resolved.teams | Where-Object name -eq 'Odyssey'
        ($root.securityGroups | Where-Object role -eq 'reader').Keys | Should -Contain 'members'
    }

    It 'names the program root group from the program key (no double dash)' {
        $root = $script:resolved.teams | Where-Object name -eq 'Odyssey'
        ($root.securityGroups.ado) | Should -Contain 'Odyssey-Readers'
    }

    It 'stamps team types: containers are portfolio, leaves are delivery' {
        ($script:resolved.teams | Where-Object name -eq 'Odyssey').type | Should -Be 'portfolio'
        ($script:resolved.teams | Where-Object name -eq 'Portal DS (portfolio)').type | Should -Be 'portfolio'
        ($script:resolved.teams | Where-Object short -eq 'GPI').type | Should -Be 'delivery'
    }

    It 'portfolio teams include sub-areas on their default area; delivery teams do not' {
        $ptl = $script:resolved.teams | Where-Object name -eq 'Portal (portfolio)'
        $ptl.includeSubAreas | Should -BeTrue
        $gpi = $script:resolved.teams | Where-Object short -eq 'GPI'
        $gpi.includeSubAreas | Should -BeFalse
        ($gpi.areaConfig | Where-Object path -eq $gpi.defaultAreaPath).includeSubAreas | Should -BeFalse
    }

    It 'honours per-node overrides: Foundation is delivery with no sprint subscriptions' {
        $fnd = $script:resolved.teams | Where-Object name -eq 'Portal · Foundation'
        $fnd.type | Should -Be 'delivery'
        $fnd.iterationScope | Should -Be 'none'
        $fnd.includeSubAreas | Should -BeFalse
    }

    It 'derives iteration scope from team type (portfolio seasons, delivery sprints)' {
        ($script:resolved.teams | Where-Object name -eq 'Portal DS (portfolio)').iterationScope | Should -Be 'seasons'
        ($script:resolved.teams | Where-Object short -eq 'GPI').iterationScope | Should -Be 'sprints'
        ($script:resolved.teams | Where-Object name -eq 'Portal · Foundation · Open API').iterationScope | Should -Be 'sprints'
    }

    It 'derives backlog levels from team type via cadence.yaml' {
        @(($script:resolved.teams | Where-Object short -eq 'GPI').backlogs) | Should -Be @('Requirements', 'Stories')
        @(($script:resolved.teams | Where-Object name -eq 'Odyssey').backlogs) | Should -Be @('Initiatives')
    }

    It 'generates iteration paths from cadence.yaml' {
        $script:resolved.iterations | Should -Not -BeNullOrEmpty
        $script:resolved.iterations.paths.Count | Should -BeGreaterThan 10
    }

    It 'generates S1-W1 of 2026 on the correct dates' {
        $s1w1 = $script:resolved.iterations.paths | Where-Object path -eq '\Odyssey\2026\S1\S1-W1'
        $s1w1 | Should -Not -BeNullOrEmpty
        $s1w1.startDate | Should -Be '2026-02-02T00:00:00Z'
        $s1w1.endDate   | Should -Be '2026-02-20T00:00:00Z'
    }

    It 'generates shortened final sprint S1-W6 of 2026 (2-week sprint)' {
        $s1w6 = $script:resolved.iterations.paths | Where-Object path -eq '\Odyssey\2026\S1\S1-W6'
        $s1w6 | Should -Not -BeNullOrEmpty
        $s1w6.startDate | Should -Be '2026-05-18T00:00:00Z'
        $s1w6.endDate   | Should -Be '2026-05-29T00:00:00Z'
    }

    It 'chains S2-W1 of 2026 starting the Monday after S1-W6 ends' {
        $s2w1 = $script:resolved.iterations.paths | Where-Object path -eq '\Odyssey\2026\S2\S2-W1'
        $s2w1 | Should -Not -BeNullOrEmpty
        $s2w1.startDate | Should -Be '2026-06-01T00:00:00Z'
    }
}

Describe 'Pipeline folder ACL resolution' {

    It 'maps read permission to correct bit mask' {
        InModuleScope AdoGovernance {
            ConvertTo-PipelinePermissionBit -Permission 'read' | Should -Be 1025
        }
    }

    It 'maps Edit, Queue permission to correct bit mask' {
        InModuleScope AdoGovernance {
            ConvertTo-PipelinePermissionBit -Permission 'Edit, Queue' | Should -Be 3201
        }
    }

    It 'throws on an unknown permission string' {
        { InModuleScope AdoGovernance { ConvertTo-PipelinePermissionBit -Permission 'unknown' } } |
            Should -Throw
    }

    It 'pipeline folder ACL contains reader group with read permission' {
        $fnd = $script:resolved.pipelineFolders | Where-Object path -eq '\Portal\Platform\Foundation'
        ($fnd.acl | Where-Object group -eq 'PTL-FND-Readers').permission | Should -Be 'read'
    }
}
