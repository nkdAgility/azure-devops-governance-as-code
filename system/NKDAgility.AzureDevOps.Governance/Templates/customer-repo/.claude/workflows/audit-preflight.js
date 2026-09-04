// audit-preflight — MANAGED FILE, shipped by the NKDAgility.AzureDevOps.Governance
// module from Templates\customer-repo\.claude\workflows\audit-preflight.js and
// overwritten on every init.ps1. Change it in the engine repo (ADR-009).
//
// One operator command, many teams. Cheap agents shell out to PowerShell for the
// deterministic work (gather, analyse, render, publish); one frontier agent per
// team writes ONLY the Observations fragment; a cheap checker verifies that every
// number in that fragment exists in the team's data. The renderer owns every
// table, so the expensive model never writes a count into one.
//
// args: { program: string, codes?: string[], check?: boolean, batch?: number }

export const meta = {
  name: 'audit-preflight',
  description: 'Gather and render per-team governance preflight fix reports, write and verify their observations, and summarise the run',
  whenToUse: 'When the operator runs /audit-preflight, or asks for the pre-migration fix reports for every team (or named teams) in a governance program. Pass args as {program, codes?, check?, batch?}. The gather reuses fresh data files, so re-running after a sign-in expiry only fetches the missing teams.',
  phases: [
    { title: 'Gather',    detail: 'One sequential preflight over every code, reusing fresh data files', model: 'haiku' },
    { title: 'Render',    detail: 'preflight-report renders every gathered team; manifest of files',   model: 'haiku' },
    { title: 'Observe',   detail: 'One preflight-reporter per team writes observations-<code>.md',     model: 'fable' },
    { title: 'Check',     detail: 'Every number in each fragment must exist in that team\'s data',     model: 'haiku' },
    { title: 'Publish',   detail: 'Re-render so the fragments are spliced into the reports',           model: 'haiku' },
    { title: 'Summarise', detail: 'Cross-team summary for the operator',                               model: 'sonnet' },
  ],
}

const program = args && args.program
if (!program) throw new Error('audit-preflight needs args.program (the governance program name, e.g. the folder under governance/programs/).')
const codes  = (args && Array.isArray(args.codes) && args.codes.length) ? args.codes : null
const check  = !(args && args.check === false)
const batch  = (args && Number.isInteger(args.batch) && args.batch > 0) ? args.batch : 8

const MANIFEST = {
  type: 'object',
  required: ['teams', 'failed'],
  properties: {
    outputDir: { type: 'string' },
    teams: { type: 'array', items: { type: 'object', required: ['code', 'dataPath', 'findingsPath'], properties: {
      code: { type: 'string' }, dataPath: { type: 'string' }, findingsPath: { type: 'string' },
      reportPath: { type: 'string' }, observationsPath: { type: 'string' }, findingCount: { type: 'integer' } } } },
    failed: { type: 'array', items: { type: 'object', required: ['code', 'reason'], properties: { code: { type: 'string' }, reason: { type: 'string' } } } },
  },
}
const OBSERVATIONS = {
  type: 'object', required: ['path', 'bullets', 'numbersUsed'],
  properties: { path: { type: 'string' }, bullets: { type: 'integer' }, numbersUsed: { type: 'array', items: { type: 'string' } } },
}
const VERDICT = {
  type: 'object', required: ['ok', 'unsupported'],
  properties: { ok: { type: 'boolean' }, unsupported: { type: 'array', items: { type: 'string' } }, note: { type: 'string' } },
}

// Custom agent types (.claude/agents/*.md) are registered when a session starts.
// In a session that began before init.ps1 shipped them, the type is unknown and
// agent() throws. Fall back to the default agent once, say so loudly, and keep
// going: the deny-apply hook still holds regardless of which agent runs a shell.
const missingTypes = new Set()
async function spawn(prompt, opts) {
  const type = opts && opts.agentType
  if (type && !missingTypes.has(type)) {
    try { return await agent(prompt, opts) }
    catch (e) {
      if (!/agent type .* not found/i.test(String(e && e.message))) throw e
      missingTypes.add(type)
      log(`⚠ agent type '${type}' is not registered in this session (start a new session after init.ps1 to load .claude/agents). Falling back to the default agent for '${opts.label || type}'.`)
    }
  }
  const { agentType, ...rest } = opts || {}
  return agent(prompt, rest)
}

const codeArgs = codes ? codes.map(c => `-Code ${c}`) : ['']
const gatherCommand = codeArgs
  .map(c => `Invoke-Governance preflight ${program} ${c} -SkipFresh`.replace(/\s+/g, ' ').trim())
  .join('; ')

// ── Gather ────────────────────────────────────────────────────────────────────
phase('Gather')
log(`Gathering ${codes ? codes.join(', ') : 'every team in sources.yaml'} for '${program}' (fresh data files are reused)`)
const gathered = await spawn(
  `In this workspace, run ONE PowerShell process:

    pwsh -NoProfile -Command ". .\\init.ps1 -NoSync; ${gatherCommand}"

It exits non-zero when it finds anything — that is a result, not an error. Do not retry.
Then list the files under output\\governance\\${program}\\ (or wherever the console said resolved.yaml lives) and return a manifest:
- teams: one entry per code that has BOTH preflight-<code>.data.json and preflight-<code>.json, with their absolute paths
- failed: one entry per code that has no data file, with the one-line reason from the console (quote it; an auth rejection or expired sign-in is a reason, report it exactly)
- outputDir: the folder those files are in
Never print or echo any token or PAT value.`,
  { label: 'gather', phase: 'Gather', agentType: 'governance-runner', model: 'haiku', effort: 'low', schema: MANIFEST })

if (!gathered) throw new Error('The gather agent returned nothing.')
for (const f of gathered.failed) log(`✗ ${f.code}: ${f.reason}`)
if (gathered.teams.length === 0) {
  return { program, teams: 0, failed: gathered.failed, summary: 'No team produced a data file. Nothing to render.' }
}

// ── Render ────────────────────────────────────────────────────────────────────
phase('Render')
const rendered = await spawn(
  `In this workspace, run ONE PowerShell process:

    pwsh -NoProfile -Command ". .\\init.ps1 -NoSync; Invoke-Governance preflight-report ${program}"

It renders preflight-<code>.md for every team that has data, in ${gathered.outputDir || 'the output folder it names'}.
Return the manifest again with, per team: code, dataPath, findingsPath, reportPath (the .md it wrote), observationsPath (the same folder, observations-<code>.md — it may not exist yet), and findingCount (read "findingCount" from preflight-<code>.json). Carry the failed list through unchanged: ${JSON.stringify(gathered.failed)}. Teams: ${JSON.stringify(gathered.teams.map(t => t.code))}.`,
  { label: 'render', phase: 'Render', agentType: 'governance-runner', model: 'haiku', effort: 'low', schema: MANIFEST })

if (!rendered) throw new Error('The render agent returned nothing.')

// ── Observe → Check, per team, in batches ─────────────────────────────────────
const observePrompt = (t, feedback) =>
  `Write the Observations fragment for team ${t.code}.
Inputs: ${t.dataPath} and ${t.findingsPath}; the rendered report is ${t.reportPath}.
Output: ${t.observationsPath} — write this file and nothing else.
Follow .claude/skills/preflight-report/SKILL.md exactly.${feedback ? `

A checker could not find these numbers in the inputs: ${feedback.join(', ')}. Remove or replace every one of them with a number that appears verbatim in the data or findings file, or refer to the report's table instead.` : ''}`

const checkPrompt = (t) =>
  `Verify ${t.observationsPath} against ${t.dataPath} and ${t.findingsPath}.
Extract every number token in the fragment (digits, with or without thousands separators; ignore the team code and file names). For each, confirm it appears as a value in one of the two JSON files. Return ok=true only if every number is found; otherwise ok=false with the unsupported numbers listed. Do not edit any file.`

const all = []
for (let i = 0; i < rendered.teams.length; i += batch) {
  const slice = rendered.teams.slice(i, i + batch)
  log(`Observations batch ${Math.floor(i / batch) + 1}: ${slice.map(t => t.code).join(', ')}`)
  const results = await pipeline(
    slice,
    t => spawn(observePrompt(t), { label: `observe:${t.code}`, phase: 'Observe', agentType: 'preflight-reporter', model: 'fable', schema: OBSERVATIONS }),
    async (obs, t) => {
      if (!obs) return null
      if (!check) return { ...t, obs, verdict: { ok: true, unsupported: [], note: 'check skipped' } }
      let verdict = await spawn(checkPrompt(t), { label: `check:${t.code}`, phase: 'Check', model: 'haiku', effort: 'low', schema: VERDICT })
      if (verdict && !verdict.ok && verdict.unsupported.length) {
        const again = await spawn(observePrompt(t, verdict.unsupported), { label: `observe:${t.code}#2`, phase: 'Observe', agentType: 'preflight-reporter', model: 'fable', schema: OBSERVATIONS })
        if (again) verdict = await spawn(checkPrompt(t), { label: `check:${t.code}#2`, phase: 'Check', model: 'haiku', effort: 'low', schema: VERDICT })
      }
      return { ...t, obs, verdict: verdict || { ok: false, unsupported: [], note: 'checker returned nothing' } }
    })
  all.push(...results.filter(Boolean))
}
const dropped = rendered.teams.length - all.length
if (dropped) log(`${dropped} team(s) produced no observations fragment`)

// ── Publish ───────────────────────────────────────────────────────────────────
phase('Publish')
await spawn(
  `In this workspace, run ONE PowerShell process:

    pwsh -NoProfile -Command ". .\\init.ps1 -NoSync; Invoke-Governance preflight-report ${program}"

This re-renders every team's preflight-<code>.md so the observations-<code>.md fragments written since the last render are spliced in. Return the manifest with reportPath per team.`,
  { label: 'publish', phase: 'Publish', agentType: 'governance-runner', model: 'haiku', effort: 'low', schema: MANIFEST })

// ── Summarise ─────────────────────────────────────────────────────────────────
phase('Summarise')
const summary = await spawn(
  `Write a short operator summary (markdown, under 250 words) of this preflight run for program '${program}'.
Per-team results (JSON): ${JSON.stringify(all.map(t => ({ code: t.code, findingCount: t.findingCount, report: t.reportPath, observationsOk: t.verdict && t.verdict.ok, unsupportedNumbers: t.verdict ? t.verdict.unsupported : [] })))}
Teams that failed to gather: ${JSON.stringify(rendered.failed || gathered.failed)}
Say: which reports exist and where; which teams have observations that passed the number check, which failed it (name the unsupported numbers), and which failed to gather and why; and the single next action for the operator (re-run after 'az login' if an auth rejection is present). Use only the facts given here.`,
  { label: 'summary', phase: 'Summarise', model: 'sonnet' })

return {
  program,
  teams: all.length,
  reports: all.map(t => ({ code: t.code, report: t.reportPath, findingCount: t.findingCount, observationsOk: !!(t.verdict && t.verdict.ok) })),
  failed: rendered.failed || gathered.failed,
  summary,
}
