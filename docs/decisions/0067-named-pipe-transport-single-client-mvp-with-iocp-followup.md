# ADR 0067 — Named-pipe transport: OVERLAPPED single-client MVP, multi-client + `CreateThreadpoolIo` follow-up

## Status

Accepted (2026-05-16, amended in-PR after the synchronous-IO attempt deadlocked CI). Companion: ADR 0048 (Tier-2 cross-platform adapter rules), `docs/research/windows-shell-apis.md` "Named-pipe IPC: the server side".

## Context

`TransportKit/Windows` needs a real implementation of the byte-oriented `Transport` protocol so M2-Win's shell extension + Windows Service host can talk to `SprigAgent` over IPC. Windows' canonical IPC primitive is named pipes; every Sprig prior-art reference (TortoiseGit, TortoiseSVN, OneDrive) uses them.

Two architectural questions had to be answered before a usable transport could ship:

1. **Single-client vs multi-client server**: real M2-Win agents serve every Explorer process on the desktop (typically 1–4 instances per session). The native named-pipe pattern for multi-client uses `PIPE_UNLIMITED_INSTANCES` with an accept loop that creates a fresh pipe instance for each connection, typically with `CreateThreadpoolIo` for async fan-out.
2. **Synchronous I/O vs OVERLAPPED**: the initial attempt at this ADR was "synchronous I/O is simpler; ship that as the MVP, IOCP later." That decision was reversed *in-PR* (see "What changed and why" below) after the synchronous-I/O variant deadlocked hosted Windows CI: `CancelIoEx` is a documented no-op for non-OVERLAPPED I/O, and `CloseHandle` on a handle with pending blocking I/O is documented as undefined behavior. With those two cancellation mechanisms unavailable, the read loop's blocking `ReadFile` could not be deterministically terminated on `close()`. On hosted CI the race always tipped the wrong way; the loop never exited, GCD's pool eventually saturated, the entire test step hung.

## Decision

Ship a **single-client, OVERLAPPED-I/O `NamedPipeTransport`** as the M2-Win foundation primitive. The multi-client accept loop + `CreateThreadpoolIo`-based fan-out remain the next M2-Win slice; the single-client primitive's API surface is shaped to compose under that future wrapper without breakage.

Specific decisions baked into the MVP:

- **OVERLAPPED I/O on every read, write, and accept.** `CreateNamedPipeW` / `CreateFileW` use `FILE_FLAG_OVERLAPPED`. Every `ReadFile`, `WriteFile`, and `ConnectNamedPipe` carries an `OVERLAPPED` struct with a completion event. Reads wait on `WaitForMultipleObjects([readCompleteEvent, cancelEvent])`; `close()` signals `cancelEvent` and the read loop wakes deterministically, cancels its pending I/O via `CancelIoEx` (which **does** work for OVERLAPPED I/O), signals a `readLoopExitedEvent`, and exits. `close()` then waits for `readLoopExitedEvent` on a background GCD thread (so the cooperative pool isn't blocked) before closing the pipe handle. This eliminates every "undefined behavior" code path the synchronous variant relied on.
- **Byte-mode pipe** (`PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`), with 4-byte little-endian length-prefix framing in our own code. Matches XPC's framing on macOS and the future D-Bus/UNIX-socket path on Linux, keeping `IPCSchema.EnvelopeCodec` single-implementation across every transport. Deliberately not `PIPE_TYPE_MESSAGE` (which has its own length encoding) — the framing benefit is illusory at our payload sizes (largest legitimate envelope ~10 MB), and using it would fork the codec.
- **Read loop on `DispatchQueue.global(qos: .userInitiated)`.** Even with OVERLAPPED I/O, `WaitForMultipleObjects` is a blocking OS call; running it on GCD's `global` queue keeps Swift's cooperative pool free for other async work. GCD has dynamic thread growth + a much larger ceiling, so per-transport read loops don't compete with the cooperative scheduler.
- **Sends serialize via `Synchronization.Mutex<Void>`** (Swift 6's `Synchronization` module). The Windows Swift toolchain marks `NSLock.lock`/`unlock` as unavailable from async contexts; `Mutex` is the portable async-safe replacement.
- **`@preconcurrency import WinSDK`.** Win32 types like `OVERLAPPED`, `HANDLE`, etc. don't carry `Sendable` conformance. They're documented as thread-safe for their MSDN-defined usage; the `@preconcurrency` attribute downgrades the resulting Sendable-strictness errors to warnings, with explicit `SendableHandle` wrappers where we cross GCD boundaries to make the safety claim auditable.
- **`close()` blocks briefly waiting for the read loop to exit.** Bounded at 5 s so a buggy loop can't deadlock the caller forever; the healthy path is microseconds. Run on a background GCD thread so the cooperative pool stays unblocked while the wait happens.

Explicitly deferred to the multi-client follow-up:

- **Multi-client accept loop with `PIPE_UNLIMITED_INSTANCES`.** Single instance per `server()` call; the wrapper above this primitive will spawn one `NamedPipeTransport` per accepted client.
- **`CreateThreadpoolIo` fan-out.** This single-client MVP uses one GCD thread per transport, which is right-sized for the agent's connection count (1–4 Explorer instances per session) but doesn't scale to dozens. The multi-client wrapper introduces threadpool-based completion handling.
- **Per-user-SID DACL** restricting the pipe to the owning user's logon SID (per the windows-shell-apis.md "DACL: per-user-SID restriction" section). The default security descriptor grants `Everyone`; production agents will override.
- **Client reconnect on broken pipe.** Lives in the agent-side wrapper, not the transport.

## Test coverage

All 8 byte-level contract tests pass on the local Windows VM in 0.064 s when run together in one `swift-test` process: `singleFrameRoundTrip`, `multipleFramesPreserveFraming`, `emptyFrameRoundTrip`, `bidirectionalSend`, `closeFinishesStream`, `sendAfterCloseThrows`, `peerCloseSurfacesAsStreamFinish`, `oversizedFrameRejected`. The multi-test deadlock that motivated the in-PR refactor is gone. Coverage also rides on the cross-platform `InProcessTransportTests` for protocol-invariant checks that don't need a per-OS blocking-I/O surface.

## Alternatives considered

### Synchronous I/O + `CloseHandle`-to-cancel (the original MVP plan)

Tried first; deadlocked on the multi-test scenario locally and hung the entire hosted Windows CI step. The two mechanisms it relied on for cancellation are documented as either no-ops (`CancelIoEx` on non-OVERLAPPED handles) or undefined behavior (`CloseHandle` on handles with pending I/O). Recovered by refactoring to OVERLAPPED.

### Synchronous I/O + `CancelSynchronousIo` on the read thread's handle

`CancelSynchronousIo` cancels synchronous I/O on a *specific* thread, identified by a Win32 thread handle. Would require `OpenThread(GetCurrentThreadId(), …)` from inside the read loop to grab a self-handle, store it, and have `close()` retrieve it. Tried in-PR; hit Swift 6 strict-concurrency hurdles around `Mutex<HANDLE?>` and didn't yield clean results in the time available. OVERLAPPED is the cleaner end-state anyway and obsoletes this approach.

### Sockets instead of named pipes

Considered briefly. Loopback TCP sockets are cross-platform-uniform but lose the per-user-SID-restriction property that named pipes provide via DACLs (a real security concern on multi-user Windows machines; the shell extension running in user A's Explorer must not be able to query user B's agent). Named pipes are the right Windows answer.

### Message-mode pipes (`PIPE_TYPE_MESSAGE`)

The OS-level message-boundary feature would replace our 4-byte length prefix on Windows. Rejected because it would fork `IPCSchema.EnvelopeCodec` between Windows (no length prefix) and every other transport (length prefix); the consistency win across XPC / D-Bus / pipe outweighs the marginal byte savings.

## Consequences

- M2-Win's next slice (the Windows Service host) can build on top of `NamedPipeTransport.server(...)` as-is, treating each service host instance as serving one client.
- The multi-client wrapper is a pure additive layer above this primitive — no internal rewrite required. `CreateThreadpoolIo` slots into the wrapper, not the primitive.
- A future contributor reading this ADR + the `NamedPipeTransport.swift` header comment + the windows-shell-apis.md design notes has enough context to extend the transport without re-deriving every decision.

## What changed and why (in-PR amendment, 2026-05-19)

The original draft of this ADR (committed earlier in PR #111) accepted "ship synchronous I/O first; do IOCP later." That decision was reversed mid-PR after hosted Windows CI hung for over an hour on the synchronous variant's `Run tests` step — the cancellation mechanisms it relied on were documented as no-ops / undefined behavior, and CI environment differences (Defender holds, scheduler quirks, parallel-test load) tipped the race against us reliably. The OVERLAPPED refactor landed within the same PR; the ADR was rewritten to match. The original "blocking-IO + IOCP-later" framing is preserved above under "Alternatives considered" so the failed approach is documented for future contributors.
