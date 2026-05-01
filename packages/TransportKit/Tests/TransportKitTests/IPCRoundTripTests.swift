import Foundation
import IPCSchema
import Testing
@testable import TransportKit

/// End-to-end demo: compose `Transport` (byte transport) with
/// `IPCSchema` (Codable envelopes) for a full request-response /
/// push-event round-trip. Proves the M2 IPC chain works without any
/// platform-specific transports — `InProcessTransport` carries the
/// bytes; the encoding/decoding layer handles the rest.
///
/// **What the agent's M2 dispatch loop will look like.** This file
/// is the working blueprint: read `Data` from `transport.messages()`,
/// peek the kind to dispatch, decode the right envelope type, route
/// to a handler, encode the response, send back. The platform-
/// specific `Sources/Mac/XPCTransport.swift` etc. plug into the same
/// shape with no changes to this code.
@Suite("IPC end-to-end round-trip (Transport + IPCSchema)")
struct IPCRoundTripTests {
    /// Tiny "agent" that handles one request type and replies. Real
    /// agents will dispatch on a `RepoStateStore` query; this just
    /// echoes a deterministic response so the test is hermetic.
    private func runEchoAgent(on transport: Transport) async {
        for await data in transport.messages() {
            guard let kind = try? EnvelopePeek.kind(of: data) else { continue }

            switch kind {
            case "badgeQuery":
                guard let request = try? EnvelopeCodec.decode(ClientRequest.self, from: data),
                      case let .badgeQuery(payload) = request.message
                else { continue }
                // Mock answer: every path that ends in `.txt` is "modified",
                // everything else is unbadged.
                let badge: String? = payload.path.hasSuffix(".txt") ? "modified" : nil
                let response = Envelope(
                    id: request.id,
                    message: AgentResponse.badgeReply(BadgeReplyPayload(badge: badge))
                )
                guard let bytes = try? EnvelopeCodec.encode(response) else { continue }
                try? await transport.send(bytes)
            case "subscribe":
                guard let request = try? EnvelopeCodec.decode(ClientRequest.self, from: data) else { continue }
                let response = Envelope(
                    id: request.id,
                    message: AgentResponse.subscribeAck(SubscribeAckPayload(
                        subscriptionId: UUID()
                    ))
                )
                guard let bytes = try? EnvelopeCodec.encode(response) else { continue }
                try? await transport.send(bytes)
            default:
                continue
            }
        }
    }

    // MARK: round-trip

    @Test("client sends badgeQuery, receives matching badgeReply correlated by envelope id")
    func badgeQueryRoundTrip() async throws {
        let pair = InProcessTransportPair.connected()
        let agentTask = Task { await runEchoAgent(on: pair.agentEnd) }

        // Client side: send a request, wait for the matching reply.
        let request = Envelope(
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/repo/file.txt"))
        )
        let requestBytes = try EnvelopeCodec.encode(request)
        try await pair.clientEnd.send(requestBytes)

        var receivedReply: Envelope<AgentResponse>?
        for await responseBytes in pair.clientEnd.messages() {
            // Peek first to dispatch by message family. In a real
            // client both AgentResponse and AgentEvent share this
            // channel; here we know only responses come back.
            let kind = try EnvelopePeek.kind(of: responseBytes)
            #expect(["badgeReply", "subscribeAck", "error"].contains(kind))
            let envelope = try EnvelopeCodec.decode(AgentResponse.self, from: responseBytes)
            // Correlate by id.
            if envelope.id == request.id {
                receivedReply = envelope
                break
            }
        }

        // Tear down. Closing the client end finishes the agent's
        // `messages()` stream so the agent task exits.
        await pair.clientEnd.close()
        await agentTask.value

        let reply = try #require(receivedReply)
        if case let .badgeReply(payload) = reply.message {
            #expect(payload.badge == "modified")
        } else {
            Issue.record("expected badgeReply, got \(reply.message)")
        }
    }

    @Test("subscribe round-trip yields a subscribeAck with a fresh subscriptionId")
    func subscribeRoundTrip() async throws {
        let pair = InProcessTransportPair.connected()
        let agentTask = Task { await runEchoAgent(on: pair.agentEnd) }

        let request = Envelope(
            message: ClientRequest.subscribe(SubscribePayload(roots: ["/repo"]))
        )
        try await pair.clientEnd.send(EnvelopeCodec.encode(request))

        var ack: SubscribeAckPayload?
        for await bytes in pair.clientEnd.messages() {
            let envelope = try EnvelopeCodec.decode(AgentResponse.self, from: bytes)
            if envelope.id == request.id, case let .subscribeAck(payload) = envelope.message {
                ack = payload
                break
            }
        }

        await pair.clientEnd.close()
        await agentTask.value

        let received = try #require(ack)
        // The subscriptionId is freshly assigned by the agent; we just
        // verify it's non-nil and well-formed (UUID parsing succeeded
        // by virtue of getting here).
        _ = received.subscriptionId
    }

    @Test("multiple in-flight requests correlate by envelope id, not order")
    func parallelRequestsCorrelateById() async throws {
        let pair = InProcessTransportPair.connected()
        let agentTask = Task { await runEchoAgent(on: pair.agentEnd) }

        // Send three requests with different paths in quick succession.
        let requests = (0 ..< 3).map { i in
            Envelope(
                message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/repo/f\(i).txt"))
            )
        }
        for r in requests {
            try await pair.clientEnd.send(EnvelopeCodec.encode(r))
        }

        // Read three replies, match each by id.
        var seen: [UUID: BadgeReplyPayload] = [:]
        for await bytes in pair.clientEnd.messages() {
            let envelope = try EnvelopeCodec.decode(AgentResponse.self, from: bytes)
            if case let .badgeReply(payload) = envelope.message {
                seen[envelope.id] = payload
            }
            if seen.count == requests.count { break }
        }

        await pair.clientEnd.close()
        await agentTask.value

        // Every request got a reply with the same id.
        for r in requests {
            #expect(seen[r.id] != nil, "no reply for request \(r.id)")
        }
    }

    // MARK: agent → client push (event channel)

    @Test("agent can push AgentEvent unsolicited; client peeks and dispatches separately")
    func unsolicitedEventPush() async throws {
        let pair = InProcessTransportPair.connected()

        // Agent task: push a single badgeChanged event then exits.
        let subscriptionId = UUID()
        let agentTask = Task {
            let event = Envelope(
                message: AgentEvent.badgeChanged(BadgeChangedPayload(
                    subscriptionId: subscriptionId,
                    path: "/repo/changed.txt",
                    badge: "modified"
                ))
            )
            try? await pair.agentEnd.send(try EnvelopeCodec.encode(event))
        }

        // Client side: peek, dispatch by kind family.
        var observedEvent: BadgeChangedPayload?
        for await bytes in pair.clientEnd.messages() {
            let outer = try EnvelopePeek.outer(of: bytes)
            switch outer.kind {
            case "badgeChanged", "subscriptionEnded":
                let event = try EnvelopeCodec.decode(AgentEvent.self, from: bytes)
                if case let .badgeChanged(payload) = event.message {
                    observedEvent = payload
                }
            case "badgeReply", "subscribeAck", "error":
                Issue.record("unexpected response kind on the event path: \(outer.kind)")
            default:
                Issue.record("unknown kind: \(outer.kind)")
            }
            if observedEvent != nil { break }
        }

        await pair.clientEnd.close()
        await agentTask.value

        let event = try #require(observedEvent)
        #expect(event.subscriptionId == subscriptionId)
        #expect(event.path == "/repo/changed.txt")
        #expect(event.badge == "modified")
    }
}
