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
import UIKitShared

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
            print("push: \(StatusVocabulary.describe(pushOutcome, register: .git))", to: &out)
        }
    }

    private func humanLine(
        for state: BranchSyncState,
        pullResults: [FastForwardResult]?
    ) -> String {
        let marker = state.isCurrent ? "*" : " "
        // ADR 0072: all human copy comes from the shared vocabulary;
        // the CLI uses the terse `.git` register (these exact strings
        // are pinned by SprigctlSyncTests).
        let relationship = StatusVocabulary.describeRelationship(of: state, register: .git)
        var line = "\(marker) \(state.name): \(relationship)"
        if let outcome = pullResults?.first(where: { $0.branch == state.name })?.outcome {
            line += " — \(StatusVocabulary.describe(outcome, register: .git))"
        }
        return line
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
