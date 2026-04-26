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
