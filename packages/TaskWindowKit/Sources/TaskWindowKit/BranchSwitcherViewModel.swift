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
//
// Dirty-tree handling (ADR 0069 "Set aside changes"): a plain
// ``switchBranch()`` against a conflicting dirty tree fails with
// git's error AND sets ``canOfferSetAside`` so the UI can offer the
// one-click retry: ``switchBranch(settingAsideChanges: true)`` runs
// the stash-push → switch → stash-pop composite. Fail-closed at every
// step — see that method's doc for the exact guarantees.

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

    /// True after a plain ``switchBranch()`` failed because the dirty
    /// worktree conflicts with the target branch — the signal for the
    /// UI to offer "Set aside changes and switch" (ADR 0069). Cleared
    /// on the next switch attempt, ``reset()``, and selection changes.
    public private(set) var canOfferSetAside: Bool = false

    /// Outcome of the set-aside leg of the most recent
    /// ``switchBranch(settingAsideChanges:)`` run, or nil when the
    /// last switch didn't set changes aside. Read alongside ``state``:
    /// a `.success` with ``SetAsideOutcome/keptInStash(detail:)``
    /// means the SWITCH succeeded but the changes stayed in
    /// `stash@{0}` because re-applying conflicted — the UI surfaces
    /// that banner instead of silently "succeeding".
    public private(set) var setAsideOutcome: SetAsideOutcome?

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
        canOfferSetAside = false
    }

    /// Drop the current selection back to nil.
    public func clearSelection() {
        selection = nil
        canOfferSetAside = false
    }

    // MARK: - Operation

    /// Run `git switch <selection>`. No-ops if no selection, if the
    /// current state is ``TaskWindowState/busy``, or if the user picked
    /// the branch HEAD already points at (the latter is a soft
    /// "nothing to do" rather than an error).
    ///
    /// **Set-aside mode (ADR 0069).** With
    /// `settingAsideChanges: true`, runs the composite
    /// `stash push --include-untracked` → `switch` → `stash pop`,
    /// fail-closed at every step:
    ///
    /// - Nothing to stash → behaves exactly like a plain switch.
    /// - Stash created, switch **fails** → the stash is popped right
    ///   back on the original branch (best effort), so the user's
    ///   tree is exactly as before; the switch failure surfaces.
    /// - Switch succeeds, pop applies cleanly →
    ///   ``setAsideOutcome`` = ``SetAsideOutcome/reapplied`` and the
    ///   changes travel to the new branch.
    /// - Switch succeeds, pop **conflicts** → git keeps the entry;
    ///   ``state`` is still `.success` (the switch DID happen) and
    ///   ``setAsideOutcome`` = ``SetAsideOutcome/keptInStash(detail:)``
    ///   so the UI shows "your changes are saved in the stash —
    ///   re-apply when ready" instead of pretending all is well.
    public func switchBranch(settingAsideChanges: Bool = false) async {
        if case .busy = state { return }
        canOfferSetAside = false
        setAsideOutcome = nil
        guard let chosen = selection else {
            state = .failure(.init(description: TaskWindowVocabulary.pickABranchFirst))
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
            if settingAsideChanges {
                await self?.runSetAsideSwitch(to: chosen, runner: runner)
            } else {
                await self?.runPlainSwitch(to: chosen, runner: runner)
            }
        }

        await runningTask?.value
    }

    /// The pre-ADR-0069 path: one `git switch`, with dirty-tree
    /// failures additionally flagging ``canOfferSetAside``.
    private func runPlainSwitch(to chosen: String, runner: Runner) async {
        do {
            _ = try await runner.run(["switch", chosen])
            recordSuccess(chosen)
        } catch is CancellationError {
            recordFailure(.init(description: TaskWindowVocabulary.cancelled("Switch")))
        } catch {
            if Self.isDirtyTreeRefusal(error) {
                canOfferSetAside = true
            }
            recordFailure(.init(from: error))
        }
    }

    /// The ADR 0069 composite. See ``switchBranch(settingAsideChanges:)``
    /// for the step-by-step guarantees.
    private func runSetAsideSwitch(to chosen: String, runner: Runner) async {
        let stash = StashOps(runner: runner)
        let pushed: StashPushOutcome
        do {
            pushed = try await stash.push(
                message: "Sprig: set aside before switching to \(chosen)"
            )
        } catch {
            recordFailure(.init(from: error))
            return
        }

        do {
            _ = try await runner.run(["switch", chosen])
        } catch {
            // Switch refused even with a clean tree (unborn branch,
            // ignored-file collision, …). Put the user's changes back
            // where they were before surfacing the failure.
            if case .created = pushed {
                _ = try? await stash.pop()
            }
            recordFailure(.init(from: error))
            return
        }

        guard case .created = pushed else {
            // Tree was clean all along; nothing to re-apply.
            recordSuccess(chosen)
            return
        }
        do {
            switch try await stash.pop() {
            case .applied:
                setAsideOutcome = .reapplied
            case let .keptDueToConflict(detail):
                setAsideOutcome = .keptInStash(detail: detail)
            }
            recordSuccess(chosen)
        } catch {
            // Pop failed in a way that did NOT keep the stash — never
            // observed (StashOps verifies); fail loudly rather than
            // pretend.
            recordFailure(.init(from: error))
        }
    }

    /// Does this `git switch` stderr describe a dirty-worktree
    /// refusal? Matches the two stable phrasings git uses
    /// ("would be overwritten by checkout" for tracked changes,
    /// "would be overwritten" for untracked collisions).
    static func isDirtyTreeRefusal(_ error: any Error) -> Bool {
        guard case let GitError.nonZeroExit(_, _, stderr, _) = error else { return false }
        return stderr.contains("would be overwritten")
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
        canOfferSetAside = false
        setAsideOutcome = nil
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

/// What happened to the user's set-aside changes during a successful
/// ``BranchSwitcherViewModel/switchBranch(settingAsideChanges:)``.
public enum SetAsideOutcome: Sendable, Equatable {
    /// The stash re-applied cleanly on the new branch and was dropped;
    /// the user's in-progress work traveled with them.
    case reapplied
    /// Re-applying conflicted, so git kept the entry (`stash@{0}`).
    /// Nothing is lost — the UI surfaces "your changes are saved;
    /// re-apply when ready" with git's `detail`.
    case keptInStash(detail: String)
}
