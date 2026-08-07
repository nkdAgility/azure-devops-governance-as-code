#Requires -Modules Pester

# Hygiene checks over the module itself. The module is COPIED out of this repo into a
# client workspace's .system\ folder, so anything it reaches for above its own root does
# not exist at runtime. These guard that contract, and the manifest against drift.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\system\NKDAgility.AzureDevOps.Governance'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'NKDAgility.AzureDevOps.Governance.psd1'
    $script:Manifest = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
    $script:PublicNames = @(Get-ChildItem (Join-Path $script:ModuleRoot 'Public') -Filter *.ps1 -Recurse).BaseName
}

Describe 'Module manifest' {

    It 'names a RootModule that exists' {
        Join-Path $script:ModuleRoot $script:Manifest.RootModule | Should -Exist
    }

    It 'exports every function file under Public' {
        $missing = @($script:PublicNames | Where-Object { $_ -notin $script:Manifest.FunctionsToExport })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a new Public function must be added to FunctionsToExport'
    }

    It 'exports nothing that has no file under Public' {
        $orphans = @($script:Manifest.FunctionsToExport | Where-Object { $_ -notin $script:PublicNames })
        $orphans -join ', ' | Should -BeNullOrEmpty -Because 'FunctionsToExport must not name a function that was renamed or removed'
    }
}

Describe 'Module is self-contained' {

    It 'has no upward path arithmetic' {
        $offenders = @(Get-ChildItem $script:ModuleRoot -Filter *.ps1 -Recurse -File |
                Where-Object { $_.FullName -notmatch '\\Templates\\' } |
                Select-String -Pattern 'Split-Path\s+-Parent\s+\(Split-Path', 'Join-Path\s+\$[\w:]*(ModuleRoot|ModuleBase|PSScriptRoot)\s+\S*\.\.' |
                ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'the module must resolve its own files from $script:ModuleRoot, never by walking up out of it'
    }

    It 'ships the capability template it scaffolds into a workspace' {
        Join-Path $script:ModuleRoot 'Templates\customer-repo\governance\init.ps1' | Should -Exist
        Join-Path $script:ModuleRoot 'Agents\CAPABILITY.md' | Should -Exist
    }

    It 'imports when copied out of the repo' {
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("adogov-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $moduleCopy = Join-Path $sandbox 'NKDAgility.AzureDevOps.Governance'
        $sandboxModule = $null
        try {
            New-Item -Path $sandbox -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $script:ModuleRoot -Destination $moduleCopy -Recurse
            $sandboxModule = Import-Module (Join-Path $moduleCopy 'NKDAgility.AzureDevOps.Governance.psd1') -Force -PassThru
            foreach ($name in $script:Manifest.FunctionsToExport) {
                $sandboxModule.ExportedFunctions.Keys | Should -Contain $name
            }
        }
        finally {
            # The copy shares this module's name; leaving it loaded makes Get-Module
            # return two and breaks anything that resolves the module by name.
            if ($sandboxModule) { Remove-Module -ModuleInfo $sandboxModule -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
