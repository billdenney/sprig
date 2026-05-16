// TransportBadgeEventSinkTests.swift
//
// End-to-end wire round-trip: `RepoAgent` constructed with a
// `TransportBadgeEventSink` over `InProcessTransport` produces
// `Envelope<AgentEvent>` envelopes that arrive on the peer's
// `messages()` stream, decode cleanly via `EnvelopeCodec`, and carry
// the expected payload. This is what validates the v1 IPCSchema
// envelope shape across a Transport boundary — the shape that the
// M2-Mac XPC adapter will pick up unchanged.
//
// Per CLAUDE.md, the integration spawns real git into a temp dir;
// only the watcher is mocked.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import TransportKit
import WatcherKit

@Suite("TransportBadgeEventSink — end-to-end Transport round-trip")
struct TransportBadgeEventSinkTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-tsink-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    /// Wait up to `timeout` for the next decoded envelope on `client`.
    /// Returns nil on timeout.
    ///
    /// Platform-conditional default: 5 s on macOS / Linux (the
    /// envelope typically lands in <1 s on those platforms), 30 s on
    /// Windows. The full agent loop (watcher → coalescer → status
    /// refresher → broadcaster → transport) carries ~5 s of Windows-
    /// specific overhead under hosted-runner load: ~2 s polling-watcher
    /// fs-visibility lag, ~1-2 s `git status` process spawn, plus
    /// scheduler latency.
    private static let defaultTimeout: Duration = {
        #if os(Windows)
            return .seconds(30)
        #else
            return .seconds(5)
        #endif
    }()

    private func awaitEnvelope(
        on client: any Transport,
        timeout: Duration = Self.defaultTimeout
    ) async -> Envelope<AgentEvent>? {
        await withTaskGroup(of: Envelope<AgentEvent>?.self) { group in
            group.addTask {
                for await data in client.messages() {
                    if let envelope = try? EnvelopeCodec.decode(AgentEvent.self, from: data) {
                        return envelope
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    @Test("a watcher-driven badge change arrives on the peer's transport as a decoded AgentEvent")
    func endToEndWireRoundTrip() async throws {
        let (root, runner) = try await mkRepo("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let watcher = MockFileWatcher()
        let registry = SubscriptionRegistry()
        let pair = InProcessTransportPair.connected()
        let sink = TransportBadgeEventSink(transport: pair.agentEnd)

        let agent = RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )
        _ = await registry.subscribe(roots: [root])
        try await agent.start()
        defer {
            Task {
                await agent.stop()
                await pair.agentEnd.close()
            }
        }

        try write("v2\n", to: file)
        await watcher.emit(WatchEvent(path: file, kind: .modified))

        let envelope = try #require(
            await awaitEnvelope(on: pair.clientEnd),
            "expected an envelope on the client end of the transport"
        )
        if case let .badgeChanged(payload) = envelope.message {
            #expect(payload.path == file.path)
            #expect(payload.badge == BadgeIdentifier.modified.rawValue)
        } else {
            Issue.record("expected .badgeChanged, got \(envelope.message)")
        }
        // The schemaVersion must match what the codec writes; mismatch
        // would break wire compatibility silently.
        #expect(envelope.schemaVersion == IPCSchema.currentSchemaVersion)
    }

    @Test("emit on a closed transport rethrows TransportError without crashing the agent")
    func emitAfterCloseRethrows() async throws {
        let pair = InProcessTransportPair.connected()
        let sink = TransportBadgeEventSink(transport: pair.agentEnd)

        // Close the peer end first so the agent end's send() observes
        // peer-closed (the in-process transport reports both as
        // `peerClosed` per its design note).
        await pair.clientEnd.close()

        let envelope = Envelope<AgentEvent>(
            message: .badgeChanged(BadgeChangedPayload(
                subscriptionId: UUID(),
                path: "/tmp/whatever",
                badge: BadgeIdentifier.modified.rawValue
            ))
        )

        await #expect(throws: TransportError.self) {
            try await sink.emit(envelope)
        }
        await pair.agentEnd.close()
    }
}
