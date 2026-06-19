// FileHistoryViewModelTests.swift
//
// ADR 0090 against real git. The load-bearing claims: the VM lists a
// file's versions, shows a chosen version's bytes, and restore is
// fail-closed — it backs up the file's current bytes to a FileBackup ref
// first, so the restore comes back byte-for-byte through that ref (the
// undo round-trip the destructive-verb rule requires).

import Foundation
import GitCore
import SafetyKit
@testable import TaskWindowKit
import Testing

@Suite("FileHistoryViewModel — file history + restore (real git)", .serialized)
struct FileHistoryViewModelTests {
    /// `file.txt` with three committed versions; worktree at "v1v2v3".
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-filehistvm-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        for version in ["v1\n", "v1\nv2\n", "v1\nv2\nv3\n"] {
            try Data(version.utf8).write(to: dir.appendingPathComponent("file.txt"))
            _ = try await runner.run(["add", "file.txt"])
            _ = try await runner.run(["commit", "-m", "rev"])
        }
        return (dir, runner)
    }

    private func content(_ dir: URL, _ relative: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("loadHistory lists all versions newest first")
    func loadHistoryLists() async throws {
        let (dir, runner) = try await makeRepo("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = FileHistoryViewModel(repoURL: dir, filePath: "file.txt", runner: runner)

        await vm.loadHistory()
        #expect(await vm.state == .success(3))
        #expect(await vm.revisions.count == 3)
    }

    @Test("showVersion fetches the selected revision's bytes")
    func showVersionFetchesBytes() async throws {
        let (dir, runner) = try await makeRepo("show")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = FileHistoryViewModel(repoURL: dir, filePath: "file.txt", runner: runner)

        await vm.loadHistory()
        let oldest = try #require(await vm.revisions.last)
        await vm.showVersion(oldest)

        let payload = try #require(await vm.selectedContent)
        #expect(String(data: payload.content, encoding: .utf8) == "v1\n")
        #expect(payload.isBinary == false)
    }

    @Test("restore writes an old version and backs up current bytes for a byte-exact undo")
    func restoreRoundTrips() async throws {
        let (dir, runner) = try await makeRepo("restore-undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = FileHistoryViewModel(repoURL: dir, filePath: "file.txt", runner: runner)

        await vm.loadHistory()
        let oldest = try #require(await vm.revisions.last) // the "v1" version

        await vm.restore(oldest)
        #expect(try content(dir, "file.txt") == "v1\n")
        let safety = try #require(await vm.lastSafetyBackup)

        // Undo through the real FileBackup restore path: the current
        // ("v1v2v3") bytes come back byte-for-byte.
        _ = try await FileBackup(runner: runner).restore(safety.refName, to: "file.txt")
        #expect(try content(dir, "file.txt") == "v1\nv2\nv3\n")
    }

    @Test("restore recreates a file (and its parent dir) that was deleted at HEAD")
    func restoreRecreatesDeletedFile() async throws {
        let (dir, runner) = try await makeRepo("deleted")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub/deep"), withIntermediateDirectories: true
        )
        try Data("nested\n".utf8).write(to: dir.appendingPathComponent("sub/deep/x.txt"))
        _ = try await runner.run(["add", "sub/deep/x.txt"])
        _ = try await runner.run(["commit", "-m", "add nested"])
        _ = try await runner.run(["rm", "-r", "sub"])
        _ = try await runner.run(["commit", "-m", "remove nested"])

        let vm = FileHistoryViewModel(repoURL: dir, filePath: "sub/deep/x.txt", runner: runner)
        await vm.loadHistory()
        let addRevision = try #require(await vm.revisions.last) // the add commit
        await vm.restore(addRevision)

        #expect(await vm.state.successValue != nil)
        #expect(try content(dir, "sub/deep/x.txt") == "nested\n")
    }

    @Test("a binary version is flagged isBinary (preview deferred to ADR 0086)")
    func binaryVersionFlagged() async throws {
        let (dir, runner) = try await makeRepo("binary")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Commit a file with a NUL byte → git/Sprig treat it as binary.
        try Data([0x01, 0x00, 0x02]).write(to: dir.appendingPathComponent("blob.bin"))
        _ = try await runner.run(["add", "blob.bin"])
        _ = try await runner.run(["commit", "-m", "add binary"])
        let vm = FileHistoryViewModel(repoURL: dir, filePath: "blob.bin", runner: runner)

        await vm.loadHistory()
        let only = try #require(await vm.revisions.first)
        await vm.showVersion(only)
        #expect(await vm.selectedContent?.isBinary == true)
    }

    @Test("restoring a binary version writes its bytes back byte-for-byte (atomic write preserves NUL/high bytes)")
    func restoreBinaryRoundTrips() async throws {
        let (dir, runner) = try await makeRepo("binary-restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data([0x00, 0x01, 0xFF, 0x00, 0x80])
        try original.write(to: dir.appendingPathComponent("blob.bin"))
        _ = try await runner.run(["add", "blob.bin"])
        _ = try await runner.run(["commit", "-m", "add binary v1"])
        // A second, different binary version lands in the worktree + HEAD.
        try Data([0x02, 0x00, 0x03]).write(to: dir.appendingPathComponent("blob.bin"))
        _ = try await runner.run(["add", "blob.bin"])
        _ = try await runner.run(["commit", "-m", "binary v2"])

        let vm = FileHistoryViewModel(repoURL: dir, filePath: "blob.bin", runner: runner)
        await vm.loadHistory()
        let firstVersion = try #require(await vm.revisions.last)
        await vm.restore(firstVersion)

        #expect(await vm.state.successValue != nil)
        // The on-disk bytes are the older version, exactly — the atomic
        // write neither truncated at the embedded NUL nor left a torn tail.
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("blob.bin"))
        #expect(onDisk == original)
        #expect(await vm.lastSafetyBackup != nil)
    }
}
