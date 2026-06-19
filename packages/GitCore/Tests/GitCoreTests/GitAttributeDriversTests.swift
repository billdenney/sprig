// GitAttributeDriversTests.swift
//
// ADR 0086 C0 — reading `.gitattributes` `diff=`/`merge=` driver names
// via `git check-attr`, parse unit + against real git.

import Foundation
@testable import GitCore
import Testing

@Suite("GitAttributeDrivers — check-attr diff/merge + real git", .serialized)
struct GitAttributeDriversTests {
    @Test("parse maps the triples to per-path drivers, ignoring unspecified")
    func parseUnit() {
        let nul = "\u{0}"
        let stream =
            "a.png\(nul)diff\(nul)exif\(nul)a.png\(nul)merge\(nul)binary\(nul)"
                + "b.txt\(nul)diff\(nul)unspecified\(nul)b.txt\(nul)merge\(nul)unspecified\(nul)"
        let results = GitAttributeDrivers.parse(Data(stream.utf8), order: ["a.png", "b.txt"])
        #expect(results.count == 2)
        #expect(results[0] == AttributeDrivers(path: "a.png", diff: "exif", merge: "binary"))
        #expect(results[1] == AttributeDrivers(path: "b.txt", diff: nil, merge: nil))
    }

    @Test("reads configured drivers from a real .gitattributes")
    func realGit() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-drivers-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        try Data("*.png diff=exif merge=binary\n".utf8)
            .write(to: dir.appendingPathComponent(".gitattributes"))

        // Only assert on the repo-controlled `*.png` rule: an in-tree
        // `.gitattributes` takes precedence over global/system ones. We
        // deliberately don't assert "no driver" for another path here —
        // many environments ship a global gitattributes mapping language
        // diff drivers (e.g. `*.swift diff=swift` on macOS), which is
        // legitimate, not a bug. The unspecified→nil case is covered by
        // the env-independent `parseUnit` test above.
        let results = try await GitAttributeDrivers.query(paths: ["art/cover.png"], runner: runner)
        #expect(results.first?.diff == "exif")
        #expect(results.first?.merge == "binary")
    }

    @Test("query returns empty for no paths without spawning git")
    func emptyPaths() async throws {
        let runner = Runner(defaultWorkingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(try await GitAttributeDrivers.query(paths: [], runner: runner).isEmpty)
    }
}
