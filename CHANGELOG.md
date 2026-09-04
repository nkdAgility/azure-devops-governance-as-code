# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Because this is a compliance engine, treat these as breaking for the purposes of
the major version, even though they are not code API changes:

- a change that makes `audit` report something it previously ignored
- a change to the authored YAML grammar that invalidates an existing program
- a change to what `apply -Prune` considers an orphan

Any of those can turn a green compliance run red, or delete something it
previously left alone, without a line of consumer code changing.

## [Unreleased]

### Added

- `preflight` — per incoming team, a read-only "what would fail if this team
  moved in today?" report against its pre-migration location, declared in a
  new authored seed file `programs/<name>/sources.yaml` (source org / project
  / area path, optional source teams and repo filter, optional PAT env-var
  reference). Projects the source state into target coordinates and evaluates
  it with the same rules audit uses: area subtree orphans-to-be, tag usage on
  the source work items (disallowed + unsanctioned), repo naming, authored
  UPNs resolvable in the target org, and source-team members not authored in
  `members/`. Writes `preflight-<code>.txt/.json` beside `resolved.yaml`;
  non-zero exit on findings. Work item type/state/field compatibility stays
  with the migration toolchain (ADR-007).

- `preflight -Offline` — re-analyse the last gathered data file without
  touching either organisation (ADR-008).
- `sources.yaml labels:` — an optional map, keyed by preflight check id
  (`area.orphan`, `tag.disallowed`, `tag.unsanctioned`, `repo.orphan`,
  `member.unresolvable`, `teamAdmin.unresolvable`, `member.unauthored`,
  `preflight.error`), whose fields are copied onto every finding of that
  check — the engagement's rule number, owner lane or task id, so the JSON
  report is already the team's fix report. Validated by `validate` and by
  preflight; unknown check ids and attempts to override engine fields fail.

- `preflight-report` / `ConvertTo-GovernancePreflightReport` (ADR-009) — the
  per-team markdown fix report, rendered deterministically from the data and
  findings files. Every count, table and label is copied from those files; an
  optional `observations-<code>.md` fragment is spliced into one bounded
  section. Idempotent, offline, no AI: CI and a bare shell produce the same
  documents an operator gets.
- `preflight -SkipFresh [-MaxAgeHours N]` — reuse each node's existing data
  file and gather only the missing (or stale) ones; contacts no organisation
  when nothing is left to gather. The resume path after a sign-in expiry.
- `sources.yaml reporting:` — optional framing for the rendered report:
  `standard`, `audience`, `candidateTagMinUses` (default 20), `iterationTop`,
  `title`. Validated by `validate`.
- **Shipped operator orchestration** under `Templates/customer-repo/.claude/`,
  all managed: `/audit-preflight` (command), `audit-preflight.js` (workflow:
  gather → render → observe → check → publish → summarise, cheap models for
  everything but the observations), `governance-runner` and
  `preflight-reporter` (subagents), `preflight-report` (skill: the
  no-invented-numbers rules), and `deny-governance-apply.ps1` (PreToolUse
  hook refusing any shell command that would run a governance apply, `-WhatIf`
  excepted). Workspaces register the hook in their own `.claude/settings.json`.

### Changed

- `preflight` now runs as two steps (ADR-008): a **gather** that writes the
  facts — source area subtree with work items per path, tag and iteration
  usage, matched repos, source-team population, authored UPN resolution in
  the target — to `preflight-<code>.data.json`, and a pure **analysis** that
  reads the document and runs the shared evaluators. A failed gather records
  an ERROR finding and never overwrites the previous data file. The text
  report gains a `Data :` header line; its format is otherwise unchanged.
- `preflight` findings are **objects**: `class`, a stable `check` id,
  `subject`, check-specific fields (`source`, `workItems`, `tags`, `examples`,
  `group`, `team`, `sourceTeam`, `suggestions`) and the prefixed `message`.
  `preflight-<code>.json` `findings[]` entries keep `class` and `message`, so
  existing consumers of those keys are unaffected. Audit and apply still emit
  strings; `Write-GovernanceReport` accepts either form.
- `preflight` reports disallowed tags as one finding per **pattern** — count
  of distinct tags, work items carrying them, and the five most-used examples —
  instead of one finding per tag. A source area stamped with thousands of
  build-id or session-id tags now produces a handful of readable lines. The
  tag evaluator exposes the grouping as `DisallowedByPattern`; its flat
  `Disallowed` list, and audit/apply output, are unchanged.
- Area-path orphans in preflight now carry the number of work items sitting
  directly on the source path, and the message says "fold it to a tag" rather
  than "move its work items", matching the tags-over-area-paths rule.

### Fixed

- Source-org authentication failures in preflight are diagnosed, not guessed.
  `Enter-AdoOrgAuth` now says whether the Entra token was rejected by the org
  (Conditional Access forced sign-out) or could not be minted (the az error,
  token-shaped text redacted), and which credential route it fell back to;
  the first failed source read names that route in the finding, and the
  report's WHY line explains it instead of blaming a missing PAT scope. Also
  diagnoses `-Offline` with no data file.
- The compliance classification rules (areas, repos, tags, member sets) now
  live in pure evaluator functions shared by the reconcile and preflight, and
  the findings summary + text/JSON report writer is shared too. Audit, plan
  and apply behaviour, finding messages and report formats are unchanged; the
  only visible difference is console line ordering inside a security-group
  section (unresolvable entries now print before missing members).

## [0.1.0] - unreleased

Initial public release.

### Added

- `build` / `validate` — compile authored YAML into a resolved model, offline.
- `plan` — diff the resolved desired state against a live organisation, read-only.
- `apply` — reconcile the live organisation, creating missing resources **and
  correcting misconfigured ones**. `-WhatIf` previews; `-Prune` additionally
  deletes orphans and is never on by default.
- `audit` — read-only compliance report over every governed resource type.
- `doctor` — probe the current identity's permissions with side-effect-free
  calls before the first `apply`.
- Governed resource types: projects, area paths, teams and their area
  configuration, team administrators, security groups and membership, repos and
  their ACLs, pipeline folders and their ACLs, iteration cadence, and a governed
  tag vocabulary.
- Entra-first authentication, with a PAT fallback and an Entra fallback for
  security ACL writes that no PAT scope short of full access can perform.
- Reusable team `systems` stamped onto teams as governed sub-elements.

[Unreleased]: https://github.com/nkdAgility/azure-devops-governance-as-code/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nkdAgility/azure-devops-governance-as-code/releases/tag/v0.1.0
