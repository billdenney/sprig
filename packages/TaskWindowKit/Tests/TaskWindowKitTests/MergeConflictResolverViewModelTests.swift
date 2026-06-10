// MergeConflictResolverViewModelTests.swift
//
// Integration tests for MergeConflictResolverViewModel against a real
// repo with a real merge conflict. CLAUDE.md: spawn real git, no mocks.

@testable import ConflictKit
import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("MergeConflictResolverViewModel — integration against real git")
struct MergeConflictResolverViewModelTests {
    // MARK: - Fixture

    /// Build a repo in conflict state: main has a.txt edit "main",
    /// feature has a.txt edit "feat", merging feature into main
    /// fails with a conflict on a.txt.
    private func makeTextConflictRepo(tag: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-mcr-\(tag)-\(UUID().uuidString)")
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
        _ = try await runner.run(["commit", "-am", "feat-edit"])
        _ = try await runner.run(["checkout", "main"])
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["commit", "-am", "main-edit"])
        _ = try await runner.run(["merge", "feature"], throwOnNonZero: false)
        return (dir, runner)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func headSubject(_ runner: Runner) async throws -> String {
        let out = try await runner.run(["log", "-1", "--pretty=%s"])
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Pure ConflictedPathChoice tests

    @Test("ConflictedPathChoice.stage maps each case to the right stage number")
    func choiceStageMap() {
        #expect(ConflictedPathChoice.pending.stage == nil)
        #expect(ConflictedPathChoice.base.stage == 1)
        #expect(ConflictedPathChoice.ours.stage == 2)
        #expect(ConflictedPathChoice.theirs.stage == 3)
    }

    @Test("ConflictedPathChoice.isResolved is true for anything except .pending")
    func choiceIsResolved() {
        #expect(ConflictedPathChoice.pending.isResolved == false)
        #expect(ConflictedPathChoice.ours.isResolved)
        #expect(ConflictedPathChoice.theirs.isResolved)
        #expect(ConflictedPathChoice.base.isResolved)
    }

    // MARK: - Refresh

    @Test("refresh() loads + classifies the conflict inventory")
    func refreshLoadsConflicts() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "refresh")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        let conflicts = await vm.conflicts
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.entry.path == "a.txt")
        // Probes default to .none → text falls through to .text.
        #expect(conflict.kind == .text)

        let unresolved = await vm.unresolvedCount
        #expect(unresolved == 1)
        let resolved = await vm.isFullyResolved
        #expect(resolved == false)
    }

    @Test("refresh() drops stale choices when paths leave the conflict set")
    func refreshDropsStaleChoices() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "stale")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        #expect(await vm.choices["a.txt"] == .ours)

        // Abort the merge — a.txt is no longer conflicted.
        _ = try await runner.run(["merge", "--abort"])
        await vm.refresh()

        #expect(await vm.conflicts.isEmpty)
        #expect(await vm.choices["a.txt"] == nil)
    }

    // MARK: - Choice picking

    @Test("choose(path:_:) accepts known paths; ignores unknown ones")
    func chooseAcceptsKnownPaths() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "choose-known")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        #expect(await vm.choices["a.txt"] == .ours)

        await vm.choose(path: "nonexistent.txt", .ours)
        #expect(await vm.choices["nonexistent.txt"] == nil)
    }

    @Test("clearChoice(for:) drops the choice and any prior resolved-set entry")
    func clearChoice() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "clear-choice")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .theirs)
        await vm.applyOne(path: "a.txt")
        #expect(await vm.resolvedPaths.contains("a.txt"))

        await vm.clearChoice(for: "a.txt")
        #expect(await vm.choices["a.txt"] == nil)
        #expect(await vm.resolvedPaths.contains("a.txt") == false)
    }

    // MARK: - Apply

    @Test("applyOne(.ours) writes HEAD's content and stages it")
    func applyOursWritesHeadContent() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-ours")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        await vm.applyOne(path: "a.txt")

        // a.txt now matches the HEAD-side content ("main\n").
        let onDisk = try readFile(dir.appendingPathComponent("a.txt"))
        #expect(onDisk == "main\n")
        #expect(await vm.resolvedPaths.contains("a.txt"))
        // Inventory still has the conflict listed; the unresolved
        // count just drops to 0.
        #expect(await vm.unresolvedCount == 0)
        #expect(await vm.isFullyResolved)
    }

    @Test("applyOne(.theirs) writes the incoming content")
    func applyTheirsWritesIncomingContent() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-theirs")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .theirs)
        await vm.applyOne(path: "a.txt")

        let onDisk = try readFile(dir.appendingPathComponent("a.txt"))
        #expect(onDisk == "feat\n")
    }

    @Test("applyOne(.base) writes the common-ancestor content")
    func applyBaseWritesAncestorContent() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-base")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .base)
        await vm.applyOne(path: "a.txt")

        let onDisk = try readFile(dir.appendingPathComponent("a.txt"))
        #expect(onDisk == "seed\n")
    }

    @Test("applyOne with a .pending choice lands in .failure without writing")
    func applyPendingFails() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-pending")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.applyOne(path: "a.txt")

        if case let .failure(failure) = await vm.state {
            #expect(failure.description.contains("Pick a side"))
        } else {
            Issue.record("expected .failure for pending choice")
        }
        #expect(await vm.resolvedPaths.contains("a.txt") == false)
    }

    @Test("applyAll() walks every non-pending choice")
    func applyAllWalksAll() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-all")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        await vm.applyAll()

        #expect(await vm.resolvedPaths == Set(["a.txt"]))
        #expect(await vm.isFullyResolved)
    }

    @Test("applyAll() with no non-pending choices lands in .failure")
    func applyAllNoChoicesFails() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "apply-all-empty")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.applyAll()

        if case let .failure(failure) = await vm.state {
            #expect(failure.description == TaskWindowVocabulary.nothingToApply)
        } else {
            Issue.record("expected .failure when nothing to apply")
        }
    }

    // MARK: - Finalize + abort

    @Test("finalize() runs git commit and produces a merge commit when fully resolved")
    func finalizeProducesMergeCommit() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "finalize")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        await vm.applyAll()
        await vm.finalize()

        // HEAD's subject is the merge commit message git wrote
        // (something like "Merge branch 'feature' into main").
        let subject = try await headSubject(runner)
        #expect(subject.contains("Merge"))
        // No more conflicts after the commit.
        await vm.refresh()
        #expect(await vm.conflicts.isEmpty)
    }

    @Test("finalize() rejects when not fully resolved")
    func finalizeRejectsUnresolved() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "finalize-unres")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.finalize() // no choice made yet

        if case let .failure(failure) = await vm.state {
            #expect(failure.description.contains("still unresolved"))
        } else {
            Issue.record("expected .failure for unresolved finalize")
        }
    }

    @Test("abort() runs git merge --abort and clears inventory")
    func abortResetsMerge() async throws {
        let (dir, runner) = try await makeTextConflictRepo(tag: "abort")
        defer { cleanup(dir) }

        let vm = MergeConflictResolverViewModel(repoURL: dir, runner: runner)
        await vm.refresh()
        await vm.choose(path: "a.txt", .ours)
        await vm.abort()

        #expect(await vm.conflicts.isEmpty)
        #expect(await vm.choices.isEmpty)
        #expect(await vm.resolvedPaths.isEmpty)

        // HEAD subject is back to the pre-merge "main-edit" commit.
        let subject = try await headSubject(runner)
        #expect(subject == "main-edit")
    }
}
