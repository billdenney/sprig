// SyncViewModel.swift
//
// ADR 0071 — the portable engine behind the "Sync" verb, the
// beginner-affordances 1.4 one-button promise: *make my copy and the
// server match*. Composite: fetch all remotes → fast-forward local
// branches (ADR 0068 safety table) → plain push of the current branch
// (ADR 0071 push half; never forced).
//
// Tier 1, portable. Per ADR 0048, the per-OS shells bind to this VM's
// `stage`, `state`, and the terminal ``SyncReport``.
//
// What this VM owns:
//   - Stage progression (fetching → fast-forwarding → pushing) so the
//     UI can show "what is Sync doing right now".
//   - The composed ``SyncReport`` — per-leg outcomes the UI renders
//     as one-line summaries ("pulled 2", "pushed 1", "main needs your
//     attention: diverged").
//   - The ADR 0056 mid-operation guard: a repo mid-merge/-rebase
//     skips the mutating legs entirely (fetch still runs — it's
//     read-only).
//
// What this VM doesn't own (deliberately):
//   - Conflict resolution — a diverged branch is *reported*; the UI
//     routes to the M4 resolver / manual flow.
//   - Force pushes (ADR 0052's separate high-tier verb).
//   - Scheduling — AgentKit's AutoSyncScheduler drives background
//     sync; this VM is the interactive verb.

import Foundation
import GitCore

/// Per-leg outcomes of one Sync run. Every leg is best-effort
/// reportable data; only infrastructure failures (fetch refused, git
/// missing) surface as ``TaskWindowState/failure``.
public struct SyncReport: Sendable, Equatable {
    /// True when the fetch leg ran and succeeded.
    public var fetched: Bool
    /// True when the mutating legs were skipped because a git
    /// operation (merge/rebase/…) was in flight (ADR 0056).
    public var skippedMidOperation: Bool
    /// Fast-forward outcome for the **current** branch, nil when the
    /// FF leg didn't run. Other branches are fast-forwarded too (same
    /// pass ADR 0068's auto-pull uses) but the verb's summary focuses
    /// on where the user is standing.
    public var currentBranchFastForward: FastForwardOutcome?
    /// Push-leg outcome, nil when the push leg didn't run.
    public var push: PushOutcome?

    public init(
        fetched: Bool = false,
        skippedMidOperation: Bool = false,
        currentBranchFastForward: FastForwardOutcome? = nil,
        push: PushOutcome? = nil
    ) {
        self.fetched = fetched
        self.skippedMidOperation = skippedMidOperation
        self.currentBranchFastForward = currentBranchFastForward
        self.push = push
    }
}

/// View model for the Sync verb. Construct, call ``run()``, read
/// ``state``'s terminal ``SyncReport``.
public actor SyncViewModel {
    /// Which leg is executing right now — the UI's progress label.
    public enum Stage: Sendable, Equatable {
        case idle
        case fetching
        case fastForwarding
        case pushing
        case finished
    }

    /// The repo this VM operates on.
    public let repoURL: URL

    /// Current leg. Distinct from ``state`` (idle/busy/terminal):
    /// `state` answers "is Sync running / did it work"; `stage`
    /// answers "what is it doing".
    public private(set) var stage: Stage = .idle

    /// Lifecycle + terminal report.
    public private(set) var state: TaskWindowState<SyncReport> = .idle

    private let runner: Runner
    private let autostash: Bool

    /// - Parameters:
    ///   - repoURL: worktree root.
    ///   - runner: `Runner` configured against `repoURL`.
    ///   - autostash: forward ADR 0068's `FastForwardOptions.autostash`
    ///     to the FF leg (set aside uncommitted changes around the
    ///     current branch's fast-forward). Default false — the verb
    ///     reports "skipped: uncommitted changes" and lets the UI
    ///     offer the ADR 0069 set-aside retry explicitly.
    public init(repoURL: URL, runner: Runner, autostash: Bool = false) {
        self.repoURL = repoURL
        self.runner = runner
        self.autostash = autostash
    }

    /// Run the composite. Re-entry while `.busy` is a no-op.
    ///
    /// Leg failure semantics:
    /// - **fetch fails** → `.failure` (offline/auth — nothing else
    ///   can meaningfully run).
    /// - **mid-operation repo** → fetch only; report carries
    ///   `skippedMidOperation` so the UI explains why nothing moved.
    /// - **FF / push legs** → their typed outcomes are *data* in the
    ///   report, including `rejectedNonFastForward` — that's a
    ///   successful Sync run that found work needing the user.
    public func run() async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        let sync = SyncOps(runner: runner)
        var report = SyncReport()

        stage = .fetching
        do {
            try await sync.fetchAll()
            report.fetched = true
        } catch {
            stage = .finished
            state = .failure(.init(from: error))
            return
        }

        // ADR 0056: never mutate a repo that's mid-operation —
        // active locks OR parked merge/rebase/… state.
        let midOperation = (try? GitMetadataPaths.resolveGitDir(forWorktree: repoURL))
            .map { GitMetadataPaths.repoIsMidOperation(gitDir: $0) } ?? false
        if midOperation {
            report.skippedMidOperation = true
            stage = .finished
            state = .success(report)
            return
        }

        stage = .fastForwarding
        do {
            let results = try await sync.fastForwardLocalBranches(
                options: FastForwardOptions(autostash: autostash)
            )
            let states = try await sync.branchSyncStates()
            if let currentName = states.first(where: \.isCurrent)?.name {
                report.currentBranchFastForward = results
                    .first { $0.branch == currentName }?
                    .outcome
            }
        } catch {
            stage = .finished
            state = .failure(.init(from: error))
            return
        }

        stage = .pushing
        do {
            report.push = try await sync.pushCurrentBranch()
        } catch {
            stage = .finished
            state = .failure(.init(from: error))
            return
        }

        stage = .finished
        state = .success(report)
    }

    /// Reset to ``Stage/idle`` / ``TaskWindowState/idle`` so the verb
    /// can run again.
    public func reset() {
        stage = .idle
        state = .idle
    }
}
