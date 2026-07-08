# ADR-001 — Implementation language: PowerShell

**Date:** 2026-07-08
**Status:** Accepted

## Context

The tool needs to orchestrate Azure DevOps REST API calls and YAML file processing. Two realistic options were considered: PowerShell and Go.

Go advantages: single static binary, compile-time type safety, direct REST client (no `az devops` CLI dependency), easy mocking for tests, goroutine-based parallelism.

PowerShell advantages: already implemented with passing tests, familiar to platform/DevOps engineers, `powershell-yaml` module, `az devops` CLI integration, WhatIf framework built-in, no compilation step.

## Decision

Keep **PowerShell** for the current implementation.

The compile/resolve/validate pipeline is pure logic — PowerShell handles it well and all 13 tests prove it. The consumers (platform/DevOps engineers) live in PowerShell. Distribution is via repo clone, not package manager.

If this tool is ever distributed as a binary to CI pipelines across many teams, **Go would be the better choice** for the plan/apply/audit commands. The YAML schema and resolved model are language-agnostic, so a port would be straightforward.

## Consequences

- The `az devops` CLI must be installed alongside PS 7.4.
- Type errors surface at runtime rather than compile time — mitigated by the Pester test suite.
- Sequential execution (no goroutines); acceptable for 20–50 resources per apply run.
- A future Go port of plan/apply/audit is not precluded by this decision.
