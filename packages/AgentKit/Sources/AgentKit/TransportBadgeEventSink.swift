// TransportBadgeEventSink.swift
//
// `BadgeEventSink` impl that wraps a `TransportKit.Transport` and
// `IPCSchema.EnvelopeCodec`: every emitted envelope is JSON-encoded
// and sent over the wire. The companion to `InMemoryBadgeEventSink` —
// same shape, real wire bytes instead of an in-process AsyncStream.
//
// What this enables
// -----------------
// `RepoAgent` constructed with this sink fans `AgentEvent` envelopes
// through whatever transport is plumbed in. With
// `InProcessTransport.connected()` you get a same-process round-trip
// for tests and CLIs that want both ends. With `TransportKit/Mac/`
// XPC (M2-Mac scope), you get a real cross-process FinderSync ↔
// SprigAgent connection. With `TransportKit/Windows/` named pipes
// (M2-Win scope), the same wiring works for the Explorer extension.
//
// Tier 2. Deps: Foundation + IPCSchema + RepoState (`BadgeEventSink`)
// + TransportKit (`Transport`). No platform APIs.

import Foundation
import IPCSchema
import RepoState
import TransportKit

/// Wire-bound `BadgeEventSink`. Encodes each emitted envelope and
/// forwards the bytes via the configured ``Transport``.
///
/// **Failure surface.** ``emit(_:)`` rethrows whatever the encoder or
/// the transport throws:
/// - `TransportError.peerClosed` / `.closed` — the peer (or this end)
///   is gone. The `BadgeChangeBroadcaster` counts this as a failed
///   emit and continues with the next subscriber, so a single dead
///   connection doesn't take down the broadcast.
/// - `TransportError.sendFailed(reason:)` — transport-specific. Same
///   per-subscriber isolation by the broadcaster.
/// - Encoding errors (`EncodingError`) — these mean the envelope is
///   structurally invalid for JSON. They're a Sprig-side bug, not a
///   peer condition; the broadcaster's "log + continue" path is still
///   the right thing to do, but a follow-up should add structured
///   logging here.
///
/// **Sendable.** The struct itself is trivial-`Sendable` because
/// `Transport` requires `Sendable`. Callers may share one sink across
/// the broadcaster's per-emit fan-out; the underlying transport
/// serializes if needed.
///
/// **One sink per subscriber-set, not per subscription.** The same
/// `Transport` typically carries every event for every subscription
/// the connected peer holds. The broadcaster identifies the target
/// subscription via the envelope's `BadgeChangedPayload.subscriptionId`,
/// so a single transport can fan out to the peer's many subscriptions
/// without per-subscription transport instances.
public struct TransportBadgeEventSink: BadgeEventSink {
    private let transport: any Transport

    public init(transport: any Transport) {
        self.transport = transport
    }

    public func emit(_ envelope: Envelope<AgentEvent>) async throws {
        let data = try EnvelopeCodec.encode(envelope)
        try await transport.send(data)
    }
}
