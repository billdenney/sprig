// SnapshotWriter.swift
//
// Slice S2 of ADR 0033 — invoke `git update-ref` to write the snapshot
// ref a destructive operation needs in order to be reversible. Slice S1
// (`SnapshotRefName`) defined the on-disk shape; this file drives git
// to put bytes there, plus the slice S4 ``withSnapshot`` helper that
// wraps any destructive op in an automatic snapshot.
//
// What this is NOT:
//   - A snapshot enumerator / pruner. That's `RepoState.SnapshotIndex`
//     per ADR 0033's amendment — read path, separate slice.
//   - The destructive-op call sites themselves. The merge / rebase /
//     reset-hard / etc. callers each invoke ``withSnapshot`` (or
//     ``createSnapshot`` directly) at their op boundary; this file
//     supplies the safety primitive, not the orchestration.

import Foundation
import GitCore

/// Writes ADR 0033 snapshot refs (`refs/sprig/snapshots/<ts>/<op>`) by
/// shelling out to `git update-ref`. One writer per repo (the wrapped
/// ``Runner`` carries the repo's working directory).
///
/// **Sendable.** The writer is a value type whose only mutable state is
/// behind the runner; both can cross actor boundaries safely.
///
/// **Clock-injectable.** The default constructor uses `Date()`; tests
/// pass a deterministic closure so the resulting ref name is
/// predictable. Two snapshots produced at the same wall-clock second
/// with the same op tag will collide on the same ref name and the
/// second write will overwrite the first — see ``createSnapshot(op:target:)``
/// for why we accept that today and how a future slice can fix it.
public struct SnapshotWriter: Sendable {
    /// `Runner` configured against the repo to snapshot.
    public let runner: Runner

    /// Source of "now" for snapshot timestamps. Tests inject a fixed
    /// or scripted closure; production uses ``defaultClock``.
    public let clock: @Sendable () -> Date

    /// `{ Date() }` lifted to a `@Sendable` closure once at module load
    /// rather than every call site. Static and not exposed as the
    /// default parameter directly because Swift 6's strict-concurrency
    /// checking won't accept `Date.init` as `@Sendable` without a
    /// trampoline.
    public static let defaultClock: @Sendable () -> Date = { Date() }

    public init(
        runner: Runner,
        clock: @Sendable @escaping () -> Date = SnapshotWriter.defaultClock
    ) {
        self.runner = runner
        self.clock = clock
    }

    /// Create a snapshot ref pointing at `target`.
    ///
    /// Generates the timestamp from ``clock`` at call time and builds a
    /// ``SnapshotRefName`` from `(timestamp, op)`. Then runs:
    ///
    /// ```
    /// git update-ref refs/sprig/snapshots/<ts>/<op> <target>
    /// ```
    ///
    /// `target` accepts anything `git update-ref`'s newvalue accepts —
    /// most callers pass `"HEAD"` (the default). A SHA, a branch name,
    /// or any other revspec git can dereference also works.
    ///
    /// - Returns: The resolved ``SnapshotRefName`` so callers can log
    ///   it, surface it in destructive-op task-window header strips
    ///   (per ADR 0033's amendment), or include it in audit traces.
    /// - Throws: ``SnapshotWriterError/invalidOp(_:)`` if `op` doesn't
    ///   match ``SnapshotRefName/isValidOp(_:)``; ``GitError`` from the
    ///   underlying invocation (ref-existence collisions surface as
    ///   ``GitError/nonZeroExit`` if `git update-ref` decides to
    ///   reject).
    ///
    /// **Same-second collision behavior.** If two snapshots are written
    /// in the same wall-clock second with the same op tag, both produce
    /// the identical ref name; the second `git update-ref` call moves
    /// the ref to the new target. The earlier snapshot is "lost"
    /// (no longer reachable from a Sprig ref name; the underlying
    /// commit is reachable via reflog or other refs until git's gc).
    /// This is acceptable today because (a) two destructive ops in the
    /// same second on the same op tag is rare, (b) tests using a fixed
    /// clock can disambiguate via the `op` argument, and (c) a future
    /// slice can add a `-2`, `-3`, … uniquifier without breaking the
    /// `SnapshotRefName` parser (which already accepts that shape).
    @discardableResult
    public func createSnapshot(
        op: String,
        target: String = "HEAD"
    ) async throws -> SnapshotRefName {
        guard let snapshot = SnapshotRefName(timestamp: clock(), op: op) else {
            throw SnapshotWriterError.invalidOp(op)
        }
        _ = try await runner.run(["update-ref", snapshot.refName, target])
        return snapshot
    }

    /// Wrap a destructive operation in an automatic snapshot.
    ///
    /// Creates the snapshot ref (via ``createSnapshot(op:target:)``) and
    /// then awaits `body`, passing the resulting ``SnapshotRefName`` so
    /// the caller can log it, surface it in a task-window header strip
    /// (per ADR 0033 amendment §13.3-A), or hand it to a "Revert this
    /// operation" button.
    ///
    /// **Failure semantics.** If `body` throws, ``withSnapshot`` rethrows
    /// the same error — but the snapshot ref has *already been written
    /// to git refs* before `body` ran, so callers can recover the
    /// pre-op state via `git update-ref HEAD <snapshot.refName>` (or
    /// surface it through `sprigctl recover` / the Recover task window).
    /// This is the entire point of the helper: the snapshot must outlive
    /// the body's success or failure for the safety net to work.
    ///
    /// **Errors from the snapshot step.** If snapshot creation itself
    /// fails (``SnapshotWriterError/invalidOp(_:)`` for a malformed op
    /// tag, or a ``GitError`` from `git update-ref`), `body` is **not**
    /// invoked. The caller sees only the snapshot-creation error and
    /// can decide whether to retry, abort, or run the op unsnapshotted.
    ///
    /// **Tier matching.** Callers should look up
    /// ``DestructiveOpTier/tier(for:)`` for the same `op` string before
    /// deciding whether to call ``withSnapshot``: ``DestructiveOpTier/low``
    /// ops don't need snapshots, ``medium`` and ``high`` do.
    ///
    /// - Parameters:
    ///   - op: Op tag for the snapshot ref. Must satisfy
    ///     ``SnapshotRefName/isValidOp(_:)``; typically one of the
    ///     ``SnapshotRefName`` `opXxx` constants.
    ///   - target: Revspec the snapshot ref points to. Defaults to
    ///     `"HEAD"` (the common case — snapshot the current commit
    ///     before mutating it). Any input `git update-ref` accepts as a
    ///     newvalue works (SHA, branch, etc.).
    ///   - body: The destructive operation. Receives the
    ///     ``SnapshotRefName`` so it can log / display the ref.
    /// - Returns: Whatever `body` returns.
    /// - Throws: ``SnapshotWriterError/invalidOp(_:)`` or ``GitError`` if
    ///   snapshot creation fails (body is not invoked); rethrows
    ///   whatever `body` throws after the snapshot has been written.
    @discardableResult
    public func withSnapshot<T>(
        op: String,
        target: String = "HEAD",
        _ body: (SnapshotRefName) async throws -> T
    ) async throws -> T {
        let snapshot = try await createSnapshot(op: op, target: target)
        return try await body(snapshot)
    }
}

/// Errors thrown by ``SnapshotWriter``.
///
/// `GitError` from the underlying `git update-ref` invocation passes
/// through unchanged; only mistakes detected before spawning git
/// surface as a `SnapshotWriterError`.
public enum SnapshotWriterError: Error, Equatable, Sendable {
    /// `op` failed ``SnapshotRefName/isValidOp(_:)``. The associated
    /// value is the offending input — useful for diagnostics, not for
    /// programmatic dispatch.
    case invalidOp(String)
}
