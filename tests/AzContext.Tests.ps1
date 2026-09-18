#Requires -Modules Pester

# The program's declared Azure CLI context (ADR-012). All offline: resolving a
# profile path, entering and restoring the environment variable, and validating
# the manifest block. Nothing here signs in or touches an organisation.

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.Governance/NKDAgility.AzureDevOps.Governance.psd1') -Force
}

Describe 'Get-GovernanceAzContext' {

    It 'resolves a bare profile name under ~/.azure-profiles, outside any repository' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $c = Get-GovernanceAzContext -Manifest @{ azure = @{ profile = 'contoso' } }
            $c.ProfileDir | Should -Be (Join-Path (Join-Path $HOME '.azure-profiles') 'contoso')
        }
    }

    It 'takes an absolute or ~-rooted path as given' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $abs = Join-Path ([System.IO.Path]::GetTempPath()) 'az-here'
            (Get-GovernanceAzContext -Manifest @{ azure = @{ profile = $abs } }).ProfileDir | Should -Be $abs
            (Get-GovernanceAzContext -Manifest @{ azure = @{ profile = '~/az-there' } }).ProfileDir |
                Should -Be (Join-Path $HOME 'az-there')
        }
    }

    It 'returns nothing for a program that declares no azure block' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            Get-GovernanceAzContext -Manifest @{ org = 'x' } | Should -BeNullOrEmpty
        }
    }

    It 'carries tenant, subscription and signInAs through' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $c = Get-GovernanceAzContext -Manifest @{ azure = @{
                tenant = '11111111-2222-3333-4444-555555555555'; subscription = '66666666-7777-8888-9999-aaaaaaaaaaaa'; signInAs = 'a@b.com' } }
            $c.Tenant       | Should -Be '11111111-2222-3333-4444-555555555555'
            $c.Subscription | Should -Be '66666666-7777-8888-9999-aaaaaaaaaaaa'
            $c.SignInAs     | Should -Be 'a@b.com'
        }
    }
}

Describe 'Enter/Exit-GovernanceAzContext' {

    It 'points AZURE_CONFIG_DIR at the declared profile and restores it afterwards' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "az-ctx-$([guid]::NewGuid())"
            $before = $env:AZURE_CONFIG_DIR
            try {
                $s = Enter-GovernanceAzContext -Manifest @{ azure = @{ profile = $dir } } -Quiet
                $env:AZURE_CONFIG_DIR | Should -Be $dir
                Test-Path $dir | Should -BeTrue      # created, so az has somewhere to write
                Exit-GovernanceAzContext -State $s
                $env:AZURE_CONFIG_DIR | Should -Be $before
            } finally {
                if ($null -ne $before) { $env:AZURE_CONFIG_DIR = $before } else { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'leaves the environment untouched when no profile is declared' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $before = $env:AZURE_CONFIG_DIR
            $s = Enter-GovernanceAzContext -Manifest @{ org = 'x' } -Quiet
            $s.Changed | Should -BeFalse
            $env:AZURE_CONFIG_DIR | Should -Be $before
            Exit-GovernanceAzContext -State $s      # a no-op, and must not throw
            $env:AZURE_CONFIG_DIR | Should -Be $before
        }
    }
}

Describe 'Test-GovernanceAzManifest' {

    It 'accepts a complete block and a program with none at all' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            Test-GovernanceAzManifest -Manifest @{ azure = @{
                profile = 'contoso'; tenant = '11111111-2222-3333-4444-555555555555'
                subscription = '66666666-7777-8888-9999-aaaaaaaaaaaa'; signInAs = 'me@customer.com' } } |
                Should -BeNullOrEmpty
            Test-GovernanceAzManifest -Manifest @{ org = 'x' } | Should -BeNullOrEmpty
        }
    }

    It 'rejects an unknown key, a non-GUID tenant and a signInAs that is not a UPN' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            $i = @(Test-GovernanceAzManifest -Manifest @{ azure = @{
                subscriptionId = 'x'; tenant = 'not-a-guid'; signInAs = 'nobody' } })
            @($i | Where-Object { $_ -like "*'subscriptionId' is not an azure field*" }).Count | Should -Be 1
            @($i | Where-Object { $_ -like '*tenant must be a GUID*' }).Count                  | Should -Be 1
            @($i | Where-Object { $_ -like '*signInAs must be a UPN*' }).Count                 | Should -Be 1
        }
    }

    It 'rejects an azure block that is not a map' {
        InModuleScope NKDAgility.AzureDevOps.Governance {
            @(Test-GovernanceAzManifest -Manifest @{ azure = 'contoso' }) |
                Should -Match 'must be a map'
        }
    }
}

Describe 'Test-GovernanceAzContextPlacement' {

    BeforeAll {
        # A throwaway workspace shaped like a customer repo: a marker at the
        # root, a .claude folder, a program folder underneath.
        $script:ws = Join-Path ([System.IO.Path]::GetTempPath()) "ws-$([guid]::NewGuid())"
        $script:prog = Join-Path $ws 'governance\programs\demo'
        New-Item -ItemType Directory -Path $prog -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $ws '.claude') -Force | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $ws 'workspace.json')
    }
    AfterAll { Remove-Item $script:ws -Recurse -Force -ErrorAction SilentlyContinue }

    It 'offers a pasteable block, filled with what was discovered, when nothing is declared' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog } {
            $a = @(Test-GovernanceAzContextPlacement -Manifest @{ program = 'Demo' } -ProgramPath $prog `
                    -Tenant '11111111-2222-3333-4444-555555555555' -SignInAs 'me@customer.com')
            $info = @($a | Where-Object Level -eq 'info')
            $info.Count               | Should -Be 1
            $info[0].Message          | Should -Match 'No azure: block in'
            $info[0].Message          | Should -Match 'profile:      demo'
            $info[0].Message          | Should -Match '11111111-2222-3333-4444-555555555555'
            $info[0].Message          | Should -Match 'signInAs:     me@customer.com'
        }
    }

    It 'warns when AZURE_CONFIG_DIR is set outside governance and nothing is declared' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog } {
            $before = $env:AZURE_CONFIG_DIR
            try {
                $env:AZURE_CONFIG_DIR = 'C:\somewhere\else'
                @(Test-GovernanceAzContextPlacement -Manifest @{ program = 'Demo' } -ProgramPath $prog |
                    Where-Object Level -eq 'warn').Message | Should -Match 'outside governance'
            } finally {
                if ($null -ne $before) { $env:AZURE_CONFIG_DIR = $before } else { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'warns when .claude settings set a competing AZURE_CONFIG_DIR' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog; ws = $script:ws } {
            $settings = Join-Path $ws '.claude\settings.local.json'
            try {
                '{ "env": { "AZURE_CONFIG_DIR": "C:\\Users\\x\\.azure-profiles\\other" } }' | Set-Content -LiteralPath $settings
                $w = @(Test-GovernanceAzContextPlacement -Manifest @{ azure = @{ profile = 'demo' } } -ProgramPath $prog |
                        Where-Object Level -eq 'warn')
                $w.Count          | Should -Be 1
                $w[0].Message     | Should -Match 'settings.local.json also sets AZURE_CONFIG_DIR'
                $w[0].Message     | Should -Match 'the manifest wins'
            } finally { Remove-Item $settings -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'is silent about competing settings when they agree with the manifest' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog; ws = $script:ws } {
            $settings = Join-Path $ws '.claude\settings.local.json'
            $dir = (Get-GovernanceAzContext -Manifest @{ azure = @{ profile = 'demo' } }).ProfileDir
            try {
                (@{ env = @{ AZURE_CONFIG_DIR = $dir } } | ConvertTo-Json) | Set-Content -LiteralPath $settings
                @(Test-GovernanceAzContextPlacement -Manifest @{ azure = @{ profile = 'demo' } } -ProgramPath $prog |
                    Where-Object Level -eq 'warn') | Should -BeNullOrEmpty
            } finally { Remove-Item $settings -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'errors when the profile directory would sit inside a repository' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog; ws = $script:ws } {
            $inside = Join-Path $ws '.azure-profiles\demo'
            $e = @(Test-GovernanceAzContextPlacement -Manifest @{ azure = @{ profile = $inside } } -ProgramPath $prog |
                    Where-Object Level -eq 'error')
            $e.Count      | Should -Be 1
            $e[0].Message | Should -Match 'holds refresh tokens'
        }
    }

    It 'says a declared profile holds no sign-in yet' {
        InModuleScope NKDAgility.AzureDevOps.Governance -Parameters @{ prog = $script:prog } {
            @(Test-GovernanceAzContextPlacement -Manifest @{ azure = @{ profile = "never-signed-in-$([guid]::NewGuid())" } } -ProgramPath $prog |
                Where-Object Level -eq 'info').Message | Should -Match "Run 'connect'"
        }
    }
}
