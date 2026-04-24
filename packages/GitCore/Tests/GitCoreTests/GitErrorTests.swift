@testable import GitCore
import Testing

@Suite("GitError")
struct GitErrorTests {
    @Test
    func `binaryNotFound description includes the probed path`() {
        let error = GitError.binaryNotFound(probedPath: "/usr/local/bin")
        #expect(error.description.contains("/usr/local/bin"))
    }

    @Test
    func `nonZeroExit description includes the exit code`() {
        let error = GitError.nonZeroExit(
            command: ["status"],
            exitCode: 128,
            stderr: "fatal: not a git repository",
            stdout: ""
        )
        #expect(error.description.contains("128"))
        #expect(error.description.contains("fatal"))
    }
}
