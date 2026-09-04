# Preflight report orchestration — one operator command, many teams

Date: 2026-09-04
Status: **proposed** — not implemented. Supersedes nothing; builds on ADR-008.
Origin: a live migration engagement. Its first preflight produced a data file
and a findings file deterministically, and then a customer-facing markdown
document that was written by hand in a chat session with no saved prompt. That
last step is not reproducible, and the engagement has roughly eighteen teams to
do it for.

## The idea in one paragraph

An operator types `/audit-preflight`. A workflow orchestrates the whole run:
cheap agents shell out to PowerShell to gather every team declared in
`sources.yaml` and render a complete, sendable markdown fix report each; an
expensive agent per team then writes *only* the judgement paragraphs, which a
cheap agent splices back in by re-running the renderer. The expensive model
never writes a number into a table, because it never writes the tables. Every
step except the judgement paragraphs is plain PowerShell, so the same reports
come out of CI, a bare shell, or a machine with no Claude Code on it.

## Non-goals

- **No new compliance rules.** This plan changes how findings are *presented*,
  never what counts as a finding. Evaluators are untouched.
- **No LLM in the fact path.** Counts, tables, rule/lane/task labels and the
  document skeleton are code. If an AI has to be trusted for a number, the
  design is wrong.
- **No customer vocabulary in this repo.** The engine is public. No customer,
  product, organisation or standard is named here or in anything this plan
  ships; engagement wording arrives through `sources.yaml` `labels:` and a
  workspace-owned config, exactly as ADR-008 established.
- **No unattended writes to Azure DevOps.** Everything here is read-only
  against both orgs and writes only into the workspace output folder.

## Current constraints discovered in the code and tooling

- **Workflow scripts cannot touch the filesystem, but their agents can — and
  the script picks each agent's model.** That is the lever this whole design
  turns on: a Haiku agent shells out to PowerShell for the deterministic work,
  and only the judgement pass pays for a frontier model. The engagement
  system's own `engage-knowledge-reconcile.js` already annotates phases this
  way (`model: 'haiku'` … `model: 'fable'`).
- **Azure DevOps auth is process-global.** `Enter-AdoOrgAuth` mutates
  `$script:AdoAuthMode` and `$env:AZURE_DEVOPS_EXT_PAT`. Two gathers in one
  process race. The gather agent must therefore issue **one** call that loops
  the codes internally — which is what `Invoke-GovernancePreflight` already
  does — never one call per team in parallel.
- **The live gather is the fragile step.** An organisation enforcing a
  Conditional Access sign-in frequency will invalidate a session part way
  through: observed in the field, a token minted at 11:20 was accepted at 11:22
  and refused by 11:58. A run across many teams can outlive its session, so
  partial progress must survive.
- **A PowerShell-capable agent in this workspace can reach `apply`.** Tool
  access is the control. See the safety note in Phase 2.
- **Template scaffolding already delivers `.claude/**`.** The workspace loader
  copies every engine's `Templates/customer-repo/**` to the same relative path
  in the workspace, dot-directories included, and overwrites the paths listed
  in that template's `.managed` on every run. The automation tools engine
  already ships `.claude/settings.json` and a managed
  `.claude/hooks/deny-system-edits.ps1` this way. This works for gallery
  consumers too, because `Templates` ships inside the published module.
- **The customer-facing verb has two dispatchers**, as the 2026-09-01 plan
  recorded: the managed `Templates/customer-repo/governance/init.ps1`, which
  propagates automatically, and each workspace's seed `governance/build.ps1`,
  which needs a one-time manual edit per workspace.
- **The Workflow tool needs explicit opt-in.** A slash command whose
  instructions say to call it satisfies that; the engine cannot self-trigger.
- **Default workflow size guidance is ~15 agents.** See the agent-count note in
  Phase 2.

## The layering

Four layers, each usable without the one above it, and each with a model tier
that matches what it actually does.

| Layer | What it is | Needs AI | Model tier | Entry point |
| --- | --- | --- | --- | --- |
| 1 Gather | live reads → `preflight-<code>.data.json` | no | Haiku shells out | `Invoke-GovernancePreflight` |
| 2 Analyse | data → `preflight-<code>.json` / `.txt` | no | same call | pure half of the same call |
| 3 Render | data + findings + optional fragment → team markdown | no | Haiku shells out | `ConvertTo-GovernancePreflightReport` |
| 4 Observe | judgement paragraphs → `observations-<code>.md` | yes | frontier | the workflow, or skipped |

Layer 3 produces a complete, sendable document on its own. Layer 4 is
enrichment. That is what makes the non-Claude path real rather than a
consolation prize, and it is also what keeps the bill small: the expensive
model runs once per team over two small JSON files, never over the estate.

## Phase 1 — The renderer (engine, no AI)

New public function `ConvertTo-GovernancePreflightReport`:

```
ConvertTo-GovernancePreflightReport
    -DataPath          preflight-<code>.data.json
    -FindingsPath      preflight-<code>.json
    [-ObservationsPath observations-<code>.md]   # spliced if present
    [-OutputPath       preflight-<code>.md]
```

It owns the whole document: header with both coordinates and the gather
timestamp, a summary table grouped by `check` with each group's rule, task and
lane taken from the finding objects, the per-area table with work items per
path, the tag family bundles, the tag distribution buckets, the candidate-tag
table above the configured threshold, iteration context, and the returns list
derived from which checks fired.

Two properties matter more than the layout:

- **Idempotent.** Running it twice with the same inputs gives the same bytes.
  Running it again after the observations fragment appears gives the same
  document plus that section. Nothing is hand-merged.
- **The fragment is inserted, never merged.** The agent's output lands in one
  clearly bounded section. It cannot reach a table.

Add `-SkipFresh` (or `-MaxAge`) to `Invoke-GovernancePreflight` so a re-run
after a token drop gathers only the teams whose data file is missing or stale.
This is the resumability the Conditional Access behaviour demands, and it is
what lets the Gather phase be retried cheaply.

Add a `preflight-report` verb to the managed template dispatcher, and note the
seed `build.ps1` edit for existing workspaces.

## Phase 2 — The five `.claude` artifacts (engine templates, managed)

All ship from `Templates/customer-repo/.claude/**` and all go in `.managed`, so
the engine owns them and improvements reach every workspace. The engagement's
wording stays in config, not in these files.

**`.claude/skills/preflight-report/SKILL.md`** — the single source of truth for
how an observation is written. It holds the rules, and the rules are mostly
prohibitions:

- Read the data file and the findings file. Write only the fragment file.
- Never restate a count that the renderer already prints. Refer to it.
- Every number you do write must be one you can point at in the data file.
- Never edit the program, `resolved.yaml`, the report, or anything under
  `.system/`.
- Say what the shape *means* — concentration, duplicates, families that belong
  together, things the counts imply but do not state. That is the whole job.

**`.claude/agents/preflight-reporter.md`** — a thin subagent definition whose
body says to load that skill and follow it, and whose `tools` frontmatter is
limited to reading and writing files. No shell. This is the expensive one, and
it structurally cannot run `apply`, reach the live organisation, or edit
authored config.

**`.claude/agents/governance-runner.md`** — the cheap one. Shell access, and a
body that names the exact read-only verbs it may invoke (`preflight`,
`preflight-report`) and forbids everything else. **Safety note:** tool access
is a weak fence around a shell that can reach `Invoke-GovernanceApply`. The
workspace already ships a `PreToolUse` hook (`deny-system-edits.ps1`), and the
same mechanism should deny any command line matching `apply` from a subagent.
Recommend shipping that hook alongside these templates rather than relying on
prompt wording.

**`.claude/workflows/audit-preflight.js`** — the orchestrator, sketched:

```js
export const meta = {
  name: 'audit-preflight',
  description: 'Gather and render per-team preflight fix reports, write and verify observations, and summarise the run',
  phases: [
    { title: 'Gather',    detail: 'One sequential Invoke-GovernancePreflight over every code',  model: 'haiku' },
    { title: 'Render',    detail: 'ConvertTo-GovernancePreflightReport per team',               model: 'haiku' },
    { title: 'Observe',   detail: 'One reporter per team writes its observations fragment',     model: 'fable' },
    { title: 'Check',     detail: 'Verify every number in the fragment appears in the data',    model: 'haiku' },
    { title: 'Publish',   detail: 'Re-render to splice the fragments in',                       model: 'haiku' },
    { title: 'Summarise', detail: 'Cross-team summary for the operator',                        model: 'sonnet' },
  ],
}

phase('Gather')
const gathered = await agent(gatherPrompt(args.codes), {
  agentType: 'governance-runner', model: 'haiku', schema: MANIFEST })
  // ONE call that loops the codes internally — auth is process-global.

phase('Render')
const manifest = await agent(renderPrompt(gathered.teams), {
  agentType: 'governance-runner', model: 'haiku', schema: MANIFEST })

const results = await pipeline(
  manifest.teams,
  t => agent(observePrompt(t), {
        label: `observe:${t.code}`, phase: 'Observe',
        agentType: 'preflight-reporter', model: 'fable', schema: OBSERVATIONS }),
  (obs, t) => args.check === false
    ? { ...t, obs }
    : agent(checkPrompt(t), {
        label: `check:${t.code}`, phase: 'Check',
        model: 'haiku', schema: VERDICT }).then(v => ({ ...t, obs, verdict: v }))
)

phase('Publish')
const done = results.filter(Boolean)
await agent(publishPrompt(done), { agentType: 'governance-runner', model: 'haiku' })

phase('Summarise')
return { teams: done.length, summary: await agent(summaryPrompt(done), { model: 'sonnet' }) }
```

`pipeline` rather than `parallel` for the per-team stages is deliberate: a
team's check starts the moment its own observations land, instead of waiting
for the slowest team. Paths arrive through `args`; the script stamps no
timestamps, because `Date.now()` is unavailable in workflow scripts by design.

**Cost shape.** Two frontier-model calls per team at most — one to observe, and
that is it, since Check runs on Haiku. Everything else in the run is Haiku
regardless of how many teams there are. Gather and Render do not scale with
model spend at all, only with wall clock.

**Agent count.** `2N + 4`. Eighteen teams is 40 agents, well past the ~15
default guidance, so `args.check` exists to drop to `N + 4`, and the command
should batch by default and say so. Silent truncation would read as full
coverage.

**`.claude/commands/audit-preflight.md`** — the operator's entry. It is thin,
because the workflow does the orchestrating:

1. Resolve which codes to run: the argument, or everything in `sources.yaml`.
2. Invoke `Workflow({name: 'audit-preflight', args: {codes, check}})` — this is
   the explicit opt-in the tool requires.
3. Report where the documents are, which teams failed to gather with the
   diagnosed reason, and which have no observations.

## Phase 3 — Configuration the workspace owns

Two things are currently judgement hard-coded into prose and must become
config, or fifteen teams get fifteen different bars:

- **The candidate-tag threshold.** "Tags used on more than 20 work items" was
  an arbitrary choice made in a chat window. It belongs in `taxonomy.yaml` or
  the program's reporting block, and the report should state the number it
  used.
- **Report framing.** Audience, tone, and the name of the standard the labels
  refer to. A workspace-owned file, read by the renderer for headings and by
  the skill for voice.

`sources.yaml labels:` already carries rule, task and lane per check and needs
no change.

## Phase 4 — The non-Claude paths

- **Plain shell.** `governance/build.ps1 preflight-report` runs layers 1 to 3
  and writes every team's document. No Claude Code, no agents, no API key. The
  documents are complete and sendable; they simply have no observations
  section.
- **CI.** The same call on a schedule, with a PAT, publishing the documents as
  build artifacts. This is what makes a per-team readiness dashboard possible
  without anyone running anything by hand.
- **Another assistant.** The skill file is plain markdown and the fragment
  contract is one file in, one file out. Any assistant, or a person, can do
  layer 4 by following it.
- **API, later.** A small script that posts the data file and the skill text to
  the Claude API and writes the fragment would close the loop unattended. It
  needs a key and a decision about where that key lives, so it is out of scope
  here and noted only so the shape stays compatible with it.

## Test plan

- Renderer: golden-file test over a fixture data + findings pair, asserting
  byte-identical output on a second run, and correct splicing when a fragment
  is present and when it is absent.
- Renderer: assert every count it prints is traceable to the fixture, and that
  no count appears in the document that is absent from the inputs.
- `-SkipFresh`: a stale data file is re-gathered, a fresh one is not.
- Existing 129 tests must stay green; the fixture program gains a fragment file
  and stays anonymised.

## Decisions still open

1. **Does the command batch, or refuse, above the agent guideline?** Batching
   is friendlier; refusing is more honest. Recommend batching with an explicit
   log line naming the batch size.
2. **Is the Check phase on by default?** On Haiku it is cheap, and it catches
   the one failure mode the renderer cannot prevent — a number invented inside
   a prose sentence. Recommend on by default.
3. **Managed or seed for the skill?** Managed keeps the anti-hallucination
   rules unweakenable and propagates fixes; it also means a workspace cannot
   tune the voice locally. Recommend managed, with voice in workspace config.
4. **Does the deny-apply hook ship with these templates?** Recommend yes.
   Giving an agent a shell in a workspace that can reconcile a live
   organisation should not be fenced by prompt wording alone.
5. **Where does the summary go?** The workflow returns one; whether it is also
   written to a file, and whether that file is committed engagement evidence,
   is an engagement decision rather than an engine one.
6. **Naming.** `audit-preflight` for the operator command against `preflight`
   for the engine verb. Fine if deliberate, confusing if not.
