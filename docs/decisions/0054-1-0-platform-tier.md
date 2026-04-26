---
status: accepted
date: 2026-04-25
deciders: maintainer
consulted: —
informed: —
supersedes: partial 0009, partial 0030, partial 0034
---

# 0054. 1.0 platform tier — macOS + Windows GUI shells, Linux engine-only

## Context

Earlier ADRs (0009 distribution, 0030 Finder-first architecture, 0034 no menu-bar helper) were drafted on the assumption that **the macOS app is the only user-facing shell at 1.0**. At the time, that was right: GUI work on a single OS is plenty for a 1.0, and the engine being portable was framed as enabling *future* ports.

Two things have changed since:

1. **The engine is already first-class on Windows** (since the elevation of `ci-windows` to required-green running the full test suite). `sprigctl` runs end-to-end on Windows today. The shell port is the only remaining gap, not a from-scratch ground-up effort.
2. **Sprig's value proposition on Windows is at least as strong as on macOS.** TortoiseGit was the Sprig-shaped reference for two decades on Windows, but it hasn't kept up with modern git (no fsmonitor integration, dated UI, no AI assist). Shipping a modern shell-integrated Git client on Windows at 1.0 is the project's clearest opportunity to capture an installed user base.

The maintainer has explicitly decided to commit Windows GUI shell into 1.0 scope alongside the macOS shell. Linux GUI shell remains post-1.0 (Linux desktop is too fragmented — Nautilus, Dolphin, Thunar, Pantheon Files, etc. — to multiplex at 1.0).

## Decision

**Sprig 1.0 ships GUI shells for both macOS and Windows.** Linux 1.0 ships engine + `sprigctl` CLI only; Linux GUI shell is post-1.0.

Concretely, the 1.0 macOS deliverables (existing) are:
- FinderSync extension (overlay badges + context menu)
- LaunchAgent for the background SprigAgent
- Task windows (CommitComposer, LogBrowser, DiffViewer, MergeConflictResolver, BranchSwitcher, etc.) in SwiftUI + AppKit
- DMG + Homebrew Cask distribution
- Sparkle auto-update

The 1.0 Windows deliverables (new) are:
- **Explorer shell extension** implementing `IShellIconOverlayIdentifier` (overlay badges) and `IContextMenu` (right-click verbs) — typically C++/COM with a thin Swift FFI bridge to the SprigAgent.
- **Windows Service** (or scheduled task running in the user session, TBD) for the SprigAgent.
- **Same task windows in swift-cross-ui** (see ADR 0055), reusing the macOS view-model code via the portable `TaskWindowKit` package.
- **MSIX installer** (preferred) with winget manifest; MSI fallback if MSIX proves problematic for the shell extension.
- **WinSparkle** (or chosen equivalent — to be ratified separately) auto-update.

Linux 1.0:
- Engine + `sprigctl` CLI work today, no change.
- Distribution: build + release the binary via the same Swift toolchain; package as a tarball or distro-specific package per community contribution.
- GUI shell explicitly post-1.0.

## Consequences

**Positive**
- Reaches Windows users at 1.0 — the project's clearest underserved market.
- Forces architectural discipline now: anything macOS-shell-specific that bleeds into the engine is a portability bug, caught before it ships.
- The view-model/state work done for the macOS task windows is reused on Windows without rewrite (ADR 0055 picks swift-cross-ui specifically for this reason).

**Negative / trade-offs**
- 1.0 ship date pushes out. Roughly: every macOS-shell milestone (M2 FinderSync, M3 task windows, M4 merge UI) gets a Windows-shell counterpart. If they're done in series, 1.0 doubles in calendar duration; if interleaved with shared infrastructure (a contributor with both Mac and Windows expertise), maybe 1.5×.
- Windows-specific surface area requires Windows expertise on the contributor side. Until that contributor exists, the work blocks on the maintainer.
- Distribution doubles: macOS DMG + Homebrew Cask **and** Windows MSIX + winget. Both pipelines need release engineering.
- Updater story doubles: Sparkle for macOS, WinSparkle (or equivalent) for Windows.

**What this supersedes**
- **ADR 0009 (distribution = direct notarized DMG + Sparkle)**: still correct for macOS; extended to "MSIX + winget + WinSparkle" for Windows. Mac App Store remains out of scope (per 0009's original logic).
- **ADR 0030 (Finder-first architecture, no main app file tree)**: the principle ("the OS file manager is the file tree, no separate file-browser window") applies to both Finder and Explorer. The Windows shell will be Explorer-first, mirroring the Finder-first model. No top-level Sprig "main window with a file tree" on either OS.
- **ADR 0034 (no menu-bar helper on macOS)**: macOS half stands. **Open question for Windows**: do we ship a Windows tray icon (the Windows analogue) or no tray? Probably mirror the macOS no-tray decision; revisit during Windows-shell research (M2-Win).

## Alternatives considered

1. **Keep 1.0 macOS-only, ship Windows post-1.0.** Faster 1.0 ship; defers the Windows opportunity. Risk: project gets typed as "another Mac-only Git GUI" before the Windows version arrives.
2. **Ship 1.0 with Windows + Linux GUI shells.** Linux desktop fragmentation (5+ file managers, each needing its own extension) makes this multiplicative cost. Rejected; Linux GUI shell is post-1.0 (community-contributed Nautilus first, then others).
3. **Ship sprigctl-only on Windows at 1.0, no GUI.** Already the de-facto state today. Decided against — `sprigctl` alone is not the project's value proposition on Windows; the Explorer integration is.

## Links

- ADR 0055 — Windows GUI stack (swift-cross-ui).
- ADR 0009 — distribution.
- ADR 0030 — Finder-first architecture.
- ADR 0034 — no menu-bar helper.
- `docs/architecture/cross-platform.md` — three-tier engine architecture; this ADR adds Windows to the user-facing shell tier.
- Master plan §3 (Decision Log) and §6 (Roadmap) — updated alongside this ADR.
