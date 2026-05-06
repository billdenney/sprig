// RecoverCommand.swift
//
// `sprigctl recover` — list (and eventually restore) ADR 0033 snapshot
// refs created by destructive operations. Per the ADR amendment, this
// is the headless equivalent of the macOS / Windows "Recover…" task
// window: anyone with a git checkout can see the safety net Sprig has
// laid down.
//
// This slice ships `--list` only. `--restore <ref>` is a follow-up
// slice — restoration creates a new snapshot of HEAD before checking
// out the older one (so the restore is itself reversible), which
// touches more of the destructive-op machinery.

import ArgumentParser
import Foundation
import GitCore
import RepoState
import SafetyKit

/// `sprigctl recover --list [<repo>] [--json]`
/// — list every `refs/sprig/snapshots/...` ref in the repo.
///
/// Default output is human-readable: one line per snapshot, sorted
/// newest first. `--json` emits a sorted-keys JSON array suitable for
/// piping into `jq` or other tooling.
struct RecoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "List ADR 0033 snapshot refs in a repo (--restore is a future slice)."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "List snapshot refs (currently the only supported mode).")
    var list: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary.")
    var json: Bool = false

    func run() async throws {
        guard list else {
            // Without --list there's nothing this subcommand does yet.
            // Surfacing this as a validation error rather than a default
            // behavior because adding `--restore` later should require an
            // explicit mode flag too — silently defaulting to list would
            // hide a footgun once both modes exist.
            throw ValidationError(
                "specify --list to enumerate snapshot refs (--restore is not yet implemented)"
            )
        }

        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()

        if json {
            try emitJSON(snapshots)
        } else {
            emitHuman(snapshots)
        }
    }

    private func emitHuman(_ snapshots: [Snapshot]) {
        var out = StdoutStream()
        guard !snapshots.isEmpty else {
            var err = StderrStream()
            print("# no snapshots under refs/sprig/snapshots/", to: &err)
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for snapshot in snapshots {
            let timestamp = formatter.string(from: snapshot.name.timestamp)
            let shortSHA = snapshot.sha.count >= 7 ? String(snapshot.sha.prefix(7)) : snapshot.sha
            print(
                "\(timestamp)  \(snapshot.name.op)  \(shortSHA)  \(snapshot.name.refName)",
                to: &out
            )
        }
    }

    private func emitJSON(_ snapshots: [Snapshot]) throws {
        let wire = snapshots.map(SnapshotWire.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(wire)
        if let text = String(data: data, encoding: .utf8) {
            var out = StdoutStream()
            print(text, to: &out)
        }
    }
}

// MARK: - JSON wire format

/// Same pattern as `LogCommand` and `StatusCommand`: keep the JSON
/// shape distinct from the public Swift types so the wire contract can
/// evolve independently (and gets dedicated docs / tests).
private struct SnapshotWire: Encodable {
    let refName: String
    let op: String
    let timestamp: Date
    let sha: String

    init(_ snapshot: Snapshot) {
        self.refName = snapshot.name.refName
        self.op = snapshot.name.op
        self.timestamp = snapshot.name.timestamp
        self.sha = snapshot.sha
    }
}
