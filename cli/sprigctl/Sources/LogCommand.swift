import ArgumentParser
import Foundation
import GitCore

/// `sprigctl log [--max N] [--json] [<path>]` — print recent commits.
///
/// Wraps `git log -z --format=<LogParser.formatString>` and parses with
/// ``GitCore/LogParser``. Human output is one line per commit; `--json`
/// emits a wire-format array suitable for piping into other tooling.
struct LogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Print recent commits."
    )

    @Argument(help: "Repository path (defaults to current directory).")
    var path: String?

    @Option(name: .long, help: "Maximum number of commits to print. Default 20.")
    var max: Int = 20

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        let runner = Runner(defaultWorkingDirectory: repoURL)

        let output = try await runner.run([
            "log",
            "-n", String(max),
            "-z",
            "--format=\(LogParser.formatString)"
        ])
        let commits = try LogParser.parse(output.stdout)

        if json {
            try emitJSON(commits)
        } else {
            emitHuman(commits)
        }
    }

    // MARK: - rendering

    private func emitHuman(_ commits: [Commit]) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        for commit in commits {
            let mergeMarker = commit.isMerge ? " [merge]" : ""
            let date = dateFormatter.string(from: commit.committerDate)
            print("\(commit.shortSHA)  \(commit.subject)\(mergeMarker)")
            print("           \(commit.author.name) <\(commit.author.email)>  \(date)")
        }
    }

    private func emitJSON(_ commits: [Commit]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let wire = commits.map(CommitWire.init)
        let data = try encoder.encode(wire)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}

// MARK: - JSON wire format

//
// Same pattern as StatusCommand: keep the JSON contract distinct from the
// public Swift types so the JSON shape can evolve independently.

private struct CommitWire: Encodable {
    let sha: String
    let parents: [String]
    let author: IdentityWire
    let committer: IdentityWire
    let authorDate: Date
    let committerDate: Date
    let subject: String
    let body: String
    let isMerge: Bool

    init(_ commit: Commit) {
        self.sha = commit.sha
        self.parents = commit.parents
        self.author = IdentityWire(commit.author)
        self.committer = IdentityWire(commit.committer)
        self.authorDate = commit.authorDate
        self.committerDate = commit.committerDate
        self.subject = commit.subject
        self.body = commit.body
        self.isMerge = commit.isMerge
    }
}

private struct IdentityWire: Encodable {
    let name: String
    let email: String

    init(_ identity: Identity) {
        self.name = identity.name
        self.email = identity.email
    }
}
