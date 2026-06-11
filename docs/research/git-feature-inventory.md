# Git feature inventory

Which `git` commands Sprig surfaces, in what tier, and where each lands in the milestone plan. **Authoritative source: §10 of the master plan** at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`. This file is a brief navigation index against that.

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

### Rebase plan (ADR 0083) — engine invocations

`GitCore.RebasePlanOps` + `TaskWindowKit.RebasePlanViewModel`:

- `git -c sequence.editor="printf '<todo>' >\"$1\"" rebase -i <HEAD~count | --root>` — the todo (lines of `pick|fixup|drop <40-hex-sha>`) rides the one-shot config value; SHAs are charset-validated before interpolation so the editor command can't be injected. Git's own sequencer owns conflict parking and `--continue`/`--abort`.
- `git log --reverse --format=%H%x00%s HEAD --not --remotes` — the rewritable range in todo order (oldest first).
- Conflict discrimination reuses the Sync rebase leg's pattern: rebase markers (`rebase-merge`/`rebase-apply`) + `git ls-files -u -z` for the conflicted path count.

### History editing (ADR 0082) — engine invocations

`GitCore.HistoryOps` + `TaskWindowKit.HistoryEditViewModel`:

- `git branch -r --contains <rev>` — the shared-history oracle: any output means the commit is on a remote and the rewrite refuses. For squash the check runs on the oldest affected commit (`HEAD~(N-1)`); a remote containing a child contains its ancestors.
- `git diff --cached --quiet` — exit 1 means the index differs from HEAD; both verbs refuse rather than fold staged changes into the rewrite.
- `git commit --amend -m <message>` — reword (message-only after the staged guard; hooks run per defer-to-git).
- `git reset --soft HEAD~N` + `git commit -m <message>` — squash; the new commit's tree is byte-identical to the old tip's.
- `git rev-list --count HEAD --not --remotes` — the rewritable depth the VM exposes as `unpushedCount` (squash bound; zero means everything is shared).

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
