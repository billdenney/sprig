# Milestones — exit criteria

Concrete "done means done" gates for each milestone. Companion to [`roadmap.md`](roadmap.md), which sketches what's *in* each milestone; this file says *how we know it shipped*. M0/M1/M2 written substantively (we're working on them); M3+ is outline-form and gets expanded as each one is scoped.

ADR cross-references throughout — each milestone exits cleanly only if all its referenced ADRs are implemented and verified.

> **Read [`roadmap.md`'s status check](roadmap.md#where-we-actually-are-status-check-2026-07-27) first.** As of 2026-07-27 the engine is ~31.6k lines and the GUI shells are 0 lines; M2-Mac has met 0 of 8 exit criteria while thirteen post-M2.5 ADRs shipped with no consumer. Engine feature work is paused in favour of the first real window. The per-milestone criteria below are still the right gates — but the *order* the sections imply is not the order work should now happen in.

## M0 — Foundations

**Status:** complete (initial scaffolding shipped; CI matrix all required-green).

Exit criteria:

- [x] `apps/macos/`, `apps/windows/`, `apps/linux/` directories exist; macOS populated, others README-only placeholders (ADR 0053).
- [x] Every `PlatformKit` protocol has Mac/Linux/Windows source files committed (stubs OK for Linux/Windows where no native impl exists yet).
- [x] `swift build` succeeds in `packages/` on macOS, Linux, and Windows toolchains.
- [x] `ci-macos`, `ci-linux`, `ci-windows` all required-green on a trivial PR.
- [x] SwiftLint custom rules forbidding AppKit/SwiftUI/Combine/FinderSync imports in `packages/` armed and tested.
- [x] LICENSE (Apache-2.0), CODE_OF_CONDUCT, SECURITY, GOVERNANCE, CHANGELOG present.
- [x] ADRs 0001–0055 in `docs/decisions/` with index README.
- [x] `script/test`, `script/lint`, `script/format`, `script/bootstrap` runnable on macOS + Linux.
- [x] Docs scaffolding present (architecture/, ci/, planning/, research/, ux/, decisions/).

## M1 — Read-only prototype

**Status:** in progress.

Exit criteria:

- [x] `GitCore.Runner` shipped with case-insensitive PATH lookup, env scrubbing, UTF-8 locale forcing, typed errors.
- [x] `GitCore.CatFileBatch` actor-isolated long-lived `git cat-file --batch` wrapper.
- [x] `GitCore.PorcelainV2Parser` parses `git status --porcelain=v2 -z` byte-for-byte against a fixture corpus.
- [x] `GitCore.LogParser` parses `git log -z --format=...` against the LogParser format string; `Commit` + `Identity` typed model.
- [x] `WatcherKit.FSEventsWatcher` (macOS) live; `WatcherKit.PollingFileWatcher` portable; `WatcherKit.MockFileWatcher` for tests.
- [x] `WatcherKit.EventCoalescer` priority-weighted dedupe, with full unit-test coverage of priority interactions and overflow.
- [x] `cli/sprigctl` ships subcommands: `version`, `status`, `watch`, `repos`, `log`.
- [x] `Benchmarks/SprigCoreBenchmarks/` benchmarks via `package-benchmark`: `PorcelainV2Parser.parse` 1k/10k/100k, `LogParser.parse` 1k/10k, `EventCoalescer` ingest→drain at 1k/10k, `PollingFileWatcher.takeSnapshot` 1k/10k/100k, end-to-end `Runner.run + PorcelainV2Parser.parse` against synthesized 1k/10k file repos. (100k-file end-to-end benchmark deferred to the self-hosted runner workflow — synthesis would push hosted-CI setup time past 30 s; ADR 0021 budget validation at that scale lives in `.github/workflows/benchmarks.yml`.)
- [ ] Benchmarks pass on a synthesized 100k-file fixture within ADR 0021 budgets (CPU, RAM, status latency). **Deferred** to self-hosted runner provisioning — but the infrastructure is in place: `Benchmarks/SprigCoreBenchmarks.swift`'s `statusEndToEndBenchmarks` ladder is extended to 100k, so when the runner comes online and runs `.github/workflows/benchmarks.yml`, the perf comparisons pick up automatically (see `docs/ci/self-hosted.md`). A 100k-scale **opt-in smoke** (`tests/integration/Tests/IntegrationTests/Status100kFileBudgetTests.swift`) is also available — guarded by `SPRIG_RUN_SCALE_TESTS=1` so it doesn't auto-run on every PR (100k file synthesis is expensive on hosted CI, especially Windows where individual filesystem ops can take ~2 s per the cross-platform-quirks catalog). The smoke can be triggered manually (`SPRIG_RUN_SCALE_TESTS=1 swift test --filter Status100kFileBudgetTests`) for pre-release spot checks or attached to a future self-hosted nightly workflow.
- [x] `swift run sprigctl status <fixture>` matches `git status --porcelain=v2 -z` byte-for-byte across every `tests/fixtures/repos/*` fixture. **Interpretation note:** sprigctl status itself emits human-readable / JSON output (not raw porcelain), so literal byte equality of binary outputs is impossible by design. The honest test is **parser fidelity** — `PorcelainV2Parser.parse(_:)` correctly handles every porcelain-v2 byte sequence git emits across the documented fixture states (clean / modified / staged / both / untracked / deleted / renamed / gitignored / merge-conflict). Wired in `tests/integration/Tests/IntegrationTests/SprigctlStatusByteMatchTests.swift`; runs on every PR across macOS / Linux / Windows.
- [x] Watcher processes 10k synthetic file-change events at <2% CPU on macOS-14 hosted runner (proxy for ADR 0021 steady-state CPU). **Implementation note:** CPU% isn't directly assertable from inside a swift-testing test (no portable read of `/proc/self/stat` etc.), so we proxy with wall-clock time on a single-core synthetic load — if `EventCoalescer` ingests + drains 10k events well under one wall-clock second, steady-state CPU under real watcher load (a few hundred events/sec) is safely below the ADR 0021 budget. Wired in `tests/integration/Tests/IntegrationTests/WatcherEventBudgetTests.swift`; runs on every PR across macOS / Linux / Windows. The 1 s budget has ~5× margin over the typical Linux measurement (~30 ms); tighten when the assertion shows consistent slack on every platform's CI history.

The parser-fidelity and watcher event-budget gates are now wired into hosted CI on every PR via the `ci/m1-m2-exit-gate-integration-tests` branch. The 100k-file gate stays formally deferred: the benchmark ladder is ready for the self-hosted runner and an opt-in smoke is available, but neither runs on hosted CI by default (the per-PR cost would be prohibitive without commensurate signal).

## M2 — Shell integration alpha (parallel tracks)

> **Substrate status (2026-06-11).** The portable share of M2 is substantively done ahead of
> the shell work: `IPCSchema` envelopes serving real clients end-to-end on **two transports**
> (UDS with same-user peer validation, ADR 0076; Windows named pipes, ADR 0067 — byte-identical
> framing), the agent host running preferences-driven background jobs (`sprigctl agent
> --preferences/--socket/--pipe`, ADR 0068/0075 host wiring), per-client dispatchers + routed
> event fan-out, and the full task-window VM layer (eleven VMs incl. Status + Recover). What
> remains in the lists below is genuinely shell-territory: the Mac XPC adapter + LaunchAgent
> registration, the FinderSync/Explorer extensions, and the per-platform perf/a11y proofs.


### M2-Mac — FinderSync alpha

> **Precursor (2026-06-11, Mac hardware imminent):** provision the self-hosted
> macOS-arm64 runner first — it unblocks the M1 100k benchmark gate, the E2E suite, the
> badge-latency verification below, and release signing (master-plan §5.5) in one stroke.
>
> **Experiment #1 — the Mac transport.** Before writing the XPC adapter, verify on real
> hardware whether the FinderSync extension and the LaunchAgent can rendezvous over the
> existing **Unix-domain-socket transport via an app-group container** socket path. The
> portable UDS transport already compiles and passes its full suite on macOS (incl.
> `getpeereid` peer validation), and the two-process e2e tests already cover it. If the
> sandbox permits it: the XPC adapter is deleted from the critical path, one wire
> transport serves all three platforms, and ADR 0048/0067 get amended. If not: ship the
> XPC adapter as planned. Either way the experiment is hours, and it decides a whole
> adapter.

Exit criteria:

- [ ] `SprigAgent` LaunchAgent registered via `SMAppService`, runnable across reboots.
- [ ] `IPCSchema` Codable envelopes finalized for v1; **Mac transport decided by experiment #1** — UDS-in-app-group (preferred if sandbox-verified) or the XPC adapter in `TransportKit/Mac` — shipped, with ADR 0048/0067 amended to record the outcome.
- [ ] `RepoState` (basic dirty-set + badge trie) populated by `WatcherKit` events.
- [ ] `SprigFinder` extension shipping the 10-state badge set (or 5/8 per user's reveal-level preference).
- [ ] Right-click menu shows the MVP-10 verbs (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log) plus `Sprig ▶` submenu.
- [ ] Verbs that need a dialog open temporary sheets (full task windows arrive in M3-Mac).
- [ ] Badges update within 500 ms of a git write op in a fixture repo (verification mechanism TBD — XCUITest needs a self-hosted macOS-arm64 runner we don't yet operate; until provisioned, manual-verification + integration-test proxy at the IPC layer).
- [ ] Steady-state CPU <1%, memory <50 MB on 100k-file fixture (ADR 0021 sub-budget for the alpha).
- [ ] FinderSync extension memory <30 MB resident under load.

### M2-Win — Explorer shell-extension alpha

Exit criteria:

- [ ] `docs/research/windows-shell-apis.md` is the canonical implementation reference for M2-Win (cross-link from the SprigExplorer source files when written).
- [ ] Windows Service host of `SprigAgent` installable via MSIX (per-user, no admin elevation).
- [ ] `IPCSchema` named-pipe transport in `TransportKit/Windows` shipped, peer-SID validation working.
- [ ] `SprigExplorer.dll` C++/COM extension implementing 5 `IShellIconOverlayIdentifier` classes + `IContextMenu` (legacy) + `IExplorerCommand` (Windows 11 streamlined).
- [ ] Badges render on a fixture repo within 500 ms of a `git status` change.
- [ ] `IsMemberOf` p99 latency <50 ms across a 100k-file fixture.
- [ ] Forced exception in any COM entry point does not crash `explorer.exe`.
- [ ] Killing the SprigAgent service falls back to "no badge / no menu" within 2 seconds, no Explorer hang.
- [ ] First-run diagnostic showing overlay-slot competition (vs OneDrive et al) functional.

## M2.5 — Portable-engine checkpoint *(new, 2026-06-11 plan review)*

The engine ran breadth-first and outpaced the shells: the complete task-window VM layer
(**14 view models**), the IPC substrate on two transports, the beginner-affordance
backlog 1.1–3.5, and the engine halves of M4 (conflict resolver), M5 (rebase plans,
history editing, stash), and M6 (submodule/LFS surfaces) shipped before any shell
exists. M2.5 names and tags that state so the changelog has a cadence anchor and the
milestone-exit disciplines actually fire.

Exit criteria:

- [x] ADRs 0068–0083 ratified and implemented with the slice gate (`docs/ci/slice-gate.md`).
- [x] `sprigctl` surfaces the engine end-to-end (17 subcommands — see `docs/architecture/sprigctl-cli.md`).
- [x] Disabled-tests review: `disabled-tests.md` is empty (nothing disabled on CI).
- [x] Audit-followups review: every Pending entry has a live trigger (`VM-ENV-1` filed as part of this review; `UP-5472` re-checked 2026-06-11, still pinned; `R15-F1..F4` remain deliberately deferred until M2 agent surfaces real failures).
- [x] Master plan vendored into the repo (`master-plan.md`) after the original's loss; ADR stubs re-pointed.
- [ ] Tag `engine-0.5.0` on main (cut by maintainer after this PR merges; CHANGELOG section already snapshotted).

Honest remaining *engine* backlog (tracked, not blocking the checkpoint): stacked-branch
restack (ADR 0051 on the 0083 substrate), plan message-editing, the Revert verb,
ForgeKit PR list, AIKit feature integration (M7).

> **What happened after this checkpoint *(added 2026-07-27)*.** M2.5 was written to *name*
> the engine-outran-the-shells problem and make the milestone disciplines fire. It did not
> stop the pattern: between 2026-06-11 and 2026-07-27 the engine took on thirteen more
> ADRs (0084–0096), the VM count went **14 → 21**, and the shells stayed at zero lines.
> The "honest remaining engine backlog" above was worked through and then extended well
> past itself. `engine-0.5.0` was never tagged.
>
> The lesson is the one CLAUDE.md already states as a rule — *a policy that lives only in
> prose will be violated; if something has recurred, add a mechanical gate.* Naming the
> problem in a planning doc was prose. The gate that actually binds is **M3's spike-first
> gate below**: no 22nd view model until one real window exists. Treat the VM count as
> frozen at 21 until that window is running.

## M3 — First task windows (parallel tracks)

**Re-scoped 2026-06-11:** the original M3 planned *building* 6 windows; the VM layer now
holds **21 ready view models** (14 at the 2026-06-11 re-scope), so M3 is a **shell
bring-up** milestone — its risk is binding ergonomics and platform quirks, not feature
construction.

**Promoted 2026-07-27:** with the Mac runner still unprovisioned and engine feature work
paused, the spike-first gate below is no longer waiting for M3's calendar slot — it is the
**current** task. It runs on the Windows VM rig + a local Linux GTK build, neither of which
needs Mac hardware.

- **Spike-first gate (both shells, risk R16):** the FIRST M3 task per shell is one real
  window bound to one *existing* VM (suggested: Status), explicitly to validate the
  actor-VM ↔ UI binding pattern before any mass window-building. If the pattern needs
  rework (e.g. a `@MainActor` observable façade over the actors), fix it once, while
  the change is cheap, and record it as an ADR.
  - 🪟 The swift-cross-ui half of this spike should run **now-ish on the existing
    Windows VM rig** rather than waiting for M3-Win's calendar slot — R1's "re-evaluate
    at M3-Win start" is cheap to satisfy early.
- **Window order is usage-priority, not the original fixed six:** Status, CommitComposer,
  Sync, CloneDialog, Stash, Recover first (the daily-driver loop), then LogBrowser,
  DiffViewer, BranchSwitcher, Preferences, and the rest of the 14.

Critical exit gates (unchanged in spirit):

- All shipped windows reuse `TaskWindowKit` view models (Tier 1 portable); per-shell
  delta is rendering-only (SwiftUI on macOS, swift-cross-ui on Windows).
- Every task window passes the VoiceOver / Narrator a11y audit checklist (ADR 0042).
- LogBrowser renders 50k-commit history in <300 ms.
- CommitComposer → push round-trip works against a local bare fixture remote.

## M4 — MergeConflictResolver (MVP gate, parallel tracks)

**Outline; expand at M4 scoping.** *(2026-06-11 note: the engine half is substantively
built — `MergeConflictResolverViewModel` with per-region text resolution, LFS/submodule
conflict classification, midstream finalize/abort. M4 is the rendering + fixtures
milestone over that engine.)*

Goal: 3-way merge view, conflict list, hunk-level accept/reject, "abort merge" safety, binary/LFS conflict handling. Optional delegation to external mergetools.

Critical exit gates (preview):

- 20+ real-world conflict fixtures (text, binary, LFS, CRLF, rename-vs-edit, submodule pointer) resolve without data loss on both shells.
- Snapshot-ref safety net (ADR 0033) restores state after every destructive op (integration tests against `SafetyKit` + the `GitCore.Runner` chain; full E2E re-introduced once a self-hosted runner is provisioned).
- External-mergetool delegation tested for FileMerge + VS Code (macOS), `WinMerge` + VS Code (Windows).
- AI not yet enabled at this milestone — bare merge UX is the MVP gate.

🎯 MVP ships at M4 exit on both shells.

## M5 — Rebase + advanced branching

**Outline.** *(2026-06-11 note: large engine pieces shipped early — the rebase-plan
engine ADR 0083, reword/squash ADR 0082, the stash browser ADR 0079, with tiered
confirmations + snapshot pairing test-pinned throughout. Remaining engine work:
stacked-branch restack (ADR 0051), message-editing inside plans, the Revert verb,
cherry-pick/tag flows. The rest of M5 is rendering.)* RebaseInteractive task window,
cherry-pick, revert, tag, stash flows. Tiered confirmations (ADR 0033) firing correctly
per destructiveness level. Interactive rebase produces identical history vs.
`git rebase -i` for 50 scripted scenarios (the ADR 0083 engine defers to
`git rebase -i` itself, so this gate is about the *plan construction + UI*, not replay
fidelity).

## M6 — Submodules + LFS first-class

**Outline.** *(2026-06-11 note: engine surfaces exist — `sprigctl submodule`/`lfs`
commands, LFS-aware conflict classification; M6 is the task-window + install-flow
milestone.)* SubmoduleManager task window, submodule badges + right-click actions, LFS detection + install flow (Homebrew + fallback), `git subtree` import wizard. Nested submodule fixtures (3 levels deep) render correctly. LFS install completes in <30 s on a fresh macOS VM and a fresh Windows VM.

## M7 — AI integration

**Outline.** AIKit provider abstraction, one-click Ollama installer per OS, conflict-resolution suggestions in MergeConflictResolver, commit-message suggestion in CommitComposer, PR-description drafting. AI eval harness (ADR 0038) runs against all providers; % matching gold on held-out conflict set above 60% (Anthropic/OpenAI), above 40% (Ollama default), publicly reported.

## M8 — Beta

**Outline.** Perf budgets hold in CI on 100k-file and 500k-file fixtures on both shells. A11y sweep with zero unresolved issues. Localization scaffolding exercised by at least one community-contributed language. Crash-report pipeline tested with an opt-in test (ADR 0014).

## M9 — 1.0

**Outline.**

- 🍎 macOS: signed/notarized DMG auto-updates from beta via Sparkle. Homebrew cask PR merged.
- 🪟 Windows: signed MSIX auto-updates via WinSparkle (or equivalent). winget manifest submitted.
- 🌐 Linux: source release tag; build instructions in README; engine + `sprigctl` smoke-tested on Ubuntu 24.04, Fedora 41, Arch.
- Docs site live at `docs.sprig.app`.
- Crash-report pipeline exercised with an opt-in test on each shell.
- All ADR-driven safety mechanisms (snapshots, force-with-lease, hook-trust prompts, AI privacy gates) verified by acceptance tests.
- README "Sprig 1.0" announcement post drafted, ready to publish.
