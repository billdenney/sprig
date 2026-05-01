import Foundation
@testable import GitCore
import Testing

@Suite("GitMetadataPaths.resolveGitDir")
struct ResolveGitDirTests {
    private func mkTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardized
    }

    @Test(".git directory case returns the directory unchanged")
    func dotGitDirectoryCase() throws {
        let worktree = try mkTempDir("dir")
        defer { try? FileManager.default.removeItem(at: worktree) }
        let dotGit = worktree.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)

        let resolved = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        // Compare via `.path` to dodge trailing-slash differences in
        // URL representations (URL(fileURLWithPath:) stat()s the path
        // and adds the slash if it's a directory).
        #expect(resolved.path == dotGit.path)
    }

    @Test(".git file with relative pointer (submodule shape) is followed")
    func dotGitFileRelativePointer() throws {
        // Simulate a submodule layout: super-repo/.git/modules/<name>/
        // and worktree is super-repo/<name> with a `.git` file pointing
        // back via a relative path.
        let superRepo = try mkTempDir("super")
        defer { try? FileManager.default.removeItem(at: superRepo) }
        let modulesDir = superRepo.appendingPathComponent(".git/modules/sub")
        try FileManager.default.createDirectory(at: modulesDir, withIntermediateDirectories: true)

        let submoduleWT = superRepo.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: submoduleWT, withIntermediateDirectories: true)
        let dotGit = submoduleWT.appendingPathComponent(".git")
        try Data("gitdir: ../.git/modules/sub\n".utf8).write(to: dotGit)

        let resolved = try GitMetadataPaths.resolveGitDir(forWorktree: submoduleWT)
        #expect(resolved.path == modulesDir.path)
    }

    @Test(".git file with absolute pointer is followed")
    func dotGitFileAbsolutePointer() throws {
        let target = try mkTempDir("target-abs")
        defer { try? FileManager.default.removeItem(at: target) }
        let worktree = try mkTempDir("worktree-abs")
        defer { try? FileManager.default.removeItem(at: worktree) }
        let dotGit = worktree.appendingPathComponent(".git")
        try Data("gitdir: \(target.path)\n".utf8).write(to: dotGit)

        let resolved = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        #expect(resolved.path == target.path)
    }

    @Test(".git file with trailing whitespace and CRLF is handled")
    func dotGitFileTolerantOfWhitespace() throws {
        let target = try mkTempDir("target-ws")
        defer { try? FileManager.default.removeItem(at: target) }
        let worktree = try mkTempDir("worktree-ws")
        defer { try? FileManager.default.removeItem(at: worktree) }
        let dotGit = worktree.appendingPathComponent(".git")
        // Trailing spaces, CRLF — both have shown up in the wild.
        try Data("gitdir: \(target.path)   \r\n".utf8).write(to: dotGit)

        let resolved = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
        #expect(resolved.path == target.path)
    }

    @Test("missing .git throws notARepository")
    func missingDotGit() throws {
        let worktree = try mkTempDir("missing")
        defer { try? FileManager.default.removeItem(at: worktree) }

        do {
            _ = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
            Issue.record("expected notARepository to be thrown")
        } catch let error as GitMetadataPaths.ResolveError {
            if case .notARepository = error {
                // expected
            } else {
                Issue.record("expected notARepository, got \(error)")
            }
        } catch {
            Issue.record("expected ResolveError, got \(error)")
        }
    }

    @Test("malformed .git file (no gitdir: prefix) throws gitdirPointerMalformed")
    func malformedDotGit() throws {
        let worktree = try mkTempDir("malformed")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try Data("not a gitdir pointer\n".utf8).write(to: worktree.appendingPathComponent(".git"))

        do {
            _ = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
            Issue.record("expected gitdirPointerMalformed")
        } catch let error as GitMetadataPaths.ResolveError {
            if case .gitdirPointerMalformed = error {
                // expected
            } else {
                Issue.record("expected gitdirPointerMalformed, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(".git pointer to non-existent dir throws gitdirPointerTargetMissing")
    func dotGitPointerTargetMissing() throws {
        let worktree = try mkTempDir("dangling")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try Data("gitdir: /no/such/path/anywhere-\(UUID())\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        do {
            _ = try GitMetadataPaths.resolveGitDir(forWorktree: worktree)
            Issue.record("expected gitdirPointerTargetMissing")
        } catch let error as GitMetadataPaths.ResolveError {
            if case .gitdirPointerTargetMissing = error {
                // expected
            } else {
                Issue.record("expected gitdirPointerTargetMissing, got \(error)")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("GitMetadataPaths.isLockOrTempPath")
struct LockOrTempPathTests {
    private let gitDir = URL(fileURLWithPath: "/tmp/r/.git").standardized

    private func path(_ relative: String) -> URL {
        gitDir.appendingPathComponent(relative).standardized
    }

    @Test("index.lock is filtered")
    func indexLockFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("index.lock"), in: gitDir))
    }

    @Test("HEAD.lock is filtered")
    func headLockFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("HEAD.lock"), in: gitDir))
    }

    @Test("packed-refs.lock is filtered")
    func packedRefsLockFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("packed-refs.lock"), in: gitDir))
    }

    @Test("refs/heads/main.lock is filtered (deep .lock)")
    func refsHeadsLockFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("refs/heads/main.lock"), in: gitDir))
    }

    @Test("objects/pack/tmp_xxx is filtered")
    func packTmpFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("objects/pack/tmp_pack_AbCd"), in: gitDir))
    }

    @Test("objects/pack/.tmp-xxx-pack is filtered")
    func packDotTmpFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("objects/pack/.tmp-1234-pack"), in: gitDir))
    }

    @Test("objects/incoming-xxx is filtered (git 2.40+ fetch staging)")
    func incomingFiltered() {
        #expect(GitMetadataPaths.isLockOrTempPath(path("objects/incoming-12345/file"), in: gitDir))
    }

    @Test("regular ref file is NOT filtered")
    func regularRefNotFiltered() {
        #expect(!GitMetadataPaths.isLockOrTempPath(path("refs/heads/main"), in: gitDir))
    }

    @Test("packed-refs (no .lock) is NOT filtered")
    func packedRefsNotFiltered() {
        #expect(!GitMetadataPaths.isLockOrTempPath(path("packed-refs"), in: gitDir))
    }

    @Test("HEAD (no .lock) is NOT filtered")
    func headNotFiltered() {
        #expect(!GitMetadataPaths.isLockOrTempPath(path("HEAD"), in: gitDir))
    }

    @Test("path outside gitDir is NOT filtered (worktree .lock from editor)")
    func outsideGitDirNotFiltered() {
        let editorTempLock = URL(fileURLWithPath: "/tmp/r/src/file.swift.lock")
        #expect(!GitMetadataPaths.isLockOrTempPath(editorTempLock, in: gitDir))
    }
}

@Suite("GitMetadataPaths.gitOperationInFlight")
struct GitOperationInFlightTests {
    private func mkGitDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-flight-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardized
    }

    @Test("empty git dir reports no operation in flight")
    func emptyDirNotInFlight() throws {
        let gitDir = try mkGitDir("empty")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        #expect(!GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("index.lock present → in flight")
    func indexLockTriggersFlight() throws {
        let gitDir = try mkGitDir("index")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try Data().write(to: gitDir.appendingPathComponent("index.lock"))
        #expect(GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("HEAD.lock present → in flight")
    func headLockTriggersFlight() throws {
        let gitDir = try mkGitDir("head")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try Data().write(to: gitDir.appendingPathComponent("HEAD.lock"))
        #expect(GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("packed-refs.lock present → in flight")
    func packedRefsLockTriggersFlight() throws {
        let gitDir = try mkGitDir("packedrefs")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try Data().write(to: gitDir.appendingPathComponent("packed-refs.lock"))
        #expect(GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("config.lock present → in flight")
    func configLockTriggersFlight() throws {
        let gitDir = try mkGitDir("config")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try Data().write(to: gitDir.appendingPathComponent("config.lock"))
        #expect(GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("shallow.lock present → in flight")
    func shallowLockTriggersFlight() throws {
        let gitDir = try mkGitDir("shallow")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try Data().write(to: gitDir.appendingPathComponent("shallow.lock"))
        #expect(GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }

    @Test("non-critical .lock files alone do NOT trigger in-flight")
    func nonCriticalLocksDontTrigger() throws {
        let gitDir = try mkGitDir("noncritical")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        // A ref-level .lock — short-lived; we filter at the
        // per-event layer, not at the agent-defer layer.
        let refsHeads = gitDir.appendingPathComponent("refs/heads")
        try FileManager.default.createDirectory(at: refsHeads, withIntermediateDirectories: true)
        try Data().write(to: refsHeads.appendingPathComponent("main.lock"))
        #expect(!GitMetadataPaths.gitOperationInFlight(in: gitDir))
    }
}

@Suite("GitMetadataPaths.linkedWorktrees")
struct LinkedWorktreesTests {
    private func mkGitDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gmd-linked-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardized
    }

    @Test("repo with no linked worktrees returns empty array")
    func noLinkedWorktreesReturnsEmpty() throws {
        let gitDir = try mkGitDir("none")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        let result = try GitMetadataPaths.linkedWorktrees(at: gitDir)
        #expect(result.isEmpty)
    }

    @Test("worktrees/<name>/gitdir files are read and resolved to worktree roots")
    func linkedWorktreesEnumerated() throws {
        let gitDir = try mkGitDir("multi")
        defer { try? FileManager.default.removeItem(at: gitDir) }

        // Set up two linked worktrees per `git worktree add` shape:
        // <gitDir>/worktrees/<name>/gitdir contains the path to
        // <linked>/.git, where <linked> is the linked worktree root.
        let linkedA = URL(fileURLWithPath: "/tmp/sprig-linked-a")
        let linkedB = URL(fileURLWithPath: "/tmp/sprig-linked-b")

        let dirA = gitDir.appendingPathComponent("worktrees/feature-a")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try Data("\(linkedA.path)/.git\n".utf8).write(to: dirA.appendingPathComponent("gitdir"))

        let dirB = gitDir.appendingPathComponent("worktrees/feature-b")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data("\(linkedB.path)/.git\n".utf8).write(to: dirB.appendingPathComponent("gitdir"))

        let result = try GitMetadataPaths.linkedWorktrees(at: gitDir)
        #expect(result.count == 2)
        let resultPaths = Set(result.map(\.path))
        #expect(resultPaths.contains(linkedA.path))
        #expect(resultPaths.contains(linkedB.path))
    }

    @Test("entries with missing gitdir files are skipped")
    func missingGitdirSkipped() throws {
        let gitDir = try mkGitDir("partial")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        let dirA = gitDir.appendingPathComponent("worktrees/dead")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        // No `gitdir` file inside — the worktree was pruned but the
        // directory wasn't cleaned up. Skip silently.

        let result = try GitMetadataPaths.linkedWorktrees(at: gitDir)
        #expect(result.isEmpty)
    }
}
