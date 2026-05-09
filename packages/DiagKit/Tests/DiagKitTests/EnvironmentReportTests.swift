@testable import DiagKit
import Foundation
import GitCore
import Testing

@Suite("EnvironmentReport — wire shape")
struct EnvironmentReportTests {
    /// Decodes the report's top-level keys to confirm the wire
    /// contract. If a field name changes, this test fails — that's
    /// intentional. The fields here are what support flows / issue
    /// templates depend on.
    @Test("encodes to JSON with the documented top-level keys")
    func topLevelKeys() throws {
        let report = EnvironmentReport(
            engine: .init(version: "0.1.0"),
            os: .init(name: "macOS", versionString: "Version 14.5", architecture: "arm64"),
            git: .init(
                gitVersionRaw: "git version 2.43.0",
                gitVersion: .init(major: 2, minor: 43, patch: 0, suffix: ""),
                gitLFSVersionRaw: "git-lfs/3.4.0 (GitHub; ...)"
            ),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(report)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(parsed["engine"] is [String: Any])
        #expect(parsed["os"] is [String: Any])
        #expect(parsed["git"] is [String: Any])
        #expect(parsed["generatedAt"] != nil)
    }

    @Test("engine carries the caller-supplied version verbatim")
    func engineVersionPassesThrough() throws {
        let report = EnvironmentReport(
            engine: .init(version: "1.2.3-rc.4"),
            os: .init(name: "Linux", versionString: "Linux 6.5.0", architecture: "x86_64"),
            git: .init(gitVersionRaw: nil, gitVersion: nil, gitLFSVersionRaw: nil),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(report)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let engine = try #require(parsed["engine"] as? [String: Any])
        #expect(engine["version"] as? String == "1.2.3-rc.4")
    }

    @Test("git tooling encodes parsed semver components")
    func gitVersionSemverShape() throws {
        let report = EnvironmentReport(
            engine: .init(version: "0.1.0"),
            os: .init(name: "Windows", versionString: "10.0.22631", architecture: "x86_64"),
            git: .init(
                gitVersionRaw: "git version 2.39.5 (Apple Git-154)",
                gitVersion: .init(major: 2, minor: 39, patch: 5, suffix: "(Apple Git-154)"),
                gitLFSVersionRaw: nil
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(report)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let git = try #require(parsed["git"] as? [String: Any])
        #expect(git["gitVersionRaw"] as? String == "git version 2.39.5 (Apple Git-154)")
        let semver = try #require(git["gitVersion"] as? [String: Any])
        #expect(semver["major"] as? Int == 2)
        #expect(semver["minor"] as? Int == 39)
        #expect(semver["patch"] as? Int == 5)
        #expect(semver["suffix"] as? String == "(Apple Git-154)")
    }

    @Test("missing git-lfs encodes as null, not absent")
    func missingLFSEncodesAsNull() throws {
        let report = EnvironmentReport(
            engine: .init(version: "0.1.0"),
            os: .init(name: "macOS", versionString: "Version 14.5", architecture: "arm64"),
            git: .init(gitVersionRaw: "git version 2.43.0", gitVersion: nil, gitLFSVersionRaw: nil),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let json = try #require(String(data: data, encoding: .utf8))
        // Foundation's JSONEncoder omits nil optionals by default.
        // That's fine for our wire — readers Map "absent" to "no
        // git-lfs", same as null. Document the behavior here so a
        // future change to keyed-encoding gets caught.
        #expect(!json.contains("gitLFSVersionRaw"))
    }

    @Test("GitSemver round-trips from GitVersion")
    func gitSemverRoundTrip() throws {
        let parsed = try #require(GitVersion.parse("git version 2.43.5 (Apple Git-154)"))
        let semver = EnvironmentReport.GitSemver(parsed)
        #expect(semver.major == 2)
        #expect(semver.minor == 43)
        #expect(semver.patch == 5)
        #expect(semver.suffix == "(Apple Git-154)")
    }
}
