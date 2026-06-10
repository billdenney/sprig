// TeeBadgeEventSink.swift
//
// Fan a `BadgeEventSink` emit to several sinks — the host glue that
// lets `sprigctl agent --socket` keep its stdout envelope stream
// (the in-memory sink the CLI drains) while ALSO serving connected
// IPC clients (the routed sink). Any host that wants diagnostics
// alongside real serving composes the same way.
//
// Failure semantics: every sink is attempted on every emit — one
// broken client transport must not starve the others (or stdout) —
// and the FIRST error is rethrown afterwards so the broadcaster's
// per-subscription failure isolation still sees it.

import Foundation
import IPCSchema
import RepoState

/// `BadgeEventSink` that forwards each envelope to every child sink.
public struct TeeBadgeEventSink: BadgeEventSink {
    private let sinks: [any BadgeEventSink]

    public init(_ sinks: [any BadgeEventSink]) {
        self.sinks = sinks
    }

    public func emit(_ envelope: Envelope<AgentEvent>) async throws {
        var firstError: (any Error)?
        for sink in sinks {
            do {
                try await sink.emit(envelope)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
    }
}
