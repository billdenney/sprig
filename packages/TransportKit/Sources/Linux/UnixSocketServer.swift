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

        /// Stop accepting: wakes the accept loop (which closes the
        /// listening fd on exit), finishes ``connections``, and
        /// removes the socket file. Already-yielded transports stay
        /// usable. Idempotent.
        public func close() {
            lock.lock()
            let alreadyClosed = closed
            closed = true
            lock.unlock()
            guard !alreadyClosed else { return }
            // shutdown(2) on a listening socket wakes a blocked
            // accept(2) on both Linux (EINVAL) and Darwin
            // (ECONNABORTED) — closing the fd out from under a
            // blocked syscall would race fd reuse instead.
            _ = shutdown(listenFD, Int32(SHUT_RDWR))
            _ = unlink(socketPath)
        }

        private func startAcceptThread() {
            let fd = listenFD
            let continuation = connectionsContinuation
            Thread.detachNewThread { [weak self] in
                defer {
                    continuation.finish()
                    _ = systemClose(fd)
                }
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 {
                        if errno == EINTR { continue }
                        // EINVAL / ECONNABORTED / EBADF: close() shut
                        // the listener down (or a transient abort on
                        // a dying connection — either way, if we're
                        // closed, exit).
                        if self?.isClosed != false { return }
                        if errno == ECONNABORTED { continue }
                        return
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
