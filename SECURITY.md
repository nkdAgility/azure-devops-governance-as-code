# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report them privately through GitHub's
[private vulnerability reporting](https://github.com/nkdAgility/azure-devops-governance-as-code/security/advisories/new)
on this repository (Security → Report a vulnerability). That channel is visible
only to the maintainers.

Please include:

- what the issue is and why it matters
- the steps or configuration needed to reproduce it
- the affected file or function, if you have narrowed it down
- any suggested fix

Strip organisation names, project names, UPNs, and tokens from anything you
attach.

**What to expect:** an acknowledgement within 5 working days, and an assessment
with a plan or a rejection within 15. We will keep you updated while a fix is in
progress, and will credit you in the advisory when it is published unless you
ask us not to.

## Supported versions

This project is pre-1.0. Security fixes are applied to `main` and released from
there. There are no supported maintenance branches for older versions.

---

## Security model, and what a report should be about

This engine holds credentials for, and makes privileged writes to, live Azure
DevOps organisations. Issues we consider security-relevant include:

- **Credential leakage** — a token written to disk, to `out/`, to a log line, to
  an error message, or to a generated report.
- **Unintended writes** — a read-only command (`build`, `validate`, `plan`,
  `audit`, `doctor`) causing a change in a live organisation. The one deliberate
  exception is documented below.
- **Privilege escalation through configuration** — authored YAML that results in
  permissions broader than it appears to grant. `sideload` granting anything
  beyond board visibility would be an example.
- **Destructive behaviour outside the declared contract** — anything deleted that
  is not an orphan, or any deletion at all without `-Prune`.
- **Injection through authored values** — a program name, node name, or UPN
  reaching a REST path, WIQL query, or shell invocation unescaped.

### Known and intended behaviours

These are by design, not vulnerabilities:

- **`apply` writes to the live organisation**, and `apply -Prune` deletes orphan
  teams, area paths, repos, and group members. This is the documented purpose of
  the command. Pruning is never on by default.
- **`audit` performs rolling iteration-window maintenance.** Time-based upkeep of
  team sprint subscriptions is maintenance rather than drift, so `audit` performs
  it rather than reporting it. It is the sole write from a read-only command and
  is limited to iteration subscriptions.
- **`apply` maintains one work item per project** when a taxonomy declares a tag
  vocabulary. Azure DevOps has no create-tag API and purges tags no work item
  references, so an anchor work item is the only available mechanism. See
  [ADR-006](.agents/decisions/ADR-006-tag-anchor-work-item.md).
- **`doctor` issues intentionally invalid writes.** They are rejected by Azure
  DevOps *after* the permission check, which is what proves access. An HTTP 400
  means the permission is present; nothing is created.

---

## Handling credentials safely

If you use this engine, these rules matter more than any code fix:

- **Prefer Entra.** `az login` (or OIDC in CI) is the default authentication
  mode. It stores no secret and carries the identity's real permissions.
- **Never commit a token.** A manifest's `accessToken` must always be an
  environment-variable reference (`$Env:NAME`), never a literal. The engine
  resolves it only for live commands and never writes it to `out/`. If
  `accessToken` resolves to something that looks like a URL, the engine throws
  rather than proceeding.
- **Treat generated artefacts as sensitive.** `resolved.yaml` and audit reports
  contain your full organisational structure and member UPNs. `out/` is
  gitignored — keep it that way.
- **If a token is exposed, revoke it first.** Revoke in Azure DevOps before
  cleaning up the repository; a token removed from a file but still valid is
  still compromised, and git history preserves it regardless.
