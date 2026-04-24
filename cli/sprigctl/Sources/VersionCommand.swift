import ArgumentParser
import Foundation
import GitCore

/// `sprigctl version` — print sprigctl's own version plus the host git version.
struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print sprigctl and system git versions."
    )

    static let toolVersion = "0.1.0"

    func run() async throws {
        print("sprigctl \(Self.toolVersion)")
        let runner = Runner()
        do {
            let gitVersion = try await runner.version()
            print("git \(gitVersion)")
            if !gitVersion.meetsMinimum {
                var err = StderrStream()
                print(
                    "warning: host git is below Sprig's minimum (\(GitVersion.minimumSupported)).",
                    to: &err
                )
            }
        } catch let error as GitError {
            print("git unavailable (\(error.description))")
        }
    }
}
