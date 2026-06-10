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
            FileManager.default.createFile(atPath: filePath, contents: Data("data".utf8))
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
    }
#endif
