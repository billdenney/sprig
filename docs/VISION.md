# Vision

Sprig is a shell-integrated Git client modelled on TortoiseGit — overlay badges, right-click context menus for every Git operation, task-specific windows for focused work. The macOS shell (Finder integration) and the Windows shell (Explorer integration) both ship at 1.0; the engine and `sprigctl` CLI are first-class on macOS, Linux, and Windows from day 1. See the master plan for full context.

## Target users

- **Novices** who want to use git without learning the CLI.
- **Power users** who want a fast, safe, scriptable GUI that stays out of the way.
- **Teams** that want shared defaults, safe destructive ops, and stacked-PR workflows.

## Differentiation

Deep shell integration (badges + context menu on every file/folder, in the OS's native file manager) combined with task-specific windows for focused work. No persistent "app window with a file tree" — the OS file manager is the file tree.

This is rare on macOS (most Git GUIs are full apps with their own browser) and the gap on Windows has been TortoiseGit for two decades — we want Sprig to be the modern equivalent on both, sharing one engine.

## Non-goals (at 1.0)

- **Not a Linux GUI shell at 1.0.** Linux desktops are fragmented (Nautilus, Dolphin, Thunar, Pantheon Files — each needs its own extension); shipping all of them at 1.0 multiplies cost. Linux engine + `sprigctl` are first-class today; a Nautilus-first GUI extension is post-1.0.
- **Not a code editor or a hosting service.**
- **Not a replacement for the `git` CLI — a companion.** Sprig shells out to the user's `git` and respects whatever config, hooks, credential helpers, and aliases are already there.
- **Not a cross-platform GUI in the Electron sense.** macOS uses Finder + AppKit/SwiftUI conventions; Windows uses Explorer + swift-cross-ui. Each shell feels native; the engine is shared.
