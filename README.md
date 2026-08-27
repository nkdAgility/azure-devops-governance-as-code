# Azure DevOps Governance-as-Code

[![main](https://github.com/nkdAgility/azure-devops-governance-as-code/actions/workflows/main.yaml/badge.svg)](https://github.com/nkdAgility/azure-devops-governance-as-code/actions/workflows/main.yaml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/NKDAgility.AzureDevOps.Governance?label=PSGallery)](https://www.powershellgallery.com/packages/NKDAgility.AzureDevOps.Governance)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![PowerShell 7.4+](https://img.shields.io/badge/PowerShell-7.4%2B-5391FE.svg)](https://github.com/PowerShell/PowerShell)

A **compliance engine** for Azure DevOps. You describe the organisation you want
in readable YAML — products, teams, area paths, repos, pipeline folders,
permissions, iteration cadence — and the engine continuously asserts that the
live Azure DevOps project matches it.

> **Config is truth. Live state must match config. Any difference is a violation.**

This is deliberately *not* a provisioning helper that creates what is missing and
moves on:

| What this is | What this is not |
| --- | --- |
| Compliance engine — drift is a finding | One-shot provisioner — "good enough" is not |
| Idempotent reconciler — every run converges | Set-and-forget — trust that it worked once |
| Corrective — a misconfigured team gets patched | Additive — only creating what does not exist |
| Auditable — every deviation is reported | Silent — unexpected state is ignored |

After a successful `apply`, an `audit` returns **zero findings**. That invariant
is the whole point.

---

## Why

Large Azure DevOps projects rot. Teams get created by hand with the wrong area
configuration, someone is added to a security group and never removed, a repo
ends up writable by the wrong team, and a year later nobody can say whether the
project reflects the org chart or a series of accidents.

Point-and-click governance cannot be reviewed, diffed, or rolled back. This
project makes the intended structure a reviewable artefact in version control,
and makes every divergence from it visible and correctable.

---

## Quick start

**You do not clone this repo to use it.** This repo is the *engine*. You create
your own private workspace repo, declare this engine as a capability, and a
loader materialises the module into a generated `.system/` folder. Your desired
state stays in your repo; the engine stays in this one. Nothing is duplicated and
nothing of yours is ever committed here.

**Prerequisites**

- [PowerShell 7.4+](https://github.com/PowerShell/PowerShell)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the
  `azure-devops` extension (`az extension add --name azure-devops`)
- [GitHub CLI](https://cli.github.com/) for the repo-creation step

### 1. Create your private workspace

```bash
gh repo create my-org/my-governance --private --clone && cd my-governance
```

### 2. Fetch the workspace loader

```bash
curl -o init.ps1 https://raw.githubusercontent.com/nkdAgility/azure-devops-automation-tools/main/system/NKDAgility.AzureDevOps.AutomationTools/Templates/customer-repo/init.ps1
```

### 3. Declare which engines you use

Create `capabilities.json` — this file is yours and is never overwritten:

```json
{
  "capabilities": [
    {
      "name": "automation",
      "module": "NKDAgility.AzureDevOps.AutomationTools",
      "repo": "https://github.com/nkdAgility/azure-devops-automation-tools.git"
    },
    {
      "name": "governance",
      "module": "NKDAgility.AzureDevOps.Governance",
      "repo": "https://github.com/nkdAgility/azure-devops-governance-as-code.git"
    }
  ]
}
```

### 4. Load the workspace

```bash
pwsh -NoProfile -Command ". .\init.ps1"
```

That clones each engine, copies its module into `.system/`, scaffolds the rest of
the workspace (`.gitignore`, `secrets/`, `governance/`, agent guidance), and
exports your secrets as environment variables.

### 5. Author your program and run the safety ladder

Create `governance/programs/<name>/` (see [Defining a
program](#defining-a-program)), then — everything except `apply` is read-only:

```bash
az login
```

```bash
pwsh -NoProfile -Command ". .\init.ps1; Invoke-Governance build    myprogram"
pwsh -NoProfile -Command ". .\init.ps1; Invoke-Governance plan     myprogram"
pwsh -NoProfile -Command ". .\init.ps1; Invoke-Governance apply    myprogram -WhatIf"
pwsh -NoProfile -Command ". .\init.ps1; Invoke-Governance apply    myprogram"
pwsh -NoProfile -Command ". .\init.ps1; Invoke-Governance audit    myprogram"
```

Always run through a **fresh shell** so `init.ps1` executes first. The engine runs
from `.system/`, which is only refreshed when `init.ps1` runs — a shell that has
been open all day keeps serving yesterday's engine even after a `git pull`.
`-NoSync` skips the pull for offline work.

### How your secrets stay yours

`init.ps1` scaffolds `secrets/secrets.example.json` and gitignores everything else
in `secrets/`. Each entry names the environment variables to export, and your
`manifest.yaml` references one **by name**, never by value:

```yaml
auth:        entra                     # default: the signed-in az identity
accessToken: $Env:AZDEVOPS_MYORG_PAT   # fallback for non-interactive runs
```

Your workspace `.gitignore` keeps the generated and secret parts out of git:

```gitignore
/.system/       # materialised engine copies — generated, never committed
/secrets/*      # PATs
!/secrets/secrets.example.json
/output/        # build artefacts and audit reports
workspace.local.json
```

---

## Two ways to run the engine

There are exactly two setups, and the difference matters for whether a compliance
run is reproducible.

| | **Consumption** | **Development** |
| --- | --- | --- |
| Source | Published module, pinned version | A clone (yours, or a fork's) |
| Changes propagate | On an explicit version bump | Instantly, uncommitted edits included |
| Selected by | Default | `enginePaths.<name>` in `workspace.local.json` |
| Reproducible | **Yes** | **No** — came from one machine's working tree |

**Consumption** is the default and the only mode a scheduled audit should ever
run in. Install it directly:

```bash
Install-Module NKDAgility.AzureDevOps.Governance -Scope CurrentUser
```

**Development** is for changing the engine, where edits have to take effect in a
real workspace immediately — no publish step in the loop. That is why a clone,
not a package: `init.ps1` copies the working tree, uncommitted changes and all,
and warns you when it does. Point a workspace at your clone in
`workspace.local.json`, which is gitignored, so the override never reaches your
teammates or CI:

```json
{ "enginePaths": { "governance": "C:\\src\\azure-devops-governance-as-code" } }
```

Contributors work the same way against a fork — it is the development setup with
a different remote, not a third mode. Clone the fork, point a workspace at it,
change engine and configuration together, then open a PR.

Working on the engine on its own, without a workspace, use the CLI directly:

```bash
pwsh ./build.ps1 audit -Program myprogram -ProgramsRoot ../my-governance/governance/programs
```

> **Provenance.** A run in development mode is not evidence of anything
> reproducible — it came from a working tree that may exist on exactly one
> machine. `.system/.source.json` records the version, commit, and whether the
> source was dirty. Check it before treating an audit result as authoritative.

### When the requested ring has nothing

Consumption mode defaults to the **production** ring, which has nothing on it
until the first stable release. `init.ps1` does not fail the workspace over that.
It never tears down a working engine without a replacement in hand:

1. **`.system/` already has the engine** — it is kept *exactly* as it is, and its
   `.source.json` is left untouched. The workspace keeps running what it was
   already running, and its provenance still names whatever produced it.
2. **Otherwise, a version is installed** — that is staged instead.
3. **Otherwise it fails**, naming the module, the ring, what is actually
   published, and both ways out.

Step 1 deliberately beats step 2: moving a workspace onto an unrelated version
that happens to be in the module path, because a release hasn't happened yet,
would change what it runs without anyone asking — worse than being stale. Every
fallback is warned about, because it means the run is not on the ring it asked
for.

---

## Commands

| Command | What it does | Writes to Azure DevOps |
| --- | --- | --- |
| `build` | Compile `programs/<name>/*.yaml` → `out/<name>/resolved.yaml`. Validates schema, unique codes, owner refs, Azure DevOps path limits. No live calls. | No |
| `validate` | Same checks as `build`, writes nothing. | No |
| `plan` | Diff the resolved desired state against live Azure DevOps. Lists every change `apply` would make. | No |
| `apply` | Reconcile live Azure DevOps to the desired state. Creates missing resources **and corrects misconfigured ones**. Supports `-WhatIf` and `-Prune`. | **Yes** |
| `audit` | Read-only compliance report. Reports every resource that deviates — missing, extra, or wrongly configured. | No |
| `doctor` | Probe the current identity's permissions against the live org with side-effect-free calls. Exits non-zero listing what is missing. | No |

### `apply` is corrective, not just additive

```text
# Non-compliant live state                    # what apply does
Team "Foundation" exists                      ✓  no create needed
  but areaConfig = [\Odyssey]                 ✗  wrong — patches it

Group "PTL-FND-Contributors" exists           ✓  no create needed
  but is missing alice@corp.com               ✗  wrong — adds her
  but also contains bob@corp.com              ✗  wrong — removes him
```

### Pruning is opt-in

By default, resources that exist in Azure DevOps but are absent from config are
reported as audit exceptions, not deleted. `apply -Prune` (or `settings.prune:
true` in the manifest) additionally **deletes** orphan teams, area paths, repos,
and extra group members. Placeholders marked `scope: future`, the project default
team and repo, and iteration paths are never pruned.

---

## Defining a program

A program is a folder of YAML. Only `manifest.yaml` and `hierarchy.yaml` are
required.

```text
governance/programs/<name>/          # in YOUR workspace repo, not this one
  manifest.yaml    # program identity, org, project, auth reference
  hierarchy.yaml   # the authored product / structural / team tree
  access.yaml      # role definitions + group naming conventions
  taxonomy.yaml    # governed vocabularies (work item tags)   — optional
  systems.yaml     # reusable team sub-elements               — optional
  cadence.yaml     # iteration cadence                        — optional
  members/         # <code>.yaml — desired group membership
```

**`manifest.yaml`** — identity and connection. `accessToken` is always an
environment-variable *reference*, never a literal token:

```yaml
program:     Odyssey
org:         my-org
accessToken: $Env:AZDEVOPS_PAT   # only used when auth: pat

project:
  name:          Odyssey
  process:       Agile
  visibility:    private
  sourceControl: git
```

**`hierarchy.yaml`** — position in the tree *is* the type. A node is a product
because it has a `dpm`; a node with child teams is structural; a leaf is a
delivery team.

```yaml
products:
  - name: Portal
    dpm: 101
    short: PTL
    pipelineFolder: true
    sections:
      - name: Platform
        items:
          - name: Graphics Pipeline
            short: GPI
            systems: [bug-inbox]
          - name: Foundation
            short: FND
            type: delivery       # a working team even though Open API nests under it
            iterations: none     # a delivery team that does not plan in sprints
      - name: Plugins
        items:
          - name: Plugin A
            short: PLGA
            sideload: PTL-FND    # area path here, on Foundation's board. No security.
            repos:
              - plugin-a         # -> PTL-PLGA-plugin-a (auto-prefixed with the node code)
```

A node's global key is the product-qualified chain of `short` codes — Portal's
Graphics Pipeline is `PTL-GPI`. That key names its groups (`PTL-GPI-Contributors`)
and its membership file (`members/PTL-GPI.yaml`).

**`members/<code>.yaml`** — desired membership, reconciled in both directions.
Every entry carries a `reason`, so an access grant is self-documenting:

```yaml
contributor: []
reader: []
admin:
  - upn: jordan.blake@example.com
    reason: "Structural authority over the Foundation subtree."
```

### Key concepts

- **`sideload`** — area-path *visibility only*. The path joins the listed teams'
  boards and grants no permission whatsoever. Structural authority always stays
  with a team's home area.
- **`admin` role** — delegated *structural* authority over a subtree (its area
  paths, teams, and settings). It is not team membership and grants no code
  access.
- **`scope: future`** — a structural placeholder. Invisible to `apply` and
  `audit`. Remove the flag when the product enters active migration.
- **`systems`** — reusable sub-elements (e.g. a `bug-inbox`) stamped onto a team
  as child areas of its home area. Uniform across every team that applies one,
  and carrying zero security.

---

## Authentication

**Entra is the default.** Runs authenticate as the signed-in `az` identity —
interactively via `az login`, or in CI via OIDC. Entra tokens carry the
identity's real permissions: no PAT scopes to configure, no secret to store, and
they work in organisations that forbid full-access PATs.

Mode resolution:

1. manifest `auth: pat` → use the `accessToken` PAT (an explicit opt-out of Entra)
2. otherwise, an `az` session is present → **entra**
3. otherwise, `accessToken` resolves → **pat**, with a warning (CI fallback)
4. otherwise → error, telling you to `az login`

Whichever mode you are in, run `doctor` first. It probes every permission family
against the live organisation using reads plus intentionally invalid writes that
Azure DevOps rejects *after* the permission check — an HTTP 400 proves access,
and nothing is ever created.

If you must use a PAT, the required scopes are listed in
[CONTRIBUTING.md](CONTRIBUTING.md#required-pat-scopes). Note that security ACL
writes need permissions no PAT scope short of full access grants; the engine
falls back to an Entra token from your `az login` session for those.

---

## Repository layout

```text
build.ps1            # CLI entry point, for working on the engine directly
programs/            # always empty here — program definitions live in the
                     #   consuming workspace repo, never in this one
system/NKDAgility.AzureDevOps.Governance/
  Private/Compile/   # build stage: Import -> Resolve -> Write/Test
  Private/AzureDevOps/   # thin wrappers over the Azure DevOps REST API
  Private/Compliance/    # the reconcile loop shared by plan/apply/audit
  Public/            # exported cmdlets, one per command verb
  Templates/         # what gets scaffolded into a consuming workspace
  Agents/            # guidance for AI agents using this as a capability
.agents/             # guidance for AI agents and contributors working ON the engine
  decisions/         # architecture decision records
tests/               # Pester tests
out/                 # generated artefacts (gitignored)
```

---

## Architecture decisions

The reasoning behind the non-obvious choices is recorded in
[`.agents/decisions/`](.agents/decisions/):

| ADR | Decision |
| --- | --- |
| [ADR-001](.agents/decisions/ADR-001-implementation-language.md) | PowerShell over Go — right for internal tooling |
| [ADR-002](.agents/decisions/ADR-002-targeted-rest-checks.md) | Targeted REST checks over bulk fetches — bulk listing causes OOM on large projects |
| [ADR-003](.agents/decisions/ADR-003-apply-is-corrective.md) | Apply is corrective, not just additive |
| [ADR-004](.agents/decisions/ADR-004-scope-future-filtering.md) | `scope: future` nodes are structural placeholders, filtered from apply and audit |
| [ADR-005](.agents/decisions/ADR-005-iteration-compliance-rule.md) | Old governance iterations are compliant by definition |
| [ADR-006](.agents/decisions/ADR-006-tag-anchor-work-item.md) | Sanctioned tags are made to exist via an anchor work item |

---

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) — it
covers the two non-negotiable rules (run the tests; never fail silently), the
checklist for adding a new governed resource type, and how to run the suite:

```bash
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Normal"
```

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). To report
a security issue, see [SECURITY.md](SECURITY.md) — please do not open a public
issue.

## License

[GNU AGPL v3](LICENSE) © naked Agility Ltd (Martin Hinshelwood & Co.)

If you run a modified version of this engine as a network service, the AGPL
requires you to offer that modified source to its users.
