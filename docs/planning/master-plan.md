# Sprig master plan

> **Provenance.** The original master plan lived at a machine-local path outside the
> repository (`~/.claude/plans/…glittery-corbato.md`) and was lost — the single-point-of-
> failure the bus-factor risk (R7) warned about, realized in documentation form. This file
> is the **reconstruction, vendored into the repo** (2026-06-11), assembled from the 80+
> ratified ADRs, the planning docs, and the §-quotations that survive throughout the tree.
> Section numbers are preserved so existing citations ("master plan §10", "§11.6", "§13")
> resolve against this document. Where the original prose could not be recovered, the
> section says so and points at the surviving source of truth. Maintainer-ratified as part
> of the 2026-06-11 plan review.

This document is the union of all ratified ADRs and the roadmap. When in doubt, consult
it; when it conflicts with an ADR, the newer ratification wins and this file gets fixed.

## §1 — Product thesis

Sprig is a **macOS-native, Finder-first Git GUI** modeled on TortoiseGit: the file manager
is the interface. Overlay badges show repo state where users already look; right-click
verbs do the work; task windows open only when a verb needs one. There is no main window
and no menu-bar app (ADR 0030). The macOS app is the 1.0 product; **the engine and
`sprigctl` are first-class on macOS, Linux, and Windows from day 1** (ADR 0054), with a
Windows GUI shell shipping at 1.0 in parallel and a Linux shell post-1.0.

The target user includes the **git beginner**: someone for whom git's own vocabulary and
failure modes are the product's main obstacle. The beginner-affordances program
(`docs/research/git-beginner-affordances.md`, ADRs 0068–0083) is thesis-level work, not
polish.

## §2 — Engineering principles

The load-bearing principles, in rough precedence order. The first four were in the
original plan; the last three were ratified during development (2026-06) and are now
plan-level peers.

1. **Defer to git.** Shell out to the user's `git`; never embed libgit2 (ADR 0023). This
   has repeatedly outperformed bespoke designs: credentials ride the user's helper chain
   (ADR 0080), interactive rebase rides git's own sequencer (ADR 0083), stash recovery
   rides `git stash store` (ADR 0079). When a bespoke mechanism and a git-native one
   compete, the git-native one has won every time so far — prefer it until it loses.
2. **Finder-first.** No app window to find; the file manager is the UI (ADR 0030). The
   agent + extension architecture (§6) follows from this.
3. **Ask less.** Convert questions into defaults, suggestions, or undo (§11). A dialog is
   a design failure unless the operation is destructive (§11.6).
4. **Safety net over confirmation.** Destructive operations write a snapshot ref *before*
   executing (ADR 0033); every destructive verb ships with a **pinned undo round-trip
   test** proving the restore path actually restores. Confirmation dialogs are honest only
   because the safety copy exists.
5. **Shared history is immutable through every standard surface.** Anything reachable from
   a remote-tracking ref refuses to be rewritten (ADRs 0082/0083) — reword, squash, and
   rebase plans never escalate to a force-push. The **sole exception is the explicit
   force-push verb itself**, kept in v1 behind the full ADR 0033 high tier: typed-phrase
   confirmation, mandatory snapshot, persistent undo banner, and always
   `--force-with-lease --force-if-includes` (raw `--force` is never emitted — CLAUDE.md
   hard rule 7). Heavy warnings, not removal.
6. **Tier discipline.** Portable core / platform adapters / per-OS shells (ADR 0048, §6).
   Tier-1 code never imports UI frameworks and never branches on `#if os(...)` for
   behavior.
7. **Real git in tests, never mocked.** Integration tests spawn real git against fixture
   repos across the pinned version matrix. HTTP fakes are the conventional seam for forge
   APIs (AIKit precedent, ADR 0078); *git* is the thing that is never faked. This caught
   `core.autocrlf`, `origin/HEAD` symref shadows, credential-manager interception, and
   `file://`-vs-local-path clone semantics — none of which a mock would have surfaced.

## §3 — Decision log

The original plan carried per-decision rationale prose for ADRs 0001–0053; that prose was
lost with the file. The surviving sources of truth are:

- **The ADR index** — [`docs/decisions/README.md`](../decisions/README.md) — one line per
  decision. ADRs 0054+ carry their full rationale inline (one-per-PR cadence).
- **The architecture docs** (`docs/architecture/`) which absorbed the load-bearing
  rationale for the scaffolding-era decisions.
- ADRs 0001–0053 are stub-form ("decision captured in the plan"); each now points here.
  When a stub ADR becomes load-bearing for new work, expand it in place (as was done for
  ADR 0051) rather than re-deriving from this file.

Ratification history: ADRs 0001–0053 were ratified together at scaffolding (2026-04);
0057–0066 together via maintainer Q&A on 2026-05-02 (§13); 0067+ one-per-PR.

## §4 — Architecture summary

See [`docs/architecture/overview.md`](../architecture/overview.md) (component diagram and
data flow) and [`docs/architecture/cross-platform.md`](../architecture/cross-platform.md)
(port guide). One-paragraph version: a **LaunchAgent-hosted agent process** watches
repositories (WatcherKit), maintains badge state (RepoState), and serves IPC
(TransportKit + IPCSchema, byte-framed `Codable` envelopes, wire-identical across XPC /
named pipes / Unix sockets); **file-manager extensions** (FinderSync / Explorer) stay thin
and delegate everything to the agent; **task windows** are per-verb processes binding
portable view models (TaskWindowKit). All git work happens through `GitCore.Runner` /
`CatFileBatch`.

## §5 — Distribution, signing, updates

- **macOS:** signed + notarized DMG, Sparkle appcast, Homebrew Cask (M9). LaunchAgent via
  `SMAppService`; FinderSync extension inside the app bundle.
- **Windows:** signed MSIX, winget manifest, WinSparkle-or-equivalent (open question in
  ADR 0055).
- **Linux:** engine + CLI source release at 1.0; GUI post-1.0 (ADR 0054).

### §5.5 — Code-signing and CI-secret handling

Signing certs and notarization credentials never land on hosted runners; release signing
runs on the **self-hosted macOS runner** (see `docs/ci/self-hosted.md`). The same runner
hosts the XCUITest E2E suite and the 100k-file benchmark gate. **Status 2026-06-11: Mac
hardware is expected within days** — provisioning this runner is the first M2-Mac
precursor task (§8), and it unblocks the M1 100k gate, the E2E suite, and per-milestone
perf proofs in one stroke.

## §6 — Three-tier architecture

Tier 1 portable core (`packages/`, pure Swift + Foundation, compiles and tests on all
three OSes), Tier 2 platform adapters (protocol + per-OS sources, portable fallback
preferred when it wins), Tier 3 per-OS shells (full rewrite per platform). The hard rules
live in CLAUDE.md and are enforced by SwiftLint custom rules + the three-OS CI matrix.
ADR 0048 records the covenant that made the transport swaps free: no XPC-native proxy
types anywhere in portable code.

## §7 — AI integration

Optional, opt-in, local-first (ADR 0007/0036/0037). Local providers (Ollama, Apple
Foundation Models) default; cloud BYOK with per-session "will send code to X" consent.
Prompts are versioned markdown in `AIKit`, user-overridable. Evals run a held-out conflict
corpus against every configured provider. AI lands at M7 — nothing before the bare merge
UX ships (M4) depends on it.

## §8 — Milestones

Canonical detail lives in [`roadmap.md`](roadmap.md) (scope) and
[`milestones.md`](milestones.md) (exit criteria). Strategic shape after the 2026-06-11
review:

- **The portable engine ran breadth-first and is ahead of the shells** — the
  M2-substrate, the complete task-window VM layer (14 VMs), and the engine halves of
  M4/M5/M6 (conflict resolver, rebase plans, history editing, stash browser,
  submodule/LFS surfaces) shipped before any shell exists. **M2.5 is the named
  checkpoint** for that state (tag `engine-0.5.0`).
- **Shell milestones are rendering milestones.** M3+ consume existing VMs; their risk is
  bring-up (binding ergonomics, extension quirks, signing), not feature construction.
  Each shell track starts with a **spike-first gate**: one real window bound to one
  existing VM before mass window-building (risk R16).
- **M2-Mac begins with the transport experiment** (§ M2-Mac in milestones.md): UDS in an
  app-group container vs the XPC adapter. The portable UDS transport already passes its
  suite on macOS; if the sandbox permits the app-group socket, the XPC adapter is deleted
  from the critical path and ADR 0048/0067 get amended. Decided on real hardware
  (imminent), not speculatively.

## §9 — Risks

Canonical: [`risk-register.md`](risk-register.md) (operational detail). Strategic
headlines: swift-cross-ui maturity (R1 — spike early on the existing Windows VM rig),
Windows shell expertise (R2), dual-shell calendar (R3), single-maintainer bus factor
(R7 — this document's loss-and-vendoring is the case study), VM↔shell binding ergonomics
(R16, new).

## §10 — Repository lifecycle and the verb surface

The right-click menu surfaces these; each maps to a sequence of git primitives. The
**MVP-10 verbs**: clone, status, commit, push, pull, fetch, branch-switch,
stage/unstage, diff, log. Highlights beyond the MVP-10 (each implemented once in the
portable engine, rendered per shell):

- **Sync** (fetch → fast-forward → plain push; never forced) — ADR 0071.
- **Commit & Push**; **Pull & Rebase** (explicit second act, never automatic) — ADR 0071.
- **Switch with dirty tree** (auto-stash around switch) — ADR 0069.
- **Resolve Conflicts** (3-way, per-region; LFS/binary aware) — ADR 0034, M4 gate.
- **Reword Last Commit / Squash Commits** (unpushed-only, snapshot-first) — ADR 0082.
- **Rebase (reorder / fold / drop)** — ADR 0083; **Rebase Stack of Branches** — ADR 0051.
- **Revert Changes** (forward-fix; the beginner-safe alternative to rewriting) — pending
  engine slice.
- **Recover Lost Work** (one list: snapshots + backups; restores that never eat work) —
  ADR 0033 amendment.
- **Set aside changes / Stash browser** — ADRs 0069/0079.
- **Force-push** — kept in v1, high-tier only (§2.5): typed phrase, snapshot, persistent
  undo banner, `--force-with-lease --force-if-includes` always.
- Repository setup: clone (URL or **browse-your-forge**, ADR 0078/0080/0081), init,
  submodule update flows (M6), LFS detect-and-install (ADR 0035).

Defaults follow `docs/research/git-best-practices.md` (e.g. `--recurse-submodules` on
clone, hourly auto-fetch ADR 0068, auto-backup ADR 0075).

## §11 — Git best practices: the intervention catalog

The original §11 held ~60 interventions, each tagged with an **intervention level**:
**(a)** silent default, **(b)** prompt on first encounter (cache the answer),
**(c)** onboarding question, **(d)** document only, **(e)** leave to the user.
Approximate split (original §11.13 tally): ~30 (a), ~12 (b), ~6 (c), ~8 (d), ~2 (e).
The full prose was lost with the plan file; the surviving structure and the authoritative
homes per subsection (mirrored in
[`git-best-practices.md`](../research/git-best-practices.md), which is the maintained
index):

- **§11.1 — Config defaults Sprig writes** (the ~30 silent defaults: `init.defaultBranch`,
  `core.fsmonitor`, `pull.ff=only`, `merge.conflictStyle=zdiff3`, etc.) → **ADR 0049**.
- **§11.2 — Performance hygiene** (Scalar-style, tiered by repo size) → **ADR 0026**.
- **§11.3 — Security defaults** (`safe.directory`, SSH signing, credentials, hook trust)
  → **ADRs 0043/0044/0050**.
- **§11.4 — Branch + workflow hygiene** (GitHub Flow default mental model,
  protected-branch detection).
- **§11.5 — Commit hygiene** (per-hunk staging, `commit.verbose`, Conventional Commits
  per-repo prompt).
- **§11.6 — History integrity** — `reset --hard` always confirms (no "don't ask again");
  force-push is always `--force-with-lease --force-if-includes` (ADR 0052) behind the
  high tier (§2.5); warn whenever published history would be rewritten. The
  unpushed-only contracts of ADRs 0082/0083 implement this section's spirit in the
  engine.
- **§11.7 — Recovery UX** ("Time Machine for Git": snapshot refs, reflog browser) →
  **ADR 0033** + the Recover surface.
- **§11.8 — Hooks** (opt-in only; trust prompts) → **ADR 0050**.
- **§11.9 — Git LFS** (detect + one-click install; migration warnings) → **ADR 0029**.
- **§11.10 — Submodules / subtrees / monorepo** (discourage for new projects; sane
  defaults for existing users).
- **§11.11 — Secrets + safety** (global OS-noise excludes — implemented via the
  ADR 0049 amendment's `GlobalExcludes`; secret-scan and history-removal wizard remain
  future work; backups already exclude likely secrets per ADR 0075's deny-list).
- **§11.12 — Collaboration hygiene** (forge integration ADR 0063/0078–0081; stacked-PR
  detection ADR 0051).
- **§11.13 — Source list** → preserved verbatim in `git-best-practices.md`.

The companion **"ask less" taxonomy** — convert questions into defaults, suggestions, or
undo; recurring prompts are never acceptable — is the organizing principle layered on
top of these levels; its canonical statement lives in
[`git-beginner-affordances.md`](../research/git-beginner-affordances.md) and it is a
plan-level principle (§2.3).

## §12 — Testing and quality

CLAUDE.md's testing expectations are canonical. Plan-level additions ratified 2026-06-11:

- **Slice gate:** every engine slice passes the full local suite, lint, the full
  Windows-VM sweep, and the **adjusted-gate receipt protocol** for the known
  environmental members — see [`docs/ci/slice-gate.md`](../ci/slice-gate.md) and the
  audit-followups entry `VM-ENV-1`.
- **Undo round-trip rule:** no destructive verb ships without a test that performs the
  operation and then restores through the real Recover path, asserting the original
  state byte-/SHA-exactly.
- **Suite growth threshold:** when the full VM sweep exceeds ~10 minutes wall, gating
  splits into changed-target sweeps per slice + a nightly full sweep. Until then, full
  sweep per slice.

## §13 — Competitive review synthesis (2026-05-02)

A review of 50+ git GUIs (TortoiseGit, Tower, Fork, GitKraken, Sourcetree, GitButler,
lazygit, et al.) filtered through the Finder-first invariant produced ADRs 0057–0066,
ratified together via maintainer Q&A on 2026-05-02. The synthesis prose was lost with the
original plan file; the ratified outcomes ARE the ADRs (see the index). The durable
takeaways that keep informing design: the file-manager-first niche is empty since
TortoiseGit (Windows-only) and nothing occupies it on macOS; undo-centric safety
(GitButler's lesson) beats confirmation-centric safety; and beginner vocabulary (Fork's
lesson) is a feature surface, not copywriting.
