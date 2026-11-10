#Requires -Modules Pester

# The customer workspace's root init.ps1 hands over to the automation tools'
# Invoke-AutomationWorkspaceInit, which dot-sources each capability's
# governance\init.ps1 from INSIDE a module function, then removes that
# bootstrap copy of the automation module. Anything the template creates in
# the bootstrap module's scope goes with it. This reproduces that sequence.

BeforeAll {
    $repoRoot  = Split-Path -Parent $PSScriptRoot
    $template  = Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.Governance/Templates/customer-repo/governance/init.ps1'
    $moduleSrc = Join-Path $repoRoot 'system/NKDAgility.AzureDevOps.Governance'

    $script:workspace = Join-Path ([IO.Path]::GetTempPath()) ("gov-init-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $script:workspace 'governance\programs') -Force | Out-Null
    Copy-Item -LiteralPath $template -Destination (Join-Path $script:workspace 'governance\init.ps1')
    New-Item -ItemType Directory -Path (Join-Path $script:workspace '.system') -Force | Out-Null
    Copy-Item -LiteralPath $moduleSrc -Destination (Join-Path $script:workspace '.system') -Recurse

    Remove-Item Function:\Invoke-Governance -ErrorAction SilentlyContinue
    Get-Module NKDAgility.AzureDevOps.Governance | Remove-Module -Force -ErrorAction SilentlyContinue
}

AfterAll {
    Remove-Item Function:\Invoke-Governance -ErrorAction SilentlyContinue
    Get-Module NKDAgility.AzureDevOps.Governance | Remove-Module -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'governance init template, loaded the way the workspace init loads it' {

    It 'leaves Invoke-Governance and the module commands in the caller after the bootstrap module is removed' {
        $initPath = Join-Path $script:workspace 'governance\init.ps1'
        $boot = New-Module -Name 'FakeAutomationBootstrap' -ScriptBlock {
            function Invoke-CapabilityLoad([string]$Path, [string]$Root) { . $Path -WorkspaceRoot $Root }
            Export-ModuleMember -Function Invoke-CapabilityLoad
        } | Import-Module -PassThru

        & $boot { param($p, $r) Invoke-CapabilityLoad -Path $p -Root $r } $initPath $script:workspace 6>$null
        Remove-Module -ModuleInfo $boot -Force

        Get-Command Invoke-Governance -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-Governance   -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-GovernanceBuild -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
