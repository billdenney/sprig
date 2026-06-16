// UnixSocketTransport.swift
//
// Unix-domain-socket ``Transport`` implementation — the Linux IPC
// adapter (ADR 0076: UDS over D-Bus), also compiled on macOS so the
// hosted Mac CI exercises it and so it can serve as a non-sandboxed
// fallback there (the FinderSync extension itself uses XPC).
//
// Wire format matches the Windows named-pipe transport byte-for-byte
// (ADR 0048's transport-swap covenant): each message is a 4-byte
// little-endian length prefix followed by the payload, frames capped
// at 16 MB.
//
// Concurrency model: blocking POSIX I/O kept OFF the cooperative
// pool — one detached reader thread per connection feeds the
// `messages()` stream; writes hop to a per-connection serial
// DispatchQueue (serialization doubles as frame-interleaving
// protection). SIGPIPE is suppressed per-send (`MSG_NOSIGNAL` on
// Linux; `SO_NOSIGPIPE` at socket creation on Darwin) — a dead peer
// must surface as a thrown error, never a process-killing signal.
//
// fd lifecycle: `close()` marks the transport closed and
// `shutdown(2)`s the socket — which wakes a reader blocked in
// `read(2)` with EOF on both platforms — and the READER thread is
// the single owner that `close(2)`s the descriptor on loop exit, so
// the fd can never be closed while a syscall is using it.

#if os(Linux) || os(macOS)
    import Foundation
    #if canImport(Glibc)
        import Glibc
    #else
        import Darwin
    #endif

    /// One end of a Unix-domain-socket connection.
    public final class UnixSocketTransport: Transport, @unchecked Sendable {
        /// Same bound as the named-pipe transport: 16 MB.
        public static let maxFrameSize = 16 * 1024 * 1024

        private let lock = NSLock()
        private let fd: Int32
        private var closed = false
        private let inbound: AsyncStream<Data>
        private let inboundContinuation: AsyncStream<Data>.Continuation
        private let writeQueue: DispatchQueue

        /// Wrap an already-connected socket descriptor (the server's
        /// accept path). Takes ownership of `fd`.
        init(fd: Int32) {
            self.fd = fd
            writeQueue = DispatchQueue(label: "app.sprig.uds.write.\(fd)")
            var continuation: AsyncStream<Data>.Continuation!
            inbound = AsyncStream { continuation = $0 }
            inboundContinuation = continuation
            startReaderThread()
        }

        /// Client entry point: connect to the agent's socket at
        /// `path`.
        public static func connect(path: String) throws -> UnixSocketTransport {
            let fd = try UnixSocketAddress.makeSocket()
            do {
                var address = try UnixSocketAddress.make(path: path)
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        systemConnect(fd, sa, UnixSocketAddress.length)
                    }
                }
                guard result == 0 else {
                    throw TransportError.sendFailed(reason: "connect(\(path)): errno \(errno)")
                }
            } catch {
                _ = systemClose(fd)
                throw error
            }
            return UnixSocketTransport(fd: fd)
        }

        // MARK: - Transport

        public func send(_ data: Data) async throws {
            guard data.count <= Self.maxFrameSize else {
                throw TransportError.sendFailed(
                    reason: "send: frame size \(data.count) exceeds max \(Self.maxFrameSize)"
                )
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                writeQueue.async { [self] in
                    do {
                        try blockingSend(data)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }

        public func messages() -> AsyncStream<Data> {
            inbound
        }

        public func close() async {
            guard markClosed() else { return }
            // Wakes the reader (read returns 0) on both platforms; the
            // reader thread closes the fd on exit.
            _ = shutdown(fd, Int32(SHUT_RDWR))
        }

        deinit {
            // Safety net for a transport dropped WITHOUT `close()`: its
            // detached reader thread would otherwise stay parked forever
            // in read(2), holding the fd open (the reader is the sole
            // owner of the close, and only EOF or shutdown(2) wakes it).
            // macOS caps a process at 256 fds by default, so a suite that
            // leaks a few dozen of these exhausts descriptors and wedges
            // the whole process — this was the macos-14/15 CI hang. Wake
            // the reader exactly as close() does, but only when neither
            // close() nor a reader-exit has already retired the transport
            // (markClosed() returns false then) — otherwise we could
            // shutdown a descriptor number the kernel has since reused.
            if markClosed() {
                _ = shutdown(fd, Int32(SHUT_RDWR))
            }
        }

        /// Synchronous closed-flag transition (NSLock's lock()/unlock()
        /// are unavailable in async contexts on the snapshot
        /// toolchain — quirk-C class). Returns true when this call
        /// performed the transition.
        private func markClosed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }

        // MARK: - Blocking internals (write queue / reader thread)

        private func blockingSend(_ data: Data) throws {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            guard !isClosed else { throw TransportError.closed }

            var lengthLE = UInt32(data.count).littleEndian
            var buffer = withUnsafeBytes(of: &lengthLE) { Data($0) }
            buffer.append(data)
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let wrote = UnixSocketAddress.sendNoSignal(
                        fd,
                        raw.baseAddress! + offset,
                        raw.count - offset
                    )
                    if wrote < 0 {
                        if errno == EINTR { continue }
                        if errno == EPIPE || errno == ECONNRESET {
                            throw TransportError.peerClosed
                        }
                        throw TransportError.sendFailed(reason: "send: errno \(errno)")
                    }
                    if wrote == 0 { throw TransportError.peerClosed }
                    offset += wrote
                }
            }
        }

        private func startReaderThread() {
            let fd = fd
            let continuation = inboundContinuation
            Thread.detachNewThread { [weak self] in
                defer {
                    continuation.finish()
                    self?.markClosedAfterReaderExit()
                    _ = systemClose(fd)
                }
                while true {
                    guard let header = Self.readExactly(fd, count: 4) else { return }
                    let length = header.withUnsafeBytes {
                        UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
                    }
                    guard length <= UInt32(Self.maxFrameSize) else { return }
                    if length == 0 {
                        continuation.yield(Data())
                        continue
                    }
                    guard let payload = Self.readExactly(fd, count: Int(length)) else { return }
                    continuation.yield(payload)
                }
            }
        }

        /// Reader exit (peer EOF or local shutdown) means no more I/O
        /// can succeed; flip `closed` so subsequent sends throw
        /// without touching the now-closed descriptor.
        private func markClosedAfterReaderExit() {
            lock.lock()
            closed = true
            lock.unlock()
        }

        /// Read exactly `count` bytes; nil on EOF or error.
        private static func readExactly(_ fd: Int32, count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            let result: Bool = data.withUnsafeMutableBytes { raw in
                while offset < count {
                    let got = read(fd, raw.baseAddress! + offset, count - offset)
                    if got < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    if got == 0 { return false }
                    offset += got
                }
                return true
            }
            return result ? data : nil
        }
    }

    /// `sockaddr_un` construction + the per-platform socket quirks,
    /// shared by the transport and the server.
    enum UnixSocketAddress {
        /// `sun_path` is 104 bytes on Darwin, 108 on Linux; stay
        /// under the smaller bound with room for the NUL.
        static let maxPathLength = 100

        static var length: socklen_t {
            socklen_t(MemoryLayout<sockaddr_un>.size)
        }

        static func make(path: String) throws -> sockaddr_un {
            let bytes = Array(path.utf8)
            guard !bytes.isEmpty, bytes.count <= maxPathLength else {
                throw TransportError.sendFailed(
                    reason: "socket path must be 1...\(maxPathLength) bytes, got \(bytes.count)"
                )
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
                for (index, byte) in bytes.enumerated() {
                    sunPath[index] = byte
                }
            }
            return address
        }

        /// `socket(AF_UNIX, SOCK_STREAM, 0)` with Darwin's
        /// SIGPIPE suppression applied at creation (Linux suppresses
        /// per-send via MSG_NOSIGNAL instead).
        static func makeSocket() throws -> Int32 {
            #if canImport(Glibc)
                let streamType = Int32(SOCK_STREAM.rawValue)
            #else
                let streamType = SOCK_STREAM
            #endif
            let fd = socket(AF_UNIX, streamType, 0)
            guard fd >= 0 else {
                throw TransportError.sendFailed(reason: "socket: errno \(errno)")
            }
            #if !canImport(Glibc)
                var one: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            return fd
        }

        static func sendNoSignal(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
            #if canImport(Glibc)
                Glibc.send(fd, pointer, count, Int32(MSG_NOSIGNAL))
            #else
                Darwin.send(fd, pointer, count, 0)
            #endif
        }
    }

    /// `connect(2)` under a non-clashing name (the type has a
    /// `connect` factory).
    private func systemConnect(
        _ fd: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t
    ) -> Int32 {
        #if canImport(Glibc)
            Glibc.connect(fd, address, length)
        #else
            Darwin.connect(fd, address, length)
        #endif
    }

    /// `close(2)` under a non-clashing name (`Transport` has `close()`).
    func systemClose(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
            Glibc.close(fd)
        #else
            Darwin.close(fd)
        #endif
    }
#endif
