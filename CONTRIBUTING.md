# Contributing to Sprig

Thank you for your interest! Sprig is designed to make contribution easy, and we want first-time contributors to be able to land a PR within 15 minutes of cloning.

## Before you start

- Read the [Code of Conduct](CODE_OF_CONDUCT.md).
- Skim [CLAUDE.md](CLAUDE.md) for the load-bearing architectural invariants.
- Skim the [ADR index](docs/decisions/README.md) if you're proposing a design change.

## Quick start

```bash
git clone https://github.com/<org>/sprig.git
cd sprig
./script/bootstrap       # installs toolchain + dependencies
./script/test            # runs the full local test matrix
```

You should now be able to open `apps/macos/SprigApp/SprigApp.xcodeproj` in Xcode and build the app. (Building the full macOS app requires macOS; the portable `packages/` graph builds on Linux too — that's how our CI catches cross-platform regressions.)

## Branching

- **Never push to `main` directly.** Always open a PR.
- Branch names: `<type>/<scope>-<short-description>`. Examples: `feat/commit-composer-autosave`, `fix/watcher-iCloud-fallback`, `docs/adr-0054-blame-cache`.
- Rebase your branch on latest `main` before opening the PR.

## Commits

We use [Conventional Commits](https://www.conventionalcommits.org/). Release notes are auto-generated from commit subjects.

- `feat:` — new user-visible feature
- `fix:` — bug fix
- `chore:` — tooling / scaffolding / non-feature maintenance
- `docs:` — documentation only
- `refactor:` — code restructure without behavior change
- `test:` — tests only
- `perf:` — performance improvement
- `build:` / `ci:` — build system or CI

Scope is optional but encouraged: `feat(WatcherKit): coalesce FSEvents at 100ms`.

If your change implements or affects an ADR, cite it: `Implements ADR 0024, 0025`.

## PR checklist

Before opening a PR, please confirm:

- [ ] `./script/test` passes locally.
- [ ] Every new public API has unit tests.
- [ ] No new `import AppKit/SwiftUI/Cocoa/FinderSync/Combine/ServiceManagement/Sparkle` in `packages/`.
- [ ] No new `#if os(macOS)` in portable (Tier 1) packages.
- [ ] No hardcoded absolute paths outside `tests/fixtures/` or `docs/`.
- [ ] Any new tier-2 adapter includes Mac/Linux/Windows source files (stubs OK).
- [ ] Destructive operations create a snapshot ref via `SafetyKit`.
- [ ] Any user-visible change has a CHANGELOG.md entry under `[Unreleased]`.
- [ ] Any behavior change has an ADR or links to an existing one.

## Writing ADRs

If your change represents a decision that future contributors should understand, add an ADR.

1. Copy `docs/decisions/0000-template.md` to `docs/decisions/<next-number>-<short-title>.md`.
2. Fill in Context, Decision, Consequences, and Alternatives Considered sections.
3. Update `docs/decisions/README.md` to add your ADR to the index.
4. Link it from the PR description.

ADRs stay in `proposed` status until the PR merges, at which point they become `accepted`. Superseding an ADR requires writing a new one and updating the old one's status.

## Tests

See `tests/README.md` for the full test strategy. Summary:

- **Unit tests** colocated per package (`packages/<Pkg>/Tests/<Pkg>Tests/`).
- **Integration tests** in `tests/integration/` spawn real `git` across a version matrix.
- **E2E tests** in `tests/e2e/` use XCUITest on a self-hosted macOS runner.
- **Snapshot tests** in `tests/snapshots/` cover diff and merge rendering.
- **Benchmarks** in `tests/benchmarks/` gate the performance budget.
- **AI evals** in `tests/ai-evals/` run a held-out conflict corpus when AIKit or prompts change.

## Good first issues

Look for the `good-first-issue` label. Typical examples:

- Documentation improvements (typos, clarifications, new examples).
- Adding a small git-command parser test case to `GitCore`.
- Improving a prompt in `packages/AIKit/Sources/AIKit/Prompts/`.
- Translating strings (once the localization workflow lands post-1.0).

## Communication

- **Bugs and feature requests:** GitHub Issues.
- **Design discussion:** open a draft ADR and link it from a GitHub Discussion.
- **Security vulnerabilities:** see [SECURITY.md](SECURITY.md). **Do not open a public issue for security reports.**

## Governance

Until 1.0, project decisions are made by the maintainer (BDFL model — see ADR 0017). After 1.0 (or earlier if we have 3+ steady contributors), we'll publish `GOVERNANCE.md` and open a steering committee.

## Thank you

Sprig is a labor of love. Your time is appreciated.
