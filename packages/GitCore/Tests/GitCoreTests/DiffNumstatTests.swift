// DiffNumstatTests.swift
//
// ADR 0086 C0 — `git diff --numstat -z` parse (rename three-token shape
// + the `-`/`-` binary marker), unit + against real git.

import Foundation
@testable import GitCore
import Testing

@Suite("DiffNumstat — numstat -z parse + real git", .serialized)
struct DiffNumstatTests {
    @Test("parse handles text counts, the binary marker, and a rename")
    func parseUnit() {
        let nul = "\u{0}"
        let stream =
            "2\t1\ttext.txt\(nul)"
                + "-\t-\timage.png\(nul)"
                + "0\t0\t\(nul)old.txt\(nul)new.txt\(nul)"
                + "1\t0\tadded.txt\(nul)"
        let entries = DiffNumstat.parse(Data(stream.utf8))
        #expect(entries.count == 4)
        #expect(entries[0] == NumstatEntry(path: "text.txt", oldPath: nil, added: 2, deleted: 1))
        #expect(entries[1].isBinary)
        #expect(entries[1].added == nil && entries[1].deleted == nil)
        #expect(entries[2].path == "new.txt")
        #expect(entries[2].oldPath == "old.txt")
        #expect(entries[3].path == "added.txt")
    }

    @Test("a path containing a TAB survives (-z paths are raw, not quoted)")
    func parseTabbedPath() {
        let nul = "\u{0}"
        // git -z emits the literal TAB inside the path (no C-quoting), so
        // the path is everything after the second TAB.
        let stream = "2\t0\tdir/file\ttab.txt\(nul)1\t1\tplain.txt\(nul)"
        let entries = DiffNumstat.parse(Data(stream.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].path == "dir/file\ttab.txt")
        #expect(entries[0].added == 2)
        #expect(entries[1].path == "plain.txt")
    }

    @Test("entries against real git: text + binary marker + rename")
    func realGit() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-numstat-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("a\nb\n".utf8).write(to: dir.appendingPathComponent("text.txt"))
        // A NUL byte makes git treat the file as binary (→ `-`/`-`).
        try Data([0x00, 0x01, 0x02]).write(to: dir.appendingPathComponent("blob.bin"))
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("torename.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])
        try Data("a\nb\nc\n".utf8).write(to: dir.appendingPathComponent("text.txt"))
        try Data([0x00, 0x09, 0x09]).write(to: dir.appendingPathComponent("blob.bin"))
        _ = try await runner.run(["mv", "torename.txt", "renamed.txt"])
        _ = try await runner.run(["add", "-A"])

        let entries = try await DiffNumstat.entries(runner: runner, baseArguments: ["diff", "--cached"])
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        #expect(byPath["text.txt"]?.added == 1)
        #expect(byPath["blob.bin"]?.isBinary == true)
        #expect(byPath["renamed.txt"]?.oldPath == "torename.txt")
    }
}
