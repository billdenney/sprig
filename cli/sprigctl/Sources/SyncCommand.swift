// SyncCommand.swift
//
// `sprigctl sync` — one-shot ADR 0068 sync: fetch all remotes, report
// every local branch's upstream relationship, and (with `--pull`)
// fast-forward whatever can be moved provably without loss.
//
// This is the scriptable face of the same engine surface the agent's
// AutoSyncScheduler drives hourly; running it by hand answers "am I
// up to date?" and `--json` feeds tooling.

import ArgumentParser
import Foundation
import GitCore

/// `sprigctl sync [<repo>] [--no-fetch] [--pull] [--autostash] [--json]`
struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Fetch all remotes and report (or fast-forward) local branch state."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(
        name: .customLong("no-fetch"),
        help: "Skip the fetch; report/fast-forward against already-fetched state."
    )
    var noFetch: Bool = false

    @Flag(
        name: .long,
        help: "Fast-forward branches strictly behind their upstream (ADR 0068 rules; never merges or rebases)."
    )
    var pull: Bool = false

    @Flag(
        name: .long,
        help: "With --pull: fast-forward the checked-out branch over uncommitted changes via git's autostash."
    )
    var autostash: Bool = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Plain-push the current branch after fetching (and pulling, with --pull).",
            discussion: "Publishes with -u when no upstream exists. Never forces; "
                + "a diverged upstream is reported, not overridden (ADR 0071)."
        )
    )
    var push: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        if autostash, !pull {
            throw ValidationError("--autostash only makes sense with --pull")
        }
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let sync = SyncOps(runner: runner)

        if !noFetch {
            try await sync.fetchAll()
        }

        // ADR 0056: never mutate a repo that's mid-merge/-rebase —
        // active locks OR parked midstream state. Report-only mode is
        // unaffected.
        let midOperation = (try? GitMetadataPaths.resolveGitDir(forWorktree: repoURL))
            .map { GitMetadataPaths.repoIsMidOperation(gitDir: $0) } ?? false
        var pullResults: [FastForwardResult]?
        var skippedMidOperation = false
        if pull {
            if midOperation {
                skippedMidOperation = true
            } else {
                pullResults = try await sync.fastForwardLocalBranches(
                    options: FastForwardOptions(autostash: autostash)
                )
            }
        }

        // Push leg (ADR 0071): after pull so a fast-forwarded branch
        // doesn't false-reject. Honors the same mid-operation guard.
        var pushOutcome: PushOutcome?
        if push, !skippedMidOperation {
            pushOutcome = try await sync.pushCurrentBranch()
        }

        let states = try await sync.branchSyncStates()
        if json {
            try emitJSON(
                states: states,
                pullResults: pullResults,
                fetched: !noFetch,
                skippedMidOperation: skippedMidOperation,
                pushOutcome: pushOutcome
            )
        } else {
            emitHuman(
                states: states,
                pullResults: pullResults,
                skippedMidOperation: skippedMidOperation,
                pushOutcome: pushOutcome
            )
        }
        if skippedMidOperation {
            throw ExitCode(2)
        }
    }

    // MARK: - Human output

    private func emitHuman(
        states: [BranchSyncState],
        pullResults: [FastForwardResult]?,
        skippedMidOperation: Bool,
        pushOutcome: PushOutcome?
    ) {
        var out = StdoutStream()
        if skippedMidOperation {
            var err = StderrStream()
            print("# pull/push skipped: a git operation (merge/rebase/…) is in progress", to: &err)
        }
        for state in states {
            print(humanLine(for: state, pullResults: pullResults), to: &out)
        }
        if let pushOutcome {
            print("push: \(describe(pushOutcome))", to: &out)
        }
    }

    private func describe(_ outcome: PushOutcome) -> String {
        switch outcome {
        case let .pushed(branch, upstream, commits):
            "\(branch): pushed \(commits) commit(s) to \(upstream)"
        case let .nothingToPush(branch):
            "\(branch): nothing to push"
        case let .publishedNewUpstream(branch, remote):
            "\(branch): published to \(remote) and now tracks it"
        case let .rejectedNonFastForward(branch):
            "\(branch): rejected — the remote has new commits; pull/resolve first (never forced)"
        case let .noRemotes(branch):
            "\(branch): no remotes configured; nowhere to push"
        case .detachedHEAD:
            "skipped: HEAD is detached (no current branch)"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    private func humanLine(
        for state: BranchSyncState,
        pullResults: [FastForwardResult]?
    ) -> String {
        let marker = state.isCurrent ? "*" : " "
        let relationship = describeRelationship(of: state)
        var line = "\(marker) \(state.name): \(relationship)"
        if let outcome = pullResults?.first(where: { $0.branch == state.name })?.outcome {
            line += " — \(describe(outcome))"
        }
        return line
    }

    private func describeRelationship(of state: BranchSyncState) -> String {
        guard let upstream = state.upstreamShort else { return "no upstream" }
        if state.upstreamGone { return "upstream \(upstream) is gone" }
        switch (state.ahead, state.behind) {
        case (0, 0): return "up to date with \(upstream)"
        case let (a, 0): return "ahead of \(upstream) by \(a)"
        case let (0, b): return "behind \(upstream) by \(b)"
        case let (a, b): return "diverged from \(upstream) (ahead \(a), behind \(b))"
        }
    }

    private func describe(_ outcome: FastForwardOutcome) -> String {
        switch outcome {
        case let .fastForwarded(from, to):
            "fast-forwarded \(String(from.prefix(8)))..\(String(to.prefix(8)))"
        case .upToDate:
            "nothing to do"
        case let .aheadOnly(ahead):
            "\(ahead) unpushed commit(s); nothing to pull"
        case let .diverged(ahead, behind):
            "needs attention: diverged (ahead \(ahead), behind \(behind))"
        case .noUpstream:
            "no upstream; skipped"
        case .upstreamGone:
            "upstream deleted on remote; skipped"
        case .skippedDirtyWorktree:
            "skipped: uncommitted changes (use --autostash to set them aside)"
        case .skippedCheckedOutElsewhere:
            "skipped: checked out in another worktree"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    // MARK: - JSON output

    private struct BranchJSON: Codable {
        var name: String
        var current: Bool
        var upstream: String?
        var upstreamGone: Bool
        var ahead: Int
        var behind: Int
        var pullOutcome: String?
    }

    private struct ReportJSON: Codable {
        var fetched: Bool
        var pullRequested: Bool
        var pullSkippedMidOperation: Bool
        var branches: [BranchJSON]
        var pushOutcome: String?
    }

    private func emitJSON(
        states: [BranchSyncState],
        pullResults: [FastForwardResult]?,
        fetched: Bool,
        skippedMidOperation: Bool,
        pushOutcome: PushOutcome?
    ) throws {
        let branches = states.map { state in
            BranchJSON(
                name: state.name,
                current: state.isCurrent,
                upstream: state.upstreamShort,
                upstreamGone: state.upstreamGone,
                ahead: state.ahead,
                behind: state.behind,
                pullOutcome: pullResults?
                    .first { $0.branch == state.name }
                    .map { jsonOutcome($0.outcome) }
            )
        }
        let report = ReportJSON(
            fetched: fetched,
            pullRequested: pullResults != nil || skippedMidOperation,
            pullSkippedMidOperation: skippedMidOperation,
            branches: branches,
            pushOutcome: pushOutcome.map(jsonPushOutcome)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        var out = StdoutStream()
        print(String(data: data, encoding: .utf8) ?? "{}", to: &out)
    }

    /// Stable machine-readable push-outcome tags (wire-shape: don't rename).
    private func jsonPushOutcome(_ outcome: PushOutcome) -> String {
        switch outcome {
        case .pushed: "pushed"
        case .nothingToPush: "nothing-to-push"
        case .publishedNewUpstream: "published-new-upstream"
        case .rejectedNonFastForward: "rejected-non-fast-forward"
        case .noRemotes: "no-remotes"
        case .detachedHEAD: "detached-head"
        case .failed: "failed"
        }
    }

    /// Stable machine-readable outcome tags (wire-shape: don't rename).
    private func jsonOutcome(_ outcome: FastForwardOutcome) -> String {
        switch outcome {
        case .fastForwarded: "fast-forwarded"
        case .upToDate: "up-to-date"
        case .aheadOnly: "ahead-only"
        case .diverged: "diverged"
        case .noUpstream: "no-upstream"
        case .upstreamGone: "upstream-gone"
        case .skippedDirtyWorktree: "skipped-dirty-worktree"
        case .skippedCheckedOutElsewhere: "skipped-checked-out-elsewhere"
        case .failed: "failed"
        }
    }
}
