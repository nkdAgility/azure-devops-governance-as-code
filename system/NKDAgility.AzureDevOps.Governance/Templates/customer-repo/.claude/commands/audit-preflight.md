---
description: Run the governance preflight end to end for every team (or the named teams) — gather, render each team's fix report, write and verify observations, summarise.
argument-hint: "[program] [code ...] [--no-check] [--batch N]"
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
(e.g. `PTL-FND`), `--no-check`, and `--batch N`.

- If no program is named and the workspace has exactly one program, use it. If
  it has several, stop and ask which.
- Codes must exist in that program's `sources.yaml`; if one does not, stop and
  say which codes are declared.
- `check` defaults to true; `--no-check` sets it false. `batch` defaults to 8.

## 2. Say what is about to happen

One line: the program, the codes (or "every team in sources.yaml"), and that
the gather reuses any data file that already exists, so a re-run after a
sign-in expiry fetches only the missing teams. If the operator needs a fresh
gather for a team that already has data, they delete that team's
`-data.json` first; say so only if a code was named.

## 3. Run the workflow

Call the Workflow tool with the saved workflow:

    Workflow({ name: 'audit-preflight', args: { program, codes, check, batch } })

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
  operator to run `az login --tenant <tenant>` and re-run this command; the
  completed teams are kept.
- Do not paraphrase numbers from the reports. Point at the files.

## What this command never does

It never runs `apply`, never writes to Azure DevOps or GitHub, never edits
anything under `governance\programs\`, and never prints a token. If the
workflow cannot be found, the workspace has not been initialised since the
engine that ships it was adopted: run `. .\init.ps1` and try again.
