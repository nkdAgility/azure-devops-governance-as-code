# Azure DevOps Governance-as-Code — Agent & Contributor Guide

## Non-negotiable rules for contributors and agents

> **After every code change, run the tests. No exceptions.**

```powershell
pwsh -NoProfile -Command { Invoke-Pester ./tests/Compile.Tests.ps1 -Output Normal }
```

If the tests fail, fix the failure before doing anything else. Do not move on, do not explain, do not commit. Fix it.

**Silent errors are never acceptable.** If a function cannot complete its work, it must throw. Returning `$null`, an empty set, or `$false` when a call fails is a bug. Every caller depends on the error surfacing immediately.

**Memory scope is this repo only.** Never write to user memory (`/memories/`) or session memory (`/memories/session/`). Do not use the memory tool for persistent notes — write them directly to files under `.agents/` in this repository instead. The `/memories/repo/` tool writes to VS Code workspace storage, not to the repo on disk.

---

## Environment variables

| Variable | Purpose |
|---|---|
| `AZDEVOPS_DEV_PAT` | Personal Access Token for `nkdagility-preview` org. Referenced by the test fixture manifest (`tests/fixtures/programs/odyssey/manifest.yaml`) as `accessToken`. |
| `AZDEVOPS_DEV_ORG` | Org URL (`https://dev.azure.com/nkdagility-preview`). **Not a PAT.** Do not use as `accessToken`. |

Client programs define their own PAT env vars in their own repos (e.g. `AZDEVOPS_<CLIENT>_PAT` in the client repo's `governance/` folder). A manifest `accessToken` must always be an `$Env:` reference — never a literal token.

If a manifest's `accessToken` resolves to a URL, `Set-AdoAuth` will throw immediately (guard is in `AzureDevOps.ps1`).

---

## Authentication (Entra-first)

**Entra is the default auth mode.** Runs authenticate as the signed-in az identity — interactively via `az login`, in CI via `azure/login` OIDC or a service-principal login. Entra tokens carry the identity's real permissions: no PAT scopes to configure, no secret to store, and they work in orgs that forbid full-access PATs. The engine acquires tokens itself (`az account get-access-token`, cached per run) and the `az devops` CLI picks up the same session automatically.

Mode resolution (`Resolve-AdoAuthMode` / `Initialize-AdoAuth`):
1. manifest `auth: pat` → use the `accessToken` PAT (explicit opt-out of Entra).
2. otherwise, az session present → **entra**.
3. otherwise, `accessToken` resolves → **pat** with a warning (CI fallback).
4. otherwise → error telling the operator to `az login`.

`doctor` prints which identity it is testing (`[auth: Entra (user@…)]` or `[auth: PAT]`) — in entra mode a `[MISSING]` row means the *identity* lacks the permission in the org, not a token scope problem.

## Required PAT scopes (auth: pat / CI fallback only)

When a PAT is used, it must carry these scopes (Azure DevOps → User settings → Personal access tokens):

| Scope (API name) | PAT UI name | Needed for |
|---|---|---|
| `vso.project` / `vso.project_manage` | Project & Team — Read, write & manage | plan/audit; apply creates projects and teams |
| `vso.work` / `vso.work_write` | Work Items — Read & write | plan/audit; apply creates area/iteration paths, team settings |
| `vso.code` / `vso.code_manage` | Code — Read, write & manage | plan/audit; apply creates repos |
| `vso.build` / `vso.build_execute` | Build — Read & execute | plan/audit; apply creates pipeline folders |
| `vso.graph` / `vso.graph_manage` | Graph — Read & manage | group membership read; apply creates groups and members |
| `vso.memberentitlementmanagement` | Member Entitlement Management — Read | apply resolves member UPNs to descriptors |
| `vso.security_manage` | *(not in the PAT UI — Full access PAT, or the Entra fallback below)* | apply stamps pipeline folder ACLs + structural authority |

**Security writes without a Full access PAT:** many orgs forbid full-access PATs. `apply` therefore retries security ACL writes with an **Entra token** from the operator's `az login` session (acquired via `az account get-access-token`, never stored). Entra tokens carry the user's real permissions and are not PAT-scope-limited. `doctor` probes the same fallback and reports `covered by the Entra fallback (az login)` — or tells you to `az login` if neither route works.

**Verify, don't guess:** `./build.ps1 doctor -Program <name>` probes every scope family against the live org with side-effect-free calls (reads, plus intentionally invalid writes that ADO rejects *after* the scope check — HTTP 400 proves the scope, nothing is ever created). It exits non-zero listing the missing scopes. Run it before the first `apply` with a new PAT. The probe matrix lives in `Get-AdoScopeProbeSet` (`AzureDevOps.ps1`); if you add a resource type that calls a new API family, add a probe for it.

A missing *write* scope typically surfaces as `The requested resource requires user authentication` (HTTP 401) mid-apply — run `doctor` whenever you see that.

---

## Iteration cadence

Iteration paths are generated from `programs/<name>/cadence.yaml` and stored in the resolved model. The hierarchy is `Year → Season → Sprint`.

**Cadence rules (Odyssey):**
- Execution year starts on the **first Monday of February**
- Seasons: **S1** (Feb–May), **S2** (Jun–Oct), **S3** (Oct–Jan)
- Standard sprint: **3 working weeks** = 19 calendar days (Mon–Fri)
- Final sprint of S1 and S3 is shortened to **2 weeks** (12 calendar days) for boundary alignment
- S2 has 6 standard sprints

**Scope defaults (configurable in `cadence.yaml`):**

| Team type | Scope |
|---|---|
| Delivery team | 10 sprints back, 10 sprints forward |
| Portfolio team | 3 seasons back, 3 seasons forward |

To change defaults, edit `cadence.yaml` under the relevant program folder. The `yearHorizon` field controls how many execution years ahead to generate.

---

## What this system is

A compliance engine for Azure DevOps. The YAML files in `programs/` are the **single source of truth**. Everything in a live ADO organisation must match them exactly. Any deviation — missing, extra, or misconfigured — is non-compliant and must be flagged.

---

## Core ethos

> **Config is truth. Live state must match config. Any difference is a violation.**

This is not a provisioning helper that creates missing things and moves on. It is a compliance system that continuously asserts desired state against live state. The distinction matters:

| What we are | What we are NOT |
|---|---|
| Compliance engine — drift is a finding | One-shot provisioner — "good enough" is not |
| Idempotent reconciler — every run converges | Set-and-forget — trust that it worked once |
| Auditable — every deviation is reported | Silent — unexpected state is ignored |

---

## Commands

| Command | What it does |
|---|---|
| `build` | Compile `programs/<name>/*.yaml` → `out/<name>/resolved.yaml`. Validates schema, unique codes, owner refs, ADO path limits. No live calls. |
| `validate` | Same checks as build but writes nothing. |
| `plan` | Diff resolved desired state vs live ADO. Lists every change that `apply` would make. **Read-only.** |
| `apply` | Reconcile live ADO to resolved desired state. Creates missing resources **and corrects misconfigured ones**. Supports `-WhatIf`. With `-Prune` (or manifest `settings.prune: true`) also **deletes** orphans — teams, area paths, repos, and extra group members that exist in ADO but not in config. Prune is **never on by default**; `scope: future` placeholders, the project default team/repo, and iteration paths (ADR-005) are never pruned. |
| `audit` | Read-only compliance report. Reports every resource that deviates from desired state — missing, extra, or wrongly configured. **Exception (by design):** rolling iteration-window maintenance (team sprint/season subscriptions + backlog-iteration root) is time-based upkeep, so audit *performs* it rather than reporting it — it never produces findings and never requires an apply. |

---

## What "compliant" means for each resource

### Project
- The target project (`manifest.yaml` `project:` block; name defaults to the program name) exists in the org.
- `apply` creates it when missing (process/visibility/sourceControl from the manifest); plan/`-WhatIf` reports it would be created and stops — nothing else can be diffed without it. `audit` reports it as the single finding.
- Process, visibility, and source-control type only apply at creation — ADO cannot change them on an existing project.

### Area paths
- Every path in `resolved.areaPaths` (non-`future`) exists in ADO.
- Paths not in the resolved model that governance owns are flagged as orphans.

### Teams
- Every team in `resolved.teams` (non-`future`) exists in ADO.
- Each team's **area configuration** (`areaConfig`) matches exactly — correct paths, correct `includeSubAreas` flags.
- Each team's **Team Administrators** match `members/<code>.yaml` `teamAdmins:` exactly — empty/absent list means NO administrators; missing and extra admins are both findings. Entries use the same grammar as role lists (`upn:`/`group:` + `reason`, optional `expires`). Stored as Identity-namespace ACEs (no first-class API); extras are never removed while any desired entry fails to resolve, so a typo cannot strip a team of all admins.
- Teams that exist in ADO but are absent from the resolved model are orphans.

### Security groups
- Every group in `resolved.teams[*].securityGroups` exists in ADO.
- Each group's **membership** matches its `members` list exactly — missing members and extra members are both findings.

### Repos
- Every repo in `resolved.repos` exists. Repos are declared per node in `hierarchy.yaml` (`repos:` list of bare names; a node can own several). Resolved names are always prefixed with the node's hierarchy code — `My Repo` on `PTL-FND` → `PTL-FND-My-Repo` (spaces become dashes).
- Repos not in the resolved model are orphans.
- Each repo's **ACL** matches the resolved model: everyone in the project reads (`Project Valid Users`), only the owning team's contributor group writes, and `innerOSS: true` additionally grants everyone branch creation + PR contribution (fork/PR flow, no direct push).
- A repo's owner is the node's own team, or its first `sideload:` team when the node has no team.

### Hierarchy node kinds
- **team** (`portfolio`/`structural`/`delivery`) — real ADO team.
- **sideload** — `sideload: <code>` (or a list): **area-path visibility ONLY** — the path joins the listed teams' boards and nothing else. Zero security: structural authority always stays with a team's home area. A node with `sideload:` **and** an explicit `type:` is both: its own team, plus board visibility for the listed teams. (`owner:` has been **removed** — using it fails the build with a migration hint.)
- **area** — `team: none`: governed structure attached to nothing.
- Product `sections` are free-form: `- name: <display name>` / `items: [...]` — any number of bands, any characters in names.
- Team security is expressed only via `access.yaml` roles, `members/<code>.yaml`, and home-area structural authority — never via area-path attachment.

### Pipeline folders
- Every folder in `resolved.pipelineFolders` exists.
- Each folder's **ACL** matches the resolved `acl` list — wrong permissions and extra ACEs are both findings.
- Pipeline folders are **opt-in**: a node (team or product) only gets one when it declares `pipelineFolder: true` in `hierarchy.yaml` — meaning it has builds of its own. No flag → no folder, no ACL.

---

## Apply is corrective, not just additive

`apply` must not only create missing resources. It must also **correct** existing ones:

```
# Non-compliant state                   # apply must fix
Team "Foundation" exists               ✓  (no create needed)
  but areaConfig = [\Odyssey]        ✗  (wrong — patch it)
  
Group "PTL-FND-Contributors" exists    ✓  (no create needed)
  but missing member alice@corp.com     ✗  (wrong — add her)
  but has extra member bob@corp.com     ✗  (wrong — remove him)
```

After every `apply`, an `audit` run must produce zero findings.

---

## Scope filtering

Products marked `scope: future` in `hierarchy.yaml` are **invisible to apply and audit**. They exist in the resolved model as structural placeholders only. Remove the `scope: future` flag when a product enters active migration.

---

## Source layout

```
programs/            # empty by default — client programs live in client repos
                     # (e.g. NKDAClient-<client>/governance/programs/) and are passed
                     # to build.ps1 via -ProgramsRoot. A program folder holds:
  <name>/
    manifest.yaml    # org + accessToken reference + project declaration
    hierarchy.yaml   # authored product/team/band tree
    access.yaml      # role definitions + group naming conventions
    members/         # <codeKey>.yaml — desired group membership

tests/fixtures/programs/  # frozen program snapshot — compile-test data only

system/NKDAgility.AzureDevOps.Governance/
  Private/
    Compile/         # build stage: Import → Resolve → Write/Test
    Common/          # shared helpers (ConvertTo-Kebab etc.)
    AzureDevOps/     # thin wrappers over ADO REST API
  Public/            # exported cmdlets (one per command verb)
  Templates/         # what gets scaffolded into a customer workspace
    customer-repo/governance/   # capability init.ps1 + programs skeleton
  Agents/
    CAPABILITY.md    # guidance for agents USING this capability in a workspace;
                     # rendered into the workspace CLAUDE.md / AGENTS.md

.agents/             # guidance for agents BUILDING this engine (this file, ADRs).
                     # Never ships to a customer workspace.

tests/               # Pester tests — Compile.Tests.ps1 covers the full compile pipeline
out/                 # generated artifacts (gitignored)
```

---

## Adding a new resource type (checklist)

1. **Resolve** — add the resource to the resolved model in `Resolve-Governance.ps1`.
2. **Test** — add a Pester test in `tests/Compile.Tests.ps1` asserting the resolved shape.
3. **ADO helper** — add `Test-Ado*`, `New-Ado*` (and `Get-Ado*` if batch read is safe) functions to `AzureDevOps.ps1`. Prefer targeted REST calls over bulk list fetches to avoid OOM on large projects.
4. **Apply** — add the reconciliation step to `Invoke-GovernanceApply.ps1`. Check existence first, then create/correct.
5. **Audit** — add the compliance check to `Invoke-GovernanceAudit.ps1`. Every finding must be a distinct, actionable string.
6. **Plan** — add the diff logic to `Invoke-GovernancePlan.ps1`.

---

## Architecture decisions

Key decisions are recorded in `.agents/decisions/`. Read these before making structural changes.

| ADR | Decision |
|---|---|
| [ADR-001](decisions/ADR-001-implementation-language.md) | PowerShell over Go — right for internal tooling; Go noted for future wide distribution |
| [ADR-002](decisions/ADR-002-targeted-rest-checks.md) | Targeted REST checks over bulk fetches — bulk `az boards area project list` causes OOM on large projects |
| [ADR-003](decisions/ADR-003-apply-is-corrective.md) | Apply is corrective, not just additive — existing but misconfigured resources must be patched |
| [ADR-005](decisions/ADR-005-iteration-compliance-rule.md) | Old governance iterations are compliant by definition — only check desired paths exist, never flag old sprints |

---

## REST API conventions

- All live ADO calls go through `Invoke-AdoRest` in `AzureDevOps.ps1`.
- `$env:AZURE_DEVOPS_EXT_PAT` must be set (via `Set-AdoAuth`) before any live call.
- Prefer targeted `GET /resource/{id}` existence checks over `GET /resource` (list all) to avoid loading large responses into memory.
- `Test-Ado*` functions must re-throw on non-404 errors — a swallowed exception that returns `$false` will trigger a spurious create.
