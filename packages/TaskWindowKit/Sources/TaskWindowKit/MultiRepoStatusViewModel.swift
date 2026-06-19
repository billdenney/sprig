// MultiRepoStatusViewModel.swift
//
// ADR 0094 Option 2's portable half: the on-demand "Repositories"
// roll-up. Given a set of watch-root repo URLs, it computes one
// per-repo `RepoStatusSummary` (reusing `StatusViewModel` verbatim —
// one `Runner` per root) and folds them into a cross-repo aggregate
// answering "which repos need attention?" — total dirty, total
// ahead/behind on the checked-out branch, repos with a parked
// merge/rebase, and repos that couldn't be read.
//
// On-demand by construction (ADR 0094 rejects the always-watching
// Option 1 and the tray): the caller drives `refresh()`; this VM never
// installs a watcher and never polls. A repo that errors degrades to a
// `.failed` entry and is counted — one unreadable root never sinks the
// roll-up.
//
// Tier 1, portable. Shells bind to `state`'s aggregate; the per-repo
// rows are `RepoRollup.repos`. No new git plumbing — every spawn rides
// `StatusViewModel`.

import Foundation
import GitCore

/// One repository's place in the roll-up: its root URL plus either the
/// `RepoStatusSummary` `StatusViewModel` produced, or the failure that
/// kept it from being read.
public struct RepoRollupEntry: Sendable, Equatable {
    /// The repo's working-tree root, as handed to the VM.
    public let repoURL: URL

    /// The per-repo summary when the refresh succeeded; nil when it
    /// failed (see ``failure``).
    public let summary: RepoStatusSummary?

    /// The failure when the per-repo refresh threw; nil when it
    /// succeeded (see ``summary``).
    public let failure: TaskWindowState<RepoStatusSummary>.Failure?

    /// True iff this repo couldn't be read.
    public var failed: Bool {
        summary == nil
    }

    /// The checked-out branch's ahead/behind, when known. Nil for a
    /// failed read, a detached HEAD, or an unborn branch.
    public var currentBranchState: BranchSyncState? {
        summary?.currentBranchState
    }

    /// True iff this repo has any staged / unstaged / untracked /
    /// conflicted change. A failed read is never "dirty" — its state is
    /// unknown, surfaced through ``failed`` instead.
    public var isDirty: Bool {
        guard let summary else { return false }
        return summary.stagedCount > 0
            || summary.unstagedCount > 0
            || summary.untrackedCount > 0
            || summary.conflictedCount > 0
    }

    /// True iff a merge / rebase / cherry-pick / revert / am is parked
    /// here, or the tree carries conflicted paths.
    public var hasConflict: Bool {
        guard let summary else { return false }
        return summary.midOperation != .none || summary.conflictedCount > 0
    }

    public init(
        repoURL: URL,
        summary: RepoStatusSummary? = nil,
        failure: TaskWindowState<RepoStatusSummary>.Failure? = nil
    ) {
        self.repoURL = repoURL
        self.summary = summary
        self.failure = failure
    }
}

/// The cross-repo aggregate plus the per-repo rows behind it. The
/// shells render the headline counts; the rows drive the list.
public struct RepoRollup: Sendable, Equatable {
    /// One row per root, in the order the roots were supplied.
    public let repos: [RepoRollupEntry]

    /// Roots whose per-repo refresh succeeded.
    public var readableCount: Int {
        repos.count(where: { !$0.failed })
    }

    /// Roots that couldn't be read (degraded entries).
    public var failedCount: Int {
        repos.count(where: \.failed)
    }

    /// Roots with any working-tree change.
    public var dirtyCount: Int {
        repos.count(where: \.isDirty)
    }

    /// Roots with a parked operation or conflicted paths.
    public var conflictedCount: Int {
        repos.count(where: \.hasConflict)
    }

    /// Total commits the checked-out branches are ahead of their
    /// upstreams, summed across readable repos.
    public var totalAhead: Int {
        repos.reduce(0) { $0 + ($1.currentBranchState?.ahead ?? 0) }
    }

    /// Total commits the checked-out branches are behind their
    /// upstreams, summed across readable repos.
    public var totalBehind: Int {
        repos.reduce(0) { $0 + ($1.currentBranchState?.behind ?? 0) }
    }

    /// True iff every repo was readable AND nothing needs attention: no
    /// dirt, no parked operation, nothing ahead or behind. A failed read
    /// is NOT "clean" — we can't vouch for a repo we couldn't read — so
    /// any failure makes this false (`failedCount` surfaces the count).
    public var allClean: Bool {
        failedCount == 0 && dirtyCount == 0 && conflictedCount == 0
            && totalAhead == 0 && totalBehind == 0
    }

    public init(repos: [RepoRollupEntry]) {
        self.repos = repos
    }
}

/// View model for ADR 0094 Option 2's "Repositories" roll-up window.
/// On-demand: ``refresh()`` re-reads every root; the VM never watches.
public actor MultiRepoStatusViewModel {
    /// The watch-root repositories to roll up, in display order.
    public let repoURLs: [URL]

    /// Lifecycle + the latest aggregate.
    public private(set) var state: TaskWindowState<RepoRollup> = .idle

    /// Per-root status VMs, one `Runner` each (built once; `refresh()`
    /// re-runs them). Keyed positionally to ``repoURLs``.
    private let perRepo: [StatusViewModel]

    /// - Parameters:
    ///   - repoURLs: the watch-root repos to aggregate. Order is
    ///     preserved in ``RepoRollup/repos``. An empty set is valid and
    ///     yields an empty, all-clean roll-up.
    ///   - makeRunner: builds the per-repo `Runner`. Defaults to a
    ///     `Runner` bound to each repo's root; tests inject a configured
    ///     runner here. The closure is called once per root at init.
    public init(
        repoURLs: [URL],
        makeRunner: (URL) -> Runner = { Runner(defaultWorkingDirectory: $0) }
    ) {
        self.repoURLs = repoURLs
        perRepo = repoURLs.map { url in
            StatusViewModel(repoURL: url, runner: makeRunner(url))
        }
    }

    /// Re-read every root and rebuild the aggregate. On-demand: the
    /// caller decides when (a window open, a manual "Refresh", the
    /// existing fetch tick) — this never fires itself. A root that
    /// throws degrades to a `.failed` entry; the roll-up as a whole only
    /// fails if the fold itself can't be built (it can't, today), so
    /// this lands in `.success` even with unreadable repos.
    public func refresh() async {
        state = .busy(progress: nil)
        var entries: [RepoRollupEntry] = []
        entries.reserveCapacity(perRepo.count)
        for vm in perRepo {
            await vm.refresh()
            await entries.append(entry(url: vm.repoURL, state: vm.state))
        }
        state = .success(RepoRollup(repos: entries))
    }

    /// Fold one per-repo VM's terminal state into a roll-up row.
    /// `.success` carries the summary; `.failure` becomes a degraded
    /// entry; the non-terminal states can't occur after `refresh()`
    /// awaited the per-repo VM, but map conservatively to a failure so
    /// the row is never silently dropped.
    private func entry(
        url: URL,
        state: TaskWindowState<RepoStatusSummary>
    ) -> RepoRollupEntry {
        switch state {
        case let .success(summary):
            RepoRollupEntry(repoURL: url, summary: summary)
        case let .failure(failure):
            RepoRollupEntry(repoURL: url, failure: failure)
        case .idle, .busy:
            RepoRollupEntry(
                repoURL: url,
                failure: .init(description: TaskWindowVocabulary.rollupRepoUnavailable)
            )
        }
    }

    /// Reset to ``TaskWindowState/idle``.
    public func reset() {
        state = .idle
    }
}
