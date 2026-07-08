# ADR-002 — Targeted REST checks over bulk tree fetches

**Date:** 2026-07-08
**Status:** Accepted

## Context

The initial `apply` implementation pre-fetched the entire area path tree with:

```powershell
az boards area project list --organization $OrgUrl --project $Project --depth 50
```

On a large project (Odyssey has hundreds of existing area paths), this produced an `OutOfMemoryException` in PowerShell's `ConvertFrom-Json`. Reducing `--depth` to 10 did not resolve the issue because the response was still too large.

The same risk exists for any bulk-list operation (team list, group list, folder list) on a project that has grown over time.

## Decision

**Prefer targeted `GET /resource/{id}` existence checks over `GET /resource` (list all).**

Concrete pattern:

```powershell
# BAD — loads entire tree, OOMs on large projects
$existingAreas = Get-AdoAreaPathSet -OrgUrl $orgUrl -Project $project

# GOOD — one small REST call per path we're about to touch
if (Test-AdoAreaPath -OrgUrl $orgUrl -Project $project -ResolvedPath $path) { continue }
```

Every `Test-Ado*` function calls a single REST endpoint for the specific resource. The response is tiny regardless of project size.

## Consequences

- `apply` makes N small REST calls (one per resource being reconciled) instead of 1 large call.
- For the current Odyssey resolved model (24 area paths, 19 teams) this is ~43 REST calls instead of 2 bulk fetches — completely acceptable.
- `Test-Ado*` functions **must re-throw on non-404 errors**. Swallowing all exceptions and returning `$false` causes a spurious create attempt, which then fails with a confusing error.
- Bulk `Get-Ado*` functions are still useful for audit (where you need the full live state to find orphans) but should not be used in `apply`'s hot path.
