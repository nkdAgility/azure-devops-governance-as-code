## Governance capability

Governance-as-code for Azure DevOps: an authored hierarchy under
`governance/programs/<name>/` is compiled to a desired state, diffed against the live
organisation, and reconciled.

### Commands

| Command | Reads | Writes |
| ------- | ----- | ------ |
| `Invoke-GovernanceBuild -ProgramPath <path>` | the authored YAML | `resolved.yaml` in the output folder |
| `Test-Governance -ProgramPath <path>` | the authored YAML | nothing — schema, rules and Azure DevOps limits, no live calls |
| `Invoke-GovernancePlan -ProgramPath <path>` | live organisation | nothing — returns a change set |
| `Invoke-GovernanceApply -ProgramPath <path>` | live organisation | **the live organisation** |
| `Invoke-GovernanceAudit -ProgramPath <path>` | live organisation | a compliance report |

### Rules

- **`apply` is the only destructive command.** Everything else is read-only. Never run
  `Invoke-GovernanceApply` unprompted; run `-WhatIf` first and have the change set read
  before it goes through. `-Prune` removes things that exist live but are not authored —
  treat it as separately destructive.
- **Programs are seed files.** `hierarchy.yaml`, `access.yaml`, `taxonomy.yaml`,
  `systems.yaml`, `members/` and `manifest.yaml` are authored by the engagement and never
  overwritten by tooling.
- **`apply` writes one work item.** When `taxonomy.yaml` declares a tag vocabulary, apply
  maintains a governance-owned anchor work item holding the sanctioned tags. Azure DevOps
  has no create-tag API and purges tags no work item references, so this is the only way
  to make a sanctioned tag exist. It is the engine's only work item write.
- **`manifest.yaml` names an environment variable, never a token.** Secrets live in the
  workspace `secrets/secrets.json` and are exported before this capability loads. Never
  write a PAT into a program file — they are committed.
- **Silent failure is a bug.** If a function cannot complete its work it throws. Returning
  `$null`, an empty set or `$false` on failure hides a broken reconcile; do not add
  fallbacks that swallow errors.
- **Build artefacts are disposable.** `resolved.yaml` and audit reports are generated into
  the workspace output folder and are gitignored. Never hand-edit `resolved.yaml` — change
  the authored source and rebuild.

### Working on a program

Start from `Invoke-GovernanceBuild` and `Test-Governance` — both are offline and fast, and
catch most authoring errors before any live call. Then `Invoke-GovernancePlan` to see what
would change. Read the plan before applying: a large diff usually means the authored
hierarchy has drifted from reality, not that reality is wrong.
