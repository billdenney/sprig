// FileHistoryTests.swift
//
// ADR 0090 — per-file `git log --follow` history + blob reads, against
// real git (never mocked). The load-bearing claims: the lineage follows
// a rename, each revision records the file's path AS IT WAS at that
// commit, and a blob read at that historical path returns the right
// bytes.

import Foundation
@testable import GitCore
import Testing

@Suite("FileHistory — log --follow + blob reads (real git)", .serialized)
struct FileHistoryTests {
    /// Seed a repo where `file.txt` gains two versions, is renamed to
    /// `renamed.txt`, then gains a third — so history spans a rename.
    private func makeRenamedHistory(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-filehist-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        _ = try await runner.run(["add", "file.txt"])
        _ = try await runner.run(["commit", "-m", "c1"])
        try Data("v1\nv2\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        _ = try await runner.run(["commit", "-am", "c2"])
        _ = try await runner.run(["mv", "file.txt", "renamed.txt"])
        _ = try await runner.run(["commit", "-m", "c3-rename"])
        try Data("v1\nv2\nv3\n".utf8).write(to: dir.appendingPathComponent("renamed.txt"))
        _ = try await runner.run(["commit", "-am", "c4"])
        return (dir, runner)
    }

    @Test("revisions lists newest-first, follows the rename, records the path at each commit")
    func revisionsFollowRename() async throws {
        let (dir, runner) = try await makeRenamedHistory("revs")
        defer { try? FileManager.default.removeItem(at: dir) }

        let revisions = try await FileHistory(runner: runner).revisions(of: "renamed.txt")
        #expect(revisions.map(\.subject) == ["c4", "c3-rename", "c2", "c1"])
        // Path at each commit: the new name from c3 onward, the old name before.
        #expect(revisions.map(\.pathAtRevision) == ["renamed.txt", "renamed.txt", "file.txt", "file.txt"])
        #expect(revisions.allSatisfy { $0.author == "Sprig Test" })
        #expect(revisions[0].commitSHA.count == 40)
    }

    @Test("contents reads each revision's blob at its historical path")
    func contentsReadsHistoricalBlob() async throws {
        let (dir, runner) = try await makeRenamedHistory("contents")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = FileHistory(runner: runner)
        let revisions = try await history.revisions(of: "renamed.txt")
        let catFile = try await CatFileBatch(repoURL: dir)

        let newest = try await history.contents(of: revisions[0], using: catFile)
        let preRename = try await history.contents(of: revisions[2], using: catFile) // c2, was file.txt
        let oldest = try await history.contents(of: revisions[3], using: catFile) // c1, was file.txt
        await catFile.close()

        #expect(String(data: newest, encoding: .utf8) == "v1\nv2\nv3\n")
        #expect(String(data: preRename, encoding: .utf8) == "v1\nv2\n")
        #expect(String(data: oldest, encoding: .utf8) == "v1\n")
    }

    @Test("revisions is empty for a path with no tracked history")
    func revisionsEmptyForUnknownPath() async throws {
        let (dir, runner) = try await makeRenamedHistory("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let revisions = try await FileHistory(runner: runner).revisions(of: "never-existed.txt")
        #expect(revisions.isEmpty)
    }

    @Test("non-ASCII filenames round-trip — -z emits raw, unquoted paths")
    func nonASCIIFilename() async throws {
        let (dir, runner) = try await makeRenamedHistory("nonascii-base")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Add an accented file with two versions in the same repo.
        try Data("uno\n".utf8).write(to: dir.appendingPathComponent("café.txt"))
        _ = try await runner.run(["add", "café.txt"])
        _ = try await runner.run(["commit", "-m", "c-accent-1"])
        try Data("uno\ndos\n".utf8).write(to: dir.appendingPathComponent("café.txt"))
        _ = try await runner.run(["commit", "-am", "c-accent-2"])

        let history = FileHistory(runner: runner)
        let revisions = try await history.revisions(of: "café.txt")
        #expect(revisions.count == 2)
        #expect(revisions.allSatisfy { $0.pathAtRevision == "café.txt" })
        // The blob read (sha:café.txt) must succeed — it would fail if the
        // path came back C-quoted.
        let catFile = try await CatFileBatch(repoURL: dir)
        let oldest = try await history.contents(of: revisions[1], using: catFile)
        await catFile.close()
        #expect(String(data: oldest, encoding: .utf8) == "uno\n")
    }

    @Test("parse extracts header fields and the new-name path for a rename (-z stream)")
    func parseUnit() {
        let rs = "\u{1e}"
        let us = "\u{1f}"
        let nul = "\u{0}"
        let text =
            "\(rs)abc123\(us)Alice\(us)2026-01-01T00:00:00Z\(us)did a thing\(nul)M\(nul)src/file.txt\(nul)"
                + "\(rs)def456\(us)Bob\(us)2026-01-02T00:00:00Z\(us)moved it\(nul)R100\(nul)old.txt\(nul)src/file.txt\(nul)"
        let revisions = FileHistory.parse(text, queriedPath: "src/file.txt")
        #expect(revisions.count == 2)
        #expect(revisions[0].commitSHA == "abc123")
        #expect(revisions[0].author == "Alice")
        #expect(revisions[0].subject == "did a thing")
        #expect(revisions[0].pathAtRevision == "src/file.txt")
        // Rename: the path at THIS commit is the new (last) name.
        #expect(revisions[1].pathAtRevision == "src/file.txt")
        #expect(revisions[1].author == "Bob")
    }
}
