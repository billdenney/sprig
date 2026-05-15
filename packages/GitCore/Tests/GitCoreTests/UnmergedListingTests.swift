// UnmergedListingTests.swift
//
// Pure-parser + real-git integration tests for UnmergedListing.

import Foundation
@testable import GitCore
import Testing

@Suite("UnmergedListing — parser + real-git")
struct UnmergedListingTests {
    // MARK: - Pure-parser tests

    private func makeRecord(mode: String, sha: String, stage: Int, path: String) -> Data {
        var data = Data()
        data.append(Data(mode.utf8))
        data.append(0x20) // SP
        data.append(Data(sha.utf8))
        data.append(0x20)
        data.append(Data("\(stage)".utf8))
        data.append(0x09) // TAB
        data.append(Data(path.utf8))
        data.append(0x00) // NUL
        return data
    }

    @Test("parse returns [] for empty input")
    func parseEmpty() throws {
        let entries = try UnmergedListing.parse(Data())
        #expect(entries.isEmpty)
    }

    @Test("parse groups 3 stages of one path into one UnmergedEntry")
    func parseThreeStagesOnePath() throws {
        let shaA = String(repeating: "a", count: 40)
        let shaB = String(repeating: "b", count: 40)
        let shaC = String(repeating: "c", count: 40)
        var data = Data()
        data.append(makeRecord(mode: "100644", sha: shaA, stage: 1, path: "x.txt"))
        data.append(makeRecord(mode: "100644", sha: shaB, stage: 2, path: "x.txt"))
        data.append(makeRecord(mode: "100644", sha: shaC, stage: 3, path: "x.txt"))

        let entries = try UnmergedListing.parse(data)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.path == "x.txt")
        #expect(entry.stages.count == 3)
        #expect(entry.baseStage?.sha == shaA)
        #expect(entry.oursStage?.sha == shaB)
        #expect(entry.theirsStage?.sha == shaC)
        #expect(entry.isAddAdd == false)
        #expect(entry.hasSubmoduleStage == false)
    }

    @Test("parse detects add/add (only stages 2 + 3, no stage 1)")
    func parseAddAdd() throws {
        var data = Data()
        let sha = String(repeating: "a", count: 40)
        data.append(makeRecord(mode: "100644", sha: sha, stage: 2, path: "new.txt"))
        data.append(makeRecord(mode: "100644", sha: sha, stage: 3, path: "new.txt"))

        let entries = try UnmergedListing.parse(data)
        let entry = try #require(entries.first)
        #expect(entry.isAddAdd)
        #expect(entry.baseStage == nil)
    }

    @Test("parse detects submodule mode 160000 in any stage")
    func parseSubmodule() throws {
        let sha = String(repeating: "f", count: 40)
        var data = Data()
        data.append(makeRecord(mode: "160000", sha: sha, stage: 2, path: "sub"))
        data.append(makeRecord(mode: "160000", sha: sha, stage: 3, path: "sub"))

        let entries = try UnmergedListing.parse(data)
        let entry = try #require(entries.first)
        #expect(entry.hasSubmoduleStage)
        #expect(entry.oursStage?.mode == .submodule)
    }

    @Test("parse preserves path emission order")
    func parsePreservesOrder() throws {
        let sha = String(repeating: "1", count: 40)
        var data = Data()
        data.append(makeRecord(mode: "100644", sha: sha, stage: 2, path: "b.txt"))
        data.append(makeRecord(mode: "100644", sha: sha, stage: 3, path: "b.txt"))
        data.append(makeRecord(mode: "100644", sha: sha, stage: 2, path: "a.txt"))
        data.append(makeRecord(mode: "100644", sha: sha, stage: 3, path: "a.txt"))

        let entries = try UnmergedListing.parse(data)
        #expect(entries.map(\.path) == ["b.txt", "a.txt"], "input order, not sorted")
    }

    @Test("parse throws on malformed records")
    func parseMalformed() {
        var data = Data()
        // Missing the tab + path part.
        data.append(Data("100644 abc 2".utf8))
        data.append(0x00)
        #expect(throws: GitError.self) {
            try UnmergedListing.parse(data)
        }
    }

    @Test("parse throws on non-octal mode")
    func parseInvalidMode() {
        let sha = String(repeating: "a", count: 40)
        var data = Data()
        data.append(Data("99999z \(sha) 2\tx.txt".utf8))
        data.append(0x00)
        #expect(throws: GitError.self) {
            try UnmergedListing.parse(data)
        }
    }

    @Test("parse throws on stage outside 1...3")
    func parseInvalidStage() {
        let sha = String(repeating: "a", count: 40)
        var data = Data()
        data.append(Data("100644 \(sha) 4\tx.txt".utf8))
        data.append(0x00)
        #expect(throws: GitError.self) {
            try UnmergedListing.parse(data)
        }
    }

    // MARK: - GitFileMode

    @Test("GitFileMode round-trips raw octal values")
    func fileModeRoundTrip() {
        #expect(GitFileMode(rawMode: 0o100644) == .regularFile)
        #expect(GitFileMode(rawMode: 0o100755) == .executable)
        #expect(GitFileMode(rawMode: 0o120000) == .symlink)
        #expect(GitFileMode(rawMode: 0o160000) == .submodule)
        #expect(GitFileMode(rawMode: 0o100664) == .unknown(0o100664))

        #expect(GitFileMode.regularFile.rawMode == 0o100644)
        #expect(GitFileMode.executable.rawMode == 0o100755)
        #expect(GitFileMode.symlink.rawMode == 0o120000)
        #expect(GitFileMode.submodule.rawMode == 0o160000)
        #expect(GitFileMode.unknown(0o100664).rawMode == 0o100664)
    }

    // MARK: - Integration

    @Test("end-to-end: git ls-files -u -z on a real text conflict")
    func integrationTextConflict() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-unmerged-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        _ = try await runner.run(["checkout", "-b", "feature-a"])
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feature-a"])
        _ = try await runner.run(["checkout", "main"])
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "on-main"])
        _ = try await runner.run(["merge", "feature-a"], throwOnNonZero: false)

        let output = try await runner.run(["ls-files", "-u", "-z"])
        let entries = try UnmergedListing.parse(output.stdout)

        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.path == "a.txt")
        #expect(entry.stages.count == 3, "3-way conflict has all three stages")
        #expect(entry.baseStage != nil)
        #expect(entry.oursStage != nil)
        #expect(entry.theirsStage != nil)
        #expect(entry.isAddAdd == false)
        #expect(entry.hasSubmoduleStage == false)
    }
}
