// UnixSocketServer.swift
//
// The agent-side listener for ``UnixSocketTransport`` (ADR 0076).
// Mirrors `NamedPipeServer`'s shape: construct with a socket path,
// consume ``connections`` (one ``UnixSocketTransport`` per accepted
// client), `close()` to stop — which finishes the stream, wakes the
// accept loop, and unlinks the socket file.
//
// Stale-socket policy: a leftover file at the path from a crashed
// agent would make `bind(2)` fail EADDRINUSE forever, so init
// unlinks the path first — but ONLY when the existing file is a
// socket. A regular file/directory at the path is someone else's
// data; init fails rather than deleting it.

#if os(Linux) || os(macOS)
    import Foundation
    #if canImport(Glibc)
        import Glibc
    #else
        import Darwin
    #endif

    /// Accept loop for one Unix-domain socket path.
    public final class UnixSocketServer: @unchecked Sendable {
        /// Decides whether a connecting peer (by effective UID) may
        /// be served. The default accepts only the server's own
        /// user — the socket file's mode is the first gate; this is
        /// defense-in-depth against permissive modes and inherited
        /// descriptors (ADR 0076's peer-SID analogue).
        public typealias PeerPolicy = @Sendable (uid_t) -> Bool

        /// One element per accepted client. Finishes on ``close()``.
        public let connections: AsyncStream<UnixSocketTransport>

        public let socketPath: String

        private let lock = NSLock()
        private let listenFD: Int32
        private var closed = false
        private let peerPolicy: PeerPolicy
        private let connectionsContinuation: AsyncStream<UnixSocketTransport>.Continuation

        public init(
            socketPath: String,
            peerPolicy: @escaping PeerPolicy = { $0 == geteuid() }
        ) throws {
            self.peerPolicy = peerPolicy
            self.socketPath = socketPath

            // Stale-socket cleanup (sockets only — see header).
            var info = stat()
            if stat(socketPath, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                    throw TransportError.sendFailed(
                        reason: "refusing to replace non-socket file at \(socketPath)"
                    )
                }
                _ = unlink(socketPath)
            }

            let fd = try UnixSocketAddress.makeSocket()
            do {
                var address = try UnixSocketAddress.make(path: socketPath)
                let bindResult = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        bind(fd, sa, UnixSocketAddress.length)
                    }
                }
                guard bindResult == 0 else {
                    throw TransportError.sendFailed(
                        reason: "bind(\(socketPath)): errno \(errno)"
                    )
                }
                guard listen(fd, 16) == 0 else {
                    throw TransportError.sendFailed(reason: "listen: errno \(errno)")
                }
                // Non-blocking so the accept loop can poll(2) with a
                // timeout and never park in accept() — see
                // startAcceptThread() for why we don't block-and-wake.
                let flags = fcntl(fd, F_GETFL, 0)
                if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
            } catch {
                _ = systemClose(fd)
                throw error
            }
            listenFD = fd

            var continuation: AsyncStream<UnixSocketTransport>.Continuation!
            connections = AsyncStream { continuation = $0 }
            connectionsContinuation = continuation
            startAcceptThread()
        }

        /// How long the accept loop blocks in `poll(2)` before
        /// re-checking ``closed``. This is the worst-case latency for
        /// ``close()`` to retire the accept thread; idle cost is one
        /// wakeup per tick (negligible).
        private static let acceptPollTimeoutMillis: Int32 = 250

        /// Stop accepting: the accept loop observes ``closed`` on its
        /// next `poll(2)` tick (≤ ``acceptPollTimeoutMillis`` later),
        /// finishes ``connections``, and closes the listening fd; this
        /// also unlinks the socket file. Already-yielded transports stay
        /// usable. Idempotent.
        public func close() {
            guard markClosed() else { return }
            _ = unlink(socketPath)
        }

        deinit {
            // Safety net for a server dropped WITHOUT `close()`: flipping
            // the flag the accept loop polls is enough for its detached
            // thread to exit instead of parking forever; also drop the
            // socket file. (No fd allocation here — see startAcceptThread.)
            if markClosed() {
                _ = unlink(socketPath)
            }
        }

        /// Idempotent closed-flag transition. Returns true only for the
        /// call that performed it, so exactly one of close()/deinit
        /// unlinks the socket file.
        private func markClosed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }

        private func startAcceptThread() {
            let fd = listenFD
            let continuation = connectionsContinuation
            Thread.detachNewThread { [weak self] in
                defer {
                    continuation.finish()
                    _ = systemClose(fd)
                }
                // We poll(2) with a timeout instead of blocking in
                // accept(2) and relying on a wake. No portable signal
                // reliably unblocks a parked listening accept(): on Darwin
                // shutdown(2) on a listening socket fails ENOTCONN and
                // leaves accept() parked (only Linux wakes it, with
                // EINVAL) — that stranded the accept thread on macOS, so
                // `connections` never finished and the suite hung. A
                // self-connection wake would work but needs a fresh fd at
                // close() time, which fails under fd pressure. Polling a
                // non-blocking listen fd needs nothing at close() but the
                // `closed` flip, which this loop notices within one tick.
                while true {
                    if self?.isClosed != false { return }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, UnixSocketServer.acceptPollTimeoutMillis)
                    if ready <= 0 {
                        // 0 = timeout (re-check closed); <0 = EINTR/error.
                        if ready < 0, errno != EINTR { return }
                        continue
                    }
                    let client = accept(fd, nil, nil)
                    // Retired (or deallocated) while we polled? Drop
                    // whatever we accepted and exit.
                    if self?.isClosed != false {
                        if client >= 0 { _ = systemClose(client) }
                        return
                    }
                    if client < 0 {
                        // EAGAIN/EWOULDBLOCK: spurious readiness on the
                        // non-blocking fd (a peer aborted before accept).
                        // EINTR/ECONNABORTED: transient. All → re-poll.
                        if errno == EAGAIN || errno == EWOULDBLOCK
                            || errno == EINTR || errno == ECONNABORTED { continue }
                        return
                    }
                    // Clear O_NONBLOCK on the accepted fd. On BSD/Darwin
                    // accept(2) INHERITS the listening socket's
                    // non-blocking flag (Linux does not); without this the
                    // accepted UnixSocketTransport's reader read(2) returns
                    // EAGAIN at once and the transport closes immediately.
                    let clientFlags = fcntl(client, F_GETFL, 0)
                    if clientFlags >= 0 {
                        _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
                    }
                    #if !canImport(Glibc)
                        var one: Int32 = 1
                        _ = setsockopt(
                            client, SOL_SOCKET, SO_NOSIGPIPE,
                            &one, socklen_t(MemoryLayout<Int32>.size)
                        )
                    #endif
                    // Peer-credential gate: an unverifiable or
                    // policy-rejected peer is closed before any
                    // transport exists — it never reaches a
                    // dispatcher.
                    guard let policy = self?.peerPolicy,
                          let peer = UnixSocketServer.peerUID(of: client),
                          policy(peer)
                    else {
                        _ = systemClose(client)
                        continue
                    }
                    continuation.yield(UnixSocketTransport(fd: client))
                }
            }
        }

        private var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        /// The connecting peer's effective UID — `SO_PEERCRED` on
        /// Linux, `getpeereid(2)` on Darwin. Nil when the kernel
        /// can't say, which the accept gate treats as a rejection
        /// (fail closed).
        /// Linux's `struct ucred` (pid, uid, gid — all 32-bit), mirrored
        /// locally because Glibc's Swift overlay hides it behind
        /// `_GNU_SOURCE`. The layout is kernel ABI, stable since 2.2.
        private struct LinuxPeerCredentials {
            var pid: Int32 = 0
            var uid: UInt32 = 0
            var gid: UInt32 = 0
        }

        static func peerUID(of fd: Int32) -> uid_t? {
            #if canImport(Glibc)
                // SO_PEERCRED is 17 on every architecture Sprig's Linux
                // CI targets (x86_64, aarch64); the overlay doesn't
                // export the constant.
                let soPeerCred: Int32 = 17
                var credentials = LinuxPeerCredentials()
                var length = socklen_t(MemoryLayout<LinuxPeerCredentials>.size)
                let result = getsockopt(fd, SOL_SOCKET, soPeerCred, &credentials, &length)
                guard result == 0 else { return nil }
                return uid_t(credentials.uid)
            #else
                var euid = uid_t(0)
                var egid = gid_t(0)
                guard getpeereid(fd, &euid, &egid) == 0 else { return nil }
                return euid
            #endif
        }
    }
#endif
