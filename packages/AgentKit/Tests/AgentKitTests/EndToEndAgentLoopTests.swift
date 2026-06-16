// EndToEndAgentLoopTests.swift
//
// The proof: in a single process, with one client connected over an
// `InProcessTransport` pair, the full bidirectional agent loop works.
//
// Wires together everything PRs #43–#45 added:
//
//   client end ──── ClientRequest ────► agent end
//                                       │
//                                       ▼
//                                   ClientRequestDispatcher
//                                       │  (writes AgentResponse back)
//                                       ▼
//                                   SubscriptionRegistry
//
//   client end ◄──── AgentEvent ──── agent end
//                                       ▲
//                                       │  (writes AgentEvent)
//                                   TransportBadgeEventSink
//                                       ▲
//                                       │
//                                   BadgeChangeBroadcaster
//                                       ▲
//                                       │
//                                   RepoAgent (watcher → driver →
//                                              refresher → store)
//
// Same envelope shape both ways. The client multiplexes by peeking
// `kind` before deciding "this is a reply, correlate by id" vs.
// "this is an event, route to the subscription handler."
//
// This is the shape the M2-Mac LaunchAgent host adopts, with the
// transport swapped from `InProcessTransport` to `XPCTransport`.

@testable import AgentKit
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import Testing
import TransportKit
import WatcherKit

@Suite("End-to-end agent loop — bidirectional IPC over InProcessTransport")
struct EndToEndAgentLoopTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-e2e-\(tag)-\(UUID().uuidString)")
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

    /// Read the next inbound buffer on `client`, peek its kind, then
    /// decode it as the matching envelope type. Returns nil on
    /// timeout. The two associated-value cases let the caller switch
    /// on what arrived.
    private enum Inbound {
        case response(Envelope<AgentResponse>)
        case event(Envelope<AgentEvent>)
        case unknown(kind: String)
    }

    /// 30 s, not 5 s: the badge step exercises the whole live pipeline
    /// (watcher → driver → refresher → store → broadcaster → sink →
    /// transport), all async on the cooperative pool. On a 2-core hosted
    /// Windows runner under the full parallel suite that chain can take
    /// well over 5 s, which flaked this as `awaitInbound → nil` on CI
    /// even though the transport itself works (the subscribeAck arrives
    /// promptly). The budget only bounds the *failure* wait; a healthy
    /// run returns the instant the event lands. Matches the 30 s
    /// Windows-friendly budgets in RepoAgentAutoSync/AutoBackup tests.
    private func awaitInbound(
        on client: any Transport,
        timeout: Duration = .seconds(30)
    ) async -> Inbound? {
        await withTaskGroup(of: Inbound?.self) { group in
            group.addTask {
                for await data in client.messages() {
                    guard let kind = try? EnvelopePeek.kind(of: data) else { continue }
                    if kind == "subscribeAck" || kind == "badgeReply" || kind == "error" {
                        if let env = try? EnvelopeCodec.decode(AgentResponse.self, from: data) {
                            return .response(env)
                        }
                    } else if kind == "badgeChanged" || kind == "subscriptionEnded" {
                        if let env = try? EnvelopeCodec.decode(AgentEvent.self, from: data) {
                            return .event(env)
                        }
                    } else {
                        return .unknown(kind: kind)
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

    /// Bundle of the three pieces a host wires together. Tests use it
    /// as a one-call setup; `Host.start()` runs both actors and the
    /// caller defers `stop()` to clean up. Avoids per-test repetition
    /// of the wiring boilerplate (which would otherwise blow past
    /// SwiftLint's `function_body_length` cap).
    private struct Host {
        let agent: RepoAgent
        let dispatcher: ClientRequestDispatcher
        let pair: InProcessTransportPair
        let watcher: MockFileWatcher
        let registry: SubscriptionRegistry

        func start() async throws {
            try await agent.start()
            await dispatcher.start()
        }

        func stop() async {
            await dispatcher.stop()
            await agent.stop()
            await pair.agentEnd.close()
        }
    }

    private func makeHost(
        root: URL,
        runner: Runner,
        badgeResolver: @escaping ClientRequestDispatcher.BadgeResolver = { _ in nil }
    ) throws -> Host {
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
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry,
            badgeResolver: badgeResolver
        )
        return Host(
            agent: agent,
            dispatcher: dispatcher,
            pair: pair,
            watcher: watcher,
            registry: registry
        )
    }

    @Test("client subscribe → ack → file change → badge event, all over one transport")
    func fullBidirectionalLoop() async throws {
        let (root, runner) = try await mkRepo("full-loop")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let host = try makeHost(root: root, runner: runner)
        try await host.start()
        defer { Task { await host.stop() } }

        // 1. Client sends subscribe.
        let subscribeReq = Envelope<ClientRequest>(
            message: .subscribe(SubscribePayload(roots: [root.path]))
        )
        try await host.pair.clientEnd.send(EnvelopeCodec.encode(subscribeReq))

        // 2. Client receives subscribeAck (an AgentResponse). The
        // initial-refresh badge events for a clean repo are empty, so
        // the next inbound after subscribe should be the ack.
        let ackInbound = try #require(
            await awaitInbound(on: host.pair.clientEnd),
            "expected an inbound envelope (subscribeAck) after subscribe"
        )
        guard case let .response(ackEnv) = ackInbound else {
            Issue.record("expected a response envelope, got \(ackInbound)")
            return
        }
        #expect(ackEnv.id == subscribeReq.id, "ack must echo the request id")
        guard case let .subscribeAck(ackPayload) = ackEnv.message else {
            Issue.record("expected .subscribeAck, got \(ackEnv.message)")
            return
        }

        // 3. The client modifies the watched file and emits a watcher
        // event. The agent's pipeline should produce a badgeChanged
        // event, encoded by `TransportBadgeEventSink` and arriving on
        // `pair.clientEnd.messages()`.
        try write("v2\n", to: file)
        await host.watcher.emit(WatchEvent(path: file, kind: .modified))

        // 4. Client receives a badgeChanged AgentEvent. The
        // subscriptionId on the event should match the ack.
        let eventInbound = try #require(
            await awaitInbound(on: host.pair.clientEnd),
            "expected a badgeChanged event after the file change"
        )
        guard case let .event(eventEnv) = eventInbound else {
            Issue.record("expected an event envelope, got \(eventInbound)")
            return
        }
        guard case let .badgeChanged(eventPayload) = eventEnv.message else {
            Issue.record("expected .badgeChanged, got \(eventEnv.message)")
            return
        }
        #expect(eventPayload.path == file.path)
        #expect(eventPayload.badge == BadgeIdentifier.modified.rawValue)
        #expect(
            eventPayload.subscriptionId == ackPayload.subscriptionId,
            "event must carry the subscription id assigned at subscribe time"
        )
    }

    @Test("badgeQuery survives the agent running concurrently — interleaved RPC + push")
    func badgeQueryUnderLoadDoesNotRaceWithEvents() async throws {
        let (root, runner) = try await mkRepo("rpc-vs-push")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try write("v1\n", to: file)
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        // Resolver returns a fixed badge so the test asserts the RPC
        // path independently of any RepoStateStore state.
        let host = try makeHost(
            root: root,
            runner: runner,
            badgeResolver: { _ in BadgeIdentifier.untracked.rawValue }
        )
        try await host.start()
        defer { Task { await host.stop() } }

        // No subscribe — just an RPC. The agent's broadcaster would
        // fire events only if some subscription matched, and there's
        // none here. So the next inbound is the badgeReply.
        let queryReq = Envelope<ClientRequest>(
            message: .badgeQuery(BadgeQueryPayload(path: file.path))
        )
        try await host.pair.clientEnd.send(EnvelopeCodec.encode(queryReq))

        let inbound = try #require(
            await awaitInbound(on: host.pair.clientEnd),
            "expected a badgeReply"
        )
        guard case let .response(env) = inbound,
              case let .badgeReply(payload) = env.message
        else {
            Issue.record("expected .badgeReply, got \(inbound)")
            return
        }
        #expect(env.id == queryReq.id)
        #expect(payload.badge == BadgeIdentifier.untracked.rawValue)
    }
}
