// NamedPipeServer.swift
//
// Multi-client named-pipe server. The agent (Windows Service) hosts
// this; each shell-extension instance / sprigctl invocation opens a
// client via `NamedPipeTransport.client(pipeName:)`. Every accepted
// connection becomes a `NamedPipeTransport` yielded on
// ``connections``.
//
// Design (see ADR 0067):
// - **One accept thread.** A single GCD task runs the accept loop:
//   create one pipe instance with `PIPE_UNLIMITED_INSTANCES`, await
//   `ConnectNamedPipe` via `NamedPipeIO.acceptClient(...)`, hand the
//   connected handle off to a `NamedPipeTransport`, and loop. The
//   `CreateThreadpoolIo`-based fan-out variant lives behind the same
//   public API; swapping it in is a follow-up slice that doesn't
//   change call-site code.
// - **Cancel-deterministic close.** ``close()`` signals
//   ``cancelEvent``; the accept thread's `WaitForMultipleObjects` call
//   inside `acceptClient(...)` returns immediately with
//   ``NamedPipeIO/AcceptOutcome/cancelled``, the loop exits, and
//   ``readLoopExitedEvent``'s server-side analogue
//   (``exitedEvent``) is signaled so ``close()`` can return.
// - **One event reused across iterations.** ``acceptCompleteEvent`` is
//   manual-reset; `acceptClient` `ResetEvent`s it on each call. This
//   beats creating + closing a new event per client.
// - **Connections-stream completion.** When the accept loop exits
//   (cancelled, fatal failure, or pipe instance creation failure), the
//   ``connections`` `AsyncStream` finishes. Consumers terminate their
//   `for await` loops naturally.
//
// Out of scope (deliberately, for this slice):
// - DACL / peer-SID validation on accept. The default security
//   descriptor accepts any process on the local machine; agent-side
//   `IPCSchema` handshake will reject mis-signed clients. Tighter
//   per-SID restrictions are the M2-Win hardening slice (ADR 0060).
// - Concurrent listening instances. A future refactor can pre-arm N
//   instances so concurrent clients connect without serializing on
//   the one-at-a-time accept thread; the current shape is fine for
//   the agent's expected fan-in (single-digit shell extensions).

#if os(Windows)
    import Foundation
    import Synchronization
    // `@preconcurrency` quiets Sendable warnings on Win32 C types;
    // see `NamedPipeTransport.swift` for the same rationale.
    @preconcurrency import WinSDK

    /// Hosts a Windows named pipe and yields each accepted client
    /// connection as a `NamedPipeTransport`.
    ///
    /// Construct once per agent; iterate ``connections`` in a `Task`
    /// to receive new clients; call ``close()`` to stop accepting and
    /// release the server.
    public final class NamedPipeServer: @unchecked Sendable {
        /// Stream of accepted transport endpoints. One element per
        /// successful `ConnectNamedPipe`; finishes when ``close()`` is
        /// called or the accept loop hits an unrecoverable failure.
        public let connections: AsyncStream<NamedPipeTransport>
        private let connectionsContinuation: AsyncStream<NamedPipeTransport>.Continuation

        /// Canonical `\\.\pipe\<name>` form used by every
        /// `CreateNamedPipeW` call in the accept loop.
        private let canonicalName: String

        private let acceptCompleteEvent: HANDLE
        private let cancelEvent: HANDLE
        private let exitedEvent: HANDLE

        private let closeState = Mutex<Bool>(false)

        // MARK: - Lifecycle

        /// Spin up the accept loop on a background GCD queue and
        /// start listening for clients on `pipeName`.
        ///
        /// **Synchronous "ready" semantics.** Init creates the FIRST
        /// pipe instance via `CreateNamedPipeW` *before* returning, so
        /// by the time the caller has a `NamedPipeServer` in hand, a
        /// client's `CreateFileW(\\.\pipe\<name>, ...)` is guaranteed
        /// to succeed (no `ERROR_FILE_NOT_FOUND` race against a not-
        /// yet-started accept loop). Subsequent instances are created
        /// by the accept loop after each client is yielded.
        ///
        /// - Parameter pipeName: Either the bare name (e.g.
        ///   `sprig-agent-foo`) or the full `\\.\pipe\sprig-agent-foo`
        ///   form. `NamedPipeIO.canonicalPipePath` normalizes the
        ///   former into the latter.
        /// - Throws: ``TransportError/sendFailed`` if any of the
        ///   internal `CreateEventW` calls fail or the first
        ///   `CreateNamedPipeW` fails. Successful init means the pipe
        ///   exists and the accept loop is running.
        public init(pipeName: String) throws {
            canonicalName = NamedPipeIO.canonicalPipePath(pipeName)

            let events = try Self.makeEvents()
            acceptCompleteEvent = events[0]
            cancelEvent = events[1]
            exitedEvent = events[2]

            // Pre-create the first instance so the pipe exists by the
            // time the constructor returns. Clean up events on failure
            // to avoid a half-initialized leak.
            guard let firstInstance = Self.makeInstance(name: canonicalName) else {
                let err = GetLastError()
                for h in events { CloseHandle(h) }
                throw TransportError.sendFailed(
                    reason: "CreateNamedPipeW(\(canonicalName)) failed: GetLastError=\(err)"
                )
            }

            let (stream, continuation) = AsyncStream<NamedPipeTransport>.makeStream()
            connections = stream
            connectionsContinuation = continuation

            startAcceptLoop(firstInstance: firstInstance)
        }

        deinit {
            // Best-effort cleanup if the caller dropped us without
            // calling `close()`. Mirror the NamedPipeTransport
            // deinit pattern.
            let alreadyClosed = closeState.withLock { $0 }
            if !alreadyClosed {
                SetEvent(cancelEvent)
                // Bounded wait so a runaway accept loop can't hang
                // deinit forever.
                _ = WaitForSingleObject(exitedEvent, 1000)
            }
            CloseHandle(acceptCompleteEvent)
            CloseHandle(cancelEvent)
            CloseHandle(exitedEvent)
        }

        /// Stop accepting new clients and tear down the server.
        ///
        /// Already-yielded `NamedPipeTransport` instances are NOT
        /// closed by this call -- they belong to the consumer of
        /// ``connections`` and are closed by that consumer when its
        /// per-client session ends. Calling ``close()`` is idempotent;
        /// repeated calls return immediately.
        public func close() async {
            let alreadyClosed = closeState.withLock { closed -> Bool in
                if closed { return true }
                closed = true
                return false
            }
            guard !alreadyClosed else { return }

            SetEvent(cancelEvent)
            connectionsContinuation.finish()

            // Wait for the accept loop to fully exit off the
            // cooperative pool. 5 s ceiling matches NamedPipeTransport.
            let exited = SendableHandle(raw: exitedEvent)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = WaitForSingleObject(exited.raw, 5000)
                    cont.resume()
                }
            }
        }

        // MARK: - Internals

        /// Create the three manual-reset events the server needs.
        /// Cleans up on partial failure so a half-initialized server
        /// doesn't leak event handles.
        private static func makeEvents() throws -> [HANDLE] {
            var events: [HANDLE] = []
            events.reserveCapacity(3)
            for label in ["acceptComplete", "cancel", "exited"] {
                guard let ev = CreateEventW(nil, true, false, nil) else {
                    let err = GetLastError()
                    for h in events { CloseHandle(h) }
                    throw TransportError.sendFailed(
                        reason: "CreateEventW(\(label)) failed: GetLastError=\(err)"
                    )
                }
                events.append(ev)
            }
            return events
        }

        /// Create the next pipe instance to accept a client on. Uses
        /// `PIPE_UNLIMITED_INSTANCES` so multiple instances of the same
        /// pipe name can coexist if a future refactor pre-arms several
        /// accept waits in parallel.
        private static func makeInstance(name: String) -> HANDLE? {
            let handle = name.withCString(encodedAs: UTF16.self) { wide in
                CreateNamedPipeW(
                    wide,
                    DWORD(PIPE_ACCESS_DUPLEX) | DWORD(FILE_FLAG_OVERLAPPED),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    DWORD(PIPE_UNLIMITED_INSTANCES),
                    DWORD(NamedPipeIO.bufferSize),
                    DWORD(NamedPipeIO.bufferSize),
                    0, // default timeout (only used by WaitNamedPipe)
                    nil // default security descriptor; per-SID DACL is
                    //    the M2-Win hardening slice (ADR 0060)
                )
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
            return handle
        }

        /// Launch the accept loop on a background GCD queue and
        /// detach. The loop owns its thread until ``close()`` cancels.
        /// Takes ownership of `firstInstance` (the pipe instance the
        /// init function pre-created so callers can connect without
        /// racing).
        private func startAcceptLoop(firstInstance: HANDLE) {
            let name = canonicalName
            let firstInst = SendableHandle(raw: firstInstance)
            let acceptEv = SendableHandle(raw: acceptCompleteEvent)
            let cancelEv = SendableHandle(raw: cancelEvent)
            let exitedEv = SendableHandle(raw: exitedEvent)
            let continuation = connectionsContinuation

            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    continuation.finish()
                    SetEvent(exitedEv.raw)
                }
                Self.acceptLoop(
                    name: name,
                    firstInstance: firstInst.raw,
                    acceptEvent: acceptEv.raw,
                    cancelEvent: cancelEv.raw,
                    continuation: continuation
                )
            }
        }

        /// Inner accept loop. Factored out of `startAcceptLoop` so the
        /// closure stays under SwiftLint's function-length cap. Runs
        /// until cancel is signaled or instance creation fails.
        ///
        /// First iteration uses `firstInstance` (pre-created by init
        /// so callers can connect without racing the GCD startup).
        /// Subsequent iterations create their own instance via
        /// `makeInstance(name:)` — note that there's still a small
        /// window between yielding a connected transport and the next
        /// `CreateNamedPipeW` call during which new clients see
        /// `ERROR_FILE_NOT_FOUND`; the `CreateThreadpoolIo` follow-up
        /// (ADR 0067) closes that window with pre-armed instances.
        private static func acceptLoop(
            name: String,
            firstInstance: HANDLE,
            acceptEvent: HANDLE,
            cancelEvent: HANDLE,
            continuation: AsyncStream<NamedPipeTransport>.Continuation
        ) {
            var currentInstance: HANDLE? = firstInstance
            while true {
                let instance: HANDLE
                if let prearmed = currentInstance {
                    instance = prearmed
                    currentInstance = nil
                } else {
                    guard let next = makeInstance(name: name) else {
                        // `CreateNamedPipeW` failed; nothing this loop
                        // can do to recover. Surface as accept-loop
                        // exit.
                        return
                    }
                    instance = next
                }
                let outcome = NamedPipeIO.acceptClient(
                    on: instance,
                    completeEvent: acceptEvent,
                    cancelEvent: cancelEvent
                )
                switch outcome {
                case .connected:
                    // Hand the connected handle to a Transport. If the
                    // Transport's init throws (event-creation failure,
                    // very rare), close the pipe handle to signal
                    // disconnect to the client and continue listening.
                    if let transport = try? NamedPipeTransport(handle: instance) {
                        continuation.yield(transport)
                    } else {
                        CloseHandle(instance)
                    }
                case .cancelled:
                    CloseHandle(instance)
                    return
                case .failed:
                    CloseHandle(instance)
                    return
                }
            }
        }
    }
#endif
