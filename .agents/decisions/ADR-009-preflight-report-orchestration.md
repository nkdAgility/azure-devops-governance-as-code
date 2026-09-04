# ADR-009: The renderer owns the fix report; agents write one fragment; the engine ships the orchestration

Date: 2026-09-04
Status: accepted
Plan: `.agents/plans/2026-09-04-preflight-report-orchestration.md`

## Context

ADR-008 made preflight produce a facts document and a findings document per
team. The customer-facing markdown that a product manager actually reads was
still being written by hand, in a chat session, with no saved prompt. That is
not reproducible, it is one place where a number can be retyped wrongly, and
an engagement has many teams to do it for.

The workspace loader already delivers `.claude/**` files from an engine's
`Templates/customer-repo/` (the automation tools ship a settings file and a
managed hook that way), and a workflow script can pick the model per agent.

## Decision

1. **A function owns the document.** `ConvertTo-GovernancePreflightReport`
   renders the whole fix report — every count, table and label — from the
   data and findings files. It is idempotent and deterministic (invariant
   culture, `\n` line endings, no run timestamp). Engagement vocabulary comes
   from `sources.yaml` `labels:` and a new optional `reporting:` block
   (standard name, audience, candidate-tag threshold); the engine names no
   customer document.

2. **Anyone else writes exactly one fragment.** Judgement lives in
   `observations-<code>.md`, spliced between two markers in one bounded
   section on the renderer's next pass. A person, another assistant, or the
   shipped skill can write it; none of them can reach a table.

3. **`Invoke-GovernancePreflightReport` is the no-AI path.** It renders every
   gathered team offline. `Invoke-GovernancePreflight -SkipFresh` reuses
   existing data files and contacts no organisation when nothing is left to
   gather, so an interrupted run resumes with only the missing teams.

4. **The engine ships the orchestration as managed templates:** a slash
   command (`/audit-preflight`), the workflow it invokes, two subagent
   definitions, the skill that holds the observation rules, and a hook. Model
   tiers are explicit in the workflow: cheap agents shell out for gather,
   render and publish; one frontier agent per team writes the fragment; a
   cheap checker verifies every number in it exists in the team's data, with
   one retry.

5. **A hook, not a prompt, keeps shell-capable agents away from `apply`.**
   `deny-governance-apply.ps1` refuses any shell command that would run a
   governance apply (except `-WhatIf`). Tool lists are a weak fence around a
   live reconcile; the hook is the fence. Workspaces register it in their own
   `.claude/settings.json`, which the automation engine owns as a seed.

## Consequences

- The observation rules are engine-owned and refreshed on every init, so they
  cannot be weakened locally. Voice and thresholds are workspace config.
- Two frontier-model calls per team at most, and nothing else in the run
  scales with model spend. Agent count is `2N + 4` with the check on, so the
  command batches (default 8) and logs each batch.
- CI can produce every team's document on a schedule with a PAT and no AI.
  The Observations section is the only thing it lacks.
- The gather step remains the only fragile one (Conditional Access sign-in
  frequency). `-SkipFresh` is the mitigation, not a fix.
- The hook only fires once it is registered in the workspace's
  `.claude/settings.json`, which the automation engine owns as a seed. The
  governance capability loader therefore registers its own entry idempotently
  on every session, adding nothing else and never reordering what is there. A
  control that ships but is never wired up is not a control.
