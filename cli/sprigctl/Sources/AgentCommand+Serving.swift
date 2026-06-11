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
    /// Stop accepting and tear down. Best-effort: the host process
    /// is about to exit when this runs.
    func shutdown()
}

#if os(Linux) || os(macOS)
    extension AgentCommand {
        /// One `--socket` serving session over the ADR 0076 UDS
        /// transport.
        struct UnixSocketServing: AgentServing {
            let server: UnixSocketServer
            let acceptTask: Task<Void, Never>
            let routedSink: RoutedBadgeEventSink
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
            let acceptTask = Task {
                await Self.acceptLoop(
                    connections: server.connections,
                    registry: registry,
                    routes: routes
                )
            }
            return UnixSocketServing(
                server: server,
                acceptTask: acceptTask,
                routedSink: RoutedBadgeEventSink(routes: routes)
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
            let acceptTask = Task {
                await Self.acceptLoop(
                    connections: server.connections,
                    registry: registry,
                    routes: routes
                )
            }
            return NamedPipeServing(
                server: server,
                acceptTask: acceptTask,
                routedSink: RoutedBadgeEventSink(routes: routes),
                address: pipe
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
    /// The shared accept loop: one `ClientRequestDispatcher` per
    /// connection. Dispatchers are retained for the server's
    /// lifetime; when `close()` finishes the connections stream,
    /// each is stopped before the task exits.
    static func acceptLoop(
        connections: AsyncStream<some Transport>,
        registry: SubscriptionRegistry,
        routes: SubscriptionTransportRoutes
    ) async {
        var dispatchers: [ClientRequestDispatcher] = []
        for await transport in connections {
            let dispatcher = ClientRequestDispatcher(
                transport: transport,
                registry: registry,
                routes: routes
            )
            await dispatcher.start()
            dispatchers.append(dispatcher)
        }
        for dispatcher in dispatchers {
            await dispatcher.stop()
        }
    }
}
