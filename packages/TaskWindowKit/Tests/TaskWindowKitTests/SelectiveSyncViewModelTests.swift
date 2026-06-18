// SelectiveSyncViewModelTests.swift
//
// ADR 0089 against real git. The load-bearing claims:
//
//   - refresh reflects the live cone state as keep/drop checkboxes;
//   - a CLEAN drop de-materializes the folder and turns cone mode on;
//   - a drop that would strand uncommitted / untracked work FAILS
//     CLOSED — the VM reports `blocked` and touches nothing;
//   - the force path mints an ADR 0075 backup BEFORE removing the work,
//     and that work comes back byte-for-byte through the real restore
//     path (the undo round-trip the destructive-verb rule requires).

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

// `.serialized`: real-git fixtures with worktree mutation per test.
@Suite("SelectiveSyncViewModel — folder picker (real git)", .serialized)
struct SelectiveSyncViewModelTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-selsync-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        for folder in ["alpha", "beta", "gamma"] {
            let sub = dir.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("\(folder)\n".utf8).write(to: sub.appendingPathComponent("file.txt"))
        }
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    private func exists(_ dir: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    private func content(_ dir: URL, _ relative: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - refresh

    @Test("refresh lists every top-level folder, all kept when sparse is off")
    func refreshListsFolders() async throws {
        let (dir, runner) = try await makeRepo("refresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        let directories = await vm.directories
        #expect(directories.map(\.name) == ["alpha", "beta", "gamma"])
        let allKept = directories.allSatisfy(\.isKept)
        #expect(allKept)
        #expect(await vm.isEnabled == false)
    }

    // MARK: - clean apply

    @Test("a clean drop de-materializes the folder and enables cone mode")
    func cleanDropApplies() async throws {
        let (dir, runner) = try await makeRepo("clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        await vm.setKept("beta", false)
        await vm.apply()

        #expect(await vm.state.successValue?.keptDirectories == ["alpha", "gamma"])
        #expect(await vm.isEnabled == true)
        #expect(exists(dir, "alpha/file.txt"))
        #expect(!exists(dir, "beta/file.txt"))
        #expect(await vm.blocked.isEmpty)
    }

    @Test("re-checking a dropped folder and applying again restores it byte-for-byte")
    func reapplyAfterReselect() async throws {
        let (dir, runner) = try await makeRepo("reapply")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        await vm.setKept("beta", false)
        await vm.apply()
        #expect(await vm.state.successValue?.keptDirectories == ["alpha", "gamma"])
        #expect(!exists(dir, "beta/file.txt"))

        // Re-check beta and apply again: success → busy → success, the
        // folder is re-materialized byte-for-byte from the object store.
        await vm.setKept("beta", true)
        await vm.apply()
        #expect(await vm.state.successValue?.keptDirectories == ["alpha", "beta", "gamma"])
        #expect(await vm.blocked.isEmpty)
        #expect(try content(dir, "beta/file.txt") == "beta\n")
    }

    @Test("a non-cone pattern repo is read-only — apply refuses without mutating")
    func unsupportedPatternModeRefuses() async throws {
        let (dir, runner) = try await makeRepo("unsupported")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["sparse-checkout", "set", "--no-cone", "/*", "!/beta/"])
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        #expect(await vm.isUnsupportedPatternMode)
        await vm.setKept("alpha", false)
        await vm.apply()
        #expect(await vm.state.failure != nil)
        // The hand-crafted pattern file is untouched.
        let selection = try await SparseCheckout(runner: runner).currentSelection()
        #expect(selection == .unsupportedPatternMode)
    }

    // MARK: - fail closed

    @Test("dropping a folder with unsaved work fails closed and touches nothing")
    func blockedDropFailsClosed() async throws {
        let (dir, runner) = try await makeRepo("blocked")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("beta/file.txt"))
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("beta/note.txt"))
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        await vm.setKept("beta", false)
        await vm.apply()

        // Reported, not applied.
        #expect(await vm.blocked.map(\.name) == ["beta"])
        #expect(await vm.state.failure != nil)
        // Nothing changed: sparse still off, beta still materialized.
        #expect(await vm.isEnabled == false)
        #expect(exists(dir, "beta/file.txt"))
        let selection = try await SparseCheckout(runner: runner).currentSelection()
        #expect(selection == .full)
    }

    // MARK: - force + undo round-trip

    @Test("force-removing unsaved work saves a backup that restores byte-for-byte")
    func forceRemovalRoundTrips() async throws {
        let (dir, runner) = try await makeRepo("force-undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        // beta holds an unsaved tracked edit AND a precious untracked file.
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("beta/file.txt"))
        try Data("precious\n".utf8).write(to: dir.appendingPathComponent("beta/note.txt"))
        let vm = SelectiveSyncViewModel(repoURL: dir, runner: runner)

        await vm.refresh()
        await vm.setKept("beta", false)
        await vm.apply() // blocks
        #expect(await vm.blocked.map(\.name) == ["beta"])

        // Now force it: backup is minted, beta is removed.
        await vm.applyRemovingUnsavedWork()
        #expect(await vm.state.successValue?.keptDirectories == ["alpha", "gamma"])
        #expect(!exists(dir, "beta/file.txt"))
        #expect(!exists(dir, "beta/note.txt"))
        let backupRef = try #require(await vm.lastBackup)
        #expect(await vm.state.successValue?.backupRef == backupRef.refName)

        // Undo through the real Recover path: turn selective sync off to
        // bring every folder back at HEAD, then restore the backup over
        // the worktree. Both the tracked edit and the untracked file
        // return byte-for-byte.
        try await SparseCheckout(runner: runner).disable()
        _ = try await WorktreeBackup(runner: runner).restore(backupRef.refName)
        #expect(try content(dir, "beta/file.txt") == "edited\n")
        #expect(exists(dir, "beta/note.txt"))
        #expect(try content(dir, "beta/note.txt") == "precious\n")
    }
}
