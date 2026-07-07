function ConvertTo-Kebab {
    <#
        .SYNOPSIS
        Lower-kebab-cases a display name for use in repo / pipeline identifiers.
        "Plugin A" -> "plugin-a", "Open API" -> "open-api".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    $clean = $Value -replace '[^\w\s-]', ''
    $clean = $clean -replace '[\s_]+', '-'
    return $clean.ToLowerInvariant().Trim('-')
}
