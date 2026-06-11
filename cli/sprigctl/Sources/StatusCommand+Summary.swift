// StatusCommand+Summary.swift
//
// `sprigctl status --summary` — the CLI face of ADR 0064's Status
// dashboard: the exact `RepoStatusSummary` the task window binds to,
// worded by the shared vocabulary's `.git` register. Split from
// StatusCommand.swift for the file-length cap.

import ArgumentParser
import Foundation
import GitCore
import TaskWindowKit
import UIKitShared

extension StatusCommand {
    func runSummary(repoURL: URL, runner: Runner) async throws {
        let vm = StatusViewModel(repoURL: repoURL, runner: runner)
        await vm.refresh()
        let state = await vm.state
        guard case let .success(summaryValue) = state else {
            if case let .failure(failure) = state {
                throw ValidationError(failure.description)
            }
            throw ValidationError("status summary did not complete")
        }
        if json {
            try emitSummaryJSON(summaryValue)
        } else {
            emitSummaryHuman(summaryValue)
        }
    }

    private func emitSummaryHuman(_ summary: RepoStatusSummary) {
        var out = StdoutStream()
        if let head = summary.branch?.head {
            print("branch: \(head)", to: &out)
        }
        if let current = summary.currentBranchState {
            print(
                "upstream: \(StatusVocabulary.describeRelationship(of: current, register: .git))",
                to: &out
            )
        }
        print(
            "tree: \(summary.stagedCount) staged, \(summary.unstagedCount) unstaged, "
                + "\(summary.untrackedCount) untracked, \(summary.conflictedCount) conflicted",
            to: &out
        )
        if summary.midOperation != .none {
            print("in progress: \(summary.midOperation)", to: &out)
        }
        print(
            "safety net: \(summary.snapshotCount) snapshot(s), \(summary.backupCount) backup(s)",
            to: &out
        )
        // ADR 0077 stale-work line, only when there's something to say.
        let dirty = summary.stagedCount + summary.unstagedCount + summary.untrackedCount
        if dirty > 0, let head = summary.branch?.head, let last = summary.lastCommitDate {
            let days = max(0, Int(Date().timeIntervalSince(last) / 86400))
            print(
                StatusVocabulary.staleWorkNudge(
                    branch: head,
                    changedFileCount: dirty,
                    daysSinceLastCommit: days,
                    register: .git
                ),
                to: &out
            )
        }
    }

    private struct SummaryJSON: Codable {
        var branch: String?
        var upstreamRelationship: String?
        var stagedCount: Int
        var unstagedCount: Int
        var untrackedCount: Int
        var conflictedCount: Int
        var midOperation: String
        var snapshotCount: Int
        var backupCount: Int
        var lastCommitDate: Date?
    }

    private func emitSummaryJSON(_ summary: RepoStatusSummary) throws {
        let wire = SummaryJSON(
            branch: summary.branch?.head,
            upstreamRelationship: summary.currentBranchState.map {
                StatusVocabulary.describeRelationship(of: $0, register: .git)
            },
            stagedCount: summary.stagedCount,
            unstagedCount: summary.unstagedCount,
            untrackedCount: summary.untrackedCount,
            conflictedCount: summary.conflictedCount,
            midOperation: String(describing: summary.midOperation),
            snapshotCount: summary.snapshotCount,
            backupCount: summary.backupCount,
            lastCommitDate: summary.lastCommitDate
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var out = StdoutStream()
        try print(String(data: encoder.encode(wire), encoding: .utf8) ?? "{}", to: &out)
    }
}
