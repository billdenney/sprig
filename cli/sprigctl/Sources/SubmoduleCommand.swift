// SubmoduleCommand.swift
//
// `sprigctl submodule --status [<repo>]` — surfaces SubmoduleKit's
// typed `git submodule status` parser to the CLI. Mirrors `sprigctl
// lfs --status`'s shape so users have one mental model across the
// CLI; the only mode today is `--status`, with room for future
// per-submodule operations as separate flag-modes once SubmoduleKit
// grows mutating ops (gated on SafetyKit hooks per CLAUDE.md rule 8).

import ArgumentParser
import Foundation
import GitCore
import SubmoduleKit

struct SubmoduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submodule",
        abstract: "Inspect submodule status (clean / out-of-date / not-initialized / merge-conflict)."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "List each submodule with its state, recorded SHA, and ref description.")
    var status: Bool = false

    @Flag(name: .long, help: "Pass --recursive to git so nested submodules are included.")
    var recursive: Bool = false

    @Flag(name: .long, help: "Pass --cached to git so SHAs reflect the super-repo's recorded pointers, not the submodule's checkout HEAD.")
    var cached: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        guard status else {
            throw ValidationError(
                "specify --status to list submodule status (other modes will follow once SubmoduleKit grows mutating ops)"
            )
        }
        try await runStatus()
    }

    private func runStatus() async throws {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)

        let entries: [SubmoduleEntry]
        do {
            entries = try await SubmoduleStatus.fetch(
                at: repoURL,
                runner: runner,
                recursive: recursive,
                source: cached ? .recorded : .workingTree
            )
        } catch let error as GitError {
            // `git submodule status` exits non-zero when run outside a
            // repository; surface a CLI-shaped diagnostic rather than
            // a Swift backtrace.
            throw ValidationError(String(describing: error))
        }

        if json {
            try emitJSON(entries: entries)
        } else {
            emitHuman(entries: entries)
        }
    }

    // MARK: - Human output

    private func emitHuman(entries: [SubmoduleEntry]) {
        var out = StdoutStream()
        if entries.isEmpty {
            print("no submodules", to: &out)
            return
        }
        let plural = entries.count == 1 ? "" : "s"
        print("\(entries.count) submodule\(plural)", to: &out)
        for entry in entries {
            let shaPrefix = String(entry.recordedSHA.prefix(Self.shaPrefixLength))
            let label = Self.stateLabel(entry.state)
                .padding(toLength: Self.stateColumnWidth, withPad: " ", startingAt: 0)
            var line = "  \(label)\(shaPrefix)  \(entry.path)"
            if let ref = entry.refDescription {
                line += "  (\(ref))"
            }
            print(line, to: &out)
        }
    }

    // `static` so AsyncParsableCommand's synthesized Decodable conformance
    // doesn't try to decode them as command-line arguments.
    private static let stateColumnWidth = 16
    private static let shaPrefixLength = 7

    private static func stateLabel(_ state: SubmoduleEntry.State) -> String {
        switch state {
        case .clean: "clean"
        case .outOfDate: "outOfDate"
        case .notInitialized: "notInitialized"
        case .mergeConflict: "mergeConflict"
        }
    }

    // MARK: - JSON output

    private func emitJSON(entries: [SubmoduleEntry]) throws {
        let wire = SubmoduleStatusWire(entries: entries.map(SubmoduleStatusWire.Entry.init))
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
/// SubmoduleKit's internal types.
private struct SubmoduleStatusWire: Encodable {
    struct Entry: Encodable {
        let state: String
        let recordedSHA: String
        let path: String
        let refDescription: String?

        init(_ entry: SubmoduleEntry) {
            self.state = Self.label(entry.state)
            self.recordedSHA = entry.recordedSHA
            self.path = entry.path
            self.refDescription = entry.refDescription
        }

        private static func label(_ state: SubmoduleEntry.State) -> String {
            switch state {
            case .clean: "clean"
            case .outOfDate: "outOfDate"
            case .notInitialized: "notInitialized"
            case .mergeConflict: "mergeConflict"
            }
        }
    }

    let entries: [Entry]
}
