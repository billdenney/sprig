---
status: accepted
date: 2026-04-25
deciders: maintainer
consulted: —
informed: —
---

# 0055. Windows GUI stack — swift-cross-ui

## Context

ADR 0054 commits us to shipping a Windows GUI shell at 1.0. That shell needs:

1. A **task-window app** (Sprig's CommitComposer, LogBrowser, DiffViewer, MergeConflictResolver, BranchSwitcher, etc.) — the Windows analogue of `apps/macos/SprigApp/`.
2. A **shell extension** for Explorer (overlay badges + context menu). The shell extension is unavoidably Win32/COM (`IShellIconOverlayIdentifier`, `IContextMenu`) — outside this ADR's scope; that's a separate native-interop ADR.

This ADR picks the framework for #1.

The constraint that drives the choice: **the macOS task windows are already SwiftUI + AppKit**, and their view-model code lives in the portable `TaskWindowKit` Tier-2 package. We want to reuse the view models on Windows; rewriting them in C# / XAML would cost months and create two diverging codebases.

Three options were on the table:

1. **swift-cross-ui** (community framework that runs SwiftUI-ish view code on Windows / Linux / macOS via per-platform backends).
2. **Native WinUI 3 / WPF** (C# or C++/WinRT) talking to the Swift agent over IPC.
3. **Electron / Tauri** with the Swift agent as a sidecar.

## Decision

**swift-cross-ui** (or the closest production-ready Swift cross-platform UI framework available at the time of M3-Win) is the primary stack for the Windows GUI shell.

If swift-cross-ui isn't sufficiently mature when M3-Win starts, the fallback is **WinUI 3 in C++/WinRT** (closer to native Windows feel than C#/XAML; better Swift FFI story than C#).

The shell extension itself stays C++/COM regardless — that's not a UI-framework choice, it's the only way to integrate with Explorer.

## Consequences

**Positive**
- View-model code in `TaskWindowKit` and feature-specific kits (ConflictKit, RepoState, etc.) is reused 1:1 between macOS and Windows.
- A bug fix in a task window's logic ships to both platforms in one PR.
- Contributors only need Swift to work on most of the GUI, not Swift + C# + XAML.
- Keeps the codebase coherent: one language for the engine, the CLI, and (most of) the GUI on every supported platform.

**Negative / trade-offs**
- swift-cross-ui's Windows backend is younger than SwiftUI's macOS backend. Some Windows-native polish (notification semantics, light/dark mode timing, accessibility quirks) may need workarounds or fall back to native Win32 calls.
- The framework's API surface is a subset of SwiftUI; some macOS-shell views may need to be ported to a swift-cross-ui-compatible subset rather than 1:1 reused.
- If swift-cross-ui stalls or pivots, our fallback (WinUI 3 in C++) is real but represents a meaningful re-platform.

## Alternatives considered

**Native WinUI 3 (C# or C++/WinRT) + IPC to Swift agent.** Best Windows-native feel, especially for accessibility and theming. Cost: a second language in the GUI codebase, no view-model reuse, requires a Windows-savvy contributor to maintain. Stays as the documented fallback.

**Electron / Tauri with Swift agent as sidecar.** Largest community, fastest UI iteration. Rejected: 80–150 MB binary, several-hundred-MB RAM at idle, GPU/Chromium overhead — runs counter to ADR 0023's spirit ("defer to git, stay lean"). Also reintroduces a JS/TS toolchain only for the Windows shell, which we deliberately avoid for the macOS shell.

## Open questions deferred to M3-Win

- Exact swift-cross-ui version and backend feature parity at the time M3-Win starts. Re-evaluate before committing to detailed UI work.
- Whether the merge UI (M4) needs a Windows-specific text-rendering path. SwiftUI's `Text` is too slow for multi-thousand-line diffs on macOS (we plan AppKit `NSTextView` there); the equivalent Windows decision is open.
- How to package the task-window app + shell extension + Windows Service into a single MSIX. Standard pattern, but worth a research spike before M9.

## Links

- ADR 0054 — 1.0 platform tier (commits to Windows GUI shell at 1.0).
- ADR 0023 — git invocation strategy (shell out to system git, stay lean).
- ADR 0030 — Finder-first / Explorer-first architecture.
- swift-cross-ui — https://github.com/stackotter/swift-cross-ui (community framework; check current state).
