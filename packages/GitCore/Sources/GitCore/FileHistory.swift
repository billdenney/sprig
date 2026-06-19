// FileHistory.swift
//
// ADR 0090 — per-file version history, the engine behind the beginner
// "Show History… / Restore Previous Version…" surface (the SharePoint
// "version history" framing of the planned blame/file-history machinery).
//
// `revisions(of:)` walks `git log --follow -z -- <path>` so the lineage
// survives renames; each revision records the file's path AS IT WAS at
// that commit (`--name-status`), because a blob read at an old revision
// must use the historical name — `<oldsha>:<currentpath>` fails once the
// file has been renamed. `contents(of:using:)` then reads that
// revision's blob through the long-lived `CatFileBatch` (the documented
// foundation for history/blame viewers, per docs/architecture/git-backend.md).
//
// `-z` is load-bearing, not just tidy: without it `git log --name-status`
// C-quotes paths with non-ASCII/control bytes (`café.txt` →
// `"caf\303\251.txt"`), which would feed a bogus `<sha>:<quoted>` to
// cat-file and break show/restore for accented / CJK / emoji filenames.
// `-z` emits raw, unquoted path bytes — the same reason every other
// path-parsing site in the repo uses it (PorcelainV2Parser, LogParser).
//
// Tier 1, portable. All git access via ``Runner`` / ``CatFileBatch``.
//
// `--follow` rename detection is a heuristic (git's own); surface the
// lineage it reports rather than implying a perfect one (ADR 0090).

import Foundation

/// One revision in a single file's history.
public struct FileRevision: Sendable, Equatable {
    /// Commit SHA where this version of the file appears.
    public let commitSHA: String
    /// Author name (`%aN`).
    public let author: String
    /// Author date, strict ISO 8601 (`%aI`).
    public let authorDate: String
    /// Commit subject (`%s`).
    public let subject: String
    /// The file's path AT THIS revision. Differs from the queried path
    /// across a rename (git's `--follow` lineage), and is what a blob
    /// read at ``commitSHA`` must use.
    public let pathAtRevision: String

    public init(
        commitSHA: String,
        author: String,
        authorDate: String,
        subject: String,
        pathAtRevision: String
    ) {
        self.commitSHA = commitSHA
        self.author = author
        self.authorDate = authorDate
        self.subject = subject
        self.pathAtRevision = pathAtRevision
    }

    /// The `<sha>:<path>` object name that reads this revision's blob.
    public var blobObjectName: String {
        "\(commitSHA):\(pathAtRevision)"
    }
}

/// Per-file history reads over `git log --follow` + `CatFileBatch`.
public struct FileHistory: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    // ASCII record/unit separators keep the format unambiguous even when
    // a subject or author contains spaces; the `--name-status` block
    // follows each formatted header.
    private static let recordSeparator = "\u{1e}"
    private static let unitSeparator = "\u{1f}"
    private static var logFormat: String {
        "\(recordSeparator)%H\(unitSeparator)%aN\(unitSeparator)%aI\(unitSeparator)%s"
    }

    /// The file's revisions, newest first, following renames. Empty when
    /// the path has no tracked history.
    public func revisions(of path: String) async throws -> [FileRevision] {
        let result = try await runner.run([
            "log",
            "--follow",
            "-z",
            "--name-status",
            "--format=\(Self.logFormat)",
            "--",
            path
        ])
        return Self.parse(result.stdoutString, queriedPath: path)
    }

    /// Read a revision's blob bytes through `catFile` (reused across
    /// revisions by the caller).
    public func contents(of revision: FileRevision, using catFile: CatFileBatch) async throws -> Data {
        try await catFile.read(revision.blobObjectName).content
    }

    // MARK: - Parsing

    /// Parse the `-z --name-status` stream into revisions. Each record
    /// starts with the record separator, then the NUL-terminated header
    /// `<sha>US<author>US<date>US<subject>`, then the name-status fields
    /// (status code, then path(s)), each NUL-separated. The file's path
    /// at that commit is the LAST non-empty name-status field — the new
    /// name for a rename (`R<score> NUL old NUL new`), the only name
    /// otherwise. `-z` paths are raw and unquoted, so non-ASCII names
    /// survive intact.
    static func parse(_ text: String, queriedPath: String) -> [FileRevision] {
        var revisions: [FileRevision] = []
        for record in text.components(separatedBy: recordSeparator) where !record.isEmpty {
            let fields = record.components(separatedBy: "\u{0}")
            guard let header = fields.first else { continue }
            // Split the header into exactly four fields; a subject that
            // happens to contain a unit separator stays whole (maxSplits).
            let head = header
                .split(separator: Character(unitSeparator), maxSplits: 3, omittingEmptySubsequences: false)
                .map(String.init)
            guard head.count == 4 else { continue }
            let pathAtRevision = fields.dropFirst().last { !$0.isEmpty } ?? queriedPath
            revisions.append(FileRevision(
                commitSHA: head[0],
                author: head[1],
                authorDate: head[2],
                subject: head[3],
                pathAtRevision: pathAtRevision
            ))
        }
        return revisions
    }
}
