# CLAUDE.md — AI agent guidance for the Sprig repository

This file orients Claude Code (and any other AI coding agent) working in this repo. It encodes the architectural invariants that hand-waving around won't catch.

## Project summary

Sprig is a macOS-native, Finder-first Git GUI modeled on TortoiseGit. The design is captured in `docs/decisions/` as 50+ ADRs (see `docs/decisions/README.md`). This CLAUDE.md summarizes the load-bearing ones.

The macOS app is the user-facing 1.0 product, but **the engine (`packages/` + `cli/sprigctl/`) is portable and runs first-class on macOS, Linux, and Windows**. Every PR has CI that builds and tests on all three. See `docs/architecture/cross-platform.md` for the full matrix.

## Architectural invariants — do not violate without an ADR update

### Tier discipline

The repo has three tiers; files live where their tier says they live.

- **Tier 1 — Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`). Pure Swift + Foundation. **Must compile and pass tests on macOS, Linux, and Windows.**
- **Tier 2 — Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`). Protocol in `Sources/<Pkg>/`; native macOS impl in `Sources/Mac/`; Linux/Windows in `Sources/Linux/` and `Sources/Windows/`. Where a portable fallback exists (e.g. `PollingFileWatcher`) it lives in `Sources/<Pkg>/` and is the default everywhere except where a native impl wins on perf. Stubs are `fatalError` until a real impl is added.
- **Tier 3 — Platform shells** (`apps/macos/`, `apps/windows/`, `apps/linux/`). Full rewrite per OS. Only `apps/macos/` is populated today; the other two are README-only placeholders for future work.

### Hard rules (enforced via SwiftLint + the three-OS CI matrix)

1. **Never import `AppKit`, `SwiftUI`, `Cocoa`, `FinderSync`, `Combine`, `ServiceManagement`, or `Sparkle` in any file under `packages/`.** These are Tier 3 imports only. *(SwiftLint custom rule `no_appkit_in_packages`.)*
2. **Never use `#if os(...)` inside portable (Tier 1) package sources for behavior branching.** Trivial cross-platform constants (PATH separator, executable name) are the only acceptable case. If you need a platform branch for real logic, the abstraction is wrong — move the capability into a `PlatformKit` protocol and add an adapter under `Sources/{Mac,Linux,Windows}/`. *(Enforced by code review + the Linux + Windows CI jobs that compile + test `packages/` on non-Apple toolchains. A real behavior divergence will fail at least one of those builds.)*
3. **No hardcoded absolute paths.** No `/Users/...`, no `~/Library/...`, no `\AppData\`, no `/home/...` outside `Tests/`, `tests/fixtures/`, and `docs/`. Use `PathResolver.appSupport()` etc. *(SwiftLint custom rule `no_hardcoded_home_paths`.)*
4. **No POSIX-only assumptions in tests either.** `/usr/bin/env`, `/`-only path separators, `git` (vs `git.exe`) bare names — none of these are safe. Use case-insensitive `PATH` walks; resolve binaries per platform. *(Caught by the Windows CI job running the full test suite.)*
5. **All git invocation goes through `GitCore.Runner` or `GitCore.CatFileBatch`.** No ad-hoc `Process()` in features — these own cwd, env scrubbing, encoding, argv escaping, the long-lived `cat-file --batch` cache, and case-insensitive PATH discovery.
6. **All IPC messages are `Codable` structs in `IPCSchema`.** No `@objc` protocols leak into portable code. The wire format must survive transport swaps (XPC → named pipes → D-Bus).
7. **Force-pushes always use `--force-with-lease --force-if-includes`.** Raw `--force` is never emitted.
8. **Destructive operations create a snapshot ref under `refs/sprig/snapshots/` *before* executing.** See `SafetyKit`.
9. **Every new tier-2 adapter adds Mac/Linux/Windows source files in the same commit** (stubs OK for Linux/Windows). The package graph must stay green on all three toolchains.

### Defer to git

We shell out to the user's `git` binary; we do not embed libgit2. Benefits: LFS, filters, hooks, credentials, signing, aliases, and includes all "just work." Cost: slower hot-path calls, mitigated by `core.fsmonitor`, persistent `cat-file --batch` processes, and careful use of `--porcelain=v2 -z`.

### No menu-bar app

Sprig runs as a LaunchAgent + FinderSync extension + task windows. There is no menu-bar icon. Preferences, Status, and other "app-level" surfaces are task windows launched from Finder right-click → Sprig ▶.

### AI is optional and local-first

AI features (merge conflict suggestions, commit message drafting, PR descriptions) are opt-in. Local providers (Ollama, Apple Foundation Models) are the default; cloud providers (Anthropic, OpenAI) require BYOK and show a "will send code to X" confirmation the first time each session.

## Where to look when…

- **I'm adding a git command invocation** → extend `GitCore` with a new runner method + tests. Update `docs/research/git-feature-inventory.md`.
- **I'm touching anything platform-specific** → add it behind a `PlatformKit` protocol + adapter. Never in a portable package.
- **I'm changing defaults** (git config, prompts, badges) → update the relevant ADR in `docs/decisions/` and document in `docs/architecture/`.
- **I'm adding an AI feature** → prompts live in `packages/AIKit/Sources/AIKit/Prompts/*.md` (versioned, user-overridable). Add a held-out eval fixture in `tests/ai-evals/`.
- **I'm adding a task window** → in `apps/macos/SprigApp/Sources/TaskWindows/`. Its view model goes in `packages/TaskWindowKit/` (portable).
- **I'm touching Finder integration** → only in `apps/macos/SprigFinder/`. Keep the extension thin — all work is delegated to SprigAgent over XPC.

## What to never do

- Never mock the git binary in integration tests. Spawn real git against fixture repos. (Different git versions have bitten us historically — test the matrix.)
- Never add telemetry or analytics without an ADR and user-visible opt-in.
- Never silently rewrite user git config at the global level; confirm first.
- Never delete `refs/sprig/snapshots/*` without respecting the TTL.
- Never reintroduce XPC-native proxy protocols in portable code (this is an intentional ergonomic sacrifice for cross-platform IPC — see ADR 0048).
- Never bundle the `git` binary or `git-lfs` binary without an ADR update (both are detect-and-install flows today).

## Commit conventions

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `perf:`): used to auto-generate release notes. Scope is optional: `feat(WatcherKit): coalesce FSEvents at 100ms`.
- Every PR should cite the ADR numbers it affects (e.g., "Implements ADR 0023, 0024").
- Never commit to `main` directly (per project-wide convention). Open a branch + PR.

## Testing expectations

- Unit tests colocated with each SPM package under `Tests/<Pkg>Tests/`.
- Integration tests in `tests/integration/` spawn real git across the pinned version matrix (2.39 Apple-bundled, current Homebrew, latest upstream).
- Snapshot tests in `tests/snapshots/` cover diff and merge rendering.
- AI evaluation tests in `tests/ai-evals/` run the held-out conflict corpus against every configured provider.
- Benchmarks in `tests/benchmarks/` gate the 100k-file performance budget (<2% CPU steady, <150 MB RAM, <100 ms badge latency).
- **No E2E suite today.** XCUITest-driven end-to-end testing of the macOS shell needs a self-hosted macOS-arm64 runner (real Finder + signing cert + notarization), which we don't have. When that runner is provisioned, the suite gets re-introduced under `tests/e2e/` with a matching workflow; until then we rely on integration tests + snapshot tests for the surfaces we can cover on hosted CI.

### Disabled CI tests must be tracked and re-enabled ASAP

When a CI test has to be disabled (intermittent flake, environment-dependent failure, missing dependency), the disable is **provisional**, never permanent. Two requirements at the moment of disabling:

1. **An in-code comment at the disable site** describing the symptom, the suspected root cause, and what would unblock re-enabling. The disable should fail review without one.
2. **A tracking entry in [`docs/planning/disabled-tests.md`](docs/planning/disabled-tests.md)** naming the test, the date disabled, the PR + commit, a link to diagnostic artifacts if any, and an owner.

Re-enabling cadence: as soon as the underlying bug is fixed (or the environment requirement met), the **next PR** flips the disable off. Don't bundle "fix bug" and "re-enable test" into the same PR — split them so reverting either is independent. Re-enabling is a one-line PR with the citation back to the fixing PR; that's the proof the fix actually worked.

The intent: a disable is a debt note we promise to pay quickly. We never accumulate dead disabled-on-CI tests; if we did, the diff between "what CI tests" and "what we ship" would silently widen. Disabled tests get reviewed at every milestone exit ([`docs/planning/milestones.md`](docs/planning/milestones.md)).

### Audit follow-ups must be tracked and closed

Every audit (per [`docs/planning/risk-register.md`](docs/planning/risk-register.md)'s audit obligations) produces findings. The deferred fixes — failure modes we've identified but aren't fixing immediately — go in [`docs/planning/audit-followups.md`](docs/planning/audit-followups.md). Same discipline as disabled tests: durable in-repo tracker beats scattered issues, every entry has a trigger condition that closes it, and milestone exits review what's still open.

When you add a deferred fix:

1. **In-code marker:** `// TODO(<RiskID>-F<N>): <one-line>` at every relevant call site, pointing at `docs/planning/audit-followups.md`. Don't leave bare `TODO`s — the audit ID is what makes them grep-able.
2. **Tracker entry** under "Pending" in `audit-followups.md` with severity, symptom, proposed fix, trigger to ship, and owner.

When the fix lands, the closing PR removes the in-code TODO markers and moves the tracker entry to "Closed" in the same diff. Splitting them creates orphan markers.

## Plan file (source of truth)

The approved plan lives at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`. When in doubt, consult it. The plan is the union of all ratified ADRs and the roadmap.

## Further reading

- `docs/architecture/overview.md` — component diagram and data flow
- `docs/architecture/cross-platform.md` — port guide for Windows/Linux
- `docs/decisions/README.md` — ADR index
- `docs/planning/roadmap.md` — milestones M0–M9
- `docs/research/git-feature-inventory.md` — what git commands Sprig surfaces at each tier
- `docs/research/git-best-practices.md` — defaults and interventions
