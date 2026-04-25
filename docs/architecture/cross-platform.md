# Cross-Platform Architecture

Sprig's macOS app is the user-facing 1.0 target, but the **engine is portable** and runs first-class on macOS, Linux, and Windows. Every PR has CI that builds, tests, and lints on all three.

This document mirrors §12 of the master plan (`/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`).

## Platform support matrix

| Surface | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| `GitCore` (Runner, CatFileBatch, PorcelainV2Parser) | ✅ | ✅ | ✅ | Shells out to system `git`. |
| `PlatformKit` (FileWatcher protocol, EventCoalescer) | ✅ | ✅ | ✅ | Pure-portable. |
| `WatcherKit.MockFileWatcher` | ✅ | ✅ | ✅ | Pure-portable. |
| `WatcherKit.PollingFileWatcher` | ✅ | ✅ | ✅ | Pure-portable; default on non-macOS, fallback on macOS via `--polling`. |
| `WatcherKit.FSEventsWatcher` | ✅ | — | — | macOS-only kernel API; CoreServices FSEvents. |
| `sprigctl` (version / status / watch) | ✅ | ✅ | ✅ | All three subcommands work on all three OSes. |
| `apps/macos/SprigApp` (FinderSync, LaunchAgent, …) | ✅ | — | — | The macOS user-facing shell. Tier-3 platform shell (per §12). |
| `apps/windows/SprigApp` (Explorer shell extension, …) | — | — | planned | Post-1.0; stub READMEs in `apps/windows/`. |
| `apps/linux/SprigApp` (Nautilus extension, …) | — | — | planned | Post-1.0; stub READMEs in `apps/linux/`. |

CI required-green per platform: macOS (`ci-macos`), Linux `packages/` (`ci-linux`), Windows full test suite (`ci-windows`).

## The three tiers

1. **Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`) — pure Swift + Foundation. Compiles + tests on macOS, Linux, Windows.
2. **Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`) — protocol in `Sources/<Pkg>/`; macOS impl in `Sources/Mac/`; portable Linux/Windows fallbacks where they exist (e.g. `PollingFileWatcher`); per-OS native impls coming as needed.
3. **Platform shells** (`apps/{macos,windows,linux}/`) — full rewrite per OS. Only `apps/macos/` is populated today.

## Hard rules (CI-enforced)

1. No `AppKit`/`SwiftUI`/`Cocoa`/`FinderSync`/`Combine`/`ServiceManagement`/`Sparkle` imports in `packages/`.
2. No `#if os(...)` in portable package sources; only in `Sources/{Mac,Linux,Windows}/` adapter subdirs.
3. No hardcoded absolute paths (POSIX or Windows). Use `PathResolver`.
4. No POSIX-only assumptions (e.g. `/usr/bin/env`, `/`-separator) in either production or test code. Use case-insensitive `PATH` walks; resolve `git` (vs `git.exe`) per platform.
5. Every `PlatformKit` protocol has Mac/Linux/Windows source files from day 1 (non-target platforms may be `fatalError` stubs).
6. CI runs the full test suite on macOS, Linux, and Windows. Red builds block merge on all three.

## Adapter seams

See `packages/PlatformKit/` for the authoritative protocol list: `FileWatcher`, `CredentialStore`, `NotificationPresenter`, `UpdateChannel`, `Transport`, `ServiceLauncher`, `PathResolver`, `GitLocator`.

Currently implemented:

- **`FileWatcher`** — protocol in `PlatformKit`. Implementations: `FSEventsWatcher` (macOS, kernel-level), `PollingFileWatcher` (portable, snapshot-diff), `MockFileWatcher` (tests). A `ReadDirectoryChangesW`-based native Windows watcher and an `inotify`-based Linux watcher are planned for parity with FSEvents perf.

The remaining `PlatformKit` protocols still have only stub adapters; they get real implementations as the milestones that need them land.

## Porting checklist for a new platform shell

1. Populate `apps/<platform>/` with the platform shell (file-manager extension, agent service, installer).
2. Replace any `fatalError` stubs in `packages/*/Sources/<Platform>/` with real native impls if perf parity matters (the portable fallbacks already work).
3. Add platform-specific CI checks that exercise the shell.
4. Write a port-specific `docs/architecture/<platform>-port.md`.

No file moves. No protocol refactors. That's the deal.
