// RoutedBadgeEventSink.swift
//
// Multi-client variant of `TransportBadgeEventSink`. Same shape, but
// instead of one configured transport, a router actor (typically
// `SubscriptionTransportRoutes`) returns the right transport per
// envelope based on `BadgeChangedPayload.subscriptionId`.
//
// Slice A5 of the M2 agent track. Lets one
// `BadgeChangeBroadcaster.broadcast(_:)` call fan out to N concurrent
// clients without any of them seeing events for subscriptions they
// don't own.
//
// Tier 2 portable. Deps: Foundation + IPCSchema + RepoState
// (`BadgeEventSink`) + TransportKit (`Transport`). No platform APIs.

import Foundation
import IPCSchema
import RepoState
import TransportKit

/// Wire-bound `BadgeEventSink` whose target transport is decided per
/// envelope by a router. The router maps the envelope's
/// `subscriptionId` to the transport that owns it.
///
/// **Behavior on unknown subscriptions.** If the router returns nil
/// (the subscriber's connection has dropped, the dispatcher hasn't
/// registered it yet, etc.) the sink silently drops the envelope.
/// Per-subscriber failure isolation is the broadcaster's job; the
/// sink staying simple is what makes that contract holdable.
///
/// **`subscriptionEnded` events** route the same way as
/// `badgeChanged` — they carry a `subscriptionId` too.
///
/// **Sendable.** The struct is trivial-Sendable; the router actor is
/// the only synchronization point.
public struct RoutedBadgeEventSink: BadgeEventSink {
    public typealias Router = @Sendable (UUID) async -> (any Transport)?

    private let router: Router

    /// - Parameter router: returns the transport that should receive
    ///   events for a given subscription, or nil to drop the event.
    ///   Most hosts will pass `routes.transport(for:)` (an instance
    ///   method on ``SubscriptionTransportRoutes``), but the closure
    ///   form leaves room for tests and unusual host configurations.
    public init(router: @escaping Router) {
        self.router = router
    }

    /// Convenience initializer that adopts a
    /// ``SubscriptionTransportRoutes`` actor as the router. The most
    /// common production shape; equivalent to
    /// `RoutedBadgeEventSink(router: { await routes.transport(for: $0) })`
    /// but without the closure-capture footnote.
    public init(routes: SubscriptionTransportRoutes) {
        self.init(router: { id in await routes.transport(for: id) })
    }

    public func emit(_ envelope: Envelope<AgentEvent>) async throws {
        let id = Self.subscriptionId(of: envelope)
        guard let transport = await router(id) else {
            // No transport for this subscription — drop the event.
            return
        }
        let data = try EnvelopeCodec.encode(envelope)
        try await transport.send(data)
    }

    /// Pull the `subscriptionId` out of either `AgentEvent` case. Both
    /// cases carry one — every per-subscription event has a
    /// destination identity.
    private static func subscriptionId(of envelope: Envelope<AgentEvent>) -> UUID {
        switch envelope.message {
        case let .badgeChanged(payload): payload.subscriptionId
        case let .subscriptionEnded(payload): payload.subscriptionId
        }
    }
}
