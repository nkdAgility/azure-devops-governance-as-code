# ADR-005 — Old iteration paths are compliant by definition

**Date:** 2026-07-08
**Status:** Accepted

## Context

ADO iteration classification nodes accumulate over time. As the rolling window
advances (10 sprints forward per run), previous sprints fall outside the team
scope window but remain in the ADO classification tree. They are not removed.

## Decision

**Iteration paths that match the governance naming pattern are never flagged as
audit exceptions, regardless of age.**

The governance naming pattern is:
```
\Program\YYYY\S[n]\S[n]-W[n]   (sprint)
\Program\YYYY\S[n]               (season)
\Program\YYYY                    (year)
```

The audit/reconcile loop only checks that the **desired** paths exist. It does
not enumerate the ADO iteration tree looking for extras. Old governance-created
iterations are expected to accumulate and are compliant by definition.

Iterations that do NOT match the governance naming pattern (manually created,
wrong format) could be flagged as audit exceptions in a future increment, but
this check is deferred until there is a demonstrated need.

## Consequences

- Running `apply` weekly adds new forward-looking iterations; old ones stay untouched.
- The ADO iteration tree grows monotonically — no automatic cleanup.
- If cleanup is ever needed it must be done manually or via a separate `clean` command.
