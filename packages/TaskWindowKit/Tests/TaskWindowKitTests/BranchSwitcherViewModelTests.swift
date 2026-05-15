// BranchSwitcherViewModelTests.swift
//
// Integration tests for BranchSwitcherViewModel against a real repo
// with multiple branches. CLAUDE.md: spawn real git, no mocks.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("BranchSwitcherViewModel — integration against real git")
struct BranchSwitcherViewModelTests {
    // MARK: - Fixture

    private func makeRepoWithBranches() async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-branchswitch-\(UUID().uuidString)")
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
        _ = try await runner.run(["branch", "feature/x"])
        _ = try await runner.run(["branch", "other"])
        return (dir, runner)
    }

    private func currentBranchName(_ runner: Runner) async throws -> String {
        let output = try await runner.run(["rev-parse", "--abbrev-ref", "HEAD"])
        return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Inventory + selection

    @Test("refresh() populates inventory and marks HEAD")
    func refreshPopulatesInventory() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let inventory = await vm.inventory
        #expect(inventory.count == 3)
        let names = inventory.map(\.shortName).sorted()
        #expect(names == ["feature/x", "main", "other"])

        let head = inventory.first(where: \.isHead)
        #expect(head?.shortName == "main")
    }

    @Test("select(_:) accepts known names and ignores unknown ones")
    func selectKnownAndUnknown() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        await vm.select("feature/x")
        #expect(await vm.selection == "feature/x")

        await vm.select("not-a-real-branch")
        #expect(await vm.selection == "feature/x", "unknown names must not change selection")

        await vm.clearSelection()
        #expect(await vm.selection == nil)
    }

    @Test("refresh() clears stale selection when the branch goes away")
    func refreshClearsStaleSelection() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("other")
        #expect(await vm.selection == "other")

        // Delete the branch out from under us, then refresh.
        _ = try await runner.run(["branch", "-D", "other"])
        await vm.refresh()
        #expect(await vm.selection == nil)
    }

    // MARK: - Switch operation

    @Test("switchBranch() runs git switch and lands on .success")
    func switchSucceeds() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch()

        let state = await vm.state
        #expect(state == .success("feature/x"))
        let onDisk = try await currentBranchName(runner)
        #expect(onDisk == "feature/x")
    }

    @Test("switchBranch() with no selection lands in .failure with a hint")
    func switchRejectsEmptySelection() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.switchBranch() // no selection

        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(failure.description.contains("Pick a branch"))
        } else {
            Issue.record("expected validation .failure, got \(state)")
        }
    }

    @Test("switchBranch() to the current HEAD is a soft no-op landing on .success")
    func switchToHeadIsNoop() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("main") // already HEAD
        await vm.switchBranch()

        let state = await vm.state
        #expect(state == .success("main"))
        // Still on main on disk; nothing changed.
        let onDisk = try await currentBranchName(runner)
        #expect(onDisk == "main")
    }

    @Test("switchBranch() against a dirty tree that conflicts surfaces git's error")
    func switchFailsOnConflictingDirtyTree() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Make feature/x's a.txt diverge from main's, so a switch with
        // an uncommitted local change to a.txt would clobber it.
        _ = try await runner.run(["switch", "feature/x"])
        try Data("on-feature-x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feature edit"])
        _ = try await runner.run(["switch", "main"])

        // Now modify a.txt on main without committing. `git switch
        // feature/x` will refuse because the worktree change would be
        // lost / conflict.
        try Data("uncommitted-on-main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch()

        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(!failure.description.isEmpty)
            #expect(failure.underlyingTypeName?.contains("GitError") == true)
        } else {
            Issue.record("expected .failure (dirty tree blocks switch), got \(state)")
        }
        let onDisk = try await currentBranchName(runner)
        #expect(onDisk == "main", "we must still be on main after a rejected switch")
    }

    // MARK: - State management

    @Test("reset() returns state to .idle while preserving inventory + selection")
    func resetPreservesInventoryAndSelection() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch()
        #expect(await vm.state == .success("feature/x"))

        await vm.reset()
        #expect(await vm.state == .idle)
        // Inventory + selection survive — useful for the "switch again
        // without re-refreshing" UX.
        #expect(await vm.inventory.count == 3)
        #expect(await vm.selection == "feature/x")
    }
}
