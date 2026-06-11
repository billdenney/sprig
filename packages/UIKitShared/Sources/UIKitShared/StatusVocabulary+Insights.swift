// StatusVocabulary+Insights.swift
//
// ADR 0077 — the Status window's insight lines: affordance 3.3's
// "what changed?" digest and 3.1's stale-work nudge. Both registers;
// no `(git: …)` parentheticals (neither is a ratified teaching
// point — the census in StatusVocabularyTests counts them).

import Foundation
import GitCore

public extension StatusVocabulary {
    // MARK: - Fetch digest (affordance 3.3)

    static func describe(
        _ digest: FetchDigest,
        register: VocabularyRegister = .plain
    ) -> String {
        switch register {
        case .git:
            "\(digest.ref): \(digest.commitCount) new commit(s) (\(digest.authorCount) author(s)) "
                + "\(String(digest.oldSHA.prefix(8)))..\(String(digest.newSHA.prefix(8)))"
        case .plain:
            digest.authorCount == 1
                ? "\(digest.commitCount) new commit(s) from 1 person on \(digest.ref)"
                : "\(digest.commitCount) new commit(s) from \(digest.authorCount) people on \(digest.ref)"
        }
    }

    // MARK: - Stale-work nudge (affordance 3.1)

    /// The "you have work sitting here" line. `changedFileCount` is
    /// the working tree's dirty total (staged + unstaged +
    /// untracked); `daysSinceLastCommit` comes from the summary's
    /// `lastCommitDate` against the shell's clock. Callers only show
    /// this when both numbers make it worth saying (dirty > 0 and
    /// the gap is long); the vocabulary just words it.
    static func staleWorkNudge(
        branch: String,
        changedFileCount: Int,
        daysSinceLastCommit: Int,
        register: VocabularyRegister = .plain
    ) -> String {
        switch register {
        case .git:
            "\(branch): \(changedFileCount) changed file(s), "
                + "no commit in \(daysSinceLastCommit) day(s)"
        case .plain:
            "\(branch) has \(changedFileCount) changed file(s) waiting — "
                + "nothing committed in \(daysSinceLastCommit) day(s)"
        }
    }
}
