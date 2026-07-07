@{
    RootModule        = 'AdoGovernance.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3f5c2a1-9d84-4e77-9c1a-0f2e6a7b4d10'
    Author            = 'naked Agility (Martin Hinshelwood & Co.)'
    Description       = 'Governance-as-code for an Azure DevOps project: compile a human-readable hierarchy into teams, area paths, repos, pipelines, and permissions.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('powershell-yaml')
    FunctionsToExport = @(
        'Invoke-GovernanceBuild',
        'Test-Governance',
        'Invoke-GovernancePlan',
        'Invoke-GovernanceApply',
        'Invoke-GovernanceAudit'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
