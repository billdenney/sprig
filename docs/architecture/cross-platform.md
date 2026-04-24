# Cross-Platform Architecture

Sprig is macOS-only at 1.0 but the codebase is structured so a future Windows or Linux port is additive.

This document mirrors §12 of the master plan (`/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`). The plan is the source of truth; this file will be expanded during M0 with concrete code examples.

## The three tiers

1. **Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`) — pure Swift + Foundation. Must compile on macOS, Linux, Windows.
2. **Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`) — protocol in `Sources/<Pkg>/`; macOS impl in `Sources/Mac/`; Linux/Windows stubs in `Sources/{Linux,Windows}/`.
3. **Platform shells** (`apps/{macos,windows,linux}/`) — full rewrite per OS; only macOS populated at 1.0.

## Hard rules (CI-enforced)

1. No `AppKit`/`SwiftUI`/`Cocoa`/`FinderSync`/`Combine`/`ServiceManagement`/`Sparkle` imports in `packages/`.
2. No `#if os(...)` in portable package sources; only in `Sources/{Mac,Linux,Windows}/`.
3. No hardcoded absolute paths.
4. Every `PlatformKit` protocol has Mac/Linux/Windows source files from day 1 (Linux/Windows may be `fatalError` stubs).
5. `ci-linux` builds `packages/` on every PR; red build blocks merge.

## Adapter seams

See `packages/PlatformKit/` for the authoritative protocol list: `FileWatcher`, `CredentialStore`, `NotificationPresenter`, `UpdateChannel`, `Transport`, `ServiceLauncher`, `PathResolver`, `GitLocator`.

## Porting checklist

When a Windows or Linux port begins:

1. Populate `apps/<platform>/` with the platform shell.
2. Replace `fatalError` stubs in `packages/*/Sources/{Linux,Windows}/` with real impls.
3. Flip `ci-<platform>` to required-green.
4. Write a port-specific `docs/architecture/<platform>-port.md`.

No file moves. No protocol refactors. That's the deal.
