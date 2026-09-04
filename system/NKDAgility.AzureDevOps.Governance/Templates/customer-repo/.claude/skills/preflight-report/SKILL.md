---
name: preflight-report
description: >
  Write the Observations fragment for one team's governance preflight fix
  report, from its data file and findings file, under strict no-invented-
  numbers rules. WHEN: asked for preflight observations for a team, or
  invoked by the audit-preflight workflow through the preflight-reporter
  agent. Never for writing the report itself — the renderer owns that.
---

# Preflight observations

## What this is

The preflight pipeline produces, per team, three machine-written files in
`<output>\preflight\<CODE>\`, each named
`<program>-preflight-<CODE>-<part>`:

| File part | Written by | Holds |
| --- | --- | --- |
| `-data.json` | the gather | facts: work items per source area path, tag and iteration usage, source-team population, authored-UPN resolution |
| `-findings.json` | the analysis | findings as objects: `class`, `check`, `subject`, counts, examples, `message`, plus any rule / task / lane labels the program attached |
| `-report.md` | `ConvertTo-GovernancePreflightReport` | the complete fix report — every table, every count |

The report already says **what** was found. Your job is the one section it
cannot write: what the shape **means**. You write that to a fourth file,
`-observations.md` in the same folder, and the renderer splices it in on its
next pass.

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
4. **Use the labels, not your own scheme.** If findings carry `rule`, `task`
   or `lane`, refer to those exactly. If they carry none, name the check id.
   Never invent a rule number or a document name.
5. **No recommendations the program has not made.** You may say "this looks
   like a capability tag in the labelled sense"; you may not decide the tag
   name, the fold, or who does the work. Those are the team's returns.
6. **No people by name.** UPNs appear in the findings for a reason; they do
   not appear in a document that gets forwarded.
7. **If the findings contain a `preflight.error`, write one bullet saying the
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
