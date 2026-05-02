import Foundation
@testable import GitCore
import Testing

@Suite("LoggedCommand — record + truncation + Codable round-trip")
struct LoggedCommandTests {
    // MARK: shape

    @Test("failed reflects exitCode != 0")
    func failedDerived() {
        let now = Date()
        let zero = LoggedCommand(
            argv: ["/usr/bin/git", "status"],
            startedAt: now,
            finishedAt: now,
            exitCode: 0
        )
        let nonZero = LoggedCommand(
            argv: ["/usr/bin/git", "push"],
            startedAt: now,
            finishedAt: now,
            exitCode: 128
        )
        #expect(!zero.failed)
        #expect(nonZero.failed)
    }

    @Test("duration computes finishedAt - startedAt")
    func durationDerived() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_000_001) // one second later
        let entry = LoggedCommand(
            argv: ["/usr/bin/git", "status"],
            startedAt: start,
            finishedAt: end,
            exitCode: 0
        )
        #expect(entry.duration == 1.0)
    }

    @Test("each constructed entry gets a fresh UUID by default")
    func defaultIDsAreUnique() {
        let now = Date()
        let a = LoggedCommand(argv: ["git"], startedAt: now, finishedAt: now, exitCode: 0)
        let b = LoggedCommand(argv: ["git"], startedAt: now, finishedAt: now, exitCode: 0)
        #expect(a.id != b.id)
    }

    @Test("explicit id is preserved")
    func explicitIDPreserved() throws {
        let want = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789012"))
        let entry = LoggedCommand(
            id: want,
            argv: ["git"],
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 0
        )
        #expect(entry.id == want)
    }

    // MARK: stderr truncation

    @Test("truncateStderr returns nil for empty input")
    func truncateEmpty() {
        #expect(LoggedCommand.truncateStderr("") == nil)
    }

    @Test("truncateStderr passes through short input unchanged")
    func truncateShort() {
        let s = "fatal: not a git repository"
        #expect(LoggedCommand.truncateStderr(s) == s)
    }

    @Test("truncateStderr clips long input and adds an elision marker")
    func truncateLong() throws {
        let big = String(repeating: "A", count: LoggedCommand.stderrTailLimit + 50)
        let truncated = try #require(LoggedCommand.truncateStderr(big))
        #expect(truncated.contains("[…50 more bytes elided]"))
        #expect(truncated.count < big.count)
    }

    @Test("truncateStderr keeps the TAIL of the input (most recent stderr)")
    func truncateKeepsTail() throws {
        // Long stderr ending with a meaningful line — make sure we keep
        // the tail, not the head.
        let head = String(repeating: "X", count: LoggedCommand.stderrTailLimit + 10)
        let tail = "fatal: oops"
        let truncated = try #require(LoggedCommand.truncateStderr(head + tail))
        #expect(truncated.hasSuffix(tail))
    }

    // MARK: Codable round-trip

    @Test("Codable round-trip preserves every field")
    func codableRoundTrip() throws {
        let original = LoggedCommand(
            id: UUID(),
            argv: ["/usr/bin/git", "push", "--force-with-lease", "--force-if-includes"],
            cwd: "/tmp/repo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001.5),
            exitCode: 0,
            stderrTail: "Everything up-to-date",
            stdoutByteCount: 42
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LoggedCommand.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable handles nil cwd and nil stderrTail")
    func codableHandlesNils() throws {
        let original = LoggedCommand(
            argv: ["git", "status"],
            startedAt: Date(),
            finishedAt: Date(),
            exitCode: 0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LoggedCommand.self, from: data)
        #expect(decoded.cwd == nil)
        #expect(decoded.stderrTail == nil)
        #expect(decoded.stdoutByteCount == 0)
    }
}
