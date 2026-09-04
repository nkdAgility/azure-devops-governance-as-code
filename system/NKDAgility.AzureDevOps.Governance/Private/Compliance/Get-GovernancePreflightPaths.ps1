function Get-GovernancePreflightPaths {
    <#
        .SYNOPSIS
        The one place that knows where a node's preflight artefacts live, so
        the gather, the renderer and the shipped workflow can never disagree.

        Everything sits under a `preflight\` folder beside resolved.yaml, one
        sub-folder per node, because a program with eighteen teams would
        otherwise scatter ninety files across the output root:

            <output>\resolved.yaml
            <output>\preflight\
                <program>-preflight-summary.md          the run, for the operator
                <CODE>\
                    <program>-preflight-<CODE>-data.json          facts from both orgs
                    <program>-preflight-<CODE>-findings.txt       findings, human form
                    <program>-preflight-<CODE>-findings.json      the same, as objects
                    <program>-preflight-<CODE>-observations.md    the prose fragment
                    <program>-preflight-<CODE>-report.md          the rendered fix report

        Every file repeats the program and the code even though the folder
        already carries both: these are lifted out and filed in engagement
        systems, where a name like `report.md` says nothing about what it is.

        findings.txt and findings.json share a base name on purpose —
        Write-GovernanceReport derives the JSON twin from the text path.

        Program defaults to the output folder's own name, which is what
        Invoke-Governance builds from the program folder; pass it explicitly
        from anywhere that knows it for certain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedPath,
        [string]$Code = '',
        [string]$Program = ''
    )

    $outDir = [System.IO.Path]::GetDirectoryName($ResolvedPath)
    if (-not $Program) { $Program = Split-Path -Leaf $outDir }
    $root = Join-Path $outDir 'preflight'
    $stem = "$Program-preflight"

    $paths = [ordered]@{
        Root    = $root
        Program = $Program
        Summary = Join-Path $root "$stem-summary.md"
    }
    if ($Code) {
        $dir  = Join-Path $root $Code
        $base = "$stem-$Code"
        $paths['Dir']          = $dir
        $paths['Base']         = $base
        $paths['Data']         = Join-Path $dir "$base-data.json"
        $paths['Findings']     = Join-Path $dir "$base-findings.txt"
        $paths['FindingsJson'] = Join-Path $dir "$base-findings.json"
        $paths['Observations'] = Join-Path $dir "$base-observations.md"
        $paths['Report']       = Join-Path $dir "$base-report.md"
    }
    return $paths
}
