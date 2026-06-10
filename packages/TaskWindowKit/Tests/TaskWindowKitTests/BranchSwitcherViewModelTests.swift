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

        // ADR 0069: the dirty-tree refusal is exactly the moment the
        // UI offers "Set aside changes and switch".
        #expect(await vm.canOfferSetAside)
    }

    // MARK: - ADR 0069 "Set aside changes" composite

    /// Divergent-`a.txt` fixture (same shape as
    /// ``switchFailsOnConflictingDirtyTree``): feature/x commits a
    /// different a.txt, we're on main. Optionally dirties a file.
    private func makeDivergentFixture() async throws -> (URL, Runner) {
        let (dir, runner) = try await makeRepoWithBranches()
        _ = try await runner.run(["switch", "feature/x"])
        try Data("on-feature-x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feature edit"])
        _ = try await runner.run(["switch", "main"])
        return (dir, runner)
    }

    @Test("set-aside switch carries non-conflicting changes to the new branch (reapplied)")
    func setAsideCarriesChangesAcross() async throws {
        let (dir, runner) = try await makeDivergentFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Dirty a file that's IDENTICAL on both branches (b.txt is
        // new + untracked) — the stash re-applies cleanly after the
        // switch, so the work travels with the user.
        let scratch = dir.appendingPathComponent("b.txt")
        try Data("in-progress work\n".utf8).write(to: scratch)

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch(settingAsideChanges: true)

        #expect(await vm.state == .success("feature/x"))
        #expect(await vm.setAsideOutcome == .reapplied)
        #expect(try await currentBranchName(runner) == "feature/x")
        // Normalize CRLF: Git for Windows defaults to core.autocrlf=true,
        // so the stash-pop checkout rewrites text files with \r\n there
        // (CLAUDE.md test rule: no POSIX-only assumptions).
        let carried = try String(contentsOf: scratch, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(carried == "in-progress work\n")
        // Entry consumed: applied + dropped.
        let stashRef = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/stash"],
            throwOnNonZero: false
        )
        #expect(stashRef.exitCode != 0)
    }

    @Test("set-aside switch with conflicting changes succeeds and keeps them in the stash")
    func setAsideKeepsConflictingChangesInStash() async throws {
        let (dir, runner) = try await makeDivergentFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The dirty edit collides with feature/x's committed a.txt —
        // re-applying after the switch conflicts, so the entry must
        // be KEPT and the outcome surfaced.
        try Data("uncommitted-on-main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch(settingAsideChanges: true)

        #expect(await vm.state == .success("feature/x"), "the switch itself succeeded")
        guard case .keptInStash = await vm.setAsideOutcome else {
            await Issue.record("expected .keptInStash, got \(String(describing: vm.setAsideOutcome))")
            return
        }
        #expect(try await currentBranchName(runner) == "feature/x")
        // Nothing lost: the entry survived for later re-apply.
        let stashRef = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/stash"],
            throwOnNonZero: false
        )
        #expect(stashRef.exitCode == 0)
    }

    @Test("set-aside switch on a clean tree degrades to a plain switch")
    func setAsideOnCleanTree() async throws {
        let (dir, runner) = try await makeRepoWithBranches()
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("other")
        await vm.switchBranch(settingAsideChanges: true)

        #expect(await vm.state == .success("other"))
        #expect(await vm.setAsideOutcome == nil, "nothing was set aside on a clean tree")
        let stashRef = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "refs/stash"],
            throwOnNonZero: false
        )
        #expect(stashRef.exitCode != 0, "no stash entry should be created for a clean tree")
    }

    @Test("canOfferSetAside clears on selection change and reset()")
    func canOfferSetAsideClears() async throws {
        let (dir, runner) = try await makeDivergentFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("uncommitted-on-main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let vm = BranchSwitcherViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.select("feature/x")
        await vm.switchBranch()
        #expect(await vm.canOfferSetAside)

        await vm.select("other")
        #expect(await vm.canOfferSetAside == false, "stale offer must not survive a new selection")

        await vm.select("feature/x")
        await vm.switchBranch()
        #expect(await vm.canOfferSetAside)
        await vm.reset()
        #expect(await vm.canOfferSetAside == false)
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
