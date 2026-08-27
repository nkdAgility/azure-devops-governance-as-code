# Azure DevOps Governance-as-Code

[![CI](https://github.com/nkdAgility/azure-devops-governance-as-code/actions/workflows/ci.yml/badge.svg)](https://github.com/nkdAgility/azure-devops-governance-as-code/actions/workflows/ci.yml)
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

**Prerequisites**

- [PowerShell 7.4+](https://github.com/PowerShell/PowerShell)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the
  `azure-devops` extension (`az extension add --name azure-devops`)
- The `powershell-yaml` module (`build.ps1` installs it if missing)

```bash
git clone https://github.com/nkdAgility/azure-devops-governance-as-code.git
cd azure-devops-governance-as-code
az login
```

Create a program folder at `programs/<name>/` (see [Defining a
program](#defining-a-program)), then work up the safety ladder — everything
except `apply` is read-only:

```bash
pwsh ./build.ps1 doctor   -Program myprogram   # can my identity do this?
pwsh ./build.ps1 build    -Program myprogram   # compile YAML -> out/myprogram/resolved.yaml
pwsh ./build.ps1 plan     -Program myprogram   # what would change?
pwsh ./build.ps1 apply    -Program myprogram -WhatIf
pwsh ./build.ps1 apply    -Program myprogram   # reconcile for real
pwsh ./build.ps1 audit    -Program myprogram   # should now be zero findings
```

Program definitions do not have to live in this repo. Point `-ProgramsRoot` at
any folder — that is how the engine is used against configuration kept in a
separate, private repository:

```bash
pwsh ./build.ps1 audit -Program myprogram -ProgramsRoot ../my-config/governance/programs
```

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
programs/<name>/
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
build.ps1            # single entry point for every command
programs/            # empty by default — your program definitions go here,
                     #   or live elsewhere and are passed via -ProgramsRoot
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
