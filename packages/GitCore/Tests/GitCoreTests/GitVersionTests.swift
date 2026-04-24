@testable import GitCore
import Testing

@Suite("GitVersion parsing")
struct GitVersionTests {
    @Test
    func `parses vanilla git version 2.43.0`() throws {
        let version = try #require(GitVersion.parse("git version 2.43.0"))
        #expect(version.major == 2)
        #expect(version.minor == 43)
        #expect(version.patch == 0)
        #expect(version.suffix.isEmpty)
    }

    @Test
    func `parses Apple-bundled git version 2.39.5 (Apple Git-154)`() throws {
        let version = try #require(
            GitVersion.parse("git version 2.39.5 (Apple Git-154)")
        )
        #expect(version.major == 2)
        #expect(version.minor == 39)
        #expect(version.patch == 5)
        #expect(version.suffix == "(Apple Git-154)")
    }

    @Test
    func `parses two-component version with implied patch 0`() throws {
        let version = try #require(GitVersion.parse("git version 2.44"))
        #expect(version.patch == 0)
    }

    @Test
    func `trims trailing whitespace`() throws {
        let version = try #require(GitVersion.parse("git version 2.43.0\n"))
        #expect(version.minor == 43)
    }

    @Test
    func `returns nil for unrecognized output`() {
        #expect(GitVersion.parse("hg version 6.7.2") == nil)
        #expect(GitVersion.parse("") == nil)
        #expect(GitVersion.parse("git version abc") == nil)
    }

    @Test
    func `comparison is lexicographic on major/minor/patch`() {
        #expect(
            GitVersion(major: 2, minor: 39, patch: 0) <
                GitVersion(major: 2, minor: 39, patch: 1)
        )
        #expect(
            GitVersion(major: 2, minor: 39, patch: 9) <
                GitVersion(major: 2, minor: 40, patch: 0)
        )
        #expect(
            !(
                GitVersion(major: 2, minor: 43, patch: 0) <
                    GitVersion(major: 2, minor: 43, patch: 0)
            )
        )
    }

    @Test
    func `meetsMinimum gates at 2.39`() {
        #expect(GitVersion(major: 2, minor: 39, patch: 0).meetsMinimum)
        #expect(GitVersion(major: 2, minor: 43, patch: 0).meetsMinimum)
        #expect(!GitVersion(major: 2, minor: 38, patch: 9).meetsMinimum)
        #expect(!GitVersion(major: 1, minor: 99, patch: 0).meetsMinimum)
    }
}
