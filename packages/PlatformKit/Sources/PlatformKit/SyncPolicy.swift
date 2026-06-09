// SyncPolicy.swift
//
// The seam between ADR 0068's portable auto-sync scheduler and
// ADR 0064's platform-specific backoff signals (AC vs battery,
// metered network, Low Power Mode, lid state).
//
// The scheduler asks the policy for a decision at each tick; the
// portable default always allows. Platform adapters (M2 macOS /
// M2-Win) implement the 0064 signal table and return
// `.pause(reason:)` when the machine shouldn't be fetching — the
// reason string feeds the Status task window's "fetch paused: lid
// closed" surface and `sprigctl status` parity.

import Foundation

/// One tick-time decision from a ``SyncPolicy``.
public enum SyncPolicyDecision: Sendable, Equatable {
    /// Run the sync job now.
    case allow
    /// Skip this tick. `reason` is human-readable, surfaced in the
    /// Status task window / `sprigctl status` ("battery 23%",
    /// "metered connection", …).
    case pause(reason: String)
}

/// Decides, per scheduler tick, whether background sync should run.
///
/// Implementations must be cheap and non-blocking — the scheduler
/// calls this on every tick. Signal subscriptions (power/network
/// notifications) belong inside the adapter; `decision()` just reads
/// the latest cached state.
public protocol SyncPolicy: Sendable {
    func decision() -> SyncPolicyDecision
}

/// Portable default: never pauses. The right policy wherever the
/// ADR 0064 platform signals aren't implemented yet (Linux today)
/// and for tests.
public struct AlwaysAllowSyncPolicy: SyncPolicy {
    public init() {}

    public func decision() -> SyncPolicyDecision {
        .allow
    }
}
