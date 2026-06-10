// CommitMessageSuggestionTests.swift
//
// ADR 0074 — the deterministic non-AI message default. Subject
// synthesis and template parsing are pure; the commit.template
// lookup and the composer wiring run against real git.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("CommitMessageSuggestion — synthesis + template parsing (pure)")
struct CommitMessageSuggestionPureTests {
    @Test("single staged file: Update <name>")
    func singleFile() {
        let subject = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["docs/README.md"],
            newPaths: []
        )
        #expect(subject == "Update README.md")
    }

    @Test("single NEW staged file: Add <name>")
    func singleNewFile() {
        let subject = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["docs/guide.md"],
            newPaths: ["docs/guide.md"]
        )
        #expect(subject == "Add guide.md")
    }

    @Test("several files in one directory: Update <dir> (N files)")
    func oneDirectory() {
        let subject = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["src/app/a.swift", "src/app/b.swift", "src/app/c.swift"],
            newPaths: []
        )
        #expect(subject == "Update src/app (3 files)")
    }

    @Test("mixed directories: Update N files across M directories")
    func mixedDirectories() {
        let subject = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["src/a.swift", "docs/b.md", "src/deep/c.swift"],
            newPaths: []
        )
        #expect(subject == "Update 3 files across 3 directories")
    }

    @Test("all-new staging uses Add; mixed new+modified stays Update")
    func addVersusUpdate() {
        let allNew = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["a.txt", "b.txt"],
            newPaths: ["a.txt", "b.txt"]
        )
        #expect(allNew.hasPrefix("Add "))
        let mixed = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["a.txt", "b.txt"],
            newPaths: ["a.txt"]
        )
        #expect(mixed.hasPrefix("Update "))
    }

    @Test("root-level files use '.' as the directory bucket")
    func rootDirectoryBucket() {
        let subject = CommitMessageSuggestion.synthesizedSubject(
            stagedPaths: ["README.md", "LICENSE"],
            newPaths: []
        )
        #expect(subject == "Update . (2 files)")
    }

    @Test("template parsing: first non-comment line is the subject, rest is body, comments stripped")
    func templateParsing() {
        let raw = """
        # Conventional Commits reminder:
        feat(scope):

        # Why is this change needed?
        Body line one.
        Body line two.
        """
        let message = CommitMessageSuggestion.parseTemplate(raw)
        #expect(message?.subject == "feat(scope):")
        #expect(message?.body == "Body line one.\nBody line two.")
    }

    @Test("all-comment template parses to nil")
    func allCommentTemplate() {
        let raw = "# just\n# comments\n"
        #expect(CommitMessageSuggestion.parseTemplate(raw) == nil)
    }
}

@Suite("CommitMessageSuggestion — commit.template + composer wiring (real git)")
struct CommitMessageSuggestionIntegrationTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-msgsuggest-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("seed\n".utf8).write(to: dir.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["add", "seed.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
        return (dir, runner)
    }

    @Test("configured commit.template wins over synthesis")
    func templateWins() async throws {
        let (dir, runner) = try await makeRepo("template")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("ticket-000: \n\n# fill in\nContext:\n".utf8)
            .write(to: dir.appendingPathComponent(".gitmessage"))
        _ = try await runner.run(["config", "commit.template", ".gitmessage"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("seed.txt"))
        _ = try await runner.run(["add", "seed.txt"])

        let suggestion = await CommitMessageSuggestion.suggest(
            stagedPaths: ["seed.txt"],
            runner: runner,
            repoURL: dir
        )

        #expect(suggestion?.subject == "ticket-000:")
        #expect(suggestion?.body == "Context:")
    }

    @Test("composer: suggestMessage fills an empty draft and never clobbers user input")
    func composerWiring() async throws {
        let (dir, runner) = try await makeRepo("composer")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("new file\n".utf8).write(to: dir.appendingPathComponent("notes.md"))
        _ = try await runner.run(["add", "notes.md"])

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        #expect(await vm.suggestMessage())
        #expect(await vm.message.subject == "Add notes.md")

        // A second call must not overwrite — the draft is non-empty.
        #expect(await !vm.suggestMessage())

        // Explicit user input is never clobbered either.
        await vm.setMessage(CommitMessage(subject: "my own words", body: ""))
        #expect(await !vm.suggestMessage())
        #expect(await vm.message.subject == "my own words")
    }

    @Test("composer: nothing staged + no template → no suggestion")
    func nothingToSuggest() async throws {
        let (dir, runner) = try await makeRepo("empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vm = CommitComposerViewModel(repoURL: dir, runner: runner)
        await vm.refresh()

        #expect(await !vm.suggestMessage())
        #expect(await vm.message.subject.isEmpty)
    }
}
