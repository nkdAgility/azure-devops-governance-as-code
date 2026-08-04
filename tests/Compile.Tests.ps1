#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'module/AdoGovernance/AdoGovernance.psd1') -Force

    # Frozen snapshot of a real program, used purely as compile-pipeline test
    # data. Live client programs no longer live in this repo (they sit in the
    # client's own repo and are pointed at build.ps1 via -ProgramsRoot).
    $programPath = Join-Path $PSScriptRoot 'fixtures/programs/odyssey'
    $outputPath  = Join-Path $repoRoot 'out/test-fixture-odyssey/resolved.yaml'
    $script:outputPath = Invoke-GovernanceBuild -ProgramPath $programPath -OutputPath $outputPath
    $script:resolved = ConvertFrom-Yaml (Get-Content $script:outputPath -Raw)
}

Describe 'Compile stage' {

    It 'writes the resolved file' {
        $script:outputPath | Should -Exist
    }

    It 'resolves the project declaration from the manifest' {
        $script:resolved.project | Should -Not -BeNullOrEmpty
        $script:resolved.project.name          | Should -Be 'Odyssey'
        $script:resolved.project.process       | Should -Be 'nkdScrum'
        $script:resolved.project.visibility    | Should -Be 'private'
        $script:resolved.project.sourceControl | Should -Be 'git'
    }

    It 'defaults the project declaration when the manifest has no project block' {
        InModuleScope AdoGovernance {
            $resolved = Resolve-Governance -Manifest @{ program = 'Demo'; org = 'demo-org' } `
                -Source @{ products = @() } `
                -Access @{ teamGroups = @(); containerGroups = @(); roles = @{};
                           stakeholders = @{ accessLevel = 'stakeholder'; ado = 'Demo-Stakeholders'; scope = 'org' } } `
                -SourceHash 'testhash'
            $resolved.project.name          | Should -Be 'Demo'
            $resolved.project.process       | Should -Be 'Agile'
            $resolved.project.visibility    | Should -Be 'private'
            $resolved.project.sourceControl | Should -Be 'git'
        }
    }

    It 'rejects an invalid project visibility' {
        InModuleScope AdoGovernance {
            $issues = Test-ResolvedGovernance -Resolved @{
                project = @{ visibility = 'internal'; sourceControl = 'git' }; areaPaths = @(); teams = @() }
            $issues | Should -Contain "Project visibility must be 'private' or 'public', got 'internal'"
        }
    }

    It 'rejects an invalid project sourceControl' {
        InModuleScope AdoGovernance {
            $issues = Test-ResolvedGovernance -Resolved @{
                project = @{ visibility = 'private'; sourceControl = 'svn' }; areaPaths = @(); teams = @() }
            $issues | Should -Contain "Project sourceControl must be 'git' or 'tfvc', got 'svn'"
        }
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

    It 'does not create an Open API team (Open API is a tag, not a team)' {
        ($script:resolved.teams | Where-Object name -like '*Open API*') | Should -BeNullOrEmpty
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

    It 'declares repos on nodes and resolves them' {
        ($script:resolved.repos | Where-Object name -eq 'PTL-PLGA-plugin-a') | Should -Not -BeNullOrEmpty
    }

    It 'prefixes repo names with the node hierarchy code, spaces to dashes' {
        ($script:resolved.repos | Where-Object name -eq 'PTL-PLGA-Test-Kit') | Should -Not -BeNullOrEmpty
    }

    It 'sideloads a multi-consumer area into every listed team' {
        $gpi = $script:resolved.teams | Where-Object short -eq 'GPI'
        $fnd = $script:resolved.teams | Where-Object short -eq 'FND'
        $gpi.areaConfig.path | Should -Contain '\Odyssey\Portal\Plugins\Plugin B'
        $fnd.areaConfig.path | Should -Contain '\Odyssey\Portal\Plugins\Plugin B'
    }

    It 'supports a node that is both a team and sideloaded elsewhere' {
        ($script:resolved.teams | Where-Object short -eq 'STM') | Should -Not -BeNullOrEmpty
        $gpi = $script:resolved.teams | Where-Object short -eq 'GPI'
        $gpi.areaConfig.path | Should -Contain '\Odyssey\Portal\Platform\Stream Modeling'
    }

    It 'creates a governed team-less area for team: none nodes' {
        $sandbox = $script:resolved.areaPaths | Where-Object path -eq '\Odyssey\Portal\Plugins\Sandbox'
        $sandbox | Should -Not -BeNullOrEmpty
        $sandbox.kind | Should -Be 'area'
        ($script:resolved.teams | Where-Object name -like '*Sandbox*') | Should -BeNullOrEmpty
    }

    It 'stamps repo ownership and ACLs: everyone reads, the owning team writes' {
        $repo = $script:resolved.repos | Where-Object name -eq 'PTL-PLGA-plugin-a'
        $repo.owner | Should -Be 'PTL-FND'
        ($repo.acl | Where-Object permission -eq 'read').principal  | Should -Be 'project-valid-users'
        ($repo.acl | Where-Object permission -eq 'write').principal | Should -Be 'PTL-FND-Contributors'
    }

    It 'innerOSS repos additionally open branch/PR contribution to everyone' {
        $repo = $script:resolved.repos | Where-Object name -eq 'PTL-PLGB-plugin-b'
        $repo.owner | Should -Be 'PTL-GPI'   # first sideloader owns the repos
        ($repo.acl | Where-Object permission -eq 'innersource').principal | Should -Be 'project-valid-users'
        ($repo.acl | Where-Object permission -eq 'write').principal | Should -Be 'PTL-GPI-Contributors'
    }

    It 'rejects the legacy string section grammar with a clear error' {
        InModuleScope AdoGovernance {
            { Resolve-Governance -Manifest @{ program = 'Demo'; org = 'demo' } `
                -Source @{ products = @(@{ name = 'P'; short = 'P'; dpm = 1; sections = @('platform'); platform = @() }) } `
                -Access @{ teamGroups = @(); containerGroups = @(); roles = @{};
                           stakeholders = @{ accessLevel = 'stakeholder'; ado = 'D-S'; scope = 'org' } } `
                -SourceHash 'x' } | Should -Throw '*legacy section keyword*'
        }
    }

    It 'creates a pipeline folder mirroring the area path, with the team ACL' {
        $fnd = $script:resolved.pipelineFolders | Where-Object path -eq '\Portal\Platform\Foundation'
        $fnd | Should -Not -BeNullOrEmpty
        ($fnd.acl | Where-Object group -eq 'PTL-FND-Contributors').permission | Should -Be 'Edit, Queue'
    }

    It 'does not create pipeline folders below the first-level team' {
        ($script:resolved.pipelineFolders.path) | Should -Not -Contain '\Portal\Platform\Foundation\Open API'
    }

    It 'omits the pipeline folder for a team without pipelineFolder: true (default off)' {
        ($script:resolved.pipelineFolders.path) | Should -Not -Contain '\Portal\Platform\Geometry Library'
        # but the team itself still exists with its area config
        ($script:resolved.teams | Where-Object short -eq 'GLI') | Should -Not -BeNullOrEmpty
    }

    It 'omits the pipeline folder for a product without pipelineFolder: true' {
        ($script:resolved.pipelineFolders.path) | Should -Not -Contain '\Vista'
        ($script:resolved.teams | Where-Object name -eq 'Vista (portfolio)') | Should -Not -BeNullOrEmpty
    }

    It 'creates pipeline folders for nodes declaring pipelineFolder: true' {
        ($script:resolved.pipelineFolders.path) | Should -Contain '\Portal\Platform\Stream Modeling'
        ($script:resolved.pipelineFolders.path) | Should -Contain '\Studio'
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
    }

    It 'derives backlog levels from team type via cadence.yaml' {
        @(($script:resolved.teams | Where-Object short -eq 'GPI').backlogs) | Should -Be @('Features', 'Backlog items')
        @(($script:resolved.teams | Where-Object name -eq 'Odyssey').backlogs) | Should -Be @('God Mode')
    }

    It 'emits an admin group on every team (structural authority role)' {
        ($script:resolved.teams | Where-Object short -eq 'GPI').securityGroups.ado | Should -Contain 'PTL-GPI-Admins'
        ($script:resolved.teams | Where-Object name -eq 'Portal (portfolio)').securityGroups.ado | Should -Contain 'PTL-Admins'
    }

    It 'grants the program owner structural authority on Portal and each adjacent product' {
        foreach ($code in @('PTL', 'PDS', 'MLP', 'OFP', 'STD', 'VIS')) {
            $team  = $script:resolved.teams | Where-Object codePath -eq $code
            $admin = $team.securityGroups | Where-Object role -eq 'admin'
            @($admin.members).Count | Should -Be 1 -Because "$code should have exactly one admin"
            $admin.members[0].upn | Should -BeLike 'alex*'
            $admin.members[0].reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'grants the Foundation owner structural authority with a recorded reason' {
        $fnd   = $script:resolved.teams | Where-Object codePath -eq 'PTL-FND'
        $admin = $fnd.securityGroups | Where-Object role -eq 'admin'
        $admin.members[0].upn | Should -BeLike 'jordan*'
        $admin.members[0].reason | Should -Match 'structural authority'
    }

    It 'projects structural authority entries covering the governed area paths' {
        $ptl = $script:resolved.structuralAuthority | Where-Object group -eq 'PTL-Admins'
        $ptl | Should -Not -BeNullOrEmpty
        $ptl.paths | Should -Contain '\Odyssey\Portal'
        $gpi = $script:resolved.structuralAuthority | Where-Object group -eq 'PTL-GPI-Admins'
        $gpi.paths | Should -Contain '\Odyssey\Colors'
    }

    It 'excludes expired member entries from the desired state' {
        InModuleScope AdoGovernance {
            $resolved = Resolve-Governance -Manifest @{ program = 'Demo'; org = 'demo-org' } `
                -Source @{ products = @() } `
                -Access @{ teamGroups = @(); roles = @{};
                           containerGroups = @(@{ role = 'reader'; ado = '{key}-Readers' });
                           stakeholders = @{ accessLevel = 'stakeholder'; ado = 'Demo-Stakeholders'; scope = 'org' } } `
                -SourceHash 'testhash' `
                -Members @{ Demo = @{ reader = @(
                    @{ upn = 'expired@corp.com'; reason = 'guest'; expires = '2000-01-01' },
                    @{ upn = 'active@corp.com';  reason = 'ongoing' }
                ) } }
            $readers = ($resolved.teams | Where-Object name -eq 'Demo').securityGroups |
                Where-Object role -eq 'reader'
            @($readers.members).Count | Should -Be 1
            $readers.members[0].upn | Should -Be 'active@corp.com'
        }
    }

    It 'fails the build when an active team has no members file (governance active)' {
        InModuleScope AdoGovernance {
            {
                Resolve-Governance -Manifest @{ program = 'Demo'; org = 'demo-org' } `
                    -Source @{ products = @(@{ name = 'Prod'; short = 'PRD' }) } `
                    -Access @{ teamGroups = @(); roles = @{};
                               containerGroups = @(@{ role = 'reader'; ado = '{key}-Readers' });
                               stakeholders = @{ accessLevel = 'stakeholder'; ado = 'S'; scope = 'org' } } `
                    -SourceHash 'testhash' `
                    -Members @{ Demo = @{ reader = @() } }
            } | Should -Throw '*members file missing*'
        }
    }

    It 'resolves the governed tag taxonomy from hierarchy.yaml' {
        $script:resolved.tags | Should -Not -BeNullOrEmpty
        $script:resolved.tags.sanctioned | Should -Contain 'Open API'
        @($script:resolved.tags.disallowedPatterns).Count | Should -BeGreaterThan 0
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

    It 'maps repo permissions to Git-namespace bits' {
        InModuleScope AdoGovernance {
            ConvertTo-RepoPermissionBit -Permission 'read'        | Should -Be 2
            ConvertTo-RepoPermissionBit -Permission 'write'       | Should -Be 16438
            ConvertTo-RepoPermissionBit -Permission 'innersource' | Should -Be 16402
        }
    }

    It 'throws on an unknown repo permission' {
        { InModuleScope AdoGovernance { ConvertTo-RepoPermissionBit -Permission 'admin' } } |
            Should -Throw
    }

    It 'pipeline folder ACL contains reader group with read permission' {
        $fnd = $script:resolved.pipelineFolders | Where-Object path -eq '\Portal\Platform\Foundation'
        ($fnd.acl | Where-Object group -eq 'PTL-FND-Readers').permission | Should -Be 'read'
    }
}

Describe 'ADO REST host routing' {

    It 'routes graph paths to the SPS host on dev.azure.com orgs' {
        InModuleScope AdoGovernance {
            Resolve-AdoRequestUri -OrgUrl 'https://dev.azure.com/acme' -Path '_apis/graph/groups' |
                Should -Be 'https://vssps.dev.azure.com/acme/_apis/graph/groups'
        }
    }

    It 'routes graph paths to the SPS host on legacy visualstudio.com orgs' {
        InModuleScope AdoGovernance {
            Resolve-AdoRequestUri -OrgUrl 'https://acme.visualstudio.com' -Path '_apis/graph/memberships/x/y' |
                Should -Be 'https://acme.vssps.visualstudio.com/_apis/graph/memberships/x/y'
        }
    }

    It 'routes user entitlement paths to the vsaex host' {
        InModuleScope AdoGovernance {
            Resolve-AdoRequestUri -OrgUrl 'https://dev.azure.com/acme' -Path '_apis/userentitlements?top=1' |
                Should -Be 'https://vsaex.dev.azure.com/acme/_apis/userentitlements?top=1'
        }
    }

    It 'leaves core-host paths untouched' {
        InModuleScope AdoGovernance {
            Resolve-AdoRequestUri -OrgUrl 'https://dev.azure.com/acme' -Path 'Proj/_apis/git/repositories' |
                Should -Be 'https://dev.azure.com/acme/Proj/_apis/git/repositories'
        }
    }

    It 'does not reroute project-scoped paths that merely contain graph' {
        InModuleScope AdoGovernance {
            Resolve-AdoRequestUri -OrgUrl 'https://dev.azure.com/acme' -Path 'Proj/_apis/graphite' |
                Should -Be 'https://dev.azure.com/acme/Proj/_apis/graphite'
        }
    }
}

Describe 'Auth mode resolution (Entra-first)' {

    It 'defaults to entra when an az session exists' {
        InModuleScope AdoGovernance {
            Resolve-AdoAuthMode -DeclaredMode $null -HasEntraSession $true -HasPatToken $true | Should -Be 'entra'
            Resolve-AdoAuthMode -DeclaredMode ''    -HasEntraSession $true -HasPatToken $false | Should -Be 'entra'
        }
    }

    It 'falls back to a configured PAT when no az session exists' {
        InModuleScope AdoGovernance {
            Resolve-AdoAuthMode -DeclaredMode $null -HasEntraSession $false -HasPatToken $true | Should -Be 'pat-fallback'
        }
    }

    It 'honours an explicit auth: pat declaration' {
        InModuleScope AdoGovernance {
            Resolve-AdoAuthMode -DeclaredMode 'pat' -HasEntraSession $true -HasPatToken $true | Should -Be 'pat'
        }
    }

    It 'throws when auth: pat is declared without a resolvable token' {
        InModuleScope AdoGovernance {
            { Resolve-AdoAuthMode -DeclaredMode 'pat' -HasEntraSession $true -HasPatToken $false } |
                Should -Throw '*accessToken did not resolve*'
        }
    }

    It 'throws when no credential of any kind is available' {
        InModuleScope AdoGovernance {
            { Resolve-AdoAuthMode -DeclaredMode $null -HasEntraSession $false -HasPatToken $false } |
                Should -Throw '*az login*'
        }
    }

    It 'rejects unknown auth modes' {
        InModuleScope AdoGovernance {
            { Resolve-AdoAuthMode -DeclaredMode 'oauth' -HasEntraSession $true -HasPatToken $true } |
                Should -Throw "*must be 'entra' or 'pat'*"
        }
    }
}

Describe 'PAT scope probe verdicts' {

    It 'treats success statuses as ok' {
        InModuleScope AdoGovernance {
            Resolve-AdoProbeVerdict -StatusCode 200 -ContentType 'application/json' | Should -Be 'ok'
            Resolve-AdoProbeVerdict -StatusCode 204 | Should -Be 'ok'
        }
    }

    It 'treats request-validation failures as ok (scope check happens first)' {
        InModuleScope AdoGovernance {
            Resolve-AdoProbeVerdict -StatusCode 400 | Should -Be 'ok'
            Resolve-AdoProbeVerdict -StatusCode 404 | Should -Be 'ok'
            Resolve-AdoProbeVerdict -StatusCode 405 | Should -Be 'ok'
        }
    }

    It 'treats auth failures as missing' {
        InModuleScope AdoGovernance {
            Resolve-AdoProbeVerdict -StatusCode 401 | Should -Be 'missing'
            Resolve-AdoProbeVerdict -StatusCode 403 | Should -Be 'missing'
            Resolve-AdoProbeVerdict -StatusCode 203 | Should -Be 'missing'
            Resolve-AdoProbeVerdict -StatusCode 302 | Should -Be 'missing'
        }
    }

    It 'treats an HTML body on success status as missing (sign-in page)' {
        InModuleScope AdoGovernance {
            Resolve-AdoProbeVerdict -StatusCode 200 -ContentType 'text/html; charset=utf-8' | Should -Be 'missing'
        }
    }

    It 'treats server errors as unknown' {
        InModuleScope AdoGovernance {
            Resolve-AdoProbeVerdict -StatusCode 500 | Should -Be 'unknown'
        }
    }

    It 'diagnoses ACL 401s as the non-selectable security scope' {
        InModuleScope AdoGovernance {
            Resolve-GovernanceErrorReason -Finding "ERROR setting ACL on '\X' for identity 'Y': Response status code does not indicate success: 401 (Unauthorized)." |
                Should -Match 'security ACLs'
            Resolve-GovernanceErrorReason -Finding "ERROR granting structural authority to 'X' on '\Y': 401 (Unauthorized)." |
                Should -Match 'security ACLs'
        }
    }

    It 'diagnoses generic 401s as a missing PAT scope' {
        InModuleScope AdoGovernance {
            Resolve-GovernanceErrorReason -Finding "ERROR creating repo 'x': The requested resource requires user authentication" |
                Should -Match "doctor"
        }
    }

    It 'diagnoses unresolvable members, with and without a near-match' {
        InModuleScope AdoGovernance {
            Resolve-GovernanceErrorReason -Finding "UNRESOLVABLE member 'a.b@c.com' in 'G': no org member has this exact UPN - did you mean: AB@c.com (A B)?" |
                Should -Match 'fix the UPN'
            Resolve-GovernanceErrorReason -Finding "UNRESOLVABLE member 'a.b@c.com' in 'G': no org member matches this UPN" |
                Should -Match 'added to the Azure DevOps org'
        }
    }

    It 'diagnoses backlog level name mismatches as a cadence.yaml problem' {
        InModuleScope AdoGovernance {
            Resolve-GovernanceErrorReason -Finding "DRIFT team 'T': configured backlog level 'God Mode' does not exist in the process (levels: A, B)" |
                Should -Match 'cadence.yaml'
            Resolve-GovernanceErrorReason -Finding "ERROR setting backlog levels for 'T': VS402489: You cannot hide all backlog levels." |
                Should -Match 'cadence.yaml'
        }
    }

    It 'returns null for undiagnosed signatures' {
        InModuleScope AdoGovernance {
            Resolve-GovernanceErrorReason -Finding 'ERROR something entirely novel' | Should -BeNullOrEmpty
        }
    }

    It 'covers every scope family the engine calls' {
        InModuleScope AdoGovernance {
            $probes = Get-AdoScopeProbeSet -Project 'Demo'
            $probes.Scope | Should -Contain 'vso.project_manage'
            $probes.Scope | Should -Contain 'vso.work_write'
            $probes.Scope | Should -Contain 'vso.code_manage'
            $probes.Scope | Should -Contain 'vso.build_execute'
            $probes.Scope | Should -Contain 'vso.graph_manage'
            # every write probe must be a no-op: empty body (rejected after the
            # scope check) or an empty accessControlEntries list (accepted but
            # writes nothing)
            foreach ($p in $probes | Where-Object Method -ne 'GET') {
                if ($p.ContainsKey('Body')) {
                    $noOp = ($p.Body.Count -eq 0) -or
                            ($p.Body.ContainsKey('accessControlEntries') -and @($p.Body.accessControlEntries).Count -eq 0)
                    $noOp | Should -BeTrue -Because "probe '$($p.Family)' must not mutate anything"
                }
            }
        }
    }
}
