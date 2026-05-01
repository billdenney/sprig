// Transport.swift
//
// Byte-level transport protocol for the agent ↔ client connection.
// Higher layers (IPCSchema's `Envelope` + Codable messages) handle the
// wire format; Transport just shuttles bytes.
//
// Tier 2 portable protocol. Per-platform impls land in
// `Sources/Mac/` (XPC), `Sources/Linux/` (D-Bus or UNIX socket),
// `Sources/Windows/` (named pipe) — each behind this protocol so
// callers don't need `#if os(...)` everywhere.
//
// Why opaque `Data` and not generic over `EnvelopeMessage`
// --------------------------------------------------------
// Keeping the protocol byte-oriented decouples Transport from
// IPCSchema. Every transport carries the SAME bytes regardless of
// what's inside, so adding new envelope types (`AgentEvent` was the
// most recent) doesn't ripple into transport implementations. The
// IPCSchema layer composes: encode `Envelope` → Data → send;
// receive Data → decode `Envelope` → dispatch by kind.

import Foundation

/// One end of a duplex connection between a Sprig client (FinderSync /
/// Explorer extension, sprigctl, task-window app) and the agent
/// (SprigAgent, Windows Service host of AgentKit, Linux systemd unit).
///
/// **Wire format is opaque** — the protocol moves byte buffers,
/// nothing more. Callers serialize `IPCSchema.Envelope` values to
/// `Data` before ``send(_:)``, and decode incoming `Data` from
/// ``messages()`` back into envelopes.
///
/// **Bidirectional, single channel.** Both replies (correlated by
/// envelope id, IPCSchema's job to match) and unsolicited events
/// (`AgentEvent`-shaped) come through the same ``messages()`` stream.
/// Caller dispatches by inspecting the envelope after decode.
///
/// **Sendable.** Implementations must be safe to share across actor
/// boundaries — typically by wrapping mutable state behind a lock or
/// actor.
public protocol Transport: Sendable {
    /// Send a serialized envelope to the peer. Returns once the bytes
    /// have been handed to the underlying transport (XPC peer queue,
    /// pipe write buffer, etc.); does **not** wait for a reply.
    /// Replies, if any, arrive on ``messages()``.
    ///
    /// Throws ``TransportError/closed`` if the local end has been
    /// closed via ``close()``. Throws ``TransportError/peerClosed``
    /// if the remote disconnected. Throws ``TransportError/sendFailed(reason:)``
    /// for transport-specific failures (XPC errors, broken pipe, etc.).
    func send(_ data: Data) async throws

    /// Asynchronous stream of inbound byte-buffers from the peer.
    ///
    /// **Single-consumer**: subscribing twice produces two streams
    /// that race for events. Most agents have one consumer task per
    /// connection; this matches that pattern.
    ///
    /// The stream finishes (returns `nil` from `next()`) when:
    /// - Local ``close()`` is called, OR
    /// - The peer disconnects, OR
    /// - The transport hits an unrecoverable error.
    ///
    /// Per-message framing is the transport's responsibility — each
    /// `Data` element is one complete envelope's worth of bytes,
    /// regardless of whether the underlying medium delivers them in
    /// fragments.
    func messages() -> AsyncStream<Data>

    /// Close the local end of the connection. Idempotent. After
    /// return:
    /// - ``send(_:)`` throws ``TransportError/closed``.
    /// - The stream from ``messages()`` finishes.
    /// - The peer (if any) sees a peer-closed signal and its own
    ///   ``messages()`` finishes.
    func close() async
}

/// Errors thrown by ``Transport`` operations.
public enum TransportError: Error, Sendable, Equatable {
    /// The local end was closed before/during this operation.
    case closed

    /// The remote peer closed before/during this operation.
    case peerClosed

    /// Transport-specific failure with a free-form reason. Examples:
    /// XPC connection invalidation, named-pipe write returning
    /// ERROR_BROKEN_PIPE, D-Bus method-call timeout.
    ///
    /// `reason` is for logging/diagnostics; do not pattern-match on
    /// the string.
    case sendFailed(reason: String)
}
