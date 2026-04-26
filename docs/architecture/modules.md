# Modules

Every Swift package in `packages/`, plus `cli/sprigctl/` and `apps/macos/`. For each:

- **Tier** — 1 (portable), 2 (platform-adapter), or 3 (platform shell). See [`cross-platform.md`](cross-platform.md).
- **Status** — `live` (real implementation exists), `stub` (placeholder waiting on milestone), or `protocol-only` (Tier-2 protocol exists, native impls TBD).
- **Depends on** — direct imports.
- **Owning milestone(s)** — when the package activates per [`../planning/roadmap.md`](../planning/roadmap.md).

The portability rules in `cross-platform.md` apply: no `AppKit`/`SwiftUI`/`Cocoa`/`FinderSync`/`Combine`/`ServiceManagement`/`Sparkle` imports in any Tier 1 or 2 package; `#if os(...)` only inside `Sources/{Mac,Linux,Windows}/` adapter subdirs.

## Tier 1 — portable core

### `GitCore` — live (M1)

Spawns and parses the system `git` binary. The single seam through which any feature in Sprig invokes git (CLAUDE.md / ADR 0023). Public types:

- `Runner` — `async run(_ args: [String], cwd: URL?, stdin: Data?, throwOnNonZero: Bool)`. Owns argv escaping, env scrubbing, UTF-8 locale forcing, case-insensitive PATH lookup so `git`/`git.exe` resolution works on Windows.
- `CatFileBatch` — actor-isolated wrapper around a long-lived `git cat-file --batch`. One round-trip per `read(_:)` instead of fork/exec/exit per call. Foundation for diff / blame / log viewers.
- `GitVersion` — parses `git --version`; comparable; enforces 2.39 minimum (ADR 0047).
- `GitError` — typed error with raw stderr/stdout/exitCode preserved.
- `PorcelainV2Parser` + `Commit` + `Identity` + `LogParser` — parsers for `git status --porcelain=v2 -z` and `git log -z --format=%H%x1f...%x1f%B`.

Depends on: Foundation only. No PlatformKit. Does its own PATH resolution to keep startup deterministic.

Owning milestones: M1 (current); future enrichment in M3 (diff viewer needs blob reads), M4 (merge state inspection), M5 (rebase plumbing).

### `RepoState` — stub (M2 / M3)

Will hold the in-memory model of a watched repo: branch info, dirty path set keyed by path, badge trie (so the FinderSync extension can ask "what badge for `<path>`?" in O(log n)), open task-window cursors, snapshot-ref TTL bookkeeping.

Depends on: `GitCore` (to refresh state), `PlatformKit.FileWatcher` (to subscribe to changes), `PlatformKit.EventCoalescer` (to debounce). No UI imports.

Owning milestones: M2 (basic dirty-set + badge trie for the FinderSync alpha), M3 (cursors for log/diff windows).

### `ConflictKit` — stub (M4)

Three-way merge data model + hunk classifier + resolver. AI suggestions plug in here via `AIKit`. Public types will include `Conflict`, `ConflictHunk`, `Resolution`, plus a state machine for the merge-resolver task window.

### `AIKit` — stub (M7)

Provider abstraction (Anthropic, OpenAI, Ollama, Apple on-device). Prompts versioned in `Sources/AIKit/Prompts/*.md` per ADR 0037. Eval harness in `tests/ai-evals/` (ADR 0038).

### `LFSKit` — stub (M6)

LFS pointer parsing, smudge/clean orchestration, install-flow coordination. Shells out to `git-lfs` via `GitCore.Runner`.

### `SubmoduleKit` — stub (M6)

Submodule graph, nested-repo discovery, badge state propagation.

### `SubtreeKit` — stub (M6)

The "Import History from Another Repo" wizard backing logic (ADR 0032). Uses `git subtree` (built into git, no extra binary).

### `SafetyKit` — stub (M2 / M5)

Snapshot refs (`refs/sprig/snapshots/<timestamp>/<op>`) for destructive-op undo per ADR 0033. Tiered confirmations. Force-push aliasing (always `--force-with-lease --force-if-includes` per ADR 0052).

### `IPCSchema` — stub (M2)

`Codable` request/response/event structs. Transport-agnostic — XPC on macOS, named pipes on Windows, D-Bus or UNIX socket on Linux all speak the same schema (ADR 0048 §12.6).

### `PlatformKit` — live (M1)

Protocols only — no platform code. Currently exposes:

- `FileWatcher` protocol — `start(paths:) -> AsyncStream<WatchEvent>`, `stop() async`.
- `WatchEvent` + `WatchEventKind` (created/modified/removed/renamed/overflow/unknown).
- `EventCoalescer` — pure-value priority-weighted dedupe over time windows.

To be added as their owners land: `CredentialStore`, `NotificationPresenter`, `UpdateChannel`, `Transport`, `ServiceLauncher`, `PathResolver`, `GitLocator`.

### `DiagKit` — stub (M2)

Structured logging, opt-in crash reports per ADR 0014. Diagnostic-bundle collection.

### `StatusKit` — stub (M3)

Cross-repo "Sprig Status" overview surface (ADR 0034). The shell-side notification + status window.

### `TaskWindowKit` — stub (M3)

Portable task-window base (view models only — no SwiftUI imports). Per ADR 0055 the macOS shell uses SwiftUI + AppKit on top of these view models, the Windows shell uses swift-cross-ui on top of the same view models.

### `UIKitShared` — stub (M3)

Portable view-model primitives shared by task windows. Same import rules — no SwiftUI / AppKit.

## Tier 2 — platform adapters

Pattern for every Tier-2 package:

```
packages/<Name>/Sources/<Name>/         # protocol + portable utilities
packages/<Name>/Sources/Mac/            # #if os(macOS) — native macOS impl
packages/<Name>/Sources/Linux/          # #if os(Linux)  — native Linux impl (often a stub)
packages/<Name>/Sources/Windows/        # #if os(Windows) — native Windows impl (often a stub)
```

CI requires every package to compile on all three OSes (`fatalError` stubs are fine for non-target platforms).

### `WatcherKit` — live (M1) + stub Linux/Windows native impls (post-M2)

- `Sources/WatcherKit/MockFileWatcher` — portable, test fixture.
- `Sources/WatcherKit/PollingFileWatcher` — portable, used on Linux and Windows today (also macOS fallback for network/iCloud volumes per ADR 0022).
- `Sources/Mac/FSEventsWatcher` — live; CoreServices FSEvents.
- `Sources/Linux/INotifyWatcher` — stub.
- `Sources/Windows/ReadDirectoryChangesWatcher` — stub. Planned for M2-Win once the shell extension lands; brings Windows perf parity with FSEvents.

### `CredentialKit` — protocol-only

Plan: `KeychainStore` (macOS), `SecretServiceStore` (Linux libsecret), `WindowsCredentialStore` (Windows Credential Manager + DPAPI fallback). Owning milestone: M5 / M6 (sign-in flows for GitHub/GitLab).

### `NotifyKit` — protocol-only

Plan: `UNUserNotificationCenter` (macOS), `notify-send`/D-Bus (Linux), `WinRT ToastNotificationManager` (Windows). Owning milestone: M3 (status notifications), M4 (conflict resolved notifications).

### `UpdateKit` — protocol-only

Plan: Sparkle (macOS, ADR 0009/0046), package-manager-update on Linux, WinSparkle or equivalent (Windows, see ADR 0055 open question). Owning milestone: M9.

### `LauncherKit` — protocol-only

Plan: `SMAppService` (macOS 13+), systemd `--user` (Linux), Windows Service Control Manager (Windows). Owning milestone: M2.

### `TransportKit` — protocol-only

Plan: `NSXPCConnection` wrapped to carry `Codable` envelopes (macOS), named pipes (Windows), D-Bus or UNIX socket (Linux). Single wire-message schema across all of them (`IPCSchema`). Owning milestone: M2.

### `AgentKit` — protocol-only

Plan: agent process lifecycle helpers — install / start / stop / health-check. Wraps `LauncherKit` + IPC. Owning milestone: M2.

## Tier 3 — platform shells

### `apps/macos/` — stub (M2-Mac onward)

Will contain `SprigApp/` (SwiftUI + AppKit task windows), `SprigAgent/` (LaunchAgent wrapper around the engine), `SprigFinder/` (FinderSync extension), `Installer/` (DMG + notarization scripts), `Sparkle/` (appcast config).

### `apps/windows/` — stub (M2-Win onward, 1.0 deliverable per ADR 0054)

Will contain a swift-cross-ui task-window app (per ADR 0055), a Windows Service host of `AgentKit`, a C++/COM Explorer shell extension (`SprigExplorer/`, separate process from the swift app per Windows shell-extension architecture norms), an MSIX installer manifest, and a WinSparkle (or equivalent) appcast.

### `apps/linux/` — stub (post-1.0)

Linux GUI shell deferred per ADR 0054. Probably Nautilus first (covers GNOME); Dolphin / Thunar / Nemo follow as community contributions.

## CLI

### `cli/sprigctl/` — live (M1)

Command-line companion. Subcommands implemented today: `version`, `status`, `watch`, `repos`, `log`. Uses `swift-argument-parser` for parsing; depends on `GitCore` + `WatcherKit` + `PlatformKit`.

Each subcommand has a paired `--json` flag for machine-readable output. JSON wire types are private to each command so the JSON contract evolves independently of the public Swift API.

Owning milestone: M1 (today) plus opportunistic additions whenever a feature lands in the engine (e.g. when `RepoState` lands, `sprigctl repos --status` becomes useful).
