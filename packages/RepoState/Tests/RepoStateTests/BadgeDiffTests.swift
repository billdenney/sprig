import Foundation
@testable import RepoState
import Testing

@Suite("BadgeDiff — pure two-snapshot diff")
struct BadgeDiffTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardized
    }

    // MARK: empty inputs

    @Test("empty before + empty after → no changes")
    func emptyEmpty() {
        #expect(BadgeDiff.compute(before: [:], after: [:]).isEmpty)
    }

    @Test("empty before + populated after reports every entry as nil → badge")
    func firstSnapshotReportsAdditions() {
        let after: [URL: BadgeIdentifier] = [
            url("/repo/a"): .untracked,
            url("/repo/b"): .modified
        ]
        let changes = BadgeDiff.compute(before: [:], after: after)
        #expect(changes.count == 2)
        for change in changes {
            #expect(change.before == nil)
        }
        let badges = changes.map(\.after)
        #expect(badges.contains(.untracked))
        #expect(badges.contains(.modified))
    }

    @Test("populated before + empty after reports every entry as badge → nil")
    func clearedSnapshotReportsRemovals() {
        let before: [URL: BadgeIdentifier] = [
            url("/repo/a"): .untracked,
            url("/repo/b"): .modified
        ]
        let changes = BadgeDiff.compute(before: before, after: [:])
        #expect(changes.count == 2)
        for change in changes {
            #expect(change.after == nil)
        }
    }

    // MARK: identical inputs

    @Test("identical before + after reports no changes")
    func identicalNoChange() {
        let snap: [URL: BadgeIdentifier] = [
            url("/repo/a"): .untracked,
            url("/repo/b"): .modified
        ]
        #expect(BadgeDiff.compute(before: snap, after: snap).isEmpty)
    }

    // MARK: per-path transitions

    @Test("a path's badge change appears with both before and after set")
    func badgeTransition() {
        let path = url("/repo/x")
        let changes = BadgeDiff.compute(
            before: [path: .untracked],
            after: [path: .added]
        )
        #expect(changes.count == 1)
        #expect(changes[0].path == path)
        #expect(changes[0].before == .untracked)
        #expect(changes[0].after == .added)
    }

    @Test("a path that disappears reports before-non-nil → after-nil")
    func pathRemoved() {
        let path = url("/repo/x")
        let changes = BadgeDiff.compute(
            before: [path: .modified],
            after: [:]
        )
        #expect(changes.count == 1)
        #expect(changes[0].path == path)
        #expect(changes[0].before == .modified)
        #expect(changes[0].after == nil)
    }

    @Test("a path that appears reports before-nil → after-non-nil")
    func pathAdded() {
        let path = url("/repo/x")
        let changes = BadgeDiff.compute(
            before: [:],
            after: [path: .modified]
        )
        #expect(changes.count == 1)
        #expect(changes[0].path == path)
        #expect(changes[0].before == nil)
        #expect(changes[0].after == .modified)
    }

    // MARK: mixed snapshots

    @Test("a mix of unchanged + added + removed + transitioned reports only the changes")
    func mixedSnapshotChangesOnly() {
        let before: [URL: BadgeIdentifier] = [
            url("/repo/unchanged"): .untracked,
            url("/repo/removed"): .modified,
            url("/repo/transitioned"): .untracked
        ]
        let after: [URL: BadgeIdentifier] = [
            url("/repo/unchanged"): .untracked,
            url("/repo/added"): .modified,
            url("/repo/transitioned"): .added
        ]
        let changes = BadgeDiff.compute(before: before, after: after)
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        #expect(changes.count == 3)
        // unchanged absent
        #expect(byPath[url("/repo/unchanged")] == nil)
        // removed: badge → nil
        #expect(byPath[url("/repo/removed")]?.before == .modified)
        #expect(byPath[url("/repo/removed")]?.after == nil)
        // added: nil → badge
        #expect(byPath[url("/repo/added")]?.before == nil)
        #expect(byPath[url("/repo/added")]?.after == .modified)
        // transitioned: badge → other-badge
        #expect(byPath[url("/repo/transitioned")]?.before == .untracked)
        #expect(byPath[url("/repo/transitioned")]?.after == .added)
    }

    // MARK: ordering

    @Test("compute returns changes sorted by path for deterministic iteration")
    func outputSortedByPath() {
        let before: [URL: BadgeIdentifier] = [:]
        let after: [URL: BadgeIdentifier] = [
            url("/repo/zeta"): .modified,
            url("/repo/alpha"): .untracked,
            url("/repo/middle"): .added
        ]
        let changes = BadgeDiff.compute(before: before, after: after)
        let paths = changes.map(\.path.path)
        #expect(paths == paths.sorted())
    }

    // MARK: PathBadgeChange Equatable

    @Test("PathBadgeChange equality compares all three fields")
    func pathBadgeChangeEquatable() {
        let path = url("/repo/x")
        let a = PathBadgeChange(path: path, before: .untracked, after: .added)
        let b = PathBadgeChange(path: path, before: .untracked, after: .added)
        let c = PathBadgeChange(path: path, before: .untracked, after: .modified)
        #expect(a == b)
        #expect(a != c)
    }
}
