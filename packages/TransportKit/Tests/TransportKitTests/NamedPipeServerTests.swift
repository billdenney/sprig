// NamedPipeServerTests.swift
//
// End-to-end tests for the Windows multi-client `NamedPipeServer`.
// Run only on Windows; on macOS / Linux the suite is
// `#if os(Windows)`-gated.
//
// What we cover here:
// - Sequential clients: server accepts one client, the round-trip
//   works, both ends close; server then accepts a *new* client on the
//   *same pipe name*, the round-trip still works. This is the central
//   reason `NamedPipeServer` exists (the single-client primitive's
//   `server(pipeName:)` returns one transport and is done).
// - `close()` before any client arrives finishes the `connections`
//   stream promptly. Verifies the cancel-event wiring inside
//   `NamedPipeIO.acceptClient` actually unblocks the accept loop.
// - `close()` after a connection has been yielded does NOT close the
//   already-yielded transport. The consumer of `connections` owns
//   each accepted transport; the server's lifecycle and the
//   per-client transports' lifecycles are independent.
//
// We do NOT test here:
//   - Concurrent (not just sequential) client connects. The
//     single-thread accept loop serializes accept calls, so a second
//     client connecting before the first has been yielded to the
//     consumer will see `ERROR_PIPE_BUSY` until the server completes
//     the next `CreateNamedPipeW` call. The `CreateThreadpoolIo`
//     follow-up slice will let the test drop in.
//   - DACL / peer-SID validation (M2-Win hardening; tracked under
//     ADR 0060).

#if os(Windows)
    import Foundation
    import Testing
    @testable import TransportKit

    @Suite("NamedPipeServer — multi-client accept loop")
    struct NamedPipeServerTests {
        /// Unique pipe name per test so concurrent test runs don't
        /// collide on the same `\\.\pipe\sprig-test-server-*` name.
        private func uniquePipeName() -> String {
            "sprig-test-server-\(UUID().uuidString)"
        }

        @Test("server accepts multiple sequential clients on the same pipe name")
        func sequentialClients() async throws {
            let pipeName = uniquePipeName()
            let server = try NamedPipeServer(pipeName: pipeName)
            var iter = server.connections.makeAsyncIterator()

            for index in 0 ..< 3 {
                // Fire the client open and the accept-pickup as
                // structured-concurrent tasks so neither blocks the
                // other; `connectedPair`'s 50 ms inter-end delay isn't
                // available to us here, but `async let` lets the
                // client's `CreateFileW` race the server's
                // `ConnectNamedPipe` cleanly.
                async let clientTask = NamedPipeTransport.client(pipeName: pipeName)
                let conn = try #require(await iter.next())
                let client = try await clientTask

                let payload = Data("hello-\(index)".utf8)
                try await client.send(payload)
                var connIter = conn.messages().makeAsyncIterator()
                let received = try #require(await connIter.next())
                #expect(received == payload)

                await client.close()
                await conn.close()
            }

            await server.close()
        }

        @Test("close() before any client arrives finishes the connections stream")
        func closeBeforeAnyClient() async throws {
            let pipeName = uniquePipeName()
            let server = try NamedPipeServer(pipeName: pipeName)

            // Let the accept loop reach its `WaitForMultipleObjects`
            // before we cancel. Without this, the cancel can race the
            // first `ConnectNamedPipe` call and we'd be testing a
            // different code path (pre-wait cancel vs. wait cancel).
            try? await Task.sleep(nanoseconds: 50_000_000)

            await server.close()

            var iter = server.connections.makeAsyncIterator()
            #expect(await iter.next() == nil)
        }

        @Test("close() finishes the connections stream even after clients have been served")
        func closeAfterServingClients() async throws {
            let pipeName = uniquePipeName()
            let server = try NamedPipeServer(pipeName: pipeName)
            var iter = server.connections.makeAsyncIterator()

            // One round-trip to confirm the server has actually
            // accepted + the connections iterator has advanced.
            async let clientTask = NamedPipeTransport.client(pipeName: pipeName)
            let conn = try #require(await iter.next())
            let client = try await clientTask
            try await client.send(Data("ping".utf8))
            var connIter = conn.messages().makeAsyncIterator()
            _ = try #require(await connIter.next())

            await client.close()
            await conn.close()

            // Now close the server and verify the stream finishes.
            await server.close()
            #expect(await iter.next() == nil)
        }

        @Test("server close() leaves already-yielded transports intact")
        func serverCloseDoesNotCloseAcceptedTransports() async throws {
            let pipeName = uniquePipeName()
            let server = try NamedPipeServer(pipeName: pipeName)
            var iter = server.connections.makeAsyncIterator()

            async let clientTask = NamedPipeTransport.client(pipeName: pipeName)
            let conn = try #require(await iter.next())
            let client = try await clientTask

            // Round-trip *before* server close to confirm baseline.
            try await client.send(Data("before".utf8))
            var connIter = conn.messages().makeAsyncIterator()
            let before = try #require(await connIter.next())
            #expect(before == Data("before".utf8))

            // Server close should NOT shut down the per-client
            // transport. The consumer owns each yielded
            // `NamedPipeTransport` and decides when to close it.
            await server.close()

            try await client.send(Data("after".utf8))
            let after = try #require(await connIter.next())
            #expect(after == Data("after".utf8))

            await client.close()
            await conn.close()
        }
    }
#endif
