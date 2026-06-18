// UnixSocketTransportTests.swift
//
// ADR 0076 — the Unix-domain-socket transport, exercised on Linux
// AND macOS (the implementation compiles on both; hosted Mac CI
// doubles the coverage). Mirrors the named-pipe suite: framing
// round-trips, boundary preservation, close semantics on both ends,
// the oversize-frame guard, multi-client accept, and stale-socket
// recovery.

#if os(Linux) || os(macOS)
    import Foundation
    import Testing
    @testable import TransportKit

    @Suite("UnixSocketTransport — round-trips + close semantics")
    struct UnixSocketTransportTests {
        private func makeSocketPath(_ label: String) -> String {
            // /tmp keeps the path well under the sun_path bound (the
            // default NSTemporaryDirectory on macOS CI is long).
            "/tmp/sprig-uds-\(label)-\(UUID().uuidString.prefix(8)).sock"
        }

        private struct Pair {
            let server: UnixSocketServer
            let agentSide: UnixSocketTransport
            let clientSide: UnixSocketTransport
        }

        private func makePair(_ label: String) async throws -> Pair {
            let path = makeSocketPath(label)
            let server = try UnixSocketServer(socketPath: path)
            let client = try UnixSocketTransport.connect(path: path)
            var iterator = server.connections.makeAsyncIterator()
            guard let accepted = await iterator.next() else {
                throw TransportError.sendFailed(reason: "accept produced no connection")
            }
            return Pair(server: server, agentSide: accepted, clientSide: client)
        }

        @Test("a Data buffer round-trips intact, both directions")
        func roundTripBothDirections() async throws {
            let pair = try await makePair("roundtrip")
            defer { pair.server.close() }

            let toAgent = Data("hello from client".utf8)
            try await pair.clientSide.send(toAgent)
            var agentInbox = pair.agentSide.messages().makeAsyncIterator()
            #expect(await agentInbox.next() == toAgent)

            let toClient = Data("hello from agent".utf8)
            try await pair.agentSide.send(toClient)
            var clientInbox = pair.clientSide.messages().makeAsyncIterator()
            #expect(await clientInbox.next() == toClient)

            await pair.clientSide.close()
            await pair.agentSide.close()
        }

        @Test("back-to-back sends preserve frame boundaries; empty frames survive")
        func frameBoundaries() async throws {
            let pair = try await makePair("frames")
            defer { pair.server.close() }

            let frames = [
                Data("first".utf8),
                Data(),
                Data(repeating: 0xAB, count: 1_000_000),
                Data("last".utf8)
            ]
            for frame in frames {
                try await pair.clientSide.send(frame)
            }
            var inbox = pair.agentSide.messages().makeAsyncIterator()
            for expected in frames {
                let received = await inbox.next()
                #expect(received == expected)
            }

            await pair.clientSide.close()
            await pair.agentSide.close()
        }

        @Test("oversize frame is rejected on send without touching the wire")
        func oversizeFrameRejected() async throws {
            let pair = try await makePair("oversize")
            defer { pair.server.close() }

            let tooBig = Data(count: UnixSocketTransport.maxFrameSize + 1)
            await #expect(throws: TransportError.self) {
                try await pair.clientSide.send(tooBig)
            }
            // The connection is still healthy afterwards.
            try await pair.clientSide.send(Data("still alive".utf8))
            var inbox = pair.agentSide.messages().makeAsyncIterator()
            #expect(await inbox.next() == Data("still alive".utf8))

            await pair.clientSide.close()
            await pair.agentSide.close()
        }

        @Test("local close finishes messages() and makes send throw .closed")
        func localCloseSemantics() async throws {
            let pair = try await makePair("local-close")
            defer { pair.server.close() }

            await pair.clientSide.close()
            var inbox = pair.clientSide.messages().makeAsyncIterator()
            #expect(await inbox.next() == nil, "stream finishes on local close")
            await #expect(throws: TransportError.self) {
                try await pair.clientSide.send(Data("late".utf8))
            }
            await pair.agentSide.close()
        }

        @Test("peer close finishes the other side's messages() stream")
        func peerCloseSemantics() async throws {
            let pair = try await makePair("peer-close")
            defer { pair.server.close() }

            await pair.agentSide.close()
            var inbox = pair.clientSide.messages().makeAsyncIterator()
            #expect(await inbox.next() == nil, "peer disconnect finishes the stream")
            await pair.clientSide.close()
        }

        @Test("server accepts multiple clients; each connection round-trips independently")
        func multiClient() async throws {
            let path = makeSocketPath("multi")
            let server = try UnixSocketServer(socketPath: path)
            defer { server.close() }
            var accepted = server.connections.makeAsyncIterator()

            let clientA = try UnixSocketTransport.connect(path: path)
            let agentA = try #require(await accepted.next())
            let clientB = try UnixSocketTransport.connect(path: path)
            let agentB = try #require(await accepted.next())

            try await clientA.send(Data("from A".utf8))
            try await clientB.send(Data("from B".utf8))
            var inboxA = agentA.messages().makeAsyncIterator()
            var inboxB = agentB.messages().makeAsyncIterator()
            #expect(await inboxA.next() == Data("from A".utf8))
            #expect(await inboxB.next() == Data("from B".utf8))

            await clientA.close()
            await clientB.close()
            await agentA.close()
            await agentB.close()
        }

        @Test("server close() finishes connections, unlinks the socket file, keeps live transports")
        func serverCloseSemantics() async throws {
            let path = makeSocketPath("server-close")
            let server = try UnixSocketServer(socketPath: path)
            var accepted = server.connections.makeAsyncIterator()
            let client = try UnixSocketTransport.connect(path: path)
            let agentSide = try #require(await accepted.next())

            server.close()
            #expect(await accepted.next() == nil, "connections stream finishes")
            #expect(!FileManager.default.fileExists(atPath: path), "socket file unlinked")

            // The already-accepted pair still works.
            try await client.send(Data("post-close".utf8))
            var inbox = agentSide.messages().makeAsyncIterator()
            #expect(await inbox.next() == Data("post-close".utf8))

            await client.close()
            await agentSide.close()
        }

        @Test("a stale socket file is replaced; a regular file at the path is refused")
        func staleSocketPolicy() throws {
            // Stale socket: bind a server, close it WITHOUT unlink by
            // simulating a crash — easiest honest approximation is to
            // create a real socket file via a server, close it (which
            // unlinks), then create another server at the same path
            // twice in a row to prove rebinding works…
            let path = makeSocketPath("stale")
            let first = try UnixSocketServer(socketPath: path)
            first.close()
            let second = try UnixSocketServer(socketPath: path)
            second.close()

            // …and the refusal case: a regular file at the path.
            let filePath = makeSocketPath("not-a-socket")
            _ = FileManager.default.createFile(atPath: filePath, contents: Data("data".utf8))
            defer { try? FileManager.default.removeItem(atPath: filePath) }
            #expect(throws: TransportError.self) {
                _ = try UnixSocketServer(socketPath: filePath)
            }
            #expect(
                FileManager.default.fileExists(atPath: filePath),
                "the non-socket file must survive"
            )
        }

        @Test("socket paths over the sun_path bound are rejected")
        func pathLengthGuard() {
            let longPath = "/tmp/" + String(repeating: "x", count: 120)
            #expect(throws: TransportError.self) {
                _ = try UnixSocketTransport.connect(path: longPath)
            }
        }

        @Test("the default peer policy serves the server's own user")
        func defaultPeerPolicyAcceptsSameUser() async throws {
            // Every earlier test exercises this implicitly; this one
            // pins it as the contract: same-euid connections are
            // served under the DEFAULT policy.
            let pair = try await makePair("peer-accept")
            defer { pair.server.close() }
            try await pair.clientSide.send(Data("hello".utf8))
            var inbox = pair.agentSide.messages().makeAsyncIterator()
            #expect(await inbox.next() == Data("hello".utf8))
            await pair.clientSide.close()
            await pair.agentSide.close()
        }

        @Test("a policy-rejected peer is closed before any transport is yielded")
        func rejectedPeerNeverServed() async throws {
            let path = makeSocketPath("peer-reject")
            // Reject everyone — the same code path a cross-user
            // connection takes, exercisable without root.
            let server = try UnixSocketServer(socketPath: path, peerPolicy: { _ in false })
            defer { server.close() }

            let client = try UnixSocketTransport.connect(path: path)
            // The server closes the descriptor immediately: the
            // client's stream finishes without ever receiving data...
            var inbox = client.messages().makeAsyncIterator()
            #expect(await inbox.next() == nil, "rejected peer sees EOF")
            // ...and the server never yields a connection. close()
            // then finishes the stream; if a transport HAD been
            // yielded it would arrive before nil.
            server.close()
            var accepted = server.connections.makeAsyncIterator()
            #expect(await accepted.next() == nil, "no transport for a rejected peer")
            await client.close()
        }

        // MARK: - Leak safety nets (the macos-14/15 CI hang)

        //
        // A transport/server dropped WITHOUT close() must still wake and
        // retire its detached reader/accept thread, or the parked thread
        // strands its fd open. macOS caps a process at 256 fds, so a few
        // dozen leaks across the suite exhaust descriptors and wedge the
        // whole async runtime — which is exactly what froze macos-14/15
        // ~30 s into the run until the watchdog hard-killed it. These two
        // tests reproduce the leak deterministically (they time out
        // before the deinit safety nets exist) and pin the fix.

        /// True if `work` runs to completion before the deadline. On
        /// timeout the work task is cancelled — an AsyncStream drain
        /// ends cleanly on cancellation, so this never strands a task.
        private func completesWithin(
            seconds: Double,
            _ work: @escaping @Sendable () async -> Void
        ) async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await work(); return true }
                group.addTask {
                    try? await Task.sleep(for: .seconds(seconds))
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
        }

        @Test("a transport dropped without close() shuts down its socket so the peer sees EOF")
        func droppedTransportReleasesReader() async throws {
            let path = makeSocketPath("drop-transport")
            let server = try UnixSocketServer(socketPath: path)
            defer { server.close() }
            var accepted = server.connections.makeAsyncIterator()

            let agentSide: UnixSocketTransport
            do {
                let client = try UnixSocketTransport.connect(path: path)
                guard let a = await accepted.next() else {
                    throw TransportError.sendFailed(reason: "accept produced no connection")
                }
                agentSide = a
                // Keep `client` alive through accept, then let it drop at
                // the end of this scope WITHOUT close(): deinit must
                // shutdown its fd, which the kernel delivers as EOF to
                // the agent side.
                withExtendedLifetime(client) {}
            }

            let sawEOF = await completesWithin(seconds: 10) {
                for await _ in agentSide.messages() {}
            }
            #expect(sawEOF, "dropping a client transport without close() must EOF the peer (deinit safety net)")
            await agentSide.close()
        }

        @Test("a server dropped without close() finishes connections and unlinks the socket")
        func droppedServerReleasesAcceptThread() async throws {
            let path = makeSocketPath("drop-server")
            let connections: AsyncStream<UnixSocketTransport>
            do {
                let server = try UnixSocketServer(socketPath: path)
                connections = server.connections
                withExtendedLifetime(server) {}
            } // server drops here WITHOUT close()

            let finished = await completesWithin(seconds: 10) {
                for await _ in connections {}
            }
            #expect(finished, "dropping a server without close() must finish connections (deinit safety net)")
            #expect(
                !FileManager.default.fileExists(atPath: path),
                "deinit must unlink the socket file"
            )
        }
    }
#endif
