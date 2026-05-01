import Foundation
@testable import RepoState
import Testing

@Suite("PathTrie — exact + nearest-ancestor lookup")
struct PathTrieTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    // MARK: empty trie

    @Test("empty trie returns nil for any lookup, count is zero")
    func emptyTrieIsEmpty() {
        let trie = PathTrie<String>()
        #expect(trie.count == 0)
        #expect(trie.value(at: url("/repo/file.txt")) == nil)
        #expect(trie.nearestValue(at: url("/repo/file.txt")) == nil)
    }

    // MARK: insert + exact lookup

    @Test("insert + exact lookup returns the inserted value")
    func insertExactLookup() {
        var trie = PathTrie<String>()
        trie.insert("clean", at: url("/repo/a.txt"))
        #expect(trie.value(at: url("/repo/a.txt")) == "clean")
        #expect(trie.count == 1)
    }

    @Test("re-inserting at the same path replaces the value, count unchanged")
    func reinsertReplaces() {
        var trie = PathTrie<String>()
        trie.insert("modified", at: url("/repo/a.txt"))
        trie.insert("staged", at: url("/repo/a.txt"))
        #expect(trie.value(at: url("/repo/a.txt")) == "staged")
        #expect(trie.count == 1)
    }

    @Test("multiple paths with shared prefix coexist independently")
    func sharedPrefixIndependence() {
        var trie = PathTrie<String>()
        trie.insert("a-value", at: url("/repo/dir/a.txt"))
        trie.insert("b-value", at: url("/repo/dir/b.txt"))
        trie.insert("c-value", at: url("/repo/other/c.txt"))
        #expect(trie.count == 3)
        #expect(trie.value(at: url("/repo/dir/a.txt")) == "a-value")
        #expect(trie.value(at: url("/repo/dir/b.txt")) == "b-value")
        #expect(trie.value(at: url("/repo/other/c.txt")) == "c-value")
        // Intermediate nodes have no values of their own.
        #expect(trie.value(at: url("/repo/dir")) == nil)
        #expect(trie.value(at: url("/repo")) == nil)
    }

    // MARK: nearest-ancestor lookup (the load-bearing badge query)

    @Test("nearestValue returns exact match when one exists")
    func nearestPrefersExactMatch() {
        var trie = PathTrie<String>()
        trie.insert("dir-value", at: url("/repo/dir"))
        trie.insert("file-value", at: url("/repo/dir/file.txt"))
        // Exact-match wins over the ancestor.
        #expect(trie.nearestValue(at: url("/repo/dir/file.txt")) == "file-value")
    }

    @Test("nearestValue inherits from the deepest ancestor when no exact match")
    func nearestInheritsFromAncestor() {
        var trie = PathTrie<String>()
        trie.insert("ignored", at: url("/repo/build"))
        // No entry for build/out.o — should inherit `ignored` from build/.
        #expect(trie.nearestValue(at: url("/repo/build/out.o")) == "ignored")
        #expect(trie.nearestValue(at: url("/repo/build/sub/deep.o")) == "ignored")
    }

    @Test("nearestValue picks the deepest ancestor among nested entries")
    func nearestPicksDeepestAncestor() {
        var trie = PathTrie<String>()
        trie.insert("repo-level", at: url("/repo"))
        trie.insert("nested-level", at: url("/repo/dir/sub"))
        // Deepest ancestor wins.
        #expect(trie.nearestValue(at: url("/repo/dir/sub/file.txt")) == "nested-level")
        // Falls back to higher level when no nearer ancestor has an entry.
        #expect(trie.nearestValue(at: url("/repo/dir/file.txt")) == "repo-level")
        #expect(trie.nearestValue(at: url("/repo/file.txt")) == "repo-level")
    }

    @Test("nearestValue returns nil when no ancestor matches")
    func nearestReturnsNilWithNoAncestor() {
        var trie = PathTrie<String>()
        trie.insert("repo-a", at: url("/repo-a/file.txt"))
        // Different repo entirely — no shared prefix.
        #expect(trie.nearestValue(at: url("/repo-b/file.txt")) == nil)
    }

    // MARK: ancestor-values walk (the load-bearing subscription lookup)

    @Test("ancestorValues on empty trie returns []")
    func ancestorValuesEmpty() {
        let trie = PathTrie<String>()
        #expect(trie.ancestorValues(at: url("/repo/file.txt")) == [])
    }

    @Test("ancestorValues collects every value along the path, root-first")
    func ancestorValuesRootFirst() {
        var trie = PathTrie<String>()
        trie.insert("repo-level", at: url("/repo"))
        trie.insert("dir-level", at: url("/repo/dir"))
        trie.insert("file-level", at: url("/repo/dir/file.txt"))
        #expect(
            trie.ancestorValues(at: url("/repo/dir/file.txt"))
                == ["repo-level", "dir-level", "file-level"]
        )
    }

    @Test("ancestorValues skips intermediate nodes that have no value")
    func ancestorValuesSkipsValuelessNodes() {
        var trie = PathTrie<String>()
        trie.insert("repo-level", at: url("/repo"))
        // No value at /repo/dir; routing-only.
        trie.insert("file-level", at: url("/repo/dir/file.txt"))
        #expect(
            trie.ancestorValues(at: url("/repo/dir/file.txt"))
                == ["repo-level", "file-level"]
        )
    }

    @Test("ancestorValues stops at the first missing path component")
    func ancestorValuesStopsAtMissing() {
        var trie = PathTrie<String>()
        trie.insert("repo-level", at: url("/repo"))
        trie.insert("dir-level", at: url("/repo/dir"))
        // Query path diverges after /repo/dir — the deeper "/repo/other"
        // segment isn't in the trie; we should still get the matched
        // ancestors, but no further values.
        #expect(
            trie.ancestorValues(at: url("/repo/dir/other/leaf"))
                == ["repo-level", "dir-level"]
        )
    }

    @Test("ancestorValues does not collect values stored deeper than the query path")
    func ancestorValuesIgnoresDescendants() {
        var trie = PathTrie<String>()
        trie.insert("repo-level", at: url("/repo"))
        trie.insert("deeper", at: url("/repo/dir/file.txt"))
        // Query at /repo/dir — `deeper` is at /repo/dir/file.txt, deeper
        // than the query path, so it must not appear.
        #expect(trie.ancestorValues(at: url("/repo/dir")) == ["repo-level"])
    }

    @Test("ancestorValues returns [] when the query shares no prefix with any entry")
    func ancestorValuesNoSharedPrefix() {
        var trie = PathTrie<String>()
        trie.insert("repo-a", at: url("/repo-a"))
        #expect(trie.ancestorValues(at: url("/repo-b/file.txt")) == [])
    }

    @Test("ancestorValues includes the value at the exact path when present")
    func ancestorValuesIncludesExact() {
        var trie = PathTrie<String>()
        trie.insert("exact", at: url("/repo/dir/file.txt"))
        #expect(trie.ancestorValues(at: url("/repo/dir/file.txt")) == ["exact"])
    }

    // MARK: removal

    @Test("remove returns the removed value and updates count")
    func removeReturnsValue() {
        var trie = PathTrie<String>()
        trie.insert("x", at: url("/repo/a.txt"))
        let removed = trie.remove(at: url("/repo/a.txt"))
        #expect(removed == "x")
        #expect(trie.count == 0)
        #expect(trie.value(at: url("/repo/a.txt")) == nil)
    }

    @Test("remove on a missing path is a no-op (returns nil, count unchanged)")
    func removeMissingIsNoop() {
        var trie = PathTrie<String>()
        trie.insert("x", at: url("/repo/a.txt"))
        let removed = trie.remove(at: url("/repo/never.txt"))
        #expect(removed == nil)
        #expect(trie.count == 1)
        #expect(trie.value(at: url("/repo/a.txt")) == "x")
    }

    @Test("remove preserves children at deeper paths")
    func removePreservesChildren() {
        var trie = PathTrie<String>()
        trie.insert("dir-value", at: url("/repo/dir"))
        trie.insert("file-value", at: url("/repo/dir/file.txt"))
        _ = trie.remove(at: url("/repo/dir"))
        #expect(trie.value(at: url("/repo/dir")) == nil)
        // The child survives — only the directory's own value is gone.
        #expect(trie.value(at: url("/repo/dir/file.txt")) == "file-value")
        // Nearest-ancestor walk now skips the (now valueless) `dir` node.
        #expect(trie.nearestValue(at: url("/repo/dir/other.txt")) == nil)
    }

    @Test("remove prunes empty leaf branches so inserts don't leak nodes")
    func removePrunesEmptyBranches() {
        var trie = PathTrie<String>()
        trie.insert("x", at: url("/a/b/c/d/e.txt"))
        _ = trie.remove(at: url("/a/b/c/d/e.txt"))
        #expect(trie.count == 0)
        // After full removal, re-inserting elsewhere shouldn't reuse stale
        // branch state. Nothing observable to assert beyond count, but the
        // round-trip exercises the prune-on-remove path.
        trie.insert("y", at: url("/a/b/y.txt"))
        #expect(trie.count == 1)
        #expect(trie.value(at: url("/a/b/y.txt")) == "y")
    }

    @Test("removeAll clears every entry in O(1)")
    func removeAllClears() {
        var trie = PathTrie<String>()
        for index in 0 ..< 50 {
            trie.insert("v\(index)", at: url("/repo/file_\(index).txt"))
        }
        #expect(trie.count == 50)
        trie.removeAll()
        #expect(trie.count == 0)
        #expect(trie.value(at: url("/repo/file_0.txt")) == nil)
    }

    // MARK: path normalization

    @Test("paths are normalized — `.` and `..` segments fold before lookup")
    func pathNormalization() {
        var trie = PathTrie<String>()
        trie.insert("v", at: url("/repo/dir/file.txt"))
        // `..` and `.` should fold to the same canonical path.
        #expect(trie.value(at: url("/repo/dir/./file.txt")) == "v")
        #expect(trie.value(at: url("/repo/other/../dir/file.txt")) == "v")
    }

    @Test("trailing slashes on directory paths don't affect lookups")
    func trailingSlashIgnored() {
        var trie = PathTrie<String>()
        trie.insert("dir-value", at: url("/repo/dir"))
        // URL(fileURLWithPath:) typically trims trailing slashes; if it
        // didn't, `decompose` would still skip the empty component.
        #expect(trie.value(at: url("/repo/dir/")) == "dir-value")
    }

    // MARK: value-type semantics

    @Test("PathTrie is a value type — copies are independent")
    func valueTypeSemantics() {
        var trieA = PathTrie<String>()
        trieA.insert("a", at: url("/repo/file.txt"))
        var trieB = trieA
        trieB.insert("b", at: url("/repo/other.txt"))
        // trieA shouldn't see trieB's later insertion.
        #expect(trieA.count == 1)
        #expect(trieA.value(at: url("/repo/other.txt")) == nil)
        #expect(trieB.count == 2)
        #expect(trieB.value(at: url("/repo/other.txt")) == "b")
    }
}
