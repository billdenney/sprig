// DiffPatchSlicerTests.swift
//
// ADR 0061 — the region-staging slicer. Two layers: PURE tests pin the
// exact emitted patch (so `git apply --recount` can't mask a count bug),
// and REAL-GIT round-trips prove slice → `apply --cached` stages exactly
// the selection, byte-exact in the index.

import Foundation
@testable import GitCore
import Testing

@Suite("DiffPatchSlicer — region staging", .serialized)
struct DiffPatchSlicerTests {
    private func rangeOf(_ needle: String, in string: String) throws -> Range<String.Index> {
        try #require(string.range(of: needle))
    }

    // MARK: - Pure transform (no git)

    @Test("staging only the added line of a modification recounts the hunk")
    func pureStageAdditionOnly() throws {
        let diff = """
        diff --git a/f b/f
        index 1111111..2222222 100644
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c

        """
        // Select just the "+B" line → the "-b" becomes context, "+B" stays.
        let sel = try rangeOf("+B\n", in: diff)
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: sel)
        #expect(sliced.addedLines == 1)
        #expect(sliced.removedLines == 0)
        #expect(sliced.files == ["f"])
        #expect(sliced.patch == """
        diff --git a/f b/f
        index 1111111..2222222 100644
        --- a/f
        +++ b/f
        @@ -1,3 +1,4 @@
         a
         b
        +B
         c

        """)
    }

    @Test("a context-only selection stages nothing")
    func pureNoChange() throws {
        let diff = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c

        """
        let sel = try rangeOf(" a\n", in: diff) // the context line only
        #expect(throws: DiffPatchSlicerError.noChangeSelected) {
            _ = try DiffPatchSlicer.slice(diff: diff, selection: sel)
        }
    }

    // MARK: - Real-git round-trips

    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-slice-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        // Keep `\r\n` opaque so the CRLF round-trip is deterministic:
        // git-for-Windows defaults core.autocrlf=true, which would
        // normalize CRLF away on add/diff and make the diff show LF.
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        return (dir, runner)
    }

    private func applyToIndex(_ patch: String, _ runner: Runner) async throws {
        _ = try await runner.run(["apply", "--cached", "--recount", "-"], stdin: Data(patch.utf8))
    }

    private func indexContent(_ path: String, _ runner: Runner) async throws -> String {
        try await runner.run(["show", ":\(path)"]).stdoutString
    }

    @Test("stages exactly the selected change within a multi-change hunk")
    func roundTripSubHunkSubset() async throws {
        let (dir, runner) = try await makeRepo("subset")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nline3\nline4\nline5\nline6\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nCHANGED2\nline3\nCHANGED4\nline5\nNEWLINE\nline6\n".utf8)
            .write(to: dir.appendingPathComponent("f.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        // Select only the line2 change (both -line2 and +CHANGED2).
        let lo = try rangeOf("-line2\n", in: diff).lowerBound
        let hi = try rangeOf("+CHANGED2\n", in: diff).upperBound
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: lo ..< hi)
        #expect(sliced.addedLines == 1)
        #expect(sliced.removedLines == 1)
        #expect(sliced.files == ["f.txt"])

        try await applyToIndex(sliced.patch, runner)
        // Exactly the line2 change is in the index; line4/NEWLINE are not.
        #expect(try await indexContent("f.txt", runner) == "line1\nCHANGED2\nline3\nline4\nline5\nline6\n")
        let unstaged = try await runner.run(["diff"]).stdoutString
        #expect(unstaged.contains("+CHANGED4")) // still pending
        #expect(unstaged.contains("+NEWLINE")) // still pending
        #expect(!unstaged.contains("+CHANGED2")) // fully staged — not a pending add
        // (CHANGED2 still appears as a *context* line in the line4 hunk.)
    }

    @Test("staging only a removed line removes it without adding the paired line")
    func roundTripRemovalOnly() async throws {
        let (dir, runner) = try await makeRepo("removal")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nline3\n".utf8).write(to: dir.appendingPathComponent("h.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nCHANGED2\nline3\n".utf8).write(to: dir.appendingPathComponent("h.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        let sel = try rangeOf("-line2\n", in: diff) // only the removal
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: sel)
        #expect(sliced.removedLines == 1)
        #expect(sliced.addedLines == 0)
        try await applyToIndex(sliced.patch, runner)
        #expect(try await indexContent("h.txt", runner) == "line1\nline3\n")
    }

    @Test("staging only an added line inserts it, keeping the original")
    func roundTripAdditionOnly() async throws {
        let (dir, runner) = try await makeRepo("addition")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nline3\n".utf8).write(to: dir.appendingPathComponent("h.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nCHANGED2\nline3\n".utf8).write(to: dir.appendingPathComponent("h.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        let sel = try rangeOf("+CHANGED2\n", in: diff) // only the addition
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: sel)
        try await applyToIndex(sliced.patch, runner)
        #expect(try await indexContent("h.txt", runner) == "line1\nline2\nCHANGED2\nline3\n")
    }

    @Test("a selection spanning two files stages a change in each")
    func roundTripMultiFile() async throws {
        let (dir, runner) = try await makeRepo("multi")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a1\na2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b1\nb2\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("A1\na2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b1\nB2\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        // Span from the first file's change through the second's.
        let lo = try rangeOf("-a1\n", in: diff).lowerBound
        let hi = try rangeOf("+B2\n", in: diff).upperBound
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: lo ..< hi)
        #expect(Set(sliced.files) == ["a.txt", "b.txt"])
        try await applyToIndex(sliced.patch, runner)
        #expect(try await indexContent("a.txt", runner) == "A1\na2\n")
        #expect(try await indexContent("b.txt", runner) == "b1\nB2\n")
    }

    @Test("a change at EOF without a trailing newline round-trips")
    func roundTripNoNewlineEOF() async throws {
        let (dir, runner) = try await makeRepo("nonewline")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\nb\nc".utf8).write(to: dir.appendingPathComponent("n.txt")) // no trailing newline
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("a\nb\nZ".utf8).write(to: dir.appendingPathComponent("n.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        // Select the whole change (both -c and +Z plus their markers).
        let lo = try rangeOf("-c", in: diff).lowerBound
        let hi = try rangeOf("+Z", in: diff).upperBound
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: lo ..< hi)
        try await applyToIndex(sliced.patch, runner)
        #expect(try await indexContent("n.txt", runner) == "a\nb\nZ")
    }

    @Test("splitting a no-newline-at-EOF change is refused, not silently mis-staged")
    func refusesEofSplit() throws {
        // Single-line file `x` (no trailing newline) changed to `y`.
        let diff = "--- a/e\n+++ b/e\n@@ -1 +1 @@\n-x\n"
            + "\\ No newline at end of file\n+y\n\\ No newline at end of file\n"
        // Select ONLY the `+y` addition. The unselected `-x` becomes a
        // context line, stranding its EOF marker mid-hunk — unrepresentable.
        let sel = try rangeOf("+y\n", in: diff)
        #expect(throws: DiffPatchSlicerError.cannotSplitEndOfFileChange) {
            _ = try DiffPatchSlicer.slice(diff: diff, selection: sel)
        }
    }

    @Test("partial staging of a no-newline final-line change is refused (real git)")
    func realGitRefusesEofSplit() async throws {
        let (dir, runner) = try await makeRepo("eofsplit")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nlastline".utf8).write(to: dir.appendingPathComponent("m.txt")) // no final newline
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("line1\nline2\nNEWlast".utf8).write(to: dir.appendingPathComponent("m.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        let onlyAddition = try rangeOf("+NEWlast", in: diff) // not the paired -lastline
        // Without the guard this would silently stage "line2\nlastlineNEWlast"; refuse instead.
        #expect(throws: DiffPatchSlicerError.cannotSplitEndOfFileChange) {
            _ = try DiffPatchSlicer.slice(diff: diff, selection: onlyAddition)
        }
        // Nothing was staged (the index still matches HEAD).
        let cachedClean = try await runner.run(["diff", "--cached", "--quiet"], throwOnNonZero: false)
        #expect(cachedClean.exitCode == 0)
    }

    @Test("a CRLF file round-trips with line endings preserved")
    func roundTripCRLF() async throws {
        let (dir, runner) = try await makeRepo("crlf")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\r\nb\r\nc\r\n".utf8).write(to: dir.appendingPathComponent("f.txt"))
        _ = try await runner.run(["add", "-A"]); _ = try await runner.run(["commit", "-m", "seed"])
        try Data("a\r\nB\r\nc\r\n".utf8).write(to: dir.appendingPathComponent("f.txt"))

        let diff = try await runner.run(["diff"]).stdoutString
        let lo = try rangeOf("-b\r\n", in: diff).lowerBound
        let hi = try rangeOf("+B\r\n", in: diff).upperBound
        let sliced = try DiffPatchSlicer.slice(diff: diff, selection: lo ..< hi)
        try await applyToIndex(sliced.patch, runner)
        // The \r bytes survive the slice → apply round-trip.
        #expect(try await indexContent("f.txt", runner) == "a\r\nB\r\nc\r\n")
    }
}
