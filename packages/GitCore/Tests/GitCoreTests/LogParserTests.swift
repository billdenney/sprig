import Foundation
@testable import GitCore
import Testing

@Suite("LogParser — synthesized fixtures")
struct LogParserTests {
    private let sha40 = String(repeating: "a", count: 40)
    private let parentSHA = String(repeating: "b", count: 40)

    /// Build one entry's worth of bytes. Pass overrides for the fields you
    /// care about; everything else gets a sensible default. Mirrors what
    /// `git log -z --format=<formatString>` emits per entry.
    private struct Entry {
        var sha: String
        var parents: String = ""
        var authorDate: String = "2026-01-01T00:00:00Z"
        var committerDate: String = "2026-01-01T00:00:00Z"
        var authorName: String = "x"
        var authorEmail: String = "x@x.com"
        var committerName: String = "x"
        var committerEmail: String = "x@x.com"
        var subject: String = "subj"
        var body: String = "subj\n"

        var bytes: Data {
            let us = "\u{001F}"
            let joined = [
                sha, parents, authorDate, committerDate,
                authorName, authorEmail, committerName, committerEmail,
                subject, body
            ].joined(separator: us)
            return Data(joined.utf8) + Data([0x00])
        }
    }

    @Test("empty input parses to empty array")
    func emptyInputYieldsEmpty() throws {
        #expect(try LogParser.parse(Data()).isEmpty)
    }

    @Test("single commit round-trips through parser")
    func singleCommit() throws {
        let bytes = Entry(
            sha: sha40,
            parents: parentSHA,
            authorDate: "2026-01-15T10:30:00Z",
            committerDate: "2026-01-15T10:30:00Z",
            authorName: "Alice Author",
            authorEmail: "alice@example.com",
            committerName: "Alice Author",
            committerEmail: "alice@example.com",
            subject: "Add hello world",
            body: "Add hello world\n\nLonger explanation.\n"
        ).bytes
        let commits = try LogParser.parse(bytes)
        #expect(commits.count == 1)
        let c = commits[0]
        #expect(c.sha == sha40)
        #expect(c.parents == [parentSHA])
        #expect(c.author.name == "Alice Author")
        #expect(c.author.email == "alice@example.com")
        #expect(c.subject == "Add hello world")
        #expect(c.body == "Add hello world\n\nLonger explanation.")
        #expect(!c.isMerge)
        #expect(c.shortSHA == String(sha40.prefix(7)))
    }

    @Test("root commit has empty parents array")
    func rootCommitNoParents() throws {
        let bytes = Entry(sha: sha40, subject: "Initial commit", body: "Initial commit\n").bytes
        let commits = try LogParser.parse(bytes)
        #expect(commits.first?.parents == [])
    }

    @Test("merge commit reports two parents and isMerge=true")
    func mergeCommit() throws {
        let p1 = String(repeating: "1", count: 40)
        let p2 = String(repeating: "2", count: 40)
        let bytes = Entry(
            sha: sha40,
            parents: "\(p1) \(p2)",
            subject: "Merge feature",
            body: "Merge feature\n"
        ).bytes
        let c = try #require(LogParser.parse(bytes).first)
        #expect(c.parents == [p1, p2])
        #expect(c.isMerge)
    }

    @Test("multiple commits parse in order")
    func multipleCommits() throws {
        var data = Data()
        for i in 0 ..< 3 {
            let sha = String(repeating: "\(i)", count: 40)
            data += Entry(
                sha: sha,
                authorDate: "2026-01-0\(i + 1)T00:00:00Z",
                committerDate: "2026-01-0\(i + 1)T00:00:00Z",
                subject: "Commit \(i)",
                body: "Commit \(i)\n"
            ).bytes
        }
        let commits = try LogParser.parse(data)
        #expect(commits.count == 3)
        #expect(commits.map(\.subject) == ["Commit 0", "Commit 1", "Commit 2"])
    }

    @Test("body containing newlines is preserved (sans trailing)")
    func bodyPreservesInternalNewlines() throws {
        let bytes = Entry(sha: sha40, body: "Line 1\nLine 2\n\nLine 4\n").bytes
        let c = try #require(LogParser.parse(bytes).first)
        #expect(c.body == "Line 1\nLine 2\n\nLine 4")
    }

    @Test("malformed date triggers parseFailure")
    func badDateThrows() throws {
        let bytes = Entry(sha: sha40, authorDate: "not a date").bytes
        #expect(throws: GitError.self) {
            _ = try LogParser.parse(bytes)
        }
    }

    @Test("entry with too few fields triggers parseFailure")
    func tooFewFieldsThrows() throws {
        // Manually build a malformed entry — only 3 fields instead of 10.
        let bytes = Data("aaa\u{001F}bbb\u{001F}ccc".utf8) + Data([0x00])
        #expect(throws: GitError.self) {
            _ = try LogParser.parse(bytes)
        }
    }
}
