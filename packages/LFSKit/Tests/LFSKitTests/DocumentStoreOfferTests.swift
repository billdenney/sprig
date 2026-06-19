// DocumentStoreOfferTests.swift
//
// ADR 0091 (part B) — the once-per-repo offer flag (a file under the git
// common dir, NOT a ref) and the provider-neutral offer struct. The flag
// runs against a real git repo so the common-dir resolution exercises
// `git rev-parse --path-format=absolute --git-common-dir`, including the
// linked-worktree case where it must resolve to the SAME shared dir.

import Foundation
import GitCore
@testable import LFSKit
import Testing

@Suite("DocumentStoreOffer — provider-neutral offer struct")
struct DocumentStoreOfferStructTests {
    @Test("builds from a firing recommendation, carrying counts and patterns")
    func buildsFromFiringRecommendation() {
        let rec = DocumentStoreRecommendation(
            shouldOffer: true,
            trackedFileCount: 8,
            binaryFileCount: 6,
            suggestedPatterns: ["*.psd", "*.docx"]
        )
        let offer = try? #require(DocumentStoreOffer(recommendation: rec))
        #expect(offer?.patternsToTrack == ["*.psd", "*.docx"])
        #expect(offer?.trackedFileCount == 8)
        #expect(offer?.binaryFileCount == 6)
    }

    @Test("a declined recommendation yields no offer")
    func declinedRecommendationYieldsNil() {
        let rec = DocumentStoreRecommendation.declined(trackedFileCount: 3, binaryFileCount: 1)
        #expect(DocumentStoreOffer(recommendation: rec) == nil)
    }
}

@Suite("DocumentStoreOfferFlag — once-per-repo, real git")
struct DocumentStoreOfferFlagTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-docstore-flag-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        return (tmp, runner)
    }

    @Test("the offer fires once: absent → record → suppressed")
    func offerFiresOnce() async throws {
        let (root, runner) = try await mkRepo("once")
        defer { try? FileManager.default.removeItem(at: root) }

        // Fresh repo: nothing recorded yet.
        let before = try await DocumentStoreOfferFlag.hasOffered(runner: runner)
        #expect(!before)

        // Record the offer; now suppressed.
        try await DocumentStoreOfferFlag.recordOffered(runner: runner)
        let after = try await DocumentStoreOfferFlag.hasOffered(runner: runner)
        #expect(after)

        // Idempotent: a second record leaves it suppressed (single marker).
        try await DocumentStoreOfferFlag.recordOffered(runner: runner)
        #expect(try await DocumentStoreOfferFlag.hasOffered(runner: runner))
    }

    @Test("the marker lands under the git common dir, namespaced under sprig/")
    func markerPathIsUnderCommonDir() async throws {
        let (root, runner) = try await mkRepo("path")
        defer { try? FileManager.default.removeItem(at: root) }

        try await DocumentStoreOfferFlag.recordOffered(runner: runner)
        // The standard .git dir IS the common dir for a non-worktree repo.
        let marker = root
            .appendingPathComponent(".git")
            .appendingPathComponent("sprig/document-store-offer-made")
            .standardized
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("linked worktrees share the same flag (common dir, not per-worktree git dir)")
    func linkedWorktreesShareTheFlag() async throws {
        let (root, runner) = try await mkRepo("worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        // Need a commit before `git worktree add`.
        try Data("x".utf8).write(to: root.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let linked = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-linked")
            .standardized
        defer { try? FileManager.default.removeItem(at: linked) }
        _ = try await runner.run(["worktree", "add", linked.path, "-b", "side"])

        // Record from the MAIN worktree…
        try await DocumentStoreOfferFlag.recordOffered(runner: runner, cwd: root)
        // …and the LINKED worktree sees it suppressed (same common dir).
        let linkedRunner = Runner(defaultWorkingDirectory: linked)
        #expect(try await DocumentStoreOfferFlag.hasOffered(runner: linkedRunner, cwd: linked))
    }
}
