@testable import LFSKit
import Testing

@Suite("GitAttributesLFSParser — extract filter=lfs rules")
struct GitAttributesLFSParserTests {
    // MARK: - Empty / no-LFS

    @Test("empty input returns no rules")
    func empty() {
        #expect(GitAttributesLFSParser.extractLFSRules("").isEmpty)
    }

    @Test("file with no filter=lfs declarations returns no rules")
    func noLFS() {
        let source = """
        *.txt text
        *.bin binary
        # comment line

        """
        #expect(GitAttributesLFSParser.extractLFSRules(source).isEmpty)
    }

    // MARK: - Successful extraction

    @Test("standard LFS rule extracts pattern + line number")
    func singleRule() {
        let source = "*.psd filter=lfs diff=lfs merge=lfs -text"
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "*.psd")
        #expect(rules[0].lineNumber == 1)
    }

    @Test("multiple LFS rules each return a separate entry, line numbers preserved")
    func multipleRules() {
        let source = """
        *.psd filter=lfs diff=lfs merge=lfs -text
        images/*.png filter=lfs diff=lfs merge=lfs -text
        binary/** filter=lfs diff=lfs merge=lfs -text
        """
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 3)
        #expect(rules[0].pattern == "*.psd")
        #expect(rules[0].lineNumber == 1)
        #expect(rules[1].pattern == "images/*.png")
        #expect(rules[1].lineNumber == 2)
        #expect(rules[2].pattern == "binary/**")
        #expect(rules[2].lineNumber == 3)
    }

    @Test("filter=lfs alone (no diff / merge / -text) is sufficient")
    func filterAlone() {
        let source = "*.bin filter=lfs"
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "*.bin")
    }

    @Test("blank lines and comments are skipped, line numbers still match the source")
    func blankAndCommentLines() {
        let source = """
        # LFS-tracked binaries
        *.psd filter=lfs

        # PNGs in images/
        images/*.png filter=lfs
        """
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 2)
        #expect(rules[0].pattern == "*.psd")
        #expect(rules[0].lineNumber == 2)
        #expect(rules[1].pattern == "images/*.png")
        #expect(rules[1].lineNumber == 5)
    }

    @Test("mix of LFS and non-LFS rules — only LFS lines are extracted")
    func mixedRules() {
        let source = """
        *.txt text
        *.psd filter=lfs diff=lfs merge=lfs -text
        *.bin -text
        *.zip filter=lfs
        """
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 2)
        #expect(rules.map(\.pattern) == ["*.psd", "*.zip"])
    }

    @Test("CRLF input parses identically to LF input")
    func crlfTolerant() {
        let lf = "*.psd filter=lfs\nimages/*.png filter=lfs\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let lfRules = GitAttributesLFSParser.extractLFSRules(lf)
        let crlfRules = GitAttributesLFSParser.extractLFSRules(crlf)
        #expect(lfRules == crlfRules)
        #expect(lfRules.count == 2)
    }

    @Test("tab and multi-space whitespace between pattern and attributes is tolerated")
    func tabsAndSpaces() {
        let source = "*.psd\tfilter=lfs\tdiff=lfs"
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "*.psd")
    }

    @Test("leading whitespace on a rule line is tolerated")
    func leadingWhitespace() {
        let source = "    *.psd filter=lfs"
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "*.psd")
    }

    // MARK: - Edge cases

    @Test("quoted-path pattern preserves quotes and embedded space")
    func quotedPattern() {
        // gitattributes allows `"file with spaces.psd"` style quoting
        // for paths that contain whitespace. We preserve the quoted
        // form verbatim — the consumer handles unquoting.
        let source = "\"file with spaces.psd\" filter=lfs"
        let rules = GitAttributesLFSParser.extractLFSRules(source)
        #expect(rules.count == 1)
        #expect(rules[0].pattern == "\"file with spaces.psd\"")
    }

    @Test("pattern with no attributes — not an LFS rule")
    func patternOnlyNoAttributes() {
        let source = "*.psd"
        #expect(GitAttributesLFSParser.extractLFSRules(source).isEmpty)
    }

    @Test("comment-only line starting with # is skipped")
    func commentLine() {
        let source = "# *.psd filter=lfs would be an LFS rule but this is a comment"
        #expect(GitAttributesLFSParser.extractLFSRules(source).isEmpty)
    }

    @Test("substring 'filter=lfs' embedded in another token is not a match")
    func substringNotMatched() {
        // `unset-filter=lfs` is not a valid attribute, but if someone
        // wrote it, our token-bounded matcher should reject it.
        let source = "*.psd unset-filter=lfs"
        #expect(GitAttributesLFSParser.extractLFSRules(source).isEmpty)
    }

    @Test("filter=lfs in pattern position (somehow) is not extracted")
    func filterAsPattern() {
        // A pathological line where someone names a file `filter=lfs`
        // and adds a real attribute. Our split makes the FIRST
        // whitespace-bounded token the pattern, so `filter=lfs` here
        // is the pattern, not an attribute → no LFS rule.
        let source = "filter=lfs text"
        #expect(GitAttributesLFSParser.extractLFSRules(source).isEmpty)
    }

    // MARK: - Per-line parser

    @Test("parseLine returns nil for blank, comment, no-attrs, and non-LFS lines")
    func parseLineRejections() {
        #expect(GitAttributesLFSParser.parseLine("", lineNumber: 1) == nil)
        #expect(GitAttributesLFSParser.parseLine("   ", lineNumber: 1) == nil)
        #expect(GitAttributesLFSParser.parseLine("# comment", lineNumber: 1) == nil)
        #expect(GitAttributesLFSParser.parseLine("*.psd", lineNumber: 1) == nil)
        #expect(GitAttributesLFSParser.parseLine("*.txt text", lineNumber: 1) == nil)
    }

    @Test("splitPatternAndAttributes handles quoted paths with internal whitespace")
    func splitWithQuotes() {
        let result = GitAttributesLFSParser.splitPatternAndAttributes("\"a b c.psd\" filter=lfs")
        #expect(result?.0 == "\"a b c.psd\"")
        #expect(result?.1 == "filter=lfs")
    }

    @Test("hasLFSFilter matches token-bounded filter=lfs only")
    func hasLFSFilterTokens() {
        #expect(GitAttributesLFSParser.hasLFSFilter(in: "filter=lfs"))
        #expect(GitAttributesLFSParser.hasLFSFilter(in: "filter=lfs diff=lfs merge=lfs"))
        #expect(GitAttributesLFSParser.hasLFSFilter(in: "diff=lfs filter=lfs"))
        #expect(!GitAttributesLFSParser.hasLFSFilter(in: "diff=lfs"))
        #expect(!GitAttributesLFSParser.hasLFSFilter(in: "filter=lfs2"))
        #expect(!GitAttributesLFSParser.hasLFSFilter(in: "afilter=lfs"))
    }
}
