# ADR-004 — scope:future filters products from apply and audit

**Date:** 2026-07-08
**Status:** Accepted

## Context

`hierarchy.yaml` contains products that are known but not yet in the active migration scope:

```yaml
- { name: Trace Log,  dpm: 107, short: TLG, scope: future }
- { name: Integrate,  dpm: 108, short: INT, scope: future }
- { name: PTS,        dpm: 109, short: PTS, scope: future }
```

These products need to be represented in the hierarchy for completeness (DPM references, area path placeholders) but should not have teams provisioned, area paths created, or groups configured until they enter active migration.

Without filtering, `apply` was creating teams for these products and then immediately failing to configure their work settings — ADO returns an authorization error when work settings are accessed on a team that was just created in the same API call sequence.

## Decision

**Products marked `scope: future` are invisible to `apply` and `audit`.**

- The `scope` property is propagated from product nodes to their team objects in `Resolve-Governance.ps1`.
- `apply` skips area path creation, team creation, area config, group creation, and membership for any team with `scope: future`.
- `audit` must also skip `scope: future` teams — their absence from ADO is not a finding.

To bring a product into scope: remove the `scope: future` line from `hierarchy.yaml`, run `build`, then `apply`. From that point on, `audit` will enforce compliance for it.

## Consequences

- `scope: future` products remain in the resolved YAML as structural records but carry a `scope: future` flag.
- Operators can see the full intended hierarchy at any time without committing to provisioning it.
- The `scope` flag is the only mechanism for deferring a product — there is no other way to suppress provisioning for a specific product.
