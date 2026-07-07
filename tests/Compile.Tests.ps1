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
        ($script:resolved.teams | Where-Object name -eq 'Foundation') | Should -Not -BeNullOrEmpty
    }

    It 'nests sub-teams (Open API under Foundation)' {
        $openApi = $script:resolved.teams | Where-Object name -eq 'Open API'
        $openApi.parent | Should -Be 'Foundation'
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
}
