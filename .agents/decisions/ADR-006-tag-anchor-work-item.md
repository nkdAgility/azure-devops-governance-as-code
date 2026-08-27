# ADR-006 — Sanctioned tags are made to exist via an anchor work item

**Status:** accepted
**Supersedes:** the "existence of sanctioned tags is not audited" carve-out in Decision-0041

## Context

The governed tag taxonomy (`taxonomy.yaml` `tags.sanctioned`) is the allowed
vocabulary for work item tags. Until now the engine only checked one direction:
a tag in ADO that was not sanctioned became an audit exception. A sanctioned tag
that did not exist was ignored.

That is a hole in the core ethos. *Config is truth; any difference is a
violation.* A vocabulary nobody can pick from is not compliant — it is a
governance document with no effect. On a live program the hole was total:
`GET /{project}/_apis/wit/tags` returned `{"count":0}` while ten tags were
sanctioned in config.

The carve-out existed for a real reason. Azure DevOps gives no way to create a
bare tag:

- `POST /{project}/_apis/wit/tags` returns **405 Method Not Allowed**. The Tags
  API is Get / List / Update (rename) / Delete only — there is no create verb.
  Verified against a live organisation with an authorized identity (`GET` on the same
  route returns 200, so the 405 is a genuine method rejection, not auth noise).
- A tag comes into existence only when it is applied to a work item.
- Azure DevOps runs a background job that deletes tags no work item references.
  So even if a tag could be conjured, it would not survive.

## Decision

`apply` maintains exactly **one governance-owned work item per project** — the
*tag anchor* — whose tag set is exactly the sanctioned vocabulary. Holding the
tags on a work item is the only mechanism ADO offers, and it satisfies both
halves of the requirement: the tags exist in the picker for every user, and the
purge job leaves them alone because they are referenced.

Consequences for each command:

| Command | Behaviour |
|---|---|
| `audit` | A sanctioned tag not present in ADO is a `MISSING tag` finding. |
| `apply` | Creates the anchor if absent; otherwise corrects its tag set (ADR-003). Then re-reads the live tag set and reports anything still missing. |
| `apply -WhatIf` | Reports `would seed tag: <name> (via anchor work item)`. |

The anchor is found by WIQL on its title, not by a stored id, so a fresh clone
with no state file finds the existing anchor instead of creating a duplicate.

The anchor carries the sanctioned set **and nothing else**. This is what keeps
the two directions from fighting: if the anchor were allowed to keep a tag that
had been de-sanctioned, that tag would immediately be reported as an audit
exception, and `-Prune` would delete it out from under the anchor.

## Why not the alternatives

**Report missing tags but never create them.** Honest and side-effect free, but
it breaks the invariant that `audit` returns zero findings after `apply`.
A real program would carry ten permanent, unfixable findings, and a compliance
report that can never reach green trains people to ignore it.

**Report them as a non-blocking class.** Preserves the invariant by redefining
the problem away. Tag existence would not actually be enforced, which is the
thing that was asked for.

## Costs, accepted

- The engine now writes **work item data**, a side-effect class it did not have
  before. It is confined to one item per project, created only when a taxonomy
  declares an anchor.
- The anchor is a real work item and will appear in unfiltered queries and
  backlogs. `tags.anchor.areaPath` and `tags.anchor.state` exist to park it out
  of the way (e.g. `state: Removed`).
- Deleting the anchor deletes the vocabulary with it, once the purge job runs.
  The item's description says so; the next `apply` recreates it.
- The anchor's work item type must exist in the project's process. Apply
  validates it against `GET /wit/workitemtypes` and fails with the list of valid
  types rather than a raw REST error.

Set `tags.anchor.enabled: false` to opt out. Missing tags are then still
reported, with the finding stating plainly that apply cannot fix them.
