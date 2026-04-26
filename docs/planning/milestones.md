# Milestones — exit criteria

Concrete "done means done" gates for each milestone. Companion to [`roadmap.md`](roadmap.md), which sketches what's *in* each milestone; this file says *how we know it shipped*. M0/M1/M2 written substantively (we're working on them); M3+ is outline-form and gets expanded as each one is scoped.

ADR cross-references throughout — each milestone exits cleanly only if all its referenced ADRs are implemented and verified.

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
- [x] `WatcherKit.FSEventsWatcher` (macOS) live; `WatcherKit.PollingFileWatcher` portable; `WatcherKit.MockFileWatcher` for tests.
- [x] `WatcherKit.EventCoalescer` priority-weighted dedupe, with full unit-test coverage of priority interactions and overflow.
- [x] `cli/sprigctl` ships subcommands: `version`, `status`, `watch`, `repos`. (`log` deferred — no `GitCore.LogParser` shipped yet; lands as a follow-up before M1 exit.)
- [~] `tests/benchmarks/` first-cut benchmarks: `PorcelainV2Parser.parse` 1k/10k/100k and `EventCoalescer` ingest→drain at 1k/10k landed (Benchmarks/SprigCoreBenchmarks/, package-benchmark harness). Pending: `PollingFileWatcher.takeSnapshot` 1k/10k/100k, end-to-end `sprigctl status` 1k/10k/100k, `LogParser.parse` (after LogParser ships).
- [ ] Benchmarks pass on a synthesized 100k-file fixture within ADR 0021 budgets (CPU, RAM, status latency).
- [ ] `swift run sprigctl status <fixture>` matches `git status --porcelain=v2 -z` byte-for-byte across every `tests/fixtures/repos/*` fixture.
- [ ] Watcher processes 10k synthetic file-change events at <2% CPU on macOS-14 hosted runner (proxy for ADR 0021 steady-state CPU).

The two unchecked items are M1's perf-validation tranche; they're the M1 → M2 gate.

## M2 — Shell integration alpha (parallel tracks)

### M2-Mac — FinderSync alpha

Exit criteria:

- [ ] `SprigAgent` LaunchAgent registered via `SMAppService`, runnable across reboots.
- [ ] `IPCSchema` Codable envelopes finalized for v1; XPC transport in `TransportKit/Mac` shipped.
- [ ] `RepoState` (basic dirty-set + badge trie) populated by `WatcherKit` events.
- [ ] `SprigFinder` extension shipping the 10-state badge set (or 5/8 per user's reveal-level preference).
- [ ] Right-click menu shows the MVP-10 verbs (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log) plus `Sprig ▶` submenu.
- [ ] Verbs that need a dialog open temporary sheets (full task windows arrive in M3-Mac).
- [ ] Badges update within 500 ms of a git write op in a fixture repo (XCUITest).
- [ ] Steady-state CPU <1%, memory <50 MB on 100k-file fixture (ADR 0021 sub-budget for the alpha).
- [ ] FinderSync extension memory <30 MB resident under load.

### M2-Win — Explorer shell-extension alpha

Exit criteria:

- [ ] `docs/research/windows-shell-apis.md` substantively expanded (currently a v0 sketch — by M2-Win exit it's the canonical implementation reference).
- [ ] Windows Service host of `SprigAgent` installable via MSIX (per-user, no admin elevation).
- [ ] `IPCSchema` named-pipe transport in `TransportKit/Windows` shipped, peer-SID validation working.
- [ ] `SprigExplorer.dll` C++/COM extension implementing 5 `IShellIconOverlayIdentifier` classes + `IContextMenu` (legacy) + `IExplorerCommand` (Windows 11 streamlined).
- [ ] Badges render on a fixture repo within 500 ms of a `git status` change.
- [ ] `IsMemberOf` p99 latency <50 ms across a 100k-file fixture.
- [ ] Forced exception in any COM entry point does not crash `explorer.exe`.
- [ ] Killing the SprigAgent service falls back to "no badge / no menu" within 2 seconds, no Explorer hang.
- [ ] First-run diagnostic showing overlay-slot competition (vs OneDrive et al) functional.

## M3 — First task windows (parallel tracks)

**Outline; expand at M3 scoping.**

Goal: replace the M2 sheets with proper standalone task windows on both shells. Concrete windows: CommitComposer, LogBrowser, DiffViewer, BranchSwitcher, CloneDialog, Preferences.

Critical exit gates (preview):

- All 6 task windows reuse view-model code from `TaskWindowKit` (Tier 1 portable).
- Per-shell delta is rendering-only (SwiftUI on macOS, swift-cross-ui on Windows).
- Every task window passes the VoiceOver / Narrator a11y audit checklist (ADR 0042).
- LogBrowser renders 50k-commit history in <300 ms.
- CommitComposer → push round-trip works against a local bare fixture remote.

## M4 — MergeConflictResolver (MVP gate, parallel tracks)

**Outline; expand at M4 scoping.**

Goal: 3-way merge view, conflict list, hunk-level accept/reject, "abort merge" safety, binary/LFS conflict handling. Optional delegation to external mergetools.

Critical exit gates (preview):

- 20+ real-world conflict fixtures (text, binary, LFS, CRLF, rename-vs-edit, submodule pointer) resolve without data loss on both shells.
- Snapshot-ref safety net (ADR 0033) restores state after every destructive op tested in E2E.
- External-mergetool delegation tested for FileMerge + VS Code (macOS), `WinMerge` + VS Code (Windows).
- AI not yet enabled at this milestone — bare merge UX is the MVP gate.

🎯 MVP ships at M4 exit on both shells.

## M5 — Rebase + advanced branching

**Outline.** RebaseInteractive task window, cherry-pick, revert, tag, stash flows. Tiered confirmations (ADR 0033) firing correctly per destructiveness level. Interactive rebase produces identical history vs. `git rebase -i` for 50 scripted scenarios.

## M6 — Submodules + LFS first-class

**Outline.** SubmoduleManager task window, submodule badges + right-click actions, LFS detection + install flow (Homebrew + fallback), `git subtree` import wizard. Nested submodule fixtures (3 levels deep) render correctly. LFS install completes in <30 s on a fresh macOS VM and a fresh Windows VM.

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
