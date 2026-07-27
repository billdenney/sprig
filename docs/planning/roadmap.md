# Roadmap

Sprig 1.0 ships GUI shells for macOS and Windows in parallel. The engine and `sprigctl` CLI are first-class on macOS, Linux, and Windows from day 1. Linux GUI shell is post-1.0. See ADR 0054 for the strategic decision and ADR 0055 for the Windows GUI stack choice.

## Where we actually are *(status check, 2026-07-27)*

Read this before picking up work. The engine has outrun the shells by so much that the milestone table below no longer describes the project's real position.

| | |
|---|---|
| Engine + CLI | ~31.6k lines source, ~32.5k lines tests, 22 packages, 18 `sprigctl` subcommands, 97 ADRs, 451 commits |
| GUI shells (`apps/`) | **0 lines** — three `README.md` files |

- **No user has ever driven Sprig through a UI.** Every line of the engine is reachable only from `sprigctl` or a test.
- **`TaskWindowKit` holds 21 view models for windows that do not exist.**
- **M2-Mac: 0 of 8 exit criteria met.** M1 still has its 100k-file benchmark gate open.
- **ADRs 0084–0096 — thirteen features — shipped with no consumer.** Region staging, forge releases, file history, sparse checkout, secret-scan rails, agent-review surface, multi-repo roll-up, AI situation explainer, submodule auto-reconcile. Each defensible alone; together they widened the never-used surface and each one carried the full three-OS slice gate.

**How this happened.** The shell tracks are hardware-blocked — the self-hosted macOS-arm64 runner (and with it signing, XCUITest, and the M1 benchmark gate) was expected 2026-06 and hasn't arrived. Rather than idle, each development cycle found engine work; the cheap engine work was long done, so the slices moved steadily further out onto speculative ground. The result is a well-tested engine built almost entirely on unfalsified guesses about what a UI will need.

**The guard rail that was overrun.** Risk R16 records that the actor-VM binding pattern is "plausible but unproven" and prescribes *"the M3 spike-first gate — one real window per shell before mass window-building."* The VM count then went from 14 to 21. The gate was written down and walked past. It is now binding again.

**Consequence for prioritisation — engine feature work is paused.** The next unit of work that produces new information is a shell, not an ADR. Concretely, the first task is **risk R1's swift-cross-ui spike**, which the risk register already says should run early because the Windows VM rig exists: build one Status window over the existing `StatusViewModel`, GTK backend on Linux for iteration speed, then confirmed on the Windows VM. That single window falsifies-or-confirms both R1 (framework viability) and R16 (binding ergonomics), and becomes the first non-test consumer of `TaskWindowKit`. Expect it to demand changes to the VM layer — that is the information being bought, and it is cheaper to learn now than after a 22nd view model.

Adding an engine feature is not forbidden, but it now needs an answer to "what consumes this?"

## Platform tier

| Surface | M0 | M1 | M2 | M3 | M4 (MVP) | M5 | M6 | M7 | M8 | M9 (1.0) |
|---|---|---|---|---|---|---|---|---|---|---|
| Engine + `sprigctl` (macOS / Linux / Windows) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| macOS GUI shell | — | — | alpha | task windows | merge UI | branching | submodules+LFS | AI | beta | 1.0 |
| Windows GUI shell | — | — | research | swift-cross-ui foundations | merge UI | branching | submodules+LFS | AI | beta | 1.0 |
| Linux GUI shell | — | — | — | — | — | — | — | — | — | post-1.0 |

CI required-green on every PR: `ci-macos`, `ci-linux` (full test suite on `packages/` + `cli/`), `ci-windows` (full test suite on `packages/` + `cli/`). Once Windows-shell work begins (M2-Win), the Windows CI matrix expands to cover the Explorer extension build + the swift-cross-ui app build.

## Milestones

The macOS-shell and Windows-shell tracks share most engineering work — the engine, the parsers, the `RepoState`/`TaskWindowKit` view-model layer. Per-shell work is concentrated in: the file-manager extension, the IPC adapter (XPC ↔ named pipes), the installer + updater, and the GUI framework (SwiftUI + AppKit ↔ swift-cross-ui).

**Track legend**: `🍎 Mac` (macOS-shell only), `🪟 Win` (Windows-shell only), `🌐 Engine` (cross-platform engine / CLI / shared view-model code).

### M0 — Foundations

🌐 Docs, CI matrix (macOS + Linux full tests + Windows full tests), SPM skeleton, ADRs 0001–0055 accepted. Contributor onboarding usable end-to-end.

### M1 — Read-only prototype *(in progress)*

🌐 `GitCore.Runner` + `CatFileBatch` + `PorcelainV2Parser` + `LogParser`. `WatcherKit.FSEventsWatcher` (macOS), `WatcherKit.PollingFileWatcher` (portable, used on Linux/Windows today). `sprigctl` subcommands: `version`, `status`, `watch`, `repos`, `log`. Validates 100k-file perf budget via benchmarks (pending).

### M2 — Shell integration alpha (parallel tracks)

> **2026-06-11:** the 🌐 engine share of M2 is substantively shipped (transports + serving
> hosts + preferences wiring + the complete TaskWindowKit VM layer + the beginner-affordance
> backlog 1.1–3.5 where ratified) — see `milestones.md`'s substrate note. Remaining M2 work
> is concentrated in the 🍎/🪟 shell tracks.


- 🍎 **M2-Mac — FinderSync alpha**: SprigAgent LaunchAgent, XPC protocol, FinderSync extension with overlay badges and the MVP-10 right-click verbs (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log). Sheets, not full task windows yet.
- 🪟 **M2-Win — Explorer shell-extension alpha**: research spike on `IShellIconOverlayIdentifier` (15-overlay-slot competition with OneDrive/Dropbox), `IContextMenu` plumbing, named-pipe IPC to a Windows Service host of SprigAgent. `docs/research/windows-shell-apis.md` lands here as the M2-Mac equivalent of `docs/research/macos-finder-apis.md`. By the end of M2-Win, overlay badges + the MVP-10 verbs work in Explorer.

The two M2 sub-milestones can run sequentially (Mac first, Win second) or in parallel if the Windows expert is available — engineering plan decides per-PR. The `IPCSchema` package is shared across both. **M2-Mac starts with the self-hosted-runner provisioning + the Mac-transport experiment** (UDS-in-app-group vs XPC) — see `milestones.md`; Mac hardware is imminent (2026-06).

### M2.5 — Portable-engine checkpoint *(added 2026-06-11)*

🌐 The named checkpoint for the engine having run ahead of the shells: 14 task-window
VMs, IPC serving on two transports, ADRs 0068–0083, the full beginner-affordance
backlog, `sprigctl` at 17 subcommands. Tagged `engine-0.5.0`; exit criteria in
`milestones.md`. Shell milestones below consume this state.

### M3 — First task windows (parallel tracks)

**Re-scoped 2026-06-11** (the VM layer already exists — M3 is shell *bring-up*, not feature construction; see `milestones.md` for the spike-first gate and window order):

- 🍎 **M3-Mac**: SwiftUI + AppKit task windows over the existing `TaskWindowKit` VMs — spike one window (Status) first to validate the actor-VM binding pattern, then the daily-driver set (Commit, Sync, Clone, Stash, Recover), then the rest.
- 🪟 **M3-Win**: same windows in swift-cross-ui (per ADR 0055); the swift-cross-ui spike runs early on the existing Windows VM rig (R1). Per-window tweaks for Windows-native interaction conventions (menu placement, keyboard shortcuts).

### M4 — MergeConflictResolver (MVP gate, parallel tracks)

- 🍎 **M4-Mac**: 3-way merge view, conflict list, hunk-level accept/reject, snapshot safety net. macOS-specific high-density text rendering via `NSTextView`.
- 🪟 **M4-Win**: same 3-way merge view in swift-cross-ui. Open question deferred to M4 start: whether the Windows version uses a swift-cross-ui-native text view or drops to native Win32 for the diff pane.

🎯 **MVP ships here** on both shells.

### M5 — Rebase + advanced branching

🌐 RebaseInteractive, cherry-pick, revert, tag, stash. Implemented once in shared view models; rendered in both shells.

### M6 — Submodules + LFS first-class

🌐 SubmoduleManager, LFS install flow, `git subtree` import wizard.

### M7 — AI integration

🌐 Merge suggestions, commit-message drafting, PR description drafting. Ollama one-click installer (with platform-specific install commands per OS).

### M8 — Beta

🌐 Perf budgets verified in CI on both macOS and Windows (Linux for engine-only). a11y pass on both shells. Localization scaffolding (`String(localized:)` cross-platform).

### M9 — 1.0

- 🍎 **macOS**: signed/notarized DMG, Sparkle appcast, Homebrew Cask submission.
- 🪟 **Windows**: signed MSIX, winget manifest submission, WinSparkle (or chosen equivalent — see open question in ADR 0055) appcast.
- 🌐 **Linux**: source release tag with build instructions; engine + CLI usable. GUI shell explicitly out of scope at 1.0 (see ADR 0054).
- Docs site at `docs.sprig.app` (per ADR 0045).

## Risks specific to the dual-shell commitment

- **Calendar slip**: each macOS-shell milestone needs a Windows-shell counterpart. Worst case (strict serialization), 1.0 takes ~2× the engineering calendar of a macOS-only 1.0. Mitigation: invest hard in shared view-model code in `TaskWindowKit` so the per-shell delta is small.
- **Contributor recruiting**: Windows-shell work needs Windows-native expertise (COM, MSIX, Windows Service authoring). The maintainer's BDFL coverage probably can't fill this alone. ADR 0017's "open up steering when 3+ steady contributors emerge" applies — finding a Windows-shell-savvy collaborator is on the M2 critical path.
- **swift-cross-ui maturity**: framework is younger than SwiftUI on macOS. ADR 0055 documents the WinUI 3 fallback. The re-evaluation spike no longer waits for M3-Win's calendar slot — the Windows VM test rig exists now, so the spike is cheap and should run early (risk R1).
- **View-model binding ergonomics (R16)**: 14 actor-based VMs were built before any shell exists; the documented SwiftUI consumption pattern is plausible but unproven. Mitigation: the M3 spike-first gate — one real window per shell before mass window-building.
- **Distribution doubling**: macOS DMG + Homebrew Cask **and** Windows MSIX + winget. Both pipelines need release engineering and code-signing infrastructure.

See `docs/planning/risk-register.md` for the full risk list (engine + per-shell risks combined).
