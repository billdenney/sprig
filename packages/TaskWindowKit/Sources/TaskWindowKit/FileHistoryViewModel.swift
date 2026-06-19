// FileHistoryViewModel.swift
//
// ADR 0090 — the portable engine behind the per-file "Show History… /
// Restore Previous Version…" task window (the SharePoint "version
// history → restore this version" framing). Lists a file's revisions via
// `git log --follow`, shows a chosen version's bytes through
// `CatFileBatch`, and restores one into the worktree — additive (never a
// history rewrite) and fail-closed: the file's current bytes are backed
// up to an ADR 0090 `FileBackup` ref FIRST, so a restore is itself
// reversible ("Sprig saved a copy of your current file before restoring").
//
// Tier 1, portable. Shells bind to ``revisions``, ``selectedContent``,
// and ``state``. Binary PREVIEW is deferred to ADR 0086; a binary
// version is flagged (``FileHistoryPayload/isBinary``) so the UI can say
// so, while restore still writes the bytes faithfully.

import Foundation
import GitCore
import SafetyKit

/// The bytes of one file version, plus the binary/text signal.
public struct FileHistoryPayload: Sendable, Equatable {
    /// Raw blob bytes (UTF-8 text for the common case).
    public let content: Data
    /// Byte length (a "large file" UI proxy without holding the bytes).
    public let byteCount: Int
    /// True when the bytes look binary (contain a NUL) — preview is
    /// deferred to ADR 0086, so the UI shows a "preview only" note.
    public let isBinary: Bool

    public init(content: Data) {
        self.content = content
        self.byteCount = content.count
        self.isBinary = content.contains(0)
    }
}

/// View model for the File History task window.
public actor FileHistoryViewModel {
    /// The repo this VM operates on.
    public let repoURL: URL
    /// The file (path at HEAD) whose history this is.
    public let filePath: String

    /// Revisions of ``filePath``, newest first (lineage follows renames).
    public private(set) var revisions: [FileRevision] = []

    /// The most recently shown version's bytes, or nil.
    public private(set) var selectedContent: FileHistoryPayload?

    /// Lifecycle of the latest list / show / restore op. Success payload
    /// is the revision count (list) or byte count (show / restore).
    public private(set) var state: TaskWindowState<Int> = .idle

    /// The safety backup written by the most recent ``restore(_:)``, for
    /// the undo banner.
    public private(set) var lastSafetyBackup: FileBackupRefName?

    private let runner: Runner
    private let history: FileHistory
    private let backup: FileBackup

    public init(repoURL: URL, filePath: String, runner: Runner) {
        self.repoURL = repoURL
        self.filePath = filePath
        self.runner = runner
        history = FileHistory(runner: runner)
        backup = FileBackup(runner: runner)
    }

    // MARK: - Reads

    /// Load the revision list from scratch.
    public func loadHistory() async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            revisions = try await history.revisions(of: filePath)
            state = .success(revisions.count)
        } catch {
            revisions = []
            state = .failure(.init(from: error))
        }
    }

    /// Show a revision's bytes (read through `CatFileBatch`).
    public func showVersion(_ revision: FileRevision) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            let payload = try await readVersion(revision)
            selectedContent = payload
            state = .success(payload.byteCount)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    // MARK: - Restore

    /// Restore a revision's bytes into the worktree at ``filePath`` —
    /// fail-closed: back up the file's current bytes first. Additive;
    /// never rewrites history.
    public func restore(_ revision: FileRevision) async {
        if case .busy = state { return }
        state = .busy(progress: nil)
        do {
            let payload = try await readVersion(revision)
            // Fail-closed: back up the file's current bytes FIRST (this
            // also refuses a symlink path, before any write happens).
            let made = try await backup.backupFile(at: filePath)
            let target = repoURL.appendingPathComponent(filePath)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.content.write(to: target)
            } catch {
                // The write failed after the backup was minted — delete
                // the orphan ref so no phantom "undo" is offered.
                if let made { _ = try? await runner.run(["update-ref", "-d", made.refName]) }
                throw error
            }
            // Commit the undo handle only once the write actually landed.
            lastSafetyBackup = made
            selectedContent = payload
            state = .success(payload.byteCount)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Reset state to idle (keeps revisions + content).
    public func reset() {
        state = .idle
    }

    // MARK: - Internals

    /// Read `revision`'s blob via a short-lived `CatFileBatch` — the
    /// documented foundation for history reads (git-backend.md).
    private func readVersion(_ revision: FileRevision) async throws -> FileHistoryPayload {
        let catFile = try await CatFileBatch(repoURL: repoURL)
        defer { Task { await catFile.close() } }
        let bytes = try await history.contents(of: revision, using: catFile)
        return FileHistoryPayload(content: bytes)
    }
}
