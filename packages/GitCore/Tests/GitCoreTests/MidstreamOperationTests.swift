// MidstreamOperationTests.swift
//
// Unit tests for marker-file-based midstream-op detection plus a
// real-git integration test for each case the M4 VM dispatches on.

import Foundation
@testable import GitCore
import Testing

@Suite("MidstreamOperation — marker-file detection + real-git")
struct MidstreamOperationTests {
    // MARK: - Argv mapping (pure)

    @Test("continueArguments matches the documented per-op argv")
    func continueArgvMap() {
        #expect(MidstreamOperation.none.continueArguments == nil)
        #expect(MidstreamOperation.merge.continueArguments == ["commit", "--no-edit"])
        #expect(MidstreamOperation.rebase.continueArguments == ["rebase", "--continue"])
        #expect(MidstreamOperation.cherryPick.continueArguments == ["cherry-pick", "--continue"])
        #expect(MidstreamOperation.revert.continueArguments == ["revert", "--continue"])
        #expect(MidstreamOperation.am.continueArguments == ["am", "--continue"])
    }

    @Test("abortArguments matches the documented per-op argv")
    func abortArgvMap() {
        #expect(MidstreamOperation.none.abortArguments == nil)
        #expect(MidstreamOperation.merge.abortArguments == ["merge", "--abort"])
        #expect(MidstreamOperation.rebase.abortArguments == ["rebase", "--abort"])
        #expect(MidstreamOperation.cherryPick.abortArguments == ["cherry-pick", "--abort"])
        #expect(MidstreamOperation.revert.abortArguments == ["revert", "--abort"])
        #expect(MidstreamOperation.am.abortArguments == ["am", "--abort"])
    }

    // MARK: - Pure marker-file detection (synthesized gitDir)

    private func makeSyntheticGitDir(tag: String, markers: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-midstream-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for marker in markers {
            let url = dir.appendingPathComponent(marker)
            let parent = url.deletingLastPathComponent()
            if parent.path != dir.path {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            // A "marker" can be either a file or a directory based on
            // git's layout. The helper writes a file unless the marker
            // string ends in /, in which case it just leaves the parent
            // directory in place.
            if !marker.hasSuffix("/") {
                try Data().write(to: url)
            }
        }
        return dir
    }

    @Test("detectFromMarkers: empty gitDir → .none")
    func detectFromMarkersNone() throws {
        let dir = try makeSyntheticGitDir(tag: "none", markers: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .none)
    }

    @Test("detectFromMarkers: MERGE_HEAD → .merge")
    func detectFromMarkersMerge() throws {
        let dir = try makeSyntheticGitDir(tag: "merge", markers: ["MERGE_HEAD"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .merge)
    }

    @Test("detectFromMarkers: rebase-merge/ → .rebase")
    func detectFromMarkersRebaseMerge() throws {
        let dir = try makeSyntheticGitDir(tag: "rebase-merge", markers: ["rebase-merge/done"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .rebase)
    }

    @Test("detectFromMarkers: rebase-apply/ without applying → .rebase")
    func detectFromMarkersRebaseApply() throws {
        let dir = try makeSyntheticGitDir(tag: "rebase-apply", markers: ["rebase-apply/next"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .rebase)
    }

    @Test("detectFromMarkers: rebase-apply/applying → .am (wins over rebase)")
    func detectFromMarkersAm() throws {
        let dir = try makeSyntheticGitDir(tag: "am", markers: ["rebase-apply/applying"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .am)
    }

    @Test("detectFromMarkers: CHERRY_PICK_HEAD → .cherryPick")
    func detectFromMarkersCherryPick() throws {
        let dir = try makeSyntheticGitDir(tag: "cherry-pick", markers: ["CHERRY_PICK_HEAD"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .cherryPick)
    }

    @Test("detectFromMarkers: REVERT_HEAD → .revert")
    func detectFromMarkersRevert() throws {
        let dir = try makeSyntheticGitDir(tag: "revert", markers: ["REVERT_HEAD"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MidstreamOperation.detectFromMarkers(gitDirURL: dir) == .revert)
    }

    // MARK: - Real-git integration

    private func makeBaseRepo(tag: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-midstream-real-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    @Test("detect against a clean repo returns .none")
    func realCleanRepoIsNone() async throws {
        let (dir, runner) = try await makeBaseRepo(tag: "clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let op = try await MidstreamOperation.detect(repoURL: dir, runner: runner)
        #expect(op == .none)
    }

    @Test("detect against a mid-merge repo returns .merge")
    func realMidMergeIsMerge() async throws {
        let (dir, runner) = try await makeBaseRepo(tag: "merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["checkout", "-b", "feat"])
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feat"])
        _ = try await runner.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main"])
        _ = try await runner.run(["merge", "feat"], throwOnNonZero: false)

        let op = try await MidstreamOperation.detect(repoURL: dir, runner: runner)
        #expect(op == .merge)
    }

    @Test("detect against a mid-cherry-pick repo returns .cherryPick")
    func realMidCherryPickIsCherryPick() async throws {
        let (dir, runner) = try await makeBaseRepo(tag: "cp")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["checkout", "-b", "feat"])
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feat-edit"])
        let featSHA = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main-edit"])
        _ = try await runner.run(["cherry-pick", featSHA], throwOnNonZero: false)

        let op = try await MidstreamOperation.detect(repoURL: dir, runner: runner)
        #expect(op == .cherryPick)
    }

    @Test("detect against a mid-revert repo returns .revert")
    func realMidRevertIsRevert() async throws {
        let (dir, runner) = try await makeBaseRepo(tag: "revert")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Commit a change on main, then a conflicting worktree-change
        // commit, then revert the earlier change → conflict on the
        // second commit's content.
        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "v1"])
        let firstChangeSHA = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("v2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "v2"])
        _ = try await runner.run(["revert", "--no-edit", firstChangeSHA], throwOnNonZero: false)

        let op = try await MidstreamOperation.detect(repoURL: dir, runner: runner)
        #expect(op == .revert)
    }
}
