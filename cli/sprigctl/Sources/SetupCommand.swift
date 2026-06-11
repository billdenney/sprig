// SetupCommand.swift
//
// `sprigctl setup` — the explicit-consent face of the onboarding
// provisions (§11's "ask less" intervention levels: silent defaults
// are written ONCE, with consent, then never asked about again).
// First provision: `--global-ignore` (ADR 0049 amendment), the
// global OS-noise excludes file.

import ArgumentParser
import Foundation
import GitCore

/// `sprigctl setup --global-ignore [<repo>]`
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "One-time provisions the onboarding flow performs (explicit consent)."
    )

    @Argument(help: "Directory to resolve git config from (defaults to the current directory).")
    var path: String?

    @Flag(
        name: .customLong("global-ignore"),
        help: ArgumentHelp(
            "Add OS-noise patterns (.DS_Store, Thumbs.db, …) to your GLOBAL excludes file.",
            discussion: "Appends under a one-time Sprig header; never rewrites "
                + "existing content and never touches git config — when "
                + "core.excludesFile is unset, git's own default location "
                + "($XDG_CONFIG_HOME/git/ignore) is used. After this, OS "
                + "droppings stop showing as untracked in every repository "
                + "(the ask-less principle: one consent, zero future questions)."
        )
    )
    var globalIgnore: Bool = false

    func run() async throws {
        guard globalIgnore else {
            throw ValidationError("nothing to do — pass --global-ignore")
        }
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let result = try await GlobalExcludes.provision(runner: runner)

        var out = StdoutStream()
        print("Global excludes file: \(result.file.path)", to: &out)
        if result.added.isEmpty {
            print("Already covered — nothing to add.", to: &out)
        } else {
            print("Added \(result.added.count) pattern(s):", to: &out)
            for line in result.added {
                print("  \(line)", to: &out)
            }
        }
    }
}
