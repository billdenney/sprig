// LFSCommand.swift
//
// `sprigctl lfs --status [<repo>]` — surfaces LFSKit's install probe
// + .gitattributes scanner to the CLI. Mirrors `sprigctl conflicts`'s
// flag-style mode discrimination so users have one mental model
// across the CLI; `--status` is the only mode today, with room for
// `--check <path>` (per-file LFS-tracked + pointer detection) as a
// follow-up.

import ArgumentParser
import Foundation
import GitCore
import LFSKit

struct LFSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lfs",
        abstract: "Inspect git-lfs install state and LFS-tracked patterns."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "Show install state and LFS-tracked patterns.")
    var status: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        guard status else {
            throw ValidationError(
                "specify --status to inspect git-lfs state (other modes will follow)"
            )
        }
        try await runStatus()
    }

    private func runStatus() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)

        // `LFSInstall.probe` distinguishes "git-lfs not installed"
        // (returned as fields on the status struct — fine, that's
        // what we report) from "git itself isn't usable" (thrown as
        // `LFSProbeError.gitNotAvailable`). Re-throw the latter as
        // a CLI-level validation error so the user sees a usable
        // diagnostic instead of a Swift backtrace.
        let install: LFSInstallStatus
        do {
            install = try await LFSInstall.probe(runner: runner)
        } catch let error as LFSProbeError {
            throw ValidationError(String(describing: error))
        }
        let rules = readLFSRules(repoURL: repoURL)

        if json {
            try emitJSON(install: install, rules: rules)
        } else {
            emitHuman(install: install, rules: rules)
        }
    }

    /// Read `.gitattributes` from the repo root and extract LFS
    /// rules. Returns `[]` for a missing / unreadable / non-UTF-8
    /// file — repos without a `.gitattributes` are common (no LFS
    /// configured) and not an error.
    private func readLFSRules(repoURL: URL) -> [LFSAttributeRule] {
        let attributesURL = repoURL.appendingPathComponent(".gitattributes")
        guard let data = try? Data(contentsOf: attributesURL) else { return [] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return GitAttributesLFSParser.extractLFSRules(text)
    }

    // MARK: - Human output

    private func emitHuman(install: LFSInstallStatus, rules: [LFSAttributeRule]) {
        var out = StdoutStream()
        let binaryLine = install.binaryVersion.map { "installed (\($0))" } ?? "not installed"
        print("git-lfs:    \(binaryLine)", to: &out)
        print("configured: \(install.configured ? "yes" : "no")", to: &out)
        print("ready:      \(install.isReady ? "yes" : "no")", to: &out)

        if rules.isEmpty {
            print("tracked:    no LFS rules in .gitattributes", to: &out)
        } else {
            let plural = rules.count == 1 ? "" : "s"
            print(
                "tracked:    \(rules.count) LFS pattern\(plural) in .gitattributes",
                to: &out
            )
            for rule in rules {
                print("  \(rule.pattern)  (line \(rule.lineNumber))", to: &out)
            }
        }
    }

    // MARK: - JSON output

    private func emitJSON(install: LFSInstallStatus, rules: [LFSAttributeRule]) throws {
        let wire = LFSStatusWire(install: install, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(wire)
        if let text = String(data: data, encoding: .utf8) {
            var out = StdoutStream()
            print(text, to: &out)
        }
    }
}

// MARK: - JSON wire format

/// Same pattern as the other sprigctl JSON outputs: a dedicated wire
/// struct so the CLI's JSON contract can evolve independently of
/// LFSKit's internal types.
private struct LFSStatusWire: Encodable {
    struct Rule: Encodable {
        let pattern: String
        let lineNumber: Int
    }

    let binaryAvailable: Bool
    let binaryVersion: String?
    let configured: Bool
    let isReady: Bool
    let trackedPatterns: [Rule]

    init(install: LFSInstallStatus, rules: [LFSAttributeRule]) {
        self.binaryAvailable = install.binaryAvailable
        self.binaryVersion = install.binaryVersion
        self.configured = install.configured
        self.isReady = install.isReady
        self.trackedPatterns = rules.map { Rule(pattern: $0.pattern, lineNumber: $0.lineNumber) }
    }
}
