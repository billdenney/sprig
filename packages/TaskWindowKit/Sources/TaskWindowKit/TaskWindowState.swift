// TaskWindowState.swift
//
// The shared lifecycle enum every task-window view model exposes.
// Defined here once so the Mac SwiftUI shell, the Windows swift-cross-ui
// shell, and the portable test layer all read the same state machine.
//
// Tier 1, portable. No UI framework imports. Per ADR 0048, view models
// live in `TaskWindowKit`; the per-platform shells in
// `apps/{macos,windows}/` bind to these states with their native
// rendering primitives.

import Foundation

/// The lifecycle phase a task-window operation is currently in.
///
/// Each task-window view model owns one of these per long-running
/// operation it surfaces. State transitions go:
/// ``idle`` → ``busy`` → ``success`` *or* ``failure``, with an explicit
/// reset back to ``idle`` (a model may also re-enter ``busy`` directly
/// from ``success`` / ``failure`` for "run it again" UX).
///
/// **Sendable.** The state crosses actor boundaries every time a view
/// model emits an update or a snapshot is captured for a test.
///
/// **Equatable.** Comparison uses ``Failure``'s description-based
/// equality (since `any Error` isn't `Equatable` in general); two
/// failures are equal iff their descriptions match.
public enum TaskWindowState<Success: Sendable & Equatable>: Sendable, Equatable {
    /// No operation in flight. Either the model just initialized, or a
    /// caller invoked ``reset`` after a terminal state.
    case idle

    /// Operation in flight. `progress` is a 0...1 fraction when the
    /// underlying op can report it (git fetch / clone with `--progress`,
    /// for instance); `nil` for ops that have no fine-grained signal.
    case busy(progress: Double?)

    /// Operation completed successfully. The associated value carries
    /// whatever the operation produced (a cloned repo URL, a list of
    /// changed files, a commit SHA…).
    case success(Success)

    /// Operation failed. The ``Failure`` carries the user-presentable
    /// description plus, when available, the underlying error's type
    /// name for diagnostics.
    case failure(Failure)

    /// Failure information surfaced from a task-window operation.
    ///
    /// Holds a user-presentable `description` plus an optional
    /// `underlyingTypeName` (e.g. `"GitError.nonZeroExit"`) so
    /// diagnostics tooling can categorize without needing the full
    /// typed error to cross the actor boundary. The underlying error
    /// itself is intentionally **not** carried — `any Error` doesn't
    /// satisfy `Sendable` or `Equatable` cleanly, and the description
    /// is what the UI surfaces anyway.
    public struct Failure: Sendable, Equatable {
        /// Short user-presentable error message.
        public let description: String

        /// Optional Swift type name of the underlying error (e.g.
        /// `"GitError.nonZeroExit"`), captured at the call site for
        /// diagnostics. Diagnostics tooling can filter / group by this;
        /// the UI typically only shows `description`.
        public let underlyingTypeName: String?

        public init(description: String, underlyingTypeName: String? = nil) {
            self.description = description
            self.underlyingTypeName = underlyingTypeName
        }

        /// Build a ``Failure`` from a thrown error. Uses
        /// `String(describing:)` for the message and the runtime type
        /// for the type name. Callers that want a cleaner message
        /// should construct the failure manually instead.
        public init(from error: any Error) {
            self.description = String(describing: error)
            self.underlyingTypeName = String(reflecting: type(of: error))
        }
    }
}

// MARK: - Convenience accessors

public extension TaskWindowState {
    /// True iff the state is ``busy``. Convenient for "disable this
    /// button while running" bindings.
    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    /// True iff the state is a terminal one (``success`` or
    /// ``failure``). The model is willing to be reset back to
    /// ``idle`` from here.
    var isTerminal: Bool {
        switch self {
        case .success, .failure: true
        case .idle, .busy: false
        }
    }

    /// The success payload if the state is ``success``; nil otherwise.
    var successValue: Success? {
        if case let .success(value) = self { return value }
        return nil
    }

    /// The failure payload if the state is ``failure``; nil otherwise.
    var failure: Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}
