// LFSTrackTests.swift
//
// ADR 0029/0091 — the "Track with LFS" write action against real git.
// Adapts to git-lfs availability: where git-lfs is on PATH (CI, dev
// machines with it) the action writes the .gitattributes entry; where
// it's absent the action refuses with the typed detect-and-prompt error.

import Foundation
import GitCore
@testable import LFSKit
import Testing

@Suite("LFSTrack — track-with-LFS action (real git)")
struct LFSTrackTests {
    private func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-lfs-track-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        return (tmp, runner)
    }

    @Test("track writes the LFS attribute when git-lfs is present, or refuses when absent")
    func trackAdaptsToAvailability() async throws {
        let (root, runner) = try await mkRepo("track")
        defer { try? FileManager.default.removeItem(at: root) }

        let status = try? await LFSInstall.probe(runner: runner)
        let available = status?.binaryAvailable ?? false
        if available {
            try await LFSTrack.track(pattern: "*.psd", runner: runner)
            let attrs = try String(
                contentsOf: root.appendingPathComponent(".gitattributes"),
                encoding: .utf8
            )
            #expect(attrs.contains("*.psd"))
            #expect(attrs.contains("filter=lfs"))
        } else {
            await #expect(throws: LFSTrackError.gitLFSNotAvailable) {
                try await LFSTrack.track(pattern: "*.psd", runner: runner)
            }
        }
    }
}
