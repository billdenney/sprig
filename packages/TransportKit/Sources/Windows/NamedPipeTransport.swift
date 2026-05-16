// NamedPipeTransport.swift
//
// Windows named-pipe ``Transport`` implementation. The agent runs as
// a Windows Service and hosts the server end (`CreateNamedPipeW`);
// each shell-extension / sprigctl client opens the client end
// (`CreateFileW`). Both ends speak the same byte-mode wire format
// the rest of Sprig's IPC uses: 4-byte little-endian length prefix
// followed by the JSON envelope body.
//
// Tier 2 platform impl. The Tier 1 `Transport` protocol is portable;
// only this file is Windows-specific. Mac equivalent (XPC) lives in
// `Sources/Mac/TransportKitMac.swift`; Linux equivalent (D-Bus /
// UNIX socket) lands in `Sources/Linux/` when prioritized.
//
// Design notes:
// - Byte mode (`PIPE_TYPE_BYTE | PIPE_READMODE_BYTE`), 4-byte LE
//   length prefix; matches the framing other transports use so
//   `IPCSchema.EnvelopeCodec` stays single-impl.
// - Read loop runs on `DispatchQueue.global(qos:)`, NOT Swift's
//   cooperative pool: blocking `ReadFile` would starve the cooperative
//   pool if multiple transports were active. See `startReadLoop` for
//   the full rationale.
// - `send(_:)` serializes concurrent writes via `Mutex<Void>` (Swift 6
//   `Synchronization`) -- `NSLock.lock` is `@unavailable` from async
//   on the Windows toolchain.
// - `close()` runs `CancelIoEx` + `CloseHandle`. Cancelling the I/O
//   wakes the read loop locally; closing the handle is what makes the
//   PEER's next `ReadFile` see `ERROR_BROKEN_PIPE` (peer-close
//   propagation).
//
// Deliberately deferred (follow-up slices):
// - Multi-client server (the agent's accept loop wraps this primitive).
// - DACL: per-user-SID restriction (production agent must override
//   the default `Everyone` SD -- see `docs/research/windows-shell-apis.md`).
// - Client reconnect on `ERROR_BROKEN_PIPE` (agent-side wrapper).
// - OVERLAPPED I/O + `CreateThreadpoolIo` for async-friendly reads
//   (the IOCP refactor; also what the multi-client server needs).

#if os(Windows)
    import Foundation
    import Synchronization
    import WinSDK

    /// Sendable wrapper for `HANDLE` (`UnsafeMutableRawPointer`),
    /// which doesn't carry `Sendable` conformance. The Win32 pipe
    /// handle is process-local + thread-safe to use across threads
    /// per MSDN, so passing it into GCD closures via this wrapper is
    /// safe in practice even though the compiler can't prove it.
    private struct SendableHandle: @unchecked Sendable {
        let raw: HANDLE
    }

    /// Windows named-pipe ``Transport`` -- one endpoint, one peer.
    /// Construct via ``server(pipeName:)`` (agent side, waits for one
    /// client) or ``client(pipeName:)`` (extension side, connects to
    /// an existing pipe). ``connectedPair(pipeName:)`` is the test
    /// helper that wires both ends inside one process.
    public final class NamedPipeTransport: Transport, @unchecked Sendable {
        /// Maximum frame size accepted from the peer. Bounds memory
        /// when a peer claims an absurd length prefix. 16 MB sits
        /// above the largest legitimate envelope (a 100k-file
        /// `badgeQuery` reply is ~10 MB at worst) and well under the
        /// address-space limits of a 64-bit process.
        public static let maxFrameSize: Int = 16 * 1024 * 1024

        /// Win32 handle to the open pipe. Owned; closed in
        /// ``close()`` and finalized in `deinit`.
        private let handle: HANDLE

        private let inbound: AsyncStream<Data>
        private let inboundContinuation: AsyncStream<Data>.Continuation

        /// Serializes concurrent ``send(_:)`` calls so frame bytes
        /// don't interleave on the wire. `Mutex` (Swift 6
        /// `Synchronization` module) is the portable async-safe
        /// alternative to `NSLock` -- Windows Swift toolchain marks
        /// `NSLock.lock`/`unlock` unavailable from async contexts.
        private let sendLock = Mutex<Void>(())

        /// Latched once ``close()`` runs (or the read loop discovers
        /// the peer closed). Reads/writes after this throw
        /// ``TransportError/closed``.
        private let closeState = Mutex<Bool>(false)

        // MARK: - Lifecycle

        private init(handle: HANDLE) {
            self.handle = handle
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            inbound = stream
            inboundContinuation = continuation
            startReadLoop()
        }

        deinit {
            // Best-effort cleanup; `close()` is the intended path.
            // The closeState gate prevents double-`CloseHandle`
            // (undefined behavior on Windows -- can close an unrelated
            // handle reallocated to the same value).
            let alreadyClosed = closeState.withLock { $0 }
            if !alreadyClosed {
                CloseHandle(handle)
            }
        }

        // MARK: - Factories

        /// Create the server end of a named pipe and wait for a single
        /// client to connect. The pipe is created at
        /// `\\.\pipe\<pipeName>` and stays alive for one client; for
        /// multi-client serving, wrap an accept loop around this.
        ///
        /// Throws ``TransportError/sendFailed`` carrying the Win32
        /// error code if `CreateNamedPipeW` or `ConnectNamedPipe`
        /// fails.
        public static func server(pipeName: String) async throws -> NamedPipeTransport {
            let fullName = canonicalPipePath(pipeName)
            let handle = fullName.withCString(encodedAs: UTF16.self) { wide in
                CreateNamedPipeW(
                    wide,
                    DWORD(PIPE_ACCESS_DUPLEX),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    1, // single instance for this MVP; multi-client wrapper above
                    DWORD(bufferSize),
                    DWORD(bufferSize),
                    0, // default timeout (used only by WaitNamedPipe)
                    nil // default security descriptor -- production
                    //     agent overrides with a SID-restricted DACL
                )
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                throw TransportError.sendFailed(
                    reason: "CreateNamedPipeW(\(fullName)) failed: GetLastError=\(GetLastError())"
                )
            }

            // Wait for the client. `ConnectNamedPipe` with a NULL
            // OVERLAPPED blocks the calling thread; we run it on
            // GCD's global queue rather than the Swift cooperative
            // pool so the cooperative pool stays free for other
            // async work (see the rationale on `startReadLoop` for
            // why blocking I/O on the cooperative pool is a deadlock
            // hazard). `ERROR_PIPE_CONNECTED` means the client beat
            // us to the connect call -- still success. Cooperative
            // cancellation isn't wired through; a caller that cancels
            // during accept leaks the pipe instance until a peer
            // attempts to connect or the process exits. Adding proper
            // cancellation requires OVERLAPPED + IOCP, which lands
            // with the multi-client server in a follow-up.
            let sendable = SendableHandle(raw: handle)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if ConnectNamedPipe(sendable.raw, nil) == false {
                        let err = GetLastError()
                        if err != ERROR_PIPE_CONNECTED {
                            CloseHandle(sendable.raw)
                            cont.resume(throwing: TransportError.sendFailed(
                                reason: "ConnectNamedPipe failed: GetLastError=\(err)"
                            ))
                            return
                        }
                    }
                    cont.resume()
                }
            }

            return NamedPipeTransport(handle: handle)
        }

        /// Connect to an existing named pipe as a client. The pipe at
        /// `\\.\pipe\<pipeName>` must already exist (i.e. some other
        /// process has called ``server(pipeName:)`` or equivalent).
        ///
        /// Throws ``TransportError/sendFailed`` if `CreateFileW`
        /// fails -- usual case is `ERROR_FILE_NOT_FOUND` (no server)
        /// or `ERROR_PIPE_BUSY` (server saturated; caller should
        /// `WaitNamedPipe` + retry).
        public static func client(pipeName: String) async throws -> NamedPipeTransport {
            let fullName = canonicalPipePath(pipeName)
            let handle = fullName.withCString(encodedAs: UTF16.self) { wide in
                CreateFileW(
                    wide,
                    DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                    0, // no sharing -- one client per server instance
                    nil,
                    DWORD(OPEN_EXISTING),
                    0, // synchronous I/O; future async variant goes here
                    nil
                )
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else {
                throw TransportError.sendFailed(
                    reason: "CreateFileW(\(fullName)) failed: GetLastError=\(GetLastError())"
                )
            }
            return NamedPipeTransport(handle: handle)
        }

        /// Test convenience: spin up a server end, connect a client
        /// end to it, return both wired together. Uses a UUID-suffixed
        /// pipe name so concurrent test runs don't collide.
        public static func connectedPair(
            pipeName: String = "sprig-test-\(UUID().uuidString)"
        ) async throws -> (server: NamedPipeTransport, client: NamedPipeTransport) {
            async let serverEnd = server(pipeName: pipeName)
            // Tiny delay so the server's ConnectNamedPipe call is
            // posted before the client's CreateFileW races in. Without
            // it, the client occasionally beats the server's
            // CreateNamedPipeW and gets ERROR_FILE_NOT_FOUND.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let clientEnd = try await client(pipeName: pipeName)
            return try await (serverEnd, clientEnd)
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

            // Hold `sendLock` across both writeAll calls so concurrent
            // sends don't interleave (header from caller A followed by
            // payload from caller B). `Mutex.withLock` rethrows so the
            // `writeAll` errors surface unchanged.
            try sendLock.withLock { _ in
                try writeAll(header)
                try writeAll(data)
            }
        }

        public func messages() -> AsyncStream<Data> {
            inbound
        }

        public func close() async {
            // Atomically transition isClosed false → true; bail if
            // already closed (idempotent per protocol contract).
            let alreadyClosed = closeState.withLock { closed -> Bool in
                if closed { return true }
                closed = true
                return false
            }
            guard !alreadyClosed else { return }

            // Order matters:
            //   1. CancelIoEx wakes the read loop's blocking ReadFile.
            //   2. CloseHandle releases the OS pipe handle so the
            //      PEER's next ReadFile sees ERROR_BROKEN_PIPE -- this
            //      is what propagates the close signal across the wire
            //      (a peer with no other way to know our intent).
            //   3. finish() the local inbound continuation so the
            //      local iterator sees the stream end.
            // The closeState flag we just set tells deinit not to
            // double-close the handle.
            CancelIoEx(handle, nil)
            CloseHandle(handle)
            inboundContinuation.finish()
        }

        // MARK: - Internals

        private func checkOpen() throws {
            let alreadyClosed = closeState.withLock { $0 }
            if alreadyClosed { throw TransportError.closed }
        }

        /// Blocking write of every byte; loops on partial writes
        /// (rare for named pipes but documented as possible).
        private func writeAll(_ data: Data) throws {
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                var offset = 0
                let total = data.count
                while offset < total {
                    var written: DWORD = 0
                    let remaining = DWORD(total - offset)
                    let ok = WriteFile(
                        handle,
                        base.advanced(by: offset),
                        remaining,
                        &written,
                        nil
                    )
                    if !ok {
                        let err = GetLastError()
                        if err == ERROR_BROKEN_PIPE || err == ERROR_NO_DATA {
                            throw TransportError.peerClosed
                        }
                        throw TransportError.sendFailed(
                            reason: "WriteFile failed: GetLastError=\(err)"
                        )
                    }
                    offset += Int(written)
                }
            }
        }

        /// Start the read loop on a GCD background queue (NOT Swift's
        /// cooperative pool: blocking `ReadFile` would pin a pool
        /// thread, and a few such transports could starve every other
        /// async task in the process -- including test cleanup. GCD's
        /// `global` queue has dynamic thread growth, so blocking I/O
        /// stays off the cooperative scheduler entirely). The IOCP
        /// refactor with `CreateThreadpoolIo` is the production-grade
        /// successor that lands with the multi-client server.
        private func startReadLoop() {
            let sendable = SendableHandle(raw: handle)
            let continuation = inboundContinuation
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    guard let header = try? Self.readExactly(handle: sendable.raw, byteCount: 4) else {
                        continuation.finish()
                        return
                    }
                    // `loadUnaligned` is required on ARM64 Windows
                    // (a 4-byte read from an arbitrary `Data` offset
                    // isn't guaranteed aligned). Explicit
                    // `UInt32(littleEndian:)` states the byte-order
                    // intent (Windows is LE in practice).
                    let length = header.withUnsafeBytes { raw in
                        UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
                    }
                    if Int(length) > Self.maxFrameSize {
                        continuation.finish()
                        return
                    }
                    guard let payload = try? Self.readExactly(
                        handle: sendable.raw,
                        byteCount: Int(length)
                    ) else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(payload)
                }
            }
        }

        /// Read exactly `byteCount` bytes from `handle`, looping over
        /// partial reads (named pipes don't guarantee atomicity in
        /// byte mode). Returns nil on peer-closed / cancelled.
        private static func readExactly(handle: HANDLE, byteCount: Int) throws -> Data? {
            if byteCount == 0 { return Data() }
            var buffer = Data(count: byteCount)
            let ok: Bool = buffer.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) -> Bool in
                guard let base = rawBuf.baseAddress else { return false }
                var offset = 0
                while offset < byteCount {
                    var readCount: DWORD = 0
                    let remaining = DWORD(byteCount - offset)
                    let ok = ReadFile(
                        handle,
                        base.advanced(by: offset),
                        remaining,
                        &readCount,
                        nil
                    )
                    if !ok { return false } // peer-closed / cancelled / real error
                    if readCount == 0 { return false } // peer closed cleanly (zero-byte read)
                    offset += Int(readCount)
                }
                return true
            }
            return ok ? buffer : nil
        }

        // MARK: - Pipe-name canonicalization

        /// Convert a Sprig-internal pipe name (e.g. `sprig-agent-...`)
        /// to the Win32 canonical form `\\.\pipe\sprig-agent-...`.
        /// Idempotent on already-prefixed input.
        private static func canonicalPipePath(_ name: String) -> String {
            if name.hasPrefix(#"\\.\pipe\"#) {
                return name
            }
            return #"\\.\pipe\"# + name
        }

        /// Default buffer size for `CreateNamedPipeW` -- 64 KiB
        /// matches the OS-side message-mode cap and is well above
        /// typical envelope sizes (a `badgeChanged` is <1 KiB).
        /// The pipe will still accept larger frames via the
        /// length-prefix framing; this is just the kernel buffer.
        private static let bufferSize = 65536
    }
#endif
