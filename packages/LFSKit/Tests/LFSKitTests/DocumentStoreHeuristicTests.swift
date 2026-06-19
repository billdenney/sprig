// DocumentStoreHeuristicTests.swift
//
// ADR 0091 (part B) — the document-store LFS heuristic. Pure
// classification is unit-tested directly; the `evaluate(runner:)`
// fetch-and-classify path runs against a real git fixture repo (never
// a mocked git binary — per CLAUDE.md).

import Foundation
import GitCore
@testable import LFSKit
import Testing

@Suite("DocumentStoreHeuristic — classify the tracked set")
struct DocumentStoreHeuristicClassifyTests {
    let heuristic = DocumentStoreHeuristic()

    @Test("a binary-dominated tracked set fires the offer with ranked patterns")
    func binaryDominatedFires() {
        // 6 binaries, 2 code files → 6/8 = 0.75 >= 0.5, count >= 5.
        let paths = [
            "art/a.psd", "art/b.psd", "art/c.psd",
            "docs/x.docx", "docs/y.docx",
            "clip.mp4",
            "README.md", "main.swift"
        ]
        let rec = heuristic.classify(trackedPaths: paths)
        #expect(rec.shouldOffer)
        #expect(rec.trackedFileCount == 8)
        #expect(rec.binaryFileCount == 6)
        // Ranked most-common-first, alphabetical tiebreak: psd(3), docx(2), mp4(1).
        #expect(rec.suggestedPatterns == ["*.psd", "*.docx", "*.mp4"])
        #expect(abs(rec.binaryShare - 0.75) < 1e-9)
    }

    @Test("a code-dominated tracked set does NOT fire the offer")
    func codeDominatedDeclines() {
        let paths = [
            "main.swift", "util.swift", "model.swift", "view.swift",
            "README.md", "config.json",
            "logo.psd" // a single asset — the per-file rail covers this
        ]
        let rec = heuristic.classify(trackedPaths: paths)
        #expect(!rec.shouldOffer)
        #expect(rec.trackedFileCount == 7)
        #expect(rec.binaryFileCount == 1)
        #expect(rec.suggestedPatterns.isEmpty)
    }

    @Test("a tiny repo below the file floor never fires, even at 100% binary")
    func belowFloorDeclines() {
        // 3 files, all binary: share 1.0 but count 3 < 5 floor.
        let rec = heuristic.classify(trackedPaths: ["a.psd", "b.psd", "c.zip"])
        #expect(!rec.shouldOffer)
        #expect(rec.trackedFileCount == 3)
        #expect(rec.binaryFileCount == 3)
    }

    @Test("an empty repo declines without dividing by zero")
    func emptyDeclines() {
        let rec = heuristic.classify(trackedPaths: [])
        #expect(!rec.shouldOffer)
        #expect(rec.trackedFileCount == 0)
        #expect(rec.binaryFileCount == 0)
        #expect(rec.binaryShare == 0)
    }

    @Test("exactly at the 0.5 share boundary fires (>= is inclusive)")
    func boundaryShareFires() {
        // 3 binary / 6 total = 0.5 exactly; count 6 >= 5.
        let paths = ["a.psd", "b.docx", "c.zip", "x.swift", "y.md", "z.txt"]
        let rec = heuristic.classify(trackedPaths: paths)
        #expect(rec.shouldOffer)
        #expect(abs(rec.binaryShare - 0.5) < 1e-9)
    }

    @Test("just below the 0.5 share boundary declines")
    func justBelowBoundaryDeclines() {
        // 3 binary / 7 total ≈ 0.4286 < 0.5.
        let paths = ["a.psd", "b.docx", "c.zip", "w.swift", "x.swift", "y.md", "z.txt"]
        let rec = heuristic.classify(trackedPaths: paths)
        #expect(!rec.shouldOffer)
    }

    @Test("thresholds are injectable — a stricter share suppresses an otherwise-firing repo")
    func injectableThresholds() {
        let strict = DocumentStoreHeuristic(minimumBinaryShare: 0.9, minimumTrackedFiles: 5)
        let paths = ["a.psd", "b.psd", "c.psd", "d.psd", "e.swift"] // 0.8 share
        #expect(!strict.classify(trackedPaths: paths).shouldOffer)
        // The default (0.5) WOULD fire on the same set.
        #expect(DocumentStoreHeuristic().classify(trackedPaths: paths).shouldOffer)
    }

    @Test("parseLSFilesZ splits on NUL and drops the trailing empty record")
    func parseLSFilesZHandlesNUL() {
        var data = Data()
        for path in ["a.psd", "dir/with space.docx", "c.zip"] {
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        #expect(DocumentStoreHeuristic.parseLSFilesZ(data) == ["a.psd", "dir/with space.docx", "c.zip"])
        #expect(DocumentStoreHeuristic.parseLSFilesZ(Data()) == [])
    }
}

@Suite("DocumentStoreHeuristic — evaluate against real git")
struct DocumentStoreHeuristicRealGitTests {
    /// A fresh repo with `core.autocrlf=false` (git-for-Windows defaults
    /// it true, which would rewrite content — we assert path lists, but
    /// keep fixtures byte-stable as a matter of habit).
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-docstore-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        return (tmp, runner)
    }

    private func commitFiles(_ names: [String], root: URL, runner: Runner) async throws {
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: url)
        }
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "add fixtures"])
    }

    @Test("a binary-dominated real repo fires the offer")
    func realBinaryDominatedFires() async throws {
        let (root, runner) = try await mkRepo("bin")
        defer { try? FileManager.default.removeItem(at: root) }
        try await commitFiles(
            ["a.psd", "b.psd", "c.docx", "d.docx", "e.zip", "README.md"],
            root: root, runner: runner
        )
        let rec = try await DocumentStoreHeuristic().evaluate(runner: runner)
        #expect(rec.shouldOffer)
        #expect(rec.trackedFileCount == 6)
        #expect(rec.binaryFileCount == 5)
        #expect(rec.suggestedPatterns == ["*.docx", "*.psd", "*.zip"])
    }

    @Test("a code-dominated real repo declines")
    func realCodeDominatedDeclines() async throws {
        let (root, runner) = try await mkRepo("code")
        defer { try? FileManager.default.removeItem(at: root) }
        try await commitFiles(
            ["main.swift", "a.swift", "b.swift", "c.swift", "d.swift", "logo.psd"],
            root: root, runner: runner
        )
        let rec = try await DocumentStoreHeuristic().evaluate(runner: runner)
        #expect(!rec.shouldOffer)
        #expect(rec.trackedFileCount == 6)
        #expect(rec.binaryFileCount == 1)
    }
}
