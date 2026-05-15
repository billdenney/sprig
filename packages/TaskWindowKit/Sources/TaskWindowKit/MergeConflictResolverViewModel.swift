// MergeConflictResolverViewModel.swift
//
// M4 MVP-gate view model — the portable engine behind the
// macOS/Windows "Resolve Conflicts…" task window. Surfaces the
// classified conflict inventory, holds the user's per-path choices,
// applies them to disk, and finalizes the merge.
//
// Tier 1, portable. Per ADR 0048, view models live here; the per-OS
// shells in `apps/{macos,windows}/` bind to this VM's `conflicts`,
// `choices`, `resolvedPaths`, and `state`.
//
// What this VM owns:
//   - The classified conflict inventory (via UnmergedListing +
//     ConflictKind).
//   - Per-path resolution choices (`ConflictedPathChoice`).
//   - Apply: read the chosen stage's blob via `CatFileBatch`, write
//     to disk, `git add`. For submodule stages, swaps in
//     `git update-index --cacheinfo` since the "blob" is a commit
//     SHA, not bytes to write.
//   - Finalize: `git commit` (auto-uses MERGE_MSG so the merge
//     commit message reads "Merge branch 'feature-x' …" without
//     the VM crafting one).
//   - Abort: `git merge --abort`.
//
// What this VM doesn't own (deliberately, for the MVP cut):
//   - Per-region text resolution (`ConflictedFile.applying(_:)`
//     with per-`ConflictRegion` choices). Whole-side picks
//     (`ours` / `theirs` / `base`) cover the table-stakes
//     affordance; per-region polish lands in a follow-up once the
//     diff-rendering selection UX is wired.
//   - Rebase / cherry-pick / am state finalization. The merge case
//     is the most common; the other midstream states (per master
//     plan §10 Tier 1) become their own `finalize` branches in a
//     follow-up that detects `<gitDir>/REBASE_HEAD`,
//     `<gitDir>/CHERRY_PICK_HEAD`, etc.
//   - LFS pointer auto-fetch. A whole-side pick of an LFS-pointer
//     file lands the chosen pointer; the agent layer triggers
//     `git lfs fetch` on the resulting working-tree state.
//   - AI-suggested resolutions. ADR 0028 gates this on M7; the VM
//     surface stays AI-free at M4 to keep MVP non-AI per the
//     `MVP ASAP` direction.

import ConflictKit
import Foundation
import GitCore

/// View model for the Resolve Conflicts task window. Holds the
/// classified inventory + per-path choices + lifecycle state.
///
/// **Actor-isolated.** All mutable state lives behind the actor.
///
/// **Lifecycle.** Construct with the repo URL + Runner + (optionally)
/// a `ConflictProbes` for binary / LFS detection (defaults to
/// `.none`, which means everything that isn't submodule or add/add
/// classifies as `.text`). Call ``refresh()`` to populate
/// ``conflicts``. The UI calls ``choose(path:_:)`` per row;
/// ``applyAll()`` walks every non-pending choice and writes it to
/// disk + git-adds. ``finalize()`` runs `git commit` once every path
/// is resolved; ``abort()`` runs `git merge --abort` to throw away
/// the merge.
public actor MergeConflictResolverViewModel {
    public let repoURL: URL

    /// Classified conflicts from the latest ``refresh()``. Index is
    /// the parser's order (typically the order git emits them, which
    /// is filesystem-walk order).
    public private(set) var conflicts: [ClassifiedConflict] = []

    /// Per-path user choices. Missing keys imply ``ConflictedPathChoice/pending``.
    public private(set) var choices: [String: ConflictedPathChoice] = [:]

    /// Paths that ``applyAll()`` (or ``applyOne(path:)``) has
    /// successfully written + staged. A path lands here after `git
    /// add` succeeds for the chosen side.
    public private(set) var resolvedPaths: Set<String> = []

    /// State of the latest refresh / apply / finalize / abort call.
    /// Success payload is the **remaining unresolved count** — the
    /// number of `conflicts` entries whose path is NOT in
    /// `resolvedPaths`. Zero means the user can call ``finalize()``.
    public private(set) var state: TaskWindowState<Int> = .idle

    private let runner: Runner
    private let probes: ConflictProbes
    private var runningTask: Task<Void, Never>?

    public init(
        repoURL: URL,
        runner: Runner,
        probes: ConflictProbes = .none
    ) {
        self.repoURL = repoURL
        self.runner = runner
        self.probes = probes
    }

    // MARK: - Inventory

    /// Re-read the conflicted-path inventory via
    /// `git ls-files -u -z` + classify each entry. Preserves any
    /// existing ``choices`` for paths that survived; drops choices
    /// for paths that are no longer conflicted.
    public func refresh() async {
        do {
            let output = try await runner.run(["ls-files", "-u", "-z"])
            let entries = try UnmergedListing.parse(output.stdout)
            let classified = ConflictKind.classifyAll(entries, probes: probes)
            conflicts = classified
            let survivingPaths = Set(classified.map(\.entry.path))
            choices = choices.filter { survivingPaths.contains($0.key) }
            resolvedPaths.formIntersection(survivingPaths)
            state = .success(unresolvedCount)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Set the choice for a path. No-ops silently if the path isn't
    /// in the current ``conflicts`` set — keeps callers from picking
    /// stale paths via timing races (e.g. the UI clicks a row that
    /// a refresh just dropped).
    public func choose(path: String, _ choice: ConflictedPathChoice) {
        guard conflicts.contains(where: { $0.entry.path == path }) else { return }
        choices[path] = choice
    }

    /// Drop the choice for a path (back to ``ConflictedPathChoice/pending``).
    /// Does NOT undo a prior ``applyOne(path:)`` — the working tree
    /// stays as it was; only the in-memory choice clears.
    public func clearChoice(for path: String) {
        choices.removeValue(forKey: path)
        resolvedPaths.remove(path)
    }

    /// Remaining unresolved paths (those whose entry isn't in
    /// ``resolvedPaths``).
    public var unresolvedCount: Int {
        conflicts.count - resolvedPaths.count
    }

    /// True when every conflict has been applied. ``finalize()``
    /// becomes valid here.
    public var isFullyResolved: Bool {
        !conflicts.isEmpty && resolvedPaths.count == conflicts.count
    }

    // MARK: - Apply

    /// Apply a single path's currently-chosen resolution. Reads the
    /// chosen stage's blob via `git cat-file --batch`, writes it to
    /// the working tree, runs `git add`. For submodule stages,
    /// substitutes `git update-index --cacheinfo`.
    ///
    /// Throws via the `state` transition if:
    /// - the path isn't in the current inventory
    /// - the choice is ``ConflictedPathChoice/pending``
    /// - ``ConflictedPathChoice/base`` was chosen but the entry has
    ///   no base stage (add/add conflict)
    /// - the chosen stage SHA is missing for any reason
    public func applyOne(path: String) async {
        guard let conflict = conflicts.first(where: { $0.entry.path == path }) else {
            state = .failure(.init(description: "No conflict at path '\(path)'."))
            return
        }
        guard let choice = choices[path], choice.isResolved else {
            state = .failure(.init(description: "Pick a side for '\(path)' first."))
            return
        }
        await runApply([(conflict, choice)])
    }

    /// Apply every path whose choice is non-pending. Skips paths
    /// that are already in ``resolvedPaths`` (idempotent).
    public func applyAll() async {
        var batch: [(ClassifiedConflict, ConflictedPathChoice)] = []
        for conflict in conflicts {
            guard let choice = choices[conflict.entry.path], choice.isResolved else { continue }
            if resolvedPaths.contains(conflict.entry.path) { continue }
            batch.append((conflict, choice))
        }
        if batch.isEmpty {
            state = .failure(.init(description: "No paths have a resolution to apply."))
            return
        }
        await runApply(batch)
    }

    // MARK: - Finalize / abort

    /// Complete the merge: `git commit` (which uses `.git/MERGE_MSG`
    /// for the message automatically). Rejected if any path is
    /// still unresolved.
    public func finalize() async {
        if case .busy = state { return }
        guard !conflicts.isEmpty else {
            state = .failure(.init(description: "No conflicts to finalize."))
            return
        }
        guard isFullyResolved else {
            state = .failure(.init(
                description: "\(unresolvedCount) path(s) still unresolved."
            ))
            return
        }
        await runGit(["commit", "--no-edit"])
    }

    /// Abandon the merge — `git merge --abort`. Resets working tree
    /// to pre-merge state. All in-memory choices are dropped; the
    /// next ``refresh()`` will return an empty inventory.
    public func abort() async {
        if case .busy = state { return }
        await runGit(["merge", "--abort"])
        choices = [:]
        resolvedPaths = []
        conflicts = []
    }

    /// Cancel the in-flight op.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset state to `.idle` while preserving inventory + choices +
    /// resolvedPaths. Cancels in-flight op.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private impl

    private func runApply(
        _ batch: [(ClassifiedConflict, ConflictedPathChoice)]
    ) async {
        if case .busy = state { return }
        state = .busy(progress: nil)

        let repoURL = self.repoURL
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                let catFile = try await CatFileBatch(repoURL: repoURL)
                defer { Task { await catFile.close() } }
                for (conflict, choice) in batch {
                    try await Self.applySingle(
                        conflict: conflict,
                        choice: choice,
                        repoURL: repoURL,
                        runner: runner,
                        catFile: catFile
                    )
                    await self?.recordResolved(path: conflict.entry.path)
                }
                await self?.recordApplySuccess()
            } catch is CancellationError {
                await self?.recordFailure(.init(description: "Apply cancelled."))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }
        await runningTask?.value
    }

    private static func applySingle(
        conflict: ClassifiedConflict,
        choice: ConflictedPathChoice,
        repoURL: URL,
        runner: Runner,
        catFile: CatFileBatch
    ) async throws {
        guard let stageNumber = choice.stage else {
            throw MergeApplyError.pending(path: conflict.entry.path)
        }
        guard let stage = conflict.entry.stages.first(where: { $0.stage == stageNumber }) else {
            throw MergeApplyError.missingStage(
                path: conflict.entry.path,
                stage: stageNumber
            )
        }
        switch stage.mode {
        case .submodule:
            // Gitlink: stage.sha is a commit SHA, not a blob. We can't
            // write bytes — we update the index directly.
            let modeOctal = String(stage.mode.rawMode, radix: 8)
            _ = try await runner.run([
                "update-index",
                "--add",
                "--cacheinfo",
                "\(modeOctal),\(stage.sha),\(conflict.entry.path)"
            ])
        case .regularFile, .executable, .symlink, .unknown:
            let blob = try await catFile.read(stage.sha)
            let target = repoURL.appendingPathComponent(conflict.entry.path)
            let parent = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try blob.content.write(to: target)
            _ = try await runner.run(["add", "--", conflict.entry.path])
        }
    }

    private func runGit(_ argv: [String]) async {
        state = .busy(progress: nil)
        let runner = self.runner
        runningTask = Task { [weak self] in
            do {
                _ = try await runner.run(argv)
                await self?.recordSuccessAfterGit()
            } catch is CancellationError {
                await self?.recordFailure(.init(description: "Cancelled."))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }
        await runningTask?.value
    }

    private func recordResolved(path: String) {
        resolvedPaths.insert(path)
    }

    private func recordApplySuccess() {
        runningTask = nil
        state = .success(unresolvedCount)
    }

    private func recordSuccessAfterGit() {
        runningTask = nil
        state = .success(unresolvedCount)
    }

    private func recordFailure(_ failure: TaskWindowState<Int>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}

/// Errors thrown by the apply pipeline. Wrapped into
/// ``TaskWindowState/failure`` for the VM's external surface; the
/// typed cases exist so diagnostics tooling can categorize.
public enum MergeApplyError: Error, Equatable, Sendable {
    /// Caller asked to apply a path whose choice is still
    /// ``ConflictedPathChoice/pending``.
    case pending(path: String)

    /// The requested stage isn't present in the conflict's entry
    /// (e.g. ``ConflictedPathChoice/base`` asked for an add/add
    /// conflict). The integer is the stage that was requested.
    case missingStage(path: String, stage: Int)
}
