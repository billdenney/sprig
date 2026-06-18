// SelectiveSyncViewModel.swift
//
// ADR 0089 — the portable engine behind the "Choose folders to keep on
// this Mac…" task window: a checkbox list of the repo's top-level
// folders backed by cone-mode sparse-checkout. Unchecking a folder
// removes it from this computer's working copy only — history is
// untouched and it returns on re-check.
//
// Tier 1, portable. Shells bind to ``directories``, ``isEnabled``,
// ``blocked``, and ``state``.
//
// Safety posture (the reason this VM exists rather than calling
// `git sparse-checkout` directly): dropping a folder that holds
// uncommitted or untracked work is the one way this otherwise-lossless
// feature can lose data. So ``apply()`` fails CLOSED — it refuses and
// reports ``blocked`` rather than letting git strand or silently
// de-materialize the work. The user can then choose
// ``applyRemovingUnsavedWork()``, which mints an ADR 0075
// ``WorktreeBackup`` (capturing tracked changes AND untracked files)
// BEFORE forcibly clearing the folders — so the removed work is always
// recoverable from the Recover surface. The undo-round-trip test proves
// it comes back byte-for-byte.

import Foundation
import GitCore
import SafetyKit

/// View model for the selective-sync (folder picker) task window.
public actor SelectiveSyncViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL

    /// Whether cone-mode sparse-checkout is currently on.
    public private(set) var isEnabled: Bool = false

    /// True when the repo has sparse-checkout on but NOT in cone mode
    /// (hand-crafted patterns). The picker is cone-only, so it shows the
    /// folders read-only and refuses to apply rather than mangle the
    /// pattern file.
    public private(set) var isUnsupportedPatternMode: Bool = false

    /// One entry per top-level folder, with its keep/drop checkbox
    /// state. The UI mutates these via ``setKept(_:_:)`` then calls
    /// ``apply()``.
    public private(set) var directories: [DirectoryChoice] = []

    /// Folders the most recent ``apply()`` refused to drop because they
    /// hold uncommitted / untracked work. Empty unless the last apply
    /// was blocked; the UI surfaces a "remove anyway (saves a backup)"
    /// affordance bound to ``applyRemovingUnsavedWork()``.
    public private(set) var blocked: [DirtyDirectory] = []

    /// The backup minted by the most recent
    /// ``applyRemovingUnsavedWork()``, for the undo banner. Nil until a
    /// force-removal actually saves work.
    public private(set) var lastBackup: BackupRefName?

    /// Lifecycle of the latest operation. Success payload carries the
    /// resulting kept set (and the backup ref when a force-removal
    /// saved work).
    public private(set) var state: TaskWindowState<SelectiveSyncResult> = .idle

    private let sparse: SparseCheckout
    private let backup: WorktreeBackup

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        sparse = SparseCheckout(runner: runner)
        backup = WorktreeBackup(runner: runner)
    }

    // MARK: - Reads

    /// Re-read the top-level folders and the current cone, rebuilding
    /// ``directories`` and ``isEnabled``.
    public func refresh() async {
        do {
            try await loadSelection()
            blocked = []
            state = .success(SelectiveSyncResult(keptDirectories: keptNames(), backupRef: nil))
        } catch {
            directories = []
            blocked = []
            state = .failure(.init(from: error))
        }
    }

    /// Toggle a folder's keep/drop checkbox. Local only — nothing
    /// touches git until ``apply()``.
    public func setKept(_ name: String, _ kept: Bool) {
        guard let index = directories.firstIndex(where: { $0.name == name }) else { return }
        directories[index].isKept = kept
    }

    // MARK: - Apply

    /// Apply the current checkbox selection. Fails closed: if dropping a
    /// folder would strand uncommitted / untracked work, it refuses,
    /// records ``blocked``, and does not touch the worktree.
    public func apply() async {
        await runApply(removingUnsavedWork: false)
    }

    /// Apply the selection, force-removing folders that hold unsaved
    /// work — after first capturing the whole working tree into a
    /// recoverable ``WorktreeBackup``. The removed work lands in
    /// ``lastBackup`` and is restorable from the Recover surface.
    public func applyRemovingUnsavedWork() async {
        await runApply(removingUnsavedWork: true)
    }

    /// Turn selective sync off entirely, restoring the full worktree.
    public func disableSelectiveSync() async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            try await sparse.disable()
            try await loadSelection()
            blocked = []
            state = .success(SelectiveSyncResult(keptDirectories: keptNames(), backupRef: nil))
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset operation state to idle (keeps the folder list).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    private func runApply(removingUnsavedWork: Bool) async {
        if case .busy = state { return }
        if isUnsupportedPatternMode {
            state = .failure(.init(description: TaskWindowVocabulary.selectiveSyncAdvancedPatterns))
            return
        }
        state = .busy(progress: nil)
        let target = keptNames()
        do {
            let plan = try await sparse.planChange(to: target)
            if !plan.isCleanToApply, !removingUnsavedWork {
                blocked = plan.blockedDrops
                state = .failure(.init(
                    description: TaskWindowVocabulary.selectiveSyncBlocked(plan.blockedDrops.map(\.name))
                ))
                return
            }

            var backupRef: String?
            if removingUnsavedWork, !plan.blockedDrops.isEmpty {
                let made = try await backup.createBackupIfDirty()
                lastBackup = made
                backupRef = made?.refName
                try await sparse.forciblyClearDirectories(plan.blockedDrops.map(\.name))
            }

            if !isEnabled {
                try await sparse.enableConeMode()
            }
            try await sparse.set(target)
            blocked = []
            try await loadSelection()
            state = .success(SelectiveSyncResult(keptDirectories: target, backupRef: backupRef))
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Rebuild ``isEnabled`` + ``directories`` from the live cone state.
    private func loadSelection() async throws {
        let topLevel = try await sparse.topLevelDirectories()
        switch try await sparse.currentSelection() {
        case .full:
            isEnabled = false
            isUnsupportedPatternMode = false
            directories = topLevel.map { DirectoryChoice(name: $0, isKept: true) }
        case let .cone(kept):
            isEnabled = true
            isUnsupportedPatternMode = false
            let keptSet = Set(kept)
            directories = topLevel.map { DirectoryChoice(name: $0, isKept: keptSet.contains($0)) }
        case .unsupportedPatternMode:
            isEnabled = true
            isUnsupportedPatternMode = true
            directories = topLevel.map { DirectoryChoice(name: $0, isKept: true) }
        }
    }

    private func keptNames() -> [String] {
        directories.filter(\.isKept).map(\.name).sorted()
    }
}

// MARK: - Model

/// One top-level folder plus its keep/drop checkbox state.
public struct DirectoryChoice: Sendable, Equatable {
    public let name: String
    public var isKept: Bool

    public init(name: String, isKept: Bool) {
        self.name = name
        self.isKept = isKept
    }
}

/// Success payload for a selective-sync apply.
public struct SelectiveSyncResult: Sendable, Equatable {
    /// The folders now kept on disk.
    public let keptDirectories: [String]
    /// The backup ref minted when a force-removal saved unsaved work;
    /// nil for a clean apply.
    public let backupRef: String?

    public init(keptDirectories: [String], backupRef: String?) {
        self.keptDirectories = keptDirectories
        self.backupRef = backupRef
    }
}
