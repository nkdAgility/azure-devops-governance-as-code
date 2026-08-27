# programs/

Program definitions do **not** live in this repository. This repo is the
governance *engine*; each client keeps its own configuration in its own repo
(e.g. `NKDAClient-<name>/governance/programs/<program>/`) and calls this repo's
`build.ps1` with `-ProgramsRoot` pointing at that folder — typically via a thin
`governance/build.ps1` shell in the client repo that clones/updates this repo
and delegates.

A program folder contains:

```
<name>/
  manifest.yaml    # program identity + org + accessToken $Env: reference
  hierarchy.yaml   # authored product/structural/team tree
  access.yaml      # role definitions + group naming conventions
  cadence.yaml     # iteration cadence + scope defaults
  members/         # <codeKey>.yaml — desired group membership
```

You can still drop a program folder here for local experiments — `build.ps1`
uses this directory by default when `-ProgramsRoot` is not given. Never commit
a real PAT; `accessToken` must be an `$Env:` reference.

The compile-pipeline tests use a frozen program snapshot under
`tests/fixtures/programs/` — that is test data, not live configuration.
