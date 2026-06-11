# Git-beginner affordances — idea backlog

Companion to ADR 0068 (auto-sync). Maintainer direction (2026-06-09): make Sprig easier for
people less familiar with git, preferring mechanisms that don't depend on AI. This document
is the working backlog of candidate affordances: what each one is, why it helps a beginner,
what it costs, and its current status. Items graduate to ADRs when ratified; nothing here is
a commitment.

Legend — **Status**: `shipped` (exists today), `ratified` (ADR exists, build pending),
`proposed` (this doc is its only home). **Effort**: S (<1 week), M (1–3 weeks), L (M2+-sized).

## Tier 1 — highest leverage per unit of surprise

These remove the most common beginner failure modes without changing what git *means*.

### 1.1 Hourly auto-fetch (default-on) — `ratified` (ADR 0068), effort S
Behind/ahead badges that are roughly current, with zero user action. The beginner never has
to learn "fetch" as a verb to benefit from it. Engine slice shipping now.

### 1.2 Opt-in auto-pull, fast-forward only — `ratified` (ADR 0068), effort S–M
Keeps local branches and the working directory current when it is *provably lossless* (FF
only, clean tree, not mid-operation). Every skip is reported, not swallowed — "main needs
your attention (diverged)" is itself a teaching surface. Default off; onboarding (ADR 0039)
can offer it to beginner-profile users.

### 1.3 Auto-stash around pull/switch — switch half `ratified + shipped` (ADR 0069), pull half partially native
The #1 beginner wall: "cannot pull/switch: you have uncommitted changes." **Switch:** shipped —
`BranchSwitcherViewModel.switchBranch(settingAsideChanges:)` + `GitCore.StashOps`, offered via
`canOfferSetAside` exactly when git refuses; fail-closed table in ADR 0069. **Pull:** the
checked-out-branch fast-forward already supports git-native `--autostash`
(`FastForwardOptions.autostash`, ADR 0068); a beginner-facing "set aside and pull" offer in the
pull verb reuses `StashOps` when that verb's task window lands. Pairs with ADR 0065 (stash
safety: export before destructive ops).

### 1.4 One "Sync" verb — `ratified + shipped` (ADR 0071)
TortoiseGit's most-loved button: fetch → FF-pull (per 1.2 rules) → **plain** push of the
current branch (publishing with `-u` when no upstream; force never implied — a rejected push
is a typed "needs your attention: diverged" report routing to the resolver).
`TaskWindowKit.SyncViewModel` (staged progress + per-leg `SyncReport`),
`SyncOps.pushCurrentBranch`, `sprigctl sync --push`. The beginner mental model: "Sync = make
my copy and the server match." **Ratified follow-up (ADR 0071 amendment, shipped):** the
diverged report offers an explicit "replay my commits on top of the server's, then push"
action — user-initiated rebase → plain push, never a force, medium-tier snapshot first
(`SyncViewModel.rebaseDivergedThenPush()`, `sprigctl sync --push --rebase-diverged`); a
conflicted rebase is left in place for the resolver or one-tap abort.

### 1.5 "Put back" / undo surface on every destructive verb — engine `shipped` (ADR 0033 amendments)
SafetyKit snapshots before destructive ops (`refs/sprig/snapshots/*`, `sprigctl recover`).
**Shipped (2026-06-11):** `TaskWindowKit.RecoverViewModel` — one newest-first list merging
snapshots AND ADR 0075 backups ("Sprig's safety copies" is one concept for the user), with
fail-closed restores: a backup restore is additive; a snapshot restore backs up uncommitted
work first (it would otherwise be eaten — the CLI gained the same insurance) and snapshots
pre-restore HEAD so it's self-reversible (restore targets SHA-pinned against same-second
ref reuse). **Remaining (M3 shells):** the window itself plus the beginner naming — "Undo
last operation" / "Sprig keeps a safety copy — restore it" in the same menu as the verb
that caused it, leading with plain language ("Before your reset 10 minutes ago").

## Tier 2 — high value, more design care needed

### 2.1 Plain-language status vocabulary with progressive disclosure — infrastructure `ratified + shipped` (ADR 0072)
**Shipped:** `UIKitShared.StatusVocabulary` — one formatter, two registers (`.plain` for
beginners; `.git` is the terse power-user/CLI register, byte-identical to sprigctl's pinned
output — `sprigctl sync` now consumes it). Covers every typed outcome so far: branch
relationships, fast-forward, push, pre-flight warnings, set-aside. VMs never format;
ADR 0019's reveal level picks the register in the shells. **Amendment (shipped, ratified
2026-06-11):** all `.plain` strings tightened; `(git: …)` teaching parentheticals reduced
to the three decision points (diverged, detached HEAD, never-forces) with a census test
pinning the count; the VMs' inline failure/validation strings moved into
`TaskWindowKit.TaskWindowVocabulary` (one reviewed table, register-neutral imperatives).
**Remaining:** applying the plain register across badge tooltips + the other task windows
as each shell surface lands (M2/M3). No AI required: string tables keyed off porcelain
fields we already parse.

### 2.2 Auto-backup snapshots of uncommitted work — `ratified + shipped` (ADR 0075)
Time-Machine-style. **Shipped:** `SafetyKit.WorktreeBackup` — throwaway-index
(`GIT_INDEX_FILE`) backup commits under `refs/sprig/backup/<ts>/<branch>` capturing tracked +
untracked work with zero HEAD/index/worktree/hook side effects; identical-tree dedup;
collision-avoiding ref minting; fail-closed additive restore (pre-restore state backed up
first, source pinned by SHA). Agent tick (default 30 min, `AutoBackupStartup` reusing the
generic scheduler) + 7-day TTL prune; `sprigctl backup --list/--now/--restore`; Preferences
toggles (default on). Size guard noted in the ADR as a future refinement. **Amendment
(shipped):** backups exclude likely secrets + tool temporaries (`GitCore.JunkFilePatterns`
deny-list via exclude pathspecs); a junk-only-dirty tree backs up nothing; the skip is
surfaced to the user by 2.3's `.gitignore` suggestion.

### 2.3 Pre-flight warnings ("you're about to step on a rake") — commit-time set `ratified + shipped` (ADR 0070)
Cheap porcelain-driven nudges at verb time, not background nags. **Shipped:**
`TaskWindowKit.PreflightChecks` + `CommitComposerViewModel.preflightWarnings` — committing to
`main`/`master` with an upstream ("most teams use a branch"), detached HEAD ("work here can be
lost"), staged file >50 MiB without LFS (offers ADR 0029's flow). Warnings never block;
banners carry one-click remedies. **Amendment (shipped):** every rail carries a stable
`railID` and the banner offers "never show this again" →
`AppPreferences.suppressedGuardRails` → `PreflightChecks(suppressedRails:)`; plus the
suggest-only `.gitignore` affordance (`GitignoreSuggestion` detect/append — consent-gated,
header-once, dedup, never rewrites) for untracked files matching the junk rules. **Still
proposed:** `git switch` away from a branch with unpushed commits (informational;
BranchSwitcher has the ahead/behind data via `SyncOps` when its UI wants it) and push-time
rails.

### 2.4 Branch-hygiene automation — `ratified + shipped` (ADR 0073)
After fetch prunes a deleted upstream, offer "This branch was merged on the server — clean
it up?". **Shipped:** `GitCore.BranchHygiene` (stale detection classified against the remote
default branch; typed delete outcomes) + `BranchHygieneViewModel` — safe cleanup on the
ancestor proof, and a medium-tier `cleanUpKeepingSafetyCopy` that snapshots the tip under
`refs/sprig/snapshots/…/branch-delete` before `-D` (ADR 0033 pairing via `DestructiveOpTier`),
surfacing the ref for the undo banner. Banner copy in `StatusVocabulary` (both registers).

### 2.5 Template-based commit messages (no AI) — `ratified + shipped` (ADR 0074)
A non-AI default for the "what do I write here" freeze. **Shipped:**
`CommitMessageSuggestion` — the repo's `commit.template` wins (loaded + comment-stripped the
way `git commit` does); otherwise a humble synthesized subject from the staged paths
("Add notes.md", "Update src/app (3 files)"), Add-vs-Update from the porcelain index codes.
`CommitComposerViewModel.suggestMessage()` fills only an empty draft — never clobbers user
input. The AI drafting path (ADR 0035) remains the opt-in upgrade.

## The organizing principle: ask less

Every affordance above is an instance of one rule — **convert questions into defaults,
suggestions, or undo**. The master plan's §11 intervention levels are the taxonomy: prefer
**(a) silent defaults** (set once with onboarding consent, visible in Settings, never asked
again — the ADR 0049 config bundle, hourly fetch ON, backup ON, and now the global
OS-noise excludes) over **(b) ask-on-first-encounter** (cache the answer: hook trust,
LFS-track-this?) over recurring prompts (never). Where a question can't be removed it
becomes a **non-blocking nudge with the remedy attached** (ADR 0070 rails, each with its
own "never show again"), a **suggestion that acts only on click** (the `.gitignore` banner),
or an **undo instead of a confirm** (ADR 0033/0075: snapshots + backups make acting first
safe). The trust spine stays: destructive-op confirms (§11.6) are not negotiable away.

## Tier 3 — worth keeping on the radar

- **3.1 Stale-work nudges** (`ratified + shipped`, ADR 0077) — Status window section:
  "branch X: 4 changed files, no commit in 9 days." `RepoStatusSummary.lastCommitDate` +
  `StatusVocabulary.staleWorkNudge`; surfaced only inside the Status window (no
  notification spam, per ADR 0014's restraint).
- **3.2 Clone wizard with provider browse** (`proposed`, M) — pick-from-list of your
  GitHub/GitLab repos via the ADR 0063 forge tokens instead of pasting clone URLs.
- **3.3 "What changed?" digest after fetch** (`ratified + shipped`, ADR 0077) — when a
  fetch moves a remote-tracking ref, "12 new commits from 3 people on origin/main"
  (`SyncOps.fetchAllDigesting`, pure `git log` counting, no AI); in
  `RepoStatusSummary.fetchDigests` for the Status window and printed by `sprigctl sync`
  today.
- **3.4 Conflict-resolution wording** (`ratified` direction, ADR 0027/0028) — the M4
  resolver already plans "keep mine / keep theirs / keep both" labels; double down for
  the beginner register (2.1) with file-level "accept all mine/theirs" affordances.
- **3.5 Guard-railed config defaults** (`shipped`, ADR 0026/0049) — `pull.ff=only`,
  `push.autoSetupRemote`, `fetch.prune`, `rerere` — many beginner footguns are already
  removed by the defaults bundle; keep auditing new git releases for additions.

## Non-goals (explicitly considered and rejected)

- **Hiding git vocabulary entirely** (a "sync only" UI à la Dropbox): produces users who
  can never collaborate outside Sprig; 2.1's progressive disclosure is the chosen path.
- **Auto-commit** (committing on a timer without user intent): destroys the meaning of
  history for collaborators; 2.2's off-branch backup refs deliver the safety without the
  pollution.
- **Auto-push**: publishing is consent; never automatic. (The "Sync" verb pushes only as
  an explicit user action.)
- **AI-dependent affordances as defaults**: per maintainer direction and ADR 0036, AI
  stays opt-in; everything in Tiers 1–2 is deterministic.

## Suggested sequencing

1.1/1.2 are in flight (ADR 0068). Next-cheapest high-leverage: **1.3 auto-stash** and
**2.3 pre-flight warnings** (both S, both engine + small VM work, no new subsystem). Then
**1.4 Sync verb** (needs its push-half ADR) and **2.1 vocabulary** (string-table
infrastructure that 2.3/3.4 also want). **2.2 auto-backup** rides once snapshot TTL/size
policy questions get an ADR.
