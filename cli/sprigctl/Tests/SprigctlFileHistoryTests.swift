// SprigctlFileHistoryTests.swift
//
// `sprigctl file-history` end-to-end CLI tests (ADR 0090). Own file to
// keep SwiftLint's file_length / type_body_length caps happy. The CLI is
// the headless face of File History: list versions, and `--restore <sha>`
// to bring one back (saving a backup first).

import Foundation
import Testing

@Suite("sprigctl file-history", .serialized)
struct SprigctlFileHistoryTests {
    private func seedRepo(_ label: String) async throws -> URL {
        let repo = try Sprigctl.mkRepo(label)
        try await Sprigctl.initRepo(at: repo)
        try await Sprigctl.spawnGit(["config", "core.autocrlf", "false"], cwd: repo)
        try Sprigctl.write("v1\n", to: repo.appendingPathComponent("file.txt"))
        try await Sprigctl.spawnGit(["add", "file.txt"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "c1"], cwd: repo)
        try Sprigctl.write("v1\nv2\n", to: repo.appendingPathComponent("file.txt"))
        try await Sprigctl.spawnGit(["commit", "-am", "c2"], cwd: repo)
        return repo
    }

    private func lines(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateLines { line, _ in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
        }
        return out
    }

    @Test("file-history lists every version, newest first")
    func listsVersions() async throws {
        let repo = try await seedRepo("list")
        defer { try? FileManager.default.removeItem(at: repo) }
        let out = try await Sprigctl.run(["file-history", "file.txt", "--repo", repo.path])
        #expect(out.exitCode == 0)
        let rows = lines(out.stdout)
        #expect(rows.count == 2)
        #expect(rows.first?.contains("c2") == true) // newest first
        #expect(rows.last?.contains("c1") == true)
    }

    @Test("file-history --restore brings an old version back and saves a backup")
    func restoresOldVersion() async throws {
        let repo = try await seedRepo("restore")
        defer { try? FileManager.default.removeItem(at: repo) }
        let list = try await Sprigctl.run(["file-history", "file.txt", "--repo", repo.path])
        let oldestSHA = try #require(lines(list.stdout).last?.split(separator: " ").first.map(String.init))

        let out = try await Sprigctl.run(
            ["file-history", "file.txt", "--restore", oldestSHA, "--repo", repo.path]
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Saved a copy"))
        let onDisk = try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(onDisk == "v1\n")
    }

    @Test("file-history --restore with an ambiguous prefix is refused, not silently resolved")
    func restoreAmbiguousRefused() async throws {
        let repo = try Sprigctl.mkRepo("ambiguous")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.initRepo(at: repo)
        try await Sprigctl.spawnGit(["config", "core.autocrlf", "false"], cwd: repo)
        // >16 commits to one file → by pigeonhole, two full SHAs share a
        // first hex char, giving a deterministic, portable (non-empty)
        // ambiguous 1-char prefix. (Empty-string args are dropped on
        // Windows, so we can't use "" to match-all.)
        for index in 0 ..< 24 {
            try Sprigctl.write("v\(index)\n", to: repo.appendingPathComponent("file.txt"))
            try await Sprigctl.spawnGit(["add", "file.txt"], cwd: repo)
            try await Sprigctl.spawnGit(["commit", "-m", "c\(index)"], cwd: repo)
        }

        let list = try await Sprigctl.run(["file-history", "file.txt", "--repo", repo.path])
        let firstChars = lines(list.stdout).compactMap { $0.first }
        var counts: [Character: Int] = [:]
        for char in firstChars { counts[char, default: 0] += 1 }
        let ambiguous = try #require(counts.first { $0.value >= 2 }?.key)

        let out = try await Sprigctl.run(
            ["file-history", "file.txt", "--restore", String(ambiguous), "--repo", repo.path]
        )
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("ambiguous"))
    }

    @Test("file-history on an untracked path exits non-zero")
    func noHistory() async throws {
        let repo = try await seedRepo("nohistory")
        defer { try? FileManager.default.removeItem(at: repo) }
        let out = try await Sprigctl.run(["file-history", "ghost.txt", "--repo", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("no tracked history"))
    }
}
