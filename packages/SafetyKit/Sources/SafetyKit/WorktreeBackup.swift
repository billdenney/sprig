// WorktreeBackup.swift
//
// ADR 0075 — Time-Machine-style insurance for uncommitted work
// (beginner-affordances item 2.2): periodically snapshot the dirty
// working tree (tracked changes AND untracked files) into a commit
// reachable only from `refs/sprig/backup/<ts>/<branch>`, without
// touching HEAD, the index, the working tree, or running any hooks.
//
// Mechanics (all plumbing, no porcelain side effects):
//   1. Dirty check via `status --porcelain -z` (any record counts —
//      a beginner's in-progress work is often untracked).
//   2. A THROWAWAY index file (`GIT_INDEX_FILE` env override on a
//      derived Runner): `read-tree HEAD` (or `--empty` on an unborn
//      branch) → `add -A` → `write-tree`. The real index never
//      changes.
//   3. Identical-tree dedup: if the newest backup for this branch
//      already has this exact tree, return it instead of minting a
//      twin (a dirty-but-unchanged tree across ticks costs nothing).
//   4. `commit-tree` (+ `-p HEAD` when HEAD exists) → `update-ref`.
//
// Restore is fail-closed: it FIRST backs up the current dirty state,
// then `git restore --source=<backup> --worktree -- :/` — additive
// over the working tree (files created after the backup are left in
// place), index untouched.
//
// Growth is bounded by ``prune(olderThan:)`` (the agent runs it every
// tick with the configured TTL); deleting the refs makes the backup
// commits unreachable, so normal `git gc` reclaims the objects.

import Foundation
import GitCore

/// One `refs/sprig/backup/<ts>/<branch-label>` ref name.
public struct BackupRefName: Sendable, Equatable, Hashable {
    public static let prefix = "refs/sprig/backup/"

    /// Snapshot instant (UTC, second precision — same format as
    /// ADR 0033 snapshot refs).
    public let timestamp: Date
    /// Sanitized branch label (`feature-x` for `feature/x`,
    /// `detached` when HEAD isn't on a branch).
    public let branchLabel: String

    public init?(timestamp: Date, branchLabel: String) {
        let label = Self.sanitize(branchLabel)
        guard !label.isEmpty else { return nil }
        self.timestamp = timestamp
        self.branchLabel = label
    }

    public var refName: String {
        "\(Self.prefix)\(SnapshotRefName.formatTimestamp(timestamp))/\(branchLabel)"
    }

    /// Parse a full ref name; nil for anything that isn't exactly
    /// `refs/sprig/backup/<16-char-ts>/<label>`.
    public static func parse(_ refName: String) -> BackupRefName? {
        guard refName.hasPrefix(prefix) else { return nil }
        let rest = refName.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let date = SnapshotRefName.parseTimestamp(String(parts[0])),
              !parts[1].isEmpty
        else { return nil }
        return BackupRefName(timestamp: date, branchLabel: String(parts[1]))
    }

    /// Branch names can contain `/` (would add ref path segments) and
    /// other ref-hostile characters; map everything outside
    /// `[A-Za-z0-9._-]` to `-`.
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }
}

/// A listed backup: where it is + what it points at.
public struct WorktreeBackupEntry: Sendable, Equatable {
    public let ref: BackupRefName
    public let sha: String

    public init(ref: BackupRefName, sha: String) {
        self.ref = ref
        self.sha = sha
    }
}

/// Outcome of ``WorktreeBackup/restore(_:)``.
public struct WorktreeRestoreOutcome: Sendable, Equatable {
    /// The backup that was restored over the working tree.
    public let restoredFrom: BackupRefName
    /// The fail-closed backup of the pre-restore dirty state, or nil
    /// when the tree was clean going in.
    public let preRestoreBackup: BackupRefName?

    public init(restoredFrom: BackupRefName, preRestoreBackup: BackupRefName?) {
        self.restoredFrom = restoredFrom
        self.preRestoreBackup = preRestoreBackup
    }
}

/// Auto-backup engine for one repository.
public struct WorktreeBackup: Sendable {
    public let runner: Runner

    /// Clock injection (tests pass scripted clocks; production uses
    /// `SnapshotWriter.defaultClock`).
    public let clock: @Sendable () -> Date

    /// `:(exclude,glob)` pathspecs withheld from every backup —
    /// likely secrets (an unignored `.env` must NOT get persisted
    /// into git objects every 30 minutes) and tool temporaries
    /// (ADR 0075 amendment). Defaults to the curated
    /// `JunkFilePatterns` set; injectable for tests and the future
    /// Preferences-driven user extension.
    public let excludedPatterns: [String]

    public init(
        runner: Runner,
        clock: @Sendable @escaping () -> Date = SnapshotWriter.defaultClock,
        excludedPatterns: [String] = JunkFilePatterns.backupExcludePathspecs
    ) {
        self.runner = runner
        self.clock = clock
        self.excludedPatterns = excludedPatterns
    }

    // MARK: - Create

    /// Snapshot the dirty working tree into a backup ref. Returns nil
    /// when the tree is clean; returns the EXISTING newest backup for
    /// this branch when the dirty tree is byte-identical to it (no
    /// twin refs for unchanged state across ticks).
    public func createBackupIfDirty() async throws -> BackupRefName? {
        let status = try await runner.run(["status", "--porcelain", "-z"])
        guard !status.stdout.isEmpty else { return nil }

        let branch = try await currentBranchLabel()
        let tree = try await stageEverythingToThrowawayIndex()

        // Junk-only-dirty guard: if everything dirty was excluded by
        // the deny patterns, the backup tree equals HEAD's tree (or
        // the empty tree on an unborn branch) and there is nothing
        // worth preserving — minting a ref would be pure churn.
        if try await tree == baselineTreeSHA() {
            return nil
        }

        if let newest = try await newestBackup(for: branch) {
            let newestTree = try await treeSHA(of: newest.ref.refName)
            if newestTree == tree {
                return newest.ref
            }
        }

        let headSHA = try await headSHAIfAny()
        var commitArgs = [
            "commit-tree",
            tree,
            "-m",
            "Sprig auto-backup of \(branch) (uncommitted work)"
        ]
        if let headSHA {
            commitArgs.append(contentsOf: ["-p", headSHA])
        }
        let commit = try await runner.run(commitArgs).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ref = try await vacantRef(branch: branch, startingAt: clock())
        _ = try await runner.run(["update-ref", ref.refName, commit])
        return ref
    }

    /// Mint a ref name that doesn't already point at a DIFFERENT
    /// commit — two backups of the same branch within one second
    /// must not clobber each other (restore's fail-closed pre-backup
    /// runs moments after the backup being restored was read; an
    /// overwrite there would destroy the restore source). Bumps the
    /// timestamp by one second per collision, bounded.
    private func vacantRef(branch: String, startingAt date: Date) async throws -> BackupRefName {
        for offset in 0 ..< 16 {
            guard let candidate = BackupRefName(
                timestamp: date.addingTimeInterval(TimeInterval(offset)),
                branchLabel: branch
            ) else {
                throw GitError.parseFailure(
                    context: "backup ref label sanitization produced an empty label",
                    rawSnippet: branch
                )
            }
            let probe = try await runner.run(
                ["rev-parse", "--quiet", "--verify", candidate.refName],
                throwOnNonZero: false
            )
            if probe.exitCode != 0 { return candidate }
        }
        throw GitError.parseFailure(
            context: "could not find a vacant backup ref slot within 16 seconds of",
            rawSnippet: BackupRefName(timestamp: date, branchLabel: branch)?.refName ?? branch
        )
    }

    // MARK: - List + prune

    /// All backup refs, newest first.
    public func backups() async throws -> [WorktreeBackupEntry] {
        let output = try await runner.run([
            "for-each-ref",
            "--format=%(refname)\t%(objectname)",
            BackupRefName.prefix
        ])
        var entries: [WorktreeBackupEntry] = []
        for line in output.stdoutString.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard fields.count == 2,
                  let ref = BackupRefName.parse(String(fields[0]))
            else { continue } // skip foreign refs under the prefix
            entries.append(WorktreeBackupEntry(ref: ref, sha: String(fields[1])))
        }
        return entries.sorted { $0.ref.timestamp > $1.ref.timestamp }
    }

    /// Delete backups strictly older than `cutoff`. Returns what was
    /// deleted.
    @discardableResult
    public func prune(olderThan cutoff: Date) async throws -> [BackupRefName] {
        let victims = try await backups().filter { $0.ref.timestamp < cutoff }
        for victim in victims {
            _ = try await runner.run(["update-ref", "-d", victim.ref.refName])
        }
        return victims.map(\.ref)
    }

    // MARK: - Restore

    /// Restore a backup over the working tree — fail-closed: the
    /// current dirty state (if any) is backed up first, so restore
    /// itself can be undone. Additive: files created after the backup
    /// are left in place; the index is untouched.
    ///
    /// The source is pinned to its commit SHA *before* the pre-restore
    /// backup runs, so the restore is immune to any ref movement in
    /// between (belt to ``vacantRef``'s suspenders).
    public func restore(_ refName: String) async throws -> WorktreeRestoreOutcome {
        guard let ref = BackupRefName.parse(refName) else {
            throw GitError.parseFailure(
                context: "not a Sprig backup ref (expected \(BackupRefName.prefix)<ts>/<branch>)",
                rawSnippet: refName
            )
        }
        let sourceSHA = try await runner.run(["rev-parse", "--verify", "\(refName)^{commit}"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let preRestore = try await createBackupIfDirty()
        _ = try await runner.run(["restore", "--source=\(sourceSHA)", "--worktree", "--", ":/"])
        return WorktreeRestoreOutcome(restoredFrom: ref, preRestoreBackup: preRestore)
    }

    // MARK: - Internals

    private func currentBranchLabel() async throws -> String {
        let result = try await runner.run(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return "detached" }
        let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "detached" : name
    }

    private func headSHAIfAny() async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "--quiet", "--verify", "HEAD"],
            throwOnNonZero: false
        )
        guard result.exitCode == 0 else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the backup tree in a throwaway index so the real index
    /// is never touched. The temp file is cleaned up before return.
    private func stageEverythingToThrowawayIndex() async throws -> String {
        let tempIndex = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-backup-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempIndex) }

        let scratch = Runner(
            gitPath: runner.gitPath,
            defaultWorkingDirectory: runner.defaultWorkingDirectory,
            environmentOverrides: runner.environmentOverrides
                .merging(["GIT_INDEX_FILE": tempIndex.path]) { _, new in new },
            log: runner.log
        )
        if try await headSHAIfAny() != nil {
            _ = try await scratch.run(["read-tree", "HEAD"])
        } else {
            _ = try await scratch.run(["read-tree", "--empty"])
        }
        var addArgs = ["add", "-A", "--", "."]
        addArgs.append(contentsOf: excludedPatterns.map { ":(exclude,glob)\($0)" })
        _ = try await scratch.run(addArgs)
        return try await scratch.run(["write-tree"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HEAD's tree, or the canonical git empty-tree object on an
    /// unborn branch (a universal constant — `git hash-object -t
    /// tree /dev/null` on any repo).
    private func baselineTreeSHA() async throws -> String {
        guard try await headSHAIfAny() != nil else {
            return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        }
        return try await runner.run(["rev-parse", "HEAD^{tree}"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func newestBackup(for branchLabel: String) async throws -> WorktreeBackupEntry? {
        let label = BackupRefName.sanitize(branchLabel)
        return try await backups().first { $0.ref.branchLabel == label }
    }

    private func treeSHA(of refName: String) async throws -> String {
        try await runner.run(["rev-parse", "\(refName)^{tree}"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
