# ============================================================================
#  MANAGED FILE - DO NOT EDIT IN THE CUSTOMER WORKSPACE
#  Source: Templates\customer-repo\.claude\hooks\deny-governance-apply.ps1 inside
#          the NKDAgility.AzureDevOps.Governance module.
# ============================================================================
<#
.SYNOPSIS
    PreToolUse hook: refuses a shell command that would run a governance apply.

.DESCRIPTION
    apply is the only command in this workspace that changes the live Azure
    DevOps organisation, and the workspace rule is that it is never run
    unprompted — an operator runs it from their own terminal after reading
    the -WhatIf change set. Subagents spawned by the audit-preflight workflow
    have a shell so they can run the read-only preflight verbs; this hook is
    what makes "read-only" true regardless of what a prompt says.

    -WhatIf is allowed through: it changes nothing and is the step that must
    precede a real apply.

    Register it in .claude\settings.json under PreToolUse with matcher
    "PowerShell|Bash". Claude Code passes the tool call as JSON on stdin;
    exit code 2 blocks the call and returns stderr to the model as the reason.
#>
$ErrorActionPreference = 'Stop'

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
}
catch {
    # A hook that cannot parse its input must not block real work.
    exit 0
}

$command = [string]$payload.tool_input.command
if (-not $command) { exit 0 }

$isApply =
    $command -match 'Invoke-GovernanceApply' -or
    $command -match 'Invoke-Governance\s+(-Command\s+)?[''"]?apply\b' -or
    $command -match 'build\.ps1\s+(-Command\s+)?[''"]?apply\b'

if ($isApply -and $command -notmatch '-WhatIf(?!\s*:\s*\$false)') {
    [Console]::Error.Write(
        "Refused: this command would run a governance APPLY, which reconciles the live " +
        "Azure DevOps organisation. apply is never run by an agent in this workspace. " +
        "An operator runs it from their own terminal, after 'apply -WhatIf' and after the " +
        "change set has been read. -WhatIf is permitted."
    )
    exit 2
}

exit 0
