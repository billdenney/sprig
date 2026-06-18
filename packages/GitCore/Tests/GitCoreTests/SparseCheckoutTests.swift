// SparseCheckoutTests.swift
//
// ADR 0089 — cone-mode sparse-checkout wrapper + the dirty-folder
// safety analysis, against real git (never mocked). The contract under
// test: top-level directory discovery excludes blobs and submodule
// gitlinks; set/list/disable round-trips materialization; and
// planChange flags dropped folders that hold uncommitted / untracked
// work (the "lossless" claim the bare git command can't keep).

import Foundation
@testable import GitCore
import Testing

@Suite("SparseCheckout — cone verbs + dirty-folder guard against real git")
struct SparseCheckoutTests {
    /// Seed a repo with three top-level folders (alpha/beta/gamma) and a
    /// repo-root file. Sparse-checkout starts OFF (.full).
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-sparse-\(label)-\(UUID().uuidString)")
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
        try Data("root\n".utf8).write(to: dir.appendingPathComponent("root.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    private func exists(_ dir: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(relative).path)
    }

    // MARK: - Parser

    @Test("parseTopLevelTreeDirectories keeps trees, drops blobs and submodule gitlinks")
    func parserFiltersToTrees() {
        let hash = String(repeating: "a", count: 40)
        // git emits `<mode> SP <type> SP <object> TAB <path>`.
        let record = { (mode: String, type: String, path: String) in
            "\(mode) \(type) \(hash)\t\(path)"
        }
        let lines = [
            record("100644", "blob", "root.txt"), // repo-root file → excluded
            record("040000", "tree", "alpha"), // directory → kept
            record("040000", "tree", "beta"), // directory → kept
            record("160000", "commit", "vendored") // submodule gitlink → excluded
        ]
        let data = Data((lines.joined(separator: "\u{0}") + "\u{0}").utf8)
        #expect(SparseCheckout.parseTopLevelTreeDirectories(data) == ["alpha", "beta"])
    }

    @Test("topLevelComponent splits on the first slash; nil for repo-root files")
    func topLevelComponentSplits() {
        #expect(SparseCheckout.topLevelComponent(of: "alpha/file.txt") == "alpha")
        #expect(SparseCheckout.topLevelComponent(of: "alpha/nested/deep.txt") == "alpha")
        #expect(SparseCheckout.topLevelComponent(of: "root.txt") == nil)
    }

    // MARK: - Reads

    @Test("topLevelDirectories returns the HEAD-tree folders, excluding root files")
    func topLevelDirectoriesFromHead() async throws {
        let (dir, runner) = try await makeRepo("topdirs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let directories = try await SparseCheckout(runner: runner).topLevelDirectories()
        #expect(directories == ["alpha", "beta", "gamma"])
    }

    @Test("currentSelection is .full when sparse-checkout is off")
    func selectionFullWhenOff() async throws {
        let (dir, runner) = try await makeRepo("full")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try await SparseCheckout(runner: runner).currentSelection() == .full)
    }

    @Test("currentSelection reports unsupported pattern mode for a non-cone sparse repo")
    func selectionUnsupportedForNonCone() async throws {
        let (dir, runner) = try await makeRepo("noncone")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["sparse-checkout", "set", "--no-cone", "/*", "!/beta/"])
        let sparse = SparseCheckout(runner: runner)
        #expect(try await sparse.currentSelection() == .unsupportedPatternMode)
        // planChange refuses rather than mangling the hand-crafted patterns.
        await #expect(throws: SparseCheckoutError.unsupportedPatternMode) {
            _ = try await sparse.planChange(to: ["alpha"])
        }
    }

    // MARK: - Write round-trip

    @Test("set/list de-materializes the rest; disable restores the full worktree")
    func setListDisableRoundTrip() async throws {
        let (dir, runner) = try await makeRepo("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sparse = SparseCheckout(runner: runner)

        try await sparse.enableConeMode()
        try await sparse.set(["alpha"])

        #expect(try await sparse.currentSelection() == .cone(directories: ["alpha"]))
        #expect(exists(dir, "alpha/file.txt"))
        #expect(!exists(dir, "beta/file.txt"))
        #expect(!exists(dir, "gamma/file.txt"))
        #expect(exists(dir, "root.txt")) // cone always keeps repo-root files

        // Re-check beta: it comes back from the object store.
        try await sparse.add(["beta"])
        #expect(exists(dir, "beta/file.txt"))

        try await sparse.disable()
        #expect(try await sparse.currentSelection() == .full)
        #expect(exists(dir, "beta/file.txt"))
        #expect(exists(dir, "gamma/file.txt"))
    }

    // MARK: - planChange (the safety analysis)

    @Test("planChange on a clean repo reports drops/adds and no blocked folders")
    func planChangeClean() async throws {
        let (dir, runner) = try await makeRepo("plan-clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sparse = SparseCheckout(runner: runner)

        let plan = try await sparse.planChange(to: ["alpha"])
        #expect(plan.drops == ["beta", "gamma"])
        #expect(plan.adds.isEmpty)
        #expect(plan.blockedDrops.isEmpty)
        #expect(plan.isCleanToApply)
    }

    @Test("planChange blocks a dropped folder with an unsaved tracked change")
    func planChangeBlocksModified() async throws {
        let (dir, runner) = try await makeRepo("plan-modified")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("beta/file.txt"))

        let plan = try await SparseCheckout(runner: runner).planChange(to: ["alpha", "gamma"])
        #expect(plan.blockedDrops.map(\.name) == ["beta"])
        #expect(plan.blockedDrops.first?.reasons.contains(.unsavedChange) == true)
        #expect(!plan.isCleanToApply)
    }

    @Test("planChange blocks a dropped folder with an untracked file")
    func planChangeBlocksUntracked() async throws {
        let (dir, runner) = try await makeRepo("plan-untracked")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("gamma/note.txt"))

        let plan = try await SparseCheckout(runner: runner).planChange(to: ["alpha", "beta"])
        #expect(plan.blockedDrops.map(\.name) == ["gamma"])
        #expect(plan.blockedDrops.first?.reasons.contains(.untrackedFile) == true)
    }

    @Test("planChange blocks a dropped folder with a staged change")
    func planChangeBlocksStaged() async throws {
        let (dir, runner) = try await makeRepo("plan-staged")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("staged\n".utf8).write(to: dir.appendingPathComponent("beta/file.txt"))
        _ = try await runner.run(["add", "beta/file.txt"])

        let plan = try await SparseCheckout(runner: runner).planChange(to: ["alpha", "gamma"])
        #expect(plan.blockedDrops.map(\.name) == ["beta"])
        #expect(plan.blockedDrops.first?.reasons.contains(.stagedChange) == true)
    }

    // Not on Windows: `git mv <dir> <Dir>` (a case-only *directory*
    // rename) fails with EPERM on the Windows VM's filesystem — Windows
    // can't rename a directory to a case-variant of itself in one step,
    // so the on-disk case divergence this test needs can't be set up
    // there. The case-fold logic under test is platform-independent
    // (pure string folding gated on `core.ignorecase`) and the
    // production fix protects Windows (NTFS, case-insensitive) users all
    // the same; only this setup mechanism is Linux/macOS-only.
    #if !os(Windows)
        @Test("planChange folds casing so a case-only rename in a dropped folder still blocks")
        func planChangeFoldsCaseRename() async throws {
            let (dir, runner) = try await makeRepo("casefold")
            defer { try? FileManager.default.removeItem(at: dir) }
            // Model a case-insensitive filesystem (macOS/Windows default):
            // a case-only rename makes `git status` report the on-disk
            // dirent casing ("Beta/…") while `ls-tree` keeps the index
            // casing ("beta") — a case-sensitive guard would miss it.
            _ = try await runner.run(["config", "core.ignorecase", "true"])
            _ = try await runner.run(["mv", "beta", "Beta"])

            let plan = try await SparseCheckout(runner: runner).planChange(to: ["alpha", "gamma"])
            #expect(plan.blockedDrops.map(\.name) == ["beta"])
            #expect(plan.blockedDrops.first?.reasons.contains(.stagedChange) == true)
        }
    #endif

    @Test("planChange ignores dirt in a folder that is kept or added (only drops matter)")
    func planChangeIgnoresKeptDirt() async throws {
        let (dir, runner) = try await makeRepo("plan-kept-dirt")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Dirty alpha, but alpha is KEPT — so it must not block.
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("alpha/file.txt"))

        let plan = try await SparseCheckout(runner: runner).planChange(to: ["alpha"])
        #expect(plan.blockedDrops.isEmpty)
        #expect(plan.drops == ["beta", "gamma"])
    }

    // MARK: - forciblyClearDirectories

    @Test("forciblyClearDirectories reverts tracked edits and removes untracked files")
    func forciblyClearsAFolder() async throws {
        let (dir, runner) = try await makeRepo("force-clear")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited\n".utf8).write(to: dir.appendingPathComponent("beta/file.txt"))
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("beta/note.txt"))

        try await SparseCheckout(runner: runner).forciblyClearDirectories(["beta"])

        // beta is back to pristine HEAD: tracked edit reverted, untracked gone.
        let content = try String(contentsOf: dir.appendingPathComponent("beta/file.txt"), encoding: .utf8)
        #expect(content == "beta\n")
        #expect(!exists(dir, "beta/note.txt"))
        // Nothing under beta is dirty anymore.
        let status = try await runner.run(["status", "--porcelain", "-z", "--", "beta"])
        #expect(status.stdout.isEmpty)
    }
}
