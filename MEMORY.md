# MEMORY.md — Sprig project state index

This file is an **index of project-state memory pointers** used in tandem with `CLAUDE.md`. It captures surprising, non-obvious, or easy-to-miss facts that an AI agent (or a new contributor) should internalize quickly when starting work on this repo.

Facts recorded here are things that would take noticeable time to rediscover from the code or git history alone. Anything fully derivable from the code, the ADRs, or `docs/` does **not** belong here.

## Project facts

- **Brand name:** Sprig. The directory is `ezgitmacos/` for legacy reasons but all product-facing copy says "Sprig." Don't rename the directory.
- **License:** Apache-2.0. Contributions must be compatible. Dependencies with GPL/AGPL licenses are blocked by CI.
- **Minimum macOS:** 14 Sonoma. macOS 15 APIs wrapped in `#available` checks.
- **Git minimum:** 2.39 (Apple-bundled on macOS 14). Newer features (fsmonitor ≥ 2.37, reftable ≥ 2.45) feature-detected at runtime.
- **No menu-bar icon.** Sprig runs as a LaunchAgent + FinderSync extension + on-demand task windows. Global status is surfaced via Notification Center + an on-demand "Status" task window.
- **No libgit2.** We shell out. This is load-bearing for cross-platform, for LFS/filter compatibility, and for respecting user git config.
- **No App Store.** Direct distribution via signed/notarized DMG + Sparkle updates + Homebrew Cask.

## Cross-platform invariants

Sprig is macOS-only at 1.0 **but** the codebase is structured so future Windows/Linux ports are additive (see ADR 0048, ADR 0053, `docs/architecture/cross-platform.md`).

- `packages/` compiles on macOS, Linux, and Windows Swift 6.3 from day 1.
- `apps/{windows,linux}/` exist as placeholders; populating them is a port, not a restructure.
- Linux/Windows adapter impls live next to macOS impls under `packages/<Pkg>/Sources/{Linux,Windows}/` and may be `fatalError` stubs pre-1.0.

## Known quirks and gotchas

- **FinderSync extensions have a 15-overlay-slot limit on Windows** (future port concern) and idiosyncratic behavior on macOS (badges only appear for directories the user has explicitly added). See `docs/research/macos-finder-apis.md`.
- **fsmonitor requires directories owned by the current user.** Sprig never enables it on foreign-owned paths.
- **iCloud Drive + git is unreliable.** FSEvents on iCloud-synced volumes miss updates; we fall back to polling with a banner warning.
- **`safe.directory`** — never `*`. We prompt per-repo.
- **`core.precomposeunicode=true`** on macOS is essential for Linux-collaboration sanity. Easy to forget, so we default it on.
- **LFS filter hand-off requires system git's `git-lfs` on PATH.** Detect + prompt; never auto-install silently.

## Recent work (keeps going stale — not authoritative)

- 2026-04-23/24: Initial scaffolding landed on branch `chore/initial-scaffolding`. 53 ADRs seeded from the approved plan. Root docs + CI workflows in place. No features implemented yet.

## Glossary cheatsheet

- **Tier 1 / Tier 2 / Tier 3** — portable core / platform adapter / platform shell. See CLAUDE.md.
- **MVP-10** — the ten Finder right-click actions shipping at M2: clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log.
- **Task window** — a focused, standalone window launched on demand from a Finder right-click (CommitComposer, LogBrowser, DiffViewer, MergeConflictResolver, etc.). No persistent "app window with a file tree" exists.
- **Snapshot ref** — `refs/sprig/snapshots/<timestamp>/<op>` written before destructive ops. 30-day TTL, user-configurable.
- **Watch root** — a directory Sprig scans for repos on startup (user-chosen; default suggestions include `~/Developer`, `~/Projects`, `~/src`).
