# Glossary

## Sprig-specific terms

- **Tier 1 / 2 / 3** — portable core / platform adapter / platform shell. See `architecture/cross-platform.md`.
- **MVP-10** — the ten Finder right-click actions shipping at M2 (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log).
- **Task window** — a focused, standalone SwiftUI window launched from a Finder right-click.
- **Snapshot ref** — a ref under `refs/sprig/snapshots/<timestamp>/<op>` auto-created before destructive ops. 30-day TTL.
- **Watch root** — a directory Sprig scans for repos at startup.

## Git terms Sprig surfaces

- **fsmonitor** — a daemon that tells git which files have changed since the last query, making `git status` O(changes) instead of O(tree).
- **Scalar stack** — Microsoft's opinionated bundle of git config for large repos: fsmonitor, commit-graph, multi-pack-index, partial clone, sparse-checkout, maintenance.
- **Partial clone** — a clone that defers blob download; filter `--filter=blob:none`.
- **Sparse-checkout cone mode** — a worktree that materializes only specified directories.
- **LFS pointer** — the tiny text file that replaces a large binary under Git LFS.

## macOS terms

- **FinderSync** — Apple's extension point for Finder badges + context menus.
- **FSEvents** — macOS kernel API for filesystem change notifications.
- **XPC** — macOS inter-process RPC.
- **LaunchAgent** — per-user background service registered with launchd.
- **Notarization** — Apple's post-sign malware-scan step; required for direct distribution.
