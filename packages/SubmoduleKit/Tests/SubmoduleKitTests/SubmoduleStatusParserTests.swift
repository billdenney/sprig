import Foundation
@testable import SubmoduleKit
import Testing

@Suite("SubmoduleStatusParser — hand-crafted fixtures")
struct SubmoduleStatusParserTests {
    private let sha1 = String(repeating: "a", count: 40)
    private let sha2 = String(repeating: "b", count: 40)
    private let sha256 = String(repeating: "c", count: 64)

    // MARK: Empty / trivial cases

    @Test("empty input yields empty entry list")
    func emptyInputYieldsEmpty() throws {
        let entries = try SubmoduleStatusParser.parse("")
        #expect(entries.isEmpty)
    }

    @Test("trailing newline is tolerated")
    func trailingNewlineTolerated() throws {
        let raw = " \(sha1) sub\n"
        let entries = try SubmoduleStatusParser.parse(raw)
        #expect(entries.count == 1)
        #expect(entries.first?.path == "sub")
    }

    @Test("CRLF line terminators are tolerated")
    func crlfTolerated() throws {
        let raw = " \(sha1) sub-a\r\n+\(sha2) sub-b\r\n"
        let entries = try SubmoduleStatusParser.parse(raw)
        #expect(entries.count == 2)
        #expect(entries[0].state == .clean)
        #expect(entries[0].path == "sub-a")
        #expect(entries[1].state == .outOfDate)
        #expect(entries[1].path == "sub-b")
    }

    // MARK: State chars

    @Test("clean state — leading space")
    func cleanState() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha1) sub")
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.state == .clean)
        #expect(e.recordedSHA == sha1)
        #expect(e.path == "sub")
        #expect(e.refDescription == nil)
    }

    @Test("outOfDate state — leading +")
    func outOfDateState() throws {
        let entries = try SubmoduleStatusParser.parse("+\(sha1) sub")
        #expect(entries.count == 1)
        #expect(entries.first?.state == .outOfDate)
    }

    @Test("notInitialized state — leading -")
    func notInitializedState() throws {
        let entries = try SubmoduleStatusParser.parse("-\(sha1) sub")
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.state == .notInitialized)
        #expect(e.recordedSHA == sha1)
    }

    @Test("mergeConflict state — leading U")
    func mergeConflictState() throws {
        let entries = try SubmoduleStatusParser.parse("U\(sha1) sub")
        #expect(entries.count == 1)
        #expect(entries.first?.state == .mergeConflict)
    }

    // MARK: Refname suffix handling

    @Test("trailing ( refname ) is captured")
    func refnameSuffixCaptured() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha1) sub (heads/main)")
        let e = try #require(entries.first)
        #expect(e.path == "sub")
        #expect(e.refDescription == "heads/main")
    }

    @Test("describe-output refname with hash suffix is captured")
    func describeRefnameCaptured() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha1) sub (v1.2.3-3-g1234abc)")
        #expect(entries.first?.refDescription == "v1.2.3-3-g1234abc")
    }

    @Test("path with embedded spaces and no refname")
    func pathWithSpacesNoRefname() throws {
        let entries = try SubmoduleStatusParser.parse("-\(sha1) sub with spaces")
        let e = try #require(entries.first)
        #expect(e.path == "sub with spaces")
        #expect(e.refDescription == nil)
    }

    @Test("path with embedded spaces AND a real refname")
    func pathWithSpacesAndRefname() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha1) sub with spaces (heads/main)")
        let e = try #require(entries.first)
        #expect(e.path == "sub with spaces")
        #expect(e.refDescription == "heads/main")
    }

    @Test("trailing parens whose content has whitespace stays in path (not extracted as refname)")
    func parensWithSpacesStayInPath() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha1) weird (with spaces)")
        let e = try #require(entries.first)
        #expect(e.path == "weird (with spaces)")
        #expect(e.refDescription == nil)
    }

    // MARK: Nested entries (--recursive output)

    @Test("nested entry path reported with forward slashes")
    func nestedPath() throws {
        let raw = " \(sha1) sub\n \(sha2) sub/deeper"
        let entries = try SubmoduleStatusParser.parse(raw)
        #expect(entries.count == 2)
        #expect(entries[0].path == "sub")
        #expect(entries[1].path == "sub/deeper")
    }

    // MARK: SHA-256 support

    @Test("SHA-256 (64 hex chars) is accepted")
    func sha256Accepted() throws {
        let entries = try SubmoduleStatusParser.parse(" \(sha256) sub")
        let e = try #require(entries.first)
        #expect(e.recordedSHA == sha256)
        #expect(e.recordedSHA.count == 64)
    }

    // MARK: Error cases

    @Test("truncated SHA throws shaUnexpectedShape")
    func truncatedShaThrows() {
        let truncated = String(repeating: "a", count: 39) // 1 short
        #expect(throws: SubmoduleStatusParser.ParseError.self) {
            try SubmoduleStatusParser.parse(" \(truncated) sub")
        }
    }

    @Test("unknown state char throws unknownStateChar")
    func unknownStateCharThrows() {
        #expect(throws: SubmoduleStatusParser.ParseError.self) {
            try SubmoduleStatusParser.parse("@\(sha1) sub")
        }
    }

    @Test("missing path after SHA throws malformedLine")
    func missingPathThrows() {
        // Just state + SHA, no separator space, no path.
        #expect(throws: SubmoduleStatusParser.ParseError.self) {
            try SubmoduleStatusParser.parse(" \(sha1)")
        }
    }

    @Test("empty path after SHA-and-space throws malformedLine")
    func emptyPathThrows() {
        // Trailing space only — `enumerateLines` keeps the trailing
        // space, so the post-separator remainder is empty.
        #expect(throws: SubmoduleStatusParser.ParseError.self) {
            try SubmoduleStatusParser.parse(" \(sha1) ")
        }
    }
}
