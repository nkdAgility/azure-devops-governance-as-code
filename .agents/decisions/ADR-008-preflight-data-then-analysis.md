# ADR-008: Preflight gathers a data document first, then analyses it offline

Date: 2026-09-04
Status: accepted

## Context

The first preflight (ADR-007) interleaved live reads and evaluation in one
pass and emitted findings as strings. Running it against a real legacy area
exposed three problems at once:

- **Data and judgement were fused.** The JSON twin was the text report's
  strings serialised, so nothing downstream — a fix-report renderer, a
  readiness dashboard, a fold-mapping template — could consume the facts
  without parsing prose.
- **Re-analysis meant re-reading.** Tightening one tag pattern meant paging
  through every work item under the source area again (tens of thousands),
  and a Conditional Access rejection on the second run meant no analysis at
  all, even though nothing about the source had changed.
- **Volume.** One area produced 8,500 individual tag findings. A team cannot
  act on that; the shape of the output has to be designed for the reader, and
  that is easier when rendering is separate from gathering.

## Decision

1. **Gather writes facts, analysis reads them.** `Get-GovernancePreflightData`
   reads the source organisation (area subtree with work items per path, tag
   and iteration usage, matched repos, source-team population) and the target
   organisation (authored UPN resolution) and returns a plain document, which
   preflight writes to `preflight-<code>.data.json` beside `resolved.yaml`.
   `Resolve-GovernancePreflightFindings` takes that document plus the node's
   slice of the resolved model and runs the shared evaluators. It is pure and
   is what the Pester tests exercise.

2. **`-Offline` re-analyses the last gathered data** without touching either
   organisation. The data file is only ever overwritten by a successful
   gather: a failed gather records an error finding and leaves the previous
   data in place.

3. **Findings are objects.** Every finding carries `class` (the JSON classes
   the report writer already used), a stable `check` id
   (`area.orphan`, `tag.disallowed`, `tag.unsanctioned`, `repo.orphan`,
   `member.unresolvable`, `teamAdmin.unresolvable`, `member.unauthored`,
   `preflight.error`), a `subject`, check-specific fields (work item counts,
   examples, source path, group, suggestions), and a `message` that keeps the
   legacy prefix so the text report reads as before. The JSON twin holds the
   objects; the text report renders the messages.

4. **Engagement vocabulary is attached, not built in.** `sources.yaml` may
   carry a top-level `labels:` map keyed by check id; its fields (a rule
   number, an owner lane, a task id — whatever the engagement's team-facing
   standard uses) are copied onto every finding of that check. The engine
   knows nothing about any customer's document; the customer's program maps
   the engine's checks onto it. Unknown check ids fail validation.

5. **Disallowed tag patterns bundle.** A pattern family is one finding with
   the distinct-tag count, the work-item count and the five most-used
   examples. Individual unsanctioned tags stay individual — they are the
   vocabulary decision the team has to make.

## Consequences

- The data document contains UPNs from the source population. It belongs in
  the customer workspace's output folder (gitignored) or committed there as
  engagement evidence — never in this repository or its fixtures.
- Audit and apply are untouched: the reconcile still emits strings and the
  report writer still classifies strings by prefix when given strings.
- Preflight's text report format is unchanged apart from a `Data :` header
  line; its JSON `findings[]` entries gain fields but keep `class` and
  `message`, so existing consumers of those two keys keep working.
- `Get-AdoWorkItemUsageUnderArea` now also counts work items per area path,
  one extra field in the same batched read.
