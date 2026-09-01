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

### Changed

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
