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

### 1.3 Auto-stash around pull/switch — `proposed`, effort S
The #1 beginner wall: "cannot pull/switch: you have uncommitted changes." Git already has
the mechanism (`--autostash`, `git stash push` + pop); Sprig's pull/switch verbs should
offer "Set aside changes and continue?" with the stash auto-reapplied after. Failure to
reapply cleanly surfaces as a conflict in the same resolver UI as merges (M4). Pairs with
ADR 0065 (stash safety: export before destructive ops).

### 1.4 One "Sync" verb — `proposed`, effort M
TortoiseGit's most-loved button. One Finder context-menu verb that does: fetch → FF-pull
(per 1.2 rules) → push your unpushed commits (with `--force-with-lease` never implied —
plain push only). The beginner mental model becomes "Sync = make my copy and the server
match." Needs ADR for the push half (when to refuse: diverged → open the resolver instead).

### 1.5 "Put back" / undo surface on every destructive verb — partially `shipped`, effort M
SafetyKit already snapshots before destructive ops (ADR 0033, `refs/sprig/snapshots/*`,
`sprigctl recover`). The beginner-facing half is naming: surface it as **"Undo last
operation"** and **"Sprig keeps a safety copy — restore it"** in the same menu as the verb
that caused it, not as a separate "Recover" power-tool. The Recover task window (ADR 0033
amendment) should lead with plain language ("Before your reset 10 minutes ago").

## Tier 2 — high value, more design care needed

### 2.1 Plain-language status vocabulary with progressive disclosure — `proposed`, effort M
Badge tooltips and task-window strings in two registers, toggled by the ADR 0019 reveal
level: beginner register ("3 files changed since your last save point", "your copy is 2
updates behind the server") with the git term in parentheses the first few times
("…behind (git: `behind origin/main`)"). Teaches vocabulary instead of hiding it — the
beginner eventually *graduates*. No AI required: it's string tables keyed off porcelain
fields we already parse.

### 2.2 Auto-backup snapshots of uncommitted work — `proposed`, effort M
Time-Machine-style: every N minutes (default 30?) with a dirty worktree, write a snapshot
commit of the working tree to `refs/sprig/backup/<branch>` (never on the branch itself; ref
TTL-pruned like ADR 0033 snapshots). The beginner who has never committed still has crash/
oops insurance, restorable from the Recover window. Cheap with `git stash create`-style
plumbing (`git commit-tree` of a temp index — no working-tree side effects, no hooks).
Needs an ADR: interval, TTL, size guards, LFS interaction.

### 2.3 Pre-flight warnings ("you're about to step on a rake") — `proposed`, effort S each
Cheap porcelain-driven nudges at verb time, not background nags:
- Committing to a branch named `main`/`master` that tracks a protected remote → "Most
  teams use a branch — create one now?" (one-click branch + carry changes along).
- Detached HEAD → banner in every task window: "You're not on a branch — work here can be
  lost. Create a branch to keep it." (one-click fix).
- About to push a file >50 MB without LFS → offer ADR 0029's LFS flow.
- `git switch` away from a branch with unpushed commits → informational, not blocking.

### 2.4 Branch-hygiene automation — `proposed`, effort S
After fetch notices an upstream branch was deleted (typical post-merge), offer "This
branch was merged on the server — clean it up?" (delete local, with the unpushed-commits
guard from `DestructiveOpTier`). Keeps the beginner's branch list from becoming a junk
drawer — a real comprehension cost, not just aesthetics.

### 2.5 Template-based commit messages (no AI) — `proposed`, effort S
A non-AI default for the "what do I write here" freeze: pre-fill from a deterministic
template — `Update <area>: <file list summary>` derived from staged paths, plus the
repo's `commit.template` if set. The AI drafting path (ADR 0035) remains the opt-in
upgrade; the template gives the never-enable-AI user a working default.

## Tier 3 — worth keeping on the radar

- **3.1 Stale-work nudges** (`proposed`, S) — Status window section: "branch X: 4 changed
  files, no commit in 9 days." Surfaced only when the Status window is opened (no
  notifications spam, per ADR 0014's restraint).
- **3.2 Clone wizard with provider browse** (`proposed`, M) — pick-from-list of your
  GitHub/GitLab repos via the ADR 0063 forge tokens instead of pasting clone URLs.
- **3.3 "What changed?" digest after fetch** (`proposed`, S) — when auto-fetch moves a
  remote-tracking ref, the Status window shows "12 new commits from 3 people on main"
  (pure `git log --oneline old..new` counting; no AI).
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
