@testable import GitCore
import Testing

@Suite("GitError")
struct GitErrorTests {
    @Test("binaryNotFound description includes the probed path")
    func binaryNotFoundDescriptionIncludesTheProbedPath() {
        let error = GitError.binaryNotFound(probedPath: "/usr/local/bin")
        #expect(error.description.contains("/usr/local/bin"))
    }

    @Test("nonZeroExit description includes the exit code")
    func nonZeroExitDescriptionIncludesTheExitCode() {
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
