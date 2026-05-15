// CommitComposerViewModelTests.swift
//
// Integration tests for CommitComposerViewModel against a real repo
// with a mix of staged / unstaged / untracked changes. CLAUDE.md:
// spawn real git, no mocks. Pure-function tests cover the argv builder
// and message-validation logic without git.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("CommitComposerViewModel — argv + validation + real-git integration")
struct CommitComposerViewModelTests {
    // MARK: - Pure-function tests

    @Test("CommitMessage validation: empty subject rejected")
    func messageValidationEmpty() {
        let m = CommitMessage(subject: "  ", body: "x")
        #expect(m.validationError == "Enter a commit subject.")
        #expect(m.isReady == false)
    }

    @Test("CommitMessage validation: non-empty subject is ready")
    func messageValidationReady() {
        let m = CommitMessage(subject: "feat: x")
        #expect(m.validationError == nil)
        #expect(m.isReady)
    }

    @Test("gitCommitArguments: minimal subject-only commit")
    func argvMinimal() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-argv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: Runner(defaultWorkingDirectory: dir),
            message: CommitMessage(subject: "hello")
        )
        let argv = await vm.gitCommitArguments()
        #expect(argv == ["commit", "-m", "hello"])
    }

    @Test("gitCommitArguments: all options + body trimmed")
    func argvAllOptions() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-argv-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: Runner(defaultWorkingDirectory: dir),
            message: CommitMessage(subject: "feat: x", body: "\n\nMore detail.\n  "),
            options: CommitOptions(amend: true, signOff: true, sign: true, allowEmpty: true)
        )
        let argv = await vm.gitCommitArguments()
        #expect(argv == [
            "commit",
            "--amend",
            "-s",
            "-S",
            "--allow-empty",
            "-m", "feat: x",
            "-m", "More detail."
        ])
    }

    // MARK: - Fixture

    private func makeRepoWithMixedChanges() async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])

        try Data("seed-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        // Staged: a.txt modified + added
        try Data("staged-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        // Unstaged: b.txt new (will land as untracked first, then we stage)
        try Data("worktree-b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        // Untracked: c.txt
        try Data("untracked-c\n".utf8).write(to: dir.appendingPathComponent("c.txt"))

        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Refresh / partition

    @Test("refresh() partitions the working tree into staged / untracked piles")
    func refreshPartitionsState() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let staged = await vm.staged
        let untracked = await vm.untracked
        let conflicted = await vm.conflicted

        #expect(staged.contains("a.txt"))
        #expect(untracked.sorted() == ["b.txt", "c.txt"])
        #expect(conflicted.isEmpty)
    }

    // MARK: - Stage / unstage

    @Test("stage(_:) moves an untracked path to the staged pile")
    func stageMovesPath() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        #expect(await vm.untracked.contains("b.txt"))

        await vm.stage("b.txt")
        #expect(await vm.staged.contains("b.txt"))
        #expect(await vm.untracked.contains("b.txt") == false)
    }

    @Test("unstage(_:) moves a staged path back to unstaged (or untracked)")
    func unstageMovesPath() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        // a.txt is staged-modified; unstaging makes it worktree-modified.
        await vm.unstage("a.txt")
        let unstaged = await vm.unstaged
        let staged = await vm.staged
        #expect(unstaged.contains("a.txt"))
        #expect(staged.contains("a.txt") == false)
    }

    // MARK: - Commit happy path

    @Test("commit() with a valid message lands in .success carrying the new SHA")
    func commitSucceeds() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            message: CommitMessage(subject: "test: stage and commit a.txt")
        )
        await vm.refresh()
        await vm.commit()

        let state = await vm.state
        if case let .success(sha) = state {
            #expect(sha.count == 40, "expected a 40-char SHA-1")
        } else {
            Issue.record("expected .success(<sha>), got \(state)")
        }

        // After commit, a.txt is no longer staged.
        #expect(await vm.staged.contains("a.txt") == false)
    }

    // MARK: - Commit pre-flight rejections

    @Test("commit() rejects empty subject without spawning git")
    func commitRejectsEmptyMessage() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            message: CommitMessage(subject: "")
        )
        await vm.refresh()
        await vm.commit()

        if case let .failure(failure) = await vm.state {
            #expect(failure.description == "Enter a commit subject.")
            #expect(failure.underlyingTypeName == nil)
        } else {
            Issue.record("expected validation .failure")
        }
    }

    @Test("commit() rejects empty staging set without amend or allow-empty")
    func commitRejectsEmptyStaging() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-empty-\(UUID().uuidString)")
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

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            message: CommitMessage(subject: "no-op")
        )
        await vm.refresh()
        await vm.commit()

        if case let .failure(failure) = await vm.state {
            #expect(failure.description.contains("Nothing to commit"))
        } else {
            Issue.record("expected validation .failure for empty staging")
        }
    }

    @Test("commit() rejects when conflicted files are present")
    func commitRejectsConflicted() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-conflict-\(UUID().uuidString)")
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
        _ = try await runner.run(["checkout", "-b", "feature-a"])
        try Data("branch-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feature-a"])
        _ = try await runner.run(["checkout", "main"])
        try Data("branch-main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main-edit"])
        _ = try await runner.run(["merge", "feature-a"], throwOnNonZero: false)

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            message: CommitMessage(subject: "trying anyway")
        )
        await vm.refresh()
        #expect(await vm.conflicted.contains("a.txt"))

        await vm.commit()
        if case let .failure(failure) = await vm.state {
            #expect(failure.description.contains("Resolve"))
        } else {
            Issue.record("expected validation .failure for conflicts")
        }
    }

    // MARK: - State management

    @Test("reset() returns state to .idle while preserving message + options + partition")
    func resetPreservesContext() async throws {
        let (dir, runner) = try await makeRepoWithMixedChanges()
        defer { cleanup(dir) }

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            message: CommitMessage(subject: "x"),
            options: CommitOptions(signOff: true)
        )
        await vm.refresh()
        let stagedBefore = await vm.staged
        await vm.commit() // → .success
        await vm.reset()
        #expect(await vm.state == .idle)
        #expect(await vm.message.subject == "x")
        #expect(await vm.options.signOff == true)
        // After commit + reset, partition reflects the post-commit
        // state — staged should differ from before-commit.
        #expect(await vm.staged != stagedBefore)
    }
}
