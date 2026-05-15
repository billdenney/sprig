// MergeConflictResolverDispatchTests.swift
//
// Per-midstream-op dispatch tests for MergeConflictResolverViewModel
// — verify that `finalize()` and `abort()` invoke the right
// `git <op> --continue` / `--abort` argv for cherry-pick (and that
// no-op states reject with a helpful message). Lives separately from
// the main resolver test file to keep each file under SwiftLint's
// type-body-length cap.

import ConflictKit
import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("MergeConflictResolverViewModel — per-midstream-op dispatch")
struct MergeConflictResolverDispatchTests {
    /// Build a repo mid-cherry-pick with a conflict on a.txt.
    private func makeCherryPickConflictRepo(tag: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-mcr-cp-\(tag)-\(UUID().uuidString)")
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
        _ = try await runner.run(["checkout", "-b", "feat"])
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feat-edit"])
        let featSHA = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main-edit"])
        _ = try await runner.run(["cherry-pick", featSHA], throwOnNonZero: false)
        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func headSubject(_ runner: Runner) async throws -> String {
        let out = try await runner.run(["log", "-1", "--pretty=%s"])
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("refresh() detects the active midstream operation (cherry-pick)")
    func refreshDetectsCherryPick() async throws {
        let (dir, runner) = try await makeCherryPickConflictRepo(tag: "detect")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        #expect(await vm.operation == .cherryPick)
        #expect(await vm.conflicts.count == 1)
    }

    @Test("finalize() during a cherry-pick runs `git cherry-pick --continue`")
    func finalizeCherryPickDispatch() async throws {
        let (dir, runner) = try await makeCherryPickConflictRepo(tag: "finalize")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .theirs)
        await vm.applyAll()
        await vm.finalize()

        // After cherry-pick --continue, no more midstream op.
        await vm.refresh()
        #expect(await vm.operation == .none)
        #expect(await vm.conflicts.isEmpty)
        // HEAD subject is the cherry-picked commit's subject.
        let subject = try await headSubject(runner)
        #expect(subject == "feat-edit")
    }

    @Test("abort() during a cherry-pick runs `git cherry-pick --abort`")
    func abortCherryPickDispatch() async throws {
        let (dir, runner) = try await makeCherryPickConflictRepo(tag: "abort")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.abort()

        #expect(await vm.operation == .none)
        #expect(await vm.conflicts.isEmpty)
        let subject = try await headSubject(runner)
        #expect(subject == "main-edit")
    }

    @Test("finalize() without refresh()ing first lands in .failure (no op known)")
    func finalizeNoOpRejects() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-mcr-no-op-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        // Skip refresh — operation stays .none, conflicts stays [].
        await vm.finalize()
        if case let .failure(failure) = await vm.state {
            // The "no conflicts" check fires first (empty conflicts
            // pre-empts the no-op check, which is the correct order
            // — the UI can't ask to finalize what it hasn't loaded).
            #expect(failure.description.contains("No conflicts"))
        } else {
            Issue.record("expected .failure")
        }
    }
}
