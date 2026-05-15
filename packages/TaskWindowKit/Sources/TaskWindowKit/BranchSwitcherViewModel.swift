// BranchSwitcherViewModel.swift
//
// Second concrete TaskWindowKit view model — the portable engine behind
// the macOS/Windows "Switch Branch…" task window. Reads the local
// branch list, surfaces it with the current HEAD marked, and runs
// `git switch <name>` for the user's pick.
//
// Tier 1, portable. Per ADR 0048, view models live here; per-OS shells
// in `apps/{macos,windows}/` bind to this VM's `inventory`, `selection`,
// and `state`.
//
// What this VM owns:
//   - Local-branch inventory (`[Branch]` from
//     `GitCore.BranchListing.parse`).
//   - User's currently-selected branch.
//   - Lifecycle state of the in-flight `git switch` op.
//
// What this VM doesn't own (lives elsewhere by design):
//   - Branch CREATION — that's a separate verb (right-click → New
//     Branch…) with its own dialog and VM.
//   - Branch DELETION — separate verb, plus tier-2 confirmation
//     (ADR 0033 medium-tier when the branch has unpushed commits).
//   - Dirty-tree auto-stash — for the MVP cut, this VM rejects the
//     switch and surfaces a hint pointing the user at Stash; a future
//     iteration can offer "stash, switch, pop" as one combined verb.

import Foundation
import GitCore

/// View model for the Switch Branch task window. Holds the branch
/// inventory + selection, runs `git switch`, surfaces results.
///
/// **Actor-isolated.** All mutable state lives behind the actor; the
/// view layer awaits to read or write.
///
/// **Lifecycle.** Construct with the repo's URL and an injected
/// `Runner`. Call ``refresh()`` to populate ``inventory`` from
/// `git for-each-ref`. The user picks a branch (``select(_:)``), then
/// triggers ``switchBranch()`` which moves ``state`` from `.idle` →
/// `.busy` → terminal.
public actor BranchSwitcherViewModel {
    /// The repo this VM operates on. Surfaced for diagnostics; the
    /// injected ``Runner`` already has it as its working directory.
    public let repoURL: URL

    /// The branches the most-recent ``refresh()`` returned. Empty
    /// before the first refresh, or in a fresh repo with no commits.
    public private(set) var inventory: [Branch] = []

    /// The short name of the user's currently-selected branch, or nil
    /// if no selection has been made.
    public private(set) var selection: String?

    /// State of the in-flight `git switch` operation. ``Success`` is
    /// the short name of the now-current branch.
    public private(set) var state: TaskWindowState<String> = .idle

    /// `Runner` configured against ``repoURL``. Injected for tests.
    private let runner: Runner

    /// In-flight switch Task, retained so ``cancel`` can interrupt it.
    private var runningTask: Task<Void, Never>?

    public init(repoURL: URL, runner: Runner) {
        self.repoURL = repoURL
        self.runner = runner
    }

    // MARK: - Inventory + selection

    /// Re-read the local branch list from `git for-each-ref`. Updates
    /// ``inventory``. If the current ``selection`` is no longer in the
    /// list, it's cleared.
    ///
    /// Failures (corrupt repo, git binary not on PATH, etc.) surface
    /// as ``TaskWindowState/failure`` on ``state`` *and* leave the
    /// inventory empty. Callers retry by calling ``refresh()`` again.
    public func refresh() async {
        do {
            let output = try await runner.run([
                "for-each-ref",
                "--format=\(BranchListing.formatString)",
                "refs/heads/"
            ])
            inventory = try BranchListing.parse(output.stdout)
            if let sel = selection, !inventory.contains(where: { $0.shortName == sel }) {
                selection = nil
            }
        } catch {
            inventory = []
            selection = nil
            state = .failure(.init(from: error))
        }
    }

    /// Pick a branch by short name. No-op if the name isn't in the
    /// current ``inventory`` (the UI should only call this with a
    /// value from there). Picking the HEAD branch is allowed — the
    /// caller can decide whether to disable the Switch button.
    public func select(_ shortName: String) {
        guard inventory.contains(where: { $0.shortName == shortName }) else { return }
        selection = shortName
    }

    /// Drop the current selection back to nil.
    public func clearSelection() {
        selection = nil
    }

    // MARK: - Operation

    /// Run `git switch <selection>`. No-ops if no selection, if the
    /// current state is ``TaskWindowState/busy``, or if the user picked
    /// the branch HEAD already points at (the latter is a soft
    /// "nothing to do" rather than an error).
    public func switchBranch() async {
        if case .busy = state { return }
        guard let chosen = selection else {
            state = .failure(.init(description: "Pick a branch to switch to first."))
            return
        }
        if let head = inventory.first(where: \.isHead), head.shortName == chosen {
            // Already on this branch; surface as success without
            // spawning git so the UI can dismiss the dialog cleanly.
            state = .success(chosen)
            return
        }

        state = .busy(progress: nil)
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                _ = try await runner.run(["switch", chosen])
                await self?.recordSuccess(chosen)
            } catch is CancellationError {
                await self?.recordFailure(.init(description: "Switch cancelled."))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    /// Cancel the in-flight switch, if any.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset to ``TaskWindowState/idle``. Does not clear inventory or
    /// selection; just the operation state. Cancels in-flight switch.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private transitions

    private func recordSuccess(_ branch: String) {
        runningTask = nil
        state = .success(branch)
    }

    private func recordFailure(_ failure: TaskWindowState<String>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
