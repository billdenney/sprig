# Shell Integration

How Sprig hooks the OS file manager — Finder on macOS, Explorer on Windows — to draw overlay badges and surface the right-click verb menu. This is the load-bearing UX of the product: Sprig has no main app window (ADR 0030), so the shell extension is *where users meet Sprig*.

ADR cross-references: 0019 (10-badge set), 0020 (context-menu layout), 0030 (Finder-first / no main window), 0031 (submodules in shell), 0034 (no menu-bar helper), 0048 (cross-platform tier rules), 0054 (Windows GUI shell at 1.0).

Companion research: [`../research/macos-finder-apis.md`](../research/macos-finder-apis.md), [`../research/windows-shell-apis.md`](../research/windows-shell-apis.md).

## Shared model — agent + thin extension

Both platforms use the same architecture: the shell extension is **dumb**, and SprigAgent (LaunchAgent on macOS, Windows Service on Windows) does all the work.

```
┌────────────────────────────────────────────────────────────────────┐
│                  OS file manager (Finder / Explorer)               │
│   ┌──────────────────────────────────────────────────────────────┐ │
│   │   Sprig shell extension                                      │ │
│   │   - asks "badge for <path>?"  (sync, must answer in <50ms)   │ │
│   │   - asks "menu items for <selection>?"  (sync, <100ms)       │ │
│   │   - on click, sends a verb request and returns immediately   │ │
│   │   - holds NO long-lived state beyond a small badge cache     │ │
│   └────────┬──────────────────────────▲──────────────────────────┘ │
└────────────┼──────────────────────────┼────────────────────────────┘
             │ IPC (XPC / named pipe)   │ push: badge invalidations,
             │ request/response         │ menu cache updates
             ▼                          │
       ┌─────────────────────────────────┐
       │           SprigAgent            │
       │  - WatcherKit + RepoState       │
       │  - badge trie keyed by path     │
       │  - CommandRouter for verbs      │
       │  - launches task windows        │
       └─────────────────────────────────┘
```

Why this shape:

- **macOS FinderSync extensions have a hard memory ceiling and are killed liberally** by `cfprefsd` and `launchd`. Anything they hold is forfeit on the next restart.
- **Windows shell extensions run inside `explorer.exe`.** A crash here takes the user's desktop with it. We minimize the surface inside the extension to almost nothing.
- The badge trie + dirty set live in SprigAgent (Tier 1, in `RepoState`) and are reused by every consumer — shell extension, CLI, future macOS Sprig task windows, future Windows GUI.

The **single wire schema** for all extension ↔ agent traffic lives in `IPCSchema` (Tier 1 Codable structs). XPC on macOS, named pipes on Windows, both speak the same envelopes.

## Badge set (ADR 0019)

10 distinct overlay states. Same iconography on both platforms; different rendering pipelines.

| State | When | Notes |
|---|---|---|
| **clean** | tracked file matches HEAD | Default for tracked-and-unmodified |
| **modified** | tracked file differs from HEAD in working tree | |
| **added** | new file already staged | |
| **staged** | tracked file modified and staged | Distinct from "modified" so users can see at a glance what's queued |
| **untracked** | not in index, not ignored | |
| **conflict** | unmerged path | Highest priority — overrides any other state |
| **ignored** | matches `.gitignore` | Suppressed at "Minimal" reveal level (default Rich) |
| **lfs-pointer** | LFS pointer file (not yet smudged) | Surfaced even when otherwise clean |
| **submodule-init-needed** | submodule directory present, not initialized | |
| **submodule-out-of-date** | submodule HEAD differs from super-repo's recorded SHA | |

User chooses reveal level in Preferences (per ADR 0019): Minimal 5 / Rich 8 (default) / Full 10.

**Conflict always wins.** If a path could be `modified` *and* `conflict`, we draw `conflict`. The badge trie stores the highest-priority state per path so resolution is O(1).

### macOS rendering

`FIFinderSyncController.setBadgeIdentifier(_:for:)` takes a string identifier we register at extension init via `setBadgeImage(_:label:forBadgeIdentifier:)`. There's no documented cap on identifier count, but Apple recommends keeping it small (<32) — well within budget.

Asset catalog: `apps/macos/SprigFinder/Resources/Badges.xcassets/`. PDFs at 16×16 nominal, scaled by AppKit. Each badge has light + dark variants and a high-contrast variant per ADR 0042 (a11y).

### Windows rendering

`IShellIconOverlayIdentifier` (one COM class per badge state) — and **the OS allows only 15 overlay handlers across all installed apps**, sorted alphabetically by registry key name. OneDrive, Dropbox, Google Drive, Box, and TortoiseGit collectively hoard the slots. See [`../research/windows-shell-apis.md`](../research/windows-shell-apis.md) for the full politics.

Mitigation strategy:

1. We register **at most 5** badge handlers under names like `   SprigClean`, `   SprigModified`, `   SprigConflict`, `   SprigStaged`, `   SprigUntracked` (leading spaces force alphabetical priority above OneDrive et al). The other five logical states map onto these five visually distinct icons (e.g. `lfs-pointer` reuses `clean` with a dot we apply at bitmap-composition time, since shell-overlay-handlers are pure passthroughs of fixed icons).
2. We expose a Preferences toggle: "Reduce overlay slot usage to 3" — clean, modified, conflict only — for users running OneDrive + Dropbox + a vendor tool.
3. We expose another toggle: "Disable overlay icons" — degrades gracefully to "context menu only," which Windows users coming from TortoiseGit are familiar with as a trade-off.

This entire situation is documented to users in the first-run flow and in [`../research/windows-shell-apis.md`](../research/windows-shell-apis.md). It is the single biggest UX regression vs macOS.

## Context menu (ADR 0020)

Same logical structure on both platforms; the visual rendering is per-OS.

**Top level (flat):**

- **Commit…** (when there are changes)
- **Push** / **Pull** / **Fetch** (when on a branch with upstream)
- **Create Branch…**
- **Diff…** (when one or two files selected)
- **Show Log…**
- **Resolve Conflicts…** (only when there are unmerged paths)

**`Sprig ▶` submenu (advanced):**

- Stash → Stash Changes…, Pop, List…
- Reset → Reset Soft, Reset Mixed, Reset Hard… (typed-phrase confirm at high tier)
- Reflog…
- Submodules → Init, Update, Switch Tracked Branch…, Open in Sprig
- Settings…
- Status… (cross-repo status window)
- Preferences…

**Non-repo right-click** in a directory shows just **Clone into here…** at top level. No `Sprig ▶` submenu.

**Multi-select** in a repo: the menu collapses to operations that make sense on multiple files (Stage, Unstage, Diff, Discard…), and per-file operations (Blame, History) are hidden.

### macOS menu rendering

`FIFinderSyncController.menu(for: .contextualMenuForItems)` returns an `NSMenu`. The flat top-level items append directly; the submenu is a single `NSMenuItem` with `submenu = NSMenu(...)` populated.

Constraints:

- The extension's `menu(for:)` must return synchronously. We pre-warm a per-path menu cache on FSEvents updates (agent pushes to extension), so the call is a hash-map lookup.
- Action selectors run in the extension process. They must not block — they fire-and-forget an XPC message to the agent and return. The agent then opens the relevant task window via `NSWorkspace.openApplication(at:)` or sends a `LaunchTaskWindow` IPC to the SprigApp host process.

### Windows menu rendering

`IContextMenu::QueryContextMenu` populates a `HMENU`. Same flat-plus-submenu shape. The actual menu items are described as a tiny in-process catalog; selecting one fires `IContextMenu::InvokeCommand`, which we translate into a named-pipe envelope to SprigAgent.

Modern Windows 11 puts third-party context menus behind a "Show more options" item (the legacy menu). To get items in the **streamlined** menu surface, we need an **`IExplorerCommand`** implementation registered via `Package.appxmanifest` from the MSIX installer. This is documented in detail in [`../research/windows-shell-apis.md`](../research/windows-shell-apis.md). Plan: ship both — `IContextMenu` for legacy/right-click+Shift, `IExplorerCommand` for Windows 11 streamlined, single source of truth for the menu structure.

## Performance budget for the extension

These are non-negotiable; if we can't hit them we're degrading the user's whole desktop.

| Surface | Budget |
|---|---|
| Badge query (`badgeIdentifier(for:)` / `IShellIconOverlayIdentifier::IsMemberOf`) | < 50 ms p99, < 5 ms p50 |
| Menu construction (`menu(for:)` / `IContextMenu::QueryContextMenu`) | < 100 ms p99 |
| Memory ceiling for the extension process | < 30 MB resident |
| Cold-start (first badge query after agent restart) | < 500 ms (badge cache primed lazily) |

How we hit them:

1. **Badge trie in agent, snapshot pushed to extension.** Lookups are O(log path-depth) hashmap walks.
2. **Menu cache per-path, invalidated on RepoState change.** Built when the user mouses to the parent directory, ready by the time they right-click.
3. **No git invocations in the extension process, ever.** Even a fork/exec of `git status` would blow the budget.
4. **Async warmup.** When the extension loads, it sends `Subscribe(roots:)` to the agent and starts receiving badge-update pushes. The first user-facing badge call is already cache-hot.

## What can go wrong

### macOS

- **Extension killed by `launchd`.** The agent re-pushes the full badge state on next reconnect; user sees a momentary stale-badge window during the gap. We don't try to keep the extension alive at all costs — the OS knows better than we do.
- **`com.apple.FinderSync` not running** (rare but happens after major macOS updates). Sprig's first-run check verifies extension registration via `pluginkit -m -p com.apple.FinderSync` and surfaces a Preferences row to re-register if absent.
- **User-granted-paths.** FinderSync only renders badges in directories the user has approved in System Settings → Extensions → Finder Extensions → Sprig. We surface this clearly during onboarding (ADR 0039) — adding a watch root in Sprig's Preferences should also walk the user through the system grant.
- **Network volumes.** FSEvents misses events on SMB/AFP/NFS shares. ADR 0022 fallback: PollingFileWatcher, with a banner.

### Windows

- **15-overlay-slot starvation.** See [`../research/windows-shell-apis.md`](../research/windows-shell-apis.md). Sprig prefixes registry keys with leading spaces; if OneDrive et al do the same arms race we lose. Mitigation: opt-in low-slot mode + opt-out entirely.
- **Extension crash hangs explorer.exe.** Mitigation: every entry point is wrapped in `try/catch`, every IPC call has a 2-second timeout falling back to "no badge" / "no menu" rather than blocking. We never call into the agent on the UI thread synchronously without a timeout.
- **Antivirus inspection.** Some AV products quarantine new shell extensions. The MSIX installer signs the DLL with the same EV cert as the rest of Sprig (ADR 0046 follow-up); no detect-and-install of an unsigned binary.
- **Per-user vs system install.** Sprig installs per-user (no admin required). Per-user shell extensions are a thing, but per-machine installs of OneDrive et al take precedence in registration ordering. Document, don't fight.

## Things the shell extension explicitly does not do

- **No git invocations.** Even read-only ones.
- **No filesystem walks.** The watcher is the agent's job.
- **No UI rendering beyond what the OS asks for** (badge for a path, menu for a selection).
- **No user-visible windows.** Task windows are launched by the agent (macOS) or SprigApp (Windows GUI shell), never by the extension. The extension is `NSExtensionPointIdentifier = com.apple.FinderSync` / a COM in-proc DLL — neither is allowed to own UI by Apple's / Microsoft's design.
- **No persistence.** All state is rehydrated from the agent on connect. If we ever need a small local cache, it goes in App Group container (macOS) / `%LOCALAPPDATA%\Sprig\extension-cache` (Windows), not in the extension's own preferences.

## Test strategy

- **Unit tests** for the menu-construction logic and badge-priority resolution live in Tier-1 packages (`RepoState`, `StatusKit`) — that logic is portable.
- **Snapshot tests** for badge rendering against a synthesized RepoState live per-platform in the shell-extension targets (XCTest for macOS; a small `windows-tests/` harness for Windows once the extension lands).
- **Integration tests** against a real Finder use AppleScript to right-click and assert menu structure; on Windows we'll use UI Automation. These live in `tests/e2e/` with platform guards.
- **Performance tests** measure the badge-query and menu-construction p99 against a 100k-file fixture repo on each OS. They run nightly per [`performance.md`](performance.md).

## Milestone alignment

- **M2-Mac** ships the FinderSync alpha — badges + the MVP-10 menu items.
- **M2-Win** ships the Explorer extension alpha — `IShellIconOverlayIdentifier` + `IContextMenu`/`IExplorerCommand` for the same MVP-10.
- Both depend on `RepoState` (M2) and the IPC/transport plumbing (`TransportKit`, `AgentKit` — M2).
- **M9** ships both shells together at 1.0 (ADR 0054).
