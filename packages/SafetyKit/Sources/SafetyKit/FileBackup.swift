// FileBackup.swift
//
// ADR 0090 — a single-file safety backup, the fail-closed insurance
// behind "Restore Previous Version…": before File History overwrites a
// file with an older version, the file's CURRENT bytes are captured here
// so the restore is itself reversible ("Sprig saved a copy of your
// current file before restoring").
//
// `WorktreeBackup` (ADR 0075) backs up the WHOLE working tree into a
// commit; for one file that is overkill. This primitive stores just the
// one file's bytes as a blob and points a ref at it
// (`refs/sprig/filebackup/<ts>/<label>`). A ref keeps its target
// reachable regardless of object type, so the blob survives `git gc`,
// and restore is a plain `cat-file blob` → write (mirroring
// `MergeApplyPipeline`'s whole-side apply). The atomic
// `update-ref --stdin create` + same-second timestamp-bump collision
// handling mirrors `WorktreeBackup` exactly.
//
// Restore is fail-closed: it backs up the file's current bytes FIRST,
// then overwrites — so restoring a restore returns the prior bytes.

import Foundation
import GitCore

/// One `refs/sprig/filebackup/<ts>/<label>` ref name.
public struct FileBackupRefName: Sendable, Equatable, Hashable {
    public static let prefix = "refs/sprig/filebackup/"

    /// Snapshot instant (UTC, second precision; same 16-char format as
    /// ADR 0033/0075 refs).
    public let timestamp: Date
    /// Sanitized file-path label (`src-main.swift` for `src/main.swift`).
    public let label: String

    public init?(timestamp: Date, filePath: String) {
        let label = Self.sanitize(filePath)
        guard !label.isEmpty else { return nil }
        self.timestamp = timestamp
        self.label = label
    }

    /// Construct from an already-sanitized label segment (used by
    /// ``parse(_:)``). Percent-encoding is NOT idempotent — re-sanitizing
    /// `f%2Etxt` would double-encode the `%` — so the parsed segment is
    /// stored verbatim.
    private init(timestamp: Date, sanitizedLabel: String) {
        self.timestamp = timestamp
        self.label = sanitizedLabel
    }

    public var refName: String {
        "\(Self.prefix)\(SnapshotRefName.formatTimestamp(timestamp))/\(label)"
    }

    /// Parse a full ref name; nil for anything that isn't exactly
    /// `refs/sprig/filebackup/<16-char-ts>/<label>`. The label segment is
    /// stored verbatim (it was already sanitized when minted).
    public static func parse(_ refName: String) -> FileBackupRefName? {
        guard refName.hasPrefix(prefix) else { return nil }
        let parts = refName.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let date = SnapshotRefName.parseTimestamp(String(parts[0])),
              !parts[1].isEmpty
        else { return nil }
        return FileBackupRefName(timestamp: date, sanitizedLabel: String(parts[1]))
    }

    /// Map a file path to a ref-safe label by percent-encoding every
    /// byte outside `[A-Za-z0-9_-]` (notably `/`, `.`, and spaces).
    ///
    /// Keeping the allowed set this tight guarantees a VALID ref segment
    /// — git rejects refs containing `..`, a leading `.`, or a `.lock`
    /// suffix, so a path like `.gitignore` or `a..b` would otherwise
    /// fail `update-ref`. It is also INJECTIVE, so distinct paths get
    /// distinct labels (`a/b` → `a%2Fb` ≠ `a-b`) and ``backups(for:)``
    /// can't cross-contaminate.
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var result = ""
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    let hex = String(byte, radix: 16, uppercase: true)
                    result += "%" + (hex.count == 1 ? "0\(hex)" : hex)
                }
            }
        }
        return result
    }
}

/// Errors specific to ``FileBackup``.
public enum FileBackupError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The path is a symbolic link; File History refuses to back up or
    /// restore through it (writing a file's text content over a link
    /// would follow it out of the repo).
    case refusedSymlink(String)

    public var description: String {
        switch self {
        case let .refusedSymlink(path):
            "'\(path)' is a symbolic link; restoring its contents isn't supported"
        }
    }
}

/// A listed file backup: where it is + the blob it points at.
public struct FileBackupEntry: Sendable, Equatable {
    public let ref: FileBackupRefName
    public let blobSHA: String

    public init(ref: FileBackupRefName, blobSHA: String) {
        self.ref = ref
        self.blobSHA = blobSHA
    }
}

/// Outcome of ``FileBackup/restore(_:to:)``.
public struct FileRestoreOutcome: Sendable, Equatable {
    /// The backup that was written over the file.
    public let restoredFrom: FileBackupRefName
    /// The fail-closed backup of the pre-restore bytes, or nil when the
    /// file didn't exist going in.
    public let preRestoreBackup: FileBackupRefName?

    public init(restoredFrom: FileBackupRefName, preRestoreBackup: FileBackupRefName?) {
        self.restoredFrom = restoredFrom
        self.preRestoreBackup = preRestoreBackup
    }
}

/// Single-file backup engine for one repository.
public struct FileBackup: Sendable {
    public let runner: Runner
    public let clock: @Sendable () -> Date

    public init(
        runner: Runner,
        clock: @Sendable @escaping () -> Date = SnapshotWriter.defaultClock
    ) {
        self.runner = runner
        self.clock = clock
    }

    /// The repo root the runner operates in (its working directory, or
    /// the process cwd as a fallback).
    private var workdir: URL {
        runner.defaultWorkingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Create

    /// Capture the file's current bytes into a backup ref. Returns nil
    /// when the file doesn't exist on disk (nothing to back up).
    public func backupFile(at path: String) async throws -> FileBackupRefName? {
        let absolute = workdir.appendingPathComponent(path)
        // Refuse symlinks: `git hash-object` would follow the link and
        // capture the TARGET's bytes, and a later restore would write
        // THROUGH the link — escaping the repo. `attributesOfItem` uses
        // lstat semantics, so even a dangling link is caught. Because
        // every restore path backs up before writing, this one guard
        // protects all of them from the symlink-escape.
        let attributes = try? FileManager.default.attributesOfItem(atPath: absolute.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw FileBackupError.refusedSymlink(path)
        }
        guard FileManager.default.fileExists(atPath: absolute.path) else { return nil }

        let blob = try await runner.run(["hash-object", "-w", "--", path]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await mintBackup(blob: blob, path: path, startingAt: clock())
    }

    // MARK: - List + prune

    /// All file-backup refs for one path, newest first.
    public func backups(for path: String) async throws -> [FileBackupEntry] {
        let label = FileBackupRefName.sanitize(path)
        return try await allBackups().filter { $0.ref.label == label }
    }

    /// All file-backup refs, newest first.
    public func allBackups() async throws -> [FileBackupEntry] {
        let output = try await runner.run([
            "for-each-ref",
            "--format=%(refname)\t%(objectname)",
            FileBackupRefName.prefix
        ])
        var entries: [FileBackupEntry] = []
        output.stdoutString.enumerateLines { line, _ in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let ref = FileBackupRefName.parse(String(fields[0])) else { return }
            entries.append(FileBackupEntry(ref: ref, blobSHA: String(fields[1])))
        }
        return entries.sorted { $0.ref.timestamp > $1.ref.timestamp }
    }

    /// Delete backups strictly older than `cutoff`.
    @discardableResult
    public func prune(olderThan cutoff: Date) async throws -> [FileBackupRefName] {
        let victims = try await allBackups().filter { $0.ref.timestamp < cutoff }
        for victim in victims {
            _ = try await runner.run(["update-ref", "-d", victim.ref.refName])
        }
        return victims.map(\.ref)
    }

    // MARK: - Restore

    /// Restore a backup's bytes over `path` — fail-closed: the file's
    /// current bytes are backed up first, so the restore is itself
    /// reversible.
    public func restore(_ refName: String, to path: String) async throws -> FileRestoreOutcome {
        guard let ref = FileBackupRefName.parse(refName) else {
            throw GitError.parseFailure(
                context: "not a Sprig file backup (expected \(FileBackupRefName.prefix)<ts>/<label>)",
                rawSnippet: refName
            )
        }
        let bytes = try await runner.run(["cat-file", "blob", refName]).stdout

        let preRestore = try await backupFile(at: path)
        let absolute = workdir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: absolute.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic-with-retry: a plain write would leave the worktree file
        // torn if we crash or the disk fills mid-write — precisely the
        // bytes `preRestore` just captured — and would fail on Windows
        // when Defender or an editor holds a handle on the target.
        try await AtomicWriteWithRetry.run(bytes, to: absolute)
        return FileRestoreOutcome(restoredFrom: ref, preRestoreBackup: preRestore)
    }

    // MARK: - Internals

    /// Upper bound on same-second collisions before failing closed.
    /// Mirrors ``WorktreeBackup`` — each collision bumps the timestamp
    /// one second.
    private static let sameSecondLimit = 16

    /// Atomically write `blob` to the first vacant
    /// `refs/sprig/filebackup/<ts>/<label>` slot, bumping the timestamp
    /// one second per collision. Uses `update-ref --stdin`'s `create`,
    /// which verifies non-existence under the ref lock, so a same-second
    /// loser fails closed and advances instead of clobbering.
    private func mintBackup(
        blob: String,
        path: String,
        startingAt date: Date
    ) async throws -> FileBackupRefName {
        for offset in 0 ..< Self.sameSecondLimit {
            guard let candidate = FileBackupRefName(
                timestamp: date.addingTimeInterval(TimeInterval(offset)),
                filePath: path
            ) else {
                throw GitError.parseFailure(
                    context: "file-backup label sanitization produced an empty label",
                    rawSnippet: path
                )
            }
            let create = try await runner.run(
                ["update-ref", "--stdin"],
                stdin: Data("create \(candidate.refName) \(blob)\n".utf8),
                throwOnNonZero: false
            )
            if create.exitCode == 0 { return candidate }
            // create failed: if the name is taken this second advance,
            // otherwise it's a genuine git failure.
            let exists = try await runner.run(
                ["rev-parse", "--quiet", "--verify", candidate.refName],
                throwOnNonZero: false
            )
            guard exists.exitCode == 0 else {
                throw GitError.nonZeroExit(
                    command: ["update-ref", "--stdin", "create", candidate.refName, blob],
                    exitCode: create.exitCode,
                    stderr: create.stderrString,
                    stdout: create.stdoutString
                )
            }
        }
        throw GitError.parseFailure(
            context: "could not find a vacant file-backup slot within \(Self.sameSecondLimit) seconds of",
            rawSnippet: FileBackupRefName(timestamp: date, filePath: path)?.refName ?? path
        )
    }
}
