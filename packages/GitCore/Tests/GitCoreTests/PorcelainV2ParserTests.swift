import Testing
import Foundation
@testable import GitCore

@Suite("PorcelainV2Parser — synthesized fixtures")
struct PorcelainV2ParserTests {
    // MARK: Helpers

    /// Build a buffer from records separated by NUL, with a trailing NUL.
    /// Matches git's actual `-z` output layout.
    private func bytes(_ records: String...) -> Data {
        var data = Data()
        for record in records {
            data.append(record.data(using: .utf8)!)
            data.append(0)
        }
        return data
    }

    // MARK: Empty / trivial cases

    @Test("empty input yields empty status")
    func emptyInput() throws {
        let status = try PorcelainV2Parser.parse(Data())
        #expect(status.branch == nil)
        #expect(status.entries.isEmpty)
        #expect(status.stashCount == nil)
    }

    @Test("only headers, no entries")
    func onlyHeaders() throws {
        let data = bytes(
            "# branch.oid abcdef1234567890abcdef1234567890abcdef12",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -1"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.oid == "abcdef1234567890abcdef1234567890abcdef12")
        #expect(status.branch?.head == "main")
        #expect(status.branch?.upstream == "origin/main")
        #expect(status.branch?.ahead == 3)
        #expect(status.branch?.behind == 1)
        #expect(status.entries.isEmpty)
    }

    @Test("initial commit — oid is (initial), head is the branch name")
    func initialCommit() throws {
        let data = bytes(
            "# branch.oid (initial)",
            "# branch.head main"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.oid == nil)
        #expect(status.branch?.head == "main")
    }

    @Test("detached HEAD — head is (detached)")
    func detachedHead() throws {
        let data = bytes(
            "# branch.oid abcdef1234567890abcdef1234567890abcdef12",
            "# branch.head (detached)"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.head == nil)
        #expect(status.branch?.oid != nil)
    }

    @Test("stash header parsed into stashCount")
    func stashCount() throws {
        let data = bytes("# stash 4")
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.stashCount == 4)
    }

    // MARK: Entry types

    @Test("ordinary entry: modified in worktree")
    func ordinaryModified() throws {
        let data = bytes(
            "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 README.md"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .ordinary(let entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.xy.index == .unmodified)
        #expect(entry.xy.worktree == .modified)
        #expect(entry.submodule == .notSubmodule)
        #expect(entry.modeHead == 0o100644)
        #expect(entry.modeIndex == 0o100644)
        #expect(entry.modeWorktree == 0o100644)
        #expect(entry.hashHead == "1111111111111111111111111111111111111111")
        #expect(entry.hashIndex == "2222222222222222222222222222222222222222")
        #expect(entry.path == "README.md")
    }

    @Test("ordinary entry: staged add (index A, worktree .)")
    func ordinaryStagedAdd() throws {
        let data = bytes(
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 2222222222222222222222222222222222222222 new.txt"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .ordinary(let entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.xy.index == .added)
        #expect(entry.xy.worktree == .unmodified)
        #expect(entry.modeHead == 0)
    }

    @Test("renamed entry: consumes the extra origPath record")
    func renamedConsumesOrigPath() throws {
        let data = bytes(
            "2 R. N... 100644 100644 100644 aaaa000000000000000000000000000000000000 bbbb000000000000000000000000000000000000 R100 new/path.swift",
            "old/path.swift"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.entries.count == 1)
        guard case .renamed(let entry) = status.entries.first else {
            Issue.record("expected renamed entry")
            return
        }
        #expect(entry.op == .renamed)
        #expect(entry.score == 100)
        #expect(entry.path == "new/path.swift")
        #expect(entry.origPath == "old/path.swift")
    }

    @Test("copied entry: op=C with partial score")
    func copiedEntry() throws {
        let data = bytes(
            "2 C. N... 100644 100644 100644 aaaa000000000000000000000000000000000000 bbbb000000000000000000000000000000000000 C85 dupe.swift",
            "orig.swift"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .renamed(let entry) = status.entries.first else {
            Issue.record("expected renamed entry (copy variant)")
            return
        }
        #expect(entry.op == .copied)
        #expect(entry.score == 85)
    }

    @Test("unmerged entry: both sides modified (UU)")
    func unmergedBothModified() throws {
        let data = bytes(
            "u UU N... 100644 100644 100644 100644 aaaa000000000000000000000000000000000000 bbbb000000000000000000000000000000000000 cccc000000000000000000000000000000000000 conflict.txt"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .unmerged(let entry) = status.entries.first else {
            Issue.record("expected unmerged entry")
            return
        }
        #expect(entry.xy.index == .updatedUnmerged)
        #expect(entry.xy.worktree == .updatedUnmerged)
        #expect(entry.hashStage1.hasPrefix("aaaa"))
        #expect(entry.hashStage2.hasPrefix("bbbb"))
        #expect(entry.hashStage3.hasPrefix("cccc"))
        #expect(entry.path == "conflict.txt")
    }

    @Test("untracked and ignored entries")
    func untrackedAndIgnored() throws {
        let data = bytes(
            "? new-file.txt",
            "! .DS_Store"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.entries.count == 2)
        #expect(status.entries[0] == .untracked(path: "new-file.txt"))
        #expect(status.entries[1] == .ignored(path: ".DS_Store"))
    }

    @Test("submodule state: S with commit-changed and tracked-modified")
    func submoduleStatePartialFlags() throws {
        let data = bytes(
            "1 .M SCM. 160000 160000 160000 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 vendor/lib"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .ordinary(let entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.submodule.isSubmodule)
        #expect(entry.submodule.commitChanged)
        #expect(entry.submodule.trackedModified)
        #expect(!entry.submodule.untrackedModified)
    }

    @Test("paths with spaces are preserved whole (last field captures everything)")
    func pathWithSpaces() throws {
        let data = bytes(
            "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 docs/my notes and plans.md"
        )
        let status = try PorcelainV2Parser.parse(data)
        guard case .ordinary(let entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.path == "docs/my notes and plans.md")
    }

    @Test("mixed entry stream round-trips")
    func mixedStream() throws {
        let data = bytes(
            "# branch.oid abcdef1234567890abcdef1234567890abcdef12",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +0 -0",
            "# stash 1",
            "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 changed.txt",
            "2 R. N... 100644 100644 100644 aaaa000000000000000000000000000000000000 bbbb000000000000000000000000000000000000 R100 renamed/new.txt",
            "renamed/old.txt",
            "u UU N... 100644 100644 100644 100644 aaaa000000000000000000000000000000000000 bbbb000000000000000000000000000000000000 cccc000000000000000000000000000000000000 conflict.txt",
            "? untracked.txt",
            "! ignored.log"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.head == "main")
        #expect(status.stashCount == 1)
        #expect(status.entries.count == 5)
    }

    // MARK: Malformed input

    @Test("unknown entry prefix throws parseFailure")
    func unknownPrefix() {
        let data = bytes("Z bogus")
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test("malformed XY status throws parseFailure")
    func badXY() {
        let data = bytes(
            "1 XZ N... 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 bad.txt"
        )
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test("malformed branch.ab throws parseFailure")
    func badBranchAB() {
        let data = bytes("# branch.ab garbage")
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test("unknown headers are tolerated (forward-compat)")
    func unknownHeaderTolerated() throws {
        let data = bytes(
            "# branch.head main",
            "# branch.future-thing hello",
            "? file.txt"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.head == "main")
        #expect(status.entries.count == 1)
    }
}
