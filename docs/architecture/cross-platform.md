# Cross-Platform Architecture

Sprig's macOS app is the user-facing 1.0 target, but the **engine is portable** and runs first-class on macOS, Linux, and Windows. Every PR has CI that builds, tests, and lints on all three.

This document mirrors §12 of the master plan ([`docs/planning/master-plan.md`](../planning/master-plan.md)).

**Companion doc:** [`cross-platform-quirks.md`](cross-platform-quirks.md) catalogs the *operational* surprises we've hit during development — symptoms, root causes, fix patterns, and upstream-fix candidates. Add an entry there whenever a CI failure surfaces on one platform but not another.

## Platform support matrix

| Surface | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| `GitCore` (Runner, CatFileBatch, PorcelainV2Parser) | ✅ | ✅ | ✅ | Shells out to system `git`. |
| `PlatformKit` (FileWatcher protocol, EventCoalescer) | ✅ | ✅ | ✅ | Pure-portable. |
| `WatcherKit.MockFileWatcher` | ✅ | ✅ | ✅ | Pure-portable. |
| `WatcherKit.PollingFileWatcher` | ✅ | ✅ | ✅ | Pure-portable; default on non-macOS, fallback on macOS via `--polling`. |
| `WatcherKit.FSEventsWatcher` | ✅ | — | — | macOS-only kernel API; CoreServices FSEvents. |
| `sprigctl` (version / status / watch / repos / log / agent / recover / conflicts) | ✅ | ✅ | ✅ | Every subcommand works on all three OSes. The Windows engine is testable today via the CLI; per-PR `ci-windows` runs the full suite. |
| `apps/macos/SprigApp` (FinderSync, LaunchAgent, …) | M2-Mac+ | — | — | The macOS user-facing shell. Tier-3 platform shell. **Not started** — stub README in `apps/macos/` only; all 8 M2-Mac exit criteria are open. |
| `apps/windows/SprigApp` (Explorer shell extension, Windows Service host, MSIX, …) | — | — | M2-Win+ | 1.0 deliverable per ADR 0054. Stub README in `apps/windows/` until M2-Win begins. |
| `apps/linux/SprigApp` (Nautilus extension, …) | — | — | post-1.0 | Linux GUI shell explicitly out of 1.0 scope per ADR 0054 (Linux desktop is too fragmented to multiplex). |

CI required-green per platform: macOS (`ci-macos`), Linux `packages/` (`ci-linux`), Windows full test suite (`ci-windows`).

## The three tiers

1. **Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`) — pure Swift + Foundation. Compiles + tests on macOS, Linux, Windows.
2. **Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`) — protocol in `Sources/<Pkg>/`; macOS impl in `Sources/Mac/`; portable Linux/Windows fallbacks where they exist (e.g. `PollingFileWatcher`); per-OS native impls coming as needed.
3. **Platform shells** (`apps/{macos,windows,linux}/`) — full rewrite per OS. **None are populated today**; all three hold a stub README.

## Hard rules (CI-enforced)

1. No `AppKit`/`SwiftUI`/`Cocoa`/`FinderSync`/`Combine`/`ServiceManagement`/`Sparkle` imports in `packages/`.
2. No `#if os(...)` in portable package sources; only in `Sources/{Mac,Linux,Windows}/` adapter subdirs.
3. No hardcoded absolute paths (POSIX or Windows). Use `PathResolver`.
4. No POSIX-only assumptions (e.g. `/usr/bin/env`, `/`-separator) in either production or test code. Use case-insensitive `PATH` walks; resolve `git` (vs `git.exe`) per platform.
5. Every `PlatformKit` protocol has Mac/Linux/Windows source files from day 1 (non-target platforms may be `fatalError` stubs).
6. CI runs the full test suite on macOS, Linux, and Windows. Red builds block merge on all three.

## Cross-platform IO conventions

Three footguns surfaced during the M2 agent track that every CLI/test author should know:

### Stdout/stderr line endings

Swift's default `print(...)` writes to stdout through a C-runtime `FILE *` with text-mode semantics on Windows, which translates `"\n"` → `"\r\n"` at the byte level. Linux and macOS pipes are byte-for-byte LF-only. CRLF on stdout is unconventional for streaming-JSON tooling (`jq -c` and similar consumers expect LF) and was the underlying cause of slice A9's Windows CI failure.

Convention: **every CLI command writes to stdout via `StdoutStream`** (see `cli/sprigctl/Sources/StdoutStream.swift`), which calls `FileHandle.standardOutput.write(Data(...).utf8)` directly — no text-mode translation, LF on every platform. Same shape as the existing `StderrStream`.

```swift
var out = StdoutStream()
print("hello", to: &out)              // LF on every platform
print("don't do this")                // CRLF on Windows; only safe for one-off scripts
```

`StderrStream` is unchanged — `FileHandle.standardError.write(Data(...).utf8)` was already byte-for-byte. Use either depending on whether the output is data (stdout) or diagnostic text (stderr).

### Splitting strings on newlines

Swift's `String` is a collection of *grapheme clusters*. Per Unicode TR#14, a CRLF pair (`"\r\n"`) is **one** cluster, not two. So `someString.split(separator: "\n", ...)` against a CRLF-terminated string returns a single element containing every line concatenated — the separator `"\n"` (one cluster) never matches any cluster in the input.

```swift
"a\r\nb\r\nc".split(separator: "\n", omittingEmptySubsequences: true)
// → ["a\r\nb\r\nc"]   (one element, NOT three)

"a\nb\nc".split(separator: "\n", omittingEmptySubsequences: true)
// → ["a", "b", "c"]   (works only for LF-only input)
```

The right primitive: **`String.enumerateLines(invoking:)`** — Foundation's canonical line iterator that handles LF, CRLF, CR-alone, and NEL uniformly.

```swift
var lines: [String] = []
input.enumerateLines { line, _ in lines.append(line) }
// Works for "a\nb\nc", "a\r\nb\r\nc", and mixed.
```

Use `enumerateLines` for any byte stream that might originate from a different platform — subprocess output, network reads, files written elsewhere. The CLI now uses `StdoutStream` so its own output is LF, but tests should still iterate with `enumerateLines` as defense-in-depth (the convention may change; tests outliving the convention shouldn't break).

This isn't a Foundation bug — Swift's grapheme-cluster `String` semantics are correct per Unicode spec. It's a portability footgun that the project leans against by convention.

### Windows filesystem propagation latency

**Filesystem changes on Windows can take up to 2 seconds to be visible** to readers — including subprocesses like `git`. A `Data.write(to: file)` followed immediately by spawning `git status` may see the pre-write state on Windows even though Linux/macOS see the post-write state instantly.

This shapes test design:

- Tests that write a file and expect a subprocess (`git`, `sprigctl`) to *observe* the change need a ≥2 s window. `--duration 0.5` is too tight on Windows; `--duration 2.5` or higher leaves margin.
- Polling watcher tests already account for this — see PR #27 (`fix(WatcherKit): bump PollingFileWatcher test pre-write delays for Windows`).
- Tests that don't depend on a *new* write reaching disk are fine at shorter timeouts. Spinning up `RepoAgent` against a repo whose state was committed earlier in setup is OK because the commit's index update has already propagated by the time the agent runs.

When a Windows test goes flaky with timing-related assertions — empty `git status` outputs after a recent file write, `RepoAgent` initial refresh reporting no entries when one was just written — the answer is almost always "increase the timeout / duration to ≥ 2 s," not adjust parser/decoder logic. The grapheme-cluster trap above is the *other* common Windows-specific flake; rule out the timing one first since it's the more common cause.

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
