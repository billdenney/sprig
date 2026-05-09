import Foundation
import GitCore
@testable import SubmoduleKit
import Testing

@Suite("SubmoduleStatus.fetch — real git fixtures")
struct SubmoduleStatusFetchTests {
    /// Result of ``mkParentWithSubmodule(nested:)`` — the URLs of
    /// the temporary repos so callers can clean them up.
    private struct Fixture {
        var parent: URL
        var helper: URL
        var nestedHelper: URL?
    }

    /// Build a parent repo with a single-level submodule pointing at
    /// a helper repo. When `nested: true`, the helper itself has a
    /// nested submodule — exercises `--recursive` output.
    ///
    /// Pattern cribbed from
    /// `GitCore.GitMetadataPaths.submoduleWorktrees` integration
    /// tests so the two surfaces share fixture-building habits.
    private func mkParentWithSubmodule(
        nested: Bool = false
    ) async throws -> Fixture {
        let helper = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-skit-helper-\(UUID().uuidString)")
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-skit-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let helperRunner = Runner(defaultWorkingDirectory: helper)
        try await initRepo(at: helper, identity: "h", runner: helperRunner)
        try Data("seed\n".utf8).write(to: helper.appendingPathComponent("h.txt"))
        _ = try await helperRunner.run(["add", "h.txt"])
        _ = try await helperRunner.run(["commit", "-m", "seed"])

        var nestedHelperURL: URL?
        if nested {
            let nestedHelper = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sprig-skit-nested-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: nestedHelper, withIntermediateDirectories: true)
            let nestedRunner = Runner(defaultWorkingDirectory: nestedHelper)
            try await initRepo(at: nestedHelper, identity: "nh", runner: nestedRunner)
            try Data("nested seed\n".utf8).write(to: nestedHelper.appendingPathComponent("n.txt"))
            _ = try await nestedRunner.run(["add", "n.txt"])
            _ = try await nestedRunner.run(["commit", "-m", "nested seed"])

            _ = try await helperRunner.run([
                "-c", "protocol.file.allow=always",
                "submodule", "add", nestedHelper.path, "deeper"
            ])
            _ = try await helperRunner.run(["commit", "-m", "add deeper submodule"])
            nestedHelperURL = nestedHelper
        }

        let parentRunner = Runner(defaultWorkingDirectory: parent)
        try await initRepo(at: parent, identity: "p", runner: parentRunner)
        try Data("p seed\n".utf8).write(to: parent.appendingPathComponent("p.txt"))
        _ = try await parentRunner.run(["add", "p.txt"])
        _ = try await parentRunner.run(["commit", "-m", "parent seed"])

        _ = try await parentRunner.run([
            "-c", "protocol.file.allow=always",
            "submodule", "add", helper.path, "sub"
        ])
        _ = try await parentRunner.run([
            "-c", "protocol.file.allow=always",
            "submodule", "update", "--init", "--recursive"
        ])
        _ = try await parentRunner.run(["commit", "-m", "add sub"])

        return Fixture(
            parent: parent.standardized,
            helper: helper.standardized,
            nestedHelper: nestedHelperURL?.standardized
        )
    }

    private func initRepo(at _: URL, identity: String, runner: Runner) async throws {
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "\(identity)@test"])
        _ = try await runner.run(["config", "user.name", identity])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
    }

    private func cleanup(_ urls: URL?...) {
        for case let url? in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Tests

    @Test("repo with no submodules returns empty list")
    func noSubmodulesEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-skit-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        try await initRepo(at: dir, identity: "x", runner: runner)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "x.txt"])
        _ = try await runner.run(["commit", "-m", "x"])

        let entries = try await SubmoduleStatus.fetch(at: dir, runner: runner)
        #expect(entries.isEmpty)
    }

    @Test("single-level submodule reports clean state")
    func singleSubmoduleClean() async throws {
        let fixture = try await mkParentWithSubmodule()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let entries = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.state == .clean)
        #expect(e.path == "sub")
        #expect(e.recordedSHA.count == 40 || e.recordedSHA.count == 64)
    }

    @Test("recursive: false skips nested entries by default")
    func recursiveFalseSkipsNested() async throws {
        let fixture = try await mkParentWithSubmodule(nested: true)
        defer { cleanup(fixture.parent, fixture.helper, fixture.nestedHelper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let entries = try await SubmoduleStatus.fetch(
            at: fixture.parent,
            runner: runner,
            recursive: false
        )
        #expect(entries.count == 1)
        #expect(entries.first?.path == "sub")
    }

    @Test("recursive: true flattens nested entries")
    func recursiveTrueFlattensNested() async throws {
        let fixture = try await mkParentWithSubmodule(nested: true)
        defer { cleanup(fixture.parent, fixture.helper, fixture.nestedHelper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let entries = try await SubmoduleStatus.fetch(
            at: fixture.parent,
            runner: runner,
            recursive: true
        )
        #expect(entries.count == 2)
        let paths = entries.map(\.path).sorted()
        #expect(paths == ["sub", "sub/deeper"])
        for entry in entries {
            #expect(entry.state == .clean)
        }
    }

    @Test("source: .recorded passes --cached and SHA matches recorded pointer")
    func cachedSourceMatchesRecorded() async throws {
        let fixture = try await mkParentWithSubmodule()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        // Compare against the SHA the parent records in its index for
        // `sub`. `git ls-tree HEAD sub` emits `<mode> commit <sha>\tsub`.
        let lsTree = try await runner.run(["ls-tree", "HEAD", "sub"])
        let lsTreeOut = try #require(String(bytes: lsTree.stdout, encoding: .utf8))
        let recordedSHA = try #require(
            lsTreeOut
                .split(separator: " ", omittingEmptySubsequences: true)
                .dropFirst(2)
                .first?
                .split(separator: "\t")
                .first
                .map(String.init)
        )

        let entries = try await SubmoduleStatus.fetch(
            at: fixture.parent,
            runner: runner,
            source: .recorded
        )
        #expect(entries.count == 1)
        #expect(entries.first?.recordedSHA == recordedSHA)
    }

    @Test("submodule with newer helper-side commit reports outOfDate")
    func outOfDateAfterHelperCommit() async throws {
        let fixture = try await mkParentWithSubmodule()
        defer { cleanup(fixture.parent, fixture.helper) }

        // Advance the submodule's checked-out HEAD by committing
        // inside `parent/sub/`. The super-repo's recorded pointer
        // doesn't change, so `git submodule status` reports `+`.
        //
        // `git submodule update --init` clones the helper into the
        // submodule with a fresh `.git/config`, so user.email/name
        // don't carry over from the helper's repo. Set them locally
        // on the submodule's worktree before committing — Windows CI
        // has no global git identity, so a missing local identity
        // fails the commit there.
        let subWorktree = fixture.parent.appendingPathComponent("sub")
        let subRunner = Runner(defaultWorkingDirectory: subWorktree)
        _ = try await subRunner.run(["config", "user.email", "sub@test"])
        _ = try await subRunner.run(["config", "user.name", "sub"])
        _ = try await subRunner.run(["config", "commit.gpgsign", "false"])
        try Data("update\n".utf8).write(to: subWorktree.appendingPathComponent("u.txt"))
        _ = try await subRunner.run(["add", "u.txt"])
        _ = try await subRunner.run(["commit", "-m", "u"])

        let parentRunner = Runner(defaultWorkingDirectory: fixture.parent)
        let entries = try await SubmoduleStatus.fetch(at: fixture.parent, runner: parentRunner)
        #expect(entries.count == 1)
        #expect(entries.first?.state == .outOfDate)
    }

    @Test("worktreeURLs returns empty for a repo with no submodules")
    func worktreeURLsEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-skit-wt-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        try await initRepo(at: dir, identity: "x", runner: runner)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "x.txt"])
        _ = try await runner.run(["commit", "-m", "x"])

        let urls = try await SubmoduleStatus.worktreeURLs(at: dir, runner: runner)
        #expect(urls.isEmpty)
    }

    @Test("worktreeURLs returns absolute URLs and recurses into nested submodules by default")
    func worktreeURLsRecursesByDefault() async throws {
        let fixture = try await mkParentWithSubmodule(nested: true)
        defer { cleanup(fixture.parent, fixture.helper, fixture.nestedHelper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let urls = try await SubmoduleStatus.worktreeURLs(at: fixture.parent, runner: runner)
        let sorted = urls.map(\.path).sorted()
        #expect(sorted.count == 2)
        #expect(sorted.contains(fixture.parent.appendingPathComponent("sub").standardized.path))
        #expect(sorted.contains(fixture.parent.appendingPathComponent("sub/deeper").standardized.path))
    }

    @Test("worktreeURLs with recursive: false stays at the top level")
    func worktreeURLsTopLevelOnly() async throws {
        let fixture = try await mkParentWithSubmodule(nested: true)
        defer { cleanup(fixture.parent, fixture.helper, fixture.nestedHelper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let urls = try await SubmoduleStatus.worktreeURLs(
            at: fixture.parent,
            runner: runner,
            recursive: false
        )
        #expect(urls.count == 1)
        #expect(urls.first == fixture.parent.appendingPathComponent("sub").standardized)
    }
}
