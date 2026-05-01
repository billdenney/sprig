import Foundation
@testable import IPCSchema
import Testing

@Suite("EnvelopeCodec — JSON encode/decode + peek")
struct EnvelopeCodecTests {
    private func uuid(_ s: String) throws -> UUID {
        try #require(UUID(uuidString: s))
    }

    // MARK: full encode + decode round-trip

    @Test("encode + decode round-trips a ClientRequest envelope")
    func roundTripClientRequest() throws {
        let original = try Envelope(
            id: uuid("12345678-1234-1234-1234-123456789012"),
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/repo/file.txt"))
        )
        let data = try EnvelopeCodec.encode(original)
        let decoded = try EnvelopeCodec.decode(ClientRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("encode + decode round-trips an AgentResponse envelope")
    func roundTripAgentResponse() throws {
        let original = try Envelope(
            id: uuid("ABCDEFAB-1234-5678-9012-345678901234"),
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        let data = try EnvelopeCodec.encode(original)
        let decoded = try EnvelopeCodec.decode(AgentResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("encode + decode round-trips an AgentEvent envelope")
    func roundTripAgentEvent() throws {
        let original = try Envelope(
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid("11111111-2222-3333-4444-555555555555"),
                path: "/repo/x.txt",
                badge: nil
            ))
        )
        let data = try EnvelopeCodec.encode(original)
        let decoded = try EnvelopeCodec.decode(AgentEvent.self, from: data)
        #expect(decoded == original)
    }

    @Test("encoded bytes are valid UTF-8 JSON")
    func encodedBytesAreUTF8() throws {
        let envelope = try Envelope(
            message: ClientRequest.subscribe(SubscribePayload(roots: ["/a", "/b"]))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.hasPrefix("{"))
        #expect(json.hasSuffix("}"))
        #expect(json.contains("\"kind\":\"subscribe\""))
    }

    // MARK: peek (without payload decode)

    @Test("peek extracts kind without committing to a Message type")
    func peekKindFromBadgeReply() throws {
        let envelope = try Envelope(
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        let data = try EnvelopeCodec.encode(envelope)
        #expect(try EnvelopePeek.kind(of: data) == "badgeReply")
    }

    @Test("peek extracts kind for an AgentEvent")
    func peekKindFromBadgeChanged() throws {
        let envelope = try Envelope(
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: UUID(),
                path: "/r/f",
                badge: "untracked"
            ))
        )
        let data = try EnvelopeCodec.encode(envelope)
        #expect(try EnvelopePeek.kind(of: data) == "badgeChanged")
    }

    @Test("peek extracts id (for request-response correlation)")
    func peekId() throws {
        let want = try uuid("DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")
        let envelope = try Envelope(
            id: want,
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: nil))
        )
        let data = try EnvelopeCodec.encode(envelope)
        #expect(try EnvelopePeek.id(of: data) == want)
    }

    @Test("peek extracts schemaVersion")
    func peekSchemaVersion() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/f"))
        )
        let data = try EnvelopeCodec.encode(envelope)
        #expect(try EnvelopePeek.schemaVersion(of: data) == 1)
    }

    @Test("peek.outer extracts all three fields in one parse")
    func peekOuter() throws {
        let id = try uuid("12345678-1234-1234-1234-123456789012")
        let envelope = try Envelope(
            id: id,
            message: ClientRequest.subscribe(SubscribePayload(roots: ["/r"]))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let outer = try EnvelopePeek.outer(of: data)
        #expect(outer.id == id)
        #expect(outer.kind == "subscribe")
        #expect(outer.schemaVersion == 1)
    }

    // MARK: peek-then-dispatch (the load-bearing pattern)

    @Test("typical client-side dispatch: peek the kind, route to AgentResponse vs AgentEvent decoder")
    func peekThenDispatch() throws {
        // Two envelopes the client might receive over the same channel:
        let response = try Envelope(
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        let event = try Envelope(
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: UUID(),
                path: "/r/f",
                badge: "modified"
            ))
        )
        let responseBytes = try EnvelopeCodec.encode(response)
        let eventBytes = try EnvelopeCodec.encode(event)

        // Client's dispatch: peek, then decode.
        let responseKind = try EnvelopePeek.kind(of: responseBytes)
        let eventKind = try EnvelopePeek.kind(of: eventBytes)

        // Response kinds: badgeReply, subscribeAck, error
        // Event kinds: badgeChanged, subscriptionEnded
        let responseKindSet: Set = ["badgeReply", "subscribeAck", "error"]
        let eventKindSet: Set = ["badgeChanged", "subscriptionEnded"]

        #expect(responseKindSet.contains(responseKind))
        let decodedResponse = try EnvelopeCodec.decode(AgentResponse.self, from: responseBytes)
        #expect(decodedResponse == response)

        #expect(eventKindSet.contains(eventKind))
        let decodedEvent = try EnvelopeCodec.decode(AgentEvent.self, from: eventBytes)
        #expect(decodedEvent == event)
    }

    // MARK: error paths

    @Test("peek of malformed bytes throws IPCError.parseFailure")
    func peekMalformedThrowsParseFailure() {
        let bogus = Data("not json".utf8)
        do {
            _ = try EnvelopePeek.kind(of: bogus)
            Issue.record("expected parseFailure")
        } catch let error as IPCError {
            if case .parseFailure = error {
                // expected
            } else {
                Issue.record("expected .parseFailure, got \(error)")
            }
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }
    }

    @Test("peek of valid JSON missing the kind field throws parseFailure")
    func peekMissingKindField() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "id": "12345678-1234-1234-1234-123456789012",
          "payload": {}
        }
        """.utf8)
        do {
            _ = try EnvelopePeek.kind(of: json)
            Issue.record("expected parseFailure")
        } catch let error as IPCError {
            if case .parseFailure = error {
                // expected
            } else {
                Issue.record("expected .parseFailure, got \(error)")
            }
        } catch {
            Issue.record("expected IPCError, got \(error)")
        }
    }

    @Test("decode of malformed bytes throws (DecodingError, not IPCError)")
    func decodeMalformedThrows() {
        let bogus = Data("not json".utf8)
        do {
            _ = try EnvelopeCodec.decode(ClientRequest.self, from: bogus)
            Issue.record("expected throw")
        } catch {
            // DecodingError is fine — we don't promise IPCError here
            // because the schema-failure cases (unknownMessageKind,
            // unsupportedSchemaVersion) already use IPCError; raw
            // JSON failures fall through to Foundation.
        }
    }
}
