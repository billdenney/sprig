import Foundation
@testable import IPCSchema
import Testing

@Suite("IPCSchema Envelope — encode/decode round-trip + version handling")
struct EnvelopeTests {
    private let json = JSONEncoder()
    private let decoder = JSONDecoder()

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

    // MARK: round-trip

    @Test("badgeQuery request round-trips through JSON")
    func badgeQueryRoundTrip() throws {
        let original = try Envelope(
            id: #require(UUID(uuidString: "12345678-1234-1234-1234-123456789012")),
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/repo/file.txt"))
        )
        let data = try encode(original)
        let decoded = try decode(ClientRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("subscribe request round-trips with multiple roots")
    func subscribeRoundTrip() throws {
        let original = Envelope(
            message: ClientRequest.subscribe(SubscribePayload(roots: [
                "/Users/me/projects/sprig",
                "/Users/me/work/foo"
            ]))
        )
        let data = try encode(original)
        let decoded = try decode(ClientRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("badgeReply with non-nil badge round-trips")
    func badgeReplyRoundTrip() throws {
        let original = Envelope(
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        let data = try encode(original)
        let decoded = try decode(AgentResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("badgeReply with nil badge round-trips")
    func badgeReplyNilBadge() throws {
        let original = Envelope(
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: nil))
        )
        let data = try encode(original)
        let decoded = try decode(AgentResponse.self, from: data)
        #expect(decoded == original)
        if case let .badgeReply(payload) = decoded.message {
            #expect(payload.badge == nil)
        } else {
            Issue.record("expected badgeReply, got \(decoded.message)")
        }
    }

    @Test("error response round-trips with code + message")
    func errorRoundTrip() throws {
        let original = Envelope(
            message: AgentResponse.error(ErrorPayload(
                code: "unknown_repo",
                message: "no watched repo at /tmp/foo"
            ))
        )
        let data = try encode(original)
        let decoded = try decode(AgentResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("subscribeAck round-trips with subscription id")
    func subscribeAckRoundTrip() throws {
        let original = try Envelope(
            message: AgentResponse.subscribeAck(SubscribeAckPayload(
                subscriptionId: #require(UUID(uuidString: "ABCDEFAB-1234-5678-9012-345678901234"))
            ))
        )
        let data = try encode(original)
        let decoded = try decode(AgentResponse.self, from: data)
        #expect(decoded == original)
    }

    // MARK: optional deadline

    @Test("deadline is preserved when present")
    func deadlinePresent() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let original = Envelope(
            deadline: when,
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/x"))
        )
        let data = try encode(original)
        let decoded = try decode(ClientRequest.self, from: data)
        #expect(decoded.deadline == when)
    }

    @Test("deadline absent encodes without the key, decodes as nil")
    func deadlineAbsent() throws {
        let original = Envelope(
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/x"))
        )
        let data = try encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        // The key shouldn't appear at all when deadline is nil — keeps
        // the wire format minimal.
        #expect(!json.contains("deadline"), "expected no `deadline` key in \(json)")
        let decoded = try decode(ClientRequest.self, from: data)
        #expect(decoded.deadline == nil)
    }

    // MARK: schema-version policing

    @Test("envelope rejects future schemaVersion with unsupportedSchemaVersion")
    func futureSchemaRejected() {
        let json = Data("""
        {
          "schemaVersion": 999,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "badgeQuery",
          "payload": {"path": "/x"}
        }
        """.utf8)
        #expect(throws: IPCError.self) {
            try decode(ClientRequest.self, from: json)
        }
    }

    @Test("envelope rejects schemaVersion below the minimum supported version")
    func tooOldSchemaRejected() {
        let json = Data("""
        {
          "schemaVersion": 0,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "badgeQuery",
          "payload": {"path": "/x"}
        }
        """.utf8)
        #expect(throws: IPCError.self) {
            try decode(ClientRequest.self, from: json)
        }
    }

    @Test("envelope at currentSchemaVersion decodes cleanly")
    func currentSchemaAccepted() throws {
        let json = Data("""
        {
          "schemaVersion": \(IPCSchema.currentSchemaVersion),
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "badgeQuery",
          "payload": {"path": "/x"}
        }
        """.utf8)
        let decoded = try decode(ClientRequest.self, from: json)
        #expect(decoded.schemaVersion == IPCSchema.currentSchemaVersion)
    }

    // MARK: unknown-kind forward-compat

    @Test("unknown message kind raises IPCError.unknownMessageKind")
    func unknownKindRejected() {
        let json = Data("""
        {
          "schemaVersion": 1,
          "id": "12345678-1234-1234-1234-123456789012",
          "kind": "futureKindThatDoesntExistYet",
          "payload": {"x": 1}
        }
        """.utf8)
        do {
            _ = try decode(ClientRequest.self, from: json)
            Issue.record("expected IPCError.unknownMessageKind to be thrown")
        } catch let error as IPCError {
            #expect(error == .unknownMessageKind("futureKindThatDoesntExistYet"))
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }
    }

    // MARK: wire shape sanity (regression guard)

    @Test("badgeQuery JSON has stable kind/payload shape (regression guard)")
    func wireShapeRegression() throws {
        let original = try Envelope(
            schemaVersion: 1,
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/r/f"))
        )
        let data = try encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        // Sorted keys → stable order. Confirms exact wire bytes.
        let expected = """
        {"id":"00000000-0000-0000-0000-000000000001","kind":"badgeQuery","payload":{"path":"\\/r\\/f"},"schemaVersion":1}
        """
        #expect(json == expected, "wire format drifted; got \(json)")
    }
}
