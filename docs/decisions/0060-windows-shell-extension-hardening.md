---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0060. Windows shell extension hardening

## Context and problem statement

ADR 0054 commits Sprig 1.0 to a Windows GUI shell with Explorer integration as the flagship Windows differentiator. The competitive review (master plan §13.3-I, §13.5) identifies eight concrete patterns that must be designed into the M2-Win track from day one. Skipping any of them produces failure modes that are documented, reproducible, and high-frequency in the existing Windows shell-extension landscape:

- **15-overlay-slot registry contention.** `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers` is iterated alphabetically and only the first 15 entries that load successfully are honored. In a typical 2026 corporate Windows environment, OneDrive registers up to 7 entries, Dropbox 3, Google Drive 4, Box 3, Adobe Creative Cloud 2, plus the previous git tool (TortoiseGit registers 5 by default). That's ≥24 contenders for 15 slots before Sprig appears.
- **Windows 11 "Show more options" demotion.** Win11 23H2+ routes legacy `IContextMenu` extensions to a "Show more options" submenu (Shift+F10 still shows them; mouse users see only modern handlers). The modern API is `IExplorerCommand` packaged via MSIX. TortoiseGit added partial `IExplorerCommand` support late and incomplete; Git Extensions never did. Sprig must not repeat.
- **Synchronous git work in `IContextMenu::QueryContextMenu`** is TortoiseGit's #1 long-standing pain point — Explorer hangs on right-click when the context-menu population synchronously runs `git status` in a large repo. The shell handler must return in <10 ms, with all git work delegated to a long-lived background process.
- **Post-update extension de-registration**, **OneDrive / Dropbox / `\\wsl$\` path failure modes**, **CRLF auto-detection committing CRLF into LF-canonical repos**, and **long-paths registry off** (>260-char paths breaking Explorer + every shell extension).

These failure modes are all observable in TortoiseGit / Git Extensions / GitHub Desktop today. Designing around them is cheaper than fixing them post-hoc.

## Decision drivers

- The Windows shell is the flagship 1.0 surface alongside FinderSync; reliability is non-negotiable.
- Windows enterprise environments are adversarial (AV quarantine, GPO-locked registry, OneDrive sync, managed feature updates).
- Preserve the Finder/Explorer-first invariant — no main-window or tray fallback.
- Implementation choices made now (e.g., MSIX vs MSI; `IExplorerCommand` vs `IContextMenu`) cascade through the M2-Win / M3-Win / M9-Win design.

## Decision

Eight load-bearing rules for the Windows shell extension, all required-on at M2-Win shipment:

### 1. One overlay handler, not five — encode status via `IconIndex`

Sprig registers a **single** entry in `ShellIconOverlayIdentifiers`, named `   SprigOverlay` (three leading spaces, deliberately, to compete in the alphabetical race). The handler implements `IShellIconOverlayIdentifier::GetOverlayInfo` and dispatches all status states (modified, clean, conflict, staged, untracked, etc.) through different `IconIndex` values returned from the same handler. Specifically rejects TortoiseGit's pattern of registering separate handlers for each status (which burns 4–5 of the 15 slots).

### 2. `IExplorerCommand`-based menu from day one, MSIX-packaged

The context menu handler implements `IExplorerCommand` (with `IExplorerCommandProvider` for the "Sprig ▶" submenu) and is packaged via MSIX with the `windows.fileExplorerContextMenus` extension manifest entry. This is what surfaces the menu in Windows 11's modern "right-click" rather than behind "Show more options."

The "Sprig ▶" submenu structure is **flat — at most one level deep** because Win11's modern menu renders nested submenus inconsistently across DPI scales. Verbs flatten to direct entries: "Commit…", "Push", "Pull", "Switch Branch…", "Diff", "Log", "Sprig ▶ More…" (the last opens a small task window listing rarer verbs).

### 3. Zero git work in shell handlers; <10 ms return; all work delegated to the Windows Service

Hard rule, enforced by code review: `IShellIconOverlayIdentifier::IsMemberOf` and `IExplorerCommand::GetState` / `Invoke` MUST return in <10 ms wall-clock. Both call into the long-lived Sprig Windows Service over a named pipe (`\\.\pipe\sprig-agent-<userSID>`); the Service maintains the `RepoStateStore` cache and answers in-memory. CI test gates: a benchmark harness in `tests/benchmarks/Windows/` measures handler latency and fails on regression.

### 4. Self-healing extension registration (Windows Service validates + re-registers on every start)

The Sprig Windows Service, on startup, validates:

- The overlay handler's COM registration entry in `HKLM\Software\Classes\CLSID\{...}\InProcServer32` exists and points at the installed binary.
- The `ShellIconOverlayIdentifiers` entry exists and points at the same CLSID.
- The `IExplorerCommand` MSIX-extension manifest is registered with Windows.

If any are missing — typically caused by feature updates, AV quarantines, or competing-installer overwrites — the Service re-registers them. Logged to `AgentDiagnostics.txt`. Surface in `sprigctl status` and the Status task window.

This eliminates the "TortoiseGit users run RegisterShellExtensions.exe after every Windows update" pain.

### 5. `IPropertyHandler` + custom property schema = a "Status" column in Explorer details view

In addition to the overlay handler, Sprig registers a property handler that exposes a `System.Sprig.Status` schema with values `Clean / Modified / Staged / Conflict / Untracked / Ignored / Unknown`. Users can add a "Sprig Status" column to Explorer's details view via right-click → "More…". This is the **overlay-fallback**: when Sprig is past slot 15 in the overlay registry, status remains visible in the column. None of the surveyed Windows clients do this, so it is also a clean differentiator.

### 6. OneDrive / Dropbox / `\\wsl$\` path detection + warnings

The Windows Service maintains a list of "risky path prefixes" (`%USERPROFILE%\OneDrive\`, `%USERPROFILE%\Dropbox\`, `\\wsl$\`, etc.) and:

- **`\\wsl$\` paths**: refuse to register overlays. UNC-on-WSL FinderSync analogue is broken upstream; failed silently in TortoiseGit. Show "Overlays unavailable on WSL paths — open the repo from inside WSL with the Linux Sprig instead" toast.
- **OneDrive / Dropbox folders**: on `git init` or first `git clone` into one, show a confirmation dialog: "Repos in OneDrive frequently corrupt because OneDrive's file-on-demand placeholder reparse points break `git status` performance and conflict with `.git/index.lock` atomic renames. Move the repo? [Move…] [Proceed anyway]." Default-focus on Move. The user can disable the warning in Preferences for that folder.

### 7. `core.autocrlf=input` Windows default + line-ending preview in CommitComposer

Sprig's per-repo defaults on Windows set `core.autocrlf=input` (commits LF, checks out as-is) — never `core.autocrlf=true`. ADR 0049 already mandates this for `~/.gitconfig` defaults; this ADR re-asserts it for the Windows track and adds the visible UX:

CommitComposer's pre-commit summary panel surfaces line-ending changes. When any staged file would be committed with CRLF, a warning row appears: "3 files will be committed with CRLF line endings. Confirm? [Convert to LF] [Commit as-is] [Show files]." This eliminates the silent-CRLF class of bug that produces half of TortoiseGit's "wrong line endings" tickets.

### 8. Long-paths registry detection at agent startup; prompt to enable

On Windows agent startup, read `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled`. If it's `0` or absent, surface a one-time-per-major-version prompt:

> **Long-path support is disabled on this system.**
> Repositories with deep `node_modules` or other long paths can fail to clone or operate. Enable long-path support? (Requires elevation; affects all apps.)
> [ Enable… ] [ Skip ] [ Don't show again ]

The "Enable…" path runs an elevation prompt to set the registry value and runs `git config --global core.longpaths true`. Documented in `docs/architecture/shell-integration.md`.

## Consequences

**Positive**
- Sprig is the **best-behaved shell extension on Windows in 2026** — the closest competitor (TortoiseGit) hits each of these failure modes with documented frequency.
- The Status column is a pure differentiator; no other Windows client offers it.
- Each rule is independently testable — CI gates exist for handler latency, overlay registration, long-paths detection, and CRLF preview behavior.
- Self-healing registration eliminates an entire support-request category.

**Negative / trade-offs**
- MSIX-only at 1.0 means corporate group policies that block MSIX-installed shell extensions (rare but real) will exclude Sprig users. Mitigation: MSI fallback build for managed enterprise environments, documented in `docs/architecture/shell-integration.md`. Ratifies the master-plan §13.3-I trade-off note.
- The `IPropertyHandler` schema requires registration in `HKEY_CLASSES_ROOT\.gitsprig` (file-class) and a manifest entry — additional installer work.
- The "risky path" warnings can frustrate experienced users who *want* OneDrive-synced repos. Per-folder opt-out preserves the path.
- Status column requires manual add via Explorer "More…" — discoverability is documented in the first-run window's Tutorial mode.

## Links

- Master plan §13.3-I, §13.5.
- Related ADRs: 0048 (cross-platform extensibility), 0049 (modern-git defaults — `core.autocrlf=input`), 0053 (day-1 cross-platform scaffolding), 0054 (1.0 platform tier — Windows shell), 0055 (swift-cross-ui for the GUI), 0030 (Finder/Explorer-first), 0033 (destructive-op tiers).
- Apple-side analogue: ADR 0059 (FinderSync resilience).
- Windows shell-extension reference: <https://learn.microsoft.com/en-us/windows/win32/shell/handlers>
