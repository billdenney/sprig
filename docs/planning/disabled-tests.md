# Disabled CI tests — tracking surface

The list of tests currently disabled on CI, why, and what unblocks re-enabling. Per `CLAUDE.md` "Disabled CI tests must be tracked and re-enabled ASAP," every disabled test must appear here within the same PR that disables it. Re-enabling happens in a follow-up PR as soon as the underlying issue is fixed.

## Currently disabled

_(none)_

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
- **`PollingFileWatcherRealFSTests` (Windows)** — disabled 2026-05-09 (PR #88) because Windows hosted-runner `FindFirstFile` lag exceeded the suite's 5 s budget. Re-enabled 2026-05-16 in PR `ci/reenable-pollingwatcher-windows-budgets` by making `preWriteDelayNs` and `eventTimeoutSec` platform-conditional (Windows: 2.5 s / 30 s; macOS + Linux: 500 ms / 5 s). Verified locally on a Windows Server 2022 dockur/windows VM matching the GitHub Actions `windows-2022` runner image; suite passes 11/11 in 2.6 s on Windows, 0.5 s on Linux (no regression).
- **`NamedPipeTransportTests` (all 8 tests)** — disabled briefly 2026-05-16 within PR #111 because the synchronous-`ReadFile`-based read loop couldn't be cancelled on `close()` (the `CancelIoEx` call was a no-op for non-OVERLAPPED I/O; relying on `CloseHandle` to unblock pending `ReadFile` is documented as undefined behavior, and on hosted Windows CI the race always tipped the wrong way). Re-enabled later in PR #111 by refactoring the transport to use OVERLAPPED I/O end-to-end: `CreateNamedPipeW`/`CreateFileW` with `FILE_FLAG_OVERLAPPED`, `ConnectNamedPipe`/`ReadFile`/`WriteFile` with `OVERLAPPED` structs + completion events, `close()` signals a dedicated `cancelEvent` that the read loop waits on alongside the read completion event via `WaitForMultipleObjects`. Verified locally on the dockur/windows VM: 8/8 tests pass in 0.064 s when run in one swift-test process (the multi-test deadlock that motivated the disable is gone).

## Why this file exists, not GitHub Issues

The full list of "what's CI-disabled right now" should be readable from a single `grep`-able file in the repo, not scattered across closed/open issues. CI-disabled tests are a coverage gap; we want every contributor (and every Claude session) to see the gap immediately on `ls docs/planning/`.

We also list these in `docs/planning/risk-register.md` when the disable represents a meaningful coverage risk; the risk register is the higher-level severity-graded view, while this file is the operational triage surface.
