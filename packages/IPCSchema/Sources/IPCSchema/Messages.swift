// Messages.swift
//
// First-cut message types for the agent ↔ client IPC. Two enums:
//
// - `ClientRequest`: messages the shell extension / sprigctl /
//   task-window app sends to the agent.
// - `AgentResponse`: messages the agent sends back, including the
//   request's `id` so callers can correlate.
//
// We use enum + custom Codable rather than Swift's auto-derived
// enum-Codable so the JSON shape is stable and human-readable:
//
//   { "kind": "badgeQuery", "payload": { "path": "/repo/file.txt" } }
//
// Auto-derivation produces uglier shapes that change with refactors;
// custom Codable makes the wire format part of the source of truth.
//
// Adding a new message type:
//   1. Add a case here with its associated payload type.
//   2. Update `kind` (encode) and the switch in `init(from:)` (decode).
//   3. Bump no schema version — adding kinds is backward-compatible
//      (older receivers raise `IPCError.unknownMessageKind`).

import Foundation

// MARK: - ClientRequest

/// What a client (shell extension, sprigctl, task-window app) asks
/// the agent to do.
public enum ClientRequest: Sendable, Equatable {
    /// "What badge should I draw at this path?" Synchronous-shaped:
    /// extension blocks on the response (with a 50 ms p99 budget per
    /// docs/architecture/shell-integration.md). Returns a string-typed
    /// badge identifier (not a typed enum) so this package stays
    /// independent of `RepoState`.
    case badgeQuery(BadgeQueryPayload)

    /// "Tell me when badges change for paths under these roots." The
    /// agent acknowledges and starts pushing `AgentEvent.badgeChanged`
    /// events for matching paths.
    case subscribe(SubscribePayload)
}

public struct BadgeQueryPayload: Codable, Sendable, Equatable {
    /// Absolute filesystem path the client wants a badge for.
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct SubscribePayload: Codable, Sendable, Equatable {
    /// Absolute filesystem paths the client wants change notifications
    /// under (recursively). Same root may appear in multiple
    /// subscriptions; the agent dedupes.
    public var roots: [String]

    public init(roots: [String]) {
        self.roots = roots
    }
}

// MARK: - AgentResponse

/// Replies to client requests + unsolicited events.
public enum AgentResponse: Sendable, Equatable {
    /// Reply to ``ClientRequest/badgeQuery``. `badge` is nil when the
    /// path has no badge (clean / outside any watched repo). The
    /// `badge` value is the wire-stable rawValue of
    /// `RepoState.BadgeIdentifier` when non-nil.
    case badgeReply(BadgeReplyPayload)

    /// Reply to ``ClientRequest/subscribe``. The agent assigns a
    /// `subscriptionId` the client uses to cancel later.
    case subscribeAck(SubscribeAckPayload)

    /// Generic error response. Used when the agent can't service a
    /// request (unknown repo, IO error, etc.) or rejects an envelope
    /// at the parse layer.
    case error(ErrorPayload)
}

public struct BadgeReplyPayload: Codable, Sendable, Equatable {
    /// Wire-stable badge identifier. nil for clean / unbadged paths.
    public var badge: String?

    public init(badge: String?) {
        self.badge = badge
    }
}

public struct SubscribeAckPayload: Codable, Sendable, Equatable {
    public var subscriptionId: UUID

    public init(subscriptionId: UUID) {
        self.subscriptionId = subscriptionId
    }
}

public struct ErrorPayload: Codable, Sendable, Equatable {
    /// Stable error code string, e.g. `"unknown_repo"`,
    /// `"bad_path"`, `"internal"`. Wire-stable; clients pattern-match.
    public var code: String

    /// Human-readable detail. NOT stable — for logs / diagnostics
    /// only; do not pattern-match this.
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Custom Codable

private enum MessageCodingKeys: String, CodingKey {
    case kind
    case payload
}

extension ClientRequest: EnvelopeMessage {
    private enum Kind: String {
        case badgeQuery
        case subscribe
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageCodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw IPCError.unknownMessageKind(rawKind)
        }
        switch kind {
        case .badgeQuery:
            self = try .badgeQuery(container.decode(BadgeQueryPayload.self, forKey: .payload))
        case .subscribe:
            self = try .subscribe(container.decode(SubscribePayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageCodingKeys.self)
        switch self {
        case let .badgeQuery(payload):
            try container.encode(Kind.badgeQuery.rawValue, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .subscribe(payload):
            try container.encode(Kind.subscribe.rawValue, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}

extension AgentResponse: EnvelopeMessage {
    private enum Kind: String {
        case badgeReply
        case subscribeAck
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: MessageCodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw IPCError.unknownMessageKind(rawKind)
        }
        switch kind {
        case .badgeReply:
            self = try .badgeReply(container.decode(BadgeReplyPayload.self, forKey: .payload))
        case .subscribeAck:
            self = try .subscribeAck(container.decode(SubscribeAckPayload.self, forKey: .payload))
        case .error:
            self = try .error(container.decode(ErrorPayload.self, forKey: .payload))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: MessageCodingKeys.self)
        switch self {
        case let .badgeReply(payload):
            try container.encode(Kind.badgeReply.rawValue, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .subscribeAck(payload):
            try container.encode(Kind.subscribeAck.rawValue, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        case let .error(payload):
            try container.encode(Kind.error.rawValue, forKey: .kind)
            try container.encode(payload, forKey: .payload)
        }
    }
}
