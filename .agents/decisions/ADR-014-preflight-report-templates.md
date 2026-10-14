# ADR-014: A preflight report can be the program's own document, filled with the team's facts

Date: 2026-10-14
Status: accepted

## Context

ADR-009 made the engine own the fix report: a fixed layout of tables, framed by
prose from `reporting:`. Teams then had two documents to read side by side —
the program's team-facing standard (what to do and how) and the fix report
(where they stand) — and the same rules were described in both.

A program asked for one document per team: the standard itself, unchanged,
with the team's position shown at each step and the full lists in appendices.
The standard is written and versioned in the program's own publishing system,
not in this engine, and it changes. Copying it into a template would drift the
first time it was edited.

## Decision

1. **The program's document is the template.** `reporting.template` in
   `sources.yaml` names the `document` (the standard, wherever it lives), a
   `slots` file and an optional `assetPrefix`. Paths are relative to the
   program folder. When `template` is present, `preflight-report` renders
   through `ConvertTo-GovernancePreflightTemplateReport` instead of the fixed
   layout; without it nothing changes.

2. **Markers in the document, wording in the slots file.** The document carries
   HTML-comment markers, invisible when it is published on its own:
   `team:replace NAME … team:end` (a region replaced), `team:slot NAME` (inline
   or whole lines), `team:check NAME` (at the end of a checklist item: the slot
   sets the box and adds the team's detail), `team:fill COLUMN ROWPREFIX` (a
   cell of each row in the table that follows) and
   `team:column HEADER SEPARATOR ROWPREFIX` (a column added to that table).
   The intent is an integrated document: the team's position lives in the
   document's own checklists and tables, not beside them. The slots file says, per marker, what to write.
   The document's authors never see placeholder syntax.

3. **A deliberately small placeholder language** (`Expand-GovernanceTemplate`):
   values, `count`, `sum`, number `words`, `note`, and `each` / `zip` / `if` /
   `unless` blocks with `limit=` and `where=`. No expressions, no functions, no
   arithmetic beyond count and sum. A missing path, unknown helper or unclosed
   block throws. The one exception is `contacts.*`, whose keys are the
   program's: an absent contact reads as empty.

4. **The engine still owns every number.** Slots read only from the model
   (`Get-GovernancePreflightModel`), built from the same data and findings
   documents as before and sorted once, so re-rendering unchanged inputs
   produces unchanged bytes.

5. **Judgement stays in one place.** Team-specific judgement is a section of
   the team's existing observations file (`<!-- note: NAME -->`), quoted by
   `{{note NAME}}`. The ADR-009 rule carries over: notes older than the
   findings are withheld.

6. **Optional per-source `contacts:`** in `sources.yaml` (any keys) is exposed
   to slots. It is not validated beyond being present: what a program calls its
   contacts is the program's business.

## Consequences

- One document per team, regenerated whenever the standard or the data changes.
- The template document is outside this repository, so a program that uses it
  depends on that path being present where reports are rendered.
- The fixed renderer is untouched; programs that do not declare `template` see
  no change.
