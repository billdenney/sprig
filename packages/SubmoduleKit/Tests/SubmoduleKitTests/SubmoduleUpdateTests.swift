import Foundation
import GitCore
import SafetyKit
@testable import SubmoduleKit
import Testing

@Suite("SubmoduleUpdate.reconcile / snapshotThenForce — real git fixtures")
struct SubmoduleUpdateTests {
    /// A super-repo + submodule fixture where the super-repo's recorded
    /// pointer for `sub` is AHEAD of the submodule's current checkout —
    /// i.e. `git submodule status` reports `+` and `reconcile` has work
    /// to do. The temp dirs are returned so callers clean them up.
    private struct DriftFixture {
        var parent: URL
        var helper: URL
        /// The SHA the parent records for `sub` (where reconcile should
        /// land the submodule's HEAD).
        var recordedSHA: String
    }

    /// Build a super-repo with a submodule, then advance the helper +
    /// bump the parent's recorded pointer, then roll the submodule's
    /// checkout BACK one commit so it's out-of-date relative to the
    /// recorded pointer. `reconcile` should move it forward.
    ///
    /// `seedFile` is the name of the submodule's seed (`c1`) tracked
    /// file — the one a dirty-edit test mutates. Defaults to `a.txt`;
    /// the snapshot-then-force data-loss regression passes a name that
    /// matches a `WorktreeBackup` exclude glob (e.g. `config.key`).
    private func makeDrifted(seedFile: String = "a.txt") async throws -> DriftFixture {
        let helper = mktemp("skit-up-helper")
        let parent = mktemp("skit-up-parent")
        try mkdir(helper, parent)

        let helperRunner = Runner(defaultWorkingDirectory: helper)
        try await initRepo(runner: helperRunner, identity: "h")
        // Mark the submodule's files binary (`-text`) so git NEVER applies
        // line-ending conversion to them on any platform. Without this,
        // git-for-Windows' system `core.autocrlf=true` checks the files out
        // as CRLF while the blobs are LF — which (a) makes a "clean"
        // submodule read as dirty (CRLF worktree vs LF blob), tripping the
        // reconcile dirty-skip, and (b) breaks the snapshotThenForce
        // byte-exact restore round-trip. `-text` is committed IN the
        // submodule so it travels with it, deterministic on every OS.
        try write("* -text\n", to: helper.appendingPathComponent(".gitattributes"))
        try write("c1\n", to: helper.appendingPathComponent(seedFile))
        _ = try await helperRunner.run(["add", "-A"])
        _ = try await helperRunner.run(["commit", "-m", "c1"])

        let parentRunner = Runner(defaultWorkingDirectory: parent)
        try await initRepo(runner: parentRunner, identity: "p")
        try write("seed\n", to: parent.appendingPathComponent("p.txt"))
        _ = try await parentRunner.run(["add", "p.txt"])
        _ = try await parentRunner.run(["commit", "-m", "seed"])
        _ = try await parentRunner.run(allowFile + ["submodule", "add", helper.path, "sub"])
        _ = try await parentRunner.run(allowFile + ["submodule", "update", "--init"])
        _ = try await parentRunner.run(["commit", "-m", "add sub"])

        // The submodule is its own git repo with its own config. Give it
        // an identity so an in-submodule WorktreeBackup `commit-tree`
        // (snapshotThenForce) works on a VM with NO global git identity
        // (the Windows CI VM has none; Linux/macOS happen to). Real
        // submodules inherit the user's global identity, so this just
        // simulates the normal environment.
        let subConfig = Runner(defaultWorkingDirectory: parent.appendingPathComponent("sub"))
        _ = try await subConfig.run(["config", "user.email", "sub@test"])
        _ = try await subConfig.run(["config", "user.name", "sub"])

        // Helper gains a new commit; bump the parent's recorded pointer
        // to it. (Add an UNRELATED file in the helper so the new commit
        // doesn't touch the file the dirty-skip test edits.)
        try write("c2\n", to: helper.appendingPathComponent("b.txt"))
        _ = try await helperRunner.run(["add", "b.txt"])
        _ = try await helperRunner.run(["commit", "-m", "c2"])
        let newSHA = try await helperRunner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let subRunner = Runner(defaultWorkingDirectory: parent.appendingPathComponent("sub"))
        _ = try await subRunner.run(["fetch", "origin"])
        _ = try await subRunner.run(["checkout", newSHA])
        _ = try await parentRunner.run(["add", "sub"])
        _ = try await parentRunner.run(["commit", "-m", "bump sub pointer"])

        // Roll the submodule's checkout back so it's now `+` (out of
        // date) relative to the recorded `newSHA`.
        _ = try await subRunner.run(["checkout", "HEAD~1"])

        return DriftFixture(parent: parent.standardized, helper: helper.standardized, recordedSHA: newSHA)
    }

    // MARK: - reconcile

    @Test("clean out-of-date submodule is updated init + recursive")
    func cleanSubmoduleUpdated() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        // Precondition: out of date.
        let before = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(before.first?.state == .outOfDate)

        let outcome = try await SubmoduleUpdate.reconcile(at: fixture.parent, runner: runner)
        #expect(outcome.updated == ["sub"])
        #expect(outcome.skippedDirty.isEmpty)

        // The submodule's HEAD now matches the recorded pointer.
        let subHEAD = try await Runner(defaultWorkingDirectory: fixture.parent.appendingPathComponent("sub"))
            .run(["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(subHEAD == fixture.recordedSHA)
        let after = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(after.first?.state == .clean)
    }

    @Test("uninitialized submodule is cloned by reconcile")
    func uninitializedSubmoduleCloned() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        // De-init the submodule so it reads as `-` (not initialized).
        _ = try await runner.run(["submodule", "deinit", "-f", "sub"])
        let before = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(before.first?.state == .notInitialized)

        let outcome = try await SubmoduleUpdate.reconcile(at: fixture.parent, runner: runner)
        #expect(outcome.updated == ["sub"])
        #expect(outcome.skippedDirty.isEmpty)
        let after = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(after.first?.state == .clean)
    }

    @Test("uninitialized submodule is cloned even when the SUPER-repo worktree is dirty")
    func uninitializedClonedDespiteDirtyParent() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        _ = try await runner.run(["submodule", "deinit", "-f", "sub"])
        // Dirty the SUPER-repo worktree (unrelated to the submodule). A
        // naive `git -C sub status` probe of the EMPTY submodule dir walks
        // UP and sees THIS dirt — which would wrongly mark the
        // uninitialized submodule "dirty" and skip its clone. The
        // entry.state == .notInitialized short-circuit must clone it anyway.
        try write("super-repo edit\n", to: fixture.parent.appendingPathComponent("p.txt"))

        let outcome = try await SubmoduleUpdate.reconcile(at: fixture.parent, runner: runner)
        #expect(outcome.updated == ["sub"]) // cloned, NOT skipped as dirty
        #expect(outcome.skippedDirty.isEmpty)
        let after = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(after.first?.state == .clean)
    }

    @Test("dirty submodule is skipped + reported, never clobbered")
    func dirtySubmoduleSkipped() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        // Locally modify a TRACKED file in the submodule — git's own
        // `update` would abort the whole command on this, so reconcile
        // must skip it.
        let subFile = fixture.parent.appendingPathComponent("sub/a.txt")
        try write("LOCAL EDIT — do not lose me\n", to: subFile)

        let outcome = try await SubmoduleUpdate.reconcile(at: fixture.parent, runner: runner)
        #expect(outcome.updated.isEmpty)
        #expect(outcome.skippedDirty == ["sub"])

        // The local edit survives byte-for-byte; the submodule is still
        // at the old (out-of-date) SHA.
        let content = try String(contentsOf: subFile, encoding: .utf8)
        #expect(content == "LOCAL EDIT — do not lose me\n")
        let after = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(after.first?.state == .outOfDate)
    }

    @Test("repo with no submodules reconciles to an empty outcome")
    func noSubmodulesEmptyOutcome() async throws {
        let dir = mktemp("skit-up-empty")
        try mkdir(dir)
        defer { cleanup(dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        try await initRepo(runner: runner, identity: "x")
        try write("x\n", to: dir.appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "x.txt"])
        _ = try await runner.run(["commit", "-m", "x"])

        let outcome = try await SubmoduleUpdate.reconcile(at: dir, runner: runner)
        #expect(outcome.updated.isEmpty)
        #expect(outcome.skippedDirty.isEmpty)
    }

    // MARK: - snapshotThenForce

    @Test("snapshotThenForce backs up inside the submodule then force-updates")
    func snapshotThenForceBacksUpAndForces() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let subWorktree = fixture.parent.appendingPathComponent("sub")
        let subFile = subWorktree.appendingPathComponent("a.txt")
        try write("WORK TO RESCUE\n", to: subFile)

        // Sanity: a plain reconcile would skip this.
        let skipped = try await SubmoduleUpdate.reconcile(at: fixture.parent, runner: runner)
        #expect(skipped.skippedDirty == ["sub"])

        let force = try await SubmoduleUpdate.snapshotThenForce(
            submodulePath: "sub",
            in: fixture.parent,
            runner: runner
        )
        #expect(force.submodulePath == "sub")
        let backupRef = try #require(force.backupRef)

        // The backup ref lives INSIDE the submodule's repo, not the
        // super-repo. Listing backups from the submodule's runner finds
        // it; listing from the super-repo's runner does not. Compare by
        // the wire-stable `refName` — the returned `BackupRefName`
        // carries sub-second `clock()` precision while the parsed-back
        // ref is second-truncated, so the struct `==` would spuriously
        // differ on the timestamp field.
        let subRunner = Runner(defaultWorkingDirectory: subWorktree)
        let subBackups = try await WorktreeBackup(runner: subRunner).backups()
        #expect(subBackups.contains { $0.ref.refName == backupRef.refName })
        let parentBackups = try await WorktreeBackup(runner: runner).backups()
        #expect(parentBackups.isEmpty)

        // The force landed the submodule on the recorded pointer.
        let subHEAD = try await subRunner.run(["rev-parse", "HEAD"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(subHEAD == fixture.recordedSHA)
        let after = try await SubmoduleStatus.fetch(at: fixture.parent, runner: runner)
        #expect(after.first?.state == .clean)
    }

    @Test("snapshotThenForce backup restores the discarded work byte-exactly")
    func snapshotThenForceRoundTrips() async throws {
        let fixture = try await makeDrifted()
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let subWorktree = fixture.parent.appendingPathComponent("sub")
        let subFile = subWorktree.appendingPathComponent("a.txt")
        let original = "PRECIOUS UNCOMMITTED WORK\nwith a second line\n"
        try write(original, to: subFile)

        let force = try await SubmoduleUpdate.snapshotThenForce(
            submodulePath: "sub",
            in: fixture.parent,
            runner: runner
        )
        let backupRef = try #require(force.backupRef)

        // The force overwrote the edit (file is back to the recorded
        // content, which has no second line).
        let clobbered = try String(contentsOf: subFile, encoding: .utf8)
        #expect(clobbered != original)

        // Restore through the real Recover path (the undo-round-trip
        // rule): the discarded work comes back byte-exactly.
        let subRunner = Runner(defaultWorkingDirectory: subWorktree)
        _ = try await WorktreeBackup(runner: subRunner).restore(backupRef.refName)
        let restored = try String(contentsOf: subFile, encoding: .utf8)
        #expect(restored == original)
    }

    @Test("""
    snapshotThenForce backs up a tracked secret-glob edit (config.key) \
    and round-trips it — no junk-only-dirty data loss
    """)
    func snapshotThenForcePreservesTrackedSecretGlobEdit() async throws {
        // Regression: the sole dirt is a TRACKED file matching a
        // `WorktreeBackup` default exclude glob (`config.key` → `*.key`).
        // With the default excludes, `createBackupIfDirty` staged a tree
        // equal to HEAD's (the `.key` excluded), hit its junk-only-dirty
        // guard, and returned `nil` — then the `--force` clobbered the
        // tracked edit with NO backup ref to recover from (HIGH-severity
        // data loss). The fix backs up with NO exclude list, so the edit
        // is captured and recoverable. The same hole exists for any
        // tracked `*.env`/`*secret*`/`*.pem`-shaped file.
        let fixture = try await makeDrifted(seedFile: "config.key")
        defer { cleanup(fixture.parent, fixture.helper) }
        let runner = Runner(defaultWorkingDirectory: fixture.parent)

        let subWorktree = fixture.parent.appendingPathComponent("sub")
        let subFile = subWorktree.appendingPathComponent("config.key")
        let original = "SECRET=do-not-lose-me\nrotated-2026-06-19\n"
        try write(original, to: subFile)

        // Sanity: it really matches a secrets exclude glob — otherwise
        // this test wouldn't exercise the junk-only-dirty path at all.
        #expect(JunkFilePatterns.rule(matching: "config.key")?.category == .secret)

        let force = try await SubmoduleUpdate.snapshotThenForce(
            submodulePath: "sub",
            in: fixture.parent,
            runner: runner
        )

        // THE regression assertion: a backup ref WAS minted (pre-fix this
        // was nil), and it actually exists inside the submodule's gitdir.
        let backupRef = try #require(
            force.backupRef,
            "force-destroy of a tracked secret-glob edit must mint a backup ref"
        )
        let subRunner = Runner(defaultWorkingDirectory: subWorktree)
        let subBackups = try await WorktreeBackup(runner: subRunner).backups()
        #expect(subBackups.contains { $0.ref.refName == backupRef.refName })

        // The force discarded the working-tree edit (back to recorded).
        let clobbered = try String(contentsOf: subFile, encoding: .utf8)
        #expect(clobbered != original)

        // Recover path round-trips the secret-glob edit byte-exactly.
        _ = try await WorktreeBackup(runner: subRunner).restore(backupRef.refName)
        let restored = try String(contentsOf: subFile, encoding: .utf8)
        #expect(restored == original)
    }

    // MARK: - Fixture helpers

    private let allowFile = ["-c", "protocol.file.allow=always"]

    private func mktemp(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-\(tag)-\(UUID().uuidString)")
    }

    private func mkdir(_ urls: URL...) throws {
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func initRepo(runner: Runner, identity: String) async throws {
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "\(identity)@test"])
        _ = try await runner.run(["config", "user.name", identity])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // Assert raw bytes on Windows git (core.autocrlf=true default).
        _ = try await runner.run(["config", "core.autocrlf", "false"])
    }

    private func cleanup(_ urls: URL?...) {
        for case let url? in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
