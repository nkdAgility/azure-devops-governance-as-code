# ADR-003 — Apply is corrective, not just additive

**Date:** 2026-07-08
**Status:** Accepted

## Context

A naive interpretation of "apply" is: check if a resource exists; if not, create it; if yes, skip it. This is the provisioner model.

This system is a **compliance engine**. A resource that exists but is misconfigured is just as wrong as a resource that doesn't exist. Silently skipping it leaves the org in a non-compliant state with no indication anything is wrong.

## Decision

**`apply` must create missing resources AND correct misconfigured ones.**

Examples of what "correct" means:

| Resource | Not just "exists?" but also... |
|---|---|
| Team | Area config matches `areaConfig` exactly — right paths, right `includeSubAreas` flags |
| Security group | Membership matches `members` list exactly — missing members added, extra members removed |
| Pipeline folder | ACL matches `acl` list — wrong permissions patched, extra ACEs removed |

The `Set-AdoTeamAreaConfig` function PATCHes the team's area configuration on every apply run (idempotent). It does not check first — it simply sets the desired state. This ensures convergence.

## Consequences

- `apply` is safe to run repeatedly — it always converges to the desired state.
- After every `apply` run, an `audit` run must produce zero findings. If it doesn't, `apply` has a bug.
- Removing a member from a `members/*.yaml` file and running `apply` must remove them from the ADO group. Governance owns the group; manual additions are not preserved.
- The `-WhatIf` flag must show both creations and corrections.
