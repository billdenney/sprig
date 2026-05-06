// SubscriptionTransportRoutes.swift
//
// Maps subscription UUIDs to the transport that should receive their
// `AgentEvent.badgeChanged` envelopes. The piece that lets a single
// `BadgeChangeBroadcaster` fan out to many concurrent clients —
// without it, every event hits every client's transport, leaking
// repos across subscribers.
//
// Slice A5 of the M2 agent track. Closes the multi-client limitation
// flagged in slice A4's `docs/architecture/agent-host.md`.
//
// Tier 2 portable. Deps: Foundation + TransportKit (`Transport`). No
// platform APIs, no `#if os(...)`.

import Foundation
import TransportKit

/// Owns the lookup `subscriptionId → Transport` that
/// ``RoutedBadgeEventSink`` reads on every emit.
///
/// **Lifecycle.** One instance per agent host process. The
/// ``ClientRequestDispatcher`` (also given this actor) populates it
/// on every successful `subscribe` ack — the dispatcher knows both
/// the assigned id and which transport the inbound request arrived
/// on, so it's the right place to record the mapping.
///
/// **Cleanup.** Hosts call ``unregisterAll(transport:)`` when a
/// connection drops to drop every subscription owned by that
/// transport. The current implementation walks the table once;
/// connection counts are expected to be small (one per FinderSync
/// extension instance, one per `sprigctl agent` invocation, etc.).
///
/// **Identity comparison.** Transports are compared by `ObjectIdentifier`
/// — same protocol-existential boxes the same heap object, so this
/// is reference equality on the underlying class instance. `Transport`
/// implementations are reference types in practice (XPC connections,
/// pipe handles, the in-process pair); requiring class-typed identity
/// avoids the pitfalls of conforming structs.
///
/// **Why an actor.** Multiple dispatchers (one per client connection)
/// register subscriptions concurrently while the broadcaster reads
/// the table on every emit. Actor isolation serializes both safely.
public actor SubscriptionTransportRoutes {
    private var byID: [UUID: any Transport] = [:]

    public init() {}

    /// Associate `subscriptionId` with `transport`. Overwrites any
    /// previous mapping for the same id (which shouldn't happen in
    /// practice — ids are minted fresh — but the simpler semantics
    /// avoids a class of bugs if a caller ever does).
    public func register(_ subscriptionId: UUID, transport: any Transport) {
        byID[subscriptionId] = transport
    }

    /// Drop a single mapping. Idempotent — removing an unknown id is
    /// a no-op.
    public func unregister(_ subscriptionId: UUID) {
        byID.removeValue(forKey: subscriptionId)
    }

    /// Drop every mapping pointing at `transport`. Hosts call this
    /// when a connection drops so dead-transport sends don't pile up.
    /// O(n) over the table; acceptable at expected scales.
    public func unregisterAll(transport: any Transport) {
        let target = ObjectIdentifier(transport as AnyObject)
        byID = byID.filter { _, t in
            ObjectIdentifier(t as AnyObject) != target
        }
    }

    /// Look up the transport for a subscription. Returns nil for
    /// unknown ids — ``RoutedBadgeEventSink`` interprets nil as
    /// "drop this event silently" (the subscriber is gone).
    ///
    /// **Sendability note.** `any Transport` doesn't always cross
    /// actor boundaries cleanly under Swift 6 strict concurrency
    /// checking even though `Transport: Sendable`. Most callers
    /// shouldn't call this directly — use ``invokeWithTransport(for:_:)``
    /// (closure runs inside actor isolation) or, for the
    /// `RoutedBadgeEventSink` use case, the ``send(_:to:)`` shorthand.
    /// This method exists for the rare caller that genuinely needs
    /// the existential out of the actor.
    public func transport(for subscriptionId: UUID) -> (any Transport)? {
        byID[subscriptionId]
    }

    /// Run `body` inside actor isolation with the transport (if any)
    /// for `subscriptionId`. Returns whatever `body` returns, or nil
    /// if there's no mapping. The transport never crosses the actor
    /// boundary — `body` consumes it in place.
    public func invokeWithTransport<R: Sendable>(
        for subscriptionId: UUID,
        _ body: (any Transport) async throws -> R
    ) async rethrows -> R? {
        guard let transport = byID[subscriptionId] else { return nil }
        return try await body(transport)
    }

    /// Send `data` to the transport registered for `subscriptionId`.
    /// Returns true if a transport was found and the send completed
    /// (or was attempted — the underlying transport may still throw).
    /// Returns false if no mapping exists. Throws on transport-level
    /// errors.
    @discardableResult
    public func send(_ data: Data, to subscriptionId: UUID) async throws -> Bool {
        guard let transport = byID[subscriptionId] else { return false }
        try await transport.send(data)
        return true
    }

    /// True if `subscriptionId` is currently mapped to *any* transport.
    /// Cheaper test-only / diagnostic accessor that avoids the
    /// non-Sendable return of ``transport(for:)``.
    public func hasMapping(for subscriptionId: UUID) -> Bool {
        byID[subscriptionId] != nil
    }

    /// True if `subscriptionId` is mapped to the same `transport`
    /// instance the caller has on hand. Reference equality on the
    /// underlying class. Test-only and diagnostic.
    public func isMapping(_ subscriptionId: UUID, to transport: any Transport) -> Bool {
        guard let stored = byID[subscriptionId] else { return false }
        return ObjectIdentifier(stored as AnyObject) == ObjectIdentifier(transport as AnyObject)
    }

    /// Number of currently-registered subscriptions. Diagnostic only.
    public func count() -> Int {
        byID.count
    }
}
