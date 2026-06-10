// StatusVocabulary+Rebase.swift
//
// ADR 0071 amendment — both registers for the rebase-then-push
// follow-up's typed outcomes. Split from StatusVocabulary.swift for
// the type-body-length cap; the rules of the house (see that file's
// header) apply unchanged. Note the plain register's detached-HEAD
// line carries a `(git: …)` parenthetical — detached HEAD is one of
// the ratified teaching points, and the census test counts it.

import Foundation
import GitCore

public extension StatusVocabulary {
    static func describe(
        _ outcome: RebaseOutcome,
        register: VocabularyRegister = .git
    ) -> String {
        switch register {
        case .git: gitDescription(of: outcome)
        case .plain: plainDescription(of: outcome)
        }
    }

    private static func gitDescription(of outcome: RebaseOutcome) -> String {
        switch outcome {
        case let .rebased(branch, onto, replayed):
            "\(branch): rebased \(replayed) commit(s) onto \(onto)"
        case let .notDiverged(branch):
            "\(branch): not diverged; nothing to rebase"
        case let .conflicted(branch, count):
            "\(branch): rebase stopped on \(count) conflict(s) — resolve and continue, or abort"
        case let .noUpstream(branch):
            "\(branch): no upstream; nothing to rebase onto"
        case .detachedHEAD:
            "skipped: HEAD is detached (no current branch)"
        case .dirtyWorktree:
            "skipped: uncommitted changes"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }

    private static func plainDescription(of outcome: RebaseOutcome) -> String {
        switch outcome {
        case let .rebased(_, _, replayed):
            "replayed your \(replayed) commit(s) on top of the server's work"
        case .notDiverged:
            "nothing to do — you and the server aren't diverged"
        case let .conflicted(_, count):
            "paused — \(count) file(s) need your decision; resolve them, or abort to undo"
        case .noUpstream:
            "skipped — not linked to a branch on the server"
        case .detachedHEAD:
            "skipped — you're not on a branch (git: detached HEAD)"
        case .dirtyWorktree:
            "skipped — you have unsaved changes; set them aside first"
        case let .failed(reason):
            "failed: \(reason)"
        }
    }
}
