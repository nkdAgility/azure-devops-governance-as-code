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
| `AZDEVOPS_DEV_PAT` | Personal Access Token for `nkdagility-preview` org. Used by `programs/odyssey/manifest.yaml` as `accessToken`. |
| `AZDEVOPS_DEV_ORG` | Org URL (`https://dev.azure.com/nkdagility-preview`). **Not a PAT.** Do not use as `accessToken`. |

If a manifest's `accessToken` resolves to a URL, `Set-AdoAuth` will throw immediately (guard is in `AzureDevOps.ps1`).

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
| `apply` | Reconcile live ADO to resolved desired state. Creates missing resources **and corrects misconfigured ones**. Supports `-WhatIf`. |
| `audit` | Read-only compliance report. Reports every resource that deviates from desired state — missing, extra, or wrongly configured. |

---

## What "compliant" means for each resource

### Area paths
- Every path in `resolved.areaPaths` (non-`future`) exists in ADO.
- Paths not in the resolved model that governance owns are flagged as orphans.

### Teams
- Every team in `resolved.teams` (non-`future`) exists in ADO.
- Each team's **area configuration** (`areaConfig`) matches exactly — correct paths, correct `includeSubAreas` flags.
- Teams that exist in ADO but are absent from the resolved model are orphans.

### Security groups
- Every group in `resolved.teams[*].securityGroups` exists in ADO.
- Each group's **membership** matches its `members` list exactly — missing members and extra members are both findings.

### Repos
- Every repo in `resolved.repos` exists.
- Repos not in the resolved model are orphans.

### Pipeline folders
- Every folder in `resolved.pipelineFolders` exists.
- Each folder's **ACL** matches the resolved `acl` list — wrong permissions and extra ACEs are both findings.

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
programs/
  <name>/
    manifest.yaml    # org + accessToken reference
    hierarchy.yaml   # authored product/team/band tree
    access.yaml      # role definitions + group naming conventions
    members/         # <codeKey>.yaml — desired group membership

module/AdoGovernance/
  Private/
    Compile/         # build stage: Import → Resolve → Write/Test
    Common/          # shared helpers (ConvertTo-Kebab etc.)
    AzureDevOps/     # thin wrappers over ADO REST API
  Public/            # exported cmdlets (one per command verb)

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
| [ADR-004](decisions/ADR-004-scope-future-filtering.md) | `scope:future` products are invisible to apply and audit until the flag is removed |

---

## REST API conventions

- All live ADO calls go through `Invoke-AdoRest` in `AzureDevOps.ps1`.
- `$env:AZURE_DEVOPS_EXT_PAT` must be set (via `Set-AdoAuth`) before any live call.
- Prefer targeted `GET /resource/{id}` existence checks over `GET /resource` (list all) to avoid loading large responses into memory.
- `Test-Ado*` functions must re-throw on non-404 errors — a swallowed exception that returns `$false` will trigger a spurious create.
