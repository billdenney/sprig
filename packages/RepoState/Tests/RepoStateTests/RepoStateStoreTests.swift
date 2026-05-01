import Foundation
import GitCore
@testable import RepoState
import Testing

@Suite("RepoStateStore — apply + badge query")
struct RepoStateStoreTests {
    private let zero = String(repeating: "0", count: 40)

    private func makeRepoRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-store-\(UUID().uuidString)")
    }

    private func ordinary(index: StatusCode, worktree: StatusCode, path: String) -> Entry {
        .ordinary(Ordinary(
            xy: StatusXY(index: index, worktree: worktree),
            submodule: .notSubmodule,
            modeHead: 0o100644,
            modeIndex: 0o100644,
            modeWorktree: 0o100644,
            hashHead: zero,
            hashIndex: zero,
            path: path
        ))
    }

    private func status(
        branch: BranchInfo? = nil,
        stashCount: Int? = nil,
        entries: [Entry] = []
    ) -> PorcelainV2Status {
        PorcelainV2Status(branch: branch, stashCount: stashCount, entries: entries)
    }

    // MARK: empty / new store

    @Test("freshly initialized store reports nothing")
    func emptyStore() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        #expect(await store.entryCount() == 0)
        #expect(await store.branch() == nil)
        #expect(await store.stashCount() == nil)
        #expect(await store.badge(for: root.appendingPathComponent("anything.txt")) == nil)
    }

    @Test("repoRoot is preserved as a nonisolated property")
    func repoRootAccessor() {
        let root = URL(fileURLWithPath: "/tmp/sprig-test")
        let store = RepoStateStore(repoRoot: root)
        // No `await` — repoRoot is `nonisolated let`.
        #expect(store.repoRoot == root)
    }

    // MARK: apply()

    @Test("apply records branch info, stash count, and per-entry badges")
    func applyBasics() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        let snapshot = status(
            branch: BranchInfo(oid: zero, head: "main", upstream: "origin/main", ahead: 0, behind: 0),
            stashCount: 2,
            entries: [
                ordinary(index: .modified, worktree: .unmodified, path: "staged.txt"),
                ordinary(index: .unmodified, worktree: .modified, path: "modified.txt"),
                .untracked(path: "new.txt")
            ]
        )
        await store.apply(snapshot)

        #expect(await store.branch()?.head == "main")
        #expect(await store.branch()?.upstream == "origin/main")
        #expect(await store.stashCount() == 2)
        #expect(await store.entryCount() == 3)

        #expect(await store.badge(for: root.appendingPathComponent("staged.txt")) == .staged)
        #expect(await store.badge(for: root.appendingPathComponent("modified.txt")) == .modified)
        #expect(await store.badge(for: root.appendingPathComponent("new.txt")) == .untracked)
    }

    @Test("badge is nil for tracked-clean files (porcelain doesn't list them)")
    func cleanFilesUnreported() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [
            ordinary(index: .unmodified, worktree: .modified, path: "modified.txt")
        ]))
        // Clean files don't appear in porcelain output. The shell
        // extension reads "no badge" as "the file is clean."
        #expect(await store.badge(for: root.appendingPathComponent("untouched.txt")) == nil)
    }

    @Test("paths outside the worktree return nil")
    func outsideWorktreeIsNil() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [
            .untracked(path: "a.txt")
        ]))
        // A path that doesn't share a prefix with repoRoot has nothing
        // to inherit from.
        let elsewhere = URL(fileURLWithPath: "/var/tmp/somewhere-else/file.txt")
        #expect(await store.badge(for: elsewhere) == nil)
    }

    // MARK: ancestor inheritance via PathTrie.nearestValue

    @Test("ignored directory propagates badge to children via nearest-ancestor lookup")
    func ignoredDirInheritance() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        // Ignored entries from porcelain v2 typically come back as
        // either a directory ("build/") or per-file paths under it.
        // Either way, child paths should resolve via the trie.
        await store.apply(status(entries: [
            .ignored(path: "build")
        ]))

        #expect(await store.badge(for: root.appendingPathComponent("build")) == .ignored)
        // A child of `build/` with no entry of its own inherits from
        // the directory.
        #expect(await store.badge(for: root.appendingPathComponent("build/output.o")) == .ignored)
        #expect(await store.badge(for: root.appendingPathComponent("build/sub/deep.o")) == .ignored)
    }

    @Test("exact-path entries take priority over ancestor entries")
    func exactPathBeatsAncestor() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        // Both the directory and a child have entries — the child's
        // exact-match should win.
        await store.apply(status(entries: [
            .ignored(path: "build"),
            ordinary(index: .modified, worktree: .modified, path: "build/special.txt")
        ]))

        #expect(await store.badge(for: root.appendingPathComponent("build/special.txt")) == .modified)
        #expect(await store.badge(for: root.appendingPathComponent("build/other.o")) == .ignored)
    }

    // MARK: replace semantics

    @Test("apply replaces the previous snapshot rather than merging")
    func applyReplaces() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        // First snapshot: one untracked, one modified.
        await store.apply(status(entries: [
            .untracked(path: "a.txt"),
            ordinary(index: .unmodified, worktree: .modified, path: "b.txt")
        ]))
        #expect(await store.entryCount() == 2)

        // Second snapshot: only the new file. Old entries are gone.
        await store.apply(status(entries: [
            .untracked(path: "c.txt")
        ]))
        #expect(await store.entryCount() == 1)
        #expect(await store.badge(for: root.appendingPathComponent("a.txt")) == nil)
        #expect(await store.badge(for: root.appendingPathComponent("b.txt")) == nil)
        #expect(await store.badge(for: root.appendingPathComponent("c.txt")) == .untracked)
    }

    @Test("apply with an empty snapshot clears all badges and metadata")
    func applyEmptyClears() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(
            branch: BranchInfo(oid: zero, head: "main", upstream: nil, ahead: nil, behind: nil),
            stashCount: 1,
            entries: [.untracked(path: "x.txt")]
        ))
        #expect(await store.entryCount() == 1)

        // Clean snapshot (no entries, no stash).
        await store.apply(status())
        #expect(await store.entryCount() == 0)
        #expect(await store.branch() == nil)
        #expect(await store.stashCount() == nil)
    }

    // MARK: path normalization

    @Test("path queries fold `.` and `..` segments")
    func pathNormalization() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [
            .untracked(path: "dir/file.txt")
        ]))

        // Different but-equivalent paths should hit the same trie slot.
        let canonical = root.appendingPathComponent("dir/file.txt")
        let withDot = root.appendingPathComponent("dir/./file.txt")
        let withDotDot = root.appendingPathComponent("dir/sub/../file.txt")
        #expect(await store.badge(for: canonical) == .untracked)
        #expect(await store.badge(for: withDot) == .untracked)
        #expect(await store.badge(for: withDotDot) == .untracked)
    }

    // MARK: currentBadges() snapshot

    @Test("currentBadges returns an empty map on a fresh store")
    func currentBadgesEmpty() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        #expect(await store.currentBadges().isEmpty)
    }

    @Test("currentBadges round-trips every applied entry as an absolute URL")
    func currentBadgesRoundTrip() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [
            .untracked(path: "new.txt"),
            ordinary(index: .unmodified, worktree: .modified, path: "dir/edited.txt")
        ]))
        let snapshot = await store.currentBadges()
        #expect(snapshot.count == 2)
        #expect(snapshot[root.appendingPathComponent("new.txt").standardized] == .untracked)
        #expect(snapshot[root.appendingPathComponent("dir/edited.txt").standardized] == .modified)
    }

    // MARK: applyAndDiff()

    @Test("applyAndDiff against an empty store reports every new entry as nil → badge")
    func applyAndDiffFirstApply() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        let changes = await store.applyAndDiff(status(entries: [
            .untracked(path: "new.txt")
        ]))
        #expect(changes.count == 1)
        #expect(changes[0].path == root.appendingPathComponent("new.txt").standardized)
        #expect(changes[0].before == nil)
        #expect(changes[0].after == .untracked)
    }

    @Test("applyAndDiff reports nothing when the snapshot is identical to the prior one")
    func applyAndDiffNoChange() async {
        let root = makeRepoRoot()
        let store = RepoStateStore(repoRoot: root)
        let snap = status(entries: [.untracked(path: "x.txt")])
        await store.apply(snap)
        let changes = await store.applyAndDiff(snap)
        #expect(changes.isEmpty)
    }

    @Test("applyAndDiff captures cleared paths as before-non-nil → after-nil")
    func applyAndDiffCleared() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [.untracked(path: "x.txt")]))
        // The new snapshot has no entries — x.txt became clean.
        let changes = await store.applyAndDiff(status())
        #expect(changes.count == 1)
        #expect(changes[0].path == root.appendingPathComponent("x.txt").standardized)
        #expect(changes[0].before == .untracked)
        #expect(changes[0].after == nil)
    }

    @Test("applyAndDiff reports a transitioning badge with both before and after set")
    func applyAndDiffTransitionedBadge() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        await store.apply(status(entries: [.untracked(path: "x.txt")]))
        // Same path, different badge — became modified after staging.
        let changes = await store.applyAndDiff(status(entries: [
            ordinary(index: .added, worktree: .unmodified, path: "x.txt")
        ]))
        #expect(changes.count == 1)
        #expect(changes[0].path == root.appendingPathComponent("x.txt").standardized)
        #expect(changes[0].before == .untracked)
        #expect(changes[0].after == .added)
    }

    @Test("applyAndDiff returns changes sorted by path for stable iteration")
    func applyAndDiffSortedOutput() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        // Changes affecting multiple paths in non-alphabetic insert order.
        let changes = await store.applyAndDiff(status(entries: [
            .untracked(path: "z.txt"),
            .untracked(path: "a.txt"),
            .untracked(path: "m.txt")
        ]))
        let paths = changes.map(\.path.path)
        #expect(paths == paths.sorted())
    }

    @Test("applyAndDiff over an unrelated transition reports only the changed path")
    func applyAndDiffMixedSnapshot() async {
        let root = makeRepoRoot().standardized
        let store = RepoStateStore(repoRoot: root)
        // Initial: a untracked, b untracked.
        await store.apply(status(entries: [
            .untracked(path: "a.txt"),
            .untracked(path: "b.txt")
        ]))
        // Next: a still untracked, b became modified-staged, c is new.
        let changes = await store.applyAndDiff(status(entries: [
            .untracked(path: "a.txt"),
            ordinary(index: .added, worktree: .unmodified, path: "b.txt"),
            .untracked(path: "c.txt")
        ]))
        let byPath = Dictionary(uniqueKeysWithValues: changes.map {
            ($0.path.lastPathComponent, $0)
        })
        #expect(changes.count == 2)
        // a.txt didn't change → not in diff
        #expect(byPath["a.txt"] == nil)
        // b.txt transitioned untracked → added
        #expect(byPath["b.txt"]?.before == .untracked)
        #expect(byPath["b.txt"]?.after == .added)
        // c.txt newly appeared
        #expect(byPath["c.txt"]?.before == nil)
        #expect(byPath["c.txt"]?.after == .untracked)
    }
}
