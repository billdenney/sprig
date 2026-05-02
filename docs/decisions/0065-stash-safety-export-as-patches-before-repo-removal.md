---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0065. Stash safety — export `refs/stash` as patches before repo removal

## Context and problem statement

GitHub Desktop Issue #16078 is a canonical user-visible disaster: when a user removes a repository from the GitHub Desktop client, the client's "remove" action also calls `rm -rf` on the working tree, which destroys the repo's `.git/refs/stash` along with everything else. Users mentally model stashes as "drafts in my client" — equivalent to email drafts that should survive even if the source thread is deleted — and the silent loss of stashes is reported as the worst experience-shock of the client.

ADR 0033 covers "stash dropped during normal use" via the snapshot ref under `refs/sprig/snapshots/stash-<sha>`. It does *not* cover "the entire repo is being dereferenced from Sprig's repo list" — when the repo goes, the stashes go with it.

Sprig's repo-removal flow (right-click → Sprig ▶ → Remove from Sprig… or `sprigctl repo remove <path>`) needs an explicit safety net: stashes must survive repo removal even if the user has no idea they exist.

## Decision drivers

- The user's mental model — "stashes are like client-side drafts" — must not be silently violated.
- The recovery format must be portable: a user moving to another machine (or another git client) should be able to restore stashes without Sprig.
- Failure must be loud: if the export can't run (disk full, permissions), the user must see it before the repo is dereferenced.
- The export must be cheap enough that users don't avoid removing repos.

## Considered options

1. **Auto-export `refs/stash` as patch files before repo removal** (this ADR).
2. Warn + confirm only — show a confirmation listing the stashes that will be lost; require typing "DROP STASHES." User retains control; users who confirm-blindly still lose work. Reproduces the GitHub Desktop pattern with friction.
3. Export on first removal of a repo with stashes; remember the choice per-user.
4. Don't export; just warn. Match GitHub Desktop's current behavior plus a warning. Cheapest; reproduces a known disaster.

## Decision

**Option 1.** When a repo is removed from Sprig's repo list, the agent automatically exports every stash as a patch file *before* the repo is dereferenced. The user sees this in the removal confirmation, not as a separate dialog.

### Export mechanics

Per stash entry (`stash@{N}`):

1. Generate a patch via `git stash show --binary --include-untracked stash@{N}`.
2. Write it to:
   - macOS: `~/Library/Application Support/Sprig/Stashes/<repo-name>/<timestamp>-<index>-<short-sha>.patch`
   - Windows: `%APPDATA%\Sprig\Stashes\<repo-name>\<timestamp>-<index>-<short-sha>.patch`
   - Linux (post-1.0): `${XDG_DATA_HOME:-~/.local/share}/Sprig/Stashes/<repo-name>/<timestamp>-<index>-<short-sha>.patch`

Where `<repo-name>` is the worktree's directory basename (sanitized for filesystem safety; if name collisions occur across repos, the second instance is `<repo-name>-<short-of-repo-root-hash>`).

3. Write a sidecar `metadata.json` per export with: original repo path, original commit SHA the stash was based on, the stash message, the timestamp Sprig saw it, and the original `stash@{N}` index.
4. The patches use git's standard format-patch shape so `git apply` (or any client) can restore them. Binary parts are preserved.

### Removal-confirmation dialog

The removal task window (or the `sprigctl repo remove --confirm` flow) shows:

> **Remove `<repo-name>` from Sprig?**
>
> Sprig will keep watching this repo until you confirm.
>
> **3 stashes will be exported as patches** to:
> `~/Library/Application Support/Sprig/Stashes/<repo-name>/`
>
> The repo's working tree and `.git/` directory are NOT affected by removing from Sprig — only Sprig's tracking is.
>
> [ Cancel ] [ Remove ]

Critically, "Remove from Sprig" does **not** delete the repo's worktree or `.git/`. Sprig's repo list is just bookkeeping; the actual repo on disk is untouched. This is the second-order safety: even without the patch export, the user's stashes are still on disk in the original `.git/refs/stash`. The patch export is a **portable** copy for users who later wipe the repo manually and discover they wanted those stashes after all.

### Recovery

A new `sprigctl recover stashes` command:

```
sprigctl recover stashes --list
sprigctl recover stashes --apply <patch-file> [--repo <path>]
```

`--list` prints the export directory tree; `--apply` runs `git apply` against the named repo (default: current directory). Surfaced in the Recover task window (per ADR 0033 amendment) under a "Stashed patches from removed repos" section.

### Per-user retention

Patches in `~/Library/Application Support/Sprig/Stashes/` are not auto-pruned. They occupy minimal space (most stashes are <100KB), and the explicit user action of restoring or deleting them is a feature, not friction. The Recover task window has a "Delete patch" button per entry.

## Consequences

**Positive**
- Closes the GH Desktop #16078 disaster-class. Users cannot lose stashes by removing a repo from Sprig, period.
- Patches are portable: the user can apply them to another machine, another git client, or even a freshly-cloned copy of the same repo.
- Removal flow is *less* scary than competitors' (it's clearly bookkeeping-only, with the extra safety of an export).
- CI test gate (master plan §13.7): "stash 3 changes, remove repo, assert patches exist + valid `git apply` input."

**Negative / trade-offs**
- Disk usage in `Application Support` grows over time. Documented; user can prune via the Recover task window.
- Repo-name collisions across multiple repos with the same basename need disambiguation; the `-<short-hash>` suffix handles it but documentation must explain.
- The export is wall-clock cost on stash-heavy repos (>10 stashes) — typical: <1s; pathological: <30s. Surface progress in the removal dialog.
- Removing a repo from Sprig is now a confirmation dialog, not a one-click — adds a step. Acceptable trade-off given the safety win.

## Links

- Master plan §13.3-J.
- Related ADRs: 0033 (snapshot refs — same recovery surface), 0033 amendment (Recover task window), 0030 (Finder-first), 0034 (Status task window).
- GitHub Desktop Issue #16078: <https://github.com/desktop/desktop/issues/16078>
