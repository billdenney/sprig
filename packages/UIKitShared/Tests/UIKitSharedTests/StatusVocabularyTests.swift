// StatusVocabularyTests.swift
//
// ADR 0072 — exhaustive case × register coverage, pure and fast (no
// git). The `.git` register's strings double as sprigctl's output
// contract (SprigctlSyncTests pins them end-to-end); the `.plain`
// register must teach the git term in parentheses wherever a term
// exists (the affordances 2.1 progressive-disclosure rule).

import Foundation
import GitCore
import TaskWindowKit
import Testing
@testable import UIKitShared

@Suite("StatusVocabulary — relationship phrases")
struct VocabularyRelationshipTests {
    private func state(
        upstream: String? = "origin/main",
        ahead: Int = 0,
        behind: Int = 0,
        gone: Bool = false
    ) -> BranchSyncState {
        BranchSyncState(
            name: "main",
            sha: String(repeating: "a", count: 40),
            upstreamFullRef: upstream.map { "refs/remotes/\($0)" },
            upstreamShort: upstream,
            ahead: ahead,
            behind: behind,
            upstreamGone: gone,
            isCurrent: true
        )
    }

    @Test("git register matches sprigctl's pinned phrasing")
    func gitRegisterPhrases() {
        #expect(
            StatusVocabulary.describeRelationship(of: state(), register: .git)
                == "up to date with origin/main"
        )
        #expect(
            StatusVocabulary.describeRelationship(of: state(ahead: 2), register: .git)
                == "ahead of origin/main by 2"
        )
        #expect(
            StatusVocabulary.describeRelationship(of: state(behind: 3), register: .git)
                == "behind origin/main by 3"
        )
        #expect(
            StatusVocabulary.describeRelationship(of: state(ahead: 1, behind: 2), register: .git)
                == "diverged from origin/main (ahead 1, behind 2)"
        )
        #expect(
            StatusVocabulary.describeRelationship(of: state(upstream: nil), register: .git)
                == "no upstream"
        )
        #expect(
            StatusVocabulary.describeRelationship(of: state(gone: true), register: .git)
                == "upstream origin/main is gone"
        )
    }

    @Test("plain register teaches the git term in parentheses")
    func plainRegisterTeaches() {
        let behind = StatusVocabulary.describeRelationship(of: state(behind: 3), register: .plain)
        #expect(behind == "your copy is 3 update(s) behind origin/main (git: behind by 3)")
        let ahead = StatusVocabulary.describeRelationship(of: state(ahead: 2), register: .plain)
        #expect(ahead.contains("(git: ahead by 2)"))
        let diverged = StatusVocabulary.describeRelationship(
            of: state(ahead: 1, behind: 2),
            register: .plain
        )
        #expect(diverged.contains("(git: diverged — ahead 1, behind 2)"))
        let none = StatusVocabulary.describeRelationship(of: state(upstream: nil), register: .plain)
        #expect(none.contains("(git: no upstream)"))
    }
}

@Suite("StatusVocabulary — fast-forward + push outcomes")
struct VocabularyOutcomeTests {
    @Test("every FastForwardOutcome formats in both registers, non-empty and distinct where intended")
    func fastForwardCoverage() {
        let outcomes: [FastForwardOutcome] = [
            .fastForwarded(from: String(repeating: "a", count: 40), to: String(repeating: "b", count: 40)),
            .upToDate,
            .aheadOnly(ahead: 2),
            .diverged(ahead: 1, behind: 2),
            .noUpstream,
            .upstreamGone,
            .skippedDirtyWorktree,
            .skippedCheckedOutElsewhere,
            .failed(reason: "boom")
        ]
        for outcome in outcomes {
            let git = StatusVocabulary.describe(outcome, register: .git)
            let plain = StatusVocabulary.describe(outcome, register: .plain)
            #expect(!git.isEmpty)
            #expect(!plain.isEmpty)
        }
        // Pinned: the CLI-facing strings sprigctl tests rely on.
        #expect(StatusVocabulary.describe(.upToDate, register: .git) == "nothing to do")
        #expect(
            StatusVocabulary.describe(.skippedDirtyWorktree, register: .git)
                == "skipped: uncommitted changes (use --autostash to set them aside)"
        )
        // The plain register never mentions CLI flags.
        #expect(
            !StatusVocabulary.describe(.skippedDirtyWorktree, register: .plain)
                .contains("--autostash")
        )
    }

    @Test("every PushOutcome formats in both registers; rejection never suggests forcing")
    func pushCoverage() {
        let outcomes: [PushOutcome] = [
            .pushed(branch: "main", upstream: "origin/main", commits: 2),
            .nothingToPush(branch: "main"),
            .publishedNewUpstream(branch: "feature/x", remote: "origin"),
            .rejectedNonFastForward(branch: "main"),
            .noRemotes(branch: "main"),
            .detachedHEAD,
            .failed(reason: "boom")
        ]
        for outcome in outcomes {
            #expect(!StatusVocabulary.describe(outcome, register: .git).isEmpty)
            #expect(!StatusVocabulary.describe(outcome, register: .plain).isEmpty)
        }
        #expect(StatusVocabulary.describe(
            .pushed(branch: "main", upstream: "origin/main", commits: 2), register: .git
        ) == "main: pushed 2 commit(s) to origin/main")
        for register in [VocabularyRegister.git, .plain] {
            let rejected = StatusVocabulary.describe(
                .rejectedNonFastForward(branch: "main"),
                register: register
            )
            #expect(
                rejected.localizedCaseInsensitiveContains("force"),
                "rejection copy must state that Sprig never forces"
            )
            #expect(
                !rejected.localizedCaseInsensitiveContains("use --force"),
                "and must never INSTRUCT forcing"
            )
        }
    }
}

@Suite("StatusVocabulary — warnings, set-aside, byte sizes")
struct VocabularyWarningTests {
    @Test("preflight warnings format in both registers; plain register stays human")
    func preflightCoverage() {
        let warnings: [PreflightWarning] = [
            .committingToDefaultBranch(branch: "main", upstream: "origin/main"),
            .detachedHEAD(oid: String(repeating: "c", count: 40)),
            .detachedHEAD(oid: nil),
            .largeStagedFileWithoutLFS(path: "big.bin", sizeBytes: 60_000_000, thresholdBytes: 52_428_800)
        ]
        for warning in warnings {
            #expect(!StatusVocabulary.describe(warning, register: .git).isEmpty)
            #expect(!StatusVocabulary.describe(warning, register: .plain).isEmpty)
        }
        let large = StatusVocabulary.describe(
            .largeStagedFileWithoutLFS(path: "big.bin", sizeBytes: 60_000_000, thresholdBytes: 52_428_800),
            register: .plain
        )
        #expect(large.contains("57.2 MB"), "plain register uses human sizes, got: \(large)")
        #expect(large.contains("LFS"))
        let detachedShort = StatusVocabulary.describe(
            .detachedHEAD(oid: String(repeating: "c", count: 40)),
            register: .git
        )
        #expect(detachedShort == "detached HEAD at cccccccc")
    }

    @Test("set-aside outcomes format in both registers")
    func setAsideCoverage() {
        #expect(
            StatusVocabulary.describe(SetAsideOutcome.reapplied, register: .git)
                == "stash reapplied"
        )
        #expect(
            StatusVocabulary.describe(SetAsideOutcome.reapplied, register: .plain)
                .contains("(git: stash reapplied)")
        )
        let kept = StatusVocabulary.describe(
            SetAsideOutcome.keptInStash(detail: "CONFLICT (content): a.txt"),
            register: .git
        )
        #expect(kept == "kept in stash: CONFLICT (content): a.txt")
        let keptPlain = StatusVocabulary.describe(
            SetAsideOutcome.keptInStash(detail: "CONFLICT (content): a.txt"),
            register: .plain
        )
        #expect(keptPlain.contains("saved"))
        #expect(!keptPlain.contains("CONFLICT"), "plain register spares the raw git detail")
    }

    @Test("byteSize is deterministic, locale-free, and rounds to one decimal")
    func byteSizeFormatting() {
        #expect(StatusVocabulary.byteSize(512) == "512 bytes")
        #expect(StatusVocabulary.byteSize(1_048_575) == "1048575 bytes")
        #expect(StatusVocabulary.byteSize(1_048_576) == "1.0 MB")
        #expect(StatusVocabulary.byteSize(52_428_800) == "50.0 MB")
        #expect(StatusVocabulary.byteSize(60_000_000) == "57.2 MB")
        // Rounds half-up, not truncates: exactly 1.25 MiB → 1.3, and
        // a hair under 1.15 MiB → 1.1.
        #expect(StatusVocabulary.byteSize(1_310_720) == "1.3 MB")
        #expect(StatusVocabulary.byteSize(1_205_862) == "1.1 MB")
    }
}
