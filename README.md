# Sprig

A macOS-native, Finder-first Git client. Think TortoiseGit, but for Mac — deep shell integration, overlay badges, right-click context menus for every Git operation, task-specific windows that open when you need them and close when you don't.

> **Status:** pre-MVP scaffolding. Not yet usable as an app.

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

### Prerequisites (for contributors)

- macOS 14 Sonoma or later (macOS 15 Sequoia recommended).
- Xcode 16 or later with the Command Line Tools installed.
- Swift 6.3 toolchain.
- `git` 2.39 or later (Apple-bundled or Homebrew).

### Build and run

```bash
git clone https://github.com/<org>/sprig.git
cd sprig
./script/bootstrap
./script/test
# macOS app build is in apps/macos/SprigApp.xcodeproj
```

## Repository layout

This repo is organized into three tiers so that a future Windows or Linux port is additive rather than requiring a restructure. See [`docs/architecture/cross-platform.md`](docs/architecture/cross-platform.md) for the full design.

- [`apps/macos/`](apps/macos/) — the macOS app (SwiftUI + AppKit shell, LaunchAgent, FinderSync extension, installer).
- [`apps/windows/`](apps/windows/), [`apps/linux/`](apps/linux/) — placeholders for future ports.
- [`packages/`](packages/) — Swift packages that form the **portable core** and **platform adapters**. Every package builds on macOS, Linux, and Windows toolchains from day 1 (Linux/Windows adapter impls may be `fatalError` stubs pre-1.0).
- [`docs/`](docs/) — architecture docs, ADRs, research, planning, UX notes.
- [`tests/`](tests/) — integration, E2E, snapshot, benchmark, AI-eval suites.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to propose changes and [`docs/decisions/`](docs/decisions/) for the Architecture Decision Records (ADRs) that shaped the design.

## Roadmap

Sprig ships in milestones. MVP is **M0–M4**: Finder badges, a right-click context menu for the 10 most-used Git commands, and a full merge conflict resolver. See [`docs/planning/roadmap.md`](docs/planning/roadmap.md) for the full plan.

## Contributing

Pull requests welcome. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). For significant changes, please open an issue or draft an ADR under [`docs/decisions/`](docs/decisions/) first.

## License

[Apache-2.0](LICENSE). See [`NOTICE`](NOTICE) for third-party attributions.

## Porting Sprig to Windows or Linux

Sprig's architecture is designed to make ports additive: portable packages already build on all three platforms; only the app shell, file-manager extension, and installer need to be rewritten per OS. See [`docs/architecture/cross-platform.md`](docs/architecture/cross-platform.md).
