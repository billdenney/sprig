// CommitComposerRegionStagingTests.swift
//
// ADR 0061 — region staging through CommitComposerViewModel. Real git:
// modify a file, fetch `git diff`, drag-select a sub-range, stage it,
// and assert the index byte-exactly (split from the main composer suite
// to keep each struct under the type-body length limit).

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("CommitComposerViewModel — region staging (ADR 0061)", .serialized)
struct CommitComposerRegionStagingTests {
    private func makeRepoWithModifiedFile() async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-region-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("line1\nline2\nline3\nline4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nCHANGED2\nline3\nCHANGED4\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("stageSelection stages only the selected lines, index byte-exact")
    func regionStagingStagesSelection() async throws {
        let (dir, runner) = try await makeRepoWithModifiedFile()
        defer { cleanup(dir) }
        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        let diff = try await runner.run(["diff"]).stdoutString
        let lo = try #require(diff.range(of: "-line2\n")).lowerBound
        let hi = try #require(diff.range(of: "+CHANGED2\n")).upperBound

        await vm.stageSelection(in: diff, selection: lo ..< hi)

        // Only the line2 change reached the index; line4 did not.
        #expect(try await runner.run(["show", ":f.txt"]).stdoutString == "line1\nCHANGED2\nline3\nline4\n")
        await vm.refresh()
        #expect(await vm.staged.contains("f.txt"))
        #expect(await vm.unstaged.contains("f.txt")) // line4 change still pending
    }

    @Test("stageSelection on a change-free selection reports it and stages nothing")
    func regionStagingNoChange() async throws {
        let (dir, runner) = try await makeRepoWithModifiedFile()
        defer { cleanup(dir) }
        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        let diff = try await runner.run(["diff"]).stdoutString
        let context = try #require(diff.range(of: " line1\n")) // a context line only

        await vm.stageSelection(in: diff, selection: context)

        #expect(await vm.state.failure?.description == TaskWindowVocabulary.selectionHasNoChange)
        await vm.refresh()
        #expect(await vm.staged.isEmpty)
    }

    @Test("stageSelection refuses to split a no-newline end-of-file change")
    func regionStagingEofSplitRefused() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-region-eof-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("x".utf8).write(to: dir.appendingPathComponent("e.txt")) // no trailing newline
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("y".utf8).write(to: dir.appendingPathComponent("e.txt"))

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        let diff = try await runner.run(["diff"]).stdoutString
        let onlyAddition = try #require(diff.range(of: "+y\n")) // the +y line, not the -x

        await vm.stageSelection(in: diff, selection: onlyAddition)

        #expect(await vm.state.failure?.description == TaskWindowVocabulary.cannotSplitEndOfFile)
        await vm.refresh()
        #expect(await vm.staged.isEmpty)
    }
}
