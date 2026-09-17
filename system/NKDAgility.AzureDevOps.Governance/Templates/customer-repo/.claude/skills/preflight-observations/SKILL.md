---
name: preflight-observations
description: >
  Write ONE team's Observations fragment for a governance preflight fix report
  that has ALREADY been gathered and rendered, under strict no-invented-numbers
  rules. It reads existing files and writes one prose fragment. It does NOT
  gather from Azure DevOps, does NOT run the analysis, and does NOT render the
  report — for the whole pipeline use /audit-preflight instead. WHEN: asked for
  preflight observations for a named team, or invoked by the audit-preflight
  workflow through the preflight-reporter agent.
---

# Preflight observations

## This skill does one thing

It writes the commentary for a team whose report already exists. Read that
twice: **it does not refresh anything.**

| | |
|---|---|
| **Does** | write `-observations.md` for one team |
| **Does not** | gather from the source organisation, run the analysis, or render the report |
| **For the whole pipeline** | `/audit-preflight` — gather, analyse, render, observe, check, publish |
| **To see the fragment in the report** | `Invoke-Governance preflight-report <program>` afterwards |

If the data is stale, this skill will happily comment on stale data. It has no
way to tell and no way to fix it. When in doubt, run `/audit-preflight`, which
gathers fresh every time.

## What you are writing into

The pipeline produces, per team, three machine-written files in
`<output>\preflight\<CODE>\`, each named `<program>-preflight-<CODE>-<part>`:

| File part | Written by | Holds |
| --- | --- | --- |
| `-data.json` | the gather | facts: work items per source area path, tag and iteration usage, source-team population, authored-UPN resolution |
| `-findings.json` | the analysis | findings as objects: `class`, `check`, `subject`, counts, examples, `message`, plus any rule / task / lane labels the program attached |
| `-report.md` | `ConvertTo-GovernancePreflightReport` | the complete fix report — every table, every count |

The report already says **what** was found. Your job is the one section it
cannot write: what the shape **means**. You write that to a fourth file,
`-observations.md` in the same folder, and the renderer splices it in on its
next pass.

**Your fragment is withheld if it is older than the findings.** The renderer
compares modification times and refuses to splice commentary written against a
superseded analysis, because that is how a report ends up contradicting its own
tables. So write against the findings that are there now, and re-render after.

## Contract

- **Read:** the `-data.json`, the `-findings.json`, and the rendered
  `-report.md` if it exists (to see what is already said).
- **Write:** the `-observations.md` in the same folder, at exactly the path
  you were given. Nothing else. Not the report, not the program, not
  `resolved.yaml`, nothing under `.system\`.
- **Shape:** plain markdown bullets. No headings. Four to ten bullets. Bold
  the first few words of each. One or two sentences per bullet.
- **Return:** the path you wrote, how many bullets, and the list of every
  number that appears in your text (as strings, exactly as written).

## Rules — mostly prohibitions, all absolute

1. **Do not restate a count the report already prints.** Refer to it ("the
   three largest sub-areas", "the family of session ids"). The tables are the
   facts; you are the commentary.
2. **Every number you do write must exist verbatim in the data file or the
   findings file.** Percentages, ratios, and "about" figures are computations
   you made, not facts you found. If you cannot point at the number, do not
   write it. A checker agent will look for every number you used; a number it
   cannot find fails the fragment.
3. **Say what the shape means.** Concentration (a few paths hold most of the
   work), duplicates spelt two ways, families that are one thing (four crash
   dump paths that are one triage board), overlaps with the sanctioned
   vocabulary, things the counts imply but do not state (empty paths, a
   BACKLOG path that a rule says folds away). That is the whole job.
4. **Propose destinations for the undecided tags, in the report's own three
   buckets.** Every tag with no destination decided has to become one of:
   **sanctioned** (it names what the work *is*, and it stays), a **board
   column** (it names where the work has *got to* — "test passed", "kicked
   off", "triaged" — so a column carries it and the tag stops being applied),
   or **retired** (nothing depends on it). Group your suggestions that way and
   say which bucket and why. Two cautions: a tag applied by tooling the team
   does not control cannot be retired by the team, so it has to be sanctioned
   or it becomes a permanent exception; and never propose a destination for a
   tag the report already shows as decided.
5. **Use the labels, not your own scheme.** If findings carry `rule`, `task`
   or `lane`, refer to those exactly. If they carry none, name the check id.
   Never invent a rule number or a document name.
6. **Propose, never decide.** A destination you suggest is a proposal for the
   team to accept or reject; it is not settled until it is in the program
   config. Do not invent tag names, decide a fold, or assign who does the work.
7. **No people by name.** UPNs appear in the findings for a reason; they do
   not appear in a document that gets forwarded.
8. **If the findings contain a `preflight.error`, write one bullet saying the
   gather failed and why, and stop.** Do not interpret partial data.

## What good looks like

- **The work is concentrated.** The three largest sub-areas hold most of the
  items on the path table; the twelve smallest hold fewer than fifty each and
  three are empty, which makes them candidates for "no replacement" in the
  fold mapping (task 2).
- **Two tags are one tag.** `Kicked off` and `Kicked-off` are the same marker
  spelt two ways; the same is true of `Test passed` and `Test case passed`.
  Pick one before proposing either for the vocabulary.
- **The crash-dump paths are one thing.** Four sibling paths named for crash
  dumps are the second triage inbox the labels already allow for, not four
  areas to fold separately.

## What bad looks like

- "Nine paths hold 95% of the work." — a percentage you computed.
- "There are 549 unsanctioned tags." — already in the summary table.
- "Rename ELITE_SUBMISSION to elite-submission." — a decision that is theirs.
- "This breaks rule B7." — a rule number that is not in the labels.
