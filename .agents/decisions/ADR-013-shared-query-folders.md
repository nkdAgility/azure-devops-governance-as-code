# ADR-013 — Shared query folders are governed like pipeline folders

**Status:** accepted

## Context

Teams need a place under **Shared Queries** that they own, with permissions
that follow the hierarchy — the same need pipeline folders already answer for
build definitions. Without it, shared queries accumulate at the root with
project-default permissions and no owner.

## Decision

Mirror the pipeline folder feature exactly, so there is one mental model:

| | Pipeline folder | Query folder |
|---|---|---|
| Opt-in flag (`hierarchy.yaml`, product or first-level team) | `pipelineFolder: true` | `queryFolder: true` |
| Resolved collection | `pipelineFolders` | `queryFolders` |
| Path | `\Portal\Platform\Foundation` | `Shared Queries/Portal/Platform/Foundation` |
| Permission source (`access.yaml`) | `roles.<role>.pipelines` | `roles.<role>.queries` |
| Security namespace | Build `33344d9c-…` | WorkItemQueryFolders `71356614-aad7-4757-8f2c-0fb3bff6f680` |

`queries:` accepts `read` (Read = 1), `contribute` (Read + Contribute + Delete
= 7) and `manage` (contribute + ManagePermissions = 15). An unknown value fails
the build rather than surfacing mid-apply.

- **Existence** — targeted `GET {project}/_apis/wit/queries/{path}?$depth=0`
  per folder (ADR-002); apply creates missing levels with
  `POST {project}/_apis/wit/queries/{parentPath}` `{ name, isFolder: true }`.
- **ACL** — the namespace token is the chain of folder **ids**,
  `$/{projectId}/{sharedQueriesId}/{childId}/…`, not the path. The engine
  resolves each level; a missing level throws instead of writing an ACE to a
  guessed token. Read with `GET _apis/accesscontrollists/{ns}?token=…`, written
  with `POST _apis/accesscontrolentries/{ns}` (merge, Entra fallback on 401 as
  for every other ACL write).
- **Compliance** — same as pipeline folders: each authored group must hold at
  least its bits. Extra ACEs are not findings (consistent with pipeline folders).
- **Prune** — never. The folder holds the teams' queries; deleting it would
  delete their work.

## Consequences

- `vso.work_write` covers folder creation; ACL writes need the same
  security-manage capability as the other ACLs.
- Renaming a node moves its expected path; the old folder is left in place
  (not pruned) and the new one is created. Moving queries across is manual.
