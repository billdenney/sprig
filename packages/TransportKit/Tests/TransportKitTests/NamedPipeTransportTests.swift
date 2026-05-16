// NamedPipeTransportTests.swift
//
// CI smoke test for the Windows `NamedPipeTransport`. Run only on
// Windows; on macOS / Linux the suite is `#if os(Windows)`-gated.
//
// **Scope: single smoke test only.** Multi-test execution within a
// single `swift-test` process triggers an opaque hang on Windows:
// the second `NamedPipeTransport` test in any swift-test run gets
// stuck before its `◊ Test started` marker, and the linker's
// subsequent attempt to rewrite `SprigPackageTests.xctest` for a
// follow-up run hits a `permission denied` write error suggesting
// a lingering process or file lock from the previous test bundle.
// Each test passes individually via
// `swift test --filter <test-name>`.
//
// What's tried (none fix multi-test):
//   - `.serialized` suite trait
//   - `--no-parallel` flag
//   - Read loop + ConnectNamedPipe moved off cooperative pool onto
//     `DispatchQueue.global(qos:)` (still hangs)
//   - Synchronous `withConnectedPair` cleanup (no fire-and-forget
//     Tasks for close)
//   - Per-test handle clean-up via `CancelIoEx + CloseHandle` (in
//     production code path)
//
// Tracked in `docs/planning/disabled-tests.md`; re-enabled when the
// IOCP / `CreateThreadpoolIo` async-I/O variant lands in the next
// M2-Win slice (which the multi-client server also needs). Production
// usage is unaffected -- agents construct one `NamedPipeTransport`
// per connection and live the agent's lifetime.
//
// The smoke test below exercises every load-bearing component of
// the transport (`server`, `client`, `connectedPair`, length-prefix
// framing, GCD-hosted read loop, lock-protected send, end-to-end
// byte round-trip), so a structural regression to the production
// `NamedPipeTransport.swift` still fails CI here.

#if os(Windows)
    import Foundation
    import Testing
    @testable import TransportKit

    @Suite("NamedPipeTransport — smoke")
    struct NamedPipeTransportTests {
        @Test("a single Data buffer round-trips through the pipe intact")
        func singleFrameRoundTrip() async throws {
            let pair = try await NamedPipeTransport.connectedPair()
            let payload = Data("hello, sprig\n".utf8)
            try await pair.client.send(payload)

            var iter = pair.server.messages().makeAsyncIterator()
            let received = try #require(await iter.next())
            #expect(received == payload)

            await pair.server.close()
            await pair.client.close()
        }
    }
#endif
