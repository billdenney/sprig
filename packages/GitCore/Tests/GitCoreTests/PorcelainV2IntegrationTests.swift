import Foundation
@testable import GitCore
import Testing

/// End-to-end parser tests: spawn real git against a temp repo in various
/// states and parse the actual `-z` output. Catches format-drift that
/// synthesized fixtures can't.
@Suite("PorcelainV2Parser — against real git")
struct PorcelainV2IntegrationTests {
    // MARK: helpers

    private func runner(at url: URL) -> Runner {
        Runner(defaultWorkingDirectory: url)
    }

    private func mkRepo(_ test: String) throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-porcelain-\(test)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let r = runner(at: tmp)
        return (tmp, r)
    }

    private func initRepo(_ r: Runner) async throws {
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "test@sprig.app"])
        _ = try await r.run(["config", "user.name", "Sprig Test"])
        // Stabilize output regardless of host config.
        _ = try await r.run(["config", "commit.gpgsign", "false"])
    }

    private func parseStatus(_ r: Runner) async throws -> PorcelainV2Status {
        let output = try await r.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        return try PorcelainV2Parser.parse(output.stdout)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    // MARK: tests

    @Test("clean repo after initial commit: branch headers present, no entries")
    func cleanRepoAfterInitialCommitBranchHeadersPresentNoEntries() async throws {
        let (tmp, r) = try mkRepo("clean")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("# hi\n", to: tmp.appendingPathComponent("README.md"))
        _ = try await r.run(["add", "README.md"])
        _ = try await r.run(["commit", "-m", "initial"])

        let status = try await parseStatus(r)
        #expect(status.branch?.head == "main")
        #expect(status.branch?.oid != nil)
        #expect(status.entries.isEmpty)
    }

    @Test("fresh repo with untracked file surfaces as untracked entry")
    func freshRepoWithUntrackedFileSurfacesAsUntrackedEntry() async throws {
        let (tmp, r) = try mkRepo("untracked")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("hello\n", to: tmp.appendingPathComponent("hello.txt"))

        let status = try await parseStatus(r)
        // No commits yet → head="main", oid=nil (initial).
        #expect(status.branch?.head == "main")
        #expect(status.branch?.oid == nil)
        #expect(status.entries == [.untracked(path: "hello.txt")])
    }

    @Test("modified tracked file surfaces as ordinary entry with .M status")
    func modifiedTrackedFileSurfacesAsOrdinaryEntryWithMStatus() async throws {
        let (tmp, r) = try mkRepo("modified")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        let file = tmp.appendingPathComponent("a.txt")
        try write("one\n", to: file)
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "add a"])
        try write("one\ntwo\n", to: file)

        let status = try await parseStatus(r)
        let ordinary = status.entries.compactMap { entry -> Ordinary? in
            if case let .ordinary(e) = entry { return e } else { return nil }
        }
        #expect(ordinary.count == 1)
        #expect(ordinary.first?.xy.index == .unmodified)
        #expect(ordinary.first?.xy.worktree == .modified)
        #expect(ordinary.first?.path == "a.txt")
    }

    @Test("staged new file surfaces as ordinary entry with A. status")
    func stagedNewFileSurfacesAsOrdinaryEntryWithAStatus() async throws {
        let (tmp, r) = try mkRepo("added")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("seed\n", to: tmp.appendingPathComponent("seed.txt"))
        _ = try await r.run(["add", "seed.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("new\n", to: tmp.appendingPathComponent("new.txt"))
        _ = try await r.run(["add", "new.txt"])

        let status = try await parseStatus(r)
        let ordinary = status.entries.compactMap { entry -> Ordinary? in
            if case let .ordinary(e) = entry { return e } else { return nil }
        }
        #expect(ordinary.first?.xy.index == .added)
        #expect(ordinary.first?.xy.worktree == .unmodified)
        #expect(ordinary.first?.path == "new.txt")
    }

    @Test("rename detected and parsed with both paths")
    func renameDetectedAndParsedWithBothPaths() async throws {
        let (tmp, r) = try mkRepo("renamed")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("body line 1\nbody line 2\nbody line 3\n", to: tmp.appendingPathComponent("old.txt"))
        _ = try await r.run(["add", "old.txt"])
        _ = try await r.run(["commit", "-m", "add old"])
        _ = try await r.run(["mv", "old.txt", "new.txt"])

        let status = try await parseStatus(r)
        let renames = status.entries.compactMap { entry -> Renamed? in
            if case let .renamed(e) = entry { return e } else { return nil }
        }
        #expect(renames.count == 1)
        #expect(renames.first?.path == "new.txt")
        #expect(renames.first?.origPath == "old.txt")
        #expect(renames.first?.op == .renamed)
    }

    @Test("merge conflict produces an unmerged entry")
    func mergeConflictProducesAnUnmergedEntry() async throws {
        let (tmp, r) = try mkRepo("conflict")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)

        let file = tmp.appendingPathComponent("c.txt")
        try write("base\n", to: file)
        _ = try await r.run(["add", "c.txt"])
        _ = try await r.run(["commit", "-m", "base"])

        _ = try await r.run(["checkout", "-b", "feature"])
        try write("feature change\n", to: file)
        _ = try await r.run(["commit", "-am", "feature change"])

        _ = try await r.run(["checkout", "main"])
        try write("main change\n", to: file)
        _ = try await r.run(["commit", "-am", "main change"])

        // Expected to fail with a conflict; we don't throw on non-zero for merge.
        _ = try await r.run(["merge", "feature"], throwOnNonZero: false)

        let status = try await parseStatus(r)
        let unmerged = status.entries.compactMap { entry -> Unmerged? in
            if case let .unmerged(e) = entry { return e } else { return nil }
        }
        #expect(unmerged.count == 1)
        #expect(unmerged.first?.path == "c.txt")
        // `UU` (updated-updated) is the typical both-modified conflict.
        #expect(unmerged.first?.xy.index == .updatedUnmerged)
        #expect(unmerged.first?.xy.worktree == .updatedUnmerged)
    }

    @Test("path with spaces survives round-trip through real git")
    func pathWithSpacesSurvivesRoundTripThroughRealGit() async throws {
        let (tmp, r) = try mkRepo("spacey-path")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write(
            "notes\n",
            to: tmp.appendingPathComponent("my notes.md")
        )

        let status = try await parseStatus(r)
        #expect(status.entries == [.untracked(path: "my notes.md")])
    }

    @Test("stash header reflects stash count")
    func stashHeaderReflectsStashCount() async throws {
        let (tmp, r) = try mkRepo("stash")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await initRepo(r)
        try write("seed\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["add", "a.txt"])
        _ = try await r.run(["commit", "-m", "seed"])
        try write("dirty\n", to: tmp.appendingPathComponent("a.txt"))
        _ = try await r.run(["stash", "push", "-m", "wip"])

        let status = try await parseStatus(r)
        #expect(status.stashCount == 1)
    }
}
