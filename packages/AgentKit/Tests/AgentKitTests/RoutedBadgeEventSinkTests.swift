// RoutedBadgeEventSinkTests.swift
//
// End-to-end multi-client tests: two clients connected to the same
// host process, each subscribed to its own roots, get the right
// events and only the right events. Without this routing, every
// event would arrive on every client's transport — leaking repos
// across subscribers.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import TransportKit
import WatcherKit

@Suite("RoutedBadgeEventSink — multi-client fan-out via subscription routing")
struct RoutedBadgeEventSinkTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-routed-\(tag)-\(UUID().uuidString)")
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

    /// Wait for the next decoded `AgentResponse` envelope, then for
    /// the next decoded `AgentEvent`. Returns nil on either timeout.
    /// Used by the multi-client tests to pull (ack, badge-event) for
    /// each client.
    ///
    /// Platform-conditional default: 3 s on macOS / Linux (where the
    /// ack + event pair typically lands in <1 s), 30 s on Windows.
    /// The full agent loop (watcher → coalescer → status refresher →
    /// broadcaster → routed sink → both transport pairs) carries ~5 s
    /// of Windows-specific overhead under hosted-runner load
    /// (polling-watcher fs-visibility lag ~2 s, `git status` process
    /// spawn ~1-2 s, scheduler latency); since this helper has to
    /// collect TWO independent envelopes, the doubled wall-clock cost
    /// makes the 3 s ceiling especially tight on Windows. The
    /// short-circuit on first match means macOS / Linux see no
    /// added cost from the larger Windows budget.
    private static let defaultTimeout: Duration = {
        #if os(Windows)
            return .seconds(30)
        #else
            return .seconds(3)
        #endif
    }()

    private func awaitAckAndEvent(
        on client: any Transport,
        timeout: Duration = Self.defaultTimeout
    ) async -> (Envelope<AgentResponse>, Envelope<AgentEvent>)? {
        await withTaskGroup(
            of: (Envelope<AgentResponse>, Envelope<AgentEvent>)?.self
        ) { group in
            group.addTask {
                var ack: Envelope<AgentResponse>?
                var event: Envelope<AgentEvent>?
                for await data in client.messages() {
                    guard let kind = try? EnvelopePeek.kind(of: data) else { continue }
                    if ack == nil, kind == "subscribeAck" {
                        ack = try? EnvelopeCodec.decode(AgentResponse.self, from: data)
                    } else if event == nil, kind == "badgeChanged" {
                        event = try? EnvelopeCodec.decode(AgentEvent.self, from: data)
                    }
                    if let ack, let event { return (ack, event) }
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

    /// Helper: build the components a single client needs (transport
    /// pair + dispatcher) wired into shared `routes` and `registry`.
    /// Returns the pair so the test can drive the client side.
    private func wireClient(
        registry: SubscriptionRegistry,
        routes: SubscriptionTransportRoutes
    ) async -> (InProcessTransportPair, ClientRequestDispatcher) {
        let pair = InProcessTransportPair.connected()
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry,
            routes: routes
        )
        await dispatcher.start()
        return (pair, dispatcher)
    }

    /// Bundle returned by `makeMultiClientHost`. Keeps the host-side
    /// agent + two clients together so the test body can drive each
    /// without re-deriving the wiring.
    private struct MultiClientHost {
        let agent: RepoAgent
        let watcher: MockFileWatcher
        let routes: SubscriptionTransportRoutes
        let pairA: InProcessTransportPair
        let dispatcherA: ClientRequestDispatcher
        let pairB: InProcessTransportPair
        let dispatcherB: ClientRequestDispatcher

        func stop() async {
            await dispatcherA.stop()
            await dispatcherB.stop()
            await agent.stop()
            await pairA.agentEnd.close()
            await pairB.agentEnd.close()
        }
    }

    private func makeMultiClientHost(
        root: URL,
        runner: Runner
    ) async throws -> MultiClientHost {
        let gitDir = try GitMetadataPaths.resolveGitDir(forWorktree: root)
        let watcher = MockFileWatcher()
        let registry = SubscriptionRegistry()
        let routes = SubscriptionTransportRoutes()
        let sink = RoutedBadgeEventSink(routes: routes)
        let agent = RepoAgent(
            repoRoot: root,
            gitDir: gitDir,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink,
            tickInterval: .milliseconds(20)
        )
        try await agent.start()
        let (pairA, dispatcherA) = await wireClient(registry: registry, routes: routes)
        let (pairB, dispatcherB) = await wireClient(registry: registry, routes: routes)
        return MultiClientHost(
            agent: agent,
            watcher: watcher,
            routes: routes,
            pairA: pairA,
            dispatcherA: dispatcherA,
            pairB: pairB,
            dispatcherB: dispatcherB
        )
    }

    @Test("two clients each subscribe to their own root; events route to the correct client only")
    func twoClientsRouteCorrectly() async throws {
        let (root, runner) = try await mkRepo("two-clients")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let host = try await makeMultiClientHost(root: root, runner: runner)
        defer { Task { await host.stop() } }

        // Both clients subscribe — A to the repo root (will match
        // events for its files), B to an unrelated path (will not
        // match anything). After modify, only A should receive the
        // badge event.
        let elsewhere = URL(fileURLWithPath: "/tmp/sprig-routed-elsewhere-\(UUID())")
        let reqA = Envelope<ClientRequest>(
            message: .subscribe(SubscribePayload(roots: [root.path]))
        )
        let reqB = Envelope<ClientRequest>(
            message: .subscribe(SubscribePayload(roots: [elsewhere.path]))
        )
        try await host.pairA.clientEnd.send(EnvelopeCodec.encode(reqA))
        try await host.pairB.clientEnd.send(EnvelopeCodec.encode(reqB))

        // Wait briefly for both subscriptions to ack. The first event
        // (the file change below) MUST arrive after both registrations
        // are recorded in the routes table.
        try await Task.sleep(for: .milliseconds(100))

        try write("v2\n", to: file)
        await host.watcher.emit(WatchEvent(path: file, kind: .modified))

        let resultA = try #require(
            await awaitAckAndEvent(on: host.pairA.clientEnd),
            "client A should receive both ack and event for its subscribed root"
        )
        guard case let .subscribeAck(ackPayloadA) = resultA.0.message,
              case let .badgeChanged(eventPayloadA) = resultA.1.message
        else {
            Issue.record("client A: unexpected envelope shapes")
            return
        }
        #expect(eventPayloadA.subscriptionId == ackPayloadA.subscriptionId)
        #expect(eventPayloadA.path == file.path)

        let sawEventOnB = await sawBadgeChanged(
            on: host.pairB.clientEnd,
            timeout: .milliseconds(500)
        )
        #expect(!sawEventOnB, "client B must NOT receive a badgeChanged event for client A's root")
    }

    /// Returns true if any `badgeChanged`-kind envelope arrives on
    /// `client` within `timeout`. Used by the negative assertion in
    /// `twoClientsRouteCorrectly` (client B must NOT see A's events).
    private func sawBadgeChanged(
        on client: any Transport,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await data in client.messages() {
                    guard let kind = try? EnvelopePeek.kind(of: data) else { continue }
                    if kind == "badgeChanged" { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test("envelope with an unrouted subscription id is silently dropped")
    func unroutedEnvelopeDropped() async throws {
        // Construct a router that always returns nil — no transport
        // for any id. The sink should accept the emit without
        // throwing, even though there's nowhere to send.
        let sink = RoutedBadgeEventSink(router: { _ in nil })
        let envelope = Envelope<AgentEvent>(
            message: .badgeChanged(BadgeChangedPayload(
                subscriptionId: UUID(),
                path: "/anything",
                badge: BadgeIdentifier.modified.rawValue
            ))
        )
        try await sink.emit(envelope)
        // Reaching here is the assertion: emit didn't throw despite
        // no destination transport.
    }
}
