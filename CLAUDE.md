# CLAUDE.md — AI agent guidance for the Sprig repository

This file orients Claude Code (and any other AI coding agent) working in this repo. It encodes the architectural invariants that hand-waving around won't catch.

## Project summary

Sprig is a macOS-native, Finder-first Git GUI modeled on TortoiseGit. The design is captured in `docs/decisions/` as 50+ ADRs (see `docs/decisions/README.md`). This CLAUDE.md summarizes the load-bearing ones.

## Architectural invariants — do not violate without an ADR update

### Tier discipline

The repo has three tiers; files live where their tier says they live.

- **Tier 1 — Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`). Pure Swift + Foundation. **Must compile on macOS, Linux, and Windows.**
- **Tier 2 — Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`). Protocol in `Sources/<Pkg>/`; macOS impl in `Sources/Mac/`; Linux/Windows impls in `Sources/Linux/` and `Sources/Windows/` (may be `fatalError` stubs but the types exist).
- **Tier 3 — Platform shells** (`apps/macos/`, `apps/windows/`, `apps/linux/`). Full rewrite per OS. At MVP only `apps/macos/` is populated; the other two are README-only placeholders.

### Hard rules (CI-enforced via SwiftLint + grep-lint + Linux build)

1. **Never import `AppKit`, `SwiftUI`, `Cocoa`, `FinderSync`, `Combine`, `ServiceManagement`, or `Sparkle` in any file under `packages/`.** These are Tier 3 imports only.
2. **Never use `#if os(...)` inside portable (Tier 1) package sources.** If you need a platform branch, the abstraction is wrong — move the capability into a `PlatformKit` protocol and add an adapter under `Sources/{Mac,Linux,Windows}/`.
3. **No hardcoded absolute paths.** No `/Users/...`, no `~/Library/...`, no `\AppData\`, no `/home/...` outside `tests/fixtures/` and `docs/`. Use `PathResolver.appSupport()` etc.
4. **All git invocation goes through `GitCore.Runner`.** No ad-hoc `Process()` in features — the runner owns cwd, env scrubbing, encoding, argv escaping, and the long-lived `cat-file --batch` cache.
5. **All IPC messages are `Codable` structs in `IPCSchema`.** No `@objc` protocols leak into portable code. The wire format must survive transport swaps (XPC → named pipes → D-Bus).
6. **Force-pushes always use `--force-with-lease --force-if-includes`.** Raw `--force` is never emitted.
7. **Destructive operations create a snapshot ref under `refs/sprig/snapshots/` *before* executing.** See `SafetyKit`.
8. **Every new tier-2 adapter adds Mac/Linux/Windows source files in the same commit** (stubs OK for Linux/Windows). The package graph must stay green on all three toolchains.

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
- E2E tests in `tests/e2e/` drive a signed build via XCUITest on a self-hosted macOS runner.
- Snapshot tests in `tests/snapshots/` cover diff and merge rendering.
- AI evaluation tests in `tests/ai-evals/` run the held-out conflict corpus against every configured provider.
- Benchmarks in `tests/benchmarks/` gate the 100k-file performance budget (<2% CPU steady, <150 MB RAM, <100 ms badge latency).

## Plan file (source of truth)

The approved plan lives at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`. When in doubt, consult it. The plan is the union of all ratified ADRs and the roadmap.

## Further reading

- `docs/architecture/overview.md` — component diagram and data flow
- `docs/architecture/cross-platform.md` — port guide for Windows/Linux
- `docs/decisions/README.md` — ADR index
- `docs/planning/roadmap.md` — milestones M0–M9
- `docs/research/git-feature-inventory.md` — what git commands Sprig surfaces at each tier
- `docs/research/git-best-practices.md` — defaults and interventions
