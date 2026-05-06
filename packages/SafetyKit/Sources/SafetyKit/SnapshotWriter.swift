// SnapshotWriter.swift
//
// Slice S2 of ADR 0033 — invoke `git update-ref` to write the snapshot
// ref a destructive operation needs in order to be reversible. Slice S1
// (`SnapshotRefName`) defined the on-disk shape; this file actually
// drives git to put bytes there.
//
// What this is NOT (yet):
//   - A higher-level "wrap a destructive op in a snapshot" helper. That
//     belongs at the destructive-op call sites (merge, rebase, …) and
//     lands as those features are built out.
//   - A snapshot enumerator / pruner. That's `RepoState.SnapshotIndex`
//     per ADR 0033's amendment — read path, separate slice.

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
