# Git feature inventory

Which `git` commands Sprig surfaces, in what tier, and where each lands in the milestone plan. **Authoritative source: [`master-plan.md`](../planning/master-plan.md) §10** plus the per-ADR engine-invocation sections below, which are the maintained record of every git command Sprig actually runs.

## Tiering at a glance

| Tier | Scope | Examples | Milestone |
|---|---|---|---|
| **1 — MVP** | Daily-driver commands every Sprig user hits in the first session | `clone`, `init`, `add`, `commit`, `push`, `pull`, `fetch`, `branch`, `switch`, `merge`, `stash`, `tag`, `reset`, `status`, `diff`, `log` | M2–M4 |
| **2 — 1.0 complete** | Power-user completeness; "I used to open Terminal for this" | `rebase -i`, `cherry-pick`, `bisect`, `reflog`, `worktree`, submodules, LFS, `subtree`, `blame`, `clean`, `gc`/`maintenance`, `sparse-checkout`, partial-clone | M5–M8 |
| **3 — post-1.0 advanced** | Specialized workflows | `filter-repo`, `format-patch` / `am`, `send-email`, hooks editor, `svn` / `p4` bridges, `git-annex`, `git-crypt`, `git-town`, `range-diff`, reftable | post-1.0 |
| **4 — out of scope** | Plumbing internals + replaced surfaces | `hash-object`, `cat-file` (used internally not as menu), `update-index`, `gitk`, `git gui`, `git instaweb` | never |

## Cross-cutting feature families

Each gets its own section in the master plan §10. Brief recap:

- **Security-related features** — GPG signing, SSH signing (default for new repos per ADR 0044), `safe.directory` trust, `transfer.fsckObjects`, hook-trust prompts, protocol allowlist, submodule-URL validation, SSH host-key dialog. See [`../architecture/security.md`](../architecture/security.md).
- **Performance-related features** — `core.fsmonitor`, `core.untrackedCache`, `feature.manyFiles`, commit-graph + changed-paths Bloom v2, multi-pack-index, sparse-index, partial clone, sparse-checkout cone, `git maintenance`, bundle URI, reftable (opt-in 2.45+). See [`../architecture/performance.md`](../architecture/performance.md).
- **Recovery-oriented features** — reflog, `fsck --lost-found`, `gc.reflogExpire` tuning, snapshot refs (`refs/sprig/snapshots/...` per ADR 0033), pseudo-refs panel. See `SafetyKit` package design.

## TortoiseGit-style composite workflows

The right-click menu surfaces these; each maps to a sequence of git primitives. Authoritative list in master plan §10. Highlights: **Sync** (fetch + rebase/merge + push), **Commit & Push**, **Pull & Rebase**, **Switch with dirty tree** (auto-stash), **Resolve Conflicts**, **Reword Last Commit**, **Squash Commits**, **Revert Changes**, **Recover Lost Work**, **Rebase Stack of Branches** (ADR 0051).

### "Set aside changes" switch (ADR 0069) — engine invocations

`GitCore.StashOps` + `BranchSwitcherViewModel.switchBranch(settingAsideChanges:)`:

- `git stash push --include-untracked -m <message>` — outcome detected via `refs/stash` movement (`git rev-parse --quiet --verify refs/stash` before/after), not message text.
- `git switch <branch>` — on failure after a stash was created, the stash is popped back (fail-closed restore).
- `git stash pop` — conflicted pops are detected by non-zero exit **plus** `refs/stash` still resolving (git keeps the entry), surfaced as "kept in stash".

### Stash browser (ADR 0079) — engine invocations

`GitCore.StashOps` by-ref verbs + `TaskWindowKit.StashViewModel`:

- `git stash list --format=%gd%x00%H%x00%cI%x00%s` — NUL-delimited fields (selector, commit SHA, ISO-8601 date, subject) so subjects can't break the parse; SHA is the stable entry identity (selectors reindex on every pop/drop).
- `git stash apply <ref>` / `git stash pop <ref>` — by-ref variants; kept-on-conflict verified by the entry's SHA still appearing in `git stash list --format=%H`, not by selector.
- `git stash drop <ref>` — only reachable via `dropKeepingSafetyCopy`, which first writes `refs/sprig/snapshots/<ts>/stash-drop` at the stash commit (ADR 0033 medium tier).
- `git stash store -m <original subject> <sha>` — Recover's restore path for stash-drop safety copies (additive; never `reset --hard`, which would move the branch onto the stash commit).

### Clone (ADR 0030 / 0078) — engine invocations

`TaskWindowKit.CloneDialogViewModel` + `sprigctl clone`:

- `git clone [--recurse-submodules] [--depth N] <source> <target>` — argv built by `CloneRequest.gitArguments()` (unit-pinned); submodule recursion defaults on per master plan §10. Note: local-path clones ignore `--depth`; the `file://` transport honors it (test-pinned).

### Stacked-branch restack (ADR 0085) — engine invocations

`GitCore.StackOps` + `TaskWindowKit.StackRestackViewModel`:

- `git config branch.<child>.sprigParent <parent>` / `branch.<child>.sprigBase <fork-sha>` — the recorded stack link (local scope; sprigBase frozen at `git merge-base <parent> <child>`, re-frozen to the parent tip after each restack). Read via `config --get`; the parent-graph inversion uses `config --get-regexp ^branch\..*\.sprigparent$` (git lowercases the variable name in output).
- `git merge-base --is-ancestor <recordedSprigBase> <child>` — the fork-point staleness guard; non-ancestor → `.refusedForkPointDiverged`.
- `git rebase --onto <parentCurrentTip> <recordedSprigBase> <child>` — the replay; the frozen fork survives parent rewrites where a live merge-base would replay orphaned parent commits (ADR 0085 rejected options, spike-pinned). Conflict discrimination reuses the rebase-marker + `ls-files -u -z` pattern; `git rebase --abort` is the parked-state undo.

### Rebase plan (ADR 0083) — engine invocations

`GitCore.RebasePlanOps` + `TaskWindowKit.RebasePlanViewModel`:

- `git -c sequence.editor="printf '<todo>' >\"$1\"" rebase -i <HEAD~count | --root>` — the todo (lines of `pick|fixup|drop <40-hex-sha>`) rides the one-shot config value; SHAs are charset-validated before interpolation so the editor command can't be injected. Git's own sequencer owns conflict parking and `--continue`/`--abort`.
- `git log --reverse --format=%H%x00%s HEAD --not --remotes` — the rewritable range in todo order (oldest first).
- Conflict discrimination reuses the Sync rebase leg's pattern: rebase markers (`rebase-merge`/`rebase-apply`) + `git ls-files -u -z` for the conflicted path count.

### Revert (ADR 0084) — engine invocations

`GitCore.HistoryOps.revert` + `TaskWindowKit.HistoryEditViewModel.revert(sha:)`:

- `git revert --no-edit <sha>` — forward-fix; clean-tree required (shared `HistoryRewriteGuards`). Conflicts park `REVERT_HEAD` (`MidstreamOperation` classifies it; `ls-files -u -z` counts paths); `git revert --abort` is the one-tap undo of the parked state.
- `git rev-parse --quiet --verify <sha>^2` — merge-commit detection: a second parent refuses (`-m` mainline choice deferred to a picker UI).

### History editing (ADR 0082) — engine invocations

`GitCore.HistoryOps` + `TaskWindowKit.HistoryEditViewModel`:

- `git branch -r --contains <rev>` — the shared-history oracle: any output means the commit is on a remote and the rewrite refuses. For squash the check runs on the oldest affected commit (`HEAD~(N-1)`); a remote containing a child contains its ancestors.
- `git diff --cached --quiet` — exit 1 means the index differs from HEAD; both verbs refuse rather than fold staged changes into the rewrite.
- `git commit --amend -m <message>` — reword (message-only after the staged guard; hooks run per defer-to-git).
- `git reset --soft HEAD~N` + `git commit -m <message>` — squash; the new commit's tree is byte-identical to the old tip's.
- `git rev-list --count HEAD --not --remotes` — the rewritable depth the VM exposes as `unpushedCount` (squash bound; zero means everything is shared).

### Region staging (ADR 0061) — engine invocations

`GitCore.DiffPatchSlicer` (pure) + `TaskWindowKit.CommitComposerViewModel.stageSelection`:

- `git diff` — the unstaged worktree-vs-index diff the UI renders and the user drag-selects in. `DiffPatchSlicer.slice(diff:selection:)` then rewrites that diff into a patch staging exactly the selected +/- lines (unselected `+` dropped, unselected `-` demoted to context, `@@` counts re-derived, per-file headers carried verbatim).
- `git apply --cached --recount -` (patch on stdin) — applies the sliced patch to the index only. `--recount` lets git re-derive the hunk line counts, so a sub-hunk slice never needs byte-perfect `@@` headers. Index-only and reversible (`git restore --staged`), so no snapshot is minted — staging isn't a destructive op.

### Sync verb (ADR 0071) — engine invocations

`SyncOps.pushCurrentBranch` + `TaskWindowKit.SyncViewModel` (fetch and fast-forward legs reuse ADR 0068's invocations below):

- `git push --quiet` — plain push of the current branch; **force is never emitted from this surface** (ADR 0052's force verb is separate). Rejections classify by git's stable stderr markers (`non-fast-forward`, `[rejected]`, `fetch first`).
- `git push --quiet -u <remote> <branch>` — publish-and-track when no upstream exists.
- `git remote` — remote enumeration for the publish path.
- `git rebase <upstream>` — the ADR 0071-amendment follow-up (`SyncOps.rebaseOntoUpstream`, `sprigctl sync --push --rebase-diverged`): user-initiated replay of a diverged branch, medium-tier snapshot first (ADR 0033), plain push after. A conflicted rebase is left in place — `git ls-files -u -z` counts the paths for the report; continuation belongs to the resolver, `git rebase --abort` is the one-tap undo.

### Auto-backup (ADR 0075) — engine invocations

`SafetyKit.WorktreeBackup` (+ agent tick via `AutoBackupStartup`; CLI `sprigctl backup`):

- `git status --porcelain -z` — dirty gate (untracked counts).
- Throwaway index (`GIT_INDEX_FILE` env): `git read-tree HEAD|--empty` → `git add -A -- . :(exclude,glob)**/<junk>` → `git write-tree` — the real index never changes; the exclude pathspecs are the ADR 0075-amendment deny-list (`GitCore.JunkFilePatterns`: likely secrets + tool temporaries). A staged tree equal to HEAD's tree (junk-only dirt) skips the backup.
- `git commit-tree <tree> [-p HEAD] -m …` — no hooks run.
- `git update-ref refs/sprig/backup/<ts>/<branch> <sha>` (collision-avoiding mint) / `update-ref -d` for TTL prune; `for-each-ref` to list.
- `git restore --source=<sha> --worktree -- :/` — additive fail-closed restore (pre-restore state backed up first).

### Branch hygiene (ADR 0073) — engine invocations

`GitCore.BranchHygiene` + `BranchHygieneViewModel` (detection rides ADR 0068's `branchSyncStates`):

- `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` — remote default branch (fallback probes `origin/main`, `origin/master`).
- `git merge-base --is-ancestor <branch> <remote-default>` — the lossless-delete proof.
- `git rev-list --count <branch> ^<remote-default>` — unpushed-commit count for the confirmation.
- `git branch -d <name>` / `git branch -D <name>` — typed refusal outcomes; the medium-tier path snapshots the tip via SafetyKit (`refs/sprig/snapshots/…/branch-delete`) before `-D`.

### Background auto-sync (ADR 0068) — engine invocations

`GitCore.SyncOps` drives these; `AgentKit.AutoSyncScheduler` sequences them hourly (default); `sprigctl sync` is the one-shot CLI face. Host wiring (ADR 0068 amendment): `sprigctl agent --preferences PATH` maps the user's `AppPreferences` to the auto-fetch and auto-backup schedulers via `AgentKit.AgentPreferencesWiring` — the same mapping the platform hosts will use.

- `git fetch --all --prune --no-write-fetch-head --quiet` — the hourly auto-fetch.
- `git for-each-ref --format='%(refname:short)…%(upstream)…%(upstream:track)…%(HEAD)' refs/heads/` — one-pass upstream relationship snapshot (`SyncOps.branchSyncStates`).
- `git merge --ff-only [--autostash] <upstream>` — fast-forward of the checked-out branch (opt-in auto-pull; autostash is a further opt-in).
- `git fetch . <upstream-ref>:refs/heads/<branch> --quiet` — ref-only fast-forward of non-checked-out branches; git itself refuses non-FF updates and worktree-checked-out branches.
- `git status --porcelain -z` — tracked-modification (dirty) gate before touching the checked-out branch.

### Global excludes provisioning (ADR 0049 amendment) — engine invocations

`GitCore.GlobalExcludes` (CLI face `sprigctl setup --global-ignore`):

- `git config --get core.excludesFile` — resolution across all scopes, exactly like git's own excludes lookup; unset falls back to the documented `$XDG_CONFIG_HOME/git/ignore` default, so provisioning never writes config.

### Secret-scan rail (ADR 0092) — engine invocations

`GitCore.SecretScan` (a default-on `stagedSecretDetected` pre-flight rail in the ADR 0070 family; feeds the ADR 0093 push-time secret rail):

- `git diff --cached --unified=0 --no-color` — added staged lines scanned against a vendored regex + entropy ruleset (no bundled binary). Only the `+` side is scanned; removed lines are never flagged. Gated on there being staged paths, so it adds no spawn when nothing is staged.
- `git diff --unified=0 --no-color <range>` — the ADR 0093 push-time variant scans the outgoing commit range (`@{u}..HEAD`), catching a secret committed in an earlier commit, not just the staged tree.
- `.sprig/secret-allow` (read, not a git invocation) — per-finding allowlist (`<matched-value>` or `<path>:<ruleID>`) suppresses known-safe matches without disabling the rail.

### Push-time rails (ADR 0093) — engine invocations

Three warn-and-proceed rails evaluated in `SyncViewModel`'s push leg from the post-fetch state:

- `pushingToProtectedBranch` / `forcePushConsequence` — **no new spawn**: pure reads of `SyncOps.branchSyncStates()` (the `for-each-ref` upstream/track parse the Sync verb already runs), keyed on the current branch name being a default branch and on `ahead>0 && behind>0` respectively.
- `secretInOutgoingCommits` — reuses the `GitCore.SecretScan` outgoing-range scan above (`git diff --unified=0 --no-color @{u}..HEAD`), run only when there's an upstream and outgoing commits.

### Type-aware LFS rail + Track-with-LFS (ADR 0091) — engine invocations

- `binaryTypeWithoutLFS` rail (`LFSKit.LFSBinaryTypes`): for staged files whose extension is in the curated binary set and that are under the size threshold, `git check-attr -z --stdin filter` (via `LFSKit.LFSAttributeChecker`, same call the size rail uses) decides which aren't LFS-tracked. The extension match itself is a pure read of the porcelain paths — no spawn.
- `LFSKit.LFSTrack.track(pattern:)` (the "Track with LFS" remedy): `git lfs version` (via `LFSInstall.probe`) to detect git-lfs — a typed `gitLFSNotAvailable` refusal if absent (never a silent install) — then `git lfs track <pattern>`, which edits `.gitattributes` (and does **not** run `git lfs install`).

### Selective sync — sparse-checkout folder picker (ADR 0089) — engine invocations

`GitCore.SparseCheckout` (cone-mode only; the beginner "Choose folders to keep on this Mac…" surface + `sprigctl sparse`):

- `git ls-tree -z HEAD` — top-level folder candidates; the parser keeps only `tree` entries, so repo-root files (blobs) and submodule gitlinks (type `commit`) are excluded from the picker.
- `git config --get core.sparseCheckout` + `git sparse-checkout list` — read the current selection (`.full` vs `.cone(dirs)`).
- `git sparse-checkout init --cone` / `set <dirs>` / `add <dirs>` / `disable` — the write verbs; `set` materializes exactly the kept folders, `disable` restores the full worktree.
- `git status --porcelain=v2 -z --untracked-files=all` — `planChange(to:)`'s dirty-folder guard: dropped folders holding uncommitted/untracked/staged work are reported as `blockedDrops` (sparse-checkout's "lossless" claim holds only for clean folders), so the surfaces fail closed.
- Force path (after a fail-closed report, only with explicit confirmation): `SafetyKit.WorktreeBackup.createBackupIfDirty()` (captures tracked + untracked work) **first**, then per blocked folder `git restore --worktree --staged -- <dir>` + `git clean -fd -- <dir>` (no `-x`, so ignored files survive; no `-ff`, so nested repos survive), then `sparse-checkout set`. Recoverable via the Recover surface — never moves HEAD.

### File version history + restore (ADR 0090) — engine invocations

`GitCore.FileHistory` + `SafetyKit.FileBackup` (the per-file "Show History… / Restore Previous Version…" surface + `sprigctl file-history`):

- `git log --follow --name-status --format=<RS>%H<US>%aN<US>%aI<US>%s -- <path>` — the revision list following renames; the `--name-status` block yields the file's path AT EACH commit (the new-name field of a rename), needed because `<old-sha>:<current-path>` fails after a rename.
- `<sha>:<pathAtRevision>` read via `CatFileBatch` — the per-revision blob bytes (the documented history/blame foundation).
- `git hash-object -w -- <path>` + `git update-ref --stdin create refs/sprig/filebackup/<ts>/<label> <blob>` — the single-file safety backup: the file's current bytes as a blob, with a ref kept reachable by `git gc`. Same atomic-create + timestamp-bump collision handling as ADR 0075's `WorktreeBackup`.
- `git cat-file blob <filebackup-ref>` → write — restore (and the fail-closed pre-restore backup of current bytes). Restore writes to the worktree; it is additive and never rewrites history.

## Newer-git features Sprig explicitly takes advantage of

Master plan §10 has a per-version (2.40 → 2.46) breakdown. Highlights:

- **2.34** — SSH signing
- **2.36** — `diff --remerge-diff` (review conflict resolution)
- **2.37** — native macOS fsmonitor, `push.autoSetupRemote`, sparse-index
- **2.38** — `rebase --update-refs` (load-bearing for stacked PRs per ADR 0051)
- **2.39** — minimum supported version (Apple-bundled on macOS 14)
- **2.45** — reftable, `index.skipHash`, `clone --revision`
- **2.46** — multi-bundle URI, `pack.writeBitmapLookupTable`

## Where the inventory is canonical

- **For surface scope** (what's a menu item) — master plan §10 + ADRs 0019/0020/0030/0031/0032.
- **For default config values** (what's `git config <key> <value>` on a fresh repo) — master plan §11.1 + ADR 0049.
- **For the recovery-affordance list** — master plan §11.7 + `SafetyKit` design.

This file gets per-feature checklist treatment as features actually ship; until then the master plan is canonical.
