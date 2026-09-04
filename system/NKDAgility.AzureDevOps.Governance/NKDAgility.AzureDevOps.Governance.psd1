@{
    RootModule        = 'NKDAgility.AzureDevOps.Governance.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3f5c2a1-9d84-4e77-9c1a-0f2e6a7b4d10'
    Author            = 'naked Agility (Martin Hinshelwood & Co.)'
    CompanyName       = 'naked Agility Ltd'
    Copyright         = '(c) 2026 naked Agility Ltd. Licensed under the GNU AGPL v3.'
    Description       = 'Governance-as-code for an Azure DevOps project: compile a human-readable hierarchy into teams, area paths, repos, pipelines, and permissions.'
    PowerShellVersion = '7.4'
    RequiredModules   = @('powershell-yaml')
    FunctionsToExport = @(
        'Invoke-GovernanceBuild',
        'Test-Governance',
        'Invoke-GovernancePlan',
        'Invoke-GovernanceApply',
        'Invoke-GovernanceAudit',
        'Invoke-GovernancePreflight',
        'Invoke-GovernancePreflightReport',
        'ConvertTo-GovernancePreflightReport',
        'Test-GovernanceAccess'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('AzureDevOps', 'Governance', 'Compliance', 'InfrastructureAsCode',
                'GovernanceAsCode', 'ADO', 'DevOps', 'Windows', 'Linux', 'MacOS')
            LicenseUri   = 'https://github.com/nkdAgility/azure-devops-governance-as-code/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/nkdAgility/azure-devops-governance-as-code'
            ReleaseNotes = 'https://github.com/nkdAgility/azure-devops-governance-as-code/releases'
        }
    }
}
