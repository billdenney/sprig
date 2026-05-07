import Foundation
@testable import LFSKit
import Testing

@Suite("LFSPointerParser — git-lfs pointer file parsing")
struct LFSPointerTests {
    /// Canonical example from the git-lfs spec.
    static let canonicalSource = """
    version https://git-lfs.github.com/spec/v1
    oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
    size 12345
    """ // trailing newline per spec

    // MARK: - Successful parse

    @Test("canonical 3-line pointer parses cleanly")
    func canonicalParse() throws {
        let parsed = try #require(LFSPointerParser.parse(Self.canonicalSource))
        #expect(parsed.version == "https://git-lfs.github.com/spec/v1")
        #expect(parsed.oidSHA256 == "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393")
        #expect(parsed.size == 12345)
    }

    @Test("CRLF input parses identically to LF input")
    func crlfTolerant() throws {
        let crlf = Self.canonicalSource.replacingOccurrences(of: "\n", with: "\r\n")
        let parsedCRLF = try #require(LFSPointerParser.parse(crlf))
        let parsedLF = try #require(LFSPointerParser.parse(Self.canonicalSource))
        #expect(parsedCRLF == parsedLF)
    }

    @Test("size 0 is valid (empty-file pointer)")
    func zeroSizeIsValid() throws {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:0000000000000000000000000000000000000000000000000000000000000000
        size 0
        """
        let parsed = try #require(LFSPointerParser.parse(source))
        #expect(parsed.size == 0)
    }

    @Test("very large size (multi-GB) parses without overflow")
    func multiGBSize() throws {
        // 50 GiB — comfortably within Int.max.
        let bigSize = 50 * 1024 * 1024 * 1024
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
        size \(bigSize)
        """
        let parsed = try #require(LFSPointerParser.parse(source))
        #expect(parsed.size == bigSize)
    }

    // MARK: - isLikelyPointer probe

    @Test("isLikelyPointer accepts canonical pointer bytes")
    func likelyPointerAcceptsCanonical() throws {
        let data = try #require(Self.canonicalSource.data(using: .utf8))
        #expect(LFSPointerParser.isLikelyPointer(data))
    }

    @Test("isLikelyPointer rejects ordinary text files")
    func likelyPointerRejectsText() {
        let text = "Hello, world!\nThis is just a text file."
        let data = Data(text.utf8)
        #expect(!LFSPointerParser.isLikelyPointer(data))
    }

    @Test("isLikelyPointer rejects oversize input cheaply")
    func likelyPointerRejectsOversize() {
        // Just over the 4 KiB cap.
        let data = Data(repeating: 0x76, count: 4097) // 'v's
        #expect(!LFSPointerParser.isLikelyPointer(data))
    }

    @Test("isLikelyPointer rejects pre-spec hawser-era URL")
    func likelyPointerRejectsHawser() {
        let source = """
        version https://hawser.github.com/spec/v1
        oid sha256:0000000000000000000000000000000000000000000000000000000000000000
        size 0
        """
        #expect(!LFSPointerParser.isLikelyPointer(Data(source.utf8)))
    }

    // MARK: - Parse rejection cases

    @Test("missing version line → nil")
    func missingVersion() {
        let source = """
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        size 100
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("wrong field order → nil")
    func wrongOrder() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        size 100
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("uppercase OID hex → nil (spec mandates lowercase)")
    func uppercaseOID() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4D7A214614AB2935C943F9E0FF69D22EADBB8F32B1258DAAA5E2CA24D17E2393
        size 100
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("OID wrong length → nil")
    func oidWrongLength() {
        // 63 hex chars instead of 64.
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e239
        size 100
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("non-hex characters in OID → nil")
    func oidNonHex() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e23zz
        size 100
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("non-numeric size → nil")
    func sizeNonNumeric() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        size 12k
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("negative size → nil (no leading sign accepted)")
    func sizeNegative() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        size -5
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("extra trailing content → nil")
    func trailingContent() {
        let source = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        size 100
        extra line that doesn't belong
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("ordinary text file → nil")
    func plainText() {
        let source = "Hello, world!\nThis is just a text file.\n"
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("pre-spec hawser-era URL → nil")
    func hawserURLRejected() {
        let source = """
        version https://hawser.github.com/spec/v1
        oid sha256:0000000000000000000000000000000000000000000000000000000000000000
        size 0
        """
        #expect(LFSPointerParser.parse(source) == nil)
    }

    @Test("empty input → nil")
    func empty() {
        #expect(LFSPointerParser.parse("") == nil)
    }

    // MARK: - Per-line parsers

    @Test("parseVersionLine accepts well-formed version, rejects others")
    func versionLineParser() {
        #expect(LFSPointerParser.parseVersionLine("version https://git-lfs.github.com/spec/v1") == "https://git-lfs.github.com/spec/v1")
        #expect(LFSPointerParser.parseVersionLine("version https://git-lfs.github.com/spec/v2") == "https://git-lfs.github.com/spec/v2")
        #expect(LFSPointerParser.parseVersionLine("version") == nil)
        #expect(LFSPointerParser.parseVersionLine("VERSION https://git-lfs.github.com/spec/v1") == nil)
        #expect(LFSPointerParser.parseVersionLine("version https://example.com/spec/v1") == nil)
    }

    @Test("parseOIDLine accepts 64-lowercase-hex, rejects others")
    func oidLineParser() {
        let validHex = String(repeating: "a", count: 64)
        #expect(LFSPointerParser.parseOIDLine("oid sha256:\(validHex)") == validHex)
        #expect(LFSPointerParser.parseOIDLine("oid sha256:") == nil)
        #expect(LFSPointerParser.parseOIDLine("oid sha1:\(validHex)") == nil)
    }

    @Test("parseSizeLine accepts plain decimal, rejects everything else")
    func sizeLineParser() {
        #expect(LFSPointerParser.parseSizeLine("size 0") == 0)
        #expect(LFSPointerParser.parseSizeLine("size 12345") == 12345)
        #expect(LFSPointerParser.parseSizeLine("size") == nil)
        #expect(LFSPointerParser.parseSizeLine("size ") == nil)
        #expect(LFSPointerParser.parseSizeLine("size +5") == nil)
        #expect(LFSPointerParser.parseSizeLine("size 1_000") == nil)
        #expect(LFSPointerParser.parseSizeLine("size 0x10") == nil)
    }
}
