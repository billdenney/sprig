// MergeConflictResolverLFSTests.swift
//
// Tests for LFS-pointer post-apply materialization in
// MergeConflictResolverViewModel. The classifier marks a conflict as
// ``ConflictKind/lfsPointer`` when the caller's ``ConflictProbes``
// `isLFSTracked` probe returns true; the VM's apply pipeline then
// runs `git lfs checkout` to swap the pointer file for its actual
// binary content.
//
// We don't depend on git-lfs being installed for these tests —
// instead, we exercise the failure path: force-classify a non-LFS
// path as `.lfsPointer` via the probe, attempt to apply, and verify
// the typed `MergeApplyError.lfsMaterializeFailed` surfaces.

@testable import ConflictKit
import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("MergeConflictResolverViewModel — LFS pointer materialization")
struct MergeConflictResolverLFSTests {
    private func makeTextConflictRepo(tag: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-mcr-lfs-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        _ = try await runner.run(["checkout", "-b", "feature"])
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "feat"])
        _ = try await runner.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main"])
        _ = try await runner.run(["merge", "feature"], throwOnNonZero: false)
        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pure-data MergeApplyError tests

    @Test("MergeApplyError.lfsMaterializeFailed is Equatable on both fields")
    func errorEquatable() {
        let a = MergeApplyError.lfsMaterializeFailed(path: "x.bin", underlying: "git: 'lfs' is not a git command")
        let b = MergeApplyError.lfsMaterializeFailed(path: "x.bin", underlying: "git: 'lfs' is not a git command")
        let c = MergeApplyError.lfsMaterializeFailed(path: "y.bin", underlying: "git: 'lfs' is not a git command")
        let d = MergeApplyError.lfsMaterializeFailed(path: "x.bin", underlying: "different message")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("MergeApplyError.lfsMaterializeFailed crosses actor boundaries (Sendable)")
    func errorSendable() async {
        actor Holder<T: Sendable> {
            var value: T
            init(_ v: T) {
                value = v
            }
        }
        let err: MergeApplyError = .lfsMaterializeFailed(path: "x.bin", underlying: "boom")
        let holder = Holder<MergeApplyError>(err)
        let read = await holder.value
        #expect(read == err)
    }

    // MARK: - Integration: force-LFS classification + verify materialize fires

    @Test("an .lfsPointer-classified path triggers git lfs checkout after the pointer write")
    func lfsMaterializationInvokedOnLFSKind() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "force-classify")
        defer { cleanup(dir) }

        // Force the classifier to mark every path as LFS-tracked.
        // The conflict is actually a plain text file; we're verifying
        // that the LFS post-apply step *fires* (which, against a non-
        // LFS file or a missing git-lfs, surfaces lfsMaterializeFailed).
        let probes = ConflictProbes(
            isLFSTracked: { _ in true },
            isBinary: nil
        )
        let vm = MergeConflictResolverViewModel(
            repoURL: dir,
            runner: runner,
            probes: probes
        )
        await vm.refresh()
        let conflict = try #require(await vm.conflicts.first)
        #expect(conflict.kind == .lfsPointer)

        await vm.choose(path: "a.txt", .ours)
        await vm.applyOne(path: "a.txt")

        // Either:
        //   (a) git-lfs isn't installed → command fails → typed
        //       lfsMaterializeFailed surfaces
        //   (b) git-lfs IS installed but the path isn't actually
        //       LFS-tracked → checkout still fails (or no-ops with
        //       non-zero exit on some lfs versions) → same typed
        //       error path.
        // Either way, the wiring is exercised and we verify the
        // typed error reaches the VM's `state`.
        let state = await vm.state
        if case let .failure(failure) = state {
            #expect(
                failure.underlyingTypeName?.contains("MergeApplyError") == true,
                "expected lfsMaterializeFailed, got typeName: \(failure.underlyingTypeName ?? "nil")"
            )
            #expect(
                failure.description.contains("lfsMaterializeFailed")
                    || failure.description.contains("a.txt"),
                "expected the typed error to mention the path or its case name"
            )
            // The pointer (in this synthesized case, just the ours-
            // side blob bytes "main\n") was still written + staged
            // before the LFS step ran. Verify the working-tree path
            // got the bytes we wrote.
            let onDisk = try String(
                contentsOf: dir.appendingPathComponent("a.txt"),
                encoding: .utf8
            )
            #expect(onDisk == "main\n", "ours-side pointer bytes should be on disk")
        } else {
            // If git-lfs is unexpectedly installed AND the checkout
            // doesn't error on a non-LFS file, the test passes too —
            // the materialize step ran without complaining, which is
            // also valid. Surface a soft note so this isn't silently
            // masking a real bug.
            Issue.record(
                "expected lfsMaterializeFailed when forcing LFS on a non-LFS file; got state: \(state)"
            )
        }
    }

    @Test("a non-LFS conflict skips the LFS materialization step entirely")
    func nonLFSSkipsMaterialization() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "non-lfs")
        defer { cleanup(dir) }

        // Default ConflictProbes.none → classifier returns .text for
        // ordinary text conflicts. The LFS post-apply step doesn't fire.
        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        let conflict = try #require(await vm.conflicts.first)
        #expect(conflict.kind == .text)

        await vm.choose(path: "a.txt", .ours)
        await vm.applyOne(path: "a.txt")

        // Standard success path; no LFS-related failures.
        #expect(await vm.resolvedPaths.contains("a.txt"))
        #expect(await vm.state == .success(0))
    }
}
