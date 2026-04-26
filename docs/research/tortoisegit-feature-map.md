# TortoiseGit → Sprig feature mapping

For users coming from TortoiseGit on Windows, here's how the menu structure translates. Sprig is heavily inspired by TortoiseGit's "Explorer is the app" model (ADR 0030); most verbs have a direct equivalent. This file gets fully expanded pre-Windows-M2 when the Explorer extension lands; until then, this is the high-level mapping.

ADR cross-references: 0019 (badge set), 0020 (context-menu layout), 0030 (no main app window), 0054 (Windows GUI shell at 1.0).

Companion: [`../architecture/shell-integration.md`](../architecture/shell-integration.md), [`windows-shell-apis.md`](windows-shell-apis.md).

## Top-level verbs

| TortoiseGit | Sprig | Notes |
|---|---|---|
| Git Commit | Commit… | Same: opens a commit composer task window |
| Git Sync | Sync (Sprig ▶) | Combined fetch + pull/rebase + push, single button |
| Git Pull | Pull | Honors `pull.ff=only` (ADR 0049); merge/rebase choice surfaced explicitly |
| Git Push | Push | Auto-set-upstream on first push of a new branch (`push.autoSetupRemote=true`) |
| Git Fetch | Fetch | Always `--prune --tags` |
| Git Clone | Clone into here… | Right-click in non-repo dir |
| Git Create Branch | Create Branch… | |
| Git Switch/Checkout | Switch Branch… | Auto-stash dirty tree, restore after switch |
| Resolve | Resolve Conflicts… | Built-in 3-way merge UI (ADR 0027) |
| Diff | Diff… | Side-by-side or unified, syntax highlighted |
| Show Log | Show Log… | Graph + topo/date order |
| Repo-browser | (no equivalent) | Sprig uses Finder/Explorer for browsing — that's the whole architectural bet (ADR 0030) |

## `Sprig ▶` submenu (TortoiseGit's "TortoiseGit ▶")

| TortoiseGit | Sprig | Notes |
|---|---|---|
| Stash → Save / Pop / List | Stash → Stash Changes… / Pop / List | Same |
| Reset… | Reset → Reset Soft / Mixed / Hard… | Tiered safety per ADR 0033; `--hard` requires confirm + auto-snapshot |
| Branch → Delete | Delete Branch… | Force-delete-with-unpushed warning |
| Cherry Pick | Cherry-pick… | Multi-select supported; `-x` annotation default |
| Rebase | Rebase… → Rebase / Interactive Rebase… | Interactive opens RebaseInteractive task window (M5) |
| Bisect → Start / Good / Bad / Reset | Bisect → Start / Good / Bad / Reset | Guided modal |
| Show Reflog | Reflog… | "Activity Log" panel — HEAD + branch reflog |
| Submodule → Add / Update / Sync | Submodules → Add / Update / Sync / Manage… | Manage opens SubmoduleManager (M6) |
| LFS → Install / Track / Locks | LFS → Install / Track / Locks | Same; auto-detect on `.gitattributes` |
| Settings | Settings… | Preferences task window |
| TortoiseGit → About | (omitted) | About surfaces from Preferences in Sprig |

## TortoiseGit-style composite workflows (master plan §10)

| TortoiseGit | Sprig | Composition |
|---|---|---|
| Sync | Sync | `fetch` + (`rebase` or `merge`) + `push` |
| Commit & Push | Commit & Push | `commit` + `push`, checkbox in commit dialog |
| Pull & Rebase | Pull → Rebase | `fetch` + `rebase @{u}` |
| Update from Upstream | Update from Upstream | `fetch` + `rebase origin/<upstream>` |
| Publish Branch | Publish Branch | `push -u origin HEAD` + optional "Open PR" |
| Resolve Conflicts | Resolve Conflicts | Unified UI across `merge` / `rebase` / `cherry-pick` / `am` |
| Reword Last Commit | Reword Last Commit | `commit --amend` (+ `push --force-with-lease` if pushed) |
| Squash Commits | Squash Commits | `reset --soft` + `commit` (simple); `rebase -i --autosquash` (mid-history) |
| Clean | Clean Repo | `clean -fd` with dry-run preview + per-file toggles |
| Check for Modifications | Check for Modifications | combined `status` + `diff` window |
| Revert Changes | Revert Changes | context-dependent: `restore` / `restore --staged` / `revert <commit>` |

## What TortoiseGit has that Sprig deliberately does not

- **Repo Browser** — by design absent; Finder/Explorer is the file browser.
- **Daemon / svnserve-style features** — out of scope.
- **Email patches via SMTP** — `format-patch` + `send-email` are Tier 3 (post-1.0).
- **TortoiseUDiff / TortoiseIDiff** — Sprig uses its own DiffViewer; no separate per-file viewer launched standalone.

## What Sprig has that TortoiseGit does not

- **Stacked-PR workflow** as a first-class right-click flow (ADR 0051).
- **AI-assisted merge conflict resolution** (ADR 0035).
- **AI commit-message suggestions** (M7).
- **macOS-native Finder integration** — TortoiseGit is Windows-only; Sprig is the macOS analogue.
- **Snapshot refs as undo for destructive ops** (ADR 0033) — TortoiseGit relies on reflog + user diligence.
- **Multi-identity profiles** with `[includeIf]` auto-config (ADR 0041).

## When this file gets fully expanded

Pre-M2-Win (when the Windows Explorer extension is being built). Each TortoiseGit menu item gets an exact Sprig analogue documented with screenshots, plus a per-verb "what's different and why" callout. Useful for the marketing surface (TortoiseGit users are Sprig's natural Windows audience) and for the test matrix (porting a TortoiseGit user's muscle memory should mostly Just Work).
