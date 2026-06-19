// AgentCommand+Serving.swift
//
// The IPC-serving half of `sprigctl agent`: accept transport clients
// and wire each into its own `ClientRequestDispatcher`, all sharing
// the host's `SubscriptionRegistry` + `SubscriptionTransportRoutes`,
// with the agent emitting through a `RoutedBadgeEventSink`.
//
// One seam, two transports (ADR 0048's covenant in action):
//   * Linux/macOS — `--socket PATH` over the ADR 0076 Unix-domain
//     socket.
//   * Windows — `--pipe NAME` over the ADR 0067 named pipe.
// The wire framing is byte-identical, so a client written against
// one transport ports to the other by swapping the connect call.
//
// Split from AgentCommand.swift for the file-length cap; members are
// internal (not private) because `run()` lives in the other file.

import AgentKit
import ArgumentParser
import Foundation
import RepoState
import TransportKit

/// What `run()` needs from a serving session, transport-agnostic.
protocol AgentServing {
    /// The sink the agent emits through (teed with stdout).
    var routedSink: RoutedBadgeEventSink { get }
    /// Where clients connect — the `# agent: serving at …` banner.
    var address: String { get }
    /// Yields exactly once when the last connected client disconnects,
    /// then finishes — but ONLY when the host opted into
    /// `--exit-on-last-client`. Otherwise it is an already-finished
    /// stream that never yields (the host runs until `--duration`).
    /// `run()` awaits this to stop the agent the moment its last client
    /// leaves, so a diagnostic/test host's lifetime tracks its client
    /// rather than racing a fixed wall-clock cap.
    var lastClientGone: AsyncStream<Void> { get }
    /// Stop accepting and tear down. Best-effort: the host process
    /// is about to exit when this runs.
    func shutdown()
}

/// Live-client bookkeeping for `--exit-on-last-client`. The accept
/// loop reports each connect; each dispatcher reports its client's
/// disconnect. When the count returns to zero after at least one
/// client has connected, ``lastClientGone`` fires once and finishes.
///
/// An actor because connects (accept loop) and disconnects (per-client
/// dispatcher tasks) race against the same counter from different
/// task contexts.
actor ClientLifecycle {
    /// Yields once when the last client disconnects, then finishes.
    /// `nonisolated` so the serving session can hand it to `run()`
    /// without an `await` hop — it's an immutable `Sendable` handle.
    nonisolated let lastClientGone: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var active = 0
    private var everConnected = false
    private var fired = false

    init() {
        var captured: AsyncStream<Void>.Continuation!
        lastClientGone = AsyncStream { captured = $0 }
        continuation = captured
    }

    func clientConnected() {
        active += 1
        everConnected = true
    }

    func clientDisconnected() {
        active -= 1
        // `everConnected` can only be true here (a decrement implies a
        // prior connect), but keep the guard explicit so a stray
        // decrement can never fire a premature shutdown.
        guard active <= 0, everConnected, !fired else { return }
        fired = true
        continuation.yield(())
        continuation.finish()
    }
}

/// The disabled-flag stand-in for ``AgentServing/lastClientGone``: an
/// empty stream that finishes immediately, so `run()`'s await over it
/// completes at once and never stops the agent.
func neverFiresClientGone() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
}

#if os(Linux) || os(macOS)
    extension AgentCommand {
        /// One `--socket` serving session over the ADR 0076 UDS
        /// transport.
        struct UnixSocketServing: AgentServing {
            let server: UnixSocketServer
            let acceptTask: Task<Void, Never>
            let routedSink: RoutedBadgeEventSink
            let lastClientGone: AsyncStream<Void>
            var address: String {
                server.socketPath
            }

            func shutdown() {
                server.close()
                acceptTask.cancel()
            }
        }

        func makeServing(registry: SubscriptionRegistry) throws -> (any AgentServing)? {
            guard pipe == nil else {
                throw ValidationError(
                    "--pipe is the Windows transport; use --socket PATH here (ADR 0076)"
                )
            }
            guard let socket else { return nil }
            let server = try UnixSocketServer(socketPath: socket)
            let routes = SubscriptionTransportRoutes()
            let lifecycle = exitOnLastClient ? ClientLifecycle() : nil
            let acceptTask = Task {
                await Self.acceptLoop(
                    connections: server.connections,
                    registry: registry,
                    routes: routes,
                    lifecycle: lifecycle
                )
            }
            return UnixSocketServing(
                server: server,
                acceptTask: acceptTask,
                routedSink: RoutedBadgeEventSink(routes: routes),
                lastClientGone: lifecycle?.lastClientGone ?? neverFiresClientGone()
            )
        }
    }

#elseif os(Windows)
    extension AgentCommand {
        /// One `--pipe` serving session over the ADR 0067 named-pipe
        /// transport.
        struct NamedPipeServing: AgentServing {
            let server: NamedPipeServer
            let acceptTask: Task<Void, Never>
            let routedSink: RoutedBadgeEventSink
            let address: String
            let lastClientGone: AsyncStream<Void>

            func shutdown() {
                acceptTask.cancel()
                let server = server
                Task { await server.close() }
            }
        }

        func makeServing(registry: SubscriptionRegistry) throws -> (any AgentServing)? {
            guard socket == nil else {
                throw ValidationError(
                    "--socket is the Linux/macOS transport; use --pipe NAME here (ADR 0067)"
                )
            }
            guard let pipe else { return nil }
            let server = try NamedPipeServer(pipeName: pipe)
            let routes = SubscriptionTransportRoutes()
            let lifecycle = exitOnLastClient ? ClientLifecycle() : nil
            let acceptTask = Task {
                await Self.acceptLoop(
                    connections: server.connections,
                    registry: registry,
                    routes: routes,
                    lifecycle: lifecycle
                )
            }
            return NamedPipeServing(
                server: server,
                acceptTask: acceptTask,
                routedSink: RoutedBadgeEventSink(routes: routes),
                address: pipe,
                lastClientGone: lifecycle?.lastClientGone ?? neverFiresClientGone()
            )
        }
    }
#else
    extension AgentCommand {
        func makeServing(registry _: SubscriptionRegistry) throws -> (any AgentServing)? {
            guard socket == nil, pipe == nil else {
                throw ValidationError("IPC serving is not supported on this platform")
            }
            return nil
        }
    }
#endif

extension AgentCommand {
    /// Stop the agent when the serving layer reports its last client
    /// disconnected (`--exit-on-last-client`). Returns nil when there's
    /// no serving session. When the flag is off, `lastClientGone` is an
    /// already-finished stream, so the `for await` exits immediately and
    /// the agent keeps running until --duration / Ctrl-C — same as
    /// before. Stops via the identical `agent.stop()` + `sink.finish()`
    /// path the --duration timer uses; both are idempotent, so the two
    /// triggers can fire in either order without harm.
    ///
    /// Internal (not private) so `run()` in AgentCommand.swift can call
    /// it across the file split.
    func makeLastClientStopTask(
        serving: (any AgentServing)?,
        agent: RepoAgent,
        sink: InMemoryBadgeEventSink
    ) -> Task<Void, Never>? {
        guard let serving else { return nil }
        // Capture only the `Sendable` stream, not the whole non-Sendable
        // `any AgentServing` — otherwise the Task closure trips Swift 6
        // region isolation (`sending`-parameter data-race diagnostic).
        let lastClientGone = serving.lastClientGone
        return Task {
            for await _ in lastClientGone {
                await agent.stop()
                sink.finish()
                break
            }
        }
    }

    /// The shared accept loop: one `ClientRequestDispatcher` per
    /// connection. Dispatchers are retained for the server's
    /// lifetime; when `close()` finishes the connections stream,
    /// each is stopped before the task exits.
    ///
    /// When `lifecycle` is non-nil (`--exit-on-last-client`), each
    /// connection is counted and each dispatcher reports its client's
    /// disconnect, so the lifecycle can fire once the last client
    /// leaves. The teardown `stop()` below does NOT count as a
    /// disconnect — `ClientRequestDispatcher` only fires `onDisconnect`
    /// on a real client EOF, not on `stop()`.
    static func acceptLoop(
        connections: AsyncStream<some Transport>,
        registry: SubscriptionRegistry,
        routes: SubscriptionTransportRoutes,
        lifecycle: ClientLifecycle?
    ) async {
        var dispatchers: [ClientRequestDispatcher] = []
        for await transport in connections {
            await lifecycle?.clientConnected()
            let dispatcher = ClientRequestDispatcher(
                transport: transport,
                registry: registry,
                routes: routes,
                onDisconnect: disconnectHandler(for: lifecycle)
            )
            await dispatcher.start()
            dispatchers.append(dispatcher)
        }
        for dispatcher in dispatchers {
            await dispatcher.stop()
        }
    }

    /// The per-connection disconnect callback for `--exit-on-last-client`,
    /// or nil when the flag is off. Factored into a function with an
    /// explicit return type for two reasons: the type context the
    /// closure needs, and a `guard`/`return` shape that sidesteps both
    /// the snapshot toolchain's inline-closure inference crash
    /// (`failed to produce diagnostic` at the init call) and
    /// SwiftFormat's `conditionalAssignment` rewrite of an if/else.
    private static func disconnectHandler(
        for lifecycle: ClientLifecycle?
    ) -> ClientRequestDispatcher.DisconnectHandler? {
        guard let lifecycle else { return nil }
        return { await lifecycle.clientDisconnected() }
    }
}
