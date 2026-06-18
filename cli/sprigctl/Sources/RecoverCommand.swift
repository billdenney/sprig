// RecoverCommand.swift
//
// `sprigctl recover` — list or restore ADR 0033 snapshot refs created
// by destructive operations. Per the ADR amendment, this is the
// headless equivalent of the macOS / Windows "Recover…" task window:
// anyone with a git checkout can see the safety net Sprig has laid
// down — and roll back to one with a single command.
//
// `--restore` does `git reset --hard <snapshot-ref>` after creating a
// new before-restore snapshot of HEAD, so the restore is itself
// reversible (re-restore the before-snapshot to undo).

import ArgumentParser
import Foundation
import GitCore
import RepoState
import SafetyKit

/// `sprigctl recover --list [<repo>] [--json]` or
/// `sprigctl recover --restore <snapshot-ref> [<repo>]`.
///
/// `--list` and `--restore` are mutually exclusive; exactly one must
/// be supplied. List output is human-readable by default; `--json`
/// emits a sorted-keys JSON array suitable for piping into `jq` or
/// other tooling.
struct RecoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "List or restore ADR 0033 snapshot refs in a repo."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "List snapshot refs in the repo. Mutually exclusive with --restore.")
    var list: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Restore the worktree to the named snapshot ref. Mutually exclusive with --list.",
            valueName: "snapshot-ref"
        )
    )
    var restore: String?

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary (only with --list).")
    var json: Bool = false

    func run() async throws {
        // Exactly-one-of validation: --list and --restore are mutually
        // exclusive, and at least one must be supplied. ArgumentParser
        // doesn't have a built-in "exactly one of these flags" so we
        // do it ourselves.
        switch (list, restore) {
        case (false, nil):
            throw ValidationError(
                "specify either --list (enumerate snapshots) or --restore <snapshot-ref>"
            )
        case (true, .some):
            throw ValidationError("--list and --restore are mutually exclusive")
        case (true, nil):
            try await runList()
        case let (false, .some(snapshotRef)):
            try await runRestore(ref: snapshotRef)
        }
    }

    // MARK: - --list

    private func runList() async throws {
        let runner = makeRunner()
        let index = SnapshotIndex(runner: runner)
        try await index.refresh()
        let snapshots = await index.list()

        if json {
            try emitJSON(snapshots)
        } else {
            emitHuman(snapshots)
        }
    }

    private func makeRunner() -> Runner {
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        return Runner(defaultWorkingDirectory: repoURL)
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

    // MARK: - --restore

    /// Op tag used for the before-restore snapshot. Distinguishes
    /// "I restored the repo at this time" from the destructive-op
    /// snapshots (`merge`, `rebase`, `reset-hard`, …) that the user
    /// might be restoring to. Now a shared SafetyKit constant — the
    /// Recover VM mints the same tag.
    static let beforeRestoreOp = SnapshotRefName.opRestore

    private func runRestore(ref: String) async throws {
        // Reject anything that doesn't parse as a snapshot ref before
        // we touch git. This keeps `--restore <some-other-branch>`
        // from accidentally rewinding HEAD via the recover tool;
        // arbitrary refs need `git reset --hard`, not Sprig.
        guard let parsed = SnapshotRefName.parse(ref) else {
            throw ValidationError(
                "ref does not match the snapshot format \(SnapshotRefName.prefix)<ts>/<op>: \(ref)"
            )
        }

        let runner = makeRunner()

        // Verify the ref actually exists in the repo. `rev-parse
        // --verify --quiet` exits non-zero if the ref is missing.
        let revParse = try await runner.run(
            ["rev-parse", "--verify", "--quiet", ref],
            throwOnNonZero: false
        )
        guard revParse.exitCode == 0 else {
            throw ValidationError("snapshot ref does not exist in this repo: \(ref)")
        }
        // Pin the target to its SHA: two restores in the same second
        // mint the SAME `<ts>/restore` before-snapshot name, so an
        // immediate undo (`--restore <before-ref>`) would otherwise
        // have its target overwritten by its own before-snapshot
        // before the reset reads it (caught by the Recover VM's
        // round-trip test).
        let targetSHA = revParse.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        // ADR 0079: a stash-drop safety copy points at the dropped
        // stash COMMIT, not a repo state — `reset --hard` would
        // wrongly move the branch onto it. Restore = put the entry
        // back in the stash list; worktree and HEAD untouched, so no
        // insurance refs are needed. Match the op family (`baseOp`),
        // not the raw op: a same-second second drop is minted as
        // `stash-drop-2` and must take this path too.
        if parsed.baseOp == SnapshotRefName.opStashDrop {
            try await restoreStashEntry(ref: ref, sha: targetSHA, runner: runner)
            return
        }

        // Uncommitted-work insurance (ADR 0033 amendment): the hard
        // reset below would eat dirty tracked changes AND untracked
        // files would survive confusingly half-restored — capture the
        // whole working tree into an ADR 0075 backup ref first. Nil
        // when the tree is clean.
        let uncommittedBackup = try await WorktreeBackup(runner: runner).createBackupIfDirty()

        // Take a snapshot of the current HEAD so the restore is
        // itself reversible — re-running `recover --restore` against
        // this new ref returns to pre-restore state. Per ADR 0033's
        // amendment.
        let writer = SnapshotWriter(runner: runner)
        let beforeSnapshot = try await writer.createSnapshot(op: RecoverCommand.beforeRestoreOp)

        // Now reset the worktree to the snapshot. `git reset --hard`
        // moves HEAD, index, and worktree to the target's commit;
        // committed state is captured in `beforeSnapshot`, uncommitted
        // state in `uncommittedBackup`.
        _ = try await runner.run(["reset", "--hard", targetSHA])

        var out = StdoutStream()
        print("Restored worktree to \(ref)", to: &out)
        if let uncommittedBackup {
            print("Uncommitted work saved: \(uncommittedBackup.refName)", to: &out)
            print(
                "Run `sprigctl backup --restore \(uncommittedBackup.refName)` to bring it back.",
                to: &out
            )
        }
        print("Before-restore snapshot: \(beforeSnapshot.refName)", to: &out)
        print("Run `sprigctl recover --restore \(beforeSnapshot.refName)` to undo.", to: &out)
    }

    /// `git stash store <sha>` with the stash commit's own subject as
    /// the reflog message, so the restored entry reads exactly like
    /// it did before the drop.
    private func restoreStashEntry(ref: String, sha: String, runner: Runner) async throws {
        let subject = try await runner.run(["log", "-1", "--format=%s", sha])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["stash", "store", "-m", subject, sha])
        var out = StdoutStream()
        print("Restored stash entry from \(ref)", to: &out)
        print("It is back in the stash list as stash@{0}.", to: &out)
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
