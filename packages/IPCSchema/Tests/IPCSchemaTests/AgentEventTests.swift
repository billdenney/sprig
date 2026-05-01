import Foundation
@testable import IPCSchema
import Testing

@Suite("IPCSchema AgentEvent — push messages")
struct AgentEventTests {
    private func encode(_ envelope: Envelope<some EnvelopeMessage>) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(envelope)
    }

    private func decode<M: EnvelopeMessage>(_: M.Type, from data: Data) throws -> Envelope<M> {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Envelope<M>.self, from: data)
    }

    private func uuid(_ s: String) throws -> UUID {
        try #require(UUID(uuidString: s))
    }

    // MARK: round-trip — badgeChanged

    @Test("badgeChanged with non-nil badge round-trips")
    func badgeChangedRoundTrip() throws {
        let original = try Envelope(
            id: uuid("12345678-1234-1234-1234-123456789012"),
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid("ABCDEFAB-1234-5678-9012-345678901234"),
                path: "/repo/file.txt",
                badge: "modified"
            ))
        )
        let data = try encode(original)
        let decoded = try decode(AgentEvent.self, from: data)
        #expect(decoded == original)
    }

    @Test("badgeChanged with nil badge (now-clean) round-trips")
    func badgeChangedNilBadge() throws {
        let original = try Envelope(
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid("ABCDEFAB-1234-5678-9012-345678901234"),
                path: "/repo/file.txt",
                badge: nil
            ))
        )
        let data = try encode(original)
        let decoded = try decode(AgentEvent.self, from: data)
        #expect(decoded == original)
        if case let .badgeChanged(payload) = decoded.message {
            #expect(payload.badge == nil)
        } else {
            Issue.record("expected badgeChanged, got \(decoded.message)")
        }
    }

    // MARK: round-trip — subscriptionEnded

    @Test("subscriptionEnded round-trips with reason code")
    func subscriptionEndedRoundTrip() throws {
        let original = try Envelope(
            message: AgentEvent.subscriptionEnded(SubscriptionEndedPayload(
                subscriptionId: uuid("ABCDEFAB-1234-5678-9012-345678901234"),
                reason: "agent_shutdown"
            ))
        )
        let data = try encode(original)
        let decoded = try decode(AgentEvent.self, from: data)
        #expect(decoded == original)
    }

    // MARK: forward-compat

    @Test("unknown event kind raises IPCError.unknownMessageKind")
    func unknownEventKindRejected() {
        let json = Data("""
        {
          "schemaVersion": 1,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "futureEventKind",
          "payload": {"x": 1}
        }
        """.utf8)
        do {
            _ = try decode(AgentEvent.self, from: json)
            Issue.record("expected IPCError.unknownMessageKind to be thrown")
        } catch let error as IPCError {
            #expect(error == .unknownMessageKind("futureEventKind"))
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }
    }

    // MARK: kind-namespace independence

    @Test("AgentEvent kinds don't collide with AgentResponse kinds")
    func kindNamespacesAreDistinct() throws {
        // Decoding a `badgeReply` (AgentResponse) shape as AgentEvent
        // should fail with unknownMessageKind — events and responses
        // share the wire transport but not the kind namespace.
        let badgeReplyJson = Data("""
        {
          "schemaVersion": 1,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "badgeReply",
          "payload": {"badge": "modified"}
        }
        """.utf8)
        do {
            _ = try decode(AgentEvent.self, from: badgeReplyJson)
            Issue.record("expected AgentEvent decoder to reject `badgeReply` kind")
        } catch let error as IPCError {
            #expect(error == .unknownMessageKind("badgeReply"))
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }

        // And vice versa: badgeChanged shouldn't decode as AgentResponse.
        let badgeChangedJson = Data("""
        {
          "schemaVersion": 1,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "badgeChanged",
          "payload": {
            "subscriptionId": "ABCDEFAB-1234-5678-9012-345678901234",
            "path": "/x",
            "badge": "modified"
          }
        }
        """.utf8)
        do {
            _ = try decode(AgentResponse.self, from: badgeChangedJson)
            Issue.record("expected AgentResponse decoder to reject `badgeChanged` kind")
        } catch let error as IPCError {
            #expect(error == .unknownMessageKind("badgeChanged"))
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }
    }

    // MARK: wire shape sanity (regression guard)

    @Test("badgeChanged JSON has stable kind/payload shape (regression guard)")
    func wireShapeRegression() throws {
        let original = try Envelope(
            schemaVersion: 1,
            id: uuid("00000000-0000-0000-0000-000000000001"),
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid("00000000-0000-0000-0000-000000000002"),
                path: "/r/f",
                badge: "modified"
            ))
        )
        let data = try encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        let expected = """
        {"id":"00000000-0000-0000-0000-000000000001","kind":"badgeChanged",\
        "payload":{"badge":"modified","path":"\\/r\\/f","subscriptionId":"00000000-0000-0000-0000-000000000002"},\
        "schemaVersion":1}
        """
        #expect(json == expected, "wire format drifted; got \(json)")
    }
}
