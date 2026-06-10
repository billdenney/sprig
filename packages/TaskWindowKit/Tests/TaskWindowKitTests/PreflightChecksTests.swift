// PreflightChecksTests.swift
//
// ADR 0070 guard rails. Branch checks are pure (BranchInfo in,
// warnings out — no git); the large-file check and the
// CommitComposer wiring run against real git per CLAUDE.md.
// Large-file fixtures inject a tiny threshold instead of staging
// 50 MiB blobs.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("PreflightChecks — branch checks (pure)")
struct PreflightBranchChecksTests {
    private let checks = PreflightChecks()

    @Test("main with an upstream warns about committing to the default branch")
    func mainWithUpstreamWarns() {
        let branch = BranchInfo(oid: "abc123", head: "main", upstream: "origin/main")
        let warnings = checks.branchWarnings(from: branch)
        #expect(warnings == [.committingToDefaultBranch(branch: "main", upstream: "origin/main")])
    }

    @Test("the legacy default-branch name with an upstream warns too")
    func legacyDefaultBranchNameWarns() {
        let branch = BranchInfo(oid: "abc123", head: "master", upstream: "origin/master")
        let warnings = checks.branchWarnings(from: branch)
        #expect(warnings == [.committingToDefaultBranch(branch: "master", upstream: "origin/master")])
    }

    @Test("main WITHOUT an upstream does not nag (local-only repo)")
    func mainWithoutUpstreamIsQuiet() {
        let branch = BranchInfo(oid: "abc123", head: "main", upstream: nil)
        #expect(checks.branchWarnings(from: branch).isEmpty)
    }

    @Test("feature branch with an upstream does not warn")
    func featureBranchIsQuiet() {
        let branch = BranchInfo(oid: "abc123", head: "feature/x", upstream: "origin/feature/x")
        #expect(checks.branchWarnings(from: branch).isEmpty)
    }

    @Test("detached HEAD warns with the oid")
    func detachedHeadWarns() {
        let branch = BranchInfo(oid: "abc123", head: nil, upstream: nil)
        #expect(checks.branchWarnings(from: branch) == [.detachedHEAD(oid: "abc123")])
    }

    @Test("nil branch info (parse without headers) produces no warnings")
    func nilBranchIsQuiet() {
        #expect(checks.branchWarnings(from: nil).isEmpty)
    }

    @Test("custom default-branch set is honored")
    func customDefaultBranchNames() {
        let custom = PreflightChecks(defaultBranchNames: ["trunk"])
        let trunk = BranchInfo(oid: "abc", head: "trunk", upstream: "origin/trunk")
        let main = BranchInfo(oid: "abc", head: "main", upstream: "origin/main")
        #expect(custom.branchWarnings(from: trunk).count == 1)
        #expect(custom.branchWarnings(from: main).isEmpty)
    }

    @Test("railIDs are stable wire values — renaming one is a prefs migration")
    func railIDStability() {
        let defaultBranch = PreflightWarning.committingToDefaultBranch(
            branch: "main", upstream: "origin/main"
        )
        let detached = PreflightWarning.detachedHEAD(oid: "abc")
        let large = PreflightWarning.largeStagedFileWithoutLFS(
            path: "big.bin", sizeBytes: 1, thresholdBytes: 1
        )
        #expect(defaultBranch.railID == "committing-to-default-branch")
        #expect(detached.railID == "detached-head")
        #expect(large.railID == "large-staged-file-without-lfs")
    }

    @Test("a suppressed rail no longer fires; the others still do")
    func suppressionFiltersPerRail() {
        let suppressed = PreflightChecks(suppressedRails: ["committing-to-default-branch"])
        let main = BranchInfo(oid: "abc", head: "main", upstream: "origin/main")
        let detached = BranchInfo(oid: "abc", head: nil, upstream: nil)
        #expect(
            suppressed.branchWarnings(from: main).isEmpty,
            "opted-out rail must stay quiet"
        )
        #expect(
            suppressed.branchWarnings(from: detached) == [.detachedHEAD(oid: "abc")],
            "other rails are unaffected"
        )
    }

    @Test("suppressing detached-head silences only that rail")
    func detachedSuppression() {
        let suppressed = PreflightChecks(suppressedRails: ["detached-head"])
        let detached = BranchInfo(oid: "abc", head: nil, upstream: nil)
        let main = BranchInfo(oid: "abc", head: "main", upstream: "origin/main")
        #expect(suppressed.branchWarnings(from: detached).isEmpty)
        #expect(suppressed.branchWarnings(from: main).count == 1)
    }
}

@Suite("PreflightChecks — large-file + CommitComposer wiring (real git)")
struct PreflightIntegrationTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-preflight-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["add", "seed.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    /// Threshold of 64 bytes so a ~100-byte file is "large".
    private let tinyThreshold = PreflightChecks(largeFileThresholdBytes: 64)

    @Test("staged over-threshold file without an LFS rule warns")
    func largeStagedFileWarns() async throws {
        let (dir, runner) = try await makeRepo("large")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 0x42, count: 200)
        try payload.write(to: dir.appendingPathComponent("big.bin"))
        _ = try await runner.run(["add", "big.bin"])

        let warnings = await tinyThreshold.largeStagedFileWarnings(
            stagedPaths: ["big.bin"],
            repoURL: dir,
            runner: runner
        )

        #expect(warnings == [.largeStagedFileWithoutLFS(
            path: "big.bin",
            sizeBytes: 200,
            thresholdBytes: 64
        )])
    }

    @Test("staged over-threshold file WITH an LFS rule stays quiet")
    func lfsTrackedLargeFileIsQuiet() async throws {
        let (dir, runner) = try await makeRepo("lfs-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("*.bin filter=lfs diff=lfs merge=lfs -text\n".utf8)
            .write(to: dir.appendingPathComponent(".gitattributes"))
        try Data(repeating: 0x42, count: 200).write(to: dir.appendingPathComponent("big.bin"))
        _ = try await runner.run(["add", ".gitattributes"])
        // `git add big.bin` would invoke the (possibly missing) LFS
        // clean filter; the check only needs the path STAGED-shaped,
        // so pass it directly — largeStagedFileWarnings takes the
        // staged list as input.
        let warnings = await tinyThreshold.largeStagedFileWarnings(
            stagedPaths: ["big.bin"],
            repoURL: dir,
            runner: runner
        )

        #expect(warnings.isEmpty)
    }

    @Test("suppressing the LFS rail skips the whole check — no warning for an oversize file")
    func suppressedLFSRailSkips() async throws {
        let (dir, runner) = try await makeRepo("suppressed")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x42, count: 200).write(to: dir.appendingPathComponent("big.bin"))
        _ = try await runner.run(["add", "big.bin"])

        let suppressed = PreflightChecks(
            largeFileThresholdBytes: 64,
            suppressedRails: ["large-staged-file-without-lfs"]
        )
        let warnings = await suppressed.largeStagedFileWarnings(
            stagedPaths: ["big.bin"],
            repoURL: dir,
            runner: runner
        )
        #expect(warnings.isEmpty)
    }

    @Test("under-threshold staged files never reach check-attr and stay quiet")
    func smallFilesAreQuiet() async throws {
        let (dir, runner) = try await makeRepo("small")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("tiny\n".utf8).write(to: dir.appendingPathComponent("small.txt"))
        _ = try await runner.run(["add", "small.txt"])

        let warnings = await tinyThreshold.largeStagedFileWarnings(
            stagedPaths: ["small.txt"],
            repoURL: dir,
            runner: runner
        )
        #expect(warnings.isEmpty)
    }

    @Test("CommitComposer.refresh() surfaces detached-HEAD + large-file warnings together")
    func commitComposerSurfacesWarnings() async throws {
        let (dir, runner) = try await makeRepo("composer")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Detach HEAD at the seed commit, then stage an over-threshold
        // file — refresh() must report both rails in one pass.
        let head = try await runner.run(["rev-parse", "HEAD"])
        let sha = head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["switch", "--detach", sha])
        try Data(repeating: 0x42, count: 200).write(to: dir.appendingPathComponent("big.bin"))
        _ = try await runner.run(["add", "big.bin"])

        let vm = CommitComposerViewModel(
            repoURL: dir,
            runner: runner,
            preflight: PreflightChecks(largeFileThresholdBytes: 64)
        )
        await vm.refresh()

        let warnings = await vm.preflightWarnings
        #expect(warnings.count == 2)
        #expect(warnings.contains(.detachedHEAD(oid: sha)))
        #expect(warnings.contains(.largeStagedFileWithoutLFS(
            path: "big.bin",
            sizeBytes: 200,
            thresholdBytes: 64
        )))
    }

    @Test("CommitComposer.refresh() on a clean feature branch reports no warnings")
    func commitComposerQuietOnFeatureBranch() async throws {
        let (dir, runner) = try await makeRepo("quiet")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await runner.run(["switch", "-c", "feature/quiet"])

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        #expect(await vm.preflightWarnings.isEmpty)
    }
}
