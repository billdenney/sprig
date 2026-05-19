// NamedPipeTransportTests.swift
//
// End-to-end tests for the Windows `NamedPipeTransport`. Run only on
// Windows; on macOS / Linux the suite is `#if os(Windows)`-gated.
//
// What we cover here is the byte-level Transport contract: a sent
// `Data` arrives intact on the peer's `messages()` stream; multiple
// sends preserve framing; `close()` finishes the stream and makes
// subsequent sends throw; peer-disconnect surfaces through the
// stream finishing.
//
// We do NOT test:
//   - Multi-client server (the MVP is single-client; the multi-client
//     accept loop lives above this primitive).
//   - DACL / SID-restricted access (production-only; tests use the
//     default security descriptor).
//   - Client reconnect on broken pipe (lives in the agent-side
//     wrapper, not in the transport).
//   - JSON envelope decode (that's `IPCSchema`'s job; this transport
//     moves opaque bytes).

#if os(Windows)
    import Foundation
    import Testing
    @testable import TransportKit

    @Suite("NamedPipeTransport — smoke")
    struct NamedPipeTransportTests {
        /// Run `body` against a connected pair, then synchronously
        /// close both ends before returning. Uses synchronous close
        /// (rather than `defer { Task { ... } }`) so cleanup is
        /// guaranteed before the next test starts; without it, the
        /// deferred close-Task can still be scheduled when the next
        /// test's setup begins, leaving stray read loops + pipe
        /// handles alive across the test boundary.
        private func withConnectedPair<T>(
            _ body: (NamedPipeTransport, NamedPipeTransport) async throws -> T
        ) async throws -> T {
            let pair = try await NamedPipeTransport.connectedPair()
            do {
                let result = try await body(pair.server, pair.client)
                await pair.server.close()
                await pair.client.close()
                return result
            } catch {
                await pair.server.close()
                await pair.client.close()
                throw error
            }
        }

        @Test("a single Data buffer round-trips through the pipe intact")
        func singleFrameRoundTrip() async throws {
            try await withConnectedPair { server, client in
                let payload = Data("hello, sprig\n".utf8)
                try await client.send(payload)

                var iter = server.messages().makeAsyncIterator()
                let received = try #require(await iter.next())
                #expect(received == payload)
            }
        }

        @Test("multiple back-to-back sends preserve frame boundaries")
        func multipleFramesPreserveFraming() async throws {
            try await withConnectedPair { server, client in
                // Three distinct frames with different lengths -- the
                // length-prefix framing has to split them cleanly on the
                // receiver side.
                let frames: [Data] = [
                    Data("first".utf8),
                    Data("second frame with more bytes".utf8),
                    Data([0x00, 0x01, 0x02, 0xFF]) // arbitrary binary
                ]
                for frame in frames {
                    try await client.send(frame)
                }

                var iter = server.messages().makeAsyncIterator()
                for expected in frames {
                    let received = try #require(await iter.next())
                    #expect(received == expected)
                }
            }
        }

        @Test("empty Data buffer round-trips (zero-length frame)")
        func emptyFrameRoundTrip() async throws {
            try await withConnectedPair { server, client in
                try await client.send(Data())

                var iter = server.messages().makeAsyncIterator()
                let received = try #require(await iter.next())
                #expect(received.isEmpty)
            }
        }

        @Test("server→client send works the same as client→server")
        func bidirectionalSend() async throws {
            try await withConnectedPair { server, client in
                let serverPayload = Data("agent → ext".utf8)
                let clientPayload = Data("ext → agent".utf8)
                try await server.send(serverPayload)
                try await client.send(clientPayload)

                var serverIter = server.messages().makeAsyncIterator()
                var clientIter = client.messages().makeAsyncIterator()
                let onClient = try #require(await clientIter.next())
                let onServer = try #require(await serverIter.next())
                #expect(onClient == serverPayload)
                #expect(onServer == clientPayload)
            }
        }

        @Test("close() finishes the messages() stream")
        func closeFinishesStream() async throws {
            let pair = try await NamedPipeTransport.connectedPair()

            await pair.server.close()

            // The server's own stream finishes immediately on close().
            var iter = pair.server.messages().makeAsyncIterator()
            #expect(await iter.next() == nil)

            await pair.client.close()
        }

        @Test("send after close throws TransportError.closed")
        func sendAfterCloseThrows() async throws {
            let pair = try await NamedPipeTransport.connectedPair()

            await pair.client.close()
            await #expect(throws: TransportError.self) {
                try await pair.client.send(Data("late\n".utf8))
            }
            await pair.server.close()
        }

        @Test("peer close surfaces as the messages() stream finishing")
        func peerCloseSurfacesAsStreamFinish() async throws {
            let pair = try await NamedPipeTransport.connectedPair()

            // Client closes; the server's read loop sees
            // ERROR_BROKEN_PIPE (zero-byte read) on its next ReadFile
            // and finishes its inbound stream.
            await pair.client.close()

            var iter = pair.server.messages().makeAsyncIterator()
            #expect(await iter.next() == nil)

            await pair.server.close()
        }

        @Test("a frame larger than maxFrameSize is rejected on send")
        func oversizedFrameRejected() async throws {
            try await withConnectedPair { _, client in
                let huge = Data(count: NamedPipeTransport.maxFrameSize + 1)
                await #expect(throws: TransportError.self) {
                    try await client.send(huge)
                }
            }
        }
    }
#endif
