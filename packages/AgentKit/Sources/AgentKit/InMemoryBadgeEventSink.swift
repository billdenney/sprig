// InMemoryBadgeEventSink.swift
//
// A `BadgeEventSink` impl that buffers envelopes onto an `AsyncStream`.
// The first portable consumer of `BadgeChangeBroadcaster` — `RepoAgent`
// uses it as the in-process bridge from broadcaster output to a CLI
// printer or an integration test, before any `Transport` is wired in.
//
// Tier-2 portable. Deps: Foundation + IPCSchema (for `Envelope` and
// `AgentEvent`) + RepoState (for `BadgeEventSink`).
//
// A Transport-backed sink (encodes the envelope and writes it to a
// `TransportKit.Transport`) is a follow-up — kept out of slice A so
// the integration test can run without touching XPC / pipes / etc.

import Foundation
import IPCSchema
import RepoState

/// A `BadgeEventSink` that pushes every emitted envelope onto an
/// `AsyncStream<Envelope<AgentEvent>>` for in-process consumption.
///
/// **Lifecycle.** Construct once per consumer. Read events via
/// ``events`` until ``finish()`` is called or the underlying
/// continuation is dropped (whichever comes first). Calling
/// ``finish()`` is idempotent.
///
/// **Thread-safety.** `Sendable` — the captured continuation is
/// thread-safe by AsyncStream's contract. The broadcaster invokes
/// ``emit(_:)`` from arbitrary task contexts; the consumer can be
/// in any actor.
///
/// **Backpressure.** None. AsyncStream's default (unbounded) buffering
/// is fine for the agent's expected fan-out shape (one envelope per
/// changed path per matching subscription, on the order of dozens
/// per refresh tick). If a future workload changes that, switching
/// the underlying continuation policy is a one-line change.
public struct InMemoryBadgeEventSink: BadgeEventSink {
    /// Stream of envelopes the broadcaster has emitted. Single-consumer
    /// — subscribing twice produces two streams that race for events.
    public let events: AsyncStream<Envelope<AgentEvent>>

    private let continuation: AsyncStream<Envelope<AgentEvent>>.Continuation

    public init() {
        var captured: AsyncStream<Envelope<AgentEvent>>.Continuation!
        events = AsyncStream<Envelope<AgentEvent>> { cont in
            captured = cont
        }
        continuation = captured
    }

    public func emit(_ envelope: Envelope<AgentEvent>) async throws {
        continuation.yield(envelope)
    }

    /// Finish the stream so any consumer's `for await` loop exits
    /// cleanly. Idempotent — safe to call from `RepoAgent.stop()`
    /// without coordinating with the broadcaster's last-emit.
    public func finish() {
        continuation.finish()
    }
}
