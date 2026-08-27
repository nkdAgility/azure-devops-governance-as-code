# Agent & contributor guide

The full engineering guide for this repository lives in
**[`.agents/agents.md`](.agents/agents.md)**. Read it before making changes — it
covers the hierarchy grammar, what "compliant" means for every resource type, the
iteration cadence rules, authentication, and the source layout.

Human contributors should start with **[CONTRIBUTING.md](CONTRIBUTING.md)**, and
new users with **[README.md](README.md)**.

> This file used to be a symlink to `.agents/agents.md`. It is now a real file so
> that it renders on GitHub and survives a clone on Windows without symlink
> support. `.agents/agents.md` remains the single source of truth — put new
> guidance there, not here.

---

## The rules that are never negotiable

**After every code change, run the tests. No exceptions.**

```powershell
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Normal"
```

If the tests fail, fix the failure before doing anything else. Do not move on, do
not explain, do not commit. Fix it.

**Silent errors are never acceptable.** If a function cannot complete its work,
it must throw. Returning `$null`, an empty set, or `$false` when a call fails is
a bug. Every caller depends on the error surfacing immediately.

**Config is truth. Live state must match config. Any difference is a violation.**
This is a compliance engine, not a provisioning helper. `apply` must not only
create what is missing — it must correct what is wrong. After every `apply`, an
`audit` must produce zero findings.

**`apply` is the only destructive command.** Never run it unprompted. Run
`-WhatIf` first and have the change set read before it goes through. `-Prune`
deletes resources that exist live but are not authored — treat it as separately
destructive.

**No customer data in this repository.** This repo is the governance *engine* and
is public. Program definitions live in their owners' own repositories and are
passed in via `-ProgramsRoot`. The fixture under `tests/fixtures/programs/` is
anonymised test data. Never commit a real organisation name, project name, UPN,
team GUID, or token — and never commit a literal PAT: a manifest `accessToken`
must always be an `$Env:` reference.
