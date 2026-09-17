# ADR-010: The migration query is a committed WIQL fragment, and it scopes preflight

Date: 2026-09-07
Status: accepted

## Context

Preflight counted every work item under a team's source area. A long-lived
area is mostly archive: in the field, one team's subtree held nearly twenty
thousand work items, the largest iteration paths were all under `ARCHIVE`, and
most of the eight and a half thousand distinct tags rode on work that was
never going to move. The team was therefore handed a fix list covering work
items nobody would migrate.

Two facts settle the shape of the fix. A migration programme already decides
what moves — a release-line boundary, a date, a state filter — and the
migration toolchain already needs that decision expressed as WIQL, because its
own configuration takes a `WIQLQuery`. So the decision exists, and its natural
form is a query; it simply had nowhere to live where governance could see it.

## Decision

1. **`sources.yaml` gains `scope:`** — the migration query, at program level
   with an optional per-node override:

   ```yaml
   scope:
     label: "2026.1 and onwards"
     query: "[System.IterationPath] NOT UNDER 'Proj\\ARCHIVE'"
   ```

2. **It is a boolean FRAGMENT, not a whole query.** The engine owns the
   project, area-path and `System.Id` paging predicates — those are what make
   the gather correct and complete — and ANDs the authored fragment into them
   **wrapped in parentheses**. Without the parentheses an authored `A OR B`
   would bind against the area predicate and silently widen the query past the
   subtree. `Test-GovernanceSources` rejects anything containing `SELECT`,
   `FROM WorkItem`, `ORDER BY` or `;`.

3. **A saved Azure DevOps query is deliberately not the input.** It would be
   friendlier for a product manager to build one in the UI, but a shared query
   is mutable state outside version control: it can be edited by anyone at any
   time, and a preflight report is engagement evidence. Evidence whose
   population depends on a mutable pointer is not reproducible. The fragment
   is committed, diffable and reviewable, and it is the same text the
   migration toolchain configuration needs, so one decision serves both.

4. **The scope is recorded with the facts it produced.** `data.json` carries
   the query and label alongside the counts, so the analysis and renderer can
   state what the numbers cover. `-SkipFresh` compares the configured query
   against the one recorded in the data file and re-gathers when they differ:
   a file gathered under a different query describes a different population,
   however recent it is.

5. **An unscoped run says so, in the report header.** "Every work item under
   the area, archive included — no migration query declared" is the prompt
   that gets the query written. Silence would read as a scoped result.

## Consequences

- Findings shrink to the population that is actually moving, so a team's fix
  list is work it will really have to do.
- Governance and the migration toolchain share one authored decision. If they
  drift, that is now visible in a diff rather than invisible in two configs.
- The area-path subtree check is unaffected: it reads classification nodes,
  not work items, so a path with no in-scope work items is still an orphan
  that would arrive. Its work-item count simply becomes the in-scope count,
  which is the number a fold decision should be based on.
- Changing the query invalidates every gathered data file, by design. The
  re-gather is a live call against the source organisation.

## Amendment — 2026-09-17: complete query owns source areas

The fragment restriction in Decision 2 is superseded. A migration scope is a
committed flat `SELECT [System.Id] FROM WorkItems WHERE ...` WIQL query. The
query owns project and source area selection, so it can name multiple areas.
The engine retains complete ID paging by adding a `System.Id` cursor predicate
and ordering each page by ID; authored ordering is replaced during gather.

The configured `areaPath` remains the root for projecting source structure
into the target hierarchy. Selected work items outside that root are included
in tag, iteration and work-item counts, and their source paths are reported as
unmapped areas needing explicit target placement before migration. The
version-controlled query and query-change re-gather rules above still apply.
