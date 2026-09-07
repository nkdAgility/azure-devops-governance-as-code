# ADR-011: A tag that is not sanctioned still needs a destination

Date: 2026-09-07
Status: accepted

## Context

The tag model had two outcomes: a tag was sanctioned, or it was an exception.
That is enough for the target, where an exception is simply drift to remove.
It is not enough for a team being asked to reshape before it migrates, which
was the situation preflight put people in: one team's report listed 549
unsanctioned tags as a single undifferentiated block and effectively said
"decide something about each of these".

Reviewing a real report showed those tags are not one problem but three, and
that the difference decides who does the work:

- Some **cannot be changed by the team at all.** A tag applied by tooling
  outside their control will keep arriving whatever they do. Left
  unsanctioned it becomes a permanent audit exception in the target, and a
  candidate for deletion under `-Prune`, forever.
- Some **name where work has got to, not what it is** — "test passed",
  "kicked off", "triaged". That is a board column wearing a tag's clothes.
  Adding it to the vocabulary entrenches the workaround; the fix is a column,
  after which nobody applies the tag.
- Some are simply noise and should go.

## Decision

1. **`taxonomy.yaml` gains two disposition lists** beside `sanctioned`:
   `boardColumns` (the concept becomes a board column) and `retire` (delete,
   no replacement). Precedence when classifying a live tag: disallowed
   pattern, then sanctioned, then board column, then retire, then undecided.

2. **A tag has exactly one destination.** The build throws when a tag appears
   in more than one of `sanctioned`, `boardColumns` and `retire`. Whoever
   reads the report should never have to work out which list won.

3. **Preflight reports the three separately** — `tag.boardColumn` and
   `tag.retire` as drift (work to do, and different work with a different
   owner from a vocabulary decision), and `tag.unsanctioned` now meaning
   *no destination decided yet*, which is the team's actual worklist. Each
   check can carry its own rule, task and owner lane through `labels:`.

4. **"Cannot be changed" means sanction it.** There is no separate
   "tolerated" state, and there should not be: the target audit knows only
   the sanctioned vocabulary, so an immovable tag that is not sanctioned is
   an exception every day forever. The report and the observation rules both
   push that decision toward `sanctioned` rather than inventing a fourth
   bucket that the audit could not honour.

## Consequences

- Audit and apply are unchanged. A tag destined for a column or for
  retirement is still not sanctioned, so in the target it is still an
  exception — which is correct, because by then it should be gone.
- `Test-GovernanceTagCompliance` gains two optional parameters and two result
  buckets; existing callers that pass neither behave exactly as before.
- The report's tag section splits into board columns, retirements, and
  undecided, so the question put to a team is "which of three" rather than
  "what do you want to do about 549 tags".
- The disposition is config, so it is diffable, reviewable, and reusable
  across every team in the programme rather than re-litigated per team.
