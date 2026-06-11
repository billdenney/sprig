---
status: accepted
date: 2026-04-24
deciders: maintainer
consulted: —
informed: —
---

# 0049. Modern git config defaults

## Context

See [`docs/planning/master-plan.md`](../planning/master-plan.md) §3 (Decision Log) for where the rationale, alternatives, and consequences that produced this ADR now live. (The original out-of-repo plan file was lost; the vendored plan records what survives and where.)

## Decision

Captured at scaffolding time; the title states the decision. This file is the canonical ADR location for linking from PRs, CHANGELOG entries, and code comments. Expand it in place when it becomes load-bearing for new work (see master-plan.md §3) — as was done for ADR 0051.

## Consequences

See the plan for trade-offs. When implementation reveals new consequences, update this file and cite the commit.

## Amendment 2026-06-11 — global excludes provisioning (§11.11, the "ask less" principle)

The first engine piece of §11.11's safety net: **`GitCore.GlobalExcludes`** provisions the
user's global excludes file with OS noise (`JunkFilePatterns.osNoise`: `.DS_Store`,
`.AppleDouble`, `._*`, `.Spotlight-V100`, `.Trashes`, `Thumbs.db`, `ehthumbs.db`,
`Desktop.ini`) so the question "ignore this junk here?" never arises in any repository again
— ignored files never show as untracked, which also keeps the per-repo `.gitignore`
suggestion banner quiet for these. This is the **ask-less principle** (master plan §11's
intervention levels) made explicit: one consent, zero future questions.

Consent + config safety: provisioning is an explicit act — onboarding, or `sprigctl setup
--global-ignore` — never a background side effect. It **never writes git config**: a set
`core.excludesFile` (any scope, `~` expanded) means appending to the user's chosen file;
unset means writing git's own documented default (`$XDG_CONFIG_HOME/git/ignore` →
`~/.config/git/ignore`), which git reads with no config key at all. Append-only mechanics
(header-once, line-dedup, never rewrites) are shared with the ADR 0070 per-repo suggestion
via the extracted `IgnoreFileEditor`. Real-git pinned: provisioning makes `.DS_Store`
vanish from porcelain while `git config --list --local` stays byte-identical.

## Links

- Master plan, §3 Decision Log (ADR 0049).
- CLAUDE.md — summarizes load-bearing rules across multiple ADRs.
