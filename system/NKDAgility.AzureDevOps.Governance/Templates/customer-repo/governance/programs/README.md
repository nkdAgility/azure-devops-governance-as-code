# Governance programs

One folder per program. Each is the authored desired state for an Azure DevOps
organisation or project, compiled and reconciled by the governance module.

```
programs/<name>/
  manifest.yaml    program identity, organisation URL, accessToken variable name
  hierarchy.yaml   the authored hierarchy (areas, teams, repos, pipeline folders)
  access.yaml      roles and the group catalog
  cadence.yaml     iteration cadence (optional)
  members/         membership per code key, one <code>.yaml per team
```

These are **seed** files: yours to author and edit. Nothing overwrites them.

## Secrets

`manifest.yaml` names an environment variable as its `accessToken` — it never holds a
token. Define that variable in the workspace's `secrets/secrets.json` via the `EnvVars`
list on the matching organisation, and the workspace `init.ps1` exports it before this
capability loads. Never put a PAT in a program file; they are committed.

## Running

```powershell
Invoke-GovernanceBuild -ProgramPath .\governance\programs\<name>   # compile + validate
Test-Governance        -ProgramPath .\governance\programs\<name>   # schema and rules, no live calls
Invoke-GovernancePlan  -ProgramPath .\governance\programs\<name>   # diff against live Azure DevOps
Invoke-GovernanceApply -ProgramPath .\governance\programs\<name> -WhatIf
Invoke-GovernanceAudit -ProgramPath .\governance\programs\<name>   # read-only compliance report
```

`plan` and `audit` are read-only. **`apply` mutates the live organisation** — always run
it with `-WhatIf` first and read the change set before letting it through.
