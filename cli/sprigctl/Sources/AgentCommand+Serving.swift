// AgentCommand+Serving.swift
//
// The `--socket` half of `sprigctl agent` (ADR 0076 first consumer):
// accept Unix-domain-socket clients and wire each into its own
// `ClientRequestDispatcher`, all sharing the host's
// `SubscriptionRegistry` + `SubscriptionTransportRoutes`, with the
// agent emitting through a `RoutedBadgeEventSink`. Split from
// AgentCommand.swift for the file-length cap; members are internal
// (not private) because `run()` lives in the other file.

import AgentKit
import Foundation
import RepoState
import TransportKit

#if os(Linux) || os(macOS)
    extension AgentCommand {
        /// One `--socket` serving session: the UDS listener, the
        /// accept loop, and the routed sink the agent emits through.
        struct Serving {
            let server: UnixSocketServer
            let acceptTask: Task<Void, Never>
            let routedSink: RoutedBadgeEventSink

            func shutdown() {
                server.close()
                acceptTask.cancel()
            }
        }

        func makeServing(registry: SubscriptionRegistry) throws -> Serving? {
            guard let socket else { return nil }
            let server = try UnixSocketServer(socketPath: socket)
            let routes = SubscriptionTransportRoutes()
            let acceptTask = Task {
                // Dispatchers are retained here for the server's
                // lifetime; when `close()` finishes the connections
                // stream, each is stopped before the task exits.
                var dispatchers: [ClientRequestDispatcher] = []
                for await transport in server.connections {
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
            return Serving(
                server: server,
                acceptTask: acceptTask,
                routedSink: RoutedBadgeEventSink(routes: routes)
            )
        }
    }
#endif
