// RecoverViewModel.swift
//
// ADR 0033 amendment — the Recover surface (beginner-affordances
// item 1.5, "Sprig keeps a safety copy — restore it"): ONE list of
// everything restorable, whichever engine minted it, with
// fail-closed restore verbs.
//
//   * ADR 0033 snapshots (`refs/sprig/snapshots/<ts>/<op>`) — repo
//     state captured before a destructive op. Restoring is a
//     `reset --hard` BUT with two insurance refs taken first: the
//     dirty working tree (if any) goes into an ADR 0075 backup, and
//     pre-restore HEAD gets its own snapshot — so a restore is
//     always itself undoable and never eats uncommitted work.
//   * ADR 0075 backups (`refs/sprig/backup/<ts>/<branch>`) —
//     uncommitted-work insurance. Restoring is `WorktreeBackup`'s
//     additive, fail-closed worktree write (no HEAD/index movement).
//
// Tier 1, portable. Shells bind to ``points`` and ``state``; banner
// copy rides the M3 shell slice (ADR 0072 vocabulary).

import Foundation
import GitCore
import RepoState
import SafetyKit

/// One restorable point-in-time, whichever engine minted it.
public struct RecoveryPoint: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// ADR 0033 pre-destructive-op snapshot; `op` is the tag
        /// ("rebase", "branch-delete", "restore", …).
        case snapshot(op: String)
        /// ADR 0075 auto-backup; `branchLabel` names the branch the
        /// work was sitting on.
        case backup(branchLabel: String)
    }

    public let kind: Kind
    /// Fully-qualified ref (`refs/sprig/…`) — the restore handle.
    public let refName: String
    public let sha: String
    public let timestamp: Date

    public init(kind: Kind, refName: String, sha: String, timestamp: Date) {
        self.kind = kind
        self.refName = refName
        self.sha = sha
        self.timestamp = timestamp
    }
}

/// Success payload of the latest Recover operation.
public enum RecoverOutcome: Sendable, Equatable {
    /// ``RecoverViewModel/refresh()`` completed; the list has this
    /// many points.
    case refreshed(pointCount: Int)
    /// An ADR 0075 backup was restored additively; the engine's
    /// outcome carries the pre-restore backup (nil if the tree was
    /// clean going in).
    case restoredBackup(WorktreeRestoreOutcome)
    /// An ADR 0033 snapshot was restored (`reset --hard`). Both
    /// insurance refs ride along for the undo banner:
    /// `uncommittedBackup` holds dirty work captured before the
    /// reset (nil if clean), `beforeRestore` is the snapshot of
    /// pre-restore HEAD — restoring IT undoes this restore.
    case restoredSnapshot(
        refName: String,
        beforeRestore: SnapshotRefName,
        uncommittedBackup: BackupRefName?
    )
    /// An ADR 0079 stash-drop safety copy was restored by putting the
    /// entry back in the stash list (`git stash store`) — additive;
    /// worktree and HEAD untouched, so no insurance refs ride along.
    case restoredStashEntry(refName: String)
}

/// View model for the Recover task window. Construct with the repo's
/// runner; ``refresh()`` populates ``points``; the two restore verbs
/// are fail-closed per their engine's contract.
public actor RecoverViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Everything restorable, newest first (timestamp descending;
    /// refName descending breaks same-second ties deterministically).
    public private(set) var points: [RecoveryPoint] = []

    /// Lifecycle of the latest refresh/restore.
    public private(set) var state: TaskWindowState<RecoverOutcome> = .idle

    private let runner: Runner
    private let snapshots: SnapshotIndex
    private let snapshotWriter: SnapshotWriter
    private let backups: WorktreeBackup

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
        snapshots = SnapshotIndex(runner: runner)
        snapshotWriter = SnapshotWriter(runner: runner)
        backups = WorktreeBackup(runner: runner)
    }

    /// Re-read both ref namespaces and merge into one newest-first
    /// list.
    public func refresh() async {
        do {
            try await snapshots.refresh()
            let snapshotPoints = await snapshots.list().map { snapshot in
                RecoveryPoint(
                    kind: .snapshot(op: snapshot.name.op),
                    refName: snapshot.name.refName,
                    sha: snapshot.sha,
                    timestamp: snapshot.name.timestamp
                )
            }
            let backupPoints = try await backups.backups().map { entry in
                RecoveryPoint(
                    kind: .backup(branchLabel: entry.ref.branchLabel),
                    refName: entry.ref.refName,
                    sha: entry.sha,
                    timestamp: entry.ref.timestamp
                )
            }
            points = (snapshotPoints + backupPoints).sorted {
                ($0.timestamp, $0.refName) > ($1.timestamp, $1.refName)
            }
            state = .success(.refreshed(pointCount: points.count))
        } catch {
            points = []
            state = .failure(.init(from: error))
        }
    }

    /// Restore an ADR 0075 backup — additive and fail-closed: the
    /// engine backs up the current dirty state first (so the restore
    /// can be undone), writes the backup's files over the worktree,
    /// and never touches HEAD or the index.
    public func restoreBackup(_ refName: String) async {
        if case .busy = state { return }
        guard BackupRefName.parse(refName) != nil else {
            state = .failure(.init(description: TaskWindowVocabulary.notABackupRef(refName)))
            return
        }
        state = .busy(progress: nil)
        do {
            let outcome = try await backups.restore(refName)
            state = .success(.restoredBackup(outcome))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Restore an ADR 0033 snapshot: `reset --hard <ref>` with two
    /// insurance refs taken FIRST — uncommitted work into an ADR 0075
    /// backup (a hard reset would otherwise eat it), and pre-restore
    /// HEAD into a fresh snapshot so this restore is itself undoable.
    ///
    /// **Stash-drop snapshots restore differently.** A
    /// `…/stash-drop` safety copy (ADR 0079) points at the dropped
    /// stash *commit*, not a repo state — `reset --hard` there would
    /// wrongly move the branch onto the stash commit. Restoring one
    /// means putting the entry back in the stash list
    /// (`git stash store`), which touches neither the worktree nor
    /// HEAD, so no insurance refs are needed.
    public func restoreSnapshot(_ refName: String) async {
        if case .busy = state { return }
        // Reject anything that isn't a Sprig snapshot ref before
        // touching git — `reset --hard <arbitrary-ref>` is a
        // different, more dangerous verb than Recover.
        guard let parsed = SnapshotRefName.parse(refName) else {
            state = .failure(.init(description: TaskWindowVocabulary.notASnapshotRef(refName)))
            return
        }
        state = .busy(progress: nil)
        do {
            let exists = try await runner.run(
                ["rev-parse", "--verify", "--quiet", refName],
                throwOnNonZero: false
            )
            guard exists.exitCode == 0 else {
                state = .failure(.init(
                    description: TaskWindowVocabulary.recoveryRefMissing(refName)
                ))
                return
            }
            // Pin the restore target to its SHA before minting any
            // refs: two restores inside the same second mint the SAME
            // `<ts>/restore` snapshot name, so when the user restores
            // the before-restore ref itself (the undo gesture), the
            // new before-restore snapshot would overwrite it *before*
            // the reset reads it. Resetting to the resolved SHA makes
            // each restore immune to that clobber (caught by the
            // round-trip test; same class as ADR 0075's backup
            // collision).
            let targetSHA = exists.stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if parsed.op == SnapshotRefName.opStashDrop {
                try await restoreStashEntry(refName: refName, sha: targetSHA)
                return
            }

            let uncommitted = try await backups.createBackupIfDirty()
            let beforeRestore = try await snapshotWriter.createSnapshot(
                op: SnapshotRefName.opRestore
            )
            _ = try await runner.run(["reset", "--hard", targetSHA])

            state = .success(.restoredSnapshot(
                refName: refName,
                beforeRestore: beforeRestore,
                uncommittedBackup: uncommitted
            ))
            await refreshKeepingState()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state (keeps the list).
    public func reset() {
        state = .idle
    }

    /// ADR 0079 stash-drop restore: `git stash store <sha>` puts the
    /// dropped entry back in the stash list, carrying its original
    /// subject forward as the reflog message so the restored entry
    /// reads exactly like it did before the drop.
    private func restoreStashEntry(refName: String, sha: String) async throws {
        let subject = try await runner.run(["log", "-1", "--format=%s", sha])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["stash", "store", "-m", subject, sha])
        state = .success(.restoredStashEntry(refName: refName))
        await refreshKeepingState()
    }

    /// Re-list after a successful restore without clobbering the
    /// terminal outcome the UI is presenting.
    private func refreshKeepingState() async {
        let kept = state
        await refresh()
        if case .success = state {
            state = kept
        }
    }
}
