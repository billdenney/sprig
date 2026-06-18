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
/// with the same op tag no longer collide: the second is minted under
/// a `-2` (then `-3`, …) op-segment suffix so both survive — see ``createSnapshot(op:target:)``
/// for the exact suffix scheme and the runaway guard.
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

    /// Upper bound on same-second, same-op snapshots before
    /// ``createSnapshot(op:target:)`` fails closed with
    /// ``SnapshotWriterError/collisionLimitExceeded(op:)``. The op-suffix
    /// space is effectively unbounded; this only guards against a runaway
    /// loop (e.g. a probe that always reports "exists"). No real workload
    /// mints anywhere near this many destructive-op snapshots of one kind
    /// inside a single wall-clock second.
    private static let sameSecondLimit = 1000

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
    /// **Same-second collision handling.** If two snapshots are written
    /// in the same wall-clock second with the same op tag, the base ref
    /// name (`…/<ts>/<op>`) is already taken, so the second snapshot is
    /// minted under `…/<ts>/<op>-2` (a third under `-3`, and so on). The
    /// `-N` suffix lives on the op segment, which ``SnapshotRefName``
    /// already accepts as a valid op (`[a-z][a-z0-9-]{0,63}`) and which
    /// the read path (`RepoState.SnapshotIndex`) treats as an opaque tag,
    /// so every snapshot survives and stays enumerable / recoverable.
    /// The base op tag and timestamp stay truthful — we do not bump the
    /// clock the way ``WorktreeBackup`` does, because the op segment has a
    /// clean suffix slot that the branch-labelled backup refs lack.
    ///
    /// The `target` is resolved to a concrete object id **once**, up
    /// front (as ``WorktreeBackup`` resolves its commit before minting),
    /// so a moving `HEAD` cannot slip across same-second retries, and a
    /// malformed `target` surfaces as ``GitError`` here before any ref is
    /// written. The ref itself is created atomically (see
    /// ``mintUniqueSnapshot(op:timestamp:target:)``), so a concurrent
    /// writer can never silently clobber a snapshot.
    ///
    /// - Throws: ``SnapshotWriterError/collisionLimitExceeded(op:)`` if
    ///   the same op collides more times in one second than
    ///   ``sameSecondLimit``, or the `-N` suffix would push the op past
    ///   ``SnapshotRefName/isValidOp(_:)``'s 64-char cap — a runaway
    ///   guard that never trips on a real workload.
    @discardableResult
    public func createSnapshot(
        op: String,
        target: String = "HEAD"
    ) async throws -> SnapshotRefName {
        guard SnapshotRefName.isValidOp(op) else {
            throw SnapshotWriterError.invalidOp(op)
        }
        let timestamp = clock()
        // Pin the target to a concrete object id before minting any ref
        // so every same-second retry writes the identical object (and a
        // bad target fails here, before any ref is written).
        let pinnedTarget = try await runner.run(["rev-parse", "--verify", target])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await mintUniqueSnapshot(op: op, timestamp: timestamp, target: pinnedTarget)
    }

    /// Write `target` to the first vacant `…/<ts>/<op>[-N]` ref this
    /// second, atomically. The op-suffix uniquifier keeps every
    /// same-second snapshot of the same op distinct so none clobbers
    /// another.
    ///
    /// The write uses `git update-ref --stdin`'s `create`, which verifies
    /// the ref does **not** exist *under the ref lock* before writing — so
    /// two writers racing for the same name can't both win, and the loser
    /// fails closed and advances to the next suffix instead of silently
    /// overwriting the winner's snapshot (the old unguarded `update-ref`
    /// blind-overwrote). A failed `create` is classified by re-checking
    /// existence (exit code, not git's version- / locale-dependent
    /// stderr): if the name is now taken, advance; otherwise it is a real
    /// git failure (lock contention, I/O) and surfaces as ``GitError``.
    private func mintUniqueSnapshot(
        op: String,
        timestamp: Date,
        target: String
    ) async throws -> SnapshotRefName {
        for attempt in 0 ..< SnapshotWriter.sameSecondLimit {
            // attempt 0 -> "<op>"; attempt N -> "<op>-<N+1>" (the first
            // collision yields "<op>-2", matching the documented shape).
            let candidateOp = attempt == 0 ? op : "\(op)-\(attempt + 1)"
            guard let snapshot = SnapshotRefName(timestamp: timestamp, op: candidateOp) else {
                // The "-N" suffix pushed the op past isValidOp (the
                // 64-char cap); nothing longer will fit either.
                throw SnapshotWriterError.collisionLimitExceeded(op: op)
            }
            let create = try await runner.run(
                ["update-ref", "--stdin"],
                stdin: Data("create \(snapshot.refName) \(target)\n".utf8),
                throwOnNonZero: false
            )
            if create.exitCode == 0 { return snapshot }
            // The create failed. If the name is already taken this second,
            // move to the next suffix; otherwise it is a genuine failure.
            let exists = try await runner.run(
                ["rev-parse", "--quiet", "--verify", snapshot.refName],
                throwOnNonZero: false
            )
            guard exists.exitCode == 0 else {
                throw GitError.nonZeroExit(
                    command: ["update-ref", "--stdin", "create", snapshot.refName, target],
                    exitCode: create.exitCode,
                    stderr: create.stderrString,
                    stdout: create.stdoutString
                )
            }
        }
        throw SnapshotWriterError.collisionLimitExceeded(op: op)
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

    /// More same-second snapshots of one op were requested than
    /// ``SnapshotWriter`` will uniquify with the `-2`/`-3`/… suffix
    /// search, or the suffix would exceed ``SnapshotRefName/isValidOp(_:)``'s
    /// length cap. Signals a runaway caller, not a routine collision.
    /// The associated value is the base op tag that could not be placed.
    case collisionLimitExceeded(op: String)
}
