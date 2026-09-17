---
description: Run the governance preflight end to end for every team (or the named teams) — gather, render each team's fix report, write and verify observations, summarise.
argument-hint: "[program] [code ...] [--resume] [--no-check] [--batch N]"
---

<!-- MANAGED FILE: shipped by the NKDAgility.AzureDevOps.Governance module from
     Templates\customer-repo\.claude\commands\audit-preflight.md and overwritten
     on every init.ps1. Change it in the engine repo (ADR-009). -->

Run the preflight pipeline as one operation. Everything except the observations
is plain PowerShell; the observations are written by one agent per team and
verified by another. Follow these steps exactly.

## 1. Resolve the arguments

`$ARGUMENTS` may contain, in any order: a program name (a folder under
`governance\programs\` holding a `manifest.yaml`), zero or more node codes
(e.g. `PTL-FND`), `--resume`, `--no-check`, and `--batch N`.

- If no program is named and the workspace has exactly one program, use it. If
  it has several, stop and ask which.
- Codes must exist in that program's `sources.yaml`; if one does not, stop and
  say which codes are declared.
- `check` defaults to true; `--no-check` sets it false. `batch` defaults to 8.
- `resume` defaults to **false**; `--resume` sets it true.

## 2. Say what is about to happen

One line: the program, the codes (or "every team in sources.yaml"), and that
**every run gathers fresh from the source organisation** — this command never
reports on data that was already sitting on disk.

Say it needs a live sign-in to the source organisation, and that a session cut
short part way through can be continued with `--resume`, which reuses the data
files already gathered and fetches only the teams still missing. Never suggest
`--resume` as a way to make a run faster or avoid signing in; it exists to
finish an interrupted run, and it is the one path that can report on data
gathered earlier.

## 3. Run the workflow

Call the Workflow tool with the saved workflow:

    Workflow({ name: 'audit-preflight', args: { program, codes, check, batch, resume } })

Pass `codes` as a real array or omit it; never as a JSON string. This command
is the operator's explicit opt-in to multi-agent orchestration; do not ask
again.

## 4. Report

When the workflow returns:

- Write its `summary` to
  `<output>\preflight\<program>-preflight-summary.md`, where `<output>` is the
  folder `resolved.yaml` is in.
- List each team's `<program>-preflight-<CODE>-report.md` with its finding
  count and whether its observations passed the number check.
- List every team that failed to gather with the reason the workflow gave. If
  a reason mentions a rejected Entra token or an expired sign-in, tell the
  operator to run `az login --tenant <tenant>` and then re-run with
  `--resume`, which keeps the teams that already gathered and fetches only the
  rest.
- If any team's observations were withheld as older than its findings, say so:
  the fragment was written against a superseded analysis and the report omits
  it rather than contradicting its own tables.
- Do not paraphrase numbers from the reports. Point at the files.

## What this command never does

It never runs `apply`, never writes to Azure DevOps or GitHub, never edits
anything under `governance\programs\`, and never prints a token. If the
workflow cannot be found, the workspace has not been initialised since the
engine that ships it was adopted: run `. .\init.ps1` and try again.
