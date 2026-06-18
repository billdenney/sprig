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
        let switching = PreflightWarning.switchingAwayFromUnpushed(
            branch: "feature/x", unpushedCount: 2
        )
        let secret = PreflightWarning.stagedSecretDetected(
            path: "config.py", rule: "AWS Access Key ID", line: 3
        )
        let protectedBranch = PreflightWarning.pushingToProtectedBranch(branch: "main")
        let forceConsequence = PreflightWarning.forcePushConsequence(branch: "main", ahead: 1, behind: 2)
        let outgoingSecret = PreflightWarning.secretInOutgoingCommits(
            path: "config.py", rule: "AWS Access Key ID", line: 3
        )
        let binaryType = PreflightWarning.binaryTypeWithoutLFS(path: "art.psd", suggestedPattern: "*.psd")
        #expect(defaultBranch.railID == "committing-to-default-branch")
        #expect(detached.railID == "detached-head")
        #expect(large.railID == "large-staged-file-without-lfs")
        #expect(switching.railID == "switching-away-from-unpushed")
        #expect(secret.railID == "staged-secret")
        #expect(protectedBranch.railID == "pushing-to-protected-branch")
        #expect(forceConsequence.railID == "force-push-consequence")
        #expect(outgoingSecret.railID == "secret-in-outgoing-commits")
        #expect(binaryType.railID == "binary-type-without-lfs")
    }

    private func syncState(
        name: String = "feature/x",
        upstream: String? = "origin/feature/x",
        ahead: Int = 0,
        gone: Bool = false,
        isCurrent: Bool = true
    ) -> BranchSyncState {
        BranchSyncState(
            name: name,
            sha: String(repeating: "a", count: 40),
            upstreamFullRef: upstream.map { "refs/remotes/\($0)" },
            upstreamShort: upstream,
            ahead: ahead,
            behind: 0,
            upstreamGone: gone,
            isCurrent: isCurrent
        )
    }

    @Test("switch-away rail fires only for the CURRENT branch with unpushed commits")
    func switchAwayRail() {
        let checks = PreflightChecks()
        #expect(
            checks.switchAwayWarnings(states: [syncState(ahead: 2)])
                == [.switchingAwayFromUnpushed(branch: "feature/x", unpushedCount: 2)]
        )
        #expect(
            checks.switchAwayWarnings(states: [syncState(ahead: 0)]).isEmpty,
            "in-sync branch is quiet"
        )
        #expect(
            checks.switchAwayWarnings(states: [syncState(upstream: nil, ahead: 3)]).isEmpty,
            "no upstream — nothing to be 'not on'"
        )
        #expect(
            checks.switchAwayWarnings(states: [syncState(ahead: 3, gone: true)]).isEmpty,
            "gone upstream belongs to the cleanup banner"
        )
        #expect(
            checks.switchAwayWarnings(states: [syncState(ahead: 3, isCurrent: false)]).isEmpty,
            "only where the user is standing"
        )
        let suppressed = PreflightChecks(suppressedRails: ["switching-away-from-unpushed"])
        #expect(suppressed.switchAwayWarnings(states: [syncState(ahead: 2)]).isEmpty)
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

    @Test("binary-type rail: fires on an untracked binary; quiet when suppressed / over-threshold / LFS-tracked")
    func binaryTypeRail() async throws {
        let (dir, runner) = try await makeRepo("binary-type")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x42, count: 100).write(to: dir.appendingPathComponent("art.psd"))
        _ = try await runner.run(["add", "art.psd"])

        let warnings = await PreflightChecks().binaryTypeWarnings(
            stagedPaths: ["art.psd"], repoURL: dir, runner: runner
        )
        #expect(warnings == [.binaryTypeWithoutLFS(path: "art.psd", suggestedPattern: "*.psd")])

        let suppressed = await PreflightChecks(suppressedRails: ["binary-type-without-lfs"])
            .binaryTypeWarnings(stagedPaths: ["art.psd"], repoURL: dir, runner: runner)
        #expect(suppressed.isEmpty, "suppressed rail stays quiet")

        // An over-threshold binary is the size rail's, not double-warned.
        try Data(repeating: 0x42, count: 100).write(to: dir.appendingPathComponent("clip.mp4"))
        _ = try await runner.run(["add", "clip.mp4"])
        let overThreshold = await tinyThreshold
            .binaryTypeWarnings(stagedPaths: ["clip.mp4"], repoURL: dir, runner: runner)
        #expect(overThreshold.isEmpty, "over-threshold binary belongs to the size rail")

        // An LFS-tracked pattern silences it (uncommitted .gitattributes is honored by check-attr).
        try Data("*.psd filter=lfs diff=lfs merge=lfs -text\n".utf8)
            .write(to: dir.appendingPathComponent(".gitattributes"))
        let tracked = await PreflightChecks().binaryTypeWarnings(
            stagedPaths: ["art.psd"], repoURL: dir, runner: runner
        )
        #expect(tracked.isEmpty, "LFS-tracked binary type doesn't warn")
    }

    @Test("staged secret fires the staged-secret rail; suppression and allowlist silence it")
    func stagedSecretRail() async throws {
        let (dir, runner) = try await makeRepo("secret")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("ok = 1\nAWS_KEY = \"AKIAIOSFODNN7EXAMPLE\"\n".utf8)
            .write(to: dir.appendingPathComponent("config.py"))
        _ = try await runner.run(["add", "config.py"])

        let warnings = await PreflightChecks().stagedSecretWarnings(
            stagedPaths: ["config.py"],
            repoURL: dir,
            runner: runner
        )
        #expect(warnings == [.stagedSecretDetected(
            path: "config.py",
            rule: "AWS Access Key ID",
            line: 2
        )])

        // Suppressing the rail skips the scan entirely.
        let suppressed = await PreflightChecks(suppressedRails: ["staged-secret"])
            .stagedSecretWarnings(stagedPaths: ["config.py"], repoURL: dir, runner: runner)
        #expect(suppressed.isEmpty)

        // The .sprig/secret-allow allowlist silences a known-safe finding.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".sprig"), withIntermediateDirectories: true
        )
        try Data("config.py:aws-access-key-id\n".utf8)
            .write(to: dir.appendingPathComponent(".sprig/secret-allow"))
        let allowlisted = await PreflightChecks().stagedSecretWarnings(
            stagedPaths: ["config.py"], repoURL: dir, runner: runner
        )
        #expect(allowlisted.isEmpty)
    }

    @Test("staged-secret rail adds no scan when nothing is staged")
    func stagedSecretRailNoStagedPaths() async throws {
        let (dir, runner) = try await makeRepo("secret-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let warnings = await PreflightChecks().stagedSecretWarnings(
            stagedPaths: [], repoURL: dir, runner: runner
        )
        #expect(warnings.isEmpty)
    }

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
