@testable import AIKit
import Foundation
import Testing

@Suite("PromptLoader — directory-based")
struct PromptLoaderDirectoryTests {
    /// Create a temp directory with a known set of files. Each test
    /// gets its own directory so they're isolated; cleanup is deferred.
    private func makePromptDir(
        _ label: String,
        files: [String: String]
    ) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-aikit-prompts-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (relative, body) in files {
            try Data(body.utf8).write(to: dir.appendingPathComponent(relative))
        }
        return dir
    }

    @Test("load(named:from:) returns the prompt body verbatim")
    func loadByName() throws {
        let dir = try makePromptDir(
            "load-by-name",
            files: ["commit-message-v1.md": "Write a commit message.\n"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompt = try PromptLoader.load(named: "commit-message-v1", from: dir)
        #expect(prompt.name == "commit-message-v1")
        #expect(prompt.body == "Write a commit message.\n")
    }

    @Test("load(named:from:) preserves trailing whitespace in the body")
    func preservesTrailingWhitespace() throws {
        let dir = try makePromptDir(
            "trailing-ws",
            files: ["p.md": "body\n\n  \n"]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompt = try PromptLoader.load(named: "p", from: dir)
        #expect(prompt.body == "body\n\n  \n")
    }

    @Test("load(named:from:) throws notFound for a missing file")
    func notFoundThrows() throws {
        let dir = try makePromptDir("missing", files: [:])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: PromptLoaderError.self) {
            _ = try PromptLoader.load(named: "absent", from: dir)
        }
        // Exact case discrimination — caller branches on it.
        do {
            _ = try PromptLoader.load(named: "absent", from: dir)
            Issue.record("expected throw")
        } catch let error as PromptLoaderError {
            switch error {
            case let .notFound(name, _):
                #expect(name == "absent")
            default:
                Issue.record("expected .notFound, got \(error)")
            }
        }
    }

    @Test("load(named:from:) throws nonUTF8 for invalid byte sequences")
    func nonUTF8Throws() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-aikit-prompts-nonutf8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Lone 0xFF byte — invalid in UTF-8.
        try Data([0xFF, 0xFE, 0xFD]).write(to: dir.appendingPathComponent("bad.md"))

        do {
            _ = try PromptLoader.load(named: "bad", from: dir)
            Issue.record("expected throw")
        } catch let error as PromptLoaderError {
            switch error {
            case let .nonUTF8(name, _):
                #expect(name == "bad")
            default:
                Issue.record("expected .nonUTF8, got \(error)")
            }
        }
    }

    @Test("loadAll(from:) returns every .md file sorted by name")
    func loadAllSorted() throws {
        let dir = try makePromptDir(
            "load-all",
            files: [
                "zebra.md": "z",
                "alpha.md": "a",
                "midpoint.md": "m"
            ]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompts = try PromptLoader.loadAll(from: dir)
        #expect(prompts.map(\.name) == ["alpha", "midpoint", "zebra"])
        #expect(prompts.map(\.body) == ["a", "m", "z"])
    }

    @Test("loadAll(from:) skips non-.md files")
    func skipsNonMarkdown() throws {
        let dir = try makePromptDir(
            "skip-non-md",
            files: [
                "real.md": "body",
                "README.txt": "ignore me",
                "notes.swift": "// also ignored"
            ]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompts = try PromptLoader.loadAll(from: dir)
        #expect(prompts.map(\.name) == ["real"])
    }

    @Test("loadAll(from:) on an empty directory returns []")
    func loadAllEmpty() throws {
        let dir = try makePromptDir("empty", files: [:])
        defer { try? FileManager.default.removeItem(at: dir) }

        let prompts = try PromptLoader.loadAll(from: dir)
        #expect(prompts.isEmpty)
    }

    @Test("loadAll(from:) throws directoryUnreadable for a missing directory")
    func loadAllMissingDirectory() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-aikit-prompts-missing-\(UUID().uuidString)")

        do {
            _ = try PromptLoader.loadAll(from: bogus)
            Issue.record("expected throw")
        } catch let error as PromptLoaderError {
            switch error {
            case .directoryUnreadable:
                break // expected
            default:
                Issue.record("expected .directoryUnreadable, got \(error)")
            }
        } catch {
            Issue.record("expected PromptLoaderError, got \(error)")
        }
    }
}

@Suite("PromptLoader — bundled")
struct PromptLoaderBundleTests {
    @Test("loadBundled(named:) resolves the shipped commit-message-v1 prompt")
    func loadCommitMessagePrompt() throws {
        let prompt = try PromptLoader.loadBundled(named: "commit-message-v1")
        #expect(prompt.name == "commit-message-v1")
        // Spot-check the prompt content rather than asserting a
        // verbatim string — the file is the source of truth and
        // may legitimately evolve. The Conventional-Commit hint
        // and the no-marketing-language constraint are the load-
        // bearing parts that shape callers' expectations.
        #expect(prompt.body.contains("Conventional Commit"))
        #expect(prompt.body.contains("imperative"))
        #expect(!prompt.body.isEmpty)
    }

    @Test("loadBundled(named:) throws notFound for an absent prompt")
    func notFoundThrows() {
        do {
            _ = try PromptLoader.loadBundled(named: "definitely-not-shipped")
            Issue.record("expected throw")
        } catch let error as PromptLoaderError {
            switch error {
            case let .notFound(name, _):
                #expect(name == "definitely-not-shipped")
            default:
                Issue.record("expected .notFound, got \(error)")
            }
        } catch {
            Issue.record("expected PromptLoaderError, got \(error)")
        }
    }

    @Test("loadAllBundled() includes every shipped prompt, sorted by name")
    func loadAllBundled() throws {
        let prompts = try PromptLoader.loadAllBundled()
        // At least the commit-message-v1 we ship today. Asserting
        // membership rather than exact count lets follow-up prompts
        // land without touching this test.
        #expect(prompts.contains { $0.name == "commit-message-v1" })
        // Sorted invariant.
        let names = prompts.map(\.name)
        #expect(names == names.sorted())
    }
}
