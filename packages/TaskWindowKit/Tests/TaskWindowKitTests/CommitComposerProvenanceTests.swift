// CommitComposerProvenanceTests.swift
//
// ADR 0088 prerequisite — a real Sprig commit through CommitComposer must
// be recorded as Sprig-authored, so the agent-review surface won't later
// flag the user's own GUI commit as an external change.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("CommitComposerViewModel — provenance (ADR 0088)", .serialized)
struct CommitComposerProvenanceTests {
    @Test("committing through the composer records the new SHA as Sprig-authored")
    func commitRecordsProvenance() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-cc-prov-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"])

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.setMessage(CommitMessage(subject: "first"))
        await vm.commit()

        let head = try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(await vm.state.successValue == head)
        // The composer's commit is Sprig-authored; an unrelated SHA is not.
        let prov = OperationProvenance(runner: runner)
        #expect(try await prov.authoredCommits().contains(head))
        #expect(try await prov.externalCommits(among: [head]).isEmpty)
        #expect(try await prov.externalCommits(among: [String(repeating: "0", count: 40)]).count == 1)
    }
}
