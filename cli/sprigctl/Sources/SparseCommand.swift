// SparseCommand.swift
//
// `sprigctl sparse` — the headless face of ADR 0089 selective sync:
// list / set / disable the cone-mode sparse-checkout that controls
// which top-level folders are materialized on disk. The macOS / Windows
// "Choose folders to keep on this Mac…" window drives the same
// `GitCore.SparseCheckout` engine.
//
// `set` fails closed when dropping a folder would strand uncommitted or
// untracked work (matching the GUI). `--force` mints an ADR 0075
// working-tree backup FIRST, then removes the folders anyway — the work
// is restorable via `sprigctl backup --restore`.

import ArgumentParser
import Foundation
import GitCore
import SafetyKit

struct SparseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sparse",
        abstract: "Choose which top-level folders to keep on disk (cone-mode sparse-checkout).",
        subcommands: [SparseListCommand.self, SparseSetCommand.self, SparseDisableCommand.self]
    )
}

// MARK: - sparse list

struct SparseListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show the folder picker state: which top-level folders are kept on disk."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    func run() async throws {
        let sparse = SparseCheckout(runner: sparseRunner(path))
        let selection = try await sparse.currentSelection()
        let directories = try await sparse.topLevelDirectories()
        var out = StdoutStream()
        switch selection {
        case .full:
            print("selective sync: off — all folders are on this computer", to: &out)
            for directory in directories {
                print("[x] \(directory)", to: &out)
            }
        case let .cone(kept):
            let keptSet = Set(kept)
            print("selective sync: on", to: &out)
            for directory in directories {
                print("\(keptSet.contains(directory) ? "[x]" : "[ ]") \(directory)", to: &out)
            }
        case .unsupportedPatternMode:
            print("selective sync: on — advanced patterns (use the git CLI to change them)", to: &out)
            for directory in directories {
                print("[?] \(directory)", to: &out)
            }
        }
    }
}

// MARK: - sparse set

struct SparseSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Keep exactly the named top-level folders on disk; remove the rest."
    )

    @Option(name: .long, help: "Repository worktree root (defaults to the current directory).")
    var repo: String?

    @Flag(
        name: .long,
        help: "Remove folders with unsaved work anyway, saving a backup first."
    )
    var force: Bool = false

    @Argument(help: "Top-level folders to keep on disk.")
    var directories: [String] = []

    func run() async throws {
        let runner = sparseRunner(repo)
        let sparse = SparseCheckout(runner: runner)

        if case .unsupportedPatternMode = try await sparse.currentSelection() {
            var err = StderrStream()
            print(
                "This repository uses advanced sparse-checkout patterns; change them with the git CLI.",
                to: &err
            )
            throw ExitCode(1)
        }

        let plan = try await sparse.planChange(to: directories)

        if !plan.isCleanToApply, !force {
            var err = StderrStream()
            print("Refusing: these folders have unsaved work and would be set aside:", to: &err)
            for blocked in plan.blockedDrops {
                print("  \(blocked.name) — \(reasonsText(blocked.reasons))", to: &err)
            }
            print("Save or set the work aside, or re-run with --force (a backup is saved first).", to: &err)
            throw ExitCode(1)
        }

        var out = StdoutStream()
        if force, !plan.blockedDrops.isEmpty {
            let made = try await WorktreeBackup(runner: runner).createBackupIfDirty()
            try await sparse.forciblyClearDirectories(plan.blockedDrops.map(\.name))
            if let made {
                print("Saved a backup of unsaved work: \(made.refName)", to: &out)
                print("Restore it with: sprigctl backup --restore \(made.refName)", to: &out)
            }
        }

        if case .full = try await sparse.currentSelection() {
            try await sparse.enableConeMode()
        }
        try await sparse.set(directories)
        print("Keeping: \(directories.sorted().joined(separator: ", "))", to: &out)
    }
}

// MARK: - sparse disable

struct SparseDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Turn selective sync off — restore the full worktree."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

    func run() async throws {
        try await SparseCheckout(runner: sparseRunner(path)).disable()
        var out = StdoutStream()
        print("selective sync: off — all folders restored", to: &out)
    }
}

// MARK: - Shared helpers

private func sparseRunner(_ path: String?) -> Runner {
    let repoURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath).standardized
    return Runner(defaultWorkingDirectory: repoURL)
}

private func reasonsText(_ reasons: Set<DirtyReason>) -> String {
    var parts: [String] = []
    if reasons.contains(.unsavedChange) { parts.append("unsaved edits") }
    if reasons.contains(.stagedChange) { parts.append("staged changes") }
    if reasons.contains(.untrackedFile) { parts.append("new files") }
    if reasons.contains(.conflict) { parts.append("merge conflicts") }
    return parts.joined(separator: ", ")
}
