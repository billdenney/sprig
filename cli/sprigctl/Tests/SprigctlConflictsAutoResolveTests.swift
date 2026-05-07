import Foundation
import Testing

// `sprigctl conflicts --auto-resolve` end-to-end CLI tests. Split out
// from `SprigctlConflictsTests.swift` so neither file trips
// SwiftLint's `type_body_length` cap as the conflicts surface grows.

@Suite("sprigctl conflicts --auto-resolve")
struct SprigctlConflictsAutoResolveTests {
    @Test("auto-resolve requires a file path argument")
    func autoResolveRequiresPath() async throws {
        let out = try await Sprigctl.run(["conflicts", "--auto-resolve"])
        #expect(out.exitCode != 0)
    }

    @Test("auto-resolve on a clean file is a no-op and does not rewrite")
    func autoResolveOnCleanFile() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-ar-clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clean.txt")
        let original = "line one\nline two\n"
        try Sprigctl.write(original, to: file)

        let out = try await Sprigctl.run(["conflicts", "--auto-resolve", file.path])
        #expect(out.exitCode == 0)
        #expect(out.stderr.contains("no conflict regions"))
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == original, "clean file should be left untouched")
    }

    @Test("auto-resolve on identical-content conflict resolves and writes back")
    func autoResolveIdenticalConflict() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-ar-identical")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Sprigctl.write(
            """
            before
            <<<<<<< HEAD
            same line
            =======
            same line
            >>>>>>> feature
            after
            """,
            to: file
        )

        let out = try await Sprigctl.run(["conflicts", "--auto-resolve", file.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Resolved all 1 region"))

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(!after.contains("<<<<<<<"))
        #expect(!after.contains("======="))
        #expect(!after.contains(">>>>>>>"))
        #expect(after.contains("same line"))
        #expect(after.contains("before"))
        #expect(after.contains("after"))
    }

    @Test("auto-resolve on whitespace-only conflict resolves only with --whitespace")
    func autoResolveWhitespaceOnly() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-ar-ws")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        let source = """
        <<<<<<< HEAD
        hello world
        =======
        hello world\u{0020}
        >>>>>>> feature
        """
        try Sprigctl.write(source, to: file)

        // Without --whitespace: nothing resolves; file untouched.
        let out1 = try await Sprigctl.run(["conflicts", "--auto-resolve", file.path])
        #expect(out1.exitCode == 0)
        #expect(out1.stderr.contains("no auto-resolvable regions"))
        #expect(try String(contentsOf: file, encoding: .utf8) == source)

        // With --whitespace: resolves and writes back.
        let out2 = try await Sprigctl.run(["conflicts", "--auto-resolve", "--whitespace", file.path])
        #expect(out2.exitCode == 0)
        #expect(out2.stdout.contains("Resolved all 1 region"))
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(!after.contains("<<<<<<<"))
        #expect(after.contains("hello world"))
    }

    @Test("auto-resolve on a mix of resolvable + manual leaves markers on the manual one")
    func autoResolveMixed() async throws {
        let dir = try Sprigctl.mkRepo("conflicts-ar-mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Sprigctl.write(
            """
            <<<<<<< HEAD
            same
            =======
            same
            >>>>>>> A
            middle
            <<<<<<< HEAD
            ours-only
            =======
            theirs-only
            >>>>>>> B
            """,
            to: file
        )

        let out = try await Sprigctl.run(["conflicts", "--auto-resolve", file.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Resolved 1 of 2 regions"))
        #expect(out.stdout.contains("1 still need manual resolution"))

        let after = try String(contentsOf: file, encoding: .utf8)
        // First (identical) region's markers should be gone.
        // Second (genuinely conflicting) region's markers should remain.
        #expect(after.contains("<<<<<<< HEAD"))
        #expect(after.contains(">>>>>>> B"))
        #expect(after.contains("ours-only"))
        #expect(after.contains("theirs-only"))
        #expect(after.contains("same"))
        #expect(after.contains("middle"))
        // No B-prefix sticking around without a closing marker.
        #expect(!after.contains(">>>>>>> A"))
    }
}
