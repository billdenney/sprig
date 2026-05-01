// EnvelopeCodec.swift
//
// Pure encode/decode helpers for `Envelope<Message>` ↔ `Data`, plus
// kind-peek for mixed-message-type streams. Lives here (in
// `IPCSchema`) so callers don't have to instantiate JSON coders
// themselves; the wire format is part of the schema's contract.
//
// No `Transport` dependency: this stays in Tier 1 (IPCSchema is
// portable). Callers compose with `TransportKit` at their own layer.
//
// Wire-format invariants
// ----------------------
// - JSON, UTF-8.
// - Sorted keys for determinism (helpful for tests, log greps,
//   future signing). Production callers don't strictly need this
//   but the cost is negligible.
// - ISO-8601 dates so `deadline` is human-readable + timezone-stable.
// - One envelope per byte buffer. Multi-envelope framing (length-
//   prefixed concatenation, etc.) is the transport's responsibility.

import Foundation

/// JSON-based codec for `Envelope<Message>` byte ↔ struct conversion.
///
/// Stateless namespace; the configured `JSONEncoder`/`JSONDecoder`
/// are constructed per-call to avoid shared mutable state. Both have
/// the same configuration as the test suite expects, so the wire
/// shape is reproducible.
public enum EnvelopeCodec {
    /// Encode an envelope to JSON bytes (UTF-8). Sorted keys, ISO-8601
    /// dates.
    public static func encode(_ envelope: Envelope<some EnvelopeMessage>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// Decode an envelope from JSON bytes. Throws ``IPCError`` for
    /// known schema violations (`.unknownMessageKind`,
    /// `.schemaVersionMismatch`); other JSON-decoding errors fall
    /// through as `DecodingError`.
    public static func decode<M: EnvelopeMessage>(_: M.Type, from data: Data) throws -> Envelope<M> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope<M>.self, from: data)
    }
}

// MARK: - Mixed-stream peek

/// Inspect an envelope's outer fields (`kind`, `id`, `schemaVersion`)
/// **without** committing to a `Message` type. Lets callers dispatch
/// on `kind` before paying for full payload decode — load-bearing
/// for the client side, which receives both `AgentResponse` and
/// `AgentEvent` over the same channel.
///
/// **Why this exists:** `Envelope<Message>` is generic; decoding it
/// requires knowing `Message` upfront. The client doesn't know
/// whether an inbound buffer is a response or an event until it
/// looks. Peek the discriminator first; full decode follows the
/// dispatch.
///
/// Implementation note: peeks only at the top-level JSON keys
/// (`kind`, `id`, `schemaVersion`), so it's cheap — no payload
/// traversal.
public enum EnvelopePeek {
    /// The wire-stable `kind` discriminator (matches the rawValue of
    /// the inner enum's `Kind` cases — e.g. `"badgeQuery"`,
    /// `"badgeReply"`, `"badgeChanged"`).
    ///
    /// Throws ``IPCError/parseFailure`` if the JSON is malformed or
    /// missing the kind field.
    public static func kind(of data: Data) throws -> String {
        try outer(of: data).kind
    }

    /// The envelope's UUID. Used by the request-response correlator
    /// to match replies to outstanding requests.
    public static func id(of data: Data) throws -> UUID {
        try outer(of: data).id
    }

    /// The schema version. Receivers reject mismatches early to
    /// avoid trying to decode an envelope from a future version.
    public static func schemaVersion(of data: Data) throws -> Int {
        try outer(of: data).schemaVersion
    }

    /// Peek every top-level field at once. Cheaper than three
    /// separate calls when the caller wants more than one — they
    /// share the JSON parse.
    public static func outer(of data: Data) throws -> OuterFields {
        struct PeekShape: Decodable {
            var schemaVersion: Int
            var id: UUID
            var kind: String
        }
        let decoder = JSONDecoder()
        do {
            let peek = try decoder.decode(PeekShape.self, from: data)
            return OuterFields(
                schemaVersion: peek.schemaVersion,
                id: peek.id,
                kind: peek.kind
            )
        } catch {
            throw IPCError.parseFailure(
                description: "envelope peek failed: \(error)"
            )
        }
    }

    /// Top-level envelope fields exposed without decoding the
    /// payload.
    public struct OuterFields: Sendable, Equatable {
        public var schemaVersion: Int
        public var id: UUID
        public var kind: String

        public init(schemaVersion: Int, id: UUID, kind: String) {
            self.schemaVersion = schemaVersion
            self.id = id
            self.kind = kind
        }
    }
}
