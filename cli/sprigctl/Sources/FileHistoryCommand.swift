// FileHistoryCommand.swift
//
// `sprigctl file-history <path>` — the headless face of ADR 0090: list a
// file's versions (via `git log --follow`), and `--restore <sha>` to
// bring one back into the worktree. Restore is fail-closed: the file's
// current bytes are backed up to a `refs/sprig/filebackup/` ref first
// (the macOS / Windows "Restore Previous Version…" window drives the same
// GitCore.FileHistory + SafetyKit.FileBackup engines).

import ArgumentParser
import Foundation
import GitCore
import SafetyKit

struct FileHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file-history",
        abstract: "Show a file's version history, or restore a previous version."
    )

    @Argument(help: "The file whose history to show (relative to the repo root).")
    var file: String

    @Option(
        name: .long,
        help: ArgumentHelp("Restore the file to its version at this commit SHA.", valueName: "sha")
    )
    var restore: String?

    @Option(name: .long, help: "Repository worktree root (defaults to the current directory).")
    var repo: String?

    func run() async throws {
        let repoURL = URL(fileURLWithPath: repo ?? FileManager.default.currentDirectoryPath).standardized
        let runner = Runner(defaultWorkingDirectory: repoURL)
        let revisions = try await FileHistory(runner: runner).revisions(of: file)

        guard !revisions.isEmpty else {
            var err = StderrStream()
            print("# no tracked history for \(file)", to: &err)
            throw ExitCode(1)
        }

        if let restore {
            try await runRestore(sha: restore, revisions: revisions, repoURL: repoURL, runner: runner)
        } else {
            emitList(revisions)
        }
    }

    private func emitList(_ revisions: [FileRevision]) {
        var out = StdoutStream()
        for revision in revisions {
            let shortSHA = String(revision.commitSHA.prefix(8))
            let renamed = revision.pathAtRevision == file ? "" : "  (was \(revision.pathAtRevision))"
            print(
                "\(shortSHA)  \(revision.authorDate)  \(revision.author)  \(revision.subject)\(renamed)",
                to: &out
            )
        }
    }

    private func runRestore(
        sha: String,
        revisions: [FileRevision],
        repoURL: URL,
        runner: Runner
    ) async throws {
        // Resolve the SHA prefix ourselves: blobObjectName uses the full
        // 40-char SHA, so git never sees the prefix and never flags an
        // ambiguous match. Mirror git's own behavior — refuse rather than
        // silently restore the newest of several matches.
        let matches = revisions.filter { $0.commitSHA.hasPrefix(sha) }
        guard !matches.isEmpty else {
            throw ValidationError("no version of \(file) found at commit \(sha)")
        }
        guard matches.count == 1 else {
            let candidates = matches.map { String($0.commitSHA.prefix(8)) }.joined(separator: ", ")
            throw ValidationError("ambiguous commit \(sha) for \(file); matches \(candidates) — use more characters")
        }
        let revision = matches[0]

        let catFile = try await CatFileBatch(repoURL: repoURL)
        defer { Task { await catFile.close() } }
        let bytes = try await FileHistory(runner: runner).contents(of: revision, using: catFile)

        // Fail-closed (also refuses a symlink path), then create any
        // missing parent directory so restoring a file whose folder was
        // removed recreates it.
        let saved = try await FileBackup(runner: runner).backupFile(at: file)
        let target = repoURL.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: target)

        var out = StdoutStream()
        print("Restored \(file) to its version at \(String(revision.commitSHA.prefix(8)))", to: &out)
        if let saved {
            print("Saved a copy of the previous \(file): \(saved.refName)", to: &out)
        }
    }
}
