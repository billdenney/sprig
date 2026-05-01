import Foundation
@testable import GitCore
import Testing

@Suite("GitMetadataPaths.submoduleWorktrees")
struct SubmoduleWorktreesTests {
    /// Build a parent repo with a single-level submodule pointing at a
    /// helper repo. Returns the parent worktree URL.
    ///
    /// Uses real git so we exercise the actual `submodule status
    /// --recursive` output format.
    private func mkParentWithSubmodule(
        nested: Bool = false
    ) async throws -> (parent: URL, helper: URL) {
        let helper = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-helper-\(UUID().uuidString)")
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let helperRunner = Runner(defaultWorkingDirectory: helper)
        _ = try await helperRunner.run(["init", "-b", "main"])
        _ = try await helperRunner.run(["config", "user.email", "h@test"])
        _ = try await helperRunner.run(["config", "user.name", "Helper"])
        _ = try await helperRunner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: helper.appendingPathComponent("h.txt"))
        _ = try await helperRunner.run(["add", "h.txt"])
        _ = try await helperRunner.run(["commit", "-m", "seed"])

        if nested {
            // Add ANOTHER helper as a submodule of the first helper.
            let nestedHelper = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sprig-gmd-nested-helper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: nestedHelper, withIntermediateDirectories: true)
            let nestedRunner = Runner(defaultWorkingDirectory: nestedHelper)
            _ = try await nestedRunner.run(["init", "-b", "main"])
            _ = try await nestedRunner.run(["config", "user.email", "nh@test"])
            _ = try await nestedRunner.run(["config", "user.name", "NestedHelper"])
            _ = try await nestedRunner.run(["config", "commit.gpgsign", "false"])
            try Data("nested seed\n".utf8).write(to: nestedHelper.appendingPathComponent("n.txt"))
            _ = try await nestedRunner.run(["add", "n.txt"])
            _ = try await nestedRunner.run(["commit", "-m", "nested seed"])

            // Add nestedHelper as a submodule of helper.
            _ = try await helperRunner.run([
                "-c", "protocol.file.allow=always",
                "submodule", "add", nestedHelper.path, "deeper"
            ])
            _ = try await helperRunner.run(["commit", "-m", "add deeper submodule"])
        }

        let parentRunner = Runner(defaultWorkingDirectory: parent)
        _ = try await parentRunner.run(["init", "-b", "main"])
        _ = try await parentRunner.run(["config", "user.email", "p@test"])
        _ = try await parentRunner.run(["config", "user.name", "Parent"])
        _ = try await parentRunner.run(["config", "commit.gpgsign", "false"])
        try Data("p seed\n".utf8).write(to: parent.appendingPathComponent("p.txt"))
        _ = try await parentRunner.run(["add", "p.txt"])
        _ = try await parentRunner.run(["commit", "-m", "parent seed"])

        // Add helper as a submodule of parent (with --recursive
        // initialization so nested ones come along).
        _ = try await parentRunner.run([
            "-c", "protocol.file.allow=always",
            "submodule", "add", helper.path, "sub"
        ])
        _ = try await parentRunner.run([
            "-c", "protocol.file.allow=always",
            "submodule", "update", "--init", "--recursive"
        ])
        _ = try await parentRunner.run(["commit", "-m", "add sub"])

        return (parent.standardized, helper.standardized)
    }

    @Test("repo with no submodules returns empty array")
    func noSubmodulesReturnsEmpty() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = Runner(defaultWorkingDirectory: dir)
        _ = try await r.run(["init", "-b", "main"])
        _ = try await r.run(["config", "user.email", "x@test"])
        _ = try await r.run(["config", "user.name", "X"])
        _ = try await r.run(["config", "commit.gpgsign", "false"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))
        _ = try await r.run(["add", "x.txt"])
        _ = try await r.run(["commit", "-m", "x"])

        let result = try await GitMetadataPaths.submoduleWorktrees(at: dir)
        #expect(result.isEmpty)
    }

    @Test("single-level submodule is discovered with absolute URL")
    func singleSubmoduleDiscovered() async throws {
        let (parent, helper) = try await mkParentWithSubmodule()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: helper)
        }
        let result = try await GitMetadataPaths.submoduleWorktrees(at: parent)
        #expect(result.count == 1)
        #expect(result.first == parent.appendingPathComponent("sub").standardized)
    }

    @Test("nested submodules are discovered (recursive walk)")
    func nestedSubmodulesDiscovered() async throws {
        let (parent, helper) = try await mkParentWithSubmodule(nested: true)
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: helper)
        }
        let result = try await GitMetadataPaths.submoduleWorktrees(at: parent)
        // Expected: parent/sub (the helper), parent/sub/deeper (the
        // nested helper).
        #expect(result.count == 2)
        #expect(result.contains(parent.appendingPathComponent("sub").standardized))
        #expect(result.contains(parent.appendingPathComponent("sub/deeper").standardized))
    }
}
