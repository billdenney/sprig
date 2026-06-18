// StatusVocabularyPushRailTests.swift
//
// ADR 0093 push-time rail copy. Split from StatusVocabularyTests to keep
// that file under the file-length cap. (The parenthetical-policy census
// stays in StatusVocabularyTests and already covers these cases.)

import Foundation
import GitCore
import TaskWindowKit
import Testing
@testable import UIKitShared

@Suite("StatusVocabulary — push-time rail copy (ADR 0093)")
struct VocabularyPushRailTests {
    @Test("push-time rails format in both registers with the key facts")
    func pushRailCopy() {
        let protected = StatusVocabulary.describe(.pushingToProtectedBranch(branch: "main"), register: .plain)
        #expect(protected.contains("main"))
        #expect(protected.lowercased().contains("pull request"))

        let force = StatusVocabulary.describe(
            .forcePushConsequence(branch: "main", ahead: 3, behind: 4), register: .plain
        )
        #expect(force.contains("3") && force.contains("4"))
        #expect(force.lowercased().contains("rewrite"))
        #expect(force.lowercased().contains("fetch"))

        let secret = StatusVocabulary.describe(
            .secretInOutgoingCommits(path: "src/k.py", rule: "Stripe Secret Key", line: 7), register: .plain
        )
        #expect(secret.contains("src/k.py") && secret.contains("line 7"))
        #expect(secret.lowercased().contains("rotate"))
    }
}
