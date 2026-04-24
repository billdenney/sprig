# Vision

Sprig is a macOS-native, Finder-first Git client. See the master plan for full context.

## Target users

- **Novices** who want to use git without learning the CLI.
- **Power users** who want a fast, safe, scriptable GUI that stays out of the way.
- **Teams** that want shared defaults, safe destructive ops, and stacked-PR workflows.

## Differentiation

Deep Finder integration (badges + context menu on every file/folder) combined with task-specific windows for focused work. No persistent "app window with a file tree" — Finder is the file tree.

## Non-goals (at 1.0)

- Not cross-platform (but the core is portable for future ports — see `architecture/cross-platform.md`).
- Not a code editor or a hosting service.
- Not a replacement for the `git` CLI — a companion.
