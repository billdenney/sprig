// MergeConflictResolverViewModel.swift
//
// M4 MVP-gate VM — the portable engine behind the "Resolve
// Conflicts…" task window. Loads classified conflicts (via
// UnmergedListing + ConflictKind), holds per-path choices, applies
// them to disk, and finalizes / aborts the active midstream op
// (merge / rebase / cherry-pick / revert / am — see
// `GitCore.MidstreamOperation`).
//
// Tier 1, portable; the per-OS shells in `apps/{macos,windows}/`
// bind to this VM's `conflicts`, `choices`, `resolvedPaths`,
// `operation`, and `state`.
//
// Apply pipeline: read the chosen stage's blob via `CatFileBatch`,
// write to disk, `git add`. Submodule stages swap in
// `git update-index --cacheinfo` because the "blob" is a commit SHA.
//
// Deliberately deferred (M4 polish, not MVP):
//   - AI-suggested resolutions (ADR 0028 gates this on M7).

import ConflictKit
import Foundation
import GitCore

/// View model for the Resolve Conflicts task window — actor-isolated;
/// holds the classified inventory + per-path choices + lifecycle state.
/// Construct with repo URL + `Runner` + optional `ConflictProbes` for
/// binary / LFS detection; ``refresh()`` populates ``conflicts``;
/// ``choose(path:_:)`` sets per-path picks; ``applyAll()`` writes them
/// to disk + git-adds; ``finalize()`` / ``abort()`` dispatch through
/// ``operation``'s `git <op> --continue / --abort` argv.
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

    /// Which midstream git operation the repo is currently in
    /// (merge / rebase / cherry-pick / revert / am / none). Populated
    /// by ``refresh()``. Drives ``finalize()`` and ``abort()`` to
    /// pick the right `git <op> --continue` / `--abort` invocation
    /// — `git merge --abort` for a merge, `git rebase --continue` for
    /// a rebase, etc. Defaults to ``MidstreamOperation/none`` until
    /// the first refresh.
    public private(set) var operation: MidstreamOperation = .none

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
    /// `git ls-files -u -z` + classify each entry. Also detects the
    /// active midstream operation (``operation``) so ``finalize()``
    /// and ``abort()`` dispatch the correct `git <op>` argv.
    ///
    /// Preserves any existing ``choices`` for paths that survived;
    /// drops choices for paths that are no longer conflicted.
    public func refresh() async {
        do {
            operation = try await MidstreamOperation.detect(repoURL: repoURL, runner: runner)
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

    /// Complete the active midstream operation, dispatching the
    /// right `git` invocation per ``operation``:
    ///
    ///   - merge       → `git commit --no-edit` (writes the merge
    ///                    commit using `.git/MERGE_MSG`)
    ///   - rebase      → `git rebase --continue`
    ///   - cherry-pick → `git cherry-pick --continue`
    ///   - revert      → `git revert --continue`
    ///   - am          → `git am --continue`
    ///
    /// Rejected if any path is still unresolved, if there's no
    /// active midstream operation, or if ``conflicts`` is empty.
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
        guard let argv = operation.continueArguments else {
            state = .failure(.init(
                description: "No active midstream operation to finalize. Call refresh() first."
            ))
            return
        }
        await runGit(argv)
    }

    /// Abandon the active midstream operation, dispatching the right
    /// `git <op> --abort` per ``operation``:
    ///
    ///   - merge       → `git merge --abort`
    ///   - rebase      → `git rebase --abort`
    ///   - cherry-pick → `git cherry-pick --abort`
    ///   - revert      → `git revert --abort`
    ///   - am          → `git am --abort`
    ///
    /// Resets working tree to its pre-op state. In-memory choices,
    /// inventory, and resolvedPaths all clear; the next ``refresh()``
    /// returns the now-empty inventory plus
    /// ``MidstreamOperation/none``.
    ///
    /// Rejected if there's no active midstream operation.
    public func abort() async {
        if case .busy = state { return }
        guard let argv = operation.abortArguments else {
            state = .failure(.init(
                description: "No active midstream operation to abort. Call refresh() first."
            ))
            return
        }
        await runGit(argv)
        choices = [:]
        resolvedPaths = []
        conflicts = []
        operation = .none
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
                    try await MergeApplyPipeline.applySingle(
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

    // Apply helpers live in MergeApplyPipeline.swift so the VM stays
    // under SwiftLint's file-length cap as the apply surface grows.

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
