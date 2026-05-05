// ClientRequestDispatcherTests.swift
//
// End-to-end tests for the inbound IPC half: a client end of an
// `InProcessTransport` sends `Envelope<ClientRequest>` envelopes; the
// dispatcher (on the agent end) decodes, dispatches, and writes
// `Envelope<AgentResponse>` envelopes back. The client-side test
// peeks the envelope kind to distinguish replies from any
// concurrently-arriving events (slice A2 territory).
//
// The dispatcher's contract is wire-format-only — the registry it
// manipulates is a real `SubscriptionRegistry`, but no `git status`
// or watcher work happens here. Pure IPC round-trips.

@testable import AgentKit
import Foundation
import IPCSchema
import RepoState
import Testing
import TransportKit

@Suite("ClientRequestDispatcher — inbound ClientRequest → AgentResponse over Transport")
struct ClientRequestDispatcherTests {
    /// Wait up to `timeout` for the next decoded `AgentResponse`
    /// envelope on `client`. Returns nil on timeout.
    private func awaitResponse(
        on client: any Transport,
        timeout: Duration = .seconds(2)
    ) async -> Envelope<AgentResponse>? {
        await withTaskGroup(of: Envelope<AgentResponse>?.self) { group in
            group.addTask {
                for await data in client.messages() {
                    guard let envelope = try? EnvelopeCodec.decode(
                        AgentResponse.self,
                        from: data
                    ) else { continue }
                    return envelope
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

    // MARK: subscribe

    @Test("subscribe → subscribeAck round-trip; registry records the new subscription")
    func subscribeRoundTrip() async throws {
        let pair = InProcessTransportPair.connected()
        let registry = SubscriptionRegistry()
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry
        )
        await dispatcher.start()
        defer {
            Task {
                await dispatcher.stop()
                await pair.agentEnd.close()
            }
        }

        let request = Envelope<ClientRequest>(
            message: .subscribe(SubscribePayload(roots: ["/some/repo/root"]))
        )
        try await pair.clientEnd.send(EnvelopeCodec.encode(request))

        let response = try #require(
            await awaitResponse(on: pair.clientEnd),
            "expected a subscribeAck envelope"
        )
        #expect(response.id == request.id, "response should echo the request id for correlation")
        guard case let .subscribeAck(payload) = response.message else {
            Issue.record("expected .subscribeAck, got \(response.message)")
            return
        }
        // Registry should now have a matching subscription for the root.
        let root = URL(fileURLWithPath: "/some/repo/root")
        let matching = await registry.matchingSubscriptions(for: root)
        #expect(matching.contains(payload.subscriptionId), "registry must contain the assigned id")
    }

    // MARK: badgeQuery

    @Test("badgeQuery → badgeReply uses the resolver to answer")
    func badgeQueryRoundTrip() async throws {
        let pair = InProcessTransportPair.connected()
        let registry = SubscriptionRegistry()
        // Resolver returns a fixed badge regardless of path so the
        // assertion is deterministic.
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry,
            badgeResolver: { _ in BadgeIdentifier.modified.rawValue }
        )
        await dispatcher.start()
        defer {
            Task {
                await dispatcher.stop()
                await pair.agentEnd.close()
            }
        }

        let request = Envelope<ClientRequest>(
            message: .badgeQuery(BadgeQueryPayload(path: "/some/repo/file.txt"))
        )
        try await pair.clientEnd.send(EnvelopeCodec.encode(request))

        let response = try #require(
            await awaitResponse(on: pair.clientEnd),
            "expected a badgeReply envelope"
        )
        #expect(response.id == request.id)
        guard case let .badgeReply(payload) = response.message else {
            Issue.record("expected .badgeReply, got \(response.message)")
            return
        }
        #expect(payload.badge == BadgeIdentifier.modified.rawValue)
    }

    @Test("badgeQuery with no resolver returns nil badge (default behavior)")
    func badgeQueryDefaultResolverReturnsNil() async throws {
        let pair = InProcessTransportPair.connected()
        let registry = SubscriptionRegistry()
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry
        )
        await dispatcher.start()
        defer {
            Task {
                await dispatcher.stop()
                await pair.agentEnd.close()
            }
        }

        let request = Envelope<ClientRequest>(
            message: .badgeQuery(BadgeQueryPayload(path: "/anything"))
        )
        try await pair.clientEnd.send(EnvelopeCodec.encode(request))

        let response = try #require(
            await awaitResponse(on: pair.clientEnd),
            "expected a badgeReply envelope"
        )
        guard case let .badgeReply(payload) = response.message else {
            Issue.record("expected .badgeReply, got \(response.message)")
            return
        }
        #expect(payload.badge == nil, "default resolver returns nil")
    }

    // MARK: error path

    @Test("malformed envelope produces an error response with a wire-stable code")
    func malformedEnvelopeProducesErrorResponse() async throws {
        let pair = InProcessTransportPair.connected()
        let registry = SubscriptionRegistry()
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry
        )
        await dispatcher.start()
        defer {
            Task {
                await dispatcher.stop()
                await pair.agentEnd.close()
            }
        }

        // Hand-rolled JSON with a kind the schema doesn't know. The
        // outer envelope shape is otherwise valid so the peek of `id`
        // succeeds and the response can echo it.
        let knownId = UUID()
        let badJSON: [String: Any] = [
            "schemaVersion": IPCSchema.currentSchemaVersion,
            "id": knownId.uuidString,
            "kind": "noSuchKind",
            "payload": [String: String]()
        ]
        let badData = try JSONSerialization.data(withJSONObject: badJSON, options: [.sortedKeys])
        try await pair.clientEnd.send(badData)

        let response = try #require(
            await awaitResponse(on: pair.clientEnd),
            "expected an error envelope"
        )
        #expect(response.id == knownId, "error envelope must echo the request id when peekable")
        guard case let .error(payload) = response.message else {
            Issue.record("expected .error, got \(response.message)")
            return
        }
        #expect(payload.code == "unknown_message_kind", "error code must be wire-stable")
    }

    // MARK: lifecycle

    @Test("stop() cancels the receive loop without affecting the registry")
    func stopShutsDownCleanly() async throws {
        let pair = InProcessTransportPair.connected()
        let registry = SubscriptionRegistry()
        let dispatcher = ClientRequestDispatcher(
            transport: pair.agentEnd,
            registry: registry
        )
        await dispatcher.start()

        // Subscribe once so the registry has state we can inspect after stop.
        let request = Envelope<ClientRequest>(
            message: .subscribe(SubscribePayload(roots: ["/x"]))
        )
        try await pair.clientEnd.send(EnvelopeCodec.encode(request))
        let response = try #require(
            await awaitResponse(on: pair.clientEnd),
            "subscribe must ack before stop()"
        )
        guard case let .subscribeAck(payload) = response.message else {
            Issue.record("expected ack, got \(response.message)")
            return
        }

        await dispatcher.stop()
        // Registry retains the subscription — stop() doesn't unsubscribe.
        let matching = await registry.matchingSubscriptions(for: URL(fileURLWithPath: "/x"))
        #expect(matching.contains(payload.subscriptionId))

        await pair.agentEnd.close()
    }
}
