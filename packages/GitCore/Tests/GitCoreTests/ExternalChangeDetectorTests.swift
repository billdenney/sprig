// ExternalChangeDetectorTests.swift
//
// ADR 0088 — detection of externally-authored change. Real git in temp
// dirs: a commit Sprig recorded authoring is NOT flagged external; a
// plain `git commit` with no provenance record IS; and a HEAD moved by
// an outside `reset` (when Sprig had checkpointed the ref) reads as
// movedExternally.

import Foundation
@testable import GitCore
import Testing

@Suite("ExternalChangeDetector — external-change detection (real git)", .serialized)
struct ExternalChangeDetectorTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-ecd-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // Byte-exact assertions later: keep git from rewriting line
        // endings under core.autocrlf=true (git-for-Windows default).
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        return (dir, runner)
    }

    private func commit(_ runner: Runner, _ dir: URL, file: String, content: String, message: String) async throws -> String {
        try Data(content.utf8).write(to: dir.appendingPathComponent(file))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", message])
        return try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("a plain git commit with no provenance record is flagged external")
    func plainCommitIsExternal() async throws {
        let (dir, runner) = try await makeRepo("plain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "base")
        let outside = try await commit(runner, dir, file: "b.txt", content: "2\n", message: "outside work")

        let detector = ExternalChangeDetector(runner: runner)
        let externals = try await detector.externalCommits(in: "\(base)..HEAD")
        #expect(externals.count == 1)
        #expect(externals.first?.sha == outside)
        #expect(externals.first?.subject == "outside work")
    }

    @Test("a Sprig-authored commit is NOT flagged external")
    func authoredCommitIsNotExternal() async throws {
        let (dir, runner) = try await makeRepo("authored")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "base")
        let mine = try await commit(runner, dir, file: "b.txt", content: "2\n", message: "sprig work")
        // Record it as Sprig-authored, exactly as a Sprig verb would.
        try await OperationProvenance(runner: runner).recordAuthored(mine)

        let detector = ExternalChangeDetector(runner: runner)
        let externals = try await detector.externalCommits(in: "\(base)..HEAD")
        #expect(externals.isEmpty)
    }

    @Test("mixed range: only the unrecorded commit is external")
    func mixedRange() async throws {
        let (dir, runner) = try await makeRepo("mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "base")
        let mine = try await commit(runner, dir, file: "b.txt", content: "2\n", message: "sprig")
        try await OperationProvenance(runner: runner).recordAuthored(mine)
        let outside = try await commit(runner, dir, file: "c.txt", content: "3\n", message: "outside")

        let detector = ExternalChangeDetector(runner: runner)
        let externals = try await detector.externalCommits(in: "\(base)..HEAD")
        #expect(externals.map(\.sha) == [outside]) // newest-first; mine filtered out
    }

    @Test("HEAD moved by an outside reset reads as movedExternally")
    func headMovedExternally() async throws {
        let (dir, runner) = try await makeRepo("headmove")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "first")
        let second = try await commit(runner, dir, file: "a.txt", content: "2\n", message: "second")
        // Sprig checkpoints the ref state at `second`.
        try await OperationProvenance(runner: runner).recordHeads(["refs/heads/main": second])
        // An outside process resets HEAD back to `first`.
        _ = try await runner.run(["reset", "--hard", first])

        let detector = ExternalChangeDetector(runner: runner)
        let movement = try await detector.headMovement()
        #expect(movement == .movedExternally(from: second, to: first))
    }

    @Test("HEAD at the checkpointed SHA reads as unchanged")
    func headUnchanged() async throws {
        let (dir, runner) = try await makeRepo("nomove")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tip = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "first")
        try await OperationProvenance(runner: runner).recordHeads(["refs/heads/main": tip])

        let detector = ExternalChangeDetector(runner: runner)
        #expect(try await detector.headMovement() == .unchanged)
    }

    @Test("a Sprig-authored new tip is not an external HEAD move")
    func authoredTipIsNotExternalMove() async throws {
        let (dir, runner) = try await makeRepo("authoredtip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "first")
        let prov = OperationProvenance(runner: runner)
        try await prov.recordHeads(["refs/heads/main": first])
        // Sprig makes (and records) a new commit — HEAD advances, but
        // this is Sprig's own work, not an external move.
        let second = try await commit(runner, dir, file: "a.txt", content: "2\n", message: "second")
        try await prov.recordAuthored(second)

        let detector = ExternalChangeDetector(runner: runner)
        #expect(try await detector.headMovement() == .unchanged)
    }

    @Test("report scopes the range to the checkpoint and reports both signals")
    func reportScopesAndReports() async throws {
        let (dir, runner) = try await makeRepo("report")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "base")
        // Sprig checkpoints at base; everything after is candidate.
        try await OperationProvenance(runner: runner).recordHeads(["refs/heads/main": base])
        let outside = try await commit(runner, dir, file: "b.txt", content: "2\n", message: "outside")

        let detector = ExternalChangeDetector(runner: runner)
        let report = try await detector.report()
        #expect(report.hasExternalChange)
        #expect(report.commits.map(\.sha) == [outside]) // base excluded by `base..HEAD`
        // HEAD moved from base to outside, unauthored → external move.
        #expect(report.headMovement == .movedExternally(from: base, to: outside))
    }

    @Test("an unborn branch (no commits) reports a clean empty report, not an error")
    func unbornBranchReportsEmpty() async throws {
        let (dir, runner) = try await makeRepo("unborn")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Freshly init'd: a branch ref exists but resolves to nothing.
        // `git log HEAD` would exit 128; report() must absorb that.
        let detector = ExternalChangeDetector(runner: runner)
        let report = try await detector.report()
        #expect(report.commits.isEmpty)
        #expect(report.headMovement == .unchanged)
        #expect(!report.hasExternalChange)
    }

    @Test("an external reset onto an older Sprig-authored commit still reads as movedExternally")
    func externalRewindOntoAuthoredAncestor() async throws {
        let (dir, runner) = try await makeRepo("rewind")
        defer { try? FileManager.default.removeItem(at: dir) }
        let prov = OperationProvenance(runner: runner)
        // Sprig authors X then Y (both recorded as authored); HEAD is
        // checkpointed at Y.
        let first = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "first")
        try await prov.recordAuthored(first)
        let second = try await commit(runner, dir, file: "a.txt", content: "2\n", message: "second")
        try await prov.recordAuthored(second)
        try await prov.recordHeads(["refs/heads/main": second])
        // An OUTSIDE process rewinds HEAD to the older (Sprig-authored)
        // commit. Authorship of `first` must NOT suppress the move — only
        // a forward move (Y is an ancestor of the new tip) is internal.
        _ = try await runner.run(["reset", "--hard", first])

        let detector = ExternalChangeDetector(runner: runner)
        #expect(try await detector.headMovement() == .movedExternally(from: second, to: first))
    }

    @Test("no checkpoint: report falls back to HEAD and still filters authored")
    func reportFallbackWithoutCheckpoint() async throws {
        let (dir, runner) = try await makeRepo("fallback")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await commit(runner, dir, file: "a.txt", content: "1\n", message: "first")
        let mine = try await commit(runner, dir, file: "b.txt", content: "2\n", message: "sprig")
        let outside = try await commit(runner, dir, file: "c.txt", content: "3\n", message: "outside")
        try await OperationProvenance(runner: runner).recordAuthored(mine)

        let detector = ExternalChangeDetector(runner: runner)
        let report = try await detector.report()
        // No recordHeads → HEAD movement unchanged; range falls to HEAD,
        // so both `first` and `outside` are external, `mine` filtered.
        #expect(report.headMovement == .unchanged)
        #expect(report.commits.map(\.sha).contains(outside))
        #expect(!report.commits.map(\.sha).contains(mine))
    }
}
