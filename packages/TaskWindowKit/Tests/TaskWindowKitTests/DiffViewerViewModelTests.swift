// DiffViewerViewModelTests.swift
//
// Integration tests for DiffViewerViewModel against a real repo with
// committed + staged + worktree changes. CLAUDE.md: spawn real git,
// no mocks. Pure-function tests of argv builder + header counter run
// without git.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("DiffViewerViewModel — argv + header counter + real-git integration")
struct DiffViewerViewModelTests {
    // MARK: - Pure-function tests (no git)

    @Test("gitArguments(for:) builds the right argv per target")
    func gitArgumentsForEachTarget() {
        #expect(DiffViewerViewModel.gitArguments(for: .worktreeAgainstIndex) == ["diff"])
        #expect(DiffViewerViewModel.gitArguments(for: .indexAgainstHead) == ["diff", "--cached"])
        #expect(
            DiffViewerViewModel.gitArguments(for: .commit(sha: "deadbeef"))
                == ["show", "--format=", "deadbeef"]
        )
    }

    @Test("countDiffGitHeaders counts only line-starting markers, not substring matches")
    func countDiffGitHeadersCorrectness() {
        // Empty.
        #expect(DiffViewerViewModel.countDiffGitHeaders(in: Data()) == 0)

        // One header at start.
        let one = Data("diff --git a/x b/x\n@@\n".utf8)
        #expect(DiffViewerViewModel.countDiffGitHeaders(in: one) == 1)

        // Multiple headers, separated by content.
        let two = Data("diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/y b/y\n@@\n".utf8)
        #expect(DiffViewerViewModel.countDiffGitHeaders(in: two) == 2)

        // A substring of the marker inside a commit-message-like line
        // must not count. The marker only triggers when at start or
        // after a newline.
        let trap = Data("some commit message saying diff --git a/x b/x in passing\n".utf8)
        #expect(DiffViewerViewModel.countDiffGitHeaders(in: trap) == 0)
    }

    // MARK: - Fixture

    private func makeRepoWithChanges() async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-diffview-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])

        // Seed commit: a.txt + b.txt
        try Data("seed-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("seed-b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "a.txt", "b.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        // Stage a change to a.txt (index ≠ HEAD).
        try Data("staged-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])

        // Worktree edit on b.txt (worktree ≠ index).
        try Data("worktree-b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func headSHA(_ runner: Runner) async throws -> String {
        let output = try await runner.run(["rev-parse", "HEAD"])
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Integration

    @Test("load(worktreeAgainstIndex) returns a diff for the worktree-only b.txt change")
    func worktreeDiffShowsOnlyWorktreeChange() async throws {
        let (dir, runner) = try await makeRepoWithChanges()
        defer { cleanup(dir) }

        let vm = DiffViewerViewModel(repoURL: dir, runner: runner)
        await vm.load()

        let state = await vm.state
        let payload = try #require(await vm.payload)
        #expect(state == .success(1))
        #expect(payload.filesChanged == 1)
        #expect(payload.isEmpty == false)
        // The raw diff mentions b.txt (worktree change), not a.txt (staged).
        let text = String(data: payload.rawDiff, encoding: .utf8) ?? ""
        #expect(text.contains("b.txt"))
        #expect(text.contains("a.txt") == false)
    }

    @Test("load(indexAgainstHead) returns a diff for the staged a.txt change only")
    func stagedDiffShowsOnlyStagedChange() async throws {
        let (dir, runner) = try await makeRepoWithChanges()
        defer { cleanup(dir) }

        let vm = DiffViewerViewModel(
            repoURL: dir,
            runner: runner,
            target: .indexAgainstHead
        )
        await vm.load()

        let payload = try #require(await vm.payload)
        #expect(payload.filesChanged == 1)
        let text = String(data: payload.rawDiff, encoding: .utf8) ?? ""
        #expect(text.contains("a.txt"))
        #expect(text.contains("b.txt") == false)
    }

    @Test("load(commit:) returns the diff a single commit introduced")
    func commitDiffShowsIntroducedFiles() async throws {
        let (dir, runner) = try await makeRepoWithChanges()
        defer { cleanup(dir) }

        let head = try await headSHA(runner)
        let vm = DiffViewerViewModel(
            repoURL: dir,
            runner: runner,
            target: .commit(sha: head)
        )
        await vm.load()

        let payload = try #require(await vm.payload)
        // The seed commit added 2 files.
        #expect(payload.filesChanged == 2)
        #expect(await vm.state == .success(2))
    }

    @Test("load() on a clean target lands in .success(0) and isEmpty payload")
    func cleanTargetSuccessZero() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-diffview-clean-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let vm = DiffViewerViewModel(repoURL: dir, runner: runner)
        await vm.load()

        let payload = try #require(await vm.payload)
        #expect(payload.isEmpty)
        #expect(payload.filesChanged == 0)
        #expect(await vm.state == .success(0))
    }

    @Test("load() against a non-repo lands in .failure with a GitError")
    func loadFailsOnNonRepo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-diffview-nonrepo-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }

        let vm = DiffViewerViewModel(
            repoURL: dir,
            runner: Runner(defaultWorkingDirectory: dir)
        )
        await vm.load()

        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(failure.underlyingTypeName?.contains("GitError") == true)
        } else {
            Issue.record("expected .failure, got \(state)")
        }
        #expect(await vm.payload == nil)
    }

    @Test("setTarget(_:) leaves payload intact until the next load completes")
    func setTargetPreservesPayloadDuringRefetch() async throws {
        let (dir, runner) = try await makeRepoWithChanges()
        defer { cleanup(dir) }

        let vm = DiffViewerViewModel(repoURL: dir, runner: runner)
        await vm.load() // worktree → b.txt
        let initial = try #require(await vm.payload)
        #expect(initial.filesChanged == 1)

        await vm.setTarget(.indexAgainstHead)
        // Prior payload still visible — UI doesn't blank.
        #expect(await vm.payload == initial)

        await vm.load()
        // Now payload reflects the new target.
        let staged = try #require(await vm.payload)
        let stagedText = String(data: staged.rawDiff, encoding: .utf8) ?? ""
        #expect(stagedText.contains("a.txt"))
    }

    @Test("reset() returns state to .idle while preserving payload + target")
    func resetPreservesPayloadAndTarget() async throws {
        let (dir, runner) = try await makeRepoWithChanges()
        defer { cleanup(dir) }

        let vm = DiffViewerViewModel(
            repoURL: dir,
            runner: runner,
            target: .indexAgainstHead
        )
        await vm.load()
        let before = try #require(await vm.payload)

        await vm.reset()
        #expect(await vm.state == .idle)
        #expect(await vm.payload == before)
        #expect(await vm.target == .indexAgainstHead)
    }
}
