// StatusVocabularyTests.swift
//
// ADR 0072 — exhaustive case × register coverage, pure and fast (no
// git). The `.git` register's strings double as sprigctl's output
// contract (SprigctlSyncTests pins them end-to-end). The `.plain`
// register is tight everyday language; per the 2026-06-11 ratified
// policy, `(git: …)` teaching parentheticals appear ONLY at the
// high-value decision points — diverged, detached HEAD, and the
// never-forces push rejection — and the policy test below counts
// them so a stray parenthetical can't creep back in.

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

    @Test("plain register is tight; only diverged keeps its teaching parenthetical")
    func plainRegisterPhrases() {
        let behind = StatusVocabulary.describeRelationship(of: state(behind: 3), register: .plain)
        #expect(behind == "3 update(s) to get from origin/main")
        let ahead = StatusVocabulary.describeRelationship(of: state(ahead: 2), register: .plain)
        #expect(ahead == "2 commit(s) to send to origin/main")
        let diverged = StatusVocabulary.describeRelationship(
            of: state(ahead: 1, behind: 2),
            register: .plain
        )
        #expect(diverged == "you and origin/main both have new work (git: diverged — ahead 1, behind 2)")
        let none = StatusVocabulary.describeRelationship(of: state(upstream: nil), register: .plain)
        #expect(none == "not linked to a branch on the server")
        let gone = StatusVocabulary.describeRelationship(of: state(gone: true), register: .plain)
        #expect(gone == "origin/main was deleted on the server")
    }
}

@Suite("StatusVocabulary — parenthetical policy (ratified 2026-06-11)")
struct VocabularyParentheticalPolicyTests {
    private let sha = String(repeating: "a", count: 40)

    private func relationship(ahead: Int, behind: Int, upstream: String?, gone: Bool) -> String {
        StatusVocabulary.describeRelationship(
            of: BranchSyncState(
                name: "main",
                sha: sha,
                upstreamFullRef: upstream.map { "refs/remotes/\($0)" },
                upstreamShort: upstream,
                ahead: ahead,
                behind: behind,
                upstreamGone: gone,
                isCurrent: true
            ),
            register: .plain
        )
    }

    private var relationshipStrings: [String] {
        [
            relationship(ahead: 0, behind: 0, upstream: "origin/main", gone: false),
            relationship(ahead: 2, behind: 0, upstream: "origin/main", gone: false),
            relationship(ahead: 0, behind: 3, upstream: "origin/main", gone: false),
            relationship(ahead: 1, behind: 2, upstream: "origin/main", gone: false), // diverged ✓
            relationship(ahead: 0, behind: 0, upstream: nil, gone: false),
            relationship(ahead: 0, behind: 0, upstream: "origin/main", gone: true)
        ]
    }

    private var outcomeStrings: [String] {
        let ffOutcomes: [FastForwardOutcome] = [
            .fastForwarded(from: sha, to: String(repeating: "b", count: 40)),
            .upToDate, .aheadOnly(ahead: 2),
            .diverged(ahead: 1, behind: 2), // ✓
            .noUpstream, .upstreamGone, .skippedDirtyWorktree,
            .skippedCheckedOutElsewhere, .failed(reason: "boom")
        ]
        let pushOutcomes: [PushOutcome] = [
            .pushed(branch: "main", upstream: "origin/main", commits: 2),
            .nothingToPush(branch: "main"),
            .publishedNewUpstream(branch: "feature/x", remote: "origin"),
            .rejectedNonFastForward(branch: "main"), // ✓ never-forces
            .noRemotes(branch: "main"),
            .detachedHEAD, // ✓ detached
            .failed(reason: "boom")
        ]
        let rebaseOutcomes: [RebaseOutcome] = [
            .rebased(branch: "main", onto: "origin/main", replayed: 2),
            .notDiverged(branch: "main"),
            .conflicted(branch: "main", conflictedPathCount: 1),
            .noUpstream(branch: "main"),
            .detachedHEAD, // ✓ detached
            .dirtyWorktree(branch: "main"),
            .failed(reason: "boom")
        ]
        return ffOutcomes.map { StatusVocabulary.describe($0, register: .plain) }
            + pushOutcomes.map { StatusVocabulary.describe($0, register: .plain) }
            + rebaseOutcomes.map { StatusVocabulary.describe($0, register: .plain) }
    }

    private var warningAndStaleStrings: [String] {
        let warnings: [PreflightWarning] = [
            .committingToDefaultBranch(branch: "main", upstream: "origin/main"),
            .detachedHEAD(oid: sha), // ✓ detached
            .largeStagedFileWithoutLFS(path: "big.bin", sizeBytes: 60_000_000, thresholdBytes: 52_428_800),
            .switchingAwayFromUnpushed(branch: "feature/x", unpushedCount: 2)
        ]
        let stales = [
            StaleBranch(
                name: "merged", sha: sha, formerUpstream: "origin/merged",
                isCurrent: false, safeToDelete: true, unpushedCommitCount: 0
            ),
            StaleBranch(
                name: "current", sha: sha, formerUpstream: "origin/current",
                isCurrent: true, safeToDelete: false, unpushedCommitCount: 0
            ),
            StaleBranch(
                name: "unmerged", sha: sha, formerUpstream: "origin/unmerged",
                isCurrent: false, safeToDelete: false, unpushedCommitCount: 2
            )
        ]
        return warnings.map { StatusVocabulary.describe($0, register: .plain) }
            + stales.map { StatusVocabulary.describe($0, register: .plain) }
            + [
                StatusVocabulary.describe(SetAsideOutcome.reapplied, register: .plain),
                StatusVocabulary.describe(SetAsideOutcome.keptInStash(detail: "x"), register: .plain)
            ]
    }

    /// Every plain-register string in the vocabulary, exercised with
    /// representative values. The (git:) teaching device is reserved
    /// for diverged, detached HEAD, and the never-forces rejection —
    /// six strings today (the rebase follow-up added a second
    /// detached-HEAD line). Anything new that wants a parenthetical
    /// must update this census deliberately.
    @Test("only the ratified strings carry a (git:) parenthetical")
    func parentheticalCensus() {
        let all = relationshipStrings + outcomeStrings + warningAndStaleStrings

        let withParenthetical = all.filter { $0.contains("(git:") }
        #expect(withParenthetical.count == 6, "got: \(withParenthetical)")
        #expect(withParenthetical.allSatisfy { string in
            string.contains("diverged") || string.contains("detached HEAD")
                || string.contains("never forces")
        }, "a (git:) parenthetical outside the ratified set: \(withParenthetical)")
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

@Suite("StatusVocabulary — rebase follow-up outcomes")
struct VocabularyRebaseTests {
    @Test("git register is pinned (CLI wire); plain register replays in plain words")
    func rebaseCoverage() {
        #expect(
            StatusVocabulary.describe(
                RebaseOutcome.rebased(branch: "main", onto: "origin/main", replayed: 2),
                register: .git
            ) == "main: rebased 2 commit(s) onto origin/main"
        )
        #expect(
            StatusVocabulary.describe(
                RebaseOutcome.rebased(branch: "main", onto: "origin/main", replayed: 2),
                register: .plain
            ) == "replayed your 2 commit(s) on top of the server's work"
        )
        let conflictedPlain = StatusVocabulary.describe(
            RebaseOutcome.conflicted(branch: "main", conflictedPathCount: 3),
            register: .plain
        )
        #expect(conflictedPlain.contains("resolve"), "conflict copy names the fix path")
        #expect(conflictedPlain.contains("abort"), "…and the undo path")
        let outcomes: [RebaseOutcome] = [
            .rebased(branch: "main", onto: "origin/main", replayed: 1),
            .notDiverged(branch: "main"),
            .conflicted(branch: "main", conflictedPathCount: 1),
            .noUpstream(branch: "main"),
            .detachedHEAD,
            .dirtyWorktree(branch: "main"),
            .failed(reason: "boom")
        ]
        for outcome in outcomes {
            let git = StatusVocabulary.describe(outcome, register: .git)
            let plain = StatusVocabulary.describe(outcome, register: .plain)
            #expect(!git.isEmpty)
            #expect(!plain.isEmpty)
            #expect(
                !plain.localizedCaseInsensitiveContains("force"),
                "rebase copy never mentions forcing: \(plain)"
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

    @Test("staged-secret rail names the file, line, rule, and both remedies in plain copy")
    func stagedSecretCopy() {
        let warning = PreflightWarning.stagedSecretDetected(
            path: "app/config.py", rule: "AWS Access Key ID", line: 12
        )
        let plain = StatusVocabulary.describe(warning, register: .plain)
        #expect(plain.contains("app/config.py"))
        #expect(plain.contains("AWS Access Key ID"))
        #expect(plain.contains("line 12"))
        #expect(plain.contains(".gitignore"))
        #expect(plain.contains("rotate"), "plain copy carries the revocation-first remedy")
        let git = StatusVocabulary.describe(warning, register: .git)
        #expect(git.contains("app/config.py:12"))
    }

    @Test("set-aside outcomes format in both registers")
    func setAsideCoverage() {
        #expect(
            StatusVocabulary.describe(SetAsideOutcome.reapplied, register: .git)
                == "stash reapplied"
        )
        #expect(
            StatusVocabulary.describe(SetAsideOutcome.reapplied, register: .plain)
                == "your changes came along to the new branch"
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
        #expect(keptPlain.contains("set aside"))
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
