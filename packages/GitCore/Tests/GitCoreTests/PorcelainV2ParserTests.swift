import Foundation
@testable import GitCore
import Testing

@Suite("PorcelainV2Parser — synthesized fixtures")
struct PorcelainV2ParserTests {
    // MARK: Helpers

    /// Realistic 40-char object hashes for fixtures. Keeping these as
    /// constants lets individual fixture records stay under 140 chars.
    private let hashA = String(repeating: "1", count: 40)
    private let hashB = String(repeating: "2", count: 40)
    private let hashC = "aaaa" + String(repeating: "0", count: 36)
    private let hashD = "bbbb" + String(repeating: "0", count: 36)
    private let hashE = "cccc" + String(repeating: "0", count: 36)
    private let hashZero = String(repeating: "0", count: 40)
    private let branchOid = "abcdef1234567890abcdef1234567890abcdef12"

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

    @Test
    func `empty input yields empty status`() throws {
        let status = try PorcelainV2Parser.parse(Data())
        #expect(status.branch == nil)
        #expect(status.entries.isEmpty)
        #expect(status.stashCount == nil)
    }

    @Test
    func `only headers, no entries`() throws {
        let data = bytes(
            "# branch.oid \(branchOid)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -1"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.oid == branchOid)
        #expect(status.branch?.head == "main")
        #expect(status.branch?.upstream == "origin/main")
        #expect(status.branch?.ahead == 3)
        #expect(status.branch?.behind == 1)
        #expect(status.entries.isEmpty)
    }

    @Test
    func `initial commit — oid is (initial), head is the branch name`() throws {
        let data = bytes(
            "# branch.oid (initial)",
            "# branch.head main"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.oid == nil)
        #expect(status.branch?.head == "main")
    }

    @Test
    func `detached HEAD — head is (detached)`() throws {
        let data = bytes(
            "# branch.oid \(branchOid)",
            "# branch.head (detached)"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.head == nil)
        #expect(status.branch?.oid != nil)
    }

    @Test
    func `stash header parsed into stashCount`() throws {
        let data = bytes("# stash 4")
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.stashCount == 4)
    }

    // MARK: Entry types

    @Test
    func `ordinary entry: modified in worktree`() throws {
        let record = "1 .M N... 100644 100644 100644 \(hashA) \(hashB) README.md"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case let .ordinary(entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.xy.index == .unmodified)
        #expect(entry.xy.worktree == .modified)
        #expect(entry.submodule == .notSubmodule)
        #expect(entry.modeHead == 0o100644)
        #expect(entry.modeIndex == 0o100644)
        #expect(entry.modeWorktree == 0o100644)
        #expect(entry.hashHead == hashA)
        #expect(entry.hashIndex == hashB)
        #expect(entry.path == "README.md")
    }

    @Test
    func `ordinary entry: staged add (index A, worktree .)`() throws {
        let record = "1 A. N... 000000 100644 100644 \(hashZero) \(hashB) new.txt"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case let .ordinary(entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.xy.index == .added)
        #expect(entry.xy.worktree == .unmodified)
        #expect(entry.modeHead == 0)
    }

    @Test
    func `renamed entry: consumes the extra origPath record`() throws {
        let record = "2 R. N... 100644 100644 100644 \(hashC) \(hashD) R100 new/path.swift"
        let data = bytes(record, "old/path.swift")
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.entries.count == 1)
        guard case let .renamed(entry) = status.entries.first else {
            Issue.record("expected renamed entry")
            return
        }
        #expect(entry.op == .renamed)
        #expect(entry.score == 100)
        #expect(entry.path == "new/path.swift")
        #expect(entry.origPath == "old/path.swift")
    }

    @Test
    func `copied entry: op=C with partial score`() throws {
        let record = "2 C. N... 100644 100644 100644 \(hashC) \(hashD) C85 dupe.swift"
        let data = bytes(record, "orig.swift")
        let status = try PorcelainV2Parser.parse(data)
        guard case let .renamed(entry) = status.entries.first else {
            Issue.record("expected renamed entry (copy variant)")
            return
        }
        #expect(entry.op == .copied)
        #expect(entry.score == 85)
    }

    @Test
    func `unmerged entry: both sides modified (UU)`() throws {
        let record = "u UU N... 100644 100644 100644 100644 \(hashC) \(hashD) \(hashE) conflict.txt"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case let .unmerged(entry) = status.entries.first else {
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

    @Test
    func `untracked and ignored entries`() throws {
        let data = bytes(
            "? new-file.txt",
            "! .DS_Store"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.entries.count == 2)
        #expect(status.entries[0] == .untracked(path: "new-file.txt"))
        #expect(status.entries[1] == .ignored(path: ".DS_Store"))
    }

    @Test
    func `submodule state: S with commit-changed and tracked-modified`() throws {
        let record = "1 .M SCM. 160000 160000 160000 \(hashA) \(hashB) vendor/lib"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case let .ordinary(entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.submodule.isSubmodule)
        #expect(entry.submodule.commitChanged)
        #expect(entry.submodule.trackedModified)
        #expect(!entry.submodule.untrackedModified)
    }

    @Test
    func `paths with spaces are preserved whole (last field captures everything)`() throws {
        let record = "1 .M N... 100644 100644 100644 \(hashA) \(hashB) docs/my notes and plans.md"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case let .ordinary(entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.path == "docs/my notes and plans.md")
    }

    @Test
    func `mixed entry stream round-trips`() throws {
        let ordinary = "1 .M N... 100644 100644 100644 \(hashA) \(hashB) changed.txt"
        let renamed = "2 R. N... 100644 100644 100644 \(hashC) \(hashD) R100 renamed/new.txt"
        let unmerged = "u UU N... 100644 100644 100644 100644 \(hashC) \(hashD) \(hashE) conflict.txt"
        let data = bytes(
            "# branch.oid \(branchOid)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +0 -0",
            "# stash 1",
            ordinary,
            renamed,
            "renamed/old.txt",
            unmerged,
            "? untracked.txt",
            "! ignored.log"
        )
        let status = try PorcelainV2Parser.parse(data)
        #expect(status.branch?.head == "main")
        #expect(status.stashCount == 1)
        #expect(status.entries.count == 5)
    }

    // MARK: Malformed input

    @Test
    func `unknown entry prefix throws parseFailure`() {
        let data = bytes("Z bogus")
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test
    func `malformed XY status throws parseFailure`() {
        let record = "1 XZ N... 100644 100644 100644 \(hashA) \(hashB) bad.txt"
        let data = bytes(record)
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test
    func `malformed branch.ab throws parseFailure`() {
        let data = bytes("# branch.ab garbage")
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test
    func `unknown headers are tolerated (forward-compat)`() throws {
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
