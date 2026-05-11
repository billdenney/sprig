# Disabled CI tests — tracking surface

The list of tests currently disabled on CI, why, and what unblocks re-enabling. Per `CLAUDE.md` "Disabled CI tests must be tracked and re-enabled ASAP," every disabled test must appear here within the same PR that disables it. Re-enabling happens in a follow-up PR as soon as the underlying issue is fixed.

## Currently disabled

### `PollingFileWatcherRealFSTests` (whole suite) — disabled on Windows 2026-05-09

- **Where:** `packages/WatcherKit/Tests/WatcherKitTests/PollingFileWatcherTests.swift` — the suite is wrapped in `#if !os(Windows)`. The pure-logic `PollingFileWatcherDiffTests` suite still runs on every platform.
- **Symptom:** `createDetected` (and intermittently `modifyDetected` / `removeDetected`) fail on Windows hosted runners with `events: []` — the polling watcher's `FileManager.contentsOfDirectory` snapshot doesn't surface the new/changed/removed file within the test budget.
- **Suspected root cause:** Foundation's `contentsOfDirectory` on Windows uses `FindFirstFile` / `FindNextFile`, which under hosted-runner load can lag well past the documented "~2s median" filesystem-visibility budget. The polling design (snapshot every 50ms via `readdir`) is structurally vulnerable to that latency.
- **Why this is OK to disable on Windows specifically:** the polling watcher is the *fallback* path on Windows — production traffic uses `ReadDirectoryChangesWatcher` (added in PR #88, file `Sources/Windows/WatcherKitWindows.swift`). The fallback's design is intentionally simple and slow; testing it under stringent timing on a runner whose filesystem semantics it's not optimized for produces noise without exercising real bugs. macOS + Linux still run the full live-FS suite, where the polling watcher is the production path.
- **What unblocks re-enabling:** either (a) provisioning a self-hosted Windows runner where filesystem visibility is stable enough to satisfy the original 5s budget reliably, or (b) factoring the polling-watcher tests so the budget is configurable per-platform with Windows getting a generous (~30s) headroom (acknowledging the test's actually testing the kernel + Foundation more than the watcher's own logic on that platform).
- **Diagnostic artifacts:** PR #87 CI run ([action 25601505900](https://github.com/billdenney/sprig/actions/runs/25601505900)) — `createDetected` failed with `events: []` after the 5s ceiling. Earlier flakes traced to the same shape on PRs #22, #23 (pre-write delay bump); PR #66 (event timeout bump 3s → 5s).
- **Disable PR:** `#88`
- **Owner:** maintainer + me (re-enable when the trigger condition above is met)

## Format

When adding an entry, use this shape:

```
### `<TestSuite>.<testName>` — disabled YYYY-MM-DD

- **Where:** `<file>:<line>`
- **Symptom:** what the failure mode looks like (hangs / crashes / wrong-result / env-missing)
- **Suspected root cause:** the working hypothesis when the disable was added.
- **What unblocks re-enabling:** the concrete signal we're waiting on (PR fix, dependency upgrade, runner change, ADR ratification…).
- **Diagnostic artifacts:** links to CI runs, watchdog uploads, sample stack traces — anything that helps the next reader skip our debugging steps.
- **Disable PR:** `#NNN` (the PR that added the disable, for blame trail).
- **Owner:** maintainer or contributor who'll drive the re-enable.
```

## Re-enabling protocol

Per `CLAUDE.md`, the fix-the-bug PR and the re-enable-the-test PR are **separate**. The fix lands first; the re-enable follows in the next PR with a one-line explanation citing the fix PR. That keeps revert windows independent: if the re-enable surfaces a different (or residual) flake, reverting just the re-enable doesn't re-introduce the original bug.

When re-enabling, the entry above gets removed from this file (not crossed out — it's not a public log; it's a working list).

## Historical context (closed disables, for reference)

Useful when triaging a similar future flake. Strict format is not required for the historical list — a one-line summary with PR links suffices.

- **`SprigctlWatchTests.macShortDurationExits`** — disabled 2026-04-26 (PR #12 / SprigctlSupport landing) attributed to "FSEvents hang on hosted macos-14"; re-enabled in PR `feat/reenable-fsevents-watch-test` (2026-04-30) after PR #16's stack-trace watchdog showed the actual root cause was `Process.waitUntilExit()` racing fast-exiting children, which PR #16 fixed via `GitCore.ProcessTerminationGate`.

## Why this file exists, not GitHub Issues

The full list of "what's CI-disabled right now" should be readable from a single `grep`-able file in the repo, not scattered across closed/open issues. CI-disabled tests are a coverage gap; we want every contributor (and every Claude session) to see the gap immediately on `ls docs/planning/`.

We also list these in `docs/planning/risk-register.md` when the disable represents a meaningful coverage risk; the risk register is the higher-level severity-graded view, while this file is the operational triage surface.
