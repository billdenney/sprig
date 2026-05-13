// WireFormatGoldenTests.swift
//
// **The v1 wire-format contract for IPCSchema.** Each test in this
// file asserts the exact bytes that `EnvelopeCodec.encode(_:)`
// produces for a known typed value (encode-direction golden) and
// that `EnvelopeCodec.decode(_:from:)` parses a known JSON string
// into the expected typed value (decode-direction golden).
//
// **Why both directions?**
// Round-trip tests (`encode then decode`) pass even if encoder and
// decoder co-evolve a breaking change in lockstep — for example, a
// field rename. Golden byte-match tests catch silent wire-format
// drift; golden decode-from-bytes tests catch silent backward-incompat
// drift (older agents talking to newer extensions or vice versa).
//
// **What's covered:** every variant of every `EnvelopeMessage`-
// conforming enum. Today: 2 `ClientRequest` cases, 3 `AgentResponse`
// cases, 2 `AgentEvent` cases. Adding a new case to any of these
// enums MUST add both an encode-golden and a decode-golden test here,
// in the same PR that adds the case. **If you're editing this file
// to change an existing assertion's `expected` string, you're changing
// the wire format** — bump `IPCSchema.currentSchemaVersion` and ratify
// the change via an ADR.
//
// JSON encoding policy: keys sorted (`outputFormatting: [.sortedKeys]`),
// no pretty-print, ISO-8601 dates. Matches `EnvelopeCodec`'s
// production encoder. The forward-slash escaping (`\/`) in path
// strings is Foundation's default for JSONEncoder — not a bug;
// stable across platforms.
//
// See `packages/IPCSchema/STABILITY.md` for the version-bump policy.

import Foundation
@testable import IPCSchema
import Testing

@Suite("IPCSchema — v1 wire-format golden tests (encode and decode)")
struct WireFormatGoldenTests {
    private func uuid(_ s: String) throws -> UUID {
        try #require(UUID(uuidString: s))
    }

    // Deterministic IDs so the expected bytes don't move per run.
    private static let envelopeID = "00000000-0000-0000-0000-000000000001"
    private static let subscriptionID = "00000000-0000-0000-0000-000000000002"

    // MARK: - ClientRequest

    @Test("encode golden: ClientRequest.badgeQuery → exact bytes")
    func encodeGoldenBadgeQuery() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/r/f"))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"badgeQuery","payload":{"path":"\\/r\\/f"},"schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: ClientRequest.badgeQuery JSON → typed envelope")
    func decodeGoldenBadgeQuery() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"badgeQuery","payload":{"path":"\\/r\\/f"},"schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(ClientRequest.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: ClientRequest.badgeQuery(BadgeQueryPayload(path: "/r/f"))
        )
        #expect(decoded == expected)
    }

    @Test("encode golden: ClientRequest.subscribe → exact bytes")
    func encodeGoldenSubscribe() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: ClientRequest.subscribe(SubscribePayload(roots: ["/a", "/b"]))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"subscribe","payload":{"roots":["\\/a","\\/b"]},"schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: ClientRequest.subscribe JSON → typed envelope")
    func decodeGoldenSubscribe() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"subscribe","payload":{"roots":["\\/a","\\/b"]},"schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(ClientRequest.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: ClientRequest.subscribe(SubscribePayload(roots: ["/a", "/b"]))
        )
        #expect(decoded == expected)
    }

    // MARK: - AgentResponse

    @Test("encode golden: AgentResponse.badgeReply (non-nil badge) → exact bytes")
    func encodeGoldenBadgeReplyNonNil() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"badgeReply","payload":{"badge":"modified"},"schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: AgentResponse.badgeReply (non-nil badge) JSON → typed envelope")
    func decodeGoldenBadgeReplyNonNil() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"badgeReply","payload":{"badge":"modified"},"schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(AgentResponse.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.badgeReply(BadgeReplyPayload(badge: "modified"))
        )
        #expect(decoded == expected)
    }

    @Test("encode golden: AgentResponse.subscribeAck → exact bytes")
    func encodeGoldenSubscribeAck() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.subscribeAck(
                SubscribeAckPayload(subscriptionId: uuid(Self.subscriptionID))
            )
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"subscribeAck","payload":{"subscriptionId":"\(Self.subscriptionID)"},"schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: AgentResponse.subscribeAck JSON → typed envelope")
    func decodeGoldenSubscribeAck() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"subscribeAck","payload":{"subscriptionId":"\(Self.subscriptionID)"},"schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(AgentResponse.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.subscribeAck(
                SubscribeAckPayload(subscriptionId: uuid(Self.subscriptionID))
            )
        )
        #expect(decoded == expected)
    }

    @Test("encode golden: AgentResponse.error → exact bytes")
    func encodeGoldenError() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.error(ErrorPayload(
                code: "unknown_repo",
                message: "no such repo"
            ))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"error","payload":{"code":"unknown_repo","message":"no such repo"},"schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: AgentResponse.error JSON → typed envelope")
    func decodeGoldenError() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"error","payload":{"code":"unknown_repo","message":"no such repo"},"schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(AgentResponse.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentResponse.error(ErrorPayload(
                code: "unknown_repo",
                message: "no such repo"
            ))
        )
        #expect(decoded == expected)
    }

    // MARK: - AgentEvent

    @Test("encode golden: AgentEvent.badgeChanged (non-nil badge) → exact bytes")
    func encodeGoldenBadgeChanged() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid(Self.subscriptionID),
                path: "/r/f",
                badge: "modified"
            ))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"badgeChanged",\
        "payload":{"badge":"modified","path":"\\/r\\/f","subscriptionId":"\(Self.subscriptionID)"},\
        "schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: AgentEvent.badgeChanged JSON → typed envelope")
    func decodeGoldenBadgeChanged() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"badgeChanged",\
        "payload":{"badge":"modified","path":"\\/r\\/f","subscriptionId":"\(Self.subscriptionID)"},\
        "schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(AgentEvent.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentEvent.badgeChanged(BadgeChangedPayload(
                subscriptionId: uuid(Self.subscriptionID),
                path: "/r/f",
                badge: "modified"
            ))
        )
        #expect(decoded == expected)
    }

    @Test("encode golden: AgentEvent.subscriptionEnded → exact bytes")
    func encodeGoldenSubscriptionEnded() throws {
        let envelope = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentEvent.subscriptionEnded(SubscriptionEndedPayload(
                subscriptionId: uuid(Self.subscriptionID),
                reason: "agent_shutdown"
            ))
        )
        let data = try EnvelopeCodec.encode(envelope)
        let actual = try #require(String(data: data, encoding: .utf8))
        let expected = """
        {"id":"\(Self.envelopeID)","kind":"subscriptionEnded",\
        "payload":{"reason":"agent_shutdown","subscriptionId":"\(Self.subscriptionID)"},\
        "schemaVersion":1}
        """
        #expect(actual == expected, "wire format drifted; got \(actual)")
    }

    @Test("decode golden: AgentEvent.subscriptionEnded JSON → typed envelope")
    func decodeGoldenSubscriptionEnded() throws {
        let goldenJSON = Data("""
        {"id":"\(Self.envelopeID)","kind":"subscriptionEnded",\
        "payload":{"reason":"agent_shutdown","subscriptionId":"\(Self.subscriptionID)"},\
        "schemaVersion":1}
        """.utf8)
        let decoded = try EnvelopeCodec.decode(AgentEvent.self, from: goldenJSON)
        let expected = try Envelope(
            schemaVersion: 1,
            id: uuid(Self.envelopeID),
            message: AgentEvent.subscriptionEnded(SubscriptionEndedPayload(
                subscriptionId: uuid(Self.subscriptionID),
                reason: "agent_shutdown"
            ))
        )
        #expect(decoded == expected)
    }
}
