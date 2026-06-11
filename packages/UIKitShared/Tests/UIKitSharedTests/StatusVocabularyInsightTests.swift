// StatusVocabularyInsightTests.swift
//
// ADR 0077's insight lines — split from StatusVocabularyTests.swift
// for the file-length cap. Same rules of the house: `.git` strings
// are CLI wire (SprigctlSyncTests pins the digest line end-to-end),
// `.plain` strings carry no parentheticals (not teaching points).

import Foundation
import GitCore
import Testing
@testable import UIKitShared

@Suite("StatusVocabulary — insight lines (ADR 0077)")
struct VocabularyInsightTests {
    @Test("fetch digest words both registers; singular author reads naturally")
    func fetchDigestCopy() {
        let digest = FetchDigest(
            ref: "origin/main",
            oldSHA: String(repeating: "a", count: 40),
            newSHA: String(repeating: "b", count: 40),
            commitCount: 12,
            authorCount: 3
        )
        #expect(
            StatusVocabulary.describe(digest, register: .plain)
                == "12 new commit(s) from 3 people on origin/main"
        )
        #expect(
            StatusVocabulary.describe(digest, register: .git)
                == "origin/main: 12 new commit(s) (3 author(s)) aaaaaaaa..bbbbbbbb"
        )

        let solo = FetchDigest(
            ref: "origin/main", oldSHA: "a", newSHA: "b",
            commitCount: 2, authorCount: 1
        )
        #expect(
            StatusVocabulary.describe(solo, register: .plain)
                == "2 new commit(s) from 1 person on origin/main"
        )
    }

    @Test("stale-work nudge words both registers without parentheticals")
    func staleWorkCopy() {
        let plain = StatusVocabulary.staleWorkNudge(
            branch: "feature/x", changedFileCount: 4, daysSinceLastCommit: 9,
            register: .plain
        )
        #expect(plain == "feature/x has 4 changed file(s) waiting — nothing committed in 9 day(s)")
        let git = StatusVocabulary.staleWorkNudge(
            branch: "feature/x", changedFileCount: 4, daysSinceLastCommit: 9,
            register: .git
        )
        #expect(git == "feature/x: 4 changed file(s), no commit in 9 day(s)")
        #expect(!plain.contains("(git:"))
    }
}
