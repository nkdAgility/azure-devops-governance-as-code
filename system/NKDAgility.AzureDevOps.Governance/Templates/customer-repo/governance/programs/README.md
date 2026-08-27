# Governance programs

One folder per program. Each is the authored desired state for an Azure DevOps
organisation or project, compiled and reconciled by the governance module.

```
programs/<name>/
  manifest.yaml    program identity, organisation URL, accessToken variable name
  hierarchy.yaml   the authored hierarchy (areas, teams, repos, pipeline folders)
  access.yaml      roles and the group catalog
  cadence.yaml     iteration cadence (optional)
  taxonomy.yaml    governed vocabularies — the sanctioned tag list (optional)
  systems.yaml     reusable team systems (optional)
  members/         membership per code key, one <code>.yaml per team
```

## Systems

`systems.yaml` declares reusable, named sets of sub-elements that teams opt into
via `systems:` on their node in `hierarchy.yaml`. Each system stamps its child
area paths under the applying team's home area and surfaces them on that team's
own board — visibility only: no extra team, no groups, no members file.

```yaml
# systems.yaml
systems:
  bug-inbox:
    areas:
      - name: Inbox    # incoming triage, on the team's own board
```

```yaml
# hierarchy.yaml — on any team node or product
- name: Foundation
  short: FND
  systems: [bug-inbox]     # -> area path ...\Foundation\Inbox on Foundation's board
```

## Tags

`taxonomy.yaml` holds the governed work item tag vocabulary. Sanctioned tags that
do not exist in the project are reported as missing, and `apply` creates them.

Azure DevOps has no API to create a bare tag, and it deletes tags that no work
item references. So `apply` maintains one governance-owned **anchor work item**
carrying the sanctioned vocabulary — that is what makes the tags exist in the
picker and keeps them from being purged. Do not delete or retag that item; the
vocabulary goes with it. Set `tags.anchor.enabled: false` to report missing tags
without creating anything.

```yaml
tags:
  sanctioned: [ Inbox, Backlog, Triage ]
  disallowedPatterns:
    - '^\d+$'          # bare build numbers
  anchor:
    enabled:      true
    workItemType: Task # must exist in the project's process
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
