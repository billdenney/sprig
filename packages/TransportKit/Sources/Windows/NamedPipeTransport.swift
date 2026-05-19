// NamedPipeTransport.swift
//
// Windows named-pipe ``Transport`` implementation. Design rationale +
// alternatives considered: ADR 0067. Reference patterns:
// `docs/research/windows-shell-apis.md` "Named-pipe IPC: the server
// side".
//
// The agent runs as a Windows Service and hosts the server end
// (`CreateNamedPipeW`); each shell-extension / sprigctl client opens
// the client end (`CreateFileW`). Both ends speak the same byte-mode
// wire format the rest of Sprig's IPC uses: 4-byte little-endian
// length prefix followed by the JSON envelope body.
//
// Tier 2 platform impl. The Tier 1 `Transport` protocol is portable;
// only this file (+ companion files) is Windows-specific. Mac
// equivalent (XPC) lives in `Sources/Mac/TransportKitMac.swift`;
// Linux equivalent (D-Bus / UNIX socket) lands in `Sources/Linux/`
// when prioritized.
//
// File split (SwiftLint file_length / type_body caps):
// - `NamedPipeTransport.swift` (this file) -- class core, lifecycle,
//   send, messages, close, read loop.
// - `NamedPipeTransport+Factories.swift` -- public + test-helper
//   factories (`server`, `client`, `connectedPair`).
// - `NamedPipeIO.swift` -- internal value types + low-level
//   OVERLAPPED-read helpers (`SendableHandle`, `NamedPipeIO`).
//
// Design notes (see ADR 0067 for the full alternatives-considered):
// - **OVERLAPPED I/O on every read, write, and accept.** Synchronous
//   ReadFile cannot be cancelled by `CancelIoEx` (it's a no-op for
//   non-OVERLAPPED I/O), and relying on `CloseHandle` to unblock
//   pending I/O is documented as undefined behavior. With OVERLAPPED,
//   every blocking step is a `WaitForMultipleObjects` on
//   `[ioCompleteEvent, cancelEvent]`; ``close()`` signals
//   ``cancelEvent`` and the loop wakes deterministically.
// - **Byte mode** (`PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`), 4-byte LE
//   length prefix; matches the framing other transports use so
//   `IPCSchema.EnvelopeCodec` stays single-impl.
// - **`send(_:)` serializes concurrent writes** via `Mutex<Void>`
//   (Swift 6 `Synchronization`) -- `NSLock.lock` is `@unavailable`
//   from async on the Windows toolchain.
// - **``close()`` coordinates with the read loop** via a
//   ``readLoopExitedEvent`` (manual-reset): signal cancel, await the
//   loop's exit signal off the cooperative pool, then close all
//   handles. This makes close() deterministic and frees the loop's
//   GCD thread back to the pool.
//
// Multi-client server: `NamedPipeServer` (this directory) wraps this
// primitive in an accept loop and yields one `NamedPipeTransport` per
// connected client.
//
// Deliberately deferred (follow-up slices):
// - DACL: per-user-SID restriction (M2-Win hardening; ADR 0060).
// - Client reconnect on `ERROR_BROKEN_PIPE` (agent-side wrapper).
// - `CreateThreadpoolIo`-based async fan-out for the multi-client
//   server -- the GCD-thread-per-server-loop variant in
//   `NamedPipeServer` is right-sized for the agent's connection
//   count; the threadpool refactor is a perf slice that doesn't
//   change call-site code.

#if os(Windows)
    import Foundation
    import Synchronization

    // `@preconcurrency` treats Win32 types as Sendable-warnings rather
    // than errors. Necessary for `OVERLAPPED`, `HANDLE`, etc. which are
    // C types without Sendable conformance but documented as safe to
    // share across threads in their MSDN-defined usage.
    @preconcurrency import WinSDK

    /// Windows named-pipe ``Transport`` -- one endpoint, one peer.
    /// Construct via ``server(pipeName:)`` (agent side, waits for one
    /// client), ``client(pipeName:)`` (extension side, connects to an
    /// existing pipe), or ``connectedPair(pipeName:)`` (test helper
    /// that wires both ends inside one process). See the
    /// `+Factories` companion file.
    public final class NamedPipeTransport: Transport, @unchecked Sendable {
        /// Maximum frame size accepted from the peer. Bounds memory
        /// when a peer claims an absurd length prefix. 16 MB sits
        /// above the largest legitimate envelope (a 100k-file
        /// `badgeQuery` reply is ~10 MB at worst) and well under the
        /// address-space limits of a 64-bit process.
        public static let maxFrameSize: Int = 16 * 1024 * 1024

        let handle: HANDLE
        private let readCompleteEvent: HANDLE
        private let writeCompleteEvent: HANDLE
        private let cancelEvent: HANDLE
        private let readLoopExitedEvent: HANDLE

        private let inbound: AsyncStream<Data>
        private let inboundContinuation: AsyncStream<Data>.Continuation

        private let sendLock = Mutex<Void>(())
        private let closeState = Mutex<Bool>(false)

        // MARK: - Lifecycle

        init(handle: HANDLE) throws {
            self.handle = handle
            let events = try Self.makeEvents()
            readCompleteEvent = events[0]
            writeCompleteEvent = events[1]
            cancelEvent = events[2]
            readLoopExitedEvent = events[3]

            let (stream, continuation) = AsyncStream<Data>.makeStream()
            inbound = stream
            inboundContinuation = continuation

            startReadLoop()
        }

        deinit {
            // Best-effort cleanup if the caller dropped us without
            // calling `close()`. The closeState gate prevents
            // double-`CloseHandle` (undefined behavior on Windows).
            let alreadyClosed = closeState.withLock { $0 }
            if !alreadyClosed {
                SetEvent(cancelEvent)
                // Give the read loop ~1 s to exit before we close
                // the pipe handle; longer waits in deinit are unsafe.
                _ = WaitForSingleObject(readLoopExitedEvent, 1000)
                CloseHandle(handle)
            }
            CloseHandle(readCompleteEvent)
            CloseHandle(writeCompleteEvent)
            CloseHandle(cancelEvent)
            CloseHandle(readLoopExitedEvent)
        }

        /// Create the four manual-reset events the transport needs,
        /// in this order: read-complete, write-complete, cancel,
        /// read-loop-exited. Cleans up on partial failure -- a half-
        /// initialized transport is a leak hazard the public init
        /// wants to avoid.
        private static func makeEvents() throws -> [HANDLE] {
            var events: [HANDLE] = []
            events.reserveCapacity(4)
            for label in ["readComplete", "writeComplete", "cancel", "readLoopExited"] {
                guard let ev = CreateEventW(nil, true, false, nil) else {
                    let err = GetLastError()
                    for h in events {
                        CloseHandle(h)
                    }
                    throw TransportError.sendFailed(
                        reason: "CreateEventW(\(label)) failed: GetLastError=\(err)"
                    )
                }
                events.append(ev)
            }
            return events
        }

        // MARK: - Transport conformance

        public func send(_ data: Data) async throws {
            guard data.count <= Self.maxFrameSize else {
                throw TransportError.sendFailed(
                    reason: "send: frame size \(data.count) exceeds max \(Self.maxFrameSize)"
                )
            }
            try checkOpen()

            // Frame: 4-byte little-endian length + payload bytes.
            var lengthLE = UInt32(data.count).littleEndian
            let header = withUnsafeBytes(of: &lengthLE) { Data($0) }

            // Hold `sendLock` across both writes so concurrent sends
            // don't interleave (header from caller A then payload
            // from caller B).
            try sendLock.withLock { _ in
                try writeAll(header)
                try writeAll(data)
            }
        }

        public func messages() -> AsyncStream<Data> {
            inbound
        }

        public func close() async {
            let alreadyClosed = closeState.withLock { closed -> Bool in
                if closed { return true }
                closed = true
                return false
            }
            guard !alreadyClosed else { return }

            // Signal cancellation; the read loop sees the signal in
            // its `WaitForMultipleObjects` call, cancels its pending
            // I/O via `CancelIoEx` (works for OVERLAPPED), signals
            // `readLoopExitedEvent`, and returns.
            SetEvent(cancelEvent)
            inboundContinuation.finish()

            // Wait for the read loop to fully exit before closing
            // the pipe handle. Off the cooperative pool so we don't
            // block it.
            let pipeHandle = SendableHandle(raw: handle)
            let exitedEvent = SendableHandle(raw: readLoopExitedEvent)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    // 5 s ceiling so a buggy read loop can't deadlock
                    // close() forever; healthy path is microseconds.
                    _ = WaitForSingleObject(exitedEvent.raw, 5000)
                    CloseHandle(pipeHandle.raw)
                    cont.resume()
                }
            }
        }

        // MARK: - Internals

        private func checkOpen() throws {
            let alreadyClosed = closeState.withLock { $0 }
            if alreadyClosed { throw TransportError.closed }
        }

        /// Atomic OVERLAPPED write of `data`. Synchronous from the
        /// caller's perspective -- we wait for the completion event
        /// via `GetOverlappedResult(bWait: true)`. Send cancellation
        /// isn't supported (writes are typically fast; cancelling a
        /// half-written frame would leave the peer in a bad framing
        /// state anyway).
        private func writeAll(_ data: Data) throws {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                let total = data.count
                if total == 0 { return }
                var offset = 0
                while offset < total {
                    ResetEvent(writeCompleteEvent)
                    var overlapped = OVERLAPPED()
                    overlapped.hEvent = writeCompleteEvent
                    let remaining = DWORD(total - offset)
                    let immediate = WriteFile(
                        handle,
                        base.advanced(by: offset),
                        remaining,
                        nil,
                        &overlapped
                    )
                    if immediate == false {
                        let err = GetLastError()
                        if err == ERROR_BROKEN_PIPE || err == ERROR_NO_DATA {
                            throw TransportError.peerClosed
                        }
                        if err != ERROR_IO_PENDING {
                            throw TransportError.sendFailed(
                                reason: "WriteFile failed: GetLastError=\(err)"
                            )
                        }
                    }
                    var bytesWritten: DWORD = 0
                    let ok = GetOverlappedResult(handle, &overlapped, &bytesWritten, true)
                    if !ok {
                        let err = GetLastError()
                        if err == ERROR_BROKEN_PIPE || err == ERROR_NO_DATA {
                            throw TransportError.peerClosed
                        }
                        throw TransportError.sendFailed(
                            reason: "GetOverlappedResult(write) failed: GetLastError=\(err)"
                        )
                    }
                    offset += Int(bytesWritten)
                }
            }
        }

        /// Start the read loop on a GCD background queue. Uses the
        /// `NamedPipeIO.readExactlyOverlapped` helper which waits on
        /// `[readCompleteEvent, cancelEvent]` for each chunk, so
        /// ``close()`` signals `cancelEvent` and the loop wakes
        /// deterministically. Signals `readLoopExitedEvent` on exit
        /// so ``close()`` knows it's safe to close the pipe handle.
        private func startReadLoop() {
            let pipe = SendableHandle(raw: handle)
            let completeEv = SendableHandle(raw: readCompleteEvent)
            let cancelEv = SendableHandle(raw: cancelEvent)
            let exitedEv = SendableHandle(raw: readLoopExitedEvent)
            let continuation = inboundContinuation
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    continuation.finish()
                    SetEvent(exitedEv.raw)
                }
                while true {
                    guard let header = NamedPipeIO.readExactlyOverlapped(
                        handle: pipe.raw,
                        completeEvent: completeEv.raw,
                        cancelEvent: cancelEv.raw,
                        byteCount: 4
                    ) else { return }
                    // `loadUnaligned` for ARM64 Windows safety;
                    // explicit `UInt32(littleEndian:)` for byte-order
                    // intent (Windows is LE in practice).
                    let length = header.withUnsafeBytes { raw in
                        UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
                    }
                    if Int(length) > Self.maxFrameSize { return }
                    guard let payload = NamedPipeIO.readExactlyOverlapped(
                        handle: pipe.raw,
                        completeEvent: completeEv.raw,
                        cancelEvent: cancelEv.raw,
                        byteCount: Int(length)
                    ) else { return }
                    continuation.yield(payload)
                }
            }
        }
    }
#endif
