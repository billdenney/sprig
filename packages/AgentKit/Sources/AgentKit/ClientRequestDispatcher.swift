// ClientRequestDispatcher.swift
//
// Inbound half of the agent's IPC loop: read `Envelope<ClientRequest>`
// off a `TransportKit.Transport.messages()` stream, dispatch by kind,
// and respond with `Envelope<AgentResponse>`. Closes the bidirectional
// loop opened by `TransportBadgeEventSink` (which writes `AgentEvent`
// envelopes outbound on the same transport).
//
// Slice A3 of the M2 agent track. The last piece before the M2-Mac
// LaunchAgent host can be wired up against XPC.
//
// Tier 2. Deps: Foundation + IPCSchema (Envelope, Codec, ClientRequest,
// AgentResponse) + RepoState (SubscriptionRegistry) + TransportKit
// (Transport). No platform APIs.

import Foundation
import IPCSchema
import RepoState
import TransportKit

/// Reads `ClientRequest` envelopes from one end of a `Transport`,
/// dispatches them, and writes `AgentResponse` envelopes back on the
/// same transport.
///
/// **One dispatcher per connection.** A single agent process typically
/// has one dispatcher per connected client (FinderSync extension,
/// sprigctl, task-window app). All dispatchers share the host's
/// `SubscriptionRegistry`, so a subscribe from any client populates
/// the same global routing table that `BadgeChangeBroadcaster` reads
/// from.
///
/// **Composes with `TransportBadgeEventSink`.** Both write to the same
/// `Transport`. The broadcaster sends events; this dispatcher sends
/// solicited replies. The wire format is opaque bytes, so the client
/// reading from `transport.messages()` peeks each envelope's `kind`
/// before deciding whether it's an event (push) or a reply
/// (correlate-by-id).
///
/// **Why an actor.** The receive task and external `start`/`stop`
/// callers race against the same `task` handle. Actor isolation is
/// the cheapest correct serialization.
public actor ClientRequestDispatcher {
    /// Resolves a path to its current badge for the synchronous
    /// `badgeQuery` path. Returns the wire-stable rawValue of
    /// `RepoState.BadgeIdentifier` (or nil for "no badge / clean").
    /// The dispatcher doesn't care which `RepoStateStore` handles
    /// each path — that's the host's call. Default resolver returns
    /// nil for every path (treats all paths as unbadged).
    public typealias BadgeResolver = @Sendable (URL) async -> String?

    private let transport: any Transport
    private let registry: SubscriptionRegistry
    private let routes: SubscriptionTransportRoutes?
    private let badgeResolver: BadgeResolver

    private var task: Task<Void, Never>?
    private var running = false

    /// - Parameters:
    ///   - transport: the duplex byte channel to read from / write to.
    ///   - registry: shared with the host's broadcaster path. Subscribes
    ///     mutate this; the broadcaster reads it on each fan-out.
    ///   - routes: optional — the host's
    ///     ``SubscriptionTransportRoutes`` actor. When provided, every
    ///     successful `subscribe` ack also registers the assigned id →
    ///     this dispatcher's `transport` so a ``RoutedBadgeEventSink``
    ///     can later route events to the right client. Pass nil for
    ///     single-client hosts (the default), where every event goes
    ///     to the same transport via ``TransportBadgeEventSink``.
    ///   - badgeResolver: resolves a path → wire-stable badge string
    ///     for the synchronous `badgeQuery` path. Default returns nil.
    public init(
        transport: any Transport,
        registry: SubscriptionRegistry,
        routes: SubscriptionTransportRoutes? = nil,
        badgeResolver: @escaping BadgeResolver = { _ in nil }
    ) {
        self.transport = transport
        self.registry = registry
        self.routes = routes
        self.badgeResolver = badgeResolver
    }

    /// Begin draining `transport.messages()` and dispatching. Idempotent
    /// — a second call while running is a no-op.
    public func start() {
        guard !running else { return }
        running = true
        let transport = self.transport
        let registry = self.registry
        let routes = self.routes
        let resolver = self.badgeResolver
        task = Task {
            for await data in transport.messages() {
                if Task.isCancelled { break }
                await Self.handle(
                    data,
                    transport: transport,
                    registry: registry,
                    routes: routes,
                    resolver: resolver
                )
            }
        }
    }

    /// Stop draining. Idempotent. After return, `transport.messages()`
    /// is no longer being consumed by this dispatcher; the caller can
    /// re-arm by constructing a fresh dispatcher.
    public func stop() async {
        guard running else { return }
        running = false
        task?.cancel()
        task = nil
    }

    // MARK: dispatch

    private static func handle(
        _ data: Data,
        transport: any Transport,
        registry: SubscriptionRegistry,
        routes: SubscriptionTransportRoutes?,
        resolver: BadgeResolver
    ) async {
        let envelope: Envelope<ClientRequest>
        do {
            envelope = try EnvelopeCodec.decode(ClientRequest.self, from: data)
        } catch let error as IPCError {
            await sendError(
                from: data,
                ipcError: error,
                transport: transport
            )
            return
        } catch {
            await sendParseError(
                from: data,
                underlying: error,
                transport: transport
            )
            return
        }

        let response: Envelope<AgentResponse>
        switch envelope.message {
        case let .subscribe(payload):
            let urls = payload.roots.map(URL.init(fileURLWithPath:))
            let id = await registry.subscribe(roots: urls)
            // Multi-client routing: associate the freshly-minted id
            // with this dispatcher's transport so a
            // `RoutedBadgeEventSink` knows where to send events.
            // Single-client hosts pass `routes: nil` and skip this.
            await routes?.register(id, transport: transport)
            response = Envelope(
                id: envelope.id,
                message: .subscribeAck(SubscribeAckPayload(subscriptionId: id))
            )

        case let .badgeQuery(payload):
            let url = URL(fileURLWithPath: payload.path)
            let badge = await resolver(url)
            response = Envelope(
                id: envelope.id,
                message: .badgeReply(BadgeReplyPayload(badge: badge))
            )
        }

        try? await transport.send(EnvelopeCodec.encode(response))
    }

    /// Build and send an `AgentResponse.error` envelope echoing whatever
    /// `id` the inbound bytes carried (or a fresh UUID if even that
    /// can't be parsed). Used for known-shape `IPCError`s — the error
    /// `code` is wire-stable; clients pattern-match on it.
    private static func sendError(
        from data: Data,
        ipcError: IPCError,
        transport: any Transport
    ) async {
        let echoId = (try? EnvelopePeek.id(of: data)) ?? UUID()
        let payload = ErrorPayload(
            code: stableCode(for: ipcError),
            message: String(describing: ipcError)
        )
        let response = Envelope(id: echoId, message: AgentResponse.error(payload))
        try? await transport.send(EnvelopeCodec.encode(response))
    }

    /// Same shape as ``sendError`` but for arbitrary `Decoding`/other
    /// errors that don't map to a known `IPCError` — uses the generic
    /// `parse_error` code.
    private static func sendParseError(
        from data: Data,
        underlying: any Error,
        transport: any Transport
    ) async {
        let echoId = (try? EnvelopePeek.id(of: data)) ?? UUID()
        let payload = ErrorPayload(
            code: "parse_error",
            message: String(describing: underlying)
        )
        let response = Envelope(id: echoId, message: AgentResponse.error(payload))
        try? await transport.send(EnvelopeCodec.encode(response))
    }

    /// Wire-stable error codes the dispatcher emits. Clients
    /// pattern-match on these strings; renaming a case here is a
    /// breaking wire change.
    private static func stableCode(for error: IPCError) -> String {
        switch error {
        case .unsupportedSchemaVersion: "unsupported_schema_version"
        case .unknownMessageKind: "unknown_message_kind"
        case .parseFailure: "parse_error"
        }
    }
}
