# Sprig

A shell-integrated Git client modelled on TortoiseGit — overlay badges and right-click context menus for every Git operation, with task-specific windows that open when you need them and close when you don't.

The **engine and `sprigctl` CLI are first-class on macOS, Linux, and Windows** today; every PR runs the full test suite on all three. The **GUI shell ships first on macOS** (Finder integration, `apps/macos/`); a Windows GUI shell (Explorer integration via `apps/windows/`) is a planned 1.0 deliverable. Linux GUI integration (Nautilus / Dolphin / etc.) is post-1.0.

> **Status:** pre-MVP scaffolding. Not yet usable as a GUI app. `sprigctl` is functional on all three platforms (status, watch, repos subcommands today; log lands soon).

## Why Sprig?

- **Finder is the file browser.** Sprig doesn't duplicate what Finder already does well; it augments Finder with status badges and context-menu actions for every Git operation.
- **Uses your system `git`.** No wrapping, no divergence. Whatever your `~/.gitconfig`, credential helper, signing key, hooks, and aliases already do — Sprig honors them.
- **Fast.** FSEvents-driven incremental status; `git status` becomes O(changed files) even on 100k-file repos via our `core.fsmonitor` integration.
- **Safe.** Tiered confirmation for destructive operations, automatic snapshot refs for 24-hour undo of force-pushes/rebases/hard-resets, and never a silent `--force`.
- **Helpful.** Novice-friendly onboarding and first-class merge-conflict UI. Optional AI assistance (Anthropic, OpenAI, or local Ollama/Apple on-device) that works per-hunk and stays out of your way.
- **Open source, Apache-2.0.** Pure FOSS — no paid tiers, no telemetry, no cloud account required.

## Design principles

1. **Finder-first.** Every feature is reachable from a right-click in Finder.
2. **Defer to git.** Sprig never reimplements git — it shells out and parses `--porcelain=v2`. What works in your terminal works in Sprig.
3. **Safe by default.** Destructive operations gated by tiered confirmations; every dangerous op creates a recoverable snapshot.
4. **Novice-safe, expert-complete.** Approachable for users who've never opened a terminal; complete enough for power users to live in it (stacked PRs, interactive rebase, bisect, subtree, LFS, submodules).
5. **Privacy-first AI.** Local-first providers (Ollama, Apple Foundation Models) are the default; cloud providers are BYOK and gated behind explicit per-action confirmation.

## Getting started

### Prerequisites

**Working with the engine + `sprigctl` CLI** (macOS / Linux / Windows):

- Swift 6.0 toolchain or newer (the repo pins 6.3.1 in `.swift-version`; matched by CI on all three OSes).
- `git` 2.39 or newer on PATH.

**Building the macOS GUI app** (`apps/macos/`), in addition:

- macOS 14 Sonoma or newer (macOS 15 Sequoia recommended).
- Xcode 16 or newer with Command Line Tools installed.

The Windows GUI shell (`apps/windows/`) is in the design phase; once it lands the prerequisites will include the Windows 10 SDK and a swift-cross-ui-compatible toolchain.

### Build and run

```bash
git clone https://github.com/<org>/sprig.git
cd sprig
./script/bootstrap   # installs Swift toolchain via swiftly if available
./script/test        # build + tests + lint+format on whichever OS you're on

# Engine + CLI work everywhere:
swift build
.build/debug/sprigctl status .

# macOS app build (macOS only):
# open apps/macos/SprigApp.xcodeproj
```

## Repository layout

The repo is organized into three tiers so that platform shells are additive — the engine never needs to move when a new shell lands. See [`docs/architecture/cross-platform.md`](docs/architecture/cross-platform.md) for the full design.

- [`apps/macos/`](apps/macos/) — the macOS GUI shell (SwiftUI + AppKit, LaunchAgent, FinderSync extension, DMG installer). Populated.
- [`apps/windows/`](apps/windows/) — the Windows GUI shell (swift-cross-ui main app, Explorer shell extension, Windows Service for the agent, MSIX installer). Stub placeholder; planned 1.0 deliverable.
- [`apps/linux/`](apps/linux/) — Linux GUI shell (Nautilus extension first, others post-1.0). Stub placeholder; post-1.0.
- [`packages/`](packages/) — Swift packages that form the **portable core** (Tier 1) and **platform adapters** (Tier 2). Every package builds and tests on macOS, Linux, and Windows toolchains every PR. Adapter packages have `Sources/{Mac,Linux,Windows}/` subdirs; portable fallbacks live alongside (e.g. `PollingFileWatcher`).
- [`cli/sprigctl/`](cli/sprigctl/) — the `sprigctl` command-line companion. First-class on all three OSes.
- [`docs/`](docs/) — architecture docs, ADRs, research, planning, UX notes.
- [`tests/`](tests/) — integration, E2E, snapshot, benchmark, AI-eval suites.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to propose changes and [`docs/decisions/`](docs/decisions/) for the Architecture Decision Records (ADRs) that shaped the design.

## Roadmap

Sprig ships in milestones. The MVP gate ships the macOS shell with Finder badges, a right-click context menu for the 10 most-used Git commands, and a full merge conflict resolver. The Windows shell is a 1.0 deliverable that ships alongside macOS at `v1.0`. See [`docs/planning/roadmap.md`](docs/planning/roadmap.md) for the full milestone definitions.

## Contributing

Pull requests welcome. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). For significant changes, please open an issue or draft an ADR under [`docs/decisions/`](docs/decisions/) first.

## License

[Apache-2.0](LICENSE). See [`NOTICE`](NOTICE) for third-party attributions.

## Platform support at a glance

| Surface | macOS | Windows | Linux |
|---|---|---|---|
| Engine (`packages/*`) | ✅ first-class | ✅ first-class | ✅ first-class |
| `sprigctl` CLI | ✅ first-class | ✅ first-class | ✅ first-class |
| GUI shell (overlay icons + context menu + task windows) | ✅ Finder integration | 🛠️ planned 1.0 deliverable (Explorer integration) | 🕐 post-1.0 (Nautilus-first) |
| CI required-green | ✅ | ✅ | ✅ (`packages/` + tests) |

See [`docs/architecture/cross-platform.md`](docs/architecture/cross-platform.md) for the engine architecture and how shell ports plug in without restructuring the codebase.
