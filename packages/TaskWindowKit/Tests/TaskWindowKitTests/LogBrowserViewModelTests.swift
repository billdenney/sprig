// LogBrowserViewModelTests.swift
//
// Integration tests for LogBrowserViewModel against a real repo with a
// known commit history. CLAUDE.md: spawn real git, no mocks.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("LogBrowserViewModel — integration against real git")
struct LogBrowserViewModelTests {
    // MARK: - Fixture

    /// Build a repo with `count` linear commits. Returns the repo URL
    /// and a `Runner` pointed at it. Caller cleans up via
    /// ``cleanup(_:)``.
    private func makeLinearHistory(count: Int, tag: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-logbrowse-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        for index in 0 ..< count {
            try Data("v\(index)\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
            _ = try await runner.run(["add", "a.txt"])
            _ = try await runner.run(["commit", "-m", "commit-\(index)"])
        }
        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Initial load

    @Test("loadInitial() returns the first page of commits, most-recent first")
    func loadInitialFirstPage() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 10, tag: "first-page")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 5)
        await vm.loadInitial()

        let commits = await vm.commits
        #expect(commits.count == 5)
        // git log default order is reverse-chronological, so the most
        // recent commit (index 9) appears first.
        #expect(commits.first?.subject == "commit-9")
        #expect(commits.last?.subject == "commit-5")

        let state = await vm.state
        #expect(state == .success(5))
        #expect(await vm.hasMore == true)
    }

    @Test("loadInitial() against an empty range surfaces .success(0) and hasMore=false")
    func loadInitialEmpty() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 3, tag: "empty-range")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(
            repoURL: dir,
            runner: runner,
            revSpec: "HEAD..HEAD", // empty range
            pageSize: 5
        )
        await vm.loadInitial()

        #expect(await vm.commits.isEmpty)
        #expect(await vm.state == .success(0))
        #expect(await vm.hasMore == false)
    }

    // MARK: - Pagination

    @Test("loadMore() appends the next page and stops when history is exhausted")
    func loadMoreToExhaustion() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 7, tag: "exhaust")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 3)
        await vm.loadInitial()
        #expect(await vm.commits.count == 3)
        #expect(await vm.hasMore == true)

        await vm.loadMore()
        #expect(await vm.commits.count == 6)
        #expect(await vm.hasMore == true)

        await vm.loadMore()
        // History had 7 commits; this page only returns 1, so we know
        // we've hit the end.
        #expect(await vm.commits.count == 7)
        #expect(await vm.hasMore == false)

        // Subsequent loadMore() is a no-op.
        await vm.loadMore()
        #expect(await vm.commits.count == 7)
    }

    @Test("loadInitial() after pagination resets the cache cleanly")
    func loadInitialResetsCache() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 5, tag: "reset")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 2)
        await vm.loadInitial()
        await vm.loadMore()
        #expect(await vm.commits.count == 4)

        await vm.loadInitial()
        #expect(await vm.commits.count == 2, "loadInitial discards prior pages")
        #expect(await vm.hasMore == true)
    }

    // MARK: - Configuration

    @Test("setRevSpec(_:) changes the next load's target without auto-reloading")
    func setRevSpecDoesNotAutoReload() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 4, tag: "revspec")
        defer { cleanup(dir) }

        _ = try await runner.run(["checkout", "-b", "feature"])
        try Data("feature\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "on-feature"])

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 100)
        await vm.loadInitial() // HEAD = feature (5 commits)
        #expect(await vm.commits.count == 5)

        await vm.setRevSpec("main")
        // Cached commits stay until next load — exactly the design
        // (UI resets scroll on caller's terms).
        #expect(await vm.commits.count == 5)

        await vm.loadInitial()
        #expect(await vm.commits.count == 4)
        #expect(await vm.commits.first?.subject == "commit-3")
    }

    @Test("setPageSize(_:) clamps to >=1 and applies on the next load")
    func setPageSizeClampsAndApplies() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 6, tag: "page-size")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 2)
        await vm.setPageSize(0) // clamped to 1
        #expect(await vm.pageSize == 1)

        await vm.loadInitial()
        #expect(await vm.commits.count == 1)
    }

    // MARK: - Error handling

    @Test("loadInitial() against a non-repo lands in .failure with a GitError")
    func loadInitialFailsOnNonRepo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-logbrowse-nonrepo-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(
            repoURL: dir,
            runner: Runner(defaultWorkingDirectory: dir)
        )
        await vm.loadInitial()

        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(failure.underlyingTypeName?.contains("GitError") == true)
        } else {
            Issue.record("expected .failure, got \(state)")
        }
        #expect(await vm.commits.isEmpty)
    }

    @Test("reset() preserves loaded commits but returns state to .idle")
    func resetPreservesCommits() async throws {
        let (dir, runner) = try await makeLinearHistory(count: 3, tag: "reset-state")
        defer { cleanup(dir) }

        let vm = LogBrowserViewModel(repoURL: dir, runner: runner, pageSize: 10)
        await vm.loadInitial()
        #expect(await vm.commits.count == 3)
        #expect(await vm.state == .success(3))

        await vm.reset()
        #expect(await vm.state == .idle)
        #expect(await vm.commits.count == 3, "loaded data survives a state reset")
    }
}
