// BackupCommand.swift
//
// `sprigctl backup` — list, create, and restore ADR 0075 worktree
// backups (`refs/sprig/backup/<ts>/<branch>`): the CLI face of the
// agent's periodic uncommitted-work insurance, and the recovery path
// when it pays off.

import ArgumentParser
import Foundation
import GitCore
import SafetyKit

/// `sprigctl backup --list [--json]` / `--now` / `--restore <ref>`.
struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "List, create, or restore ADR 0075 uncommitted-work backups."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    @Flag(name: .long, help: "List backup refs, newest first.")
    var list: Bool = false

    @Flag(name: .long, help: "Back up the dirty working tree right now (no-op when clean).")
    var now: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Restore the named backup over the working tree.",
            discussion: "Fail-closed: the current dirty state is backed up first, "
                + "so the restore itself can be undone. Additive — files created "
                + "after the backup are left in place; the index is untouched.",
            valueName: "backup-ref"
        )
    )
    var restore: String?

    @Flag(name: .long, help: "Emit JSON instead of a human-readable summary (with --list).")
    var json: Bool = false

    func run() async throws {
        let modes = [list, now, restore != nil].count(where: { $0 })
        guard modes == 1 else {
            throw ValidationError("specify exactly one of --list, --now, or --restore <ref>")
        }
        let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized
        let backup = WorktreeBackup(runner: Runner(defaultWorkingDirectory: repoURL))

        if list {
            try await runList(backup)
        } else if now {
            try await runNow(backup)
        } else if let restore {
            try await runRestore(backup, ref: restore)
        }
    }

    private func runList(_ backup: WorktreeBackup) async throws {
        let entries = try await backup.backups()
        if json {
            try emitJSON(entries)
            return
        }
        var out = StdoutStream()
        guard !entries.isEmpty else {
            var err = StderrStream()
            print("# no backups under \(BackupRefName.prefix)", to: &err)
            return
        }
        for entry in entries {
            print("\(entry.ref.refName) \(String(entry.sha.prefix(8)))", to: &out)
        }
    }

    private func runNow(_ backup: WorktreeBackup) async throws {
        var out = StdoutStream()
        if let ref = try await backup.createBackupIfDirty() {
            print("backed up: \(ref.refName)", to: &out)
        } else {
            print("nothing to back up: working tree is clean", to: &out)
        }
    }

    private func runRestore(_ backup: WorktreeBackup, ref: String) async throws {
        let outcome = try await backup.restore(ref)
        var out = StdoutStream()
        print("restored: \(outcome.restoredFrom.refName)", to: &out)
        if let pre = outcome.preRestoreBackup {
            print("pre-restore state saved: \(pre.refName)", to: &out)
        }
    }

    private struct BackupJSON: Codable {
        var ref: String
        var sha: String
        var branchLabel: String
    }

    private func emitJSON(_ entries: [WorktreeBackupEntry]) throws {
        let payload = entries.map { entry in
            BackupJSON(
                ref: entry.ref.refName,
                sha: entry.sha,
                branchLabel: entry.ref.branchLabel
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        var out = StdoutStream()
        print(String(data: data, encoding: .utf8) ?? "[]", to: &out)
    }
}
