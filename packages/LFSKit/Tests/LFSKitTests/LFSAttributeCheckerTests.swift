import Foundation
import GitCore
@testable import LFSKit
import Testing

@Suite("LFSAttributeChecker — git check-attr wrapper")
struct LFSAttributeCheckerTests {
    /// Build a NUL-separated byte stream from `tokens`. Replaces the
    /// `Array("foo".utf8) + [0] + Array("bar".utf8) + ...` pattern
    /// that hits "the compiler is unable to type-check this
    /// expression in reasonable time" on macOS Swift (the `[0]`
    /// literal's `[Int]` vs `[UInt8]` ambiguity multiplied across
    /// many `+` operands turns inference into exponential work).
    /// Linux Swift had more headroom and the chains compiled fine
    /// there; the macOS-14 / -15 jobs on PR #76 surfaced the gap.
    private func nulSeparated(_ tokens: [String]) -> Data {
        var data = Data()
        for token in tokens {
            data.append(contentsOf: token.utf8)
            data.append(0)
        }
        return data
    }

    // MARK: - Pure parser

    @Test("parse handles a single record")
    func parseSingle() {
        let parsed = LFSAttributeChecker.parse(nulSeparated(["a.psd", "filter", "lfs"]))
        #expect(parsed.count == 1)
        #expect(parsed[0].path == "a.psd")
        #expect(parsed[0].filter == "lfs")
        #expect(parsed[0].isLFS)
    }

    @Test("parse handles multiple records")
    func parseMultiple() {
        let parsed = LFSAttributeChecker.parse(nulSeparated([
            "a.psd", "filter", "lfs",
            "b.txt", "filter", "unspecified",
            "c.bin", "filter", "lfs"
        ]))
        #expect(parsed.count == 3)
        #expect(parsed[0].isLFS)
        #expect(!parsed[1].isLFS)
        #expect(parsed[1].filter == "unspecified")
        #expect(parsed[2].isLFS)
    }

    @Test("parse drops a trailing partial record")
    func parseTrailingPartial() {
        // Full record + 2 trailing tokens (incomplete second record).
        let parsed = LFSAttributeChecker.parse(nulSeparated([
            "ok.psd", "filter", "lfs",
            "partial", "filter"
        ]))
        #expect(parsed.count == 1)
        #expect(parsed[0].path == "ok.psd")
    }

    @Test("parse skips records whose attribute name isn't 'filter'")
    func parseSkipsUnknownAttr() {
        // Pathological — git would never emit this, but be defensive.
        let parsed = LFSAttributeChecker.parse(nulSeparated([
            "foo", "merge", "custom",
            "bar.psd", "filter", "lfs"
        ]))
        #expect(parsed.count == 1)
        #expect(parsed[0].path == "bar.psd")
    }

    @Test("parse on empty data returns empty results")
    func parseEmpty() {
        #expect(LFSAttributeChecker.parse(Data()).isEmpty)
    }

    @Test("encodeStdin produces NUL-separated UTF-8 bytes per path")
    func encodeStdinFormat() {
        let data = LFSAttributeChecker.encodeStdin(paths: ["a.psd", "images/b c.png"])
        let expected = nulSeparated(["a.psd", "images/b c.png"])
        #expect(data == expected)
    }

    @Test("encodeStdin on empty paths produces empty data")
    func encodeStdinEmpty() {
        #expect(LFSAttributeChecker.encodeStdin(paths: []).isEmpty)
    }

    // MARK: - Integration: real git fixture with .gitattributes

    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-lfs-checkattr-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    @Test("empty input list short-circuits — no git invocation, empty output")
    func emptyInputNoInvocation() async throws {
        let (root, runner) = try await mkRepo("empty-input")
        defer { try? FileManager.default.removeItem(at: root) }
        let results = try await LFSAttributeChecker.check(paths: [], runner: runner)
        #expect(results.isEmpty)
    }

    @Test("repo with no .gitattributes — every path is unspecified, none are LFS")
    func noGitAttributes() async throws {
        let (root, runner) = try await mkRepo("no-attrs")
        defer { try? FileManager.default.removeItem(at: root) }
        let results = try await LFSAttributeChecker.check(
            paths: ["foo.psd", "bar.txt"],
            runner: runner
        )
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.isLFS })
        #expect(results.allSatisfy { $0.filter == "unspecified" })
    }

    @Test("LFS-tracked extension matches via *.psd glob")
    func extensionGlob() async throws {
        let (root, runner) = try await mkRepo("ext-glob")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            "*.psd filter=lfs diff=lfs merge=lfs -text\n".utf8
        ).write(to: root.appendingPathComponent(".gitattributes"))

        let results = try await LFSAttributeChecker.check(
            paths: ["art/cover.psd", "src/main.swift", "deep/nested/path.psd"],
            runner: runner
        )
        #expect(results.count == 3)
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.isLFS) })
        #expect(byPath["art/cover.psd"] == true)
        #expect(byPath["src/main.swift"] == false)
        #expect(byPath["deep/nested/path.psd"] == true)
    }

    @Test("directory-anchored pattern matches only inside that directory")
    func directoryAnchored() async throws {
        let (root, runner) = try await mkRepo("dir-anchored")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            "images/*.png filter=lfs diff=lfs merge=lfs -text\n".utf8
        ).write(to: root.appendingPathComponent(".gitattributes"))

        let results = try await LFSAttributeChecker.check(
            paths: ["images/cover.png", "elsewhere/cover.png", "images/nested/inner.png"],
            runner: runner
        )
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.isLFS) })
        #expect(byPath["images/cover.png"] == true)
        #expect(byPath["elsewhere/cover.png"] == false)
        // git's `images/*.png` matches direct children only — not
        // recursive. `images/**` would be the recursive variant.
        #expect(byPath["images/nested/inner.png"] == false)
    }

    @Test("explicit -filter (unset) overrides a broader LFS rule")
    func unsetOverride() async throws {
        let (root, runner) = try await mkRepo("unset-override")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            """
            *.psd filter=lfs diff=lfs merge=lfs -text
            small.psd -filter

            """
            .utf8
        ).write(to: root.appendingPathComponent(".gitattributes"))

        let results = try await LFSAttributeChecker.check(
            paths: ["big.psd", "small.psd"],
            runner: runner
        )
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.filter) })
        #expect(byPath["big.psd"] == "lfs")
        // Negation makes git return "unset", which is distinct from
        // "unspecified" (= no rule). Our `isLFS` check picks up only
        // exact `"lfs"`, so both unset/unspecified read as "not LFS".
        #expect(byPath["small.psd"] == "unset")
    }

    @Test("path with embedded spaces survives NUL-separated stdin")
    func pathWithSpaces() async throws {
        let (root, runner) = try await mkRepo("spaces")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            "*.psd filter=lfs\n".utf8
        ).write(to: root.appendingPathComponent(".gitattributes"))

        let results = try await LFSAttributeChecker.check(
            paths: ["my art file.psd"],
            runner: runner
        )
        #expect(results.count == 1)
        #expect(results[0].path == "my art file.psd")
        #expect(results[0].isLFS)
    }
}
