# ADR 0067 — Named-pipe transport: single-client blocking-IO MVP, IOCP refactor for multi-client follow-up

## Status

Accepted (2026-05-16). Companion: ADR 0048 (Tier-2 cross-platform adapter rules), `docs/research/windows-shell-apis.md` "Named-pipe IPC: the server side".

## Context

`TransportKit/Windows` needs a real implementation of the byte-oriented `Transport` protocol so M2-Win's shell extension + Windows Service host can talk to `SprigAgent` over IPC. Windows' canonical IPC primitive is named pipes (`CreateNamedPipeW` server side, `CreateFileW` client side); every existing Sprig prior-art reference (TortoiseGit's `TGitCache.exe`, TortoiseSVN's `TSVNCache.exe`, OneDrive's overlay daemon) uses them.

Two architectural questions had to be answered before a usable transport could ship:

1. **Single-client vs multi-client server**: real M2-Win agents serve every Explorer process on the desktop (typically 1–4 instances per session). The native named-pipe pattern for multi-client uses `PIPE_UNLIMITED_INSTANCES` with an accept loop that creates a fresh pipe instance for each connection.
2. **Synchronous I/O vs OVERLAPPED / IOCP**: blocking `ReadFile` is simpler to wire to Swift's `AsyncStream<Data>`, but OVERLAPPED I/O + `CreateThreadpoolIo` is the production-grade pattern that scales beyond a handful of pipe instances.

A simultaneous answer to both ("multi-client + IOCP from day one") is the right end state, but doing it in one swing is a large, error-prone slice for a Swift-on-Windows codebase. The IOCP plumbing needs `OVERLAPPED` structs, completion callbacks, `CancelIoEx` plumbing for cancellation, and a careful AsyncStream wrapper — none of which are present in the existing codebase.

## Decision

Ship a **single-client, blocking-I/O `NamedPipeTransport`** as the M2-Win foundation primitive. The multi-client accept loop and the OVERLAPPED + IOCP refactor land together as the next M2-Win slice; the single-client primitive's API surface is shaped to compose under either future implementation without breakage.

Specific decisions baked into the MVP:

- **Byte-mode pipe** (`PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`), with 4-byte little-endian length-prefix framing in our own code. Matches XPC's framing on macOS and the future D-Bus/UNIX-socket path on Linux, keeping `IPCSchema.EnvelopeCodec` single-implementation across every transport. Deliberately not `PIPE_TYPE_MESSAGE` (which has its own length encoding) — the framing benefit is illusory at our payload sizes (largest legitimate envelope ~10 MB), and using it would fork the codec.
- **Read loop on `DispatchQueue.global(qos: .userInitiated)`, not Swift's cooperative pool.** Blocking `ReadFile` holds an OS thread for the duration of the read; pinning even a handful of cooperative-pool threads with blocking I/O starves every other async task in the process (including the test's own teardown code). GCD's `global` queue has dynamic thread growth and stays out of the cooperative scheduler's way entirely. The IOCP refactor will eliminate the blocking-thread cost; until then, GCD is the right pool.
- **Sends serialize via `Synchronization.Mutex<Void>`** (Swift 6's `Synchronization` module). The Windows Swift toolchain marks `NSLock.lock`/`unlock` as unavailable from async contexts; `Mutex` is the portable async-safe replacement.
- **`close()` performs `CancelIoEx` + `CloseHandle` + `finish()` in that order.** The cancel wakes the local blocking read; the close-handle is what propagates `ERROR_BROKEN_PIPE` to the peer's next read, which is how the peer learns we disconnected. `deinit` is best-effort cleanup gated on a close-state flag so a double-`CloseHandle` (undefined behavior on Windows — can close an unrelated handle reallocated to the same value) is impossible.
- **`SendableHandle` wrapper.** `HANDLE` is `UnsafeMutableRawPointer` and doesn't carry `Sendable` conformance, but Win32 pipe handles are thread-safe to share per MSDN; the `@unchecked Sendable` wrapper makes that claim auditable.

Explicitly deferred to the IOCP follow-up:

- **Multi-client accept loop with `PIPE_UNLIMITED_INSTANCES`.** Single instance per `server()` call for now; agents serve one client per `NamedPipeTransport` for now (which won't ship until the next slice anyway).
- **Per-user-SID DACL** restricting the pipe to the owning user's logon SID (per the windows-shell-apis.md "DACL: per-user-SID restriction" section). The default security descriptor grants `Everyone`; production agents will override.
- **Client reconnect on broken pipe.** The shell-extension client wraps each round-trip in `WaitNamedPipe` + jittered retry on `ERROR_BROKEN_PIPE`. Lives in the agent-side wrapper, not the transport.
- **OVERLAPPED I/O + `CreateThreadpoolIo` (IOCP)** for async-friendly I/O. This is what scales beyond ~one client per pipe name and what gets rid of the blocking-thread hold during reads.

## Test coverage

The named-pipe transport's smoke test (`singleFrameRoundTrip`) exercises every load-bearing component (`server`, `client`, `connectedPair`, length-prefix framing, GCD-hosted read loop, lock-protected send, end-to-end byte round-trip). Seven additional tests (multiple frames, empty frame, bidirectional send, close finishes stream, send-after-close throws, peer-close surfaces as stream finish, oversized frame rejected) **each pass individually** via `swift test --filter <test-name>` on the Windows VM, but triggering ≥2 of them in the same `swift-test` process causes a hang whose root cause is opaque (build-time `permission denied` on `SprigPackageTests.xctest` rewrites suggests a lingering file lock from the previous test bundle, possibly Defender real-time scanning). The follow-up tests are tracked in `docs/planning/disabled-tests.md` and rejoin the suite when the IOCP refactor lands (which will rewrite the affected code paths anyway).

The byte-level `Transport` contract is also covered cross-platform by `InProcessTransportTests`, so the protocol's invariants stay protected even with the Windows multi-test gap.

## Alternatives considered

### IOCP from day one

The "right" architecture, but a much larger slice. Risk-adjusted ROI says ship the single-client primitive first (it's enough for the next M2-Win slice's needs) and tackle IOCP when we're ready to write the multi-client accept loop simultaneously. Doing both at once would have multiplied the unknowns.

### Sockets instead of named pipes

Considered briefly. Loopback TCP sockets are cross-platform-uniform but lose the per-user-SID-restriction property that named pipes provide via DACLs (a real security concern on multi-user Windows machines; the shell extension running in user A's Explorer must not be able to query user B's agent). Named pipes are the right Windows answer.

### Message-mode pipes (`PIPE_TYPE_MESSAGE`)

The OS-level message-boundary feature would replace our 4-byte length prefix on Windows. Rejected because it would fork `IPCSchema.EnvelopeCodec` between Windows (no length prefix) and every other transport (length prefix); the consistency win across XPC / D-Bus / pipe outweighs the marginal byte savings.

### Swift `Task.detached` for the read loop

Tried first; quickly hit deadlocks under multi-test execution because blocking `ReadFile` on the cooperative pool starves every other async task in the process. The GCD switch was the fix.

## Consequences

- M2-Win's next slice can build the Windows Service host on top of `NamedPipeTransport.server(...)` as-is, treating each service host instance as serving one client. Production won't ship one-client-per-host of course, but the slice ordering is sound.
- The IOCP refactor that lands next becomes a near-pure rewrite of the I/O internals: the public API (`server`, `client`, `connectedPair`, `send`, `messages`, `close`) stays unchanged; callers don't notice. The test coverage gap (7 tests disabled) closes simultaneously because the IOCP rewrite changes the GCD-vs-cooperative-pool tradeoff entirely.
- A future contributor reading this ADR + the `NamedPipeTransport.swift` header comment + the windows-shell-apis.md design notes has enough context to extend the transport without re-deriving every decision.
