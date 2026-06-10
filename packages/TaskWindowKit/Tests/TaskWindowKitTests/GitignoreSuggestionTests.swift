// GitignoreSuggestionTests.swift
//
// ADR 0070 amendment — the suggest-only .gitignore affordance.
// `detect` is pure (untracked list in, suggestions out); `append` is
// the consent-gated write, tested against real files for the four
// shapes that matter: missing file, existing file without trailing
// newline, dedup of already-present lines, and header-once.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("GitignoreSuggestion — detect (pure)")
struct GitignoreSuggestionDetectTests {
    @Test("untracked junk groups by pattern with sorted evidence; legit files don't appear")
    func detectGroupsByPattern() {
        let suggestions = GitignoreSuggestion.detect(untrackedPaths: [
            "zeta/prod.env",
            "alpha/dev.env",
            "config/service.pem",
            "~$Budget.xlsx",
            "Sources/App/main.swift",
            "README.md"
        ])

        #expect(suggestions == [
            SuggestedIgnore(
                pattern: "*.env",
                category: .secret,
                matchedPaths: ["alpha/dev.env", "zeta/prod.env"]
            ),
            SuggestedIgnore(
                pattern: "*.pem",
                category: .secret,
                matchedPaths: ["config/service.pem"]
            ),
            SuggestedIgnore(
                pattern: "~$*",
                category: .temporary,
                matchedPaths: ["~$Budget.xlsx"]
            )
        ])
    }

    @Test("no junk → no suggestions")
    func detectNothing() {
        let suggestions = GitignoreSuggestion.detect(
            untrackedPaths: ["main.swift", "docs/guide.md"]
        )
        #expect(suggestions.isEmpty)
    }

    @Test("secrets order before temporaries regardless of input order")
    func secretsFirst() {
        let suggestions = GitignoreSuggestion.detect(
            untrackedPaths: ["x.tmp", "prod.env"]
        )
        #expect(suggestions.map(\.pattern) == ["*.env", "*.tmp"])
        #expect(suggestions.map(\.category) == [.secret, .temporary])
    }
}

@Suite("GitignoreSuggestion — append (consent action, real files)")
struct GitignoreSuggestionAppendTests {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-gitignore-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let header = "# Added by Sprig (likely secrets / temporary files)"

    @Test("missing .gitignore is created with the header and the patterns")
    func createsWhenMissing() throws {
        let dir = try makeTempDir("create")
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = try GitignoreSuggestion.append(patterns: ["*.env", "~$*"], toRepoRoot: dir)

        #expect(written == ["*.env", "~$*"])
        let content = try String(
            contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8
        )
        #expect(content == "\(header)\n*.env\n~$*\n")
    }

    @Test("existing file is appended to — never rewritten — and gets a separating newline")
    func appendsToExisting() throws {
        let dir = try makeTempDir("append")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".gitignore")
        // Deliberately no trailing newline: append must add one
        // before its own lines rather than gluing onto "build/".
        try Data("# theirs\nbuild/".utf8).write(to: url)

        let written = try GitignoreSuggestion.append(patterns: ["*.env"], toRepoRoot: dir)

        #expect(written == ["*.env"])
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == "# theirs\nbuild/\n\(header)\n*.env\n")
    }

    @Test("already-present patterns are skipped; nothing written when all are present")
    func dedupsExistingLines() throws {
        let dir = try makeTempDir("dedup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".gitignore")
        try Data("*.env\n".utf8).write(to: url)

        let written = try GitignoreSuggestion.append(
            patterns: ["*.env", "*.pem"], toRepoRoot: dir
        )
        #expect(written == ["*.pem"], "only the missing pattern is added")

        let unchanged = try GitignoreSuggestion.append(patterns: ["*.env"], toRepoRoot: dir)
        #expect(unchanged.isEmpty)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content == "*.env\n\(header)\n*.pem\n", "no-op append must not touch the file")
    }

    @Test("the Sprig header appears once across repeated appends")
    func headerOnce() throws {
        let dir = try makeTempDir("header")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try GitignoreSuggestion.append(patterns: ["*.env"], toRepoRoot: dir)
        _ = try GitignoreSuggestion.append(patterns: ["*.pem"], toRepoRoot: dir)

        let content = try String(
            contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8
        )
        let headerCount = content
            .split(whereSeparator: \.isNewline)
            .count { $0.trimmingCharacters(in: .whitespaces) == header }
        #expect(headerCount == 1)
        #expect(content == "\(header)\n*.env\n*.pem\n")
    }
}
