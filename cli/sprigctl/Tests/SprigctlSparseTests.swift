// SprigctlSparseTests.swift
//
// `sprigctl sparse` end-to-end CLI tests (ADR 0089). Own file to keep
// SwiftLint's file_length / type_body_length caps happy as the surface
// grows. The CLI is the headless face of selective sync: list / set /
// disable, with the same fail-closed guard the GUI uses and a
// backup-saving --force escape hatch.

import Foundation
import Testing

@Suite("sprigctl sparse", .serialized)
struct SprigctlSparseTests {
    private func seedRepo(_ label: String) async throws -> URL {
        let repo = try Sprigctl.mkRepo(label)
        try await Sprigctl.initRepo(at: repo)
        try await Sprigctl.spawnGit(["config", "core.autocrlf", "false"], cwd: repo)
        for folder in ["alpha", "beta", "gamma"] {
            let sub = repo.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Sprigctl.write("\(folder)\n", to: sub.appendingPathComponent("file.txt"))
        }
        try await Sprigctl.spawnGit(["add", "-A"], cwd: repo)
        try await Sprigctl.spawnGit(["commit", "-m", "seed"], cwd: repo)
        return repo
    }

    private func exists(_ repo: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(relative).path)
    }

    @Test("sparse --help shows usage")
    func help() async throws {
        let out = try await Sprigctl.run(["sparse", "--help"])
        #expect(out.exitCode == 0)
        #expect(out.stdout.lowercased().contains("sparse"))
        #expect(out.stdout.contains("list"))
        #expect(out.stdout.contains("set"))
        #expect(out.stdout.contains("disable"))
    }

    @Test("sparse list shows all folders kept when selective sync is off")
    func listOff() async throws {
        let repo = try await seedRepo("list-off")
        defer { try? FileManager.default.removeItem(at: repo) }
        let out = try await Sprigctl.run(["sparse", "list", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("off"))
        #expect(out.stdout.contains("[x] alpha"))
        #expect(out.stdout.contains("[x] beta"))
    }

    @Test("sparse set keeps the named folders and de-materializes the rest")
    func setKeepsAndDrops() async throws {
        let repo = try await seedRepo("set")
        defer { try? FileManager.default.removeItem(at: repo) }

        let out = try await Sprigctl.run(["sparse", "set", "alpha", "--repo", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Keeping: alpha"))
        #expect(exists(repo, "alpha/file.txt"))
        #expect(!exists(repo, "beta/file.txt"))

        let list = try await Sprigctl.run(["sparse", "list", repo.path])
        #expect(list.stdout.contains("on"))
        #expect(list.stdout.contains("[x] alpha"))
        #expect(list.stdout.contains("[ ] beta"))
    }

    @Test("sparse set refuses to drop a folder with unsaved work (no --force)")
    func setFailsClosed() async throws {
        let repo = try await seedRepo("blocked")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Sprigctl.write("new\n", to: repo.appendingPathComponent("beta/note.txt"))

        let out = try await Sprigctl.run(["sparse", "set", "alpha", "gamma", "--repo", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("Refusing"))
        #expect(out.stderr.contains("beta"))
        // Nothing was applied: beta is still present.
        #expect(exists(repo, "beta/note.txt"))
    }

    @Test("sparse set names staged changes in the refusal text (no --force)")
    func setReportsStagedChange() async throws {
        let repo = try await seedRepo("staged")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Sprigctl.write("staged\n", to: repo.appendingPathComponent("beta/file.txt"))
        try await Sprigctl.spawnGit(["add", "beta/file.txt"], cwd: repo)

        let out = try await Sprigctl.run(["sparse", "set", "alpha", "gamma", "--repo", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("beta"))
        #expect(out.stderr.contains("staged changes"))
        #expect(exists(repo, "beta/file.txt"))
    }

    @Test("sparse set refuses a non-cone pattern repo rather than mangling it")
    func setRefusesPatternMode() async throws {
        let repo = try await seedRepo("patternmode")
        defer { try? FileManager.default.removeItem(at: repo) }
        try await Sprigctl.spawnGit(
            ["sparse-checkout", "set", "--no-cone", "/*", "!/beta/"], cwd: repo
        )
        let out = try await Sprigctl.run(["sparse", "set", "alpha", "--repo", repo.path])
        #expect(out.exitCode != 0)
        #expect(out.stderr.contains("advanced sparse-checkout patterns"))
    }

    @Test("sparse set --force saves a backup, then removes the folder")
    func setForceSavesBackup() async throws {
        let repo = try await seedRepo("force")
        defer { try? FileManager.default.removeItem(at: repo) }
        try Sprigctl.write("precious\n", to: repo.appendingPathComponent("beta/note.txt"))

        let out = try await Sprigctl.run(
            ["sparse", "set", "alpha", "gamma", "--force", "--repo", repo.path]
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("Saved a backup"))
        #expect(out.stdout.contains("refs/sprig/backup/"))
        #expect(!exists(repo, "beta/note.txt"))
    }

    @Test("sparse disable restores the full worktree")
    func disableRestores() async throws {
        let repo = try await seedRepo("disable")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Sprigctl.run(["sparse", "set", "alpha", "--repo", repo.path])
        #expect(!exists(repo, "beta/file.txt"))

        let out = try await Sprigctl.run(["sparse", "disable", repo.path])
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("off"))
        #expect(exists(repo, "beta/file.txt"))
        #expect(exists(repo, "gamma/file.txt"))
    }
}
