// Envelope.swift
//
// The single wrapper struct every IPC message uses. Versioned so we
// can evolve the wire format without coordinated agent/extension
// upgrades, with a `kind`-discriminated payload so receivers can
// dispatch without inspecting payload shape.
//
// Per ADR 0048 §12.6:
// - schemaVersion: Int   — for forward/backward compat
// - id: UUID              — request/response correlation
// - kind: enum            — discriminator
// - payload: Codable      — message-specific body
// - deadline: Date?       — optional client-side timeout hint
//
// JSON shape (deliberately stable):
//
//   {
//     "schemaVersion": 1,
//     "id": "8C8...",
//     "kind": "badgeQuery",
//     "payload": { "path": "/repo/file.txt" },
//     "deadline": "2026-05-01T12:00:00Z"
//   }
//
// `payload` is decoded based on `kind`. Unknown kinds raise a typed
// error rather than silently dropping the envelope.

import Foundation

/// IPC envelope. `Message` is the typed message enum specific to a
/// transport direction (e.g. ``ClientRequest``, ``AgentEvent``); the
/// generic parameter lets each direction keep its own narrowed
/// `kind` set without sharing one gigantic enum.
public struct Envelope<Message: EnvelopeMessage>: Sendable, Equatable {
    /// Wire-version of this envelope. Receivers MUST check
    /// `schemaVersion` is within
    /// `[IPCSchema.minimumSupportedSchemaVersion,
    /// IPCSchema.currentSchemaVersion]` and reject otherwise.
    public var schemaVersion: Int

    /// Identifier for request/response correlation. Generated
    /// fresh per request; responses echo the request's id.
    public var id: UUID

    /// Optional client-side timeout hint. The agent uses this as a
    /// soft deadline — work in progress at the deadline is allowed
    /// to finish, but no new work starts.
    public var deadline: Date?

    /// The actual message. Carries its own `kind` discriminator
    /// when encoded.
    public var message: Message

    public init(
        schemaVersion: Int = IPCSchema.currentSchemaVersion,
        id: UUID = UUID(),
        deadline: Date? = nil,
        message: Message
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.deadline = deadline
        self.message = message
    }
}

/// A message type that knows how to encode itself with a `kind`
/// discriminator. Conforming types are usually enums where each
/// case wraps a specific request/response/event payload.
///
/// Two requirements: (1) `Codable` so the envelope can be encoded
/// alongside the message, (2) `Sendable` and `Equatable` so the
/// envelope can carry it across actor boundaries and tests can
/// compare envelopes directly.
public protocol EnvelopeMessage: Codable, Sendable, Equatable {}

// MARK: - Codable

extension Envelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case deadline
        case payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion >= IPCSchema.minimumSupportedSchemaVersion,
              schemaVersion <= IPCSchema.currentSchemaVersion
        else {
            throw IPCError.unsupportedSchemaVersion(
                got: schemaVersion,
                supported: IPCSchema.minimumSupportedSchemaVersion ... IPCSchema.currentSchemaVersion
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        // The Message type itself decodes from the *whole* envelope so
        // it can read its own `kind`/payload-shaped fields. Pass the
        // outer decoder through, not the keyed container.
        message = try Message(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        // The Message encodes its `kind` + `payload` keys directly
        // into the envelope's container.
        try message.encode(to: encoder)
    }
}

// MARK: - Errors

/// Typed errors surfaced when decoding envelopes. Used by callers
/// (the agent's IPC dispatch loop, the shell extension's response
/// reader) to distinguish "I don't know this message kind" from
/// generic decoding noise — the former is a forward-compat case
/// where we want to log and continue rather than crash.
public enum IPCError: Error, Equatable, Sendable {
    /// The envelope's `schemaVersion` is outside the receiver's
    /// supported range. `supported` carries the receiver's range
    /// at the time of decoding for diagnostic / log purposes.
    case unsupportedSchemaVersion(got: Int, supported: ClosedRange<Int>)

    /// The envelope decoded but its `kind` field names a message
    /// type the receiver doesn't know. Forward-compat case: a newer
    /// agent sending a message kind a receiver doesn't yet handle.
    case unknownMessageKind(String)
}
