// InProcessTransport.swift
//
// Portable, in-process ``Transport`` implementation. Both ends live
// in the same Swift process and exchange `Data` buffers via two
// crossed `AsyncStream`s. Used by:
//
// 1. **Tests** — exercise the IPCSchema → Transport → IPCSchema
//    round-trip without spinning up XPC / named pipes.
// 2. **Same-process agent + client** — `sprigctl` on a host that's
//    also running SprigAgent could in principle short-circuit IPC
//    by linking the agent in-process. Less common, but the
//    primitive is the same.
//
// Tier 2 portable. No platform APIs.
//
// Concurrency model
// -----------------
// Each end is an isolated `@unchecked Sendable` final class wrapping:
//
// - An outbound `AsyncStream<Data>.Continuation` — the peer reads
//   from the matching stream.
// - An inbound `AsyncStream<Data>` (and its handle) — the local
//   consumer iterates this.
// - A small lock around close-state to avoid double-finish.
//
// Pair construction creates two streams (one per direction) and
// wires each end to the right continuation/stream.

import Foundation

/// Two ``Transport`` endpoints connected to each other in-process.
/// Use ``connected()`` to construct a fresh pair; the returned ends
/// are crossed (clientEnd's outbound feeds agentEnd's inbound and
/// vice versa).
public struct InProcessTransportPair: Sendable {
    /// The "client" end. Send from here goes to ``agentEnd``'s
    /// ``Transport/messages()``.
    public let clientEnd: Transport

    /// The "agent" end. Send from here goes to ``clientEnd``'s
    /// ``Transport/messages()``.
    public let agentEnd: Transport

    /// Construct a fresh connected pair.
    public static func connected() -> InProcessTransportPair {
        let (clientToAgent, c2aContinuation) = AsyncStream<Data>.makeStream()
        let (agentToClient, a2cContinuation) = AsyncStream<Data>.makeStream()

        let client = InProcessTransport(
            outbound: c2aContinuation,
            inbound: agentToClient,
            peerOutbound: a2cContinuation
        )
        let agent = InProcessTransport(
            outbound: a2cContinuation,
            inbound: clientToAgent,
            peerOutbound: c2aContinuation
        )
        return InProcessTransportPair(clientEnd: client, agentEnd: agent)
    }
}

/// One end of an in-process duplex connection. Constructed via
/// ``InProcessTransportPair/connected()``; the standalone constructor
/// is internal so tests can't accidentally create unconnected
/// instances.
public final class InProcessTransport: Transport, @unchecked Sendable {
    private let outbound: AsyncStream<Data>.Continuation
    private let inbound: AsyncStream<Data>
    /// The peer's outbound continuation. We finish it on `close()` so
    /// the peer's `messages()` stream terminates with EOF.
    private let peerOutbound: AsyncStream<Data>.Continuation

    init(
        outbound: AsyncStream<Data>.Continuation,
        inbound: AsyncStream<Data>,
        peerOutbound: AsyncStream<Data>.Continuation
    ) {
        self.outbound = outbound
        self.inbound = inbound
        self.peerOutbound = peerOutbound
    }

    public func send(_ data: Data) async throws {
        // No explicit closed-flag — we use `AsyncStream`'s natural
        // lifecycle. `yield(_:)` reports `.terminated` if the stream
        // was finished, whether by our `close()` or the peer's. We
        // surface that as `peerClosed` since callers handle both
        // ends the same way (give up). The protocol's distinction
        // between `closed` and `peerClosed` is best-effort across
        // implementations; in-process can't distinguish without a
        // separate atomic, and the cost (Synchronization.Mutex needs
        // macOS 15+; we target 14+) outweighs the value.
        let result = outbound.yield(data)
        switch result {
        case .enqueued, .dropped:
            return
        case .terminated:
            throw TransportError.peerClosed
        @unknown default:
            return
        }
    }

    public func messages() -> AsyncStream<Data> {
        inbound
    }

    public func close() async {
        // `finish()` is idempotent — repeated calls are silently
        // ignored. So is calling it after the peer has already
        // finished its end.
        outbound.finish()
        peerOutbound.finish()
    }
}
