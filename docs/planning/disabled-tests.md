# Disabled CI tests — tracking surface

The list of tests currently disabled on CI, why, and what unblocks re-enabling. Per `CLAUDE.md` "Disabled CI tests must be tracked and re-enabled ASAP," every disabled test must appear here within the same PR that disables it. Re-enabling happens in a follow-up PR as soon as the underlying issue is fixed.

## Currently disabled

### `NamedPipeTransportTests` (multi-test coverage) — limited to 1 of 8 tests on Windows, 2026-05-16

- **Where:** `packages/TransportKit/Tests/TransportKitTests/NamedPipeTransportTests.swift`. The suite contains only the smoke test `singleFrameRoundTrip`. Seven additional tests covering `multipleFramesPreserveFraming`, `emptyFrameRoundTrip`, `bidirectionalSend`, `closeFinishesStream`, `sendAfterCloseThrows`, `peerCloseSurfacesAsStreamFinish`, and `oversizedFrameRejected` were verified passing **individually** during the introducing PR (via `swift test --filter <test-name>`) but are omitted from the source until the multi-test-hang root cause is fixed.
- **Symptom:** when two or more `NamedPipeTransport` tests run inside the same `swift-test` process, the second test gets stuck before printing its `◊ Test started` marker. The next `swift-test` invocation can't rebuild `SprigPackageTests.xctest` (link fails with `permission denied`), suggesting a lingering process / file lock from the prior bundle.
- **Suspected root cause:** between-test cleanup of `NamedPipeTransport` instances leaves some Windows-side resource (pipe handle, GCD-queued read loop, or the `SprigPackageTests.xctest` image itself) blocked. Tracing through SSH didn't surface the actual stuck call. The hang reproduces deterministically on the local dockur/windows VM; not specific to hosted-CI load.
- **What's been tried** (none fixed the multi-test hang):
  - swift-testing `.serialized` suite trait
  - `--no-parallel` swift-test flag
  - Moving `ReadFile` / `ConnectNamedPipe` off the Swift cooperative pool onto `DispatchQueue.global(qos: .userInitiated)` to keep blocking I/O off the cooperative scheduler
  - Replacing `defer { Task { close() } }` with a `withConnectedPair` helper that closes both ends synchronously before returning
  - `CancelIoEx` + `CloseHandle` in `close()` so the peer's `ReadFile` returns `ERROR_BROKEN_PIPE`
  - Killing all `Sprig*` / `swift*` / `clang*` / `lld*` processes between runs and removing the locked `.xctest` file
  - Restarting the dockur/windows container
  - Timeouts up to 8 minutes
- **What unblocks re-enabling:** the proper long-term fix is OVERLAPPED I/O + `CreateThreadpoolIo` (an IOCP-based async transport) -- documented in `docs/research/windows-shell-apis.md` as the production pattern. That refactor is also required by the multi-client server (the next M2-Win slice), so the re-enables ride along with it.
- **Why this is OK to limit on Windows for now:** production use is one `NamedPipeTransport` per agent connection, lived for the agent's lifetime. The multi-instance test scenario doesn't reflect real production usage. The byte-level Transport contract is also covered on every platform by `InProcessTransport` tests (`InProcessTransportTests.swift`), which exercise the protocol's invariants without per-OS blocking I/O. The retained smoke test exercises every load-bearing component (`server`, `client`, `connectedPair`, length-prefix framing, GCD-hosted read loop, lock-protected send, end-to-end byte round-trip), so a structural regression to the production code still fails CI.
- **Disable PR:** `feat/transportkit-windows-namedpipe`.
- **Owner:** me (re-enable when the IOCP-based variant lands).

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

## Why this file exists, not GitHub Issues

The full list of "what's CI-disabled right now" should be readable from a single `grep`-able file in the repo, not scattered across closed/open issues. CI-disabled tests are a coverage gap; we want every contributor (and every Claude session) to see the gap immediately on `ls docs/planning/`.

We also list these in `docs/planning/risk-register.md` when the disable represents a meaningful coverage risk; the risk register is the higher-level severity-graded view, while this file is the operational triage surface.
