<!--
Thanks for contributing. Please read CONTRIBUTING.md if you have not already —
in particular the two non-negotiable rules: run the tests, and never fail
silently.
-->

## What changed

<!-- A short description of the change. -->

## Why

<!-- The problem this solves. Link an issue if one exists: Fixes #123 -->

## Checklist

- [ ] `pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Normal"` passes
- [ ] Tests added or updated to cover the change
- [ ] No new code path returns `$null`, `$false`, or an empty set on failure — failures throw
- [ ] Comments explain *why*, not *what*

If this adds or changes a **governed resource type**, also confirm:

- [ ] Resolved model updated (`Resolve-Governance.ps1`)
- [ ] `apply` both **creates** missing resources and **corrects** misconfigured ones
- [ ] `audit` reports missing, extra, and misconfigured cases with distinct, actionable findings
- [ ] `plan` shows the diff before it is made
- [ ] `doctor` probes any new API family the change depends on
- [ ] An `audit` run immediately after `apply` would produce zero findings

If this is a **structural change**, also confirm:

- [ ] An ADR has been added under `.agents/decisions/`, and listed in both `README.md` and `.agents/agents.md`

## Live verification

<!--
Optional — the test suite is offline, so this is not required. If you did run
against a real organisation, say which commands you ran and what you saw.
Anonymise the output. Never test against an organisation you do not control.
-->
