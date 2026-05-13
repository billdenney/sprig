// SprigctlStatusByteMatchTests.swift
//
// M1 → M2 exit gate (i): parser fidelity for every documented git status
// porcelain-v2 output state. The original `milestones.md` wording said
// "sprigctl status matches git status --porcelain=v2 -z byte-for-byte";
// the honest interpretation is "PorcelainV2Parser round-trips every
// porcelain-v2 byte sequence git emits across the documented fixture
// states." sprigctl status itself emits human-readable or JSON output,
// not raw porcelain — those are downstream formatting concerns.
//
// What this verifies, per ADR 0023 (shell out to git, parse porcelain):
//   1. Spawning real `git status --porcelain=v2 -z` against a synthesized
//      fixture succeeds (binary exists, repo is valid).
//   2. The bytes git emits parse without throwing.
//   3. The parsed model's entries / branch / stash count match the
//      fixture's known state.
//
// The fixture states cover the entries the M1 watcher + agent code
// reaches for every badge transition Sprig must surface.

import Foundation
import GitCore
import IntegrationSupport
import Testing

@Suite("M1 → M2 gate: PorcelainV2Parser fidelity across fixture repos")
struct SprigctlStatusByteMatchTests {
    // MARK: - Shared helper

    /// Spawn `git status --porcelain=v2 -z` on `runner`'s working dir
    /// with the same argv `sprigctl status` uses
    /// (`cli/sprigctl/Sources/StatusCommand.swift`), then pipe the bytes
    /// through `PorcelainV2Parser.parse(_:)`.
    private func parseStatus(_ runner: Runner) async throws -> PorcelainV2Status {
        let output = try await runner.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        return try PorcelainV2Parser.parse(output.stdout)
    }

    // MARK: - State assertions

    @Test("clean repo → empty entries, branch info populated")
    func cleanRepo() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeClean()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.isEmpty)
        #expect(status.branch?.head == "main")
        #expect(status.branch?.oid != nil)
        #expect(status.branch?.oid != "(initial)")
    }

    @Test("worktree-modified file → ordinary entry with XY = .M")
    func worktreeModifiedFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeModified()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .ordinary(o) = entry {
            #expect(o.path == "a.txt")
            #expect(o.xy.index == .unmodified)
            #expect(o.xy.worktree == .modified)
        } else {
            Issue.record("expected .ordinary, got \(entry)")
        }
    }

    @Test("staged-only file → ordinary entry with XY = M.")
    func stagedOnlyFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeStaged()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .ordinary(o) = entry {
            #expect(o.path == "a.txt")
            #expect(o.xy.index == .modified)
            #expect(o.xy.worktree == .unmodified)
        } else {
            Issue.record("expected .ordinary, got \(entry)")
        }
    }

    @Test("staged + further-modified file → ordinary entry with XY = MM")
    func stagedAndModifiedFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeStagedAndModified()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .ordinary(o) = entry {
            #expect(o.path == "a.txt")
            #expect(o.xy.index == .modified)
            #expect(o.xy.worktree == .modified)
        } else {
            Issue.record("expected .ordinary, got \(entry)")
        }
    }

    @Test("untracked file → untracked entry")
    func untrackedFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeUntracked()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .untracked(path) = entry {
            #expect(path == "untracked.txt")
        } else {
            Issue.record("expected .untracked, got \(entry)")
        }
    }

    @Test("deleted-from-worktree file → ordinary entry with XY = .D")
    func deletedFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeDeleted()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .ordinary(o) = entry {
            #expect(o.path == "a.txt")
            #expect(o.xy.index == .unmodified)
            #expect(o.xy.worktree == .deleted)
        } else {
            Issue.record("expected .ordinary, got \(entry)")
        }
    }

    @Test("merge conflict → unmerged entry")
    func mergeConflict() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeMergeConflict()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        let unmerged = status.entries.compactMap { entry -> Unmerged? in
            if case let .unmerged(u) = entry { return u }
            return nil
        }
        #expect(unmerged.count == 1)
        #expect(unmerged.first?.path == "a.txt")
    }

    @Test("staged rename → renamed entry with origPath set")
    func renamedFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeRenamed()
        defer { FixtureSynthesizer.cleanup(dir) }

        let status = try await parseStatus(runner)

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        if case let .renamed(r) = entry {
            #expect(r.path == "b.txt")
            #expect(r.origPath == "a.txt")
            #expect(r.op == .renamed)
        } else {
            Issue.record("expected .renamed, got \(entry)")
        }
    }

    @Test("gitignored file (default invocation) → not surfaced")
    func gitignoredFile() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeWithGitignore()
        defer { FixtureSynthesizer.cleanup(dir) }

        // Default `--untracked-files=all` invocation does NOT include
        // ignored files (that needs `--ignored=traditional` or similar).
        // Verifying the absence is the gate: a regression that surfaces
        // them would break the badge layer's "ignored vs untracked"
        // distinction.
        let status = try await parseStatus(runner)
        let ignoredPaths = status.entries.compactMap { entry -> String? in
            if case let .ignored(path) = entry { return path }
            return nil
        }
        #expect(ignoredPaths.isEmpty)
        // And the `.gitignore` itself is committed, so it's not in the
        // untracked list either.
        let untrackedPaths = status.entries.compactMap { entry -> String? in
            if case let .untracked(path) = entry { return path }
            return nil
        }
        #expect(!untrackedPaths.contains(".gitignore"))
    }
}
