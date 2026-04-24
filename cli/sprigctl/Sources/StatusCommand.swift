import ArgumentParser
import Foundation
import GitCore

/// `sprigctl status [--json] [path]` — dump a repo's porcelain-v2 state.
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print the repository's porcelain-v2 status."
    )

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    @Argument(help: "Repository path (defaults to current directory).")
    var path: String?

    func run() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let output = try await runner.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        let status = try PorcelainV2Parser.parse(output.stdout)

        if json {
            try emitJSON(status)
        } else {
            emitHuman(status, repoURL: repoURL)
        }
    }

    // MARK: human format

    private func emitHuman(_ status: PorcelainV2Status, repoURL: URL) {
        print("# repo: \(repoURL.path)")
        if let branch = status.branch {
            if let head = branch.head {
                print("# branch: \(head)")
            } else {
                print("# branch: (detached)")
            }
            if let oid = branch.oid {
                print("# oid: \(oid)")
            } else {
                print("# oid: (initial)")
            }
            if let upstream = branch.upstream {
                let ab = (branch.ahead, branch.behind)
                switch ab {
                case let (.some(a), .some(b)):
                    print("# upstream: \(upstream) (+\(a) -\(b))")
                default:
                    print("# upstream: \(upstream)")
                }
            }
        }
        if let stashCount = status.stashCount, stashCount > 0 {
            print("# stashes: \(stashCount)")
        }
        if status.entries.isEmpty {
            print("# (clean)")
            return
        }
        for entry in status.entries {
            print(formatEntry(entry))
        }
    }

    private func formatEntry(_ entry: Entry) -> String {
        switch entry {
        case let .ordinary(e):
            let xy = String(e.xy.index.rawValue) + String(e.xy.worktree.rawValue)
            return "\(xy)  \(e.path)"
        case let .renamed(e):
            let xy = String(e.xy.index.rawValue) + String(e.xy.worktree.rawValue)
            let marker = String(e.op.rawValue) + String(e.score)
            return "\(xy)  \(e.origPath) -> \(e.path) (\(marker))"
        case let .unmerged(e):
            let xy = String(e.xy.index.rawValue) + String(e.xy.worktree.rawValue)
            return "\(xy)  \(e.path)  [unmerged]"
        case let .untracked(path):
            return "??  \(path)"
        case let .ignored(path):
            return "!!  \(path)"
        }
    }

    // MARK: JSON format

    private func emitJSON(_ status: PorcelainV2Status) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let wire = StatusWire(status)
        let data = try encoder.encode(wire)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}

// MARK: - JSON wire format

//
// We deliberately don't make PorcelainV2Status itself Codable — its public
// API is modeled for Swift ergonomics, and the CLI's JSON is a separate
// serialization contract we version independently.

private struct StatusWire: Encodable {
    var branch: BranchWire?
    var stashCount: Int?
    var entries: [EntryWire]

    init(_ status: PorcelainV2Status) {
        self.branch = status.branch.map(BranchWire.init)
        self.stashCount = status.stashCount
        self.entries = status.entries.map(EntryWire.init)
    }
}

private struct BranchWire: Encodable {
    var oid: String?
    var head: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?

    init(_ branch: BranchInfo) {
        self.oid = branch.oid
        self.head = branch.head
        self.upstream = branch.upstream
        self.ahead = branch.ahead
        self.behind = branch.behind
    }
}

private struct EntryWire: Encodable {
    var kind: String
    var xy: String?
    var path: String
    var origPath: String?
    var score: Int?
    var op: String?
    var submodule: SubmoduleWire?
    var modeHead: String?
    var modeIndex: String?
    var modeWorktree: String?
    var hashHead: String?
    var hashIndex: String?
    var modeStage1: String?
    var modeStage2: String?
    var modeStage3: String?
    var hashStage1: String?
    var hashStage2: String?
    var hashStage3: String?

    init(_ entry: Entry) {
        switch entry {
        case let .ordinary(e):
            self.kind = "ordinary"
            self.xy = xyString(e.xy)
            self.path = e.path
            self.submodule = SubmoduleWire(e.submodule)
            self.modeHead = octal(e.modeHead)
            self.modeIndex = octal(e.modeIndex)
            self.modeWorktree = octal(e.modeWorktree)
            self.hashHead = e.hashHead
            self.hashIndex = e.hashIndex
        case let .renamed(e):
            self.kind = "renamed"
            self.xy = xyString(e.xy)
            self.path = e.path
            self.origPath = e.origPath
            self.op = String(e.op.rawValue)
            self.score = e.score
            self.submodule = SubmoduleWire(e.submodule)
            self.modeHead = octal(e.modeHead)
            self.modeIndex = octal(e.modeIndex)
            self.modeWorktree = octal(e.modeWorktree)
            self.hashHead = e.hashHead
            self.hashIndex = e.hashIndex
        case let .unmerged(e):
            self.kind = "unmerged"
            self.xy = xyString(e.xy)
            self.path = e.path
            self.submodule = SubmoduleWire(e.submodule)
            self.modeStage1 = octal(e.modeStage1)
            self.modeStage2 = octal(e.modeStage2)
            self.modeStage3 = octal(e.modeStage3)
            self.modeWorktree = octal(e.modeWorktree)
            self.hashStage1 = e.hashStage1
            self.hashStage2 = e.hashStage2
            self.hashStage3 = e.hashStage3
        case let .untracked(path):
            self.kind = "untracked"
            self.path = path
        case let .ignored(path):
            self.kind = "ignored"
            self.path = path
        }
    }
}

private struct SubmoduleWire: Encodable {
    var isSubmodule: Bool
    var commitChanged: Bool
    var trackedModified: Bool
    var untrackedModified: Bool

    init(_ state: SubmoduleState) {
        self.isSubmodule = state.isSubmodule
        self.commitChanged = state.commitChanged
        self.trackedModified = state.trackedModified
        self.untrackedModified = state.untrackedModified
    }
}

private func xyString(_ xy: StatusXY) -> String {
    String(xy.index.rawValue) + String(xy.worktree.rawValue)
}

private func octal(_ mode: UInt32) -> String {
    String(mode, radix: 8)
}
