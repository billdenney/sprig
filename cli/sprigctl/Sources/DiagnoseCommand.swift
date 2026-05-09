// DiagnoseCommand.swift
//
// `sprigctl diagnose [<repo>]` — emits an `EnvironmentReport` for
// support / issue templates. Mirrors the `sprigctl lfs --status` /
// `sprigctl submodule --status` shape, but uses positional-mode
// rather than a flag-mode discriminator: there's only one mode
// here, and there's no obvious follow-up mode that would make the
// flag worthwhile (per-repo specifics live in the existing
// per-package surfaces — `lfs --check`, `submodule --status`).
//
// Engine version is `VersionCommand.toolVersion` so a single
// constant feeds both `sprigctl version` and the diagnose envelope.

import ArgumentParser
import DiagKit
import Foundation
import GitCore

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Emit an environment-report envelope for support / issue templates."
    )

    @Argument(
        help: """
        Repository worktree root (defaults to the current directory). Used as the runner's cwd; \
        doesn't affect the report shape.
        """
    )
    var path: String?

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)

        let report = await EnvironmentCollector.collect(
            runner: runner,
            engineVersion: VersionCommand.toolVersion
        )

        if json {
            try emitJSON(report)
        } else {
            emitHuman(report)
        }
    }

    // MARK: - Human output

    private func emitHuman(_ report: EnvironmentReport) {
        var out = StdoutStream()
        print("sprigctl:    \(report.engine.version)", to: &out)
        print(
            "os:          \(report.os.name) (\(report.os.architecture))",
            to: &out
        )
        print("os-version:  \(report.os.versionString)", to: &out)

        if let raw = report.git.gitVersionRaw {
            print("git:         \(raw)", to: &out)
            if let semver = report.git.gitVersion {
                let coreLine = "             parsed=\(semver.major).\(semver.minor).\(semver.patch)"
                if semver.suffix.isEmpty {
                    print(coreLine, to: &out)
                } else {
                    print("\(coreLine) \(semver.suffix)", to: &out)
                }
            }
        } else {
            print("git:         not available", to: &out)
        }

        if let lfs = report.git.gitLFSVersionRaw {
            print("git-lfs:     \(lfs)", to: &out)
        } else {
            print("git-lfs:     not installed", to: &out)
        }

        let formatter = ISO8601DateFormatter()
        print("collected:   \(formatter.string(from: report.generatedAt))", to: &out)
    }

    // MARK: - JSON output

    /// Re-encodes the `EnvironmentReport` directly. Wire shape is
    /// owned by DiagKit (so it can stay stable across CLI changes);
    /// this just streams it to stdout.
    private func emitJSON(_ report: EnvironmentReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        if let text = String(data: data, encoding: .utf8) {
            var out = StdoutStream()
            print(text, to: &out)
        }
    }
}
