# ADR-012: A program declares the Azure CLI context it runs in

Date: 2026-09-18
Status: accepted

## Context

Entra authentication made the engine dependent on something it had no way to
describe: whichever identity the machine's Azure CLI happened to hold. A
consultant holds one account per customer tenant, and the same workstation runs
scheduled tasks and unrelated scripts against other tenants. `az login` is
global to the user, so signing in for one customer signs the operator *out* of
the account every other job on that machine was using. The two uses take turns,
and each one breaks the other silently.

The failures are all quiet, and all expensive:

- Signing in for the customer redirects every other `az`-dependent job on the
  machine to that account. Nothing announces it.
- Signing in somewhere else mid-engagement leaves the governance run holding a
  token for the wrong identity. Azure DevOps rejects it with **AADSTS50020,
  "user account does not exist in tenant"**, which reads like a permissions
  fault. An hour went into one instance of exactly that.
- Azure DevOps only advertises its Entra tenant on a response that actually
  challenges for authentication; an anonymous probe answers 203 without the
  header. So tenant discovery alone cannot be relied on to pin a sign-in.
- Setting `AZURE_CONFIG_DIR` by hand in a shell profile or a local settings
  file works, and is invisible to everyone else. The next person reproduces
  nothing.

Azure CLI keeps its entire state — accounts, active subscription, MSAL token
cache — under `AZURE_CONFIG_DIR`. That variable is the whole isolation
primitive; the question was only who gets to set it and where that is written
down.

## Decision

1. **`manifest.yaml` gains an optional `azure:` block.** Four optional string
   fields: `profile`, `tenant`, `subscription`, `signInAs`. It sits with the
   program's other connection facts, beside `org` and `auth`, because it *is*
   one — the identity a program authenticates as belongs to the program, not to
   the machine that happens to run it. A program that declares nothing behaves
   exactly as it did before.

2. **`profile` gives the program an az world of its own.** A bare name resolves
   to `~/.azure-profiles/<name>`; an absolute or `~`-rooted path is taken as
   given. `Enter-GovernanceAzContext` points `AZURE_CONFIG_DIR` there for the
   rest of the process, and `Exit-GovernanceAzContext` restores it. Other
   processes are unaffected, because an environment variable does not travel
   upwards.

3. **The profile lives outside every working tree.** `~/.azure-profiles/`, not
   the repository. An Azure CLI profile holds refresh tokens, and a token store
   inside a git working tree is one bad `.gitignore` away from being published.
   A declared profile that resolves inside a repository is an **error**, not
   advice.

4. **`Initialize-AdoAuth` enters the context** — the one choke point every live
   command already goes through — and confirms the active account against
   `signInAs` before requesting any token. The wrong-account case becomes one
   sentence naming both identities, ahead of the token request, instead of
   AADSTS50020 after it.

5. **A declared tenant beats a discovered one**, since discovery cannot
   distinguish "not Entra-backed" from "did not challenge".

6. **The configuration is checked, not assumed.** `Test-GovernanceAzManifest`
   validates the block offline and rejects unknown keys, a non-GUID tenant and
   a `signInAs` that is not a UPN — a typo here otherwise produces a run that
   works, against the wrong identity, and fails much later.
   `Test-GovernanceAzContextPlacement` answers the separate question of whether
   the configuration is in the right *place*: it names the file the block
   belongs in when there is none, reports any competing `AZURE_CONFIG_DIR` set
   from a shell or a `.claude` settings file, and refuses a profile path inside
   a repository. `validate`, `connect` and `doctor` all report it.

7. **`signInAs` is an identity, never a secret.** Same standing as the
   migration capability's `SignInAs`: a UPN is safe to commit, a token is not.

## Consequences

- Governance runs and the rest of the machine stop taking turns. A customer
  sign-in is held in that customer's profile and nothing else sees it.
- `connect` is the only command an operator needs for sign-in, and it always
  states which profile directory it signed in to — a sign-in performed in a
  shell without the variable lands somewhere the workspace will never read, and
  that failure is otherwise silent.
- The sign-in persists on disk, so `connect` restores the shell's previous
  profile on exit unless `-Keep` is passed. Every governance command finds the
  sign-in; a bare `az` afterwards is back on the machine default, which is the
  point.
- One profile holds one *active* account, so a program spanning two Entra
  tenants still cannot be served by a single sign-in. `connect` warns and
  points at per-organisation PATs.
- CI is unaffected: no `azure:` block, or one with no `profile`, leaves
  `AZURE_CONFIG_DIR` alone, and OIDC sign-in works as before.
- A workspace that set `AZURE_CONFIG_DIR` in `.claude/settings.local.json`
  before this existed should delete that entry. It is not wrong, but it is not
  in source control and the manifest now says the same thing where everyone can
  see it.
