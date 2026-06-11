// StashViewModel.swift
//
// ADR 0079 — the portable engine behind the Stash task window: one
// list of every set-aside entry with apply / pop / drop verbs. The
// window answers the beginner's "where did my set-aside changes go?"
// (the recovery/visibility face of affordance 1.3's auto-stash; the
// window's "set aside now" button binds to ADR 0069's existing
// `StashOps.push`).
//
// Tier 1, portable. Shells bind to ``entries`` and ``state``.
//
// Identity discipline: reflog selectors (`stash@{N}`) shift whenever
// an entry is popped or dropped, so a list the user has been staring
// at can go stale the moment anything else touches the stash. Every
// verb therefore re-resolves its ``StashEntry`` by **commit SHA**
// against a fresh list before acting — acting on the wrong entry is
// the one failure mode a browser over a mutable index must never
// have. A vanished entry is a worded validation failure, not a
// misfire.
//
// Safety pairing (ADR 0033 via SafetyKit): dropping is the only
// destructive verb here, and unlike branch hygiene there is no
// "already safe" stash entry — a stash is by definition work saved
// nowhere else. So the only drop verb is ``dropKeepingSafetyCopy(_:)``
// (medium tier): snapshot the stash commit under
// `refs/sprig/snapshots/…/stash-drop` first, then drop. Restoring
// that safety copy is the Recover surface's stash-aware path
// (`git stash store` — see RecoverViewModel).

import Foundation
import GitCore
import SafetyKit

/// View model for the Stash task window. Construct with the repo's
/// runner; ``refresh()`` populates ``entries``; the verbs re-resolve
/// entries by SHA so a stale list can't misfire.
public actor StashViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Set-aside entries from the latest listing, newest first.
    public private(set) var entries: [StashEntry] = []

    /// Lifecycle of the latest operation. Success payload is the
    /// affected entry's subject (or "" for refresh).
    public private(set) var state: TaskWindowState<String> = .idle

    /// Snapshot ref written by the most recent
    /// ``dropKeepingSafetyCopy(_:)``, for the undo banner.
    public private(set) var lastSafetyCopy: SnapshotRefName?

    private let stash: StashOps
    private let snapshots: SnapshotWriter

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        stash = StashOps(runner: runner)
        snapshots = SnapshotWriter(runner: runner)
    }

    /// Re-read the stash list.
    public func refresh() async {
        do {
            entries = try await stash.list()
            state = .success("")
        } catch {
            entries = []
            state = .failure(.init(from: error))
        }
    }

    /// Re-apply an entry's changes to the working tree, keeping the
    /// entry (apply never drops). A conflicted apply is a worded
    /// failure — markers are in the files and the set-aside copy is
    /// untouched, so nothing is lost.
    public func apply(_ entry: StashEntry) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            guard let ref = try await currentRef(for: entry) else { return }
            switch try await stash.apply(ref) {
            case .applied:
                state = .success(entry.subject)
            case .conflicted:
                state = .failure(.init(
                    description: TaskWindowVocabulary.stashConflicted(entry.subject)
                ))
            }
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Apply an entry and drop it on success. A conflicted pop keeps
    /// the entry (git's contract, verified by the engine) and is
    /// worded the same as a conflicted apply.
    public func pop(_ entry: StashEntry) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            guard let ref = try await currentRef(for: entry) else { return }
            switch try await stash.pop(ref) {
            case .applied:
                await refreshEntriesQuietly()
                state = .success(entry.subject)
            case .keptDueToConflict:
                state = .failure(.init(
                    description: TaskWindowVocabulary.stashConflicted(entry.subject)
                ))
            }
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Drop an entry — ADR 0033 medium tier: snapshot the stash
    /// commit under `refs/sprig/snapshots/…/stash-drop` FIRST (a
    /// dropped entry is otherwise unreachable), then drop. The
    /// snapshot ref lands in ``lastSafetyCopy`` for the undo banner;
    /// restoring it puts the entry back in the list (Recover's
    /// stash-aware path).
    public func dropKeepingSafetyCopy(_ entry: StashEntry) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        let tier = DestructiveOpTier.tier(for: SnapshotRefName.opStashDrop)
        do {
            guard let ref = try await currentRef(for: entry) else { return }
            if tier?.requiresSnapshot == true {
                lastSafetyCopy = try await snapshots.createSnapshot(
                    op: SnapshotRefName.opStashDrop,
                    target: entry.sha
                )
            }
            _ = try await stash.drop(ref)
            await refreshEntriesQuietly()
            state = .success(entry.subject)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state (keeps the entry list).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    /// Re-resolve `entry` by commit SHA against a fresh list, keeping
    /// ``entries`` current as a side effect. Returns the entry's
    /// *current* selector, or records a worded failure and returns
    /// nil when the entry no longer exists (applied/dropped behind
    /// this VM's back).
    private func currentRef(for entry: StashEntry) async throws -> String? {
        let fresh = try await stash.list()
        entries = fresh
        guard let match = fresh.first(where: { $0.sha == entry.sha }) else {
            state = .failure(.init(
                description: TaskWindowVocabulary.stashEntryGone(entry.subject)
            ))
            return nil
        }
        return match.ref
    }

    /// Refresh ``entries`` after a verb that changed the list,
    /// without letting a listing hiccup clobber the verb's outcome.
    private func refreshEntriesQuietly() async {
        if let fresh = try? await stash.list() {
            entries = fresh
        }
    }
}
