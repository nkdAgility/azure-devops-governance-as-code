# ADR-007: Preflight evaluates projected source state through the audit's own evaluators

Date: 2026-09-01
Status: accepted

## Context

Teams migrating into a governed program need to pre-comply in their CURRENT
location — a different organisation, project and area path — before they move.
That means answering, per team: *if this team's content moved into the governed
target today, which compliance checks would fail?*

The reconcile loop could not answer this: it is a whole-project comparison of
one org against the whole resolved model, with live reads, fixes and reporting
interleaved. Pointing it at a source project would report the entire target
structure as missing and everything the source project contains as exceptions.

## Decision

1. **The classification rules live in pure evaluators**
   (`Private/Compliance/Evaluators.ps1`): area orphans/missing, repo
   missing/orphans (project default exempt), tag
   disallowed/unsanctioned/missing (disallowed wins over sanctioned), and
   exact-match member sets (extras suppressed while any desired entry is
   unresolved; extras filtered to user descriptors for groups). The reconcile
   gathers live target state and acts on evaluator verdicts; preflight gathers
   source state, **projects** it into target coordinates (source area subtree
   onto the node's authored path), and runs the same evaluators. Audit and
   preflight can therefore never disagree about what compliant means.

2. **Source locations are authored, per node, in `programs/<name>/sources.yaml`**
   — a seed file (org, project, areaPath, optional source `teams` defining the
   works-there-today population, optional `repos.include` filter, optional
   `accessToken` env-var reference). Validated offline by
   `Test-GovernanceSources` (wired into `validate` and preflight itself).

3. **Preflight is read-only against BOTH organisations** and mirrors audit's
   CI contract: `preflight-<code>.txt` + `.json` per node, non-zero exit on
   findings. Info that is not a finding (authored paths with no source
   counterpart, iteration paths in use, work item counts) goes into an INFO
   section that never affects the count.

4. **Two-org auth swaps module state, Entra first**
   (`Enter-AdoOrgAuth`/`Exit-AdoOrgAuth`): the az session is used when the
   source org accepts its token, else the source entry's PAT reference, else
   the already-configured PAT with a warning (all-orgs PATs exist); no route
   at all throws. State is always restored in a `finally`.

## Scope limits (as important as the checks)

- **No work item type/state/field validation.** Process compatibility belongs
  to the migration toolchain; preflight links to it in its INFO section.
  Rebuilding it here would duplicate a whole validation engine.
- **No target-only checks** (iteration scope roll, backlog visibility,
  pipeline folder ACLs, structural authority ACEs, repo ACL bits): they
  describe state apply creates after migration and cannot fail "pre-move".
- **Nested group entries are not preflighted** — they are audited post-apply;
  preflight resolves user UPNs only (an org-level lookup that works even while
  the target project is empty).
- **The works-there-today population is the source teams' direct user members**
  (declared in `sources.yaml teams:`). Assignee- or contributor-based
  populations were considered and rejected for v1: noisier, and the team list
  is the customer's own definition of who works there.

## Consequences

- The reconcile's console line ordering inside a group section changed
  slightly (unresolvables print before missing members); the finding set,
  messages, report text and JSON are unchanged.
- `Select-GovernanceSubtree` (one node's teams/areas/repos + program-wide
  tags) now exists as the slicing primitive that per-owner finding routing
  (gap-closure Phase 5) will reuse.
- A `sources.yaml` is required before preflight runs; programs without one are
  unaffected everywhere else (the source hash is unchanged when the file is
  absent).
