# Contributing

Thanks for considering a contribution. This document covers everything you need
to make a change that will be accepted.

For the deeper narrative — what "compliant" means for each resource type, the
hierarchy grammar in full, the iteration cadence rules — see
[`.agents/agents.md`](.agents/agents.md). That file is the canonical engineering
guide for this repository and is kept current.

---

## Two non-negotiable rules

**1. After every code change, run the tests.**

```bash
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Normal"
```

If the tests fail, fix the failure before doing anything else. Do not move on,
do not open the PR, do not commit around it.

**2. Silent errors are never acceptable.**

If a function cannot complete its work, it must **throw**. Returning `$null`, an
empty set, or `$false` when a call fails is a bug, not a defensive style choice.
Every caller depends on the error surfacing immediately — a swallowed exception
in a `Test-Ado*` function returns `$false`, which the reconciler reads as "does
not exist", which triggers a spurious create against a live organisation.

Concretely: `Test-Ado*` functions must re-throw on any non-404 error.

---

## Getting set up

**Prerequisites**

- [PowerShell 7.4+](https://github.com/PowerShell/PowerShell)
- [Pester](https://pester.dev/) 5.x — `Install-Module Pester -Scope CurrentUser`
- `powershell-yaml` — `Install-Module powershell-yaml -Scope CurrentUser`
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) with the
  `azure-devops` extension — only needed for live commands, not for the tests

```bash
git clone https://github.com/nkdAgility/azure-devops-governance-as-code.git
cd azure-devops-governance-as-code
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Normal"
```

The whole test suite is **offline**. It compiles the frozen sample program in
`tests/fixtures/programs/odyssey/` and asserts the resolved model, so it needs no
Azure DevOps organisation, no credentials, and no network. If a change you are
making would require a live call to test, that is a strong signal the logic
belongs in the compile stage instead.

---

## Making a change

1. Fork the repository and branch from `main`.
2. Make the change, matching the surrounding style (see below).
3. Add or update Pester tests. A behaviour change with no test change is
   usually an incomplete change.
4. Run the full suite. It must be green.
5. Open a pull request describing *what* changed and *why*. Link an issue if one
   exists.

### Adding a new governed resource type

This is the most common substantial contribution. Work through it in order —
each step depends on the last:

1. **Resolve** — add the resource to the resolved model in
   `Private/Compile/Resolve-Governance.ps1`.
2. **Test** — add a Pester test in `tests/Compile.Tests.ps1` asserting the
   resolved shape. Do this before writing any live code.
3. **ADO helper** — add `Test-Ado*` and `New-Ado*` functions (and `Get-Ado*` if a
   batch read is safe) to `Private/AzureDevOps/AzureDevOps.ps1`. Prefer targeted
   `GET /resource/{id}` calls over `GET /resource` list-alls — see
   [ADR-002](.agents/decisions/ADR-002-targeted-rest-checks.md); bulk fetches
   cause out-of-memory failures on large projects.
4. **Apply** — add the reconciliation step. Check existence first, then create
   **or correct**. Creating what is missing is only half the job; see
   [ADR-003](.agents/decisions/ADR-003-apply-is-corrective.md).
5. **Audit** — add the compliance check. Every finding must be a distinct,
   actionable string that names the resource and what is wrong with it.
6. **Plan** — add the diff logic so the change is visible before it is made.
7. **Doctor** — if the resource calls a new API family, add a probe to
   `Get-AdoScopeProbeSet` so `doctor` can verify access to it.

Miss step 4 or 5 and the engine will report a resource as compliant when it is
not, which is worse than not governing it at all.

### Style

- Match the conventions of the file you are editing — naming, comment density,
  and idiom.
- All live calls go through `Invoke-AdoRest`.
- Comments should explain *why*, not restate *what*. The existing codebase is a
  good guide: comments earn their place by recording a constraint or a rejected
  alternative.
- Public functions get comment-based help with a `.SYNOPSIS`.

### Architecture decisions

Structural changes deserve an ADR in [`.agents/decisions/`](.agents/decisions/).
Follow the existing format: **Context** (what forced the decision), **Decision**,
**Why not the alternatives**, and **Costs, accepted**. Recording the rejected
options is the valuable part — it stops the same debate being reopened in six
months. Add new ADRs to the tables in both `README.md` and `.agents/agents.md`.

---

## Running against a real organisation

You do not need to do this to contribute — the tests are offline. If you want to
exercise the live path, use a scratch Azure DevOps organisation you own. Never
test against an organisation you do not control.

Always work up the safety ladder: `doctor` → `build` → `plan` → `apply -WhatIf` →
`apply`. `apply` is the only command that writes, and `-Prune` deletes.

### Required PAT scopes

Entra (`az login`) is the default and preferred authentication mode, and carries
your real permissions. If you must use a PAT instead, it needs these scopes:

| Scope | PAT UI name | Needed for |
| --- | --- | --- |
| `vso.project_manage` | Project & Team — Read, write & manage | Creating projects and teams |
| `vso.work_write` | Work Items — Read & write | Area/iteration paths, team settings |
| `vso.code_manage` | Code — Read, write & manage | Creating repos |
| `vso.build_execute` | Build — Read & execute | Pipeline folders |
| `vso.graph_manage` | Graph — Read & manage | Groups and membership |
| `vso.memberentitlementmanagement` | Member Entitlement Management — Read | Resolving member UPNs to descriptors |
| `vso.security_manage` | *(not offered in the PAT UI)* | Pipeline folder ACLs, structural authority |

The last row is why Entra matters: security ACL writes need permissions no PAT
scope short of full access grants, and many organisations forbid full-access
PATs. The engine falls back to an Entra token from your `az login` session for
those writes. Run `doctor` to see exactly which route is covering what — it
reports the identity it is testing and any gaps.

A missing write scope typically surfaces mid-apply as `The requested resource
requires user authentication` (HTTP 401). Run `doctor` whenever you see that.

---

## Reporting bugs and requesting features

Open an issue using the appropriate template. For bugs, the most useful thing you
can include is the anonymised YAML that reproduces the problem plus the output of
`build` or `audit` — remember to strip organisation names, project names, and
UPNs before posting.

**Do not report security vulnerabilities in a public issue.** See
[SECURITY.md](SECURITY.md).

---

## Code of Conduct

Participation in this project is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## License

By contributing, you agree that your contributions will be licensed under the
[GNU Affero General Public License v3.0](LICENSE).
