// DiffFileClassifierTests.swift
//
// ADR 0086 C0 — per-file diff classification through
// DiffViewerViewModel.classifyFiles(), against real git. Verifies the
// three detection legs (numstat binary marker, check-attr driver, magic
// sniff) and LFS-pointer resolution combine into the right renderer.

import Foundation
import GitCore
@testable import TaskWindowKit
import Testing

@Suite("DiffFileClassifier — per-file diff classification (real git)", .serialized)
struct DiffFileClassifierTests {
    private func makeRepo(_ label: String) async throws -> (URL, Runner) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-diffclass-\(label)-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@t.t"])
        _ = try await runner.run(["config", "user.name", "t"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        _ = try await runner.run(["config", "core.autocrlf", "false"])
        return (dir, runner)
    }

    private func head(_ runner: Runner) async throws -> String {
        try await runner.run(["rev-parse", "HEAD"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func classifiedByPath(_ vm: DiffViewerViewModel) async -> [String: ClassifiedDiffFile] {
        await Dictionary(uniqueKeysWithValues: vm.classifiedFiles.map { ($0.path, $0) })
    }

    @Test("routes text, image, csv, and Office files by content type")
    func classifiesContentTypes() async throws {
        let (dir, runner) = try await makeRepo("types")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello\nworld\n".utf8).write(to: dir.appendingPathComponent("text.txt"))
        try Data("a,b\n1,2\n".utf8).write(to: dir.appendingPathComponent("data.csv"))
        // PNG signature + a NUL → git binary, sniff = png.
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
            .write(to: dir.appendingPathComponent("pic.png"))
        // ZIP signature + a NUL, .docx extension → office.
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01])
            .write(to: dir.appendingPathComponent("doc.docx"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let vm = try await DiffViewerViewModel(repoURL: dir, runner: runner, target: .commit(sha: head(runner)))
        await vm.classifyFiles()
        let byPath = await classifiedByPath(vm)

        #expect(byPath["text.txt"]?.renderer == .text)
        #expect(byPath["data.csv"]?.renderer == .csv)
        #expect(byPath["pic.png"]?.renderer == .image(.png))
        #expect(byPath["pic.png"]?.isBinary == true)
        #expect(byPath["doc.docx"]?.renderer == .office)
    }

    @Test("a configured diff= driver routes to the external tool")
    func driverRoutesToExternalTool() async throws {
        let (dir, runner) = try await makeRepo("driver")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("*.dat diff=mydriver\n".utf8).write(to: dir.appendingPathComponent(".gitattributes"))
        try Data("payload\n".utf8).write(to: dir.appendingPathComponent("blob.dat"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let vm = try await DiffViewerViewModel(repoURL: dir, runner: runner, target: .commit(sha: head(runner)))
        await vm.classifyFiles()
        let byPath = await classifiedByPath(vm)

        #expect(byPath["blob.dat"]?.diffDriver == "mydriver")
        #expect(byPath["blob.dat"]?.renderer == .externalTool(driver: "mydriver"))
    }

    @Test("an LFS pointer resolves to the real media's content type")
    func lfsPointerResolvesToMedia() async throws {
        let (dir, runner) = try await makeRepo("lfs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oid = String(repeating: "a", count: 64)
        let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size 10

        """
        try Data(pointer.utf8).write(to: dir.appendingPathComponent("art.bin"))
        // Place the real PNG bytes in local LFS storage so resolution works.
        let store = dir.appendingPathComponent(".git/lfs/objects/aa/aa")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
            .write(to: store.appendingPathComponent(oid))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let vm = try await DiffViewerViewModel(repoURL: dir, runner: runner, target: .commit(sha: head(runner)))
        await vm.classifyFiles()
        let byPath = await classifiedByPath(vm)

        #expect(byPath["art.bin"]?.lfsPointer?.oidSHA256 == oid)
        #expect(byPath["art.bin"]?.renderer == .image(.png))
    }

    @Test("route trusts git's binary marker over a magic false positive")
    func routeRespectsBinaryMarker() {
        // git says text → a `%PDF-`/`PK..` magic match is a false
        // positive; diff as text (by extension).
        #expect(DiffRendererKind.route(path: "note.md", contentType: .pdf, diffDriver: nil, isBinary: false) == .text)
        #expect(DiffRendererKind.route(path: "weird.txt", contentType: .zipContainer, diffDriver: nil, isBinary: false) == .text)
        #expect(DiffRendererKind.route(path: "data.csv", contentType: .pdf, diffDriver: nil, isBinary: false) == .csv)
        // git says binary → trust the magic type.
        #expect(DiffRendererKind.route(path: "real.png", contentType: .png, diffDriver: nil, isBinary: true) == .image(.png))
        #expect(DiffRendererKind.route(path: "doc.docx", contentType: .zipContainer, diffDriver: nil, isBinary: true) == .office)
        // a configured driver always wins.
        #expect(
            DiffRendererKind.route(path: "x.txt", contentType: .plainText, diffDriver: "exif", isBinary: false)
                == .externalTool(driver: "exif")
        )
    }

    @Test("classifyFiles is empty for a clean worktree")
    func emptyWhenClean() async throws {
        let (dir, runner) = try await makeRepo("clean")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "-A"])
        _ = try await runner.run(["commit", "-m", "seed"])

        let vm = DiffViewerViewModel(repoURL: dir, runner: runner, target: .worktreeAgainstIndex)
        await vm.classifyFiles()
        #expect(await vm.classifiedFiles.isEmpty)
        #expect(await vm.state == .success(0))
    }
}
