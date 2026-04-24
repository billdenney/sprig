import Testing
import Foundation
@testable import GitCore

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
            "# branch.oid \(branchOid)",
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
        let record = "1 .M N... 100644 100644 100644 \(hashA) \(hashB) README.md"
        let data = bytes(record)
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
        #expect(entry.hashHead == hashA)
        #expect(entry.hashIndex == hashB)
        #expect(entry.path == "README.md")
    }

    @Test("ordinary entry: staged add (index A, worktree .)")
    func ordinaryStagedAdd() throws {
        let record = "1 A. N... 000000 100644 100644 \(hashZero) \(hashB) new.txt"
        let data = bytes(record)
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
        let record = "2 R. N... 100644 100644 100644 \(hashC) \(hashD) R100 new/path.swift"
        let data = bytes(record, "old/path.swift")
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
        let record = "2 C. N... 100644 100644 100644 \(hashC) \(hashD) C85 dupe.swift"
        let data = bytes(record, "orig.swift")
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
        let record = "u UU N... 100644 100644 100644 100644 \(hashC) \(hashD) \(hashE) conflict.txt"
        let data = bytes(record)
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
        let record = "1 .M SCM. 160000 160000 160000 \(hashA) \(hashB) vendor/lib"
        let data = bytes(record)
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
        let record = "1 .M N... 100644 100644 100644 \(hashA) \(hashB) docs/my notes and plans.md"
        let data = bytes(record)
        let status = try PorcelainV2Parser.parse(data)
        guard case .ordinary(let entry) = status.entries.first else {
            Issue.record("expected ordinary entry")
            return
        }
        #expect(entry.path == "docs/my notes and plans.md")
    }

    @Test("mixed entry stream round-trips")
    func mixedStream() throws {
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

    @Test("unknown entry prefix throws parseFailure")
    func unknownPrefix() {
        let data = bytes("Z bogus")
        #expect(throws: GitError.self) {
            _ = try PorcelainV2Parser.parse(data)
        }
    }

    @Test("malformed XY status throws parseFailure")
    func badXY() {
        let record = "1 XZ N... 100644 100644 100644 \(hashA) \(hashB) bad.txt"
        let data = bytes(record)
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
