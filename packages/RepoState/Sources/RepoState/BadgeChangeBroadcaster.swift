// BadgeChangeBroadcaster.swift
//
// The "fan-out" piece that ties the rest of RepoState together for
// the agent's IPC push path:
//
//   refresher.refresh()                            // git status v2
//      → store.applyAndDiff(_:)                    // PathBadgeChange[]
//          → broadcaster.broadcast(_:)             // ← this file
//              → registry.matchingSubscriptions    // UUID[] per change
//              → AgentEvent.badgeChanged envelope  // wire-stable
//              → sink.emit(_:)                     // transport-shaped
//
// One envelope per (subscriber, change) pair: a single change can fire
// multiple events when several subscribers cover the path; a single
// subscriber can receive multiple events when several paths changed.
//
// Tier-1 portable. Depends only on Foundation + IPCSchema (also
// Tier-1). The sink is a protocol so the broadcaster doesn't drag
// `TransportKit` into Tier-1; the agent provides a sink that wraps a
// `Transport` + `EnvelopeCodec`.
//
// Per-subscription failure isolation: an `emit` that throws does NOT
// abort the rest of the broadcast — other subscribers still get their
// events. Failure counts are returned in `BroadcastResult` so callers
// can drive dead-subscription pruning out of band.

import Foundation
import IPCSchema

/// What the broadcaster sends to. Real implementations wrap a
/// `TransportKit.Transport` with `IPCSchema.EnvelopeCodec`; tests use
/// a recording double that captures envelopes without I/O.
///
/// `Sendable` because the broadcaster is itself `Sendable` and may be
/// invoked from any task; the sink may need to thread events into an
/// actor or task-local context.
public protocol BadgeEventSink: Sendable {
    /// Emit one envelope. Implementors decide whether to await
    /// transport ack or fire-and-forget. Throwing surfaces a
    /// per-envelope failure; the broadcaster counts it but keeps
    /// going.
    func emit(_ envelope: Envelope<AgentEvent>) async throws
}

/// Outcome of a ``BadgeChangeBroadcaster/broadcast(_:)`` call. Useful
/// for diagnostics and for the agent's "this subscription has failed
/// N times in a row, drop it" pruning logic. The two counters sum to
/// the total fan-out attempts.
public struct BroadcastResult: Sendable, Equatable {
    /// Envelopes the sink accepted without throwing.
    public var emitted: Int

    /// Envelopes the sink rejected (the sink threw). The broadcaster
    /// continued on to the next subscriber.
    public var failed: Int

    public init(emitted: Int, failed: Int) {
        self.emitted = emitted
        self.failed = failed
    }
}

/// Fan-out helper that converts a `[PathBadgeChange]` (from
/// `RepoStateStore.applyAndDiff(_:)`) into one
/// `AgentEvent.badgeChanged` envelope per matching subscription.
///
/// Stateless besides the captured registry + sink, so this is a
/// `Sendable` struct rather than an actor — concurrent invocations
/// are fine; the registry actor protects its own state.
public struct BadgeChangeBroadcaster: Sendable {
    private let registry: SubscriptionRegistry
    private let sink: any BadgeEventSink

    public init(registry: SubscriptionRegistry, sink: any BadgeEventSink) {
        self.registry = registry
        self.sink = sink
    }

    /// Fan `changes` out to every matching subscriber via the sink.
    ///
    /// For each ``PathBadgeChange``, looks up the matching
    /// subscriptions in the registry and emits one
    /// `AgentEvent.badgeChanged` envelope per subscription. The
    /// envelope's `BadgeChangedPayload.badge` carries the **after**
    /// state's `rawValue` (or nil for "now clean") — receivers update
    /// their local cache directly from this without re-querying the
    /// agent.
    ///
    /// **Path encoding.** The envelope carries the absolute file path
    /// as `URL.path`. On POSIX (macOS / Linux) this is the canonical
    /// `/dir/file.txt` form; Windows callers will need to revisit
    /// when M2-Win lands (likely backslash-aware encoding via
    /// `Pathish`).
    ///
    /// **Failure isolation.** A sink that throws on one envelope does
    /// not abort the broadcast — the broadcaster increments the
    /// `failed` counter and continues. The agent uses repeated
    /// failures against the same subscription to decide to drop it
    /// (out of scope for this type).
    @discardableResult
    public func broadcast(_ changes: [PathBadgeChange]) async -> BroadcastResult {
        var result = BroadcastResult(emitted: 0, failed: 0)
        for change in changes {
            let subscriptions = await registry.matchingSubscriptions(for: change.path)
            for subscriptionId in subscriptions {
                let envelope = Envelope(
                    message: AgentEvent.badgeChanged(BadgeChangedPayload(
                        subscriptionId: subscriptionId,
                        path: change.path.path,
                        badge: change.after?.rawValue
                    ))
                )
                do {
                    try await sink.emit(envelope)
                    result.emitted += 1
                } catch {
                    result.failed += 1
                }
            }
        }
        return result
    }
}
