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
| `Invoke-GovernancePreflight -ProgramPath <path> [-Code <code>] [-Offline] [-SkipFresh]` | the SOURCE org named in `sources.yaml` + the target org (`-Offline`: only the last gathered data; `-SkipFresh`: only nodes with no data file yet) | per node, in `preflight\<CODE>\`: `-data.json` (facts) + `-findings.txt/.json` — read-only against both orgs |
| `Invoke-GovernancePreflightReport -ProgramPath <path> [-Code <code>]` | the data + findings files already written, plus `-observations.md` if present | `-report.md` per node — offline, deterministic, no AI |

### Rules

- **`apply` is the only destructive command.** Everything else is read-only. Never run
  `Invoke-GovernanceApply` unprompted; run `-WhatIf` first and have the change set read
  before it goes through. `-Prune` removes things that exist live but are not authored —
  treat it as separately destructive.
- **Programs are seed files.** `hierarchy.yaml`, `access.yaml`, `taxonomy.yaml`,
  `systems.yaml`, `sources.yaml`, `members/` and `manifest.yaml` are authored by the
  engagement and never overwritten by tooling.
- **`preflight` answers "what would fail if this team moved in today?"** — per incoming
  team, against its CURRENT location declared in `sources.yaml` (source org/project/area
  path, plus optionally its source teams and a repo filter). It projects the source state
  into target coordinates and runs the same evaluators audit uses: area subtree orphans,
  tag usage on the source work items, repo naming, authored UPNs resolvable in the target
  org, and people in the source team who are not authored. Findings are what the team
  fixes before migration; work item type/state/field compatibility stays with the
  migration toolchain. Everything lands in `<output>\preflight\<CODE>\`, named
  `<program>-preflight-<CODE>-<part>`, with the run summary one level up at
  `<program>-preflight-summary.md`. It runs in two steps: a **gather** writes the facts
  to `-data.json` (work items per source area path, tag and iteration usage, population,
  UPN resolution — it contains UPNs, keep it in the workspace), and a pure **analysis**
  turns that into `-findings.txt` and `-findings.json`.
  `-Offline` re-runs the analysis on the last data file with no live calls — change a tag
  pattern, re-run, nothing is read from either org. Findings are objects with a stable
  `check` id; `sources.yaml labels:` attaches the engagement's own rule/lane/task fields
  per check so the JSON is already the team's fix report. Disallowed tag patterns are one
  finding per pattern with counts and examples. Non-zero exit on findings, same CI
  contract as audit.
- **The fix report is rendered, never written.** `preflight-report` turns each team's
  data + findings files into `-report.md` deterministically; every count and table in it
  is copied from those files. The one section anyone else writes is `-observations.md`,
  spliced in between markers on the next render. **Never edit the report by hand and
  never retype a number from it** — change the fragment or the inputs and re-render. The shipped `/audit-preflight` command runs the whole
  pipeline for every team (cheap agents shell out for gather/render/publish; one agent
  per team writes the fragment under `.claude/skills/preflight-report/SKILL.md`; a
  checker verifies its numbers). Subagents spawned by it have a shell for the read-only
  verbs only: `.claude/hooks/deny-governance-apply.ps1` refuses any shell command that
  would run `apply` (except `-WhatIf`) — register it in `.claude/settings.json` under
  `PreToolUse` with matcher `PowerShell|Bash` if this workspace has not already.
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
