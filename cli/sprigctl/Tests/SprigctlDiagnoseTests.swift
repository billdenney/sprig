import Foundation
import Testing

// `sprigctl diagnose` end-to-end CLI tests. Lives in its own file so
// neither it nor `SprigctlTests.swift` trips SwiftLint's `file_length`
// or `type_body_length` caps as the surface grows.

@Suite("sprigctl diagnose")
struct SprigctlDiagnoseTests {
    @Test("diagnose --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["diagnose", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("diagnose"))
    }

    @Test("diagnose against a temp directory emits the documented human-readable lines")
    func humanLines() async throws {
        let dir = try Sprigctl.mkRepo("diagnose-human")
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await Sprigctl.run(["diagnose", dir.path])
        #expect(out.exitCode == 0)
        // sprigctl line should carry the toolVersion constant (kept in
        // sync between `version` and `diagnose` via VersionCommand).
        #expect(out.stdout.contains("sprigctl:"))
        #expect(out.stdout.contains("os:"))
        #expect(out.stdout.contains("os-version:"))
        #expect(out.stdout.contains("git:"))
        #expect(out.stdout.contains("git-lfs:"))
        #expect(out.stdout.contains("collected:"))
    }

    @Test("diagnose --json emits parseable JSON with the documented top-level keys")
    func jsonShape() async throws {
        let dir = try Sprigctl.mkRepo("diagnose-json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await Sprigctl.run(["diagnose", "--json", dir.path])
        #expect(out.exitCode == 0)
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try #require(trimmed.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = try #require(parsed as? [String: Any])

        // Wire-stable keys (sorted JSON, owned by DiagKit).
        let engine = try #require(dict["engine"] as? [String: Any])
        #expect(engine["version"] is String)

        let os = try #require(dict["os"] as? [String: Any])
        #expect(os["name"] is String)
        #expect(os["architecture"] is String)
        #expect(os["versionString"] is String)

        let git = try #require(dict["git"] as? [String: Any])
        // `gitVersionRaw` is present when git is on PATH (which CI
        // runners always have); assert non-nil here.
        let gitRaw = try #require(git["gitVersionRaw"] as? String)
        #expect(gitRaw.hasPrefix("git version "))

        // `generatedAt` is ISO 8601 because the encoder is configured
        // with `.iso8601`. Format check is lenient — the exact
        // millisecond shape varies.
        let generated = try #require(dict["generatedAt"] as? String)
        #expect(generated.contains("T"))
        #expect(generated.hasSuffix("Z"))
    }

    @Test("diagnose runs without a positional path (defaults to current directory)")
    func defaultsToCurrentDir() async throws {
        let dir = try Sprigctl.mkRepo("diagnose-default-cwd")
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try await Sprigctl.run(["diagnose"], cwd: dir)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("sprigctl:"))
    }
}
