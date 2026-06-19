// ExternalDiffToolTests.swift
//
// ADR 0086 C0 / ADR 0027 — the git difftool/mergetool external-tool
// fallback: argv builders (unit) + a real `git difftool` run with a
// configured no-op tool.

import Foundation
@testable import GitCore
import Testing

@Suite("ExternalDiffTool — git difftool/mergetool fallback", .serialized)
struct ExternalDiffToolTests {
    @Test("argv builders: --no-prompt, optional --tool, path after --")
    func argvBuilders() {
        #expect(
            ExternalDiffTool.diffArguments(path: "a.txt", tool: nil)
                == ["difftool", "--no-prompt", "--", "a.txt"]
        )
        #expect(
            ExternalDiffTool.diffArguments(path: "a.txt", tool: "vimdiff")
                == ["difftool", "--no-prompt", "--tool", "vimdiff", "--", "a.txt"]
        )
        #expect(
            ExternalDiffTool.mergeArguments(path: "a.txt", tool: "meld")
                == ["mergetool", "--no-prompt", "--tool", "meld", "--", "a.txt"]
        )
    }

    @Test("launchDiff runs the configured tool through git")
    func launchDiffRunsTool() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-difftool-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // A no-op "tool" that just records that it ran (git runs the cmd
        // via its bundled sh on every platform).
        _ = try await runner.run(["config", "difftool.noop.cmd", "echo ran > tool-ran.txt"])
        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        _ = try await runner.run(["add", "file.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        // Dirty the file so difftool has something to open.
        try Data("v2\n".utf8).write(to: dir.appendingPathComponent("file.txt"))

        try await ExternalDiffTool.launchDiff(path: "file.txt", tool: "noop", runner: runner)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tool-ran.txt").path))
    }

    @Test("launchMerge is a no-op (exit 0) when there is nothing to merge")
    func launchMergeNoConflicts() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-mergetool-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        _ = try await runner.run(["add", "file.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])

        // No conflict in the tree → git mergetool reports nothing to do
        // and exits 0; the launch must not throw.
        try await ExternalDiffTool.launchMerge(path: "file.txt", tool: "noop", runner: runner)
    }
}
