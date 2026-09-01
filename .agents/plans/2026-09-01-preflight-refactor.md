# Preflight refactor plan — "what would fail if this team moved in today?"

Date: 2026-09-01
Status: **implemented** same day — see ADR-007 for the decisions as landed
(deviations from this plan: no Analytics OData path yet, WIQL-paging only;
`Use-AdoOrgAuth` became the `Enter-/Exit-AdoOrgAuth` pair; nested-group
entries are informational-only in preflight). The open Phase-0-style
decisions at the bottom still stand.
Origin: SLB/Subsurface engagement. Teams migrating into a governed program
(e.g. Foundation, living today in `slb1-swt/Petrel` under area path
`Petrel\Foundation`) need a per-team failure report so they can pre-comply in
their current location before migration.
Driver conversation: NKDAClient-SLB workspace, 2026-09-01.

## The idea in one paragraph

Preflight answers: *if this team's current content were moved into the governed
target today, which compliance checks would fail?* It gathers live state from
the team's **source** location (foreign org/project/area path), **projects** it
into target coordinates (source area subtree → the node's authored path, source
repo names → convention names), and evaluates the projected snapshot with the
**same rules** the audit uses. No rule logic is forked; the reconcile loop is
refactored so its comparisons become shared, pure evaluators.

## Non-goals (write these down or they creep in)

- **No work item type/state/field validation.** Process compatibility belongs
  to the migration toolchain (Data Import / Migration Tools validation loops).
  Preflight links to it, never reimplements it.
- **No writes anywhere.** Preflight is read-only against both orgs, same
  standing as audit.
- **No target-structure checks that only exist post-move** (iteration scope
  roll, backlog visibility, pipeline folder ACLs, structural authority ACEs).
  They describe target state apply will create; they cannot fail "pre-move".

## Current constraints discovered in the code

- `Invoke-GovernanceReconcile` (Private/Compliance) is one ~1,300-line function
  interleaving *read live → compare → fix/report* per resource section.
  Findings are prefix-classified strings (`MISSING `, `DRIFT `,
  `AUDIT EXCEPTION `, `ERROR `/`UNRESOLVABLE `); the text/JSON report writer and
  CI exit code depend on those prefixes.
- Tag check reads the **project-wide** tag set (`Get-AdoTagSet`); there is no
  "tags in use under an area path" helper.
- Auth is module-global and single-org: `Initialize-AdoAuth` sets
  `$script:AdoAuthMode` + one `AZURE_DEVOPS_EXT_PAT`. Preflight needs source
  org + target org in one run.
- `Import-GovernanceSource` loads a fixed file set; the source hash feeds
  provenance — any new file must join the hash.
- The customer-facing verb has TWO dispatchers: the managed template
  `Templates/customer-repo/governance/init.ps1` (propagates via workspace
  `init.ps1`) and each workspace's seed `governance/build.ps1` (one-time manual
  edit per workspace).
- Test fixture `tests/fixtures/programs/odyssey/` already models the Subsurface
  shape (has PTL-FND) — use it for preflight fixtures.

## Phase 1 — Evaluator extraction (no behaviour change)

Extract the compare step of exactly the sections preflight needs into pure
functions, new file `Private/Compliance/Evaluators.ps1`. Each takes desired
(model slice) + observed (plain hashtables/arrays, no live calls) and returns
**finding objects** `@{ class; resource; codePath; message }` where `message`
is byte-identical to today's string:

| Evaluator | Extracted from section | Observed input |
| --- | --- | --- |
| `Test-GovernanceAreaCompliance` | 1 (area paths) | desired paths + live path set |
| `Test-GovernanceGroupCompliance` | 3 (security groups) | desired groups/members + live groups, member sets, and a pre-resolved UPN→descriptor map (incl. unresolvable + suggestions) |
| `Test-GovernanceRepoCompliance` | 6 (repos, naming/orphans only — not ACL bits) | desired repo names + live repo names |
| `Test-GovernanceTeamAdminCompliance` | 5c | desired admins (pre-resolved) + live admin set |
| `Test-GovernanceTagCompliance` | 7 (sanctioned/disallowed classification only — not the anchor) | sanctioned + patterns + observed tag names |

Key design points:

- **Identity resolution stays in gather.** Evaluators must be pure; UPN→
  descriptor lookups are live calls, so the reconcile (and later preflight)
  resolves first and passes the resolution map in. Unresolvable entries arrive
  as data and the evaluator emits the `UNRESOLVABLE` finding.
- **Reconcile keeps orchestration and fixes.** Each refactored section becomes:
  gather (existing helpers) → evaluate → act (Apply fixes / report). Console
  output lines and report text stay identical; existing prefix-string plumbing
  is fed by `.message`.
- **Leave untouched:** iterations (2), team iteration scope (4), backlog
  levels (5), pipeline folders (7), repo ACLs (6b), structural authority (6),
  tag anchor seeding (7a). Preflight never runs them and extracting them buys
  nothing today.
- Extract the report-writing block (text + JSON twin) into
  `Write-GovernanceReport` so preflight reuses it verbatim.

Verification: Pester unit tests per evaluator (pure functions, fixture
snapshots); existing 37 tests stay green; one read-only `audit` against
nkdagility-preview diffed against a pre-refactor run of the same org —
reports must be identical.

## Phase 2 — `sources.yaml` + model slicing

New optional seed file `programs/<name>/sources.yaml` — the authored map of
where each incoming team lives today:

```yaml
# programs/<name>/sources.yaml — pre-migration source locations, per codePath.
sources:
  PTL-FND:
    org:      slb1-swt
    project:  Petrel
    areaPath: Petrel\Foundation      # source subtree root, project-rooted
    teams:                            # source teams whose membership defines
      - Petrel Foundation             #   "works there today" (optional)
    repos:                            # which source repos are this team's
      include: ['Foundation*']        #   (globs) — optional; empty = skip repo checks
```

- `Import-GovernanceSource`: load it, include raw text in the provenance hash.
- `Test-Governance`: validate — every key is a known non-future codePath,
  areaPath is project-rooted (no leading `\`), org/project non-empty.
- New `Select-GovernanceSubtree -Resolved -Code`: slices the resolved model to
  one node — its area subtree, teams, groups+members, repos, teamAdmins;
  taxonomy passes through program-wide (tags are program policy). Also the
  building block Phase-5-style owner routing wants later.

## Phase 3 — Source gather + projection

New helpers in `Private/AzureDevOps/AzureDevOps.ps1` (all read-only):

- `Get-AdoTagUsageUnderArea -OrgUrl -Project -AreaPath` → tag → work item
  count. WIQL `[System.AreaPath] UNDER` selecting `System.Tags`, paged in ID
  batches to dodge the 20k WIQL cap; prefer Analytics OData when the org has
  it, WIQL as fallback. This is the only genuinely new mechanism.
- `Get-AdoTeamMemberUpnSet -OrgUrl -Project -Team` → UPN set (expand team →
  members via existing graph plumbing).
- Reuse as-is against the source org: `Get-AdoAreaPathSubtree`,
  `Get-AdoRepoSet`, `Get-AdoTeamList`.

`ConvertTo-PreflightProjection` (new, `Private/Compliance/`): maps the source
snapshot into target coordinates —

- area paths: `<sourceRoot>\X\Y` → `<node target path>\X\Y`;
- repos: matched source repos kept under their source names (evaluated against
  the authored list + `{key}-{Name}` convention — a name mismatch IS the
  finding);
- people: union of source team membership (per `sources.yaml.teams`) as the
  observed population.

**Auth (the one real refactor risk).** Two orgs in one run:

- Entra path: same tenant covers both SLB orgs — validate the Entra session
  against **each** org URL at preflight start (`Test-AdoEntraSession` per org),
  not just the manifest org.
- PAT path: the manifest holds one token. Add optional
  `accessToken:` per `sources.yaml` entry (env-var reference, same
  `Resolve-AccessToken` rules, never a literal). Because `Set-AdoAuth` is
  global, `Invoke-AdoRest` calls against the source org must swap/restore the
  active token — implement as a small `Use-AdoOrgAuth -OrgUrl { … }` wrapper
  rather than threading tokens everywhere. If neither route can auth the
  source org, fail fast with the doctor-style explanation.

## Phase 4 — the command

`Public/Invoke-GovernancePreflight.ps1`:

```
Invoke-GovernancePreflight -ProgramPath <p> -ResolvedPath <p> [-Code PTL-FND] [-Org <override>]
```

Flow per code (default: every code present in `sources.yaml`):

1. Build (same always-build-first rule as audit).
2. `Select-GovernanceSubtree` for the code.
3. Gather source snapshot (Phase 3) + gather target-side facts needed for
   security: resolve every authored member UPN against the **target** org
   (people not yet in `slb-swt` = findings), and resolve the observed source
   population against the authored member list (working there today but not
   authored = the day-one-lockout finding, class `DRIFT`).
4. Project, then run the Phase 1 evaluators.
5. Emit per-code report via `Write-GovernanceReport`:
   `preflight-<code>.txt` + `.json` next to `resolved.yaml`. Non-zero exit on
   findings (same CI contract as audit).
6. Informational (not findings): source iteration paths in use (free from the
   same work item query — feeds the migration mapping), and a pointer to the
   migration toolchain for process/type validation.

Wire the verb:
- Template `Templates/customer-repo/governance/init.ps1`: add `preflight` to
  the `ValidateSet` + dispatch (+ `-Code` passthrough) — managed, reaches every
  workspace on next `init.ps1`.
- `Templates/customer-repo/.managed` unchanged (init.ps1 already listed).
- Customer workspaces' seed `governance/build.ps1` needs the same one-time
  edit (NKDAClient-SLB: add `preflight` to its ValidateSet/dispatch).

## Phase 5 — docs, tests, rollout

- **ADR-007**: preflight = projected source state through shared evaluators;
  records the non-goals (esp. process validation stays in migration tooling)
  and the "population" definition below.
- Update `Agents/CAPABILITY.md` + the rendered customer-repo guidance
  (commands table gains preflight: reads source org + target org, writes a
  report; read-only).
- Pester: evaluator tests (Phase 1), `sources.yaml` validation tests,
  subtree-slice tests, projection tests — all offline against the odyssey
  fixture (add a `sources.yaml` fixture for PTL-FND).
- Live verification ladder: read-only run against nkdagility-preview → real
  run `preflight -Code PTL-FND` against `slb1-swt/Petrel` + `slb-swt` → review
  the report with Foundation before publishing the pattern to other teams.
- Workspace follow-up (NKDAClient-SLB, separate change): author
  `governance/programs/subsurface/sources.yaml` (PTL-FND first), edit
  `governance/build.ps1`, decide whether per-team preflight reports are
  committed engagement evidence or handed over from `output/` (default:
  gitignored output, revisit with Phase 5 owner routing).

## Decisions needed before/while building (take to Rudi/Kjartan, Phase-0 style)

1. **"Works there today" population** for the security lockout check: source
   team membership (proposed default), recent work item assignees, repo
   contributors, or a union. Affects noise level directly.
2. **Repo target-name source of truth**: governance `repos:` vs the migration
   inventory CSV `TargetName`. Proposal: preflight checks naming convention +
   flags repos in the source filter with no authored counterpart; the
   migration CSV remains the migration's truth. One report line explains the
   split.
3. Whether unsanctioned tags **below a usage threshold** (e.g. <5 work items)
   are worth listing individually or as a rollup — Petrel-scale tag noise will
   otherwise dominate the report.

## Sequencing and size

Phases are strictly ordered 1→4; 5 overlaps. Phase 1 is the bulk (careful
extraction + identical-output verification) — roughly half the effort. Phase 3
is the only new ADO mechanics (tag usage query + auth wrapper). Phases 2 and 4
are thin. Everything ships behind a new verb; audit/plan/apply behaviour and
report formats are unchanged throughout, so partial landings are safe.
